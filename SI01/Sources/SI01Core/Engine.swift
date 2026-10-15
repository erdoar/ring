import Foundation
import KernelStore

public enum FitMode {
    /// Same sample timing as the note. Used by the kernel tests.
    case inline
    /// The callback only copies a job. Another thread calls `performFit()`.
    case worker
}

private let histSize = 8192
private let histMask = histSize - 1
private let trackMem = 40
private let jobSize = MAX_BLOCK + HORIZON + TAIL_TAPS + PART
/// Feature snapshot: epoch, sequence, likelihood, voice hold, confirmed, then hz, gain, b0, b1, b2, a1, a2 per howl.
private let featureHead = 5
private let featurePerHowl = 7
private let featureCount = featureHead + HOWLS * featurePerHowl

private struct Coeff {
    var b0: Double = 0
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
}

private func bandpass(hz: Double, sr: Double, q: Double = 40) -> Coeff {
    let w0 = (2 * Double.pi * min(hz, sr * 0.45)) / sr
    let alpha = sin(w0) / (2 * q)
    let a0 = 1 + alpha
    return Coeff(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: (-2 * cos(w0)) / a0, a2: (1 - alpha) / a0)
}

private struct Ring {
    var values = [Double](repeating: 0, count: trackMem)
    var count = 0
    var start = 0

    mutating func removeAll() {
        count = 0
        start = 0
    }

    mutating func push(_ value: Double) {
        if count < trackMem {
            values[count] = value
            count += 1
        } else {
            values[start] = value
            start = (start + 1) % trackMem
        }
    }

    func at(_ index: Int) -> Double {
        if count < trackMem { return values[index] }
        return values[(start + index) % trackMem]
    }

    var oldest: Double { at(0) }
    var newest: Double { at(count - 1) }
}

/// Detector state. Owned by whichever thread runs `performAnalysis()`.
private struct Track {
    var hz: Double = 0
    var gain: Double = 1
    var mags = Ring()
    var freqs = Ring()
    var age = 0
    var coeff = Coeff()

    mutating func reset() {
        hz = 0
        gain = 1
        mags.removeAll()
        freqs.removeAll()
        age = 0
    }
}

/// Subtraction filter. Owned by the callback.
private struct Notch {
    var hz: Double = 0
    var gain: Double = 1
    var coeff = Coeff()
    var x1 = 0.0
    var x2 = 0.0
    var y1 = 0.0
    var y2 = 0.0

    mutating func clearFilterState() {
        y1 = 0
        y2 = 0
        x1 = 0
        x2 = 0
    }
}

public final class Engine {
    public var bypass = false
    public var mode: Mode
    public var strength = 0.5
    public var dereverb = 0.35
    public var freeze = false
    public let sr: Double
    public var likelihood = 0.0
    public var missedPublish = 0
    public var crossfades = 0
    public var confirmedHowls = 0
    public var workerEnabled = true
    public var minInputAgo = 0
    public private(set) var lastTailHorizon = HORIZON
    /// Also decides where gate and howl analysis run: `.inline` on the callback (tests), `.worker` on `performAnalysis()`.
    public var fitMode: FitMode = .inline
    /// Partitions whose analysis frame was dropped because the worker still owned the previous one. Callback-owned.
    public private(set) var missedAnalysis = 0
    /// Feature snapshots the worker could not publish. Worker-owned.
    public private(set) var missedFeatures = 0

    public var tail: [Double]
    public var howlGain: [Double]
    public var howlHz: [Double]
    public var bleed: [Double]
    private let kernelStore: OpaquePointer?
    private let jobState: OpaquePointer?
    private let analysisState: OpaquePointer?
    private let featureStore: OpaquePointer?

    // Worker-side analysis state.
    private let analyzer = Analyzer(count: GATE_WINDOW)
    private var frame = [Double](repeating: 0, count: GATE_WINDOW)
    private var tracks: [Track]
    private var workerEpoch = 0
    private var workerHold = 0
    private var workerSeq = 0
    private var features = [Double](repeating: 0, count: featureCount)

    // Analysis hand-off, written by the callback under `analysisState`.
    private let analysisFrame: UnsafeMutablePointer<Double>
    private var analysisEpoch = 0
    private var analysisSkipHowl = false

