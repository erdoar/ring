public enum Mode: String, Equatable {
    case zero
    case low

    public var delaySamples: Int { self == .low ? 127 : 0 }
}

public enum SessionError: Error, Equatable {
    case whileRunning
    case whileStopped
    case channelCount
    case block
}

public struct Session: Equatable {
    public private(set) var channels: Int
    public private(set) var mode: Mode
    public private(set) var running: Bool
    public let ioBuffer: Int

    public init(channels: Int = 1, mode: Mode = .zero, ioBuffer: Int = 32) {
        self.channels = min(8, max(1, channels))
        self.mode = mode
        self.running = false
        self.ioBuffer = ioBuffer
    }

    public var delaySamples: Int { mode.delaySamples }

    public mutating func setChannels(_ count: Int) throws {
        if running { throw SessionError.whileRunning }
        guard (1 ... 8).contains(count) else { throw SessionError.channelCount }
        channels = count
    }

    public mutating func setMode(_ next: Mode) throws {
        if running { throw SessionError.whileRunning }
        mode = next
    }

    public mutating func start() {
        running = true
    }

    public mutating func stop() {
        running = false
    }
}

public struct QuitList: Equatable {
    public static let never = ["WindowServer", "coreaudiod", "loginwindow", "Finder"]
    public var names: [String]
    public var onOpen: Bool
    public var atLogin: Bool

    public init(names: [String] = [], onOpen: Bool = false, atLogin: Bool = false) {
        self.names = names
        self.onOpen = onOpen
        self.atLogin = atLogin
    }

    public func askable() -> [String] {
        var seen: [String] = []
        for name in names where !name.isEmpty && !Self.never.contains(name) && !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    /// The login item starts this process. It does not carry a quit list.
    public func afterOpen() -> [String] {
        onOpen ? askable() : []
    }
}
