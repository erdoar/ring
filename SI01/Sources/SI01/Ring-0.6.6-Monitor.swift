#if os(macOS)
import Darwin
import Foundation

final class MonitorServer {
    private let lock = NSLock()
    private var body = "{}"
    private var listenFD: Int32 = -1
    private var stopped = false
    private var boundPort = 0

    func port() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    func start() {
        Thread.detachNewThread { [self] in
            self.serve()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    func publish(_ json: String) {
        lock.lock()
        body = json
        lock.unlock()
    }

    private func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    private func shouldStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var chosen = 0
        for candidate in [8765, 8766, 8767] {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(candidate).bigEndian
            addr.sin_addr = in_addr(s_addr: in_addr_t(0))
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 {
                chosen = candidate
                break
            }
        }
        if chosen == 0 || listen(fd, 8) != 0 {
            close(fd)
            return
        }
        lock.lock()
        listenFD = fd
        boundPort = chosen
        lock.unlock()
        while !shouldStop() {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            reply(client)
            close(client)
        }
        close(fd)
    }

    private func reply(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = read(client, &buffer, buffer.count)
        let request = count > 0 ? String(bytes: buffer[..<count], encoding: .utf8) ?? "" : ""
        let first = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        if path == "/state" || path.hasPrefix("/state?") {
            send(client, current(), type: "application/json")
        } else if path == "/" || path.hasPrefix("/?") {
            send(client, Self.page, type: "text/html; charset=utf-8")
        } else {
            send(client, "not found", type: "text/plain")
        }
    }

    private func send(_ client: Int32, _ payload: String, type: String) {
        let bytes = Array(payload.utf8)
        let header = "HTTP/1.0 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var data = Array(header.utf8)
        data.append(contentsOf: bytes)
        var sent = 0
        while sent < data.count {
            let wrote = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return write(client, base.advanced(by: sent), data.count - sent)
            }
            if wrote <= 0 { break }
            sent += wrote
        }
    }

