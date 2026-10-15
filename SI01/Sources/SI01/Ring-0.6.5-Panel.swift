#if os(macOS)
import AppKit
import CoreAudio
import Darwin
import SI01Core

private struct Snapshot {
    var likelihood: [Double]
    var cut: [Double]
    var input: [Double]
    var missed: Int
    var overrun: Int

    static func parse(_ json: String) -> Snapshot? {
        func array(_ key: String) -> [Double] {
            guard let start = json.range(of: "\"\(key)\":[") else { return [] }
            let rest = json[start.upperBound...]
            guard let end = rest.firstIndex(of: "]") else { return [] }
            return rest[..<end].split(separator: ",").compactMap { Double($0) }
        }
        func whole(_ key: String) -> Int {
            guard let start = json.range(of: "\"\(key)\":") else { return 0 }
            let rest = json[start.upperBound...]
            let end = rest.firstIndex(where: { $0 == "," || $0 == "}" }) ?? rest.endIndex
            return Int(rest[..<end]) ?? 0
        }
        let likes = array("likelihood")
        if likes.isEmpty { return nil }
        return Snapshot(
            likelihood: likes,
            cut: array("cutDb"),
            input: array("inputDb"),
            missed: whole("missed"),
            overrun: whole("overrun")
        )
    }
}

private struct MachineSample {
    var appCPU = 0.0
    var systemCPU = 0.0
    var appBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
}

private final class MachineMeter {
    private var lastApp: UInt64?
    private var lastWall: TimeInterval?
    private var lastTicks: (UInt64, UInt64, UInt64, UInt64)?
    private let cores = Double(max(1, ProcessInfo.processInfo.processorCount))

    func sample() -> MachineSample {
        var sample = MachineSample()
        sample.totalBytes = physicalBytes()
        sample.appBytes = residentBytes()
        sample.usedBytes = usedBytes()
        let now = ProcessInfo.processInfo.systemUptime
        let app = appMicros()
        if let lastApp, let lastWall, now > lastWall {
            let used = Double(app &- lastApp) / 1_000_000
            sample.appCPU = min(100, max(0, used / (now - lastWall) / cores * 100))
        }
        self.lastApp = app
        lastWall = now
        let ticks = cpuTicks()
        if let lastTicks, let ticks {
            let busy = (ticks.0 &- lastTicks.0) + (ticks.1 &- lastTicks.1) + (ticks.3 &- lastTicks.3)
            let idle = ticks.2 &- lastTicks.2
            let total = busy + idle
            if total > 0 { sample.systemCPU = min(100, Double(busy) / Double(total) * 100) }
        }
        if let ticks { lastTicks = ticks }
        return sample
    }

    private func appMicros() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return micros(usage.ru_utime) + micros(usage.ru_stime)
    }

    private func micros(_ time: timeval) -> UInt64 {
        UInt64(max(0, time.tv_sec)) * 1_000_000 + UInt64(max(0, time.tv_usec))
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func usedBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        if result != KERN_SUCCESS { return 0 }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func cpuTicks() -> (UInt64, UInt64, UInt64, UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), host_flavor_t(HOST_CPU_LOAD_INFO), $0, &count)
            }
        }
        if result != KERN_SUCCESS { return nil }
        let raw = withUnsafeBytes(of: load.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)) }
        guard raw.count >= 4 else { return nil }
        return (UInt64(raw[0]), UInt64(raw[1]), UInt64(raw[2]), UInt64(raw[3]))
    }

    private func physicalBytes() -> UInt64 {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        return bytes
    }
}

private struct ChannelRow {
    let level: MeterBar
    let levelValue: NSTextField
    let voice: NSTextField
    let cut: NSTextField
    let trimValue: NSTextField
    let mixValue: NSTextField
}

private final class MeterBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
        let width = bounds.width * CGFloat(min(1, max(0, fraction)))
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: width, height: bounds.height).fill()
    }
}

