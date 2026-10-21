import Foundation
import Security

/// Publishes readings to a Prometheus Pushgateway (text exposition format, PUT per instance).
public struct Pushgateway: Sendable {
    public var baseURL: URL
    public var user: String?
    public var password: String?
    public var job: String
    public var instance: String

    public init(baseURL: URL, user: String?, password: String?, job: String = "papayapower", instance: String) {
        self.baseURL = baseURL
        self.user = user
        self.password = password
        self.job = job
        self.instance = instance
    }

    /// Prometheus text for a set of readings. Pure, so it can be tested.
    public static func exposition(battery: [BatterySnapshot], ups: [UPSSnapshot]) -> String {
        var lines: [String] = []
        var declared = Set<String>()
        func metric(_ name: String, _ help: String, _ labels: [String: String], _ value: Double?) {
            guard let value, value.isFinite else { return }
            if !declared.contains(name) {
                lines.append("# HELP \(name) \(help)")
                lines.append("# TYPE \(name) gauge")
                declared.insert(name)
            }
            let l = labels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\"\(escape($0.value))\"" }.joined(separator: ",")
            lines.append("\(name){\(l)} \(value)")
        }
        for b in battery {
            let lab = ["device": b.deviceName, "device_id": b.deviceID, "kind": b.kind.rawValue]
            metric("papaya_battery_charge_percent", "Battery charge in percent.", lab, b.chargePercent)
            metric("papaya_battery_health_ratio", "Full charge capacity / design capacity.", lab, b.health)
            metric("papaya_battery_cycles", "Charge cycle count.", lab, b.cycleCount.map(Double.init))
            metric("papaya_battery_full_charge_mah", "Full charge capacity in mAh.", lab, b.fullChargeCapacity.map(Double.init))
            metric("papaya_battery_design_mah", "Design capacity in mAh.", lab, b.designCapacity.map(Double.init))
            metric("papaya_battery_temperature_celsius", "Battery temperature.", lab, b.temperature)
            metric("papaya_battery_power_watts", "Power into (+) or out of (-) the battery.", lab, b.batteryWatts)
            metric("papaya_battery_external_power", "1 when on external power.", lab, b.externalConnected.map { $0 ? 1 : 0 })
            metric("papaya_battery_reading_timestamp_seconds", "Time of the reading.", lab, b.timestamp.timeIntervalSince1970)
        }
        for u in ups {
            let lab = ["ups": u.name, "ups_id": u.id]
            metric("papaya_ups_charge_percent", "UPS battery charge in percent.", lab, u.chargePercent)
            metric("papaya_ups_on_battery", "1 when the UPS runs on battery.", lab, u.onBattery.map { $0 ? 1 : 0 })
            metric("papaya_ups_low_battery", "1 when the UPS reports low battery.", lab, u.lowBattery ? 1 : 0)
            metric("papaya_ups_runtime_seconds", "Estimated runtime on battery.", lab, u.runtimeSeconds.map(Double.init))
            metric("papaya_ups_load_percent", "UPS load in percent.", lab, u.loadPercent)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// PUTs the readings, replacing this instance's previous group. Returns the HTTP status.
    public func push(battery: [BatterySnapshot], ups: [UPSSnapshot]) async throws -> Int {
        let path = "metrics/job/\(pathEscape(job))/instance/\(pathEscape(instance))"
        var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 10)
        req.httpMethod = "PUT"
        req.setValue("text/plain; version=0.0.4", forHTTPHeaderField: "Content-Type")
        if let user, let password, !user.isEmpty {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data(Self.exposition(battery: battery, ups: ups).utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? s
    }
}

/// Generic-password items in the login keychain, used for the Pushgateway password.
public enum Keychain {
    static let service = "PapayaPower"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
