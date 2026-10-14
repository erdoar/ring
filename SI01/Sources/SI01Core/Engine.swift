import Foundation

public enum FitMode {
    /// Same sample timing as the note. Used by the kernel tests.
    case inline
    /// The callback only copies a job. Another thread calls `performFit()`.
    case worker
}

private let histSize = 8192
private let histMask = histSize - 1
private let trackMem = 40
private let jobSize = 768

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

private struct Track {
    var hz: Double = 0
    var gain: Double = 1
    var mags = Ring()
    var freqs = Ring()
    var age = 0
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
    public var minInputAgo = HORIZON
    public var fitMode: FitMode = .inline

    public var tail: [Double]
    public var howlGain: [Double]
    public var howlHz: [Double]
    public var bleed: [Double]
    private var seq: UInt32 = 0

    private let analyzer = Analyzer(count: GATE_WINDOW)
    private var frame = [Double](repeating: 0, count: GATE_WINDOW)
    private var hist = [Double](repeating: 0, count: histSize)
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
    private var slotBand: [[Double]]
    private var delayI = 0
    private var tracks: [Track]
    private var bands: [Track]
    private var bleedApplied: [Double]
    private var bleedPending: [Double]
    private var tailEnergy = 0.0
    private var outEnergy = 0.0
    private var meterN = 0
    private var xbuf = [Double](repeating: 0, count: TAIL_TAPS)
    private var gbuf = [Double](repeating: 0, count: TAIL_TAPS)
    private var scratch = [Double](repeating: 0, count: BANDS)
    private var voiceHold = 0
    private var gateReady = false
    private var job = [Double](repeating: 0, count: jobSize)
    private var jobFrozen = false
    private var usedPeak = [Bool](repeating: false, count: 8)
    private var claimed = [Bool](repeating: false, count: BANDS)
    public private(set) var needsFit = false

    public init(mode: Mode = .zero, sr: Double = SR) {
        self.mode = mode
        self.sr = sr
        tail = [Double](repeating: 0, count: TAIL_TAPS)
        howlGain = [Double](repeating: 1, count: HOWLS)
        howlHz = [Double](repeating: 0, count: HOWLS)
        bleed = [Double](repeating: 1, count: BANDS)
        bleedApplied = [Double](repeating: 1, count: BANDS)
        bleedPending = [Double](repeating: 1, count: BANDS)
        tracks = [Track](repeating: Track(), count: HOWLS)
        slotBand = Array(repeating: [Double](repeating: 0, count: 127), count: BANDS)
        let lo = 80.0
        let hi = min(12000, sr * 0.45)
        let ratio = hi / lo
        var built: [Track] = []
        built.reserveCapacity(BANDS)
        for i in 0 ..< BANDS {
            let a = lo * pow(ratio, Double(i) / Double(BANDS))
            let b = lo * pow(ratio, Double(i + 1) / Double(BANDS))
            let hz = sqrt(a * b)
            let width = b - a
            let q = max(0.7, hz / width)
            var band = Track()
            band.hz = hz
            band.coeff = bandpass(hz: hz, sr: sr, q: q)
            built.append(band)
        }
        bands = built
    }

    public var latency: Int { mode.delaySamples }

    public func subtractionDb() -> Double {
        if outEnergy < 1e-12 { return -120 }
        return 10 * log10((tailEnergy + 1e-18) / outEnergy)
    }

    public var horizonHeld: Bool { minInputAgo >= HORIZON }

