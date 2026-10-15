import Accelerate
import Foundation

struct Result {
    let stimulus: Stimulus
    var latencyMs = 0.0
    var correlation = 0.0
    var levelDb: Double?
    var detectS: Double?
    var finalCutDb: Double?
    var peakDeltaDb: Double?
    var meanLossDb = 0.0
    var p95LossDb = 0.0
    var cutPct = 0.0
}

/// Hann-windowed 2048-point power spectrum.
final class Spectrum {
    static let n = 2048
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)

    deinit { vDSP_destroy_fftsetup(setup) }

    func power(_ x: [Float], at start: Int) -> [Float] {
        let n = Spectrum.n, half = n / 2
        var buf = [Float](repeating: 0, count: n)
        for i in 0 ..< n where start + i >= 0 && start + i < x.count { buf[i] = x[start + i] * window[i] }
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var p = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &sc, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&sc, 1, &p, 1, vDSP_Length(half))
            }
        }
        p[0] = 0
        return p
    }
}

private let hop = 960
private let binHz = sr / Double(Spectrum.n)
private let bands: [Range<Int>] = (-9 ... 12).map { k in
    let fc = 1000 * pow(2, Double(k) / 3)
    let lo = Int(fc * pow(2, -1.0 / 6) / binHz)
    return lo ..< max(lo + 1, Int(fc * pow(2, 1.0 / 6) / binHz))
}

private func dB(_ p: Double) -> Double { 10 * log10(max(p, 1e-20)) }
private func sumsq(_ x: ArraySlice<Float>) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }

/// Finds the output delay (0–250 ms) by cross-correlating 1.5 s of input from 0.5 s.
func latency(_ x: [Float], _ y: [Float]) -> (lag: Int, correlation: Double) {
    let s = Int(0.5 * sr), len = Int(1.5 * sr), maxLag = Int(0.25 * sr)
    guard x.count >= s + len else { return (0, 0) }
    let seg = Array(x[s ..< s + len])
    var yy = [Float](repeating: 0, count: len + maxLag)
    for i in yy.indices where s + i < y.count { yy[i] = y[s + i] }
    var r = [Float](repeating: 0, count: maxLag + 1)
    vDSP_conv(yy, 1, seg, 1, &r, 1, vDSP_Length(maxLag + 1), vDSP_Length(len))
    var best = 0
    for i in r.indices where abs(r[i]) > abs(r[best]) { best = i }
    let norm = sqrt(sumsq(seg[...]) * sumsq(yy[best ..< best + len]))
    return (best, norm > 0 ? Double(r[best]) / norm : 0)
}

/// `lag` is the run's delay, measured on the sweep: a steady note repeats every period, so its own lag is ambiguous.
func analyse(_ s: Stimulus, x: [Float], y rawY: [Float], gain: Double, lag fixedLag: Int? = nil) -> Result {
    var r = Result(stimulus: s)
    let (found, corr) = latency(x, rawY)
    let lag = fixedLag ?? found
    r.latencyMs = Double(lag) / sr * 1000
    r.correlation = corr
    var y = [Float](repeating: 0, count: x.count)
    for i in y.indices where i + lag < rawY.count { y[i] = rawY[i + lag] / Float(gain) }
    if s.kind == .sweep {
        r.levelDb = dB(sumsq(y[...]) / max(sumsq(x[...]), 1e-20)) + 20 * log10(gain)
        return r
    }

    let spectrum = Spectrum()
    var howlBins: Range<Int>?
    if let hz = s.howlHz { let b = Int((hz / binHz).rounded()); howlBins = max(1, b - 2) ..< b + 3 }
    var frames: [(t: Double, px: [Float], py: [Float])] = []
    var start = 0
    while start + Spectrum.n <= x.count {
        frames.append((Double(start + Spectrum.n / 2) / sr, spectrum.power(x, at: start), spectrum.power(y, at: start)))
        start += hop
    }

    // Damage to everything that is not the howl.
    func band(_ p: [Float], _ b: Range<Int>) -> Double { p[b].reduce(0) { $0 + Double($1) } }
    let keep = bands.filter { b in howlBins.map { !b.overlaps($0.lowerBound - 6 ..< $0.upperBound + 6) } ?? true }
    let loudest = frames.map { f in keep.map { band(f.px, $0) }.max() ?? 0 }.max() ?? 0
    var losses: [Double] = []
    for f in frames {
        let ex = keep.map { band(f.px, $0) }
        let top = ex.max() ?? 0
        for (i, b) in keep.enumerated() where ex[i] > loudest * 1e-6 && ex[i] > top * 1e-3 {
            losses.append(dB(ex[i]) - dB(band(f.py, b)))
        }
    }
    if !losses.isEmpty {
        losses.sort()
        r.meanLossDb = losses.reduce(0, +) / Double(losses.count)
        r.p95LossDb = losses[min(losses.count - 1, Int(Double(losses.count) * 0.95))]
        r.cutPct = 100 * Double(losses.filter { $0 > 3 }.count) / Double(losses.count)
    }

    // The howl itself.
    if let hb = howlBins, let onset = s.howlOnset {
        let after = frames.filter { $0.t >= onset }
        let lx = after.map { dB(band($0.px, hb)) }, ly = after.map { dB(band($0.py, hb)) }
        let cut = zip(lx, ly).map { $0 - $1 }
        if let i = cut.indices.first(where: { i in i + 5 <= cut.count && cut[i ..< i + 5].allSatisfy { $0 >= 6 } }) {
            r.detectS = after[i].t - onset
        }
        let end = Double(x.count) / sr
        let tail = zip(after, cut).filter { $0.0.t >= end - 1.5 && $0.0.t <= end - 0.5 }.map(\.1).sorted()
        if !tail.isEmpty { r.finalCutDb = tail[tail.count / 2] }
        r.peakDeltaDb = (ly.max() ?? 0) - (lx.max() ?? 0)
    }
    return r
}

