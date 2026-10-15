import Foundation
import SI01Core

let usage = """
ring-bench: black-box comparison of feedback suppressors on the same test signals.

  ring-bench generate <stimuli-dir>
  ring-bench render si01 <stimuli-dir> <out-dir> [--low] [--block N]
  ring-bench render au <plug-in name> <stimuli-dir> <out-dir> [--block N]
  ring-bench record <stimuli-dir> <out-dir>
  ring-bench analyse <stimuli-dir> <run-dir>... [--out report.md] [--calibrate]
  ring-bench plugins [filter]
  ring-bench selftest
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i ... i + 1) }
    return args[i + 1]
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func dir(_ path: String, create: Bool = false) -> URL {
    let url = URL(fileURLWithPath: path)
    if create { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    return url
}

func generate(_ out: URL) throws {
    let all = makeStimuli()
    for (s, x) in all { try Wav.write(out.appendingPathComponent("\(s.name).wav"), x.map(Float.init)) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(all.map(\.0)).write(to: out.appendingPathComponent("stimuli.json"))
}

var quiet = false
func renderAll(_ stimuli: URL, _ out: URL, _ process: (Stimulus, [Float]) throws -> [Float]) throws {
    for (s, x) in try loadStimuli(stimuli) {
        if !quiet { print("  \(s.name)") }
        try Wav.write(out.appendingPathComponent("\(s.name).wav"), try process(s, x))
    }
}

func selftest() throws {
    quiet = true
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ring-bench-\(getpid())")
    defer { try? FileManager.default.removeItem(at: root) }
    let stim = dir(root.appendingPathComponent("stimuli").path, create: true)
    try generate(stim)
    let runs: [(String, Int, Double, Double?)] = [("bypass", 37, -3, nil), ("notch", 64, 0, 0.3)]
    var results: [(name: String, results: [Result])] = []
    for (name, delay, gain, after) in runs {
        let out = dir(root.appendingPathComponent(name).path, create: true)
        try renderAll(stim, out) { s, x in simulate(s, x, delay: delay, gainDb: gain, notchAfter: after) }
        results.append((name, try analyseRun(try loadStimuli(stim), out, calibrate: true)))
    }
    print(report(results))
    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }
    let bypass = results[0].results, notch = results[1].results
    func r(_ rs: [Result], _ n: String) -> Result { rs.first { $0.stimulus.name == n }! }
    check(abs(r(bypass, "sweep").latencyMs - 37 / 48) < 0.03, "bypass latency should be 37 samples")
    check(abs((r(bypass, "sweep").levelDb ?? 0) + 3) < 0.2, "bypass level should be -3 dB")
    check(bypass.allSatisfy { $0.detectS == nil }, "bypass should never cut a howl")
    check(bypass.allSatisfy { abs($0.p95LossDb) < 0.5 }, "bypass should not damage anything")
    check(abs((r(notch, "howl-2k5").detectS ?? 9) - 0.3) < 0.1, "notch should cut 2.5 kHz about 0.3 s after onset")
    check((r(notch, "howl-2k5").finalCutDb ?? 0) > 20, "notch should cut the 2.5 kHz howl by more than 20 dB")
    check(abs(r(notch, "vibrato-note").p95LossDb) < 0.5, "notch should leave the vibrato note alone")
    if problems.isEmpty { print("selftest passed") } else { fail("selftest failed:\n- " + problems.joined(separator: "\n- ")) }
}

do {
    guard let command = args.first else { fail(usage) }
    args.removeFirst()
    switch command {
    case "generate":
        guard args.count == 1 else { fail(usage) }
        try generate(dir(args[0], create: true))
        print("Wrote \(makeStimuli().count) stimuli to \(args[0])")
    case "render":
        let block = option("--block").flatMap(Int.init) ?? 256
        let low = flag("--low")
        guard let engine = args.first else { fail(usage) }
        if engine == "si01", args.count == 3 {
            print("SI-01 (\(low ? "low" : "zero") mode, \(block)-frame blocks)")
            try renderAll(dir(args[1]), dir(args[2], create: true)) { _, x in renderSI01(x, mode: low ? .low : .zero, block: block) }
        } else if engine == "au", args.count == 4 {
            let found = findEffect(args[1])
            guard let c = found.first else { fail("No Audio Unit effect matches \"\(args[1])\". Run `ring-bench plugins` to list them.") }
            let plugin = try PluginRenderer(c, block: block)
            print("\(c.manufacturerName) \(c.name) \(c.versionString), reports \(Int(plugin.unit.auAudioUnit.latency * sr)) samples latency, \(block)-frame blocks")
            try renderAll(dir(args[2]), dir(args[3], create: true)) { _, x in try plugin.render(x) }
        } else { fail(usage) }
    case "record":
        guard args.count == 2 else { fail(usage) }
        print("Playing on the default output and recording the default input")
        try renderAll(dir(args[0]), dir(args[1], create: true)) { s, x in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ring-bench-\(s.name).wav")
            try recordLive(x, to: tmp)
            return try Wav.read(tmp).samples
        }
    case "analyse", "analyze":
        let out = option("--out")
        let calibrate = flag("--calibrate")
        guard args.count >= 2 else { fail(usage) }
        let stimuli = try loadStimuli(dir(args[0]))
        let runs = try args.dropFirst().map { path in (URL(fileURLWithPath: path).lastPathComponent, try analyseRun(stimuli, dir(path), calibrate: calibrate)) }
        let text = report(runs)
        print(text)
        if let out { try text.write(toFile: out, atomically: true, encoding: .utf8) }
    case "plugins":
        for c in findEffect(args.first ?? "") { print("\(c.manufacturerName) — \(c.name) \(c.versionString)") }
    case "selftest":
        try selftest()
    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
