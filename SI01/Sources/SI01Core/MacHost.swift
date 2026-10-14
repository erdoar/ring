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
        let created = AudioDeviceCreateIOProcID(device, { _, _, input, _, output, _, _, context in
            guard let context, let output, let input else { return noErr }
            let host = Unmanaged<CoreAudioHost>.fromOpaque(context).takeUnretainedValue()
            let frames = Int(input.pointee.mNumberBuffers > 0 ? input.pointee.mBuffers.mDataByteSize / 4 : 0)
            host.render(input: input, output: output, frames: frames)
            return noErr
        }, opaque, &proc)
        if created != noErr { throw SessionError.block }
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let channels = min(app.session.channels, inList.count, outList.count)
        for channel in 0 ..< channels {
            guard let src = inList[channel].mData?.assumingMemoryBound(to: Float.self),
                  let dst = outList[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
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
}
#endif
