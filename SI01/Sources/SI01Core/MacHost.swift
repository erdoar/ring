import Foundation

/// What the stream is allowed to ask of the device. It does not hunt for a larger buffer.
public struct DeviceRequest: Equatable {
    public var sampleRate: Double
    public var frames: Int
    public var channels: Int

    public init(sampleRate: Double = 48000, frames: Int = 32, channels: Int = 1) {
        self.sampleRate = sampleRate
        self.frames = frames
        self.channels = channels
    }

    public var legal: Bool {
        sampleRate == 48000 && frames == 32 && (1 ... 8).contains(channels)
    }
}

#if os(macOS)
import AudioToolbox
import CoreAudio
import Darwin

/// Opens one USB input device. The IO proc calls `App.processBlock` and nothing else.
public final class CoreAudioHost {
    private var device: AudioDeviceID = 0
    private var proc: AudioDeviceIOProcID?
    private let app: App
    public let request: DeviceRequest

    public init(app: App, request: DeviceRequest) {
        self.app = app
        self.request = request
    }

    public func open(device: AudioDeviceID) throws {
        guard request.legal else { throw SessionError.block }
        self.device = device
        var frames = UInt32(request.frames)
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &frames)
        if status != noErr { throw SessionError.block }
        var got = frames
        var gotSize = size
        AudioObjectGetPropertyData(device, &address, 0, nil, &gotSize, &got)
        if got != frames { throw SessionError.block }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let created = AudioDeviceCreateIOProcID(device, { _, _, input, _, output, _, context in
            guard let context, let output, let input else { return noErr }
            let host = Unmanaged<CoreAudioHost>.fromOpaque(context).takeUnretainedValue()
            host.render(input: input, output: output)
            return noErr
        }, opaque, &proc)
        if created != noErr { throw SessionError.block }
    }

    private var planeIn = [Float](repeating: 0, count: MAX_BLOCK)
    private var planeOut = [Float](repeating: 0, count: MAX_BLOCK)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard inList.count > 0, outList.count > 0 else { return }
        if inList.count == 1 && inList[0].mNumberChannels > 1 {
            let stride = Int(inList[0].mNumberChannels)
            let frames = min(MAX_BLOCK, Int(inList[0].mDataByteSize) / (4 * max(1, stride)))
            guard let src = inList[0].mData?.assumingMemoryBound(to: Float.self),
                  let dst = outList[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = min(app.session.channels, stride)
            for channel in 0 ..< channels {
                for i in 0 ..< frames { planeIn[i] = src[i * stride + channel] }
                planeIn.withUnsafeBufferPointer { source in
                    planeOut.withUnsafeMutableBufferPointer { dest in
                        try? app.processBlock(input: source.baseAddress!, output: dest.baseAddress!, frames: frames, channel: channel)
                    }
                }
                for i in 0 ..< frames { dst[i * stride + channel] = planeOut[i] }
            }
            return
        }
        let channels = min(app.session.channels, inList.count, outList.count)
        for channel in 0 ..< channels {
            guard let src = inList[channel].mData?.assumingMemoryBound(to: Float.self),
                  let dst = outList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(MAX_BLOCK, Int(inList[channel].mDataByteSize) / 4)
            try? app.processBlock(input: src, output: dst, frames: frames, channel: channel)
        }
    }

    public func start() throws {
        guard let proc else { throw SessionError.whileStopped }
        app.start()
        if AudioDeviceStart(device, proc) != noErr {
            app.stop()
            throw SessionError.block
        }
    }

    public func stop() {
        if let proc { AudioDeviceStop(device, proc) }
        app.stop()
    }

    /// Default input, 48 kHz, 32 frames. Returns when the process is signalled.
    public static func runDefault(channels: Int) throws {
        var device = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let read = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        if read != noErr || device == 0 { throw SessionError.block }
        let app = App()
        try app.setChannels(channels)
        let host = CoreAudioHost(app: app, request: DeviceRequest(channels: channels))
        try host.open(device: device)
        try host.start()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            host.stop()
            exit(0)
        }
        source.resume()
        dispatchMain()
    }
}
#endif