    // Callback state. `hist` mirrors each sample at i and i + histSize so any window is contiguous.
    private let hist: UnsafeMutablePointer<Double>
    private var notches: [Notch]
    private var epoch = 0
    private var appliedSeq = 0
    private var histI = 0
    private var seen = 0
    private var hostBlock = 0
    private var fifo = 0
    private var holdSamples = 0
    private var fadeLeft = 0
    private var fadeLen = 1
    private var bypassMix = 1.0
    private var bypassTarget = 1.0
    private var slotDry = [Double](repeating: 0, count: 127)
    private var slotTail = [Double](repeating: 0, count: 127)
    private var slotHowl = [Double](repeating: 0, count: 127)
    private var delayI = 0
    private var tailEnergy = 0.0
    private var outEnergy = 0.0
    private var meterN = 0
    private var xbuf = [Double](repeating: 0, count: TAIL_TAPS)
    private var gbuf = [Double](repeating: 0, count: TAIL_TAPS)
    private var voiceHold = 0
    private var gateReady = false
    private var job = [Double](repeating: 0, count: jobSize)
    private var jobFrozen = false
    private var jobHorizon = HORIZON
    private var usedPeak = [Bool](repeating: false, count: 8)
    private var claimed = [Bool](repeating: false, count: BANDS)
    public var needsFit: Bool { si01_job_is_pending(jobState) }
    public var needsAnalysis: Bool { si01_job_is_pending(analysisState) }

    public init(mode: Mode = .zero, sr: Double = SR) {
        self.mode = mode
        self.sr = sr
        kernelStore = si01_kernel_store_create(TAIL_TAPS)
        jobState = si01_job_state_create()
        analysisState = si01_job_state_create()
        featureStore = si01_kernel_store_create(featureCount)
        analysisFrame = .allocate(capacity: GATE_WINDOW)
        analysisFrame.initialize(repeating: 0, count: GATE_WINDOW)
        hist = .allocate(capacity: 2 * histSize)
        hist.initialize(repeating: 0, count: 2 * histSize)
        notches = [Notch](repeating: Notch(), count: HOWLS)
        tail = [Double](repeating: 0, count: TAIL_TAPS)
        howlGain = [Double](repeating: 1, count: HOWLS)
        howlHz = [Double](repeating: 0, count: HOWLS)
        bleed = [Double](repeating: 1, count: BANDS)
        tracks = [Track](repeating: Track(), count: HOWLS)
    }

    deinit {
        si01_kernel_store_destroy(kernelStore)
        si01_job_state_destroy(jobState)
        si01_job_state_destroy(analysisState)
        si01_kernel_store_destroy(featureStore)
        analysisFrame.deallocate()
        hist.deallocate()
    }

    /// Deterministic test seam for checking the subtraction cap.
    public func setTailForTesting(_ taps: [Double]) {
        guard taps.count == TAIL_TAPS else { return }
        tail = taps
        let ok = taps.withUnsafeBufferPointer {
            si01_kernel_publish(kernelStore, $0.baseAddress, $0.count)
        }
        if !ok { missedPublish += 1 }
    }

    public var latency: Int { mode.delaySamples }

    public func subtractionDb() -> Double {
        if outEnergy < 1e-12 { return -120 }
        return 10 * log10((tailEnergy + 1e-18) / outEnergy)
    }

    public var horizonHeld: Bool { minInputAgo >= HORIZON }

