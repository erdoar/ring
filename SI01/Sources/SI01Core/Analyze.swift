import Foundation

struct Peak {
    var hz: Double
    var mag: Double
    var harmonic: Double
}

/// Scratch for the gate and the howl scan. Runs on the analysis worker, never the callback.
/// Buffers and the FFT setup exist for the life of the engine.
final class Analyzer {
    let count: Int
    private let win: [Double]
    var hann: [Double]
    var mag: [Double]
    var peaks: [Peak]
    private var gathered: [Peak]
    private let fft: RealFFT

    init(count: Int = 1024) {
        self.count = count
        let denom = Double(count - 1)
        win = (0 ..< count).map { 0.5 - 0.5 * cos((2 * Double.pi * Double($0)) / denom) }
        hann = [Double](repeating: 0, count: count)
        mag = [Double](repeating: 0, count: count / 2)
        peaks = [Peak](repeating: Peak(hz: 0, mag: 0, harmonic: 0), count: 8)
        gathered = [Peak](repeating: Peak(hz: 0, mag: 0, harmonic: 0), count: 256)
        fft = RealFFT(count: count)
    }

    func window(_ frame: [Double]) {
        for i in 0 ..< count { hann[i] = frame[i] * win[i] }
    }

    func fftMag() {
        hann.withUnsafeBufferPointer { src in
            mag.withUnsafeMutableBufferPointer { fft.magnitudes(src.baseAddress!, into: $0.baseAddress!) }
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
        let energy = frame.withUnsafeBufferPointer { dot($0.baseAddress!, 1, $0.baseAddress!, 1, $0.count) }
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
        let n = frame.count
        return frame.withUnsafeBufferPointer { buf -> Double in
            let f = buf.baseAddress!
            var bestLag = lag0
            var best = -1.0
            if minLag <= maxLag {
                for lag in minLag ... maxLag {
                    let limit = n - lag
                    let num = dot(f, 1, f + lag, 1, limit)
                    let a = dot(f, 1, f, 1, limit)
                    let b = dot(f + lag, 1, f + lag, 1, limit)
                    let c = num / sqrt(a * b + 1e-18)
                    if c > best {
                        best = c
                        bestLag = lag
                    }
                }
            }
            if best < 0.85 { return coarseHz }
            func corr(_ lag: Int) -> Double {
                let limit = n - lag
                return limit <= 0 ? 0 : dot(f, 1, f + lag, 1, limit)
            }
            let c0 = corr(bestLag - 1)
            let c1 = corr(bestLag)
            let c2 = corr(bestLag + 1)
            let denom = c0 - 2 * c1 + c2
            let delta = abs(denom) < 1e-12 ? 0 : (0.5 * (c0 - c2)) / denom
            let lag = Double(bestLag) + min(0.5, max(-0.5, delta))
            return sr / lag
        }
    }

    private func sharp(_ bin: Int) -> Double {
        if bin < 0 || bin >= mag.count { return 0 }
        let peak = mag[bin]
        let left = mag[max(0, bin - 2)]
        let right = mag[min(mag.count - 1, bin + 2)]
        return peak / ((left + right) / 2 + 1e-12)
    }
}