func loadStimuli(_ dir: URL) throws -> [(Stimulus, [Float])] {
    let list = try JSONDecoder().decode([Stimulus].self, from: Data(contentsOf: dir.appendingPathComponent("stimuli.json")))
    return try list.map { ($0, try Wav.read(dir.appendingPathComponent("\($0.name).wav")).samples) }
}

/// `calibrate` divides out the level change measured on the sweep, for live recordings through unknown gain.
func analyseRun(_ stimuli: [(Stimulus, [Float])], _ run: URL, calibrate: Bool = false) throws -> [Result] {
    func output(_ name: String) throws -> [Float]? {
        let url = run.appendingPathComponent("\(name).wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let (y, r) = try Wav.read(url)
        guard r == rate else { throw Wav.Failure(description: "\(url.path): \(r) Hz, expected \(rate)") }
        return y
    }
    var gain = 1.0, lag: Int?
    if let (s, x) = stimuli.first(where: { $0.0.kind == .sweep }), let y = try output(s.name) {
        let sweep = analyse(s, x: x, y: y, gain: 1)
        lag = Int((sweep.latencyMs * sr / 1000).rounded())
        if calibrate { gain = db(sweep.levelDb ?? 0) }
    }
    return try stimuli.compactMap { s, x in try output(s.name).map { analyse(s, x: x, y: $0, gain: gain, lag: lag) } }
}

func report(_ runs: [(name: String, results: [Result])]) -> String {
    func cell(_ v: Double?, _ f: String = "%.1f") -> String { v.map { String(format: f, $0) } ?? "—" }
    let head = "| Stimulus | Measure | " + runs.map(\.name).joined(separator: " | ") + " |\n|---|---|" + runs.map { _ in "---|" }.joined() + "\n"
    var rows: [(String, String, (Result) -> String)] = []
    let names = runs.flatMap { $0.results.map(\.stimulus.name) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    for name in names {
        guard let s = runs.lazy.compactMap({ $0.results.first { $0.stimulus.name == name } }).first?.stimulus else { continue }
        switch s.kind {
        case .sweep:
            rows.append((name, "Latency (ms)", { cell($0.latencyMs, "%.2f") }))
            rows.append((name, "Match to input", { cell($0.correlation, "%.3f") }))
            rows.append((name, "Level (dB)", { cell($0.levelDb) }))
        case .howl:
            rows.append((name, "Time to 6 dB cut (s)", { cell($0.detectS, "%.2f") }))
            rows.append((name, "Howl cut at end (dB)", { cell($0.finalCutDb) }))
            rows.append((name, "Howl peak out vs in (dB)", { cell($0.peakDeltaDb) }))
            fallthrough
        case .voice:
            rows.append((name, "Other content lost, mean (dB)", { cell($0.meanLossDb) }))
            rows.append((name, "Other content lost, 95th pct (dB)", { cell($0.p95LossDb) }))
            rows.append((name, "Band-frames cut > 3 dB (%)", { cell($0.cutPct) }))
        }
    }
    var out = head
    for (name, label, f) in rows {
        out += "| \(name) | \(label) | " + runs.map { run in run.results.first { $0.stimulus.name == name }.map(f) ?? "—" }.joined(separator: " | ") + " |\n"
    }
    return out
}
