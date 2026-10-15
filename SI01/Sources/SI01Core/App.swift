import Darwin
import Foundation

public final class App {
    public private(set) var session: Session
    public var quits: QuitList
    private var meter = Meter()
    private var engines: [Engine] = []
    private let worker = FitWorker()
    private var scratchIn = [Double](repeating: 0, count: MAX_BLOCK)
    private var scratchOut = [Double](repeating: 0, count: MAX_BLOCK)
    private var trimGain = [Float](repeating: 1, count: 8)
    private var trimDecibels = [Float](repeating: 0, count: 8)
    private var inputMix = [Float](repeating: 1, count: 8)
    private var inputMuted = [UInt8](repeating: 0, count: 8)

    public init(session: Session = Session(), quits: QuitList = QuitList()) {
        self.session = session
        self.quits = quits
    }

    public func setChannels(_ count: Int) throws {
        try session.setChannels(count)
    }

    public func setMode(_ mode: Mode) throws {
        try session.setMode(mode)
    }

    public func start() {
        session.start()
        engines = (0 ..< session.channels).map { _ in
            let engine = Engine(mode: session.mode)
            engine.fitMode = .worker
            return engine
        }
        worker.bind(engines)
        worker.start()
    }

    public func stop() {
        worker.stop()
        engines = []
        session.stop()
    }

    public var delaySamples: Int { session.delaySamples }

    public var asksAfterOpen: [String] { quits.afterOpen() }

    public func setTrim(channel: Int, db: Double) {
        guard channel >= 0, channel < trimGain.count else { return }
        let clamped = Float(min(8, max(-8, db)))
        trimDecibels[channel] = clamped
        trimGain[channel] = clamped == 0 ? 1 : Float(pow(10, Double(clamped) / 20))
    }

    public func trimDb(channel: Int) -> Double {
        guard channel >= 0, channel < trimDecibels.count else { return 0 }
        return Double(trimDecibels[channel])
    }

    public func setMix(channel: Int, mix: Double) {
        guard channel >= 0, channel < inputMix.count else { return }
        inputMix[channel] = Float(min(1, max(0, mix)))
    }

    public func mix(channel: Int) -> Double {
        guard channel >= 0, channel < inputMix.count else { return 1 }
        return Double(inputMix[channel])
    }

    public func setMuted(channel: Int, muted: Bool) {
        guard channel >= 0, channel < inputMuted.count else { return }
        inputMuted[channel] = muted ? 1 : 0
    }

    public func isMuted(channel: Int) -> Bool {
        guard channel >= 0, channel < inputMuted.count else { return false }
        return inputMuted[channel] != 0
    }

    /// Test seam with the same rule as the callback: copy, then note. No send.
    public func processBlock(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        channel: Int
    ) throws {
        if !session.running { throw SessionError.whileStopped }
        if channel < 0 || channel >= session.channels { throw SessionError.channelCount }
        if frames < 1 || frames > MAX_BLOCK { throw SessionError.block }
        let engine = engines[channel]
        let mix = Double(inputMix[channel])
        let muted = inputMuted[channel] != 0
        let gain = Double(trimGain[channel])
        var peak: Float = 0
        if muted || mix < 0.0005 {
            for i in 0 ..< frames {
                let sample = input[i]
                let magnitude = sample < 0 ? -sample : sample
                if magnitude > peak { peak = magnitude }
                output[i] = muted ? 0 : sample
            }
        } else {
            scratchIn.withUnsafeMutableBufferPointer { source in
                scratchOut.withUnsafeMutableBufferPointer { dest in
                    for i in 0 ..< frames {
                        let sample = input[i]
                        let magnitude = sample < 0 ? -sample : sample
                        if magnitude > peak { peak = magnitude }
                        source[i] = Double(sample) * gain
                    }
                    engine.render(input: source.baseAddress!, output: dest.baseAddress!, frames: frames)
                    let wetMix = Float(mix)
                    let dryMix = Float(1 - mix)
                    for i in 0 ..< frames {
                        let wet = Float(dest[i])
                        output[i] = mix > 0.9995 ? wet : input[i] * dryMix + wet * wetMix
                    }
                }
            }
        }
        let inputDb: Float = peak < 1e-6 ? -120 : Float(20 * log10(Double(peak)))
        meter.note(
            channel: channel,
            channels: session.channels,
            delay: session.delaySamples,
            mode: session.mode,
            likelihood: Float(engine.likelihood),
            cutDb: Float(engine.subtractionDb()),
            inputDb: inputDb
        )
    }

    public func noteFault(missed: UInt32 = 0, overrun: UInt32 = 0) {
        meter.note(
            channel: 0,
            channels: session.channels,
            delay: session.delaySamples,
            mode: session.mode,
            likelihood: 0,
            cutDb: 0,
            missedAdd: missed,
            overrunAdd: overrun
        )
    }

    public func snapshot() -> String? { meter.frame() }

    public func didSendSnapshot() { meter.didSend() }

    public func holdSnapshotOpen() { meter.openForTest() }

    public func releaseSnapshot() { meter.closeForTest() }
}
