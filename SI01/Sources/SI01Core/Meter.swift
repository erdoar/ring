import Foundation

public enum MeterLink {
    public static let framesPerSecond = 2
}

public struct Meter {
    public static let maxChannels = 8
    private var likelihood = [Float](repeating: 0, count: maxChannels)
    private var cutDb = [Float](repeating: 0, count: maxChannels)
    private var channelCount = 1
    private var delay = 0
    private var mode = Mode.zero
    private var missed: UInt32 = 0
    private var overrun: UInt32 = 0
    private var seq: UInt32 = 0
    private var published: UInt32 = 0
    private var pressure = "normal"
    private var thermal = "nominal"

    public init() {}

    public var isOpen: Bool { seq & 1 == 1 }

    /// Callback only. The arrays already exist. This does not send.
    public mutating func note(
        channel: Int,
        channels: Int,
        delay: Int,
        mode: Mode,
        likelihood: Float,
        cutDb: Float,
        missedAdd: UInt32 = 0,
        overrunAdd: UInt32 = 0
    ) {
        seq &+= 1
        channelCount = min(Self.maxChannels, max(1, channels))
        self.delay = delay
        self.mode = mode
        if channel >= 0 && channel < Self.maxChannels {
            self.likelihood[channel] = likelihood
            self.cutDb[channel] = cutDb
        }
        missed &+= missedAdd
        overrun &+= overrunAdd
        published &+= 1
        seq &+= 1
    }

    public mutating func setMachine(pressure: String, thermal: String) {
        seq &+= 1
        self.pressure = pressure
        self.thermal = thermal
        seq &+= 1
    }

    /// Leaves the counter odd. The sender must not read through this.
    public mutating func openForTest() { seq &+= 1 }

    public mutating func closeForTest() { seq &+= 1 }

    public func frame() -> String? {
        if seq & 1 == 1 { return nil }
        var likes = "["
        var cuts = "["
        for index in 0 ..< channelCount {
            if index > 0 {
                likes += ","
                cuts += ","
            }
            likes += format(likelihood[index])
            cuts += format(cutDb[index])
        }
        likes += "]"
        cuts += "]"
        return "{\"seq\":\(published),\"channels\":\(channelCount),\"delay\":\(delay),\"mode\":\"\(mode.rawValue)\",\"likelihood\":\(likes),\"cutDb\":\(cuts),\"missed\":\(missed),\"overrun\":\(overrun),\"pressure\":\"\(pressure)\",\"thermal\":\"\(thermal)\"}"
    }

    public var containsSamples: Bool { false }

    /// Call only after the frame has left the machine.
    public mutating func didSend() {
        if seq & 1 == 1 { return }
        missed = 0
        overrun = 0
    }

    private func format(_ value: Float) -> String {
        if value == 0 { return "0" }
        var text = String(format: "%.2f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) {
            text.removeLast()
        }
        return text
    }
}