    public func render(input: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>, frames: Int) {
        if frames < 1 || frames > MAX_BLOCK { return }
        if hostBlock != 0 && frames != hostBlock { onBlockChange(frames) }
        hostBlock = frames
        bypassTarget = bypass ? 0 : 1
        for i in 0 ..< frames {
            let y = input[i]
            push(y)
            let tailOutNow = applyTail(ago: HORIZON)
            let howlOutNow = howlSample(y)
            tickBands(y)
            fifo += 1
            if holdSamples > 0 { holdSamples -= 1 }
            if fifo >= PART {
                fifo = 0
                if gateReady {
                    if fitMode == .inline { fitFromLiveHistory() }
                    else { captureJob() }
                }
                analyzeGate()
                updateHowl()
                updateBleed()
            }
            var dry = y
            var tailOut = tailOutNow
            var howlOut = howlOutNow
            var bleedOut = mixBleed(scratch)
            if mode == .low {
                let slot = delayI
                dry = slotDry[slot]
                tailOut = slotTail[slot]
                howlOut = slotHowl[slot]
                bleedOut = 0
                for b in 0 ..< BANDS {
                    let delayed = slotBand[b][slot]
                    slotBand[b][slot] = scratch[b]
                    let gain = bleedApplied[b]
                    if gain < 0.999 { bleedOut += (1 - gain) * delayed }
                }
                slotDry[slot] = y
                slotTail[slot] = tailOutNow
                slotHowl[slot] = howlOutNow
                delayI = (slot + 1) % 127
            }
            let broadband = cap(y: dry, broadband: tailOut + bleedOut)
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
        guard needsFit else { return }
        needsFit = false
        if !workerEnabled {
            missedPublish += 1
            return
        }
        if jobFrozen {
            publish(gbufIsTail: true)
            return
        }
        adapt(read: { self.job[$0] }, frozen: false)
    }

    private func at(_ ago: Int) -> Double {
        if ago < 0 || ago >= histSize || ago >= seen { return 0 }
        return hist[(histI - 1 - ago) & histMask]
    }

    private func push(_ x: Double) {
        hist[histI] = x
        histI = (histI + 1) & histMask
        seen += 1
    }

    private func fillFrame() {
        let n = GATE_WINDOW
        for i in 0 ..< n { frame[i] = at(n - 1 - i) }
    }

    private func applyTail(ago: Int) -> Double {
        var guardCount = 0
        while seq & 1 == 1 && guardCount < 4 { guardCount += 1 }
        var sum = 0.0
        for k in 0 ..< TAIL_TAPS { sum += tail[k] * at(ago + k) }
        return sum * dereverb
    }

    private func cap(y: Double, broadband: Double) -> Double {
        let db = CAP_DB * min(1, max(0, strength))
        let floor = pow(10, -db / 20)
        let limit = abs(y) * (1 - floor)
        if abs(broadband) <= limit { return broadband }
        let sign: Double = broadband < 0 ? -1 : (broadband > 0 ? 1 : 0)
        return sign * limit
    }

    private func publish(gbufIsTail: Bool) {
        seq &+= 1
        if !gbufIsTail {
            for i in 0 ..< TAIL_TAPS { tail[i] = gbuf[i] }
        }
        seq &+= 1
    }

    private func fit(read: (Int) -> Double) {
        adapt(read: read, frozen: jobFrozen || freeze || likelihood >= FREEZE_LINE || voiceHold > 0)
    }

    private func adapt(read: (Int) -> Double, frozen: Bool) {
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
                let ago = t + HORIZON + k
                if ago < minInputAgo { minInputAgo = ago }
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
        for ago in 0 ..< jobSize { job[ago] = at(ago) }
        for i in 0 ..< TAIL_TAPS { gbuf[i] = tail[i] }
        jobFrozen = freeze || likelihood >= FREEZE_LINE || voiceHold > 0
        needsFit = true
    }

    private func analyzeGate() {
        if seen < GATE_WINDOW { return }
        fillFrame()
        likelihood = analyzer.likelihood(frame, sr: sr)
        if likelihood >= FREEZE_LINE { voiceHold = 8 }
        else if voiceHold > 0 { voiceHold -= 1 }
        gateReady = true
    }

    private func updateHowl() {
        if fadeLeft > 0 || seen < GATE_WINDOW { return }
        fillFrame()
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
                    tracks[index].hz = 0
                    tracks[index].gain = 1
                    tracks[index].mags.removeAll()
                    tracks[index].freqs.removeAll()
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
        confirmedHowls = confirmed
        for i in 0 ..< HOWLS {
            howlGain[i] = tracks[i].gain
            howlHz[i] = tracks[i].hz
        }
    }

    private func howlSample(_ x: Double) -> Double {
        var sub = 0.0
        for index in 0 ..< HOWLS {
            if tracks[index].hz == 0 { continue }
            let c = tracks[index].coeff
            let y = c.b0 * x + c.b1 * tracks[index].x1 + c.b2 * tracks[index].x2
                - c.a1 * tracks[index].y1 - c.a2 * tracks[index].y2
            tracks[index].x2 = tracks[index].x1
            tracks[index].x1 = x
            tracks[index].y2 = tracks[index].y1
            tracks[index].y1 = y
            sub += (1 - tracks[index].gain) * y
        }
        return sub
    }

    private func bandOf(_ hz: Double) -> Int {
        let lo = 80.0
        let hi = min(12000, sr * 0.45)
        if hz < lo || hz >= hi { return -1 }
        let t = log(hz / lo) / log(hi / lo)
        return max(0, min(BANDS - 1, Int((t * Double(BANDS)).rounded(.down))))
    }

    private func updateBleed() {
        if seen < GATE_WINDOW { return }
        fillFrame()
        var energy = 0.0
        for sample in frame { energy += sample * sample }
        energy /= Double(frame.count)
        let voiced = likelihood >= FREEZE_LINE || voiceHold > 0
        for i in 0 ..< BANDS { claimed[i] = voiced }
        if energy >= 1e-6 && !voiced {
            analyzer.window(frame)
            analyzer.fftMag()
            let found = analyzer.findPeaks(frameLength: GATE_WINDOW, sr: sr)
            for i in 0 ..< found {
                let band = bandOf(analyzer.peaks[i].hz)
                if band >= 0 && analyzer.peaks[i].harmonic >= 0.2 { claimed[band] = true }
            }
            for track in tracks {
                if track.hz == 0 || track.freqs.count < 8 { continue }
                var mean = 0.0
                for i in 0 ..< track.freqs.count { mean += track.freqs.at(i) }
                mean /= Double(track.freqs.count)
                var varSum = 0.0
                for i in 0 ..< track.freqs.count {
                    let d = track.freqs.at(i) - mean
                    varSum += d * d
                }
                let stdev = sqrt(varSum / Double(track.freqs.count))
                let band = bandOf(track.hz)
                if band >= 0 && stdev > 6 { claimed[band] = true }
            }
        }
        let magReady = energy >= 1e-6
        if magReady {
            analyzer.window(frame)
            analyzer.fftMag()
        }
        let binHz = sr / Double(GATE_WINDOW)
        let hi = min(12000, sr * 0.45)
        for i in 0 ..< BANDS {
            var bandEnergy = 0.0
            if magReady {
                let loHz = 80 * pow(hi / 80, Double(i) / Double(BANDS))
                let hiHz = 80 * pow(hi / 80, Double(i + 1) / Double(BANDS))
                let a = max(1, Int((loHz / binHz).rounded(.down)))
                let b = min(analyzer.mag.count - 1, Int((hiHz / binHz).rounded(.up)))
                if a <= b {
                    for k in a ... b { bandEnergy += analyzer.mag[k] * analyzer.mag[k] }
                }
            }
            let audible = bandEnergy > energy * Double(frame.count) * 0.02
            let target = claimed[i] || !audible ? 1.0 : 0.0
            let g = bleed[i]
            bleed[i] = g + (target - g) * 0.85
        }
        if mode == .low {
            for i in 0 ..< BANDS { bleedApplied[i] = bleed[i] }
        } else {
            for i in 0 ..< BANDS {
                bleedApplied[i] = bleedPending[i]
                bleedPending[i] = bleed[i]
            }
        }
    }

    private func tickBands(_ x: Double) {
        for i in 0 ..< BANDS {
            let c = bands[i].coeff
            let y = c.b0 * x + c.b1 * bands[i].x1 + c.b2 * bands[i].x2 - c.a1 * bands[i].y1 - c.a2 * bands[i].y2
            bands[i].x2 = bands[i].x1
            bands[i].x1 = x
            bands[i].y2 = bands[i].y1
            bands[i].y1 = y
            scratch[i] = y
        }
    }

    private func mixBleed(_ bands: [Double]) -> Double {
        var sub = 0.0
        for i in 0 ..< BANDS {
            let gain = bleedApplied[i]
            if gain < 0.999 { sub += (1 - gain) * bands[i] }
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
        for i in 0 ..< HOWLS {
            tracks[i].hz = 0
            tracks[i].gain = 1
            tracks[i].mags.removeAll()
            tracks[i].freqs.removeAll()
            tracks[i].age = 0
            tracks[i].clearFilterState()
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
