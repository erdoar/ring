public final class App {
    public private(set) var session: Session
    public var quits: QuitList
    private var meter = Meter()
    private var engines: [Engine] = []
    private let worker = FitWorker()
    private var scratchIn = [Double](repeating: 0, count: MAX_BLOCK)
    private var scratchOut = [Double](repeating: 0, count: MAX_BLOCK)

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
        scratchIn.withUnsafeMutableBufferPointer { source in
            scratchOut.withUnsafeMutableBufferPointer { dest in
                for i in 0 ..< frames { source[i] = Double(input[i]) }
                engine.render(input: source.baseAddress!, output: dest.baseAddress!, frames: frames)
                for i in 0 ..< frames { output[i] = Float(dest[i]) }
            }
        }
        meter.note(
            channel: channel,
            channels: session.channels,
            delay: session.delaySamples,
            mode: session.mode,
            likelihood: Float(engine.likelihood),
            cutDb: Float(engine.subtractionDb())
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
