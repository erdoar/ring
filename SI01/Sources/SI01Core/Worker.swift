import Foundation

/// Drains gate/howl analysis and tail fits off the audio callback. The callback never waits for this worker.
final class FitWorker {
    private var engines: [Engine] = []
    private let stateLock = NSLock()
    private var running = false
    private var thread: Thread?
    private var finished: DispatchSemaphore?

    func bind(_ engines: [Engine]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        precondition(thread == nil, "Cannot replace engines while the worker is running")
        self.engines = engines
    }

    func start() {
        stateLock.lock()
        guard thread == nil else {
            stateLock.unlock()
            return
        }
        running = true
        let completion = DispatchSemaphore(value: 0)
        finished = completion
        let worker = Thread { [weak self] in
            guard let self else {
                completion.signal()
                return
            }
            while self.shouldRun {
                var worked = false
                for engine in self.engines {
                    if engine.needsAnalysis {
                        engine.performAnalysis()
                        worked = true
                    }
                    if engine.needsFit {
                        engine.performFit()
                        worked = true
                    }
                }
                if !worked { Thread.sleep(forTimeInterval: 0.0005) }
            }
            completion.signal()
        }
        worker.name = "SI01 analysis"
        thread = worker
        worker.start()
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        guard thread != nil else {
            stateLock.unlock()
            return
        }
        running = false
        let completion = finished
        stateLock.unlock()

        // Joining here is safe: stop is called by the control thread, never the audio callback.
        completion?.wait()
        for engine in engines {
            engine.performAnalysis()
            engine.performFit()
        }

        stateLock.lock()
        thread = nil
        finished = nil
        stateLock.unlock()
    }

    private var shouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }
}
