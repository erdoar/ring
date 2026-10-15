import Foundation

let rate = 48000
let sr = Double(rate)

/// What a stimulus is for. `sweep` calibrates latency and level; `howl` files carry a growing
/// feedback tone that should be cut; `voice` files contain no feedback and should pass unchanged.
enum Kind: String, Codable { case sweep, howl, voice }

struct Stimulus: Codable {
    let name: String
    let kind: Kind
    let about: String
    var howlHz: Double?
    var howlOnset: Double?
}

struct Rng {
    var s: UInt64
    mutating func next() -> Double {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Double(s >> 11) / Double(1 << 53) * 2 - 1
    }
}

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func bandpass(_ f: Double, q: Double) -> Biquad { rbj(f, q: q) { _, alpha in (alpha, 0, -alpha) } }
    static func notch(_ f: Double, q: Double) -> Biquad { rbj(f, q: q) { c, _ in (1, -2 * c, 1) } }

    private static func rbj(_ f: Double, q: Double, _ num: (Double, Double) -> (Double, Double, Double)) -> Biquad {
        let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        let (n0, n1, n2) = num(c, alpha)
        return Biquad(b0: n0 / a0, b1: n1 / a0, b2: n2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

func db(_ v: Double) -> Double { pow(10, v / 20) }

func scaleToRms(_ x: inout [Double], _ dbfs: Double) {
    let rms = sqrt(x.reduce(0) { $0 + $1 * $1 } / Double(max(1, x.count)))
    guard rms > 0 else { return }
    let g = db(dbfs) / rms
    for i in x.indices { x[i] *= g }
}

func pink(_ seconds: Double, dbfs: Double, seed: UInt64) -> [Double] {
    var r = Rng(s: seed)
    var b = [Double](repeating: 0, count: 7)
    var y = (0 ..< Int(seconds * sr)).map { _ -> Double in
        let w = r.next()
        b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
        b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
        b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
        let s = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
        b[6] = w * 0.115926
        return s
    }
    scaleToRms(&y, dbfs)
    return y
}

/// A sung note: harmonic series with a gentle formant tilt, optional vibrato, 60 ms fades.
func sungNote(_ f0: Double, seconds: Double, vibratoHz: Double, cents: Double, dbfs: Double) -> [Double] {
    let n = Int(seconds * sr), fade = Int(0.06 * sr)
    var phase = 0.0
    var y = [Double](repeating: 0, count: n)
    for i in 0 ..< n {
        let t = Double(i) / sr
        phase += 2 * Double.pi * f0 * pow(2, cents / 1200 * sin(2 * Double.pi * vibratoHz * t)) / sr
        var s = 0.0
        var k = 1
        while Double(k) * f0 < 12000 {
            let fk = Double(k) * f0
            s += sin(Double(k) * phase) / Double(k) * (1 + 2 * exp(-pow((fk - 700) / 400, 2)) + exp(-pow((fk - 2800) / 600, 2)))
            k += 1
        }
        y[i] = s * min(1, Double(min(i, n - 1 - i)) / Double(fade))
    }
    scaleToRms(&y, dbfs)
    return y
}

/// A feedback tone: silent until `onset`, then rising `dbPerSecond` from `startDb` to `capDb` (peak dBFS).
func howl(_ hz: Double, seconds: Double, onset: Double, startDb: Double = -50, dbPerSecond: Double = 6, capDb: Double = -12) -> [Double] {
    (0 ..< Int(seconds * sr)).map { i in
        let t = Double(i) / sr
        guard t >= onset else { return 0 }
        return db(min(capDb, startDb + dbPerSecond * (t - onset))) * sin(2 * Double.pi * hz * t)
    }
}

func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + $1 } }