    private static let page = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ring 0.6.2</title>
    <style>
    body { margin: 0; background: #ececec; color: #1d1d1f; font: 13px -apple-system, sans-serif; user-select: text; }
    main { max-width: 640px; margin: 8px auto; background: #fff; border: 1px solid #c6c6c8; border-radius: 10px; padding: 12px 12px 16px; }
    h1 { font-size: 15px; margin: 0 0 12px; }
    .status { font-size: 15px; font-weight: 600; margin: 0 0 12px; }
    .row { display: flex; align-items: center; gap: 12px; margin: 8px 0; }
    .box { border: 1px solid #c6c6c8; border-radius: 6px; max-height: 360px; overflow: auto; padding: 8px; margin: 16px 0 8px; }
    .channel { display: flex; gap: 8px; align-items: center; padding: 6px 4px 10px; border-bottom: 1px solid #eee; }
    .top, .mid, .low { display: flex; align-items: center; gap: 8px; }
    .mid, .low { margin-top: 6px; }
    .num { width: 20px; font-weight: 600; font-variant-numeric: tabular-nums; }
    .bar { flex: 1; height: 10px; background: #d2d2d7; }
    .bar > span { display: block; height: 10px; background: #007aff; }
    .value { width: 78px; text-align: right; font-variant-numeric: tabular-nums; font-size: 12px; }
    input[type="range"] { flex: 1; }
    .health, .note { color: #6e6e73; font-size: 12px; font-variant-numeric: tabular-nums; }
    .channel .body { flex: 1; min-width: 0; }
    .trim-side { width: 56px; text-align: center; flex: none; font-size: 11px; }
    .mini-knob { width: 28px; height: 28px; border: 2px solid #c6c6c8; border-radius: 50%; position: relative; margin: 0 auto 2px; }
    .mini-knob i { position: absolute; width: 2px; height: 11px; background: #007aff; left: 12px; top: 2px; transform-origin: 50% 11px; }
    .meter { display: grid; grid-template-columns: minmax(72px, 96px) 1fr minmax(64px, 108px); gap: 8px; align-items: center; margin-top: 8px; font-size: 12px; }
    .meter b { font-weight: 400; }
    </style>
    </head>
    <body>
    <main>
    <h1>Ring 0.6.2</h1>
    <p class="status" id="status">Opening</p>
    <div class="row"><span>Channels</span><b id="channels">1</b><span>Mode</span><b id="mode">ZERO</b></div>
    <div class="box" id="channels-box"></div>
    <p class="health" id="health">missed 0    overrun 0</p>
    <div class="meter"><b>App CPU</b><div class="bar"><span id="app-cpu"></span></div><span id="app-cpu-v">—</span></div>
    <div class="meter"><b>System CPU</b><div class="bar"><span id="sys-cpu"></span></div><span id="sys-cpu-v">—</span></div>
    <div class="meter"><b>App memory</b><div class="bar"><span id="app-mem"></span></div><span id="app-mem-v">—</span></div>
    <div class="meter"><b>System memory</b><div class="bar"><span id="sys-mem"></span></div><span id="sys-mem-v">—</span></div>
    </main>
    <script>
    function bar(db) { if (db <= -60) return 0; return Math.max(0, Math.min(100, (db + 60) / 60 * 100)); }
    function trimText(db) { return (db >= 0 ? "+" : "") + db.toFixed(1) + " dB"; }
    function draw(state) {
      document.getElementById("status").textContent = state.status || "";
      document.getElementById("channels").textContent = state.channels;
      document.getElementById("mode").textContent = (state.mode || "zero").toUpperCase();
      document.getElementById("health").textContent = "missed " + state.missed + "    overrun " + state.overrun;
      var box = document.getElementById("channels-box");
      var top = box.scrollTop;
      var html = "<div class='note'>Mix at bypass drops the effect and the trim. Mute sends silence.</div>";
      (state.inputs || []).forEach(function (input, index) {
        var mixLabel = input.mix < 0.5 ? "Bypass" : Math.round(input.mix) + "%";
        var deg = (input.trim / 8) * 135;
        html += "<div class='channel'><div class='body'><div class='top'><span>Mix</span><input type='range' min='0' max='100' disabled value='" + input.mix + "'><span class='value'>" + mixLabel + "</span><span class='num'>" + (index + 1) + "</span><div class='bar'><span style='width:" + bar(input.level) + "%'></span></div><span class='value'>" + Number(input.level).toFixed(1) + " dB</span></div>";
        html += "<div class='low'><label><input type='checkbox' disabled " + (input.mute ? "checked" : "") + "> Mute</label><span>Voice " + Number(input.voice).toFixed(2) + "</span><span>Cut " + Number(input.cut).toFixed(1) + " dB</span></div></div>";
        html += "<div class='trim-side'><div class='mini-knob'><i style='transform:rotate(" + deg + "deg)'></i></div><span>" + trimText(input.trim) + "</span></div></div>";
      });
      box.innerHTML = html;
      document.getElementById("app-cpu").style.width = Math.min(100, state.appCPU) + "%";
      document.getElementById("sys-cpu").style.width = Math.min(100, state.systemCPU) + "%";
      document.getElementById("app-cpu-v").textContent = state.appCPUText;
      document.getElementById("sys-cpu-v").textContent = state.systemCPUText;
      document.getElementById("app-mem").style.width = Math.min(100, state.appMemoryFraction || 0) + "%";
      document.getElementById("sys-mem").style.width = Math.min(100, state.systemMemoryFraction || 0) + "%";
      document.getElementById("app-mem-v").textContent = state.appMemory;
      document.getElementById("sys-mem-v").textContent = state.systemMemory;
      box.scrollTop = top;
    }
    function tick() {
      fetch("/state").then(function (r) { return r.json(); }).then(draw).catch(function () {});
    }
    tick();
    setInterval(tick, 500);
    </script>
    </body>
    </html>
    """#
}
#endif