    public func render(input: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>, frames: Int) {
        if frames < 1 || frames > MAX_BLOCK { return }
        let activeKernel = si01_kernel_read_begin(kernelStore)
        defer { si01_kernel_read_end(kernelStore) }
        lastTailHorizon = max(lastTailHorizon, max(HORIZON, frames))
        if hostBlock != 0 && frames != hostBlock { onBlockChange(frames) }
        hostBlock = frames
        bypassTarget = bypass ? 0 : 1
        let floor = pow(10, -(CAP_DB * min(1, max(0, strength))) / 20)
        let tailAgo = max(HORIZON, frames)
        for i in 0 ..< frames {
            let y = input[i]
            push(y)
            let tailOutNow = applyTail(ago: tailAgo, kernel: activeKernel)
            let howlOutNow = howlSample(y)
            fifo += 1
            if holdSamples > 0 { holdSamples -= 1 }
            if fifo >= PART {
                fifo = 0
                if gateReady {
                    if fitMode == .inline { fitFromLiveHistory() }
                    else { captureJob() }
                }
                requestAnalysis()
                applyFeatures()
            }
            var dry = y
            var tailOut = tailOutNow
            var howlOut = howlOutNow
            var bleedOut = 0.0 // Phase 1: learned bleed suppression is deliberately disabled.
            if mode == .low {
                let slot = delayI
                dry = slotDry[slot]
                tailOut = slotTail[slot]
                howlOut = slotHowl[slot]
                bleedOut = 0
                slotDry[slot] = y
                slotTail[slot] = tailOutNow
                slotHowl[slot] = howlOutNow
                delayI = (slot + 1) % 127
            }
            let broadband = cap(y: dry, broadband: tailOut + bleedOut, floor: floor)
            let wet = dry - broadband - howlOut
            if bypassMix != bypassTarget {
                let step = 1 / Double(frames)
                bypassMix = bypassMix < bypassTarget
                    ? min(bypassTarget, bypassMix + step)
                    : max(bypassTarget, bypassMix - step)
            }
            var sample = dry * (1 - bypassMix) + wet * bypassMix
            if fadeLeft > 0 {
                let a = 1 - Double(fadeLeft) / Double(fadeLen)
                sample = dry * (1 - a) + sample * a
                fadeLeft -= 1
            }
            output[i] = sample
            tailEnergy += broadband * broadband
            outEnergy += dry * dry
            meterN += 1
        }
    }

    /// Worker entry. Does nothing when the callback has not closed a partition.
    public func performFit() {
        guard si01_job_take(jobState) else { return }
        defer { si01_job_finish_read(jobState) }
        if !workerEnabled {
            missedPublish += 1
            return
        }
        if jobFrozen {
            publish(gbufIsTail: true)
            return
        }
        adapt(read: { self.job[$0] }, frozen: false, horizon: jobHorizon)
    }

    /// Analysis worker entry. Does nothing when the callback has not handed over a frame.
    public func performAnalysis() {
        guard si01_job_take(analysisState) else { return }
        defer { si01_job_finish_read(analysisState) }
        if analysisEpoch != workerEpoch {
            workerEpoch = analysisEpoch
            for i in 0 ..< HOWLS { tracks[i].reset() }
        }
        for i in 0 ..< GATE_WINDOW { frame[i] = analysisFrame[i] }
        let gate = analyzer.likelihood(frame, sr: sr)
        if gate >= FREEZE_LINE { workerHold = 8 }
        else if workerHold > 0 { workerHold -= 1 }
        let confirmed = analysisSkipHowl ? 0 : updateHowl(likelihood: gate)
        workerSeq += 1
        features[0] = Double(workerEpoch)
        features[1] = Double(workerSeq)
        features[2] = gate
        features[3] = Double(workerHold)
        features[4] = Double(confirmed)
        for i in 0 ..< HOWLS {
            let base = featureHead + i * featurePerHowl
            let c = tracks[i].coeff
            features[base] = tracks[i].hz
            features[base + 1] = tracks[i].gain
            features[base + 2] = c.b0
            features[base + 3] = c.b1
            features[base + 4] = c.b2
            features[base + 5] = c.a1
            features[base + 6] = c.a2
        }
        let ok = features.withUnsafeBufferPointer {
            si01_kernel_publish(featureStore, $0.baseAddress, $0.count)
        }
        if !ok { missedFeatures += 1 }
    }

    private func at(_ ago: Int) -> Double {
        if ago < 0 || ago >= histSize || ago >= seen { return 0 }
        return hist[(histI - 1 - ago) & histMask]
    }

    private func push(_ x: Double) {
        hist[histI] = x
        hist[histI + histSize] = x
        histI = (histI + 1) & histMask
        seen += 1
    }

    private func applyTail(ago: Int, kernel: UnsafePointer<Double>?) -> Double {
        guard let kernel else { return 0 }
        // kernel[k] * at(ago + k): walk the mirrored history backwards from `ago`.
        let newest = ((histI - 1 - ago) & histMask) + histSize
        return dot(kernel, 1, hist + newest, -1, TAIL_TAPS) * dereverb
    }

    private func cap(y: Double, broadband: Double, floor: Double) -> Double {
        let limit = abs(y) * (1 - floor)
        if abs(broadband) <= limit { return broadband }
        let sign: Double = broadband < 0 ? -1 : (broadband > 0 ? 1 : 0)
        return sign * limit
    }

