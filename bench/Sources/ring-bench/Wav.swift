import Foundation

/// Mono 48 kHz WAV in and out. Reads 16/24/32-bit PCM and 32-bit float; keeps channel 1.
enum Wav {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func write(_ url: URL, _ samples: [Float], rate: Int = 48000) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }

    static func read(_ url: URL) throws -> (samples: [Float], rate: Int) {
        let b = [UInt8](try Data(contentsOf: url))
        func le16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func le32(_ o: Int) -> UInt32 { UInt32(le16(o)) | UInt32(le16(o + 2)) << 16 }
        func tag(_ o: Int) -> String { String(bytes: b[o ..< o + 4], encoding: .ascii) ?? "" }
        guard b.count > 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw Failure(description: "\(url.lastPathComponent): not a WAV file") }
        var fmt: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var data: Range<Int>?
        var o = 12
        while o + 8 <= b.count {
            let id = tag(o), n = Int(le32(o + 4)), body = o + 8
            if id == "fmt " {
                var t = Int(le16(body))
                if t == 0xFFFE { t = Int(le16(body + 24)) }
                fmt = (t, Int(le16(body + 2)), Int(le32(body + 4)), Int(le16(body + 14)))
            }
            if id == "data" { data = body ..< min(body + n, b.count) }
            o = body + n + (n & 1)
        }
        guard let fmt, let data else { throw Failure(description: "\(url.lastPathComponent): missing fmt or data chunk") }
        let stride = fmt.channels * fmt.bits / 8
        let count = data.count / stride
        var out = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let p = data.lowerBound + i * stride
            switch (fmt.tag, fmt.bits) {
            case (3, 32): out[i] = Float(bitPattern: le32(p))
            case (1, 16): out[i] = Float(Int16(bitPattern: le16(p))) / 32768
            case (1, 24):
                let v = (Int32(b[p]) | Int32(b[p + 1]) << 8 | Int32(b[p + 2]) << 16) << 8; let s24 = v >> 8
                out[i] = Float(s24) / 8_388_608
            case (1, 32): out[i] = Float(Int32(bitPattern: le32(p))) / 2_147_483_648
            default: throw Failure(description: "\(url.lastPathComponent): unsupported format \(fmt.tag)/\(fmt.bits)-bit")
            }
        }
        return (out, fmt.rate)
    }
}
