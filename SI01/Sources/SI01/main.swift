import Foundation
import SI01Core

@main
enum SI01Main {
    static func main() throws {
        if CommandLine.arguments.contains("--self-test") {
            var failed = 0
            for check in kernelChecks() {
                print("\(check.pass ? "pass" : "fail")  \(check.name)  \(check.detail)")
                if !check.pass { failed += 1 }
            }
            if failed > 0 { exit(1) }
            return
        }
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
            app.stop()
            return
        }
        fputs("Ring 0.6.2 runs on macOS. --check exercises the session. --self-test runs the kernel.\n", stderr)
        #if os(macOS)
        try InsertLaunch.run()
        #endif
    }
}