    private func publish(gbufIsTail: Bool) {
        guard !gbufIsTail else { return }
        let ok = gbuf.withUnsafeBufferPointer {
            si01_kernel_publish(kernelStore, $0.baseAddress, $0.count)
        }
        guard ok else {
            missedPublish += 1
            return
        }
        tail = gbuf
    }

    private func fit(read: (Int) -> Double) {
        adapt(read: read, frozen: jobFrozen || freeze || likelihood >= FREEZE_LINE || voiceHold > 0, horizon: max(HORIZON, hostBlock))
    }

    private func adapt(read: (Int) -> Double, frozen: Bool, horizon: Int = HORIZON) {
        if frozen {
            publish(gbufIsTail: true)
            return
        }
        for i in 0 ..< TAIL_TAPS { gbuf[i] = tail[i] }
        let mu = 0.2
        for t in stride(from: PART - 1, through: 0, by: -1) {
            let target = read(t)
            var power = 1e-8
            var pred = 0.0
            for k in 0 ..< TAIL_TAPS {
                let ago = t + horizon + k
                if minInputAgo == 0 || ago < minInputAgo { minInputAgo = ago }
                let s = read(ago)
                xbuf[k] = s
                power += s * s
                pred += gbuf[k] * s
            }
            let step = (mu * (target - pred)) / power
            for k in 0 ..< TAIL_TAPS {
                gbuf[k] = gbuf[k] * 0.9995 + step * xbuf[k]
            }
        }
        publish(gbufIsTail: false)
    }

    private func fitFromLiveHistory() {
        if !workerEnabled {
            missedPublish += 1
            return
        }
        if holdSamples > 0 || !gateReady { return }
        jobFrozen = freeze || likelihood >= FREEZE_LINE || voiceHold > 0
        fit(read: { self.at($0) })
    }

    private func captureJob() {
        if !workerEnabled {
            missedPublish += 1
            return
        }
        if holdSamples > 0 { return }
        guard si01_job_begin_write(jobState) else {
            missedPublish += 1
            return
        }
        jobHorizon = max(HORIZON, hostBlock)
        let captureCount = min(jobSize, PART + jobHorizon + TAIL_TAPS)
        job.withUnsafeMutableBufferPointer { dst in
            for ago in 0 ..< captureCount { dst[ago] = at(ago) }
        }
        jobFrozen = freeze || likelihood >= FREEZE_LINE || voiceHold > 0
        si01_job_finish_write(jobState)
    }

    /// Callback side: hand the newest gate window to the analysis worker. Never waits.
    private func requestAnalysis() {
        if seen < GATE_WINDOW { return }
        guard si01_job_begin_write(analysisState) else {
            missedAnalysis += 1
            return
        }
        let start = (histI - GATE_WINDOW) & histMask
        analysisFrame.update(from: hist + start, count: GATE_WINDOW)
        analysisEpoch = epoch
        analysisSkipHowl = fadeLeft > 0
        si01_job_finish_write(analysisState)
        if fitMode == .inline { performAnalysis() }
    }

    /// Callback side: adopt the newest feature snapshot if it belongs to the current block size.
    private func applyFeatures() {
        guard let f = si01_kernel_read_begin(featureStore) else { return }
        defer { si01_kernel_read_end(featureStore) }
        let seq = Int(f[1])
        if seq == appliedSeq || Int(f[0]) != epoch { return }
        appliedSeq = seq
        likelihood = f[2]
        voiceHold = Int(f[3])
        gateReady = true
        confirmedHowls = Int(f[4])
        for i in 0 ..< HOWLS {
            let base = featureHead + i * featurePerHowl
            notches[i].hz = f[base]
            notches[i].gain = f[base + 1]
            notches[i].coeff = Coeff(b0: f[base + 2], b1: f[base + 3], b2: f[base + 4], a1: f[base + 5], a2: f[base + 6])
            howlHz[i] = f[base]
            howlGain[i] = f[base + 1]
        }
    }

