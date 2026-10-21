import Foundation
import IOKit
import IOKit.ps

/// Reads the internal battery of this Mac from the IORegistry (`AppleSmartBattery`), the
/// documented place every battery tool reads (`ioreg -rc AppleSmartBattery`).
public enum MacBattery {

    /// The battery's IORegistry properties, or nil on a Mac without a battery.
    public static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    /// Reads the battery now. Returns nil when the Mac has no battery (Mac Pro, mini, iMac…).
    public static func read() -> BatterySnapshot? {
        guard let p = registryProperties() else { return nil }
        let machine = MachineInfo.current
        // Named after the computer ("Arya’s MacBook Air"), like iPhones: two Macs of the same
        // family stay distinct in the history and in Prometheus labels.
        var s = BatterySnapshot(kind: .mac, deviceID: machine.serial ?? machine.hostName,
                                deviceName: machine.hostName)
        s.model = machine.model
        s.marketingName = machine.marketingName
        s.osVersion = machine.osVersion
        s.deviceSerial = machine.serial

        fill(&s, from: p)
        // The percentage shown by macOS itself, when available, wins (it is what the user sees).
        if let ps = internalPowerSourcePercent() { s.chargePercent = ps }
        return s
    }


    /// Fills a snapshot from an `AppleSmartBattery` property dictionary. Shared by the Mac reader
    /// and the iOS reader (the diagnostics relay returns the same IORegistry entry).
    public static func fill(_ s: inout BatterySnapshot, from p: [String: Any]) {
        // Apple silicon reports CurrentCapacity/MaxCapacity as percentages and the mAh values
        // under AppleRaw*; Intel reports mAh directly. Prefer the raw keys when present.
        let rawMax = int(p["AppleRawMaxCapacity"])
        let rawCur = int(p["AppleRawCurrentCapacity"])
        let maxCap = int(p["NominalChargeCapacity"]) ?? int(p["MaxCapacity"])
        let curCap = int(p["CurrentCapacity"])
        s.fullChargeCapacity = rawMax ?? maxCap
        s.currentCapacity = rawCur ?? curCap
        s.designCapacity = int(p["DesignCapacity"])
        if let cur = s.currentCapacity, let full = s.fullChargeCapacity, full > 0 {
            s.chargePercent = min(100, Double(cur) / Double(full) * 100)
        }

        s.cycleCount = int(p["CycleCount"])
        s.designCycleCount = int(p["DesignCycleCount9C"]) ?? int(p["DesignCycleCount"])
        if let t = int(p["Temperature"]) { s.temperature = Double(t) / 100 }
        s.voltage = int(p["Voltage"]) ?? int(p["AppleRawBatteryVoltage"])
        s.amperage = int(p["InstantAmperage"]) ?? int(p["Amperage"])
        s.isCharging = bool(p["IsCharging"])
        s.externalConnected = bool(p["ExternalConnected"])
        s.fullyCharged = bool(p["FullyCharged"])
        s.timeToEmpty = minutes(p["AvgTimeToEmpty"])
        s.timeToFull = minutes(p["AvgTimeToFull"])
        if s.isCharging == true { s.timeToEmpty = nil } else { s.timeToFull = nil }

        let adapter = (p["AdapterDetails"] as? [String: Any])
            ?? (p["AppleRawAdapterDetails"] as? [[String: Any]])?.first
        if let a = adapter {
            s.adapterWatts = int(a["Watts"])
            s.adapterName = (a["Name"] as? String) ?? (a["Description"] as? String)
        }

        let batteryData = p["BatteryData"] as? [String: Any]
        s.cellVoltages = (batteryData?["CellVoltage"] as? [Any])?.compactMap(int)
        s.batterySerial = (p["BatterySerialNumber"] as? String) ?? (p["Serial"] as? String)
        s.batteryManufacturer = (p["Manufacturer"] as? String)
            ?? (batteryData?["Manufacturer"] as? String) ?? manufacturerFromData(batteryData)
        s.batteryModel = (p["DeviceName"] as? String) ?? (batteryData?["DeviceName"] as? String)
        s.batteryManufactureDate = manufactureDate(p, batteryData)
        if let pf = int(p["PermanentFailureStatus"]) { s.permanentFailure = pf != 0 }
        s.lifetime = lifetime(batteryData?["LifetimeData"] as? [String: Any])

        s.raw = flatten(p)
    }

