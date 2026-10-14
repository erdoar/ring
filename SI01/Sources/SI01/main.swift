import Foundation
import SI01Core

@main
enum SI01Main {
    static func main() throws {
        let app = App()
        if CommandLine.arguments.contains("--check") {
            try app.setChannels(1)
            app.start()
            var input: [Float] = [0, 0, 0, 0]
            var output: [Float] = [1, 1, 1, 1]
            try input.withUnsafeMutableBufferPointer { source in
                try output.withUnsafeMutableBufferPointer { dest in
                    try app.processBlock(
                        input: source.baseAddress!,
                        output: dest.baseAddress!,
                        frames: 4,
                        channel: 0
                    )
                }
            }
            guard output == input, let frame = app.snapshot() else {
                fputs("check failed\n", stderr)
                exit(1)
            }
            print(frame)
            return
        }
        fputs("SI-01 runs on macOS. Pass --check to exercise the session.\n", stderr)
    }
}
