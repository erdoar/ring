import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Strided dot product. A negative stride starts at `b` and walks backwards, as in vDSP.
@inline(__always)
func dot(_ a: UnsafePointer<Double>, _ strideA: Int, _ b: UnsafePointer<Double>, _ strideB: Int, _ n: Int) -> Double {
    #if canImport(Accelerate)
    var sum = 0.0
    vDSP_dotprD(a, strideA, b, strideB, &sum, vDSP_Length(n))
    return sum
    #else
    var sum = 0.0
    for k in 0 ..< n { sum += a[k * strideA] * b[k * strideB] }
    return sum
    #endif
}

/// Real forward FFT magnitudes, |X[k]| for k in 0 ..< n/2, unscaled like a textbook DFT.
final class RealFFT {
    let n: Int
    private let re: UnsafeMutablePointer<Double>
    private let im: UnsafeMutablePointer<Double>
    #if canImport(Accelerate)
    private let log2n: vDSP_Length
    private let setup: FFTSetupD
    #endif

    init(count: Int) {
        precondition(count > 1 && count & (count - 1) == 0, "FFT size must be a power of two")
        n = count
        #if canImport(Accelerate)
        re = .allocate(capacity: count / 2)
        im = .allocate(capacity: count / 2)
        log2n = vDSP_Length(count.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        #else
        re = .allocate(capacity: count)
        im = .allocate(capacity: count)
        #endif
    }

    deinit {
        #if canImport(Accelerate)
        vDSP_destroy_fftsetupD(setup)
        #endif
        re.deallocate()
        im.deallocate()
    }

    func magnitudes(_ input: UnsafePointer<Double>, into mag: UnsafeMutablePointer<Double>) {
        let half = n / 2
        #if canImport(Accelerate)
        var split = DSPDoubleSplitComplex(realp: re, imagp: im)
        input.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        // zrip packs Nyquist into imagp[0] and scales every bin by two.
        let dc = abs(re[0])
        im[0] = 0
        vDSP_zvabsD(&split, 1, mag, 1, vDSP_Length(half))
        mag[0] = dc
        var scale = 0.5
        vDSP_vsmulD(mag, 1, &scale, mag, 1, vDSP_Length(half))
        #else
        for i in 0 ..< n {
            re[i] = input[i]
            im[i] = 0
        }
        var j = 0
        for i in 1 ..< n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j { swap(&re[i], &re[j]) }
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
                let h = len / 2
                for k in 0 ..< h {
                    let uRe = re[base + k]
                    let uIm = im[base + k]
                    let vRe = re[base + k + h] * wRe - im[base + k + h] * wIm
                    let vIm = re[base + k + h] * wIm + im[base + k + h] * wRe
                    re[base + k] = uRe + vRe
                    im[base + k] = uIm + vIm
                    re[base + k + h] = uRe - vRe
                    im[base + k + h] = uIm - vIm
                    let nextRe = wRe * wlenRe - wIm * wlenIm
                    wIm = wRe * wlenIm + wIm * wlenRe
                    wRe = nextRe
                }
                base += len
            }
            len <<= 1
        }
        for k in 0 ..< half { mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
        #endif
    }
}