    // MARK: - Helpers

    /// Battery percentage as macOS displays it (IOPowerSources), if there is an internal battery.
    public static func internalPowerSourcePercent() -> Double? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = int(d[kIOPSCurrentCapacityKey]), let max = int(d[kIOPSMaxCapacityKey]), max > 0
            else { continue }
            return Double(cur) / Double(max) * 100
        }
        return nil
    }

    static func lifetime(_ d: [String: Any]?) -> LifetimeData? {
        guard let d else { return nil }
        var l = LifetimeData()
        // Temperatures in LifetimeData are in tenths of a degree on the gauges we measured;
        // values above 200 are taken as tenths, below as whole degrees.
        func temp(_ k: String) -> Double? {
            guard let v = int(d[k]) else { return nil }
            return abs(v) > 200 ? Double(v) / 10 : Double(v)
        }
        l.maximumTemperature = temp("MaximumTemperature")
        l.minimumTemperature = temp("MinimumTemperature")
        l.averageTemperature = temp("AverageTemperature")
        l.maximumChargeCurrent = int(d["MaximumChargeCurrent"])
        if let v = int(d["MaximumDischargeCurrent"]) { l.maximumDischargeCurrent = abs(v) }
        l.maximumPackVoltage = int(d["MaximumPackVoltage"])
        l.minimumPackVoltage = int(d["MinimumPackVoltage"])
        l.totalOperatingTime = int(d["TotalOperatingTime"])
        return l.isEmpty ? nil : l
    }

    /// Smart Battery Data spec date: day | month << 5 | (year − 1980) << 9.
    static func manufactureDate(_ p: [String: Any], _ bd: [String: Any]?) -> Date? {
        if let v = int(p["ManufactureDate"]) ?? int(bd?["ManufactureDate"]), v > 0, v < 0x10000 {
            var c = DateComponents()
            c.day = v & 0x1F
            c.month = (v >> 5) & 0x0F
            c.year = 1980 + (v >> 9)
            guard let day = c.day, let month = c.month, (1...31).contains(day), (1...12).contains(month) else { return nil }
            return Calendar(identifier: .gregorian).date(from: c)
        }
        return nil
    }

    static func manufacturerFromData(_ bd: [String: Any]?) -> String? {
        guard let data = bd?["ManufacturerData"] as? Data, data.count > 0 else { return nil }
        let s = String(decoding: data.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// Minutes from an IORegistry field where 65535 means "unknown / still computing".
    static func minutes(_ v: Any?) -> Int? {
        guard let m = int(v), m > 0, m < 65535 else { return nil }
        return m
    }

    /// Flattens nested dictionaries to "Parent.Child" keys, for the advanced viewer.
    public static func flatten(_ d: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in d {
            let key = prefix.isEmpty ? k : "\(prefix).\(k)"
            switch v {
            case let sub as [String: Any]:
                out.merge(flatten(sub, prefix: key)) { a, _ in a }
            case let arr as [Any]:
                if arr.allSatisfy({ $0 is [String: Any] }) {
                    for (i, e) in arr.enumerated() {
                        out.merge(flatten(e as! [String: Any], prefix: "\(key)[\(i)]")) { a, _ in a }
                    }
                } else {
                    out[key] = arr.map { describe($0) }.joined(separator: ", ")
                }
            default:
                out[key] = describe(v)
            }
        }
        return out
    }

    static func describe(_ v: Any) -> String {
        switch v {
        case let d as Data:
            return d.count <= 64 ? d.map { String(format: "%02x", $0) }.joined() : "<\(d.count) bytes>"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            return "\(v)"
        }
    }
}

/// Integer from an IORegistry value. Negative numbers arrive as 64-bit two's complement.
func int(_ v: Any?) -> Int? {
    switch v {
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        return Int(truncatingIfNeeded: n.int64Value)
    case let i as Int: return i
    case let s as String: return Int(s)
    default: return nil
    }
}

func bool(_ v: Any?) -> Bool? {
    switch v {
    case let n as NSNumber: return n.boolValue
    case let b as Bool: return b
    default: return nil
    }
}
