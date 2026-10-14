public final class App {
    public private(set) var session: Session
    public var quits: QuitList
    private var meter = Meter()

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
    }

    public func stop() {
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
        if frames <= 0 { throw SessionError.block }
        output.update(from: input, count: frames)
        meter.note(
            channel: channel,
            channels: session.channels,
            delay: session.delaySamples,
            mode: session.mode,
            likelihood: 0,
            cutDb: 0
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
