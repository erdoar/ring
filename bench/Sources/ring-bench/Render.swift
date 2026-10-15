import AVFoundation
import Foundation
import SI01Core

/// Runs SI-01's engine offline in host-sized blocks. Fits run between blocks, as an ideal worker would.
func renderSI01(_ x: [Float], mode: Mode, block: Int) -> [Float] {
    let engine = Engine(mode: mode)
    var input = x.map(Double.init), output = [Double](repeating: 0, count: x.count)
    var i = 0
    while i < x.count {
        let n = min(block, x.count - i)
        input.withUnsafeMutableBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                engine.render(input: src.baseAddress! + i, output: dst.baseAddress! + i, frames: n)
            }
        }
        if engine.needsFit { engine.performFit() }
        i += n
    }
    return output.map(Float.init)
}

func findEffect(_ name: String) -> [AVAudioUnitComponent] {
    AVAudioUnitComponentManager.shared().components { c, _ in
        let d = c.audioComponentDescription
        let effect = d.componentType == kAudioUnitType_Effect || d.componentType == kAudioUnitType_MusicEffect
        return effect && (name.isEmpty || c.name.localizedCaseInsensitiveContains(name) || c.manufacturerName.localizedCaseInsensitiveContains(name))
    }
}

func instantiate(_ c: AVAudioUnitComponent) throws -> AVAudioUnit {
    let done = DispatchSemaphore(value: 0)
    var unit: AVAudioUnit?, failure: Error?
    AVAudioUnit.instantiate(with: c.audioComponentDescription, options: []) { u, e in unit = u; failure = e; done.signal() }
    done.wait()
    guard let unit else { throw failure ?? Wav.Failure(description: "Could not load \(c.name)") }
    return unit
}

/// Renders through an Audio Unit plug-in offline, in `block`-frame calls, feeding the same signal to both channels.
final class PluginRenderer {
    let unit: AVAudioUnit
    let block: Int
    let tail = Int(0.3 * sr)

    init(_ component: AVAudioUnitComponent, block: Int) throws {
        unit = try instantiate(component)
        self.block = block
    }

    func render(_ x: [Float]) throws -> [Float] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(block))
        engine.attach(player); engine.attach(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        unit.auAudioUnit.reset()
        try engine.start()
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count + tail))!
        input.frameLength = input.frameCapacity
        for ch in 0 ..< 2 {
            let p = input.floatChannelData![ch]
            for i in 0 ..< Int(input.frameLength) { p[i] = i < x.count ? x[i] : 0 }
        }
        player.scheduleBuffer(input)
        player.play()
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(block))!
        var out: [Float] = []
        out.reserveCapacity(x.count + tail)
        while out.count < x.count + tail {
            let n = AVAudioFrameCount(min(block, x.count + tail - out.count))
            guard try engine.renderOffline(n, to: chunk) == .success else { throw Wav.Failure(description: "\(unit.name) stopped rendering") }
            out.append(contentsOf: UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength)))
        }
        player.stop(); engine.stop()
        engine.detach(unit)
        return out
    }
}

/// Plays each stimulus on the default output and records the default input, for hardware or console inserts.
func recordLive(_ x: [Float], to url: URL) throws {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    let inFormat = engine.inputNode.outputFormat(forBus: 0)
    guard inFormat.sampleRate == sr else { throw Wav.Failure(description: "Input device runs at \(inFormat.sampleRate) Hz; set it to 48 kHz") }
    let lock = NSLock()
    var recorded: [Float] = []
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buf, _ in
        lock.lock(); recorded.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))); lock.unlock()
    }
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count))!
    buf.frameLength = buf.frameCapacity
    for i in x.indices { buf.floatChannelData![0][i] = x[i] }
    try engine.start()
    player.scheduleBuffer(buf)
    player.play()
    Thread.sleep(forTimeInterval: Double(x.count) / sr + 0.5)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.lock(); defer { lock.unlock() }
    try Wav.write(url, recorded)
}

/// Known processors for the self-test: a plain delay and gain, and an ideal notch that engages 0.3 s after onset.
func simulate(_ s: Stimulus, _ x: [Float], delay: Int, gainDb: Double, notchAfter: Double?) -> [Float] {
    var notch = s.howlHz.map { Biquad.notch($0, q: 8) }
    let switchAt = (s.howlOnset ?? 0) + (notchAfter ?? 0)
    var y = [Float](repeating: 0, count: x.count + delay)
    for i in x.indices {
        var v = Double(x[i])
        if notchAfter != nil, var n = notch {
            let filtered = n.run(v)
            notch = n
            if Double(i) / sr >= switchAt { v = filtered }
        }
        y[i + delay] = Float(v * db(gainDb))
    }
    return y
}
