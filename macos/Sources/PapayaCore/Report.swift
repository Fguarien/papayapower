import Foundation

/// Printable reports. A template is plain HTML with `$NAME` placeholders; users can supply
/// their own. Placeholder names follow the convention battery tools already use for reports
/// (`$MAC_BATTERY_HEALTH_PERCENT`, `$IOS_BATTERY_CYCLECOUNT`…), so existing templates keep working.
public enum Report {

    public static func variables(for s: BatterySnapshot, appVersion: String) -> [String: String] {
        let p = s.kind == .ios ? "IOS" : "MAC"
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        let now = DateFormatter.localizedString(from: s.timestamp, dateStyle: .long, timeStyle: .short)
        let v: [String: String] = [
            "REPORT_CREATION": now,
            "REPORT_VERSION": "PapayaPower \(appVersion)",
            "MAC_MODEL": MachineInfo.current.displayName + " (\(MachineInfo.current.model))",
            "\(p)_MODEL": s.kind == .ios ? (s.model ?? s.deviceName) : (MachineInfo.current.displayName + " (\(MachineInfo.current.model))"),
            "\(p)_SERIAL": s.deviceSerial ?? "—",
            "\(p)_MANUFACTURE_DATE": "—",
            "\(p)_BATTERY_CYCLECOUNT": s.cycleCount.map(String.init) ?? "—",
            "\(p)_BATTERY_HEALTH_PERCENT": s.health.map { Format.percent($0 * 100) } ?? "—",
            "\(p)_BATTERY_MAH": [s.fullChargeCapacity, s.designCapacity].contains(where: { $0 == nil }) ? "—"
                : "\(s.fullChargeCapacity!) / \(s.designCapacity!) mAh",
            "\(p)_BATTERY_MANUFACTURE_DATE": s.batteryManufactureDate.map { df.string(from: $0) } ?? "—",
            "\(p)_BATTERY_SERIAL": s.batterySerial ?? "—",
            "\(p)_BATTERY_MANUFACTURER": s.batteryManufacturer ?? "—",
            "\(p)_BATTERY_FAILURE": s.permanentFailure == true ? "Yes" : "No",
            "DEVICE_NAME": s.deviceName,
            "OS_VERSION": s.osVersion ?? "—",
            "BATTERY_TEMPERATURE": s.temperature.map { Format.temperature($0) } ?? "—",
        ]
        return v
    }

    /// Replaces `$NAME` placeholders, longest names first so `$X_Y` never eats `$X_YZ`.
    public static func render(template: String, variables: [String: String]) -> String {
        var out = template
        for key in variables.keys.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: "$" + key, with: htmlEscape(variables[key]!))
        }
        return out
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func defaultTemplate(kind: DeviceKind) -> String {
        let p = kind == .ios ? "IOS" : "MAC"
        let title = kind == .ios ? "iPhone / iPad battery report" : "Mac battery report"
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        body { font: 13px -apple-system, Helvetica, sans-serif; color: #1d1d1f; margin: 40px; }
        h1 { font-size: 22px; margin: 0 0 4px; color: #e8590c; }
        .sub { color: #6e6e73; margin-bottom: 24px; }
        table { border-collapse: collapse; width: 100%; max-width: 640px; }
        td { padding: 7px 10px; border-bottom: 1px solid #e5e5ea; }
        td:first-child { color: #6e6e73; width: 45%; }
        .foot { margin-top: 32px; color: #8e8e93; font-size: 11px; }
        </style></head><body>
        <h1>\(title)</h1>
        <div class="sub">$DEVICE_NAME · $REPORT_CREATION</div>
        <table>
        <tr><td>Model</td><td>$\(p)_MODEL</td></tr>
        <tr><td>Serial number</td><td>$\(p)_SERIAL</td></tr>
        <tr><td>System</td><td>$OS_VERSION</td></tr>
        <tr><td>Battery health</td><td><b>$\(p)_BATTERY_HEALTH_PERCENT</b></td></tr>
        <tr><td>Full charge / design capacity</td><td>$\(p)_BATTERY_MAH</td></tr>
        <tr><td>Charge cycles</td><td>$\(p)_BATTERY_CYCLECOUNT</td></tr>
        <tr><td>Temperature</td><td>$BATTERY_TEMPERATURE</td></tr>
        <tr><td>Battery manufacturer</td><td>$\(p)_BATTERY_MANUFACTURER</td></tr>
        <tr><td>Battery manufacture date</td><td>$\(p)_BATTERY_MANUFACTURE_DATE</td></tr>
        <tr><td>Battery serial</td><td>$\(p)_BATTERY_SERIAL</td></tr>
        <tr><td>Permanent failure</td><td>$\(p)_BATTERY_FAILURE</td></tr>
        </table>
        <div class="foot">$REPORT_VERSION</div>
        </body></html>
        """
    }
}

public enum Format {
    public static func percent(_ v: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f %%", v)
    }

    public static func temperature(_ c: Double) -> String {
        let m = Measurement(value: c, unit: UnitTemperature.celsius)
        let f = MeasurementFormatter()
        f.numberFormatter.maximumFractionDigits = 1
        f.unitOptions = .providedUnit
        if Locale.current.measurementSystem == .us {
            return f.string(from: m.converted(to: .fahrenheit))
        }
        return f.string(from: m)
    }

    public static func minutes(_ m: Int) -> String {
        "\(m / 60):" + String(format: "%02d", m % 60)
    }

    public static func watts(_ w: Double) -> String {
        String(format: "%.1f W", w)
    }

    public static func mah(_ v: Int) -> String { "\(v) mAh" }
}
