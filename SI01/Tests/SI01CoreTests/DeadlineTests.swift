import XCTest
@testable import SI01Core

/// Times the real render path for a full eight-channel insert against the host-block deadline.
final class DeadlineTests: XCTestCase {
    func testEightEnginesMeetTheCallbackDeadline() throws {
        #if DEBUG
        throw XCTSkip("Callback timing is only meaningful in release builds: swift test -c release")
        #else
        let sr = 48000.0
        let seconds = 2.0
        let count = Int(seconds * sr)
        var signal = [Double](repeating: 0, count: count)
        var phase = 0.0
        for i in 0 ..< count {
            let t = Double(i) / sr
            phase += (2 * Double.pi * 196) / sr
            var voice = 0.0
            for h in 1 ... 8 { voice += sin(Double(h) * phase) / Double(h) }
            let howl = min(0.5, 0.01 * pow(10, t * 1.3)) * sin(2 * Double.pi * 1000 * t)
            signal[i] = 0.2 * voice + howl
        }

        for block in [32, 128] {
            let deadline = Double(block) / sr * 1e9
            let engines = (0 ..< 8).map { _ -> Engine in
                let engine = Engine(sr: sr)
                engine.fitMode = .worker
                return engine
            }
            let worker = FitWorker()
            worker.bind(engines)
            worker.start()
            var output = [Double](repeating: 0, count: block)
            var worst = 0.0
            var total = 0.0
            var blocks = 0
            var i = 0
            signal.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    while i + block <= count {
                        let start = DispatchTime.now().uptimeNanoseconds
                        for engine in engines {
                            engine.render(input: src.baseAddress! + i, output: dst.baseAddress!, frames: block)
                        }
                        let took = Double(DispatchTime.now().uptimeNanoseconds - start)
                        // The first half second warms caches and fills the gate window; time the rest.
                        if i >= Int(sr) / 2 {
                            worst = max(worst, took)
                            total += took
                            blocks += 1
                        }
                        i += block
                    }
                }
            }
            worker.stop()
            let analysed = engines.filter { $0.likelihood > 0 || $0.howlHz.contains { $0 > 0 } }.count
            print(String(format: "8 engines, %d-frame block: worst %.1f us, mean %.1f us, deadline %.1f us",
                         block, worst / 1000, total / Double(max(1, blocks)) / 1000, deadline / 1000))
            XCTAssertEqual(analysed, engines.count, "worker analysis never reached the callback")
            XCTAssertLessThan(worst, deadline, "worst-case callback for \(block) frames missed the deadline")
        }
        #endif
    }
}
