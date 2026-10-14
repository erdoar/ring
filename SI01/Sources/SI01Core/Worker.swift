import Foundation

/// Drains tail fits. The callback only posts the job.
final class FitWorker {
    private var engines: [Engine] = []
    private var running = false
    private var thread: Thread?

    func bind(_ engines: [Engine]) {
        self.engines = engines
    }

    func start() {
        guard thread == nil else { return }
        running = true
        let thread = Thread { [weak self] in
            while let self, self.running {
                var worked = false
                for engine in self.engines where engine.needsFit {
                    engine.performFit()
                    worked = true
                }
                if !worked { Thread.sleep(forTimeInterval: 0.0005) }
            }
        }
        thread.name = "SI01 fit"
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        for engine in engines { engine.performFit() }
        thread = nil
    }
}