private final class MixKnob: NSControl {
    var mix = 1.0 { didSet { needsDisplay = true } }
    private var dragStart: (y: CGFloat, mix: Double)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.5 - 2
        let start = CGFloat.pi * 1.25
        let end = CGFloat.pi * -0.25
        let angle = start + CGFloat(mix) * (end - start)
        NSColor.separatorColor.setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: start * 180 / .pi, endAngle: end * 180 / .pi, clockwise: true)
        track.lineWidth = 2
        track.stroke()
        NSColor.controlAccentColor.setStroke()
        NSColor.controlAccentColor.setFill()
        let pointer = NSBezierPath()
        pointer.move(to: center)
        pointer.line(to: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        pointer.lineWidth = 2
        pointer.stroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = (point.y, mix)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = min(1, max(0, dragStart.mix + Double(point.y - dragStart.y) / 70))
        guard abs(next - mix) > 0.0001 else { return }
        mix = next
        sendAction(action, to: target)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}

private final class TrimKnob: NSControl {
    var decibels = 0.0 { didSet { needsDisplay = true } }
    private var dragStart: (y: CGFloat, db: Double)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.5 - 2
        let start = CGFloat.pi * 1.25
        let end = CGFloat.pi * -0.25
        let fraction = min(1, max(0, (decibels + 8) / 16))
        let angle = start + CGFloat(fraction) * (end - start)
        NSColor.separatorColor.setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: start * 180 / .pi, endAngle: end * 180 / .pi, clockwise: true)
        track.lineWidth = 2
        track.stroke()
        NSColor.controlAccentColor.setStroke()
        NSColor.controlAccentColor.setFill()
        let pointer = NSBezierPath()
        pointer.move(to: center)
        pointer.line(to: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        pointer.lineWidth = 2
        pointer.stroke()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = (point.y, decibels)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = min(8, max(-8, dragStart.db + Double(point.y - dragStart.y) / 8))
        guard abs(next - decibels) > 0.01 else { return }
        decibels = next
        sendAction(action, to: target)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }
}

