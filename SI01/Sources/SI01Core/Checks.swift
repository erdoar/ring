import Foundation

public struct KernelCheck {
    public let name: String
    public let pass: Bool
    public let detail: String
}

private func vowel(_ seconds: Double, sr: Double = SR) -> [Double] {
    let n = Int(seconds * sr)
    var y = [Double](repeating: 0, count: n)
    var phase = 0.0
    for i in 0 ..< n {
        let t = Double(i) / sr
        let f0 = 196 * (1 + 0.012 * sin(2 * Double.pi * 5.2 * t))
        phase += (2 * Double.pi * f0) / sr
        var s = 0.0
        for h in 1 ... 8 { s += sin(Double(h) * phase) / Double(h) }
        y[i] = 0.4 * s
    }
    return y
}

private func growingTone(_ seconds: Double, sr: Double = SR) -> [Double] {
    let n = Int(seconds * sr)
    var y = [Double](repeating: 0, count: n)
    for i in 0 ..< n {
        let t = Double(i) / sr
        let amp = min(0.85, 0.008 * pow(10, t * 1.3))
        y[i] = min(0.9, amp) * sin((2 * Double.pi * 1000 * Double(i)) / sr)
    }
    return y
}

private func vibrato(_ seconds: Double, sr: Double = SR) -> [Double] {
    let n = Int(seconds * sr)
    var y = [Double](repeating: 0, count: n)
    var phase = 0.0
    for i in 0 ..< n {
        let t = Double(i) / sr
        let hz = 880 * (1 + 0.03 * sin(2 * Double.pi * 5.5 * t))
        phase += (2 * Double.pi * hz) / sr
        let amp = min(0.8, 0.05 * exp(1.2 * t))
        y[i] = amp * sin(phase)
    }
    return y
}

private func render(_ engine: Engine, _ signal: [Double], _ block: Int) -> [Double] {
    var out = [Double](repeating: 0, count: signal.count)
    var i = 0
    while i < signal.count {
        let n = min(block, signal.count - i)
        signal.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                engine.render(input: src.baseAddress! + i, output: dst.baseAddress! + i, frames: n)
            }
        }
        i += n
    }
    return out
}

private func finite(_ x: [Double]) -> Bool { x.allSatisfy { $0.isFinite } }

private func rms(_ x: [Double], from: Int, to: Int) -> Double {
    let a = max(0, from)
    let b = min(x.count, to)
    var s = 0.0
    for i in a ..< b { s += x[i] * x[i] }
    return sqrt(s / Double(max(1, b - a)))
}

private func nullDb(_ a: [Double], _ b: [Double]) -> Double {
    let n = min(a.count, b.count)
    var s = 0.0
    var r = 0.0
    for i in 0 ..< n {
        let d = a[i] - b[i]
        s += d * d
        r += a[i] * a[i]
    }
    if r < 1e-18 { return -120 }
    return 10 * log10((s + 1e-18) / r)
}