    /// Worker side. Returns the number of confirmed howls.
    private func updateHowl(likelihood: Double) -> Int {
        analyzer.window(frame)
        analyzer.fftMag()
        let found = analyzer.findPeaks(frameLength: GATE_WINDOW, sr: sr)
        for i in 0 ..< 8 { usedPeak[i] = false }
        var confirmed = 0
        for index in 0 ..< HOWLS {
            if tracks[index].hz == 0 { continue }
            var best = -1
            var bestDist = 40.0
            for i in 0 ..< found {
                if usedPeak[i] { continue }
                let dist = abs(analyzer.peaks[i].hz - tracks[index].hz)
                if dist < bestDist {
                    bestDist = dist
                    best = i
                }
            }
            if best < 0 {
                tracks[index].age += 1
                if tracks[index].age > 4 {
                    tracks[index].reset()
                }
                continue
            }
            usedPeak[best] = true
            let peak = analyzer.peaks[best]
            let refined = analyzer.refineHz(frame, coarseHz: peak.hz, sr: sr)
            tracks[index].hz = refined == 0 ? peak.hz : refined
            tracks[index].age = 0
            tracks[index].mags.push(peak.mag)
            tracks[index].freqs.push(tracks[index].hz)
            let rising = tracks[index].mags.count >= trackMem
                && tracks[index].mags.newest > tracks[index].mags.oldest * 1.3
            var mean = 0.0
            for i in 0 ..< tracks[index].freqs.count { mean += tracks[index].freqs.at(i) }
            mean /= Double(max(1, tracks[index].freqs.count))
            var varSum = 0.0
            for i in 0 ..< tracks[index].freqs.count {
                let d = tracks[index].freqs.at(i) - mean
                varSum += d * d
            }
            let stdev = sqrt(varSum / Double(max(1, tracks[index].freqs.count)))
            let steady = tracks[index].freqs.count >= trackMem && stdev < 6
            let voiced = peak.harmonic >= 0.2 || likelihood >= FREEZE_LINE
            let held = tracks[index].gain < 0.5 && steady && !voiced
            let cut = ((rising && steady) || held) && !voiced
            let target = cut ? 0.2 : 1.0
            tracks[index].gain += (target - tracks[index].gain) * 0.35
            if cut && tracks[index].gain < 0.85 { confirmed += 1 }
            tracks[index].coeff = bandpass(hz: tracks[index].hz, sr: sr)
        }
        var usedCount = 0
        for i in 0 ..< found where usedPeak[i] { usedCount += 1 }
        if found > 0 {
            for i in 0 ..< found where !usedPeak[i] && usedCount < HOWLS {
                guard let slot = tracks.firstIndex(where: { $0.hz == 0 }) else { break }
                tracks[slot].hz = analyzer.peaks[i].hz
                tracks[slot].gain = 1
                tracks[slot].mags.removeAll()
                tracks[slot].freqs.removeAll()
                tracks[slot].mags.push(analyzer.peaks[i].mag)
                tracks[slot].freqs.push(analyzer.peaks[i].hz)
                tracks[slot].age = 0
                tracks[slot].coeff = bandpass(hz: tracks[slot].hz, sr: sr)
                usedPeak[i] = true
                usedCount += 1
            }
        }
        return confirmed
    }

    private func howlSample(_ x: Double) -> Double {
        var sub = 0.0
        for index in 0 ..< HOWLS {
            if notches[index].hz == 0 { continue }
            let c = notches[index].coeff
            let y = c.b0 * x + c.b1 * notches[index].x1 + c.b2 * notches[index].x2
                - c.a1 * notches[index].y1 - c.a2 * notches[index].y2
            notches[index].x2 = notches[index].x1
            notches[index].x1 = x
            notches[index].y2 = notches[index].y1
            notches[index].y1 = y
            sub += (1 - notches[index].gain) * y
        }
        return sub
    }

    private func onBlockChange(_ n: Int) {
        fifo = 0
        holdSamples = PART
        fadeLeft = n
        fadeLen = max(1, n)
        crossfades += 1
        confirmedHowls = 0
        // The worker resets its tracks when it sees the new epoch; older snapshots are ignored.
        epoch += 1
        for i in 0 ..< HOWLS {
            notches[i].hz = 0
            notches[i].gain = 1
            notches[i].clearFilterState()
            howlGain[i] = 1
            howlHz[i] = 0
        }
    }
}

public let SR: Double = 48000
let PART = 128
let HORIZON = 128
let TAIL_TAPS = 512
let HOWLS = 8
let BANDS = 16
let MAX_BLOCK = 2048
let CAP_DB = 12.0
let GATE_WINDOW = 1024
let FREEZE_LINE = 0.5
