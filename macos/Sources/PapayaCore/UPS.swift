import Foundation
import IOKit.ps

/// UPS units macOS itself manages: a USB HID UPS plugged into this Mac appears in
/// IOPowerSources with type "UPS Power Source", no driver needed.
public enum LocalUPS {
    public static func read() -> [UPSSnapshot] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var out: [UPSSnapshot] = []
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSUPSType else { continue }
            out.append(snapshot(from: d))
        }
        return out
    }

    /// Builds a snapshot from an IOPowerSources description. Public so it can be fed fixtures.
    public static func snapshot(from d: [String: Any]) -> UPSSnapshot {
        let name = (d[kIOPSNameKey] as? String) ?? "UPS"
        var u = UPSSnapshot(id: "iops:\(name)", name: name, source: "USB (macOS)")
        if let cur = int(d[kIOPSCurrentCapacityKey]), let max = int(d[kIOPSMaxCapacityKey]), max > 0 {
            u.chargePercent = Double(cur) / Double(max) * 100
        }
        if let state = d[kIOPSPowerSourceStateKey] as? String {
            u.onBattery = state == kIOPSBatteryPowerValue
            u.status = state == kIOPSBatteryPowerValue ? "OB" : "OL"
        }
        if let t = int(d[kIOPSTimeToEmptyKey]), t > 0 { u.runtimeSeconds = t * 60 }
        if let v = int(d[kIOPSVoltageKey]) { u.batteryVoltage = Double(v) / 1000 }
        u.manufacturer = d["Manufacturer"] as? String
        u.model = d["Model"] as? String ?? d["Product"] as? String
        u.serial = d[kIOPSHardwareSerialNumberKey] as? String
        u.raw = MacBattery.flatten(d)
        return u
    }
}

/// Minimal client for a Network UPS Tools server (upsd, TCP 3493): read-only, no login needed
/// for LIST UPS / LIST VAR. Blocking — call it off the main thread.
public struct NUTClient: Sendable {
    public var host: String
    public var port: UInt16
    public var timeout: TimeInterval

    public init(host: String, port: UInt16 = 3493, timeout: TimeInterval = 3) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    public enum NUTError: Error, CustomStringConvertible {
        case connect(String), protocolError(String)
        public var description: String {
            switch self {
            case .connect(let s): return "NUT connect: \(s)"
            case .protocolError(let s): return "NUT: \(s)"
            }
        }
    }

    /// Every UPS the server knows, with its variables.
    public func read() throws -> [UPSSnapshot] {
        let conn = try LineConnection(host: host, port: port, timeout: timeout)
        defer { conn.close() }
        let upsLines = try conn.list("LIST UPS")
        var out: [UPSSnapshot] = []
        for line in upsLines {
            // UPS <name> "<description>"
            let parts = NUTClient.tokenize(line)
            guard parts.count >= 2, parts[0] == "UPS" else { continue }
            let name = parts[1]
            var vars: [String: String] = [:]
            for v in try conn.list("LIST VAR \(name)") {
                let t = NUTClient.tokenize(v)
                if t.count >= 4, t[0] == "VAR" { vars[t[2]] = t[3] }
            }
            out.append(NUTClient.snapshot(ups: name, host: "\(host):\(port)", vars: vars,
                                          description: parts.count > 2 ? parts[2] : nil))
        }
        return out
    }

    /// Maps NUT standard variable names (docs/nut-names) to a snapshot.
    public static func snapshot(ups: String, host: String, vars: [String: String], description: String?) -> UPSSnapshot {
        var u = UPSSnapshot(id: "nut:\(host)/\(ups)", name: description.flatMap { $0.isEmpty ? nil : $0 } ?? ups,
                            source: "NUT \(host)")
        u.chargePercent = vars["battery.charge"].flatMap(Double.init)
        u.runtimeSeconds = vars["battery.runtime"].flatMap(Double.init).map { Int($0) }
        u.loadPercent = vars["ups.load"].flatMap(Double.init)
        u.inputVoltage = vars["input.voltage"].flatMap(Double.init)
        u.outputVoltage = vars["output.voltage"].flatMap(Double.init)
        u.batteryVoltage = vars["battery.voltage"].flatMap(Double.init)
        u.status = vars["ups.status"]
        if let st = u.status { u.onBattery = st.split(separator: " ").contains("OB") }
        u.manufacturer = vars["ups.mfr"] ?? vars["device.mfr"]
        u.model = vars["ups.model"] ?? vars["device.model"]
        u.serial = vars["ups.serial"] ?? vars["device.serial"]
        u.batteryDate = vars["battery.date"] ?? vars["battery.mfr.date"]
        u.raw = vars
        return u
    }

    /// Splits a NUT protocol line, honouring double quotes and backslash escapes.
    public static func tokenize(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var escape = false
        var has = false
        for ch in line {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inQuotes.toggle(); has = true; continue }
            if ch == " " && !inQuotes {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// A line-oriented TCP connection on BSD sockets, with a receive timeout.
final class LineConnection {
    private let fd: Int32
    private var buffer = Data()

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw NUTClient.NUTError.connect("cannot resolve \(host)")
        }
        defer { freeaddrinfo(res) }
        var fd: Int32 = -1
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { fd = s; break }
                Darwin.close(s)
            }
            ai = a.pointee.ai_next
        }
        guard fd >= 0 else { throw NUTClient.NUTError.connect("\(host):\(port) unreachable") }
        self.fd = fd
    }

    func close() {
        _ = send("LOGOUT")
        Darwin.close(fd)
    }

    @discardableResult
    func send(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        return bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } == bytes.count
    }

    func readLine() throws -> String {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw NUTClient.NUTError.connect("connection closed or timed out") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Sends a LIST command and returns the lines between BEGIN LIST and END LIST.
    func list(_ command: String) throws -> [String] {
        guard send(command) else { throw NUTClient.NUTError.connect("send failed") }
        var lines: [String] = []
        let first = try readLine()
        if first.hasPrefix("ERR") { throw NUTClient.NUTError.protocolError(first) }
        guard first.hasPrefix("BEGIN LIST") else { throw NUTClient.NUTError.protocolError("unexpected: \(first)") }
        while true {
            let l = try readLine()
            if l.hasPrefix("END LIST") { break }
            lines.append(l)
        }
        return lines
    }
}
