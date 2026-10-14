import Foundation

struct Peak {
    var hz: Double
    var mag: Double
    var harmonic: Double
}

/// Scratch for the gate and the bleed scan. Buffers exist for the life of the engine.
final class Analyzer {
    let count: Int
    var hann: [Double]
    var re: [Double]
    var im: [Double]
    var mag: [Double]
    var peaks: [Peak]
    private var gathered: [Peak]

    init(count: Int = 1024) {
        self.count = count
        hann = [Double](repeating: 0, count: count)
        re = [Double](repeating: 0, count: count)
        im = [Double](repeating: 0, count: count)
        mag = [Double](repeating: 0, count: count / 2)
        peaks = [Peak](repeating: Peak(hz: 0, mag: 0, harmonic: 0), count: 8)
        gathered = [Peak](repeating: Peak(hz: 0, mag: 0, harmonic: 0), count: 256)
    }

    func window(_ frame: [Double]) {
        let n = count
        let denom = Double(n - 1)
        for i in 0 ..< n {
            hann[i] = frame[i] * (0.5 - 0.5 * cos((2 * Double.pi * Double(i)) / denom))
        }
    }

    func fftMag() {
        let n = count
        for i in 0 ..< n {
            re[i] = hann[i]
            im[i] = 0
        }
        var j = 0
        var i = 1
        while i < n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                let tr = re[i]
                re[i] = re[j]
                re[j] = tr
            }
            i += 1
        }
        var len = 2
        while len <= n {
            let ang = (-2 * Double.pi) / Double(len)
            let wlenRe = cos(ang)
            let wlenIm = sin(ang)
            var base = 0
            while base < n {
                var wRe = 1.0
                var wIm = 0.0
                let half = len / 2
                for k in 0 ..< half {
                    let uRe = re[base + k]
                    let uIm = im[base + k]
                    let vRe = re[base + k + half] * wRe - im[base + k + half] * wIm
                    let vIm = re[base + k + half] * wIm + im[base + k + half] * wRe
                    re[base + k] = uRe + vRe
                    im[base + k] = uIm + vIm
                    re[base + k + half] = uRe - vRe
                    im[base + k + half] = uIm - vIm
                    let nextRe = wRe * wlenRe - wIm * wlenIm
                    wIm = wRe * wlenIm + wIm * wlenRe
                    wRe = nextRe
                }
                base += len
            }
            len <<= 1
        }
        for k in 0 ..< mag.count {
            mag[k] = hypot(re[k], im[k])
        }
    }

    /// Loudest eight peaks, stored in `peaks`. Returns how many.
    func findPeaks(frameLength: Int, sr: Double) -> Int {
        let binHz = sr / Double(frameLength)
        let minBin = max(2, Int((70 / binHz).rounded(.down)))
        let maxBin = min(mag.count - 3, Int((6000 / binHz).rounded(.down)))
        var n = 0
        if maxBin >= minBin {
            for k in minBin ... maxBin {
                let m = mag[k]
                if m < mag[k - 1] || m < mag[k + 1] || m < 1e-4 { continue }
                let denom = mag[k - 1] - 2 * m + mag[k + 1]
                let delta = abs(denom) < 1e-12 ? 0 : (0.5 * (mag[k - 1] - mag[k + 1])) / denom
                let hz = (Double(k) + delta) * binHz
                let bin2 = Int((2 * hz / binHz).rounded())
                let bin3 = Int((3 * hz / binHz).rounded())
                let second = bin2 >= 0 && bin2 < mag.count ? mag[bin2] : 0
                let third = bin3 >= 0 && bin3 < mag.count ? mag[bin3] : 0
                let ratio2 = second / (m + 1e-12)
                let ratio3 = third / (m + 1e-12)
                let harmonic =
                    sharp(k) > 6 && sharp(bin2) > 4 && sharp(bin3) > 3 && ratio2 > 0.12 && ratio3 > 0.06
                    ? min(ratio2, ratio3) : 0
                let peak = Peak(hz: hz, mag: m, harmonic: harmonic)
                if n < gathered.count {
                    gathered[n] = peak
                    n += 1
                } else if let quiet = (0 ..< n).min(by: { gathered[$0].mag < gathered[$1].mag }),
                          m > gathered[quiet].mag {
                    gathered[quiet] = peak
                }
            }
        }
        gathered[0 ..< n].sort { $0.mag > $1.mag }
        let keep = min(8, n)
        for i in 0 ..< keep { peaks[i] = gathered[i] }
        return keep
    }

    func likelihood(_ frame: [Double], sr: Double) -> Double {
        if frame.count < count { return 0 }
        var energy = 0.0
        for sample in frame { energy += sample * sample }
        if energy / Double(frame.count) < 1e-8 { return 0 }
        window(frame)
        fftMag()
        let n = findPeaks(frameLength: frame.count, sr: sr)
        var best = 0.0
        for i in 0 ..< n { best = max(best, peaks[i].harmonic) }
        return min(1, max(0, best / 0.25))
    }

    func refineHz(_ frame: [Double], coarseHz: Double, sr: Double) -> Double {
        if coarseHz < 70 || coarseHz > 6000 { return 0 }
        let lag0 = Int((sr / coarseHz).rounded())
        let minLag = max(2, lag0 - 5)
        let maxLag = min(frame.count - 2, lag0 + 5)
        var bestLag = lag0
        var best = -1.0
        let n = frame.count
        if minLag <= maxLag {
            for lag in minLag ... maxLag {
                var num = 0.0
                var a = 0.0
                var b = 0.0
                let limit = n - lag
                for i in 0 ..< limit {
                    let x = frame[i]
                    let y = frame[i + lag]
                    num += x * y
                    a += x * x
                    b += y * y
                }
                let c = num / sqrt(a * b + 1e-18)
                if c > best {
                    best = c
                    bestLag = lag
                }
            }
        }
        if best < 0.85 { return coarseHz }
        func corr(_ lag: Int) -> Double {
            var num = 0.0
            let limit = n - lag
            if limit <= 0 { return 0 }
            for i in 0 ..< limit { num += frame[i] * frame[i + lag] }
            return num
        }
        let c0 = corr(bestLag - 1)
        let c1 = corr(bestLag)
        let c2 = corr(bestLag + 1)
        let denom = c0 - 2 * c1 + c2
        let delta = abs(denom) < 1e-12 ? 0 : (0.5 * (c0 - c2)) / denom
        let lag = Double(bestLag) + min(0.5, max(-0.5, delta))
        return sr / lag
    }

    private func sharp(_ bin: Int) -> Double {
        if bin < 0 || bin >= mag.count { return 0 }
        let peak = mag[bin]
        let left = mag[max(0, bin - 2)]
        let right = mag[min(mag.count - 1, bin + 2)]
        return peak / ((left + right) / 2 + 1e-12)
    }
}