public func kernelChecks() -> [KernelCheck] {
    var checks: [KernelCheck] = []
    let dry = vowel(1.2)
    let engaged = render(Engine(), dry, 32)
    let bypassed = render({ let e = Engine(); e.bypass = true; return e }(), dry, 32)
    let db = nullDb(bypassed, engaged)
    checks.append(KernelCheck(name: "Dead room", pass: db < -60 && finite(engaged), detail: String(format: "null %.1f dB", db)))

    let freeze = Engine()
    _ = render(freeze, dry, 64)
    let before = freeze.tail
    let opened = freeze.likelihood
    _ = render(freeze, vowel(0.4), 64)
    var moved = 0.0
    for i in 0 ..< before.count { moved = max(moved, abs(before[i] - freeze.tail[i])) }
    checks.append(KernelCheck(name: "Voiced freeze", pass: opened >= 0.5 && moved == 0, detail: String(format: "likelihood %.2f, tail move %.6f", opened, moved)))

    let note = Engine()
    _ = render(note, vibrato(1.4), 32)
    let noteGain = note.howlGain.min() ?? 0
    checks.append(KernelCheck(name: "Note on a howl", pass: noteGain == 1 && note.confirmedHowls == 0, detail: String(format: "min howl gain %.3f", noteGain)))

    let tone = growingTone(1.6)
    let grow = Engine()
    let grown = render(grow, tone, 32)
    let from = Int(Double(tone.count) * 0.75)
    let inR = rms(tone, from: from, to: tone.count)
    let outR = rms(grown, from: from, to: grown.count)
    let growGain = grow.howlGain.min() ?? 1
    checks.append(KernelCheck(
        name: "Growing tone",
        pass: grow.likelihood < 0.5 && growGain < 0.5 && outR < inR * 0.8 && finite(grown),
        detail: String(format: "likelihood %.2f, howl %.2f, late %.2f", grow.likelihood, growGain, outR / inR)
    ))

    let capped = Engine()
    capped.freeze = true
    capped.dereverb = 1
    capped.strength = 0.5
    capped.workerEnabled = false
    var aggressiveTail = [Double](repeating: 0, count: TAIL_TAPS)
    aggressiveTail[0] = 40
    capped.setTailForTesting(aggressiveTail)
    let y = [Double](repeating: 0.5, count: 640)
    let cappedOut = render(capped, y, 32)
    let floor = pow(10, -(12 * 0.5) / 20)
    var worst = 0.0
    for i in 256 ..< y.count {
        let ratio = abs(cappedOut[i]) / 0.5
        if worst == 0 || ratio < worst { worst = ratio }
    }
    checks.append(KernelCheck(name: "Cap", pass: worst >= floor - 1e-6, detail: String(format: "remaining %.1f%%", worst * 100)))

    let overrun = Engine()
    overrun.workerEnabled = false
    let rising = growingTone(0.8)
    let overrunOut = render(overrun, rising, 32)
    let tailPeak = overrun.tail.map { abs($0) }.max() ?? 0
    checks.append(KernelCheck(
        name: "Overrun",
        pass: overrunOut.count == rising.count && finite(overrunOut) && tailPeak == 0 && overrun.missedPublish > 0,
        detail: "missed \(overrun.missedPublish)"
    ))

    var delayOK = true
    for sr in [44100.0, 48000.0, 96000.0] {
        let engine = Engine(sr: sr)
        if engine.latency != 0 { delayOK = false }
        engine.mode = .low
        if engine.latency != 127 { delayOK = false }
    }
    checks.append(KernelCheck(name: "Delay report", pass: delayOK, detail: "ZERO 0, LOW 127"))

    let horizon = Engine()
    _ = render(horizon, growingTone(1), 256)
    checks.append(KernelCheck(name: "Horizon", pass: horizon.lastTailHorizon == 256, detail: "FIR horizon \(horizon.lastTailHorizon) for 256-sample host block"))

    let worker = Engine()
    worker.fitMode = .worker
    let workerSignal = growingTone(0.5)
    var posted = false
    var analysed = false
    var workerOut = [Double](repeating: 0, count: workerSignal.count)
    var wi = 0
    while wi < workerSignal.count {
        let n = min(32, workerSignal.count - wi)
        workerSignal.withUnsafeBufferPointer { src in
            workerOut.withUnsafeMutableBufferPointer { dst in
                worker.render(input: src.baseAddress! + wi, output: dst.baseAddress! + wi, frames: n)
            }
        }
        if worker.needsAnalysis {
            analysed = true
            worker.performAnalysis()
        }
        if worker.needsFit {
            posted = true
            worker.performFit()
        }
        wi += n
    }
    checks.append(KernelCheck(
        name: "Analysis and fit leave the callback",
        pass: analysed && posted && !worker.needsFit && worker.missedPublish == 0 && worker.missedAnalysis == 0,
        detail: "analysed \(analysed), posted \(posted), pending \(worker.needsFit), missed \(worker.missedPublish)/\(worker.missedAnalysis)"
    ))
    let bleedSafe = Engine()
    _ = render(bleedSafe, growingTone(0.5), 32)
    let bleedPass = bleedSafe.bleed.allSatisfy { $0 == 1 }
    checks.append(KernelCheck(
        name: "Phase 1 bleed safety",
        pass: bleedPass,
        detail: bleedPass ? "all bands pass unchanged" : "a band was attenuated before a trained student exists"
    ))
    return checks
}