func logSweep(seconds: Double, from f1: Double, to f2: Double, dbfs: Double) -> [Double] {
    let n = Int(seconds * sr), k = log(f2 / f1)
    return (0 ..< n).map { i in
        let t = Double(i) / sr
        let fade = min(1, Double(min(i, n - 1 - i)) / (0.01 * sr))
        return db(dbfs) * fade * sin(2 * Double.pi * f1 * seconds / k * (exp(t / seconds * k) - 1))
    }
}

func fricatives(seconds: Double, dbfs: Double, seed: UInt64) -> [Double] {
    var r = Rng(s: seed)
    var bp = Biquad.bandpass(5500, q: 0.7)
    let burst = Int(0.12 * sr), period = Int(0.4 * sr)
    var y = (0 ..< Int(seconds * sr)).map { i -> Double in
        let p = i % period
        let env = p < burst ? sin(Double.pi * Double(p) / Double(burst)) : 0
        return bp.run(r.next() * env)
    }
    scaleToRms(&y, dbfs)
    return y
}

/// Vocal fry: an irregular ~70 Hz glottal pulse train through two formants.
func fry(seconds: Double, dbfs: Double, seed: UInt64) -> [Double] {
    var r = Rng(s: seed)
    var f1 = Biquad.bandpass(600, q: 4), f2 = Biquad.bandpass(1800, q: 5)
    var next = 0
    var y = (0 ..< Int(seconds * sr)).map { i -> Double in
        var pulse = 0.0
        if i >= next { pulse = 1 + 0.3 * r.next(); next = i + Int(sr / (70 * (1 + 0.15 * r.next()))) }
        return f1.run(pulse) + 0.6 * f2.run(pulse)
    }
    scaleToRms(&y, dbfs)
    return y
}

func makeStimuli() -> [(Stimulus, [Double])] {
    let silence = [Double](repeating: 0, count: Int(0.5 * sr))
    return [
        (Stimulus(name: "sweep", kind: .sweep, about: "40 Hz–18 kHz log sweep at -12 dBFS. Sets latency and level for the run."),
         silence + logSweep(seconds: 3, from: 40, to: 18000, dbfs: -12) + silence + silence),
        (Stimulus(name: "howl-2k5", kind: .howl, about: "2.5 kHz tone rising 6 dB/s from 1 s over a pink-noise room bed.", howlHz: 2500, howlOnset: 1),
         mix(pink(8, dbfs: -36, seed: 1), howl(2500, seconds: 8, onset: 1))),
        (Stimulus(name: "howl-315", kind: .howl, about: "Low 315 Hz howl rising 6 dB/s over the room bed.", howlHz: 315, howlOnset: 1),
         mix(pink(8, dbfs: -36, seed: 2), howl(315, seconds: 8, onset: 1))),
        (Stimulus(name: "howl-under-note", kind: .howl, about: "Howl at 1980 Hz, the 6th harmonic of a 330 Hz sung note with vibrato. The note must survive.", howlHz: 1980, howlOnset: 1),
         mix(sungNote(330, seconds: 8, vibratoHz: 5, cents: 30, dbfs: -20), howl(1980, seconds: 8, onset: 1))),
        (Stimulus(name: "vibrato-note", kind: .voice, about: "220 Hz sung note, 5.5 Hz vibrato ±50 cents. No feedback."),
         sungNote(220, seconds: 6, vibratoHz: 5.5, cents: 50, dbfs: -18)),
        (Stimulus(name: "straight-note", kind: .voice, about: "440 Hz note with no vibrato: looks most like a howl. No feedback."),
         sungNote(440, seconds: 6, vibratoHz: 0, cents: 0, dbfs: -18)),
        (Stimulus(name: "fricatives", kind: .voice, about: "120 ms 's'-like noise bursts around 5.5 kHz. No feedback."),
         fricatives(seconds: 5, dbfs: -24, seed: 3)),
        (Stimulus(name: "fry", kind: .voice, about: "Irregular 70 Hz vocal fry through two formants. No feedback."),
         fry(seconds: 5, dbfs: -24, seed: 4)),
    ]
}