private final class InsertPanel: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let host: CoreAudioHost
    private let window: NSWindow
    private let status: NSTextField
    private let channels: NSStepper
    private let channelValue: NSTextField
    private let modeControl: NSSegmentedControl
    private let scroll = NSScrollView()
    private let document = NSView()
    private let health: NSTextField
    private let monitorLine: NSTextField
    private let meter = MachineMeter()
    private let monitor = MonitorServer()
    private var channelRows: [ChannelRow] = []
    private var timer: Timer?
    private let appCPU = MeterBar()
    private let systemCPU = MeterBar()
    private let appMemory = MeterBar()
    private let systemMemory = MeterBar()
    private let appCPUValue = NSTextField(labelWithString: "—")
    private let systemCPUValue = NSTextField(labelWithString: "—")
    private let appMemoryValue = NSTextField(labelWithString: "—")
    private let systemMemoryValue = NSTextField(labelWithString: "—")

    init(host: CoreAudioHost) {
        self.host = host
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ring 0.6.2"
        window.contentMinSize = NSSize(width: 300, height: 360)
        status = NSTextField(labelWithString: "Opening the default input.")
        channels = NSStepper()
        channelValue = NSTextField(labelWithString: "1")
        modeControl = NSSegmentedControl()
        health = NSTextField(labelWithString: "missed 0    overrun 0")
        monitorLine = NSTextField(labelWithString: "External monitor")
        super.init()
        window.delegate = self
        build()
    }

    func show(status text: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        installMenu(app)
        status.stringValue = text
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        monitor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func setStatus(_ text: String) {
        status.stringValue = text
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        monitor.stop()
        host.stop()
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    @objc private func channelsChanged() {
        let count = channels.integerValue
        channelValue.stringValue = String(count)
        do {
            try host.restart(channels: count, mode: host.mode)
            status.stringValue = "Listening. \(count) \(count == 1 ? "channel" : "channels")."
        } catch {
            channels.integerValue = host.channelCount
            channelValue.stringValue = String(host.channelCount)
            status.stringValue = "The channel change did not start."
        }
    }

    @objc private func trimChanged(_ sender: TrimKnob) {
        let index = sender.tag
        let db = min(8, max(-8, sender.decibels))
        host.setTrim(channel: index, db: db)
        guard index >= 0, index < channelRows.count else { return }
        channelRows[index].trimValue.stringValue = trimText(db)
    }

    @objc private func mixChanged(_ sender: MixKnob) {
        let index = sender.tag
        host.setMix(channel: index, mix: sender.mix)
        guard index >= 0, index < channelRows.count else { return }
        channelRows[index].mixValue.stringValue = mixText(sender.mix)
    }

    @objc private func muteChanged(_ sender: NSButton) {
        host.setMuted(channel: sender.tag, muted: sender.state == .on)
    }

    @objc private func modeChanged() {
        let next: Mode = modeControl.selectedSegment == 1 ? .low : .zero
        do {
            try host.restart(channels: host.channelCount, mode: next)
            status.stringValue = next == .low ? "Listening. LOW adds 127 samples." : "Listening. ZERO adds no delay."
        } catch {
            modeControl.selectedSegment = host.mode == .low ? 1 : 0
            status.stringValue = "The mode change did not start."
        }
    }

    private func refresh() {
        var reading: Snapshot?
        if let frame = host.snapshot(), let parsed = Snapshot.parse(frame) {
            reading = parsed
            updateChannels(parsed)
            health.stringValue = "missed \(parsed.missed)    overrun \(parsed.overrun)"
        }
        let sample = meter.sample()
        appCPU.fraction = sample.appCPU / 100
        systemCPU.fraction = sample.systemCPU / 100
        appCPUValue.stringValue = percent(sample.appCPU)
        systemCPUValue.stringValue = percent(sample.systemCPU)
        appMemoryValue.stringValue = bytes(sample.appBytes)
        systemMemoryValue.stringValue = sample.totalBytes == 0 ? bytes(sample.usedBytes) : "\(bytes(sample.usedBytes)) / \(bytes(sample.totalBytes))"
        appMemory.fraction = sample.totalBytes == 0 ? 0 : Double(sample.appBytes) / Double(sample.totalBytes)
        systemMemory.fraction = sample.totalBytes == 0 ? 0 : Double(sample.usedBytes) / Double(sample.totalBytes)
        monitorLine.stringValue = monitorText()
        publishMonitor(parsed: reading, sample: sample)
    }

    private func monitorText() -> String {
        let port = monitor.port()
        if port == 0 { return "Starting" }
        let addresses = Self.monitorAddresses()
        if addresses.isEmpty { return "No network" }
        return addresses.map { "http://\($0):\(port)" }.joined(separator: "   ")
    }

    private func publishMonitor(parsed: Snapshot?, sample: MachineSample) {
        func num(_ value: Double) -> String { String(format: "%.2f", value) }
        func quote(_ value: String) -> String {
            var out = "\""
            for character in value {
                if character == "\\" || character == "\"" { out.append("\\") }
                out.append(character)
            }
            out.append("\"")
            return out
        }
        var rows = ""
        let count = host.channelCount
        for index in 0 ..< count {
            if index > 0 { rows += "," }
            let level = parsed.map { index < $0.input.count ? $0.input[index] : -120 } ?? -120
            let voice = parsed.map { index < $0.likelihood.count ? $0.likelihood[index] : 0 } ?? 0
            let cut = parsed.map { index < $0.cut.count ? $0.cut[index] : 0 } ?? 0
            rows += "{\"level\":\(num(level)),\"voice\":\(num(voice)),\"cut\":\(num(cut)),\"trim\":\(num(host.trimDb(channel: index))),\"mix\":\(num(host.mix(channel: index) * 100)),\"mute\":\(host.isMuted(channel: index))}"
        }
        let appFraction = sample.totalBytes == 0 ? 0 : Double(sample.appBytes) / Double(sample.totalBytes) * 100
        let usedFraction = sample.totalBytes == 0 ? 0 : Double(sample.usedBytes) / Double(sample.totalBytes) * 100
        let systemText = sample.totalBytes == 0 ? bytes(sample.usedBytes) : "\(bytes(sample.usedBytes)) / \(bytes(sample.totalBytes))"
        let json = "{\"status\":\(quote(status.stringValue)),\"channels\":\(count),\"mode\":\(quote(host.mode.rawValue)),\"missed\":\(parsed?.missed ?? 0),\"overrun\":\(parsed?.overrun ?? 0),\"inputs\":[\(rows)],\"appCPU\":\(num(sample.appCPU)),\"systemCPU\":\(num(sample.systemCPU)),\"appCPUText\":\(quote(percent(sample.appCPU))),\"systemCPUText\":\(quote(percent(sample.systemCPU))),\"appMemory\":\(quote(bytes(sample.appBytes))),\"systemMemory\":\(quote(systemText)),\"appMemoryFraction\":\(num(appFraction)),\"systemMemoryFraction\":\(num(usedFraction))}"
        monitor.publish(json)
    }

    private func updateChannels(_ parsed: Snapshot) {
        if channelRows.count != parsed.likelihood.count { rebuildChannels(parsed.likelihood.count) }
        for index in parsed.likelihood.indices {
            let level = index < parsed.input.count ? parsed.input[index] : -120
            channelRows[index].level.fraction = level <= -60 ? 0 : min(1, (level + 60) / 60)
            channelRows[index].levelValue.stringValue = String(format: "%.1f dB", level)
            channelRows[index].voice.stringValue = String(format: "%.2f", parsed.likelihood[index])
            let cut = index < parsed.cut.count ? parsed.cut[index] : 0
            channelRows[index].cut.stringValue = String(format: "%.1f dB", cut)
        }
    }

    private func rebuildChannels(_ count: Int) {
        for view in document.subviews { view.removeFromSuperview() }
        channelRows = []
        let header = label("Ring 0.6.2. Mix at bypass drops the effect and the trim. Mute sends silence.")
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(header)
        header.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8).isActive = true
        header.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8).isActive = true
        header.topAnchor.constraint(equalTo: document.topAnchor, constant: 8).isActive = true
        var previous: NSView = header
        for index in 0 ..< count {
            let line = channelBlock(index)
            document.addSubview(line.view)
            line.view.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: 6).isActive = true
            pin(line.view, top: nil, topGap: 0)
            channelRows.append(line.row)
            previous = line.view
        }
        previous.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8).isActive = true
    }

    private func build() {
        guard let content = window.contentView else { return }
        status.font = .systemFont(ofSize: 15, weight: .semibold)
        status.translatesAutoresizingMaskIntoConstraints = false
        let channelLabel = label("Channels")
        channels.minValue = 1
        channels.maxValue = 8
        channels.integerValue = 1
        channels.valueWraps = false
        channels.target = self
        channels.action = #selector(channelsChanged)
        channels.translatesAutoresizingMaskIntoConstraints = false
        channelValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        channelValue.translatesAutoresizingMaskIntoConstraints = false
        let modeLabel = label("Mode")
        modeControl.segmentCount = 2
        modeControl.setLabel("ZERO", forSegment: 0)
        modeControl.setLabel("LOW", forSegment: 1)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        health.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        health.textColor = .secondaryLabelColor
        health.translatesAutoresizingMaskIntoConstraints = false
        monitorLine.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        monitorLine.isSelectable = true
        monitorLine.isEditable = false
        monitorLine.lineBreakMode = .byTruncatingMiddle
        monitorLine.translatesAutoresizingMaskIntoConstraints = false
        status.isSelectable = true
        status.isEditable = false
        health.isSelectable = true
        health.isEditable = false
        let meters = NSStackView()
        meters.orientation = .vertical
        meters.spacing = 8
        meters.alignment = .leading
        meters.translatesAutoresizingMaskIntoConstraints = false
        meters.addArrangedSubview(meterRow("App CPU", appCPU, appCPUValue))
        meters.addArrangedSubview(meterRow("System CPU", systemCPU, systemCPUValue))
        meters.addArrangedSubview(meterRow("App memory", appMemory, appMemoryValue))
        meters.addArrangedSubview(meterRow("System memory", systemMemory, systemMemoryValue))
        for view in meters.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: meters.widthAnchor).isActive = true
        }
        content.addSubview(status)
        content.addSubview(channelLabel)
        content.addSubview(channels)
        content.addSubview(channelValue)
        content.addSubview(modeLabel)
        content.addSubview(modeControl)
        content.addSubview(scroll)
        content.addSubview(health)
        content.addSubview(monitorLine)
        content.addSubview(meters)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            channelLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            channelLabel.centerYAnchor.constraint(equalTo: channels.centerYAnchor),
            channels.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            channels.leadingAnchor.constraint(equalTo: channelLabel.trailingAnchor, constant: 12),
            channelValue.leadingAnchor.constraint(equalTo: channels.trailingAnchor, constant: 8),
            channelValue.centerYAnchor.constraint(equalTo: channels.centerYAnchor),
            modeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            modeLabel.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            modeControl.topAnchor.constraint(equalTo: channels.bottomAnchor, constant: 8),
            modeControl.leadingAnchor.constraint(equalTo: channels.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            health.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            health.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            monitorLine.topAnchor.constraint(equalTo: health.bottomAnchor, constant: 6),
            monitorLine.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            monitorLine.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            meters.topAnchor.constraint(equalTo: monitorLine.bottomAnchor, constant: 12),
            meters.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            meters.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            meters.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        rebuildChannels(1)
    }

    private static func monitorAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cursor {
            let flags = Int32(iface.pointee.ifa_flags)
            let family = iface.pointee.ifa_addr?.pointee.sa_family ?? 0
            if (flags & IFF_LOOPBACK) == 0, family == UInt8(AF_INET), let addr = iface.pointee.ifa_addr {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    let ip = String(cString: host)
                    let name = String(cString: iface.pointee.ifa_name)
                    if !ip.isEmpty, ip != "0.0.0.0", name == "en0" || name.hasPrefix("en") || name.hasPrefix("bridge") {
                        if addresses.contains(ip) { cursor = iface.pointee.ifa_next; continue }
                        if name == "en0" { addresses.insert(ip, at: 0) } else { addresses.append(ip) }
                    }
                }
            }
            cursor = iface.pointee.ifa_next
        }
        if addresses.isEmpty { return [] }
        return [addresses[0]]
    }

    private func meterRow(_ title: String, _ bar: MeterBar, _ value: NSTextField) -> NSView {
        let name = label(title)
        name.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)
        row.addSubview(bar)
        row.addSubview(value)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.widthAnchor.constraint(equalToConstant: 88),
            bar.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 10),
            value.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            value.widthAnchor.constraint(lessThanOrEqualToConstant: 108),
            row.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    private func channelBlock(_ index: Int) -> (view: NSView, row: ChannelRow) {
        let name = label(String(index + 1))
        name.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let knob = MixKnob(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        knob.mix = host.mix(channel: index)
        knob.tag = index
        knob.target = self
        knob.action = #selector(mixChanged(_:))
        knob.translatesAutoresizingMaskIntoConstraints = false
        let mix = label(mixText(knob.mix))
        mix.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(muteChanged(_:)))
        mute.tag = index
        mute.state = host.isMuted(channel: index) ? .on : .off
        mute.translatesAutoresizingMaskIntoConstraints = false
        let bar = MeterBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let level = label("-120.0 dB")
        level.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        level.alignment = .right
        let trimKnob = TrimKnob(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        trimKnob.decibels = host.trimDb(channel: index)
        trimKnob.tag = index
        trimKnob.target = self
        trimKnob.action = #selector(trimChanged(_:))
        trimKnob.translatesAutoresizingMaskIntoConstraints = false
        let trim = label(trimText(trimKnob.decibels))
        trim.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trim.alignment = .center
        let voiceName = label("Voice")
        let voice = label("0.00")
        voice.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let cutName = label("Cut")
        let cut = label("0.0 dB")
        cut.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        for view in [knob, mix, name, bar, level, trimKnob, trim, mute, voiceName, voice, cutName, cut] as [NSView] {
            line.addSubview(view)
        }
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 78),
            knob.leadingAnchor.constraint(equalTo: line.leadingAnchor, constant: 8),
            knob.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: 32),
            knob.heightAnchor.constraint(equalToConstant: 32),
            mix.leadingAnchor.constraint(equalTo: knob.trailingAnchor, constant: 4),
            mix.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            mix.widthAnchor.constraint(equalToConstant: 48),
            name.leadingAnchor.constraint(equalTo: mix.trailingAnchor, constant: 4),
            name.topAnchor.constraint(equalTo: line.topAnchor, constant: 4),
            name.widthAnchor.constraint(equalToConstant: 16),
            bar.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            bar.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 10),
            level.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
            level.trailingAnchor.constraint(equalTo: trimKnob.leadingAnchor, constant: -8),
            level.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            level.widthAnchor.constraint(equalToConstant: 64),
            trimKnob.trailingAnchor.constraint(equalTo: line.trailingAnchor, constant: -8),
            trimKnob.topAnchor.constraint(equalTo: line.topAnchor, constant: 4),
            trimKnob.widthAnchor.constraint(equalToConstant: 32),
            trimKnob.heightAnchor.constraint(equalToConstant: 32),
            trim.centerXAnchor.constraint(equalTo: trimKnob.centerXAnchor),
            trim.topAnchor.constraint(equalTo: trimKnob.bottomAnchor, constant: 2),
            trim.widthAnchor.constraint(equalToConstant: 56),
            mute.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            mute.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            voiceName.leadingAnchor.constraint(equalTo: mute.trailingAnchor, constant: 8),
            voiceName.centerYAnchor.constraint(equalTo: mute.centerYAnchor),
            voice.leadingAnchor.constraint(equalTo: voiceName.trailingAnchor, constant: 4),
            voice.centerYAnchor.constraint(equalTo: voiceName.centerYAnchor),
            cutName.leadingAnchor.constraint(equalTo: voice.trailingAnchor, constant: 8),
            cutName.centerYAnchor.constraint(equalTo: voiceName.centerYAnchor),
            cut.leadingAnchor.constraint(equalTo: cutName.trailingAnchor, constant: 4),
            cut.centerYAnchor.constraint(equalTo: voiceName.centerYAnchor),
        ])
        return (line, ChannelRow(level: bar, levelValue: level, voice: voice, cut: cut, trimValue: trim, mixValue: mix))
    }

    private func mixText(_ mix: Double) -> String {
        if mix < 0.005 { return "Bypass" }
        return String(format: "%.0f%%", mix * 100)
    }

    private func trimText(_ db: Double) -> String {
        String(format: "%+.1f dB", db)
    }

    private func pin(_ view: NSView, top: NSLayoutYAxisAnchor?, topGap: CGFloat) {
        view.leadingAnchor.constraint(equalTo: document.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: document.trailingAnchor).isActive = true
        if let top { view.topAnchor.constraint(equalTo: top, constant: topGap).isActive = true }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.font = .systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func percent(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    private func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    private func installMenu(_ app: NSApplication) {
        let bar = NSMenu()
        let item = NSMenuItem()
        bar.addItem(item)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit Ring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = menu
        app.mainMenu = bar
    }
}

enum InsertLaunch {
    private static var panelAnchor: InsertPanel?

    static func run() throws {
        let app = App()
        try app.setChannels(1)
        let host = CoreAudioHost(app: app, request: DeviceRequest())
        let panel = InsertPanel(host: host)
        panelAnchor = panel
        panel.show(status: "Opening the default input.")
        do {
            var device = AudioDeviceID(0)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: 0
            )
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let read = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            if read != noErr || device == 0 { throw SessionError.block }
            try host.open(device: device)
            try host.start()
            panel.setStatus("Listening. The insert is on the default input.")
        } catch {
            panel.setStatus("Audio did not start. The default input must be 48 kHz and 32 frames.")
        }
        NSApplication.shared.run()
    }
}
#endif
