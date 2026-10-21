import Foundation

/// What kind of device a reading comes from.
public enum DeviceKind: String, Codable, Sendable {
    case mac
    case ios
    case ups
}

/// Minimum, maximum and average values recorded by the battery's gas gauge over its life.
public struct LifetimeData: Codable, Equatable, Sendable {
    public var maximumTemperature: Double?      // °C
    public var minimumTemperature: Double?      // °C
    public var averageTemperature: Double?      // °C
    public var maximumChargeCurrent: Int?       // mA
    public var maximumDischargeCurrent: Int?    // mA (positive number)
    public var maximumPackVoltage: Int?         // mV
    public var minimumPackVoltage: Int?         // mV
    public var totalOperatingTime: Int?         // hours

    public init() {}

    public var isEmpty: Bool {
        self == LifetimeData()
    }
}

/// One reading of one battery. Every field is optional: what a gauge reports varies by model.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var kind: DeviceKind
    public var deviceID: String               // stable id (machine or device serial)
    public var deviceName: String             // "MacBook Air", "Sasha's iPhone"…
    public var model: String?                 // hw.model / ProductType
    public var marketingName: String?         // "11\" MacBook Air (Early 2015)"
    public var osVersion: String?
    public var deviceSerial: String?
    public var timestamp: Date

    public var chargePercent: Double?         // 0…100
    public var currentCapacity: Int?          // mAh
    public var fullChargeCapacity: Int?       // mAh
    public var designCapacity: Int?           // mAh
    public var cycleCount: Int?
    public var designCycleCount: Int?
    public var temperature: Double?           // °C
    public var voltage: Int?                  // mV
    public var amperage: Int?                 // mA, negative = discharging
    public var isCharging: Bool?
    public var externalConnected: Bool?
    public var fullyCharged: Bool?
    public var timeToEmpty: Int?              // minutes
    public var timeToFull: Int?               // minutes
    public var adapterWatts: Int?
    public var adapterName: String?
    public var cellVoltages: [Int]?           // mV
    public var batterySerial: String?
    public var batteryManufacturer: String?
    public var batteryModel: String?
    public var batteryManufactureDate: Date?
    public var permanentFailure: Bool?
    public var lifetime: LifetimeData?

    /// Every raw key the source exposed, stringified, for the advanced viewer.
    public var raw: [String: String]

    public init(kind: DeviceKind, deviceID: String, deviceName: String, timestamp: Date = Date()) {
        self.kind = kind
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
        self.raw = [:]
    }

    /// Full charge capacity divided by design capacity, 0…1 (may exceed 1 on a new battery).
    public var health: Double? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(full) / Double(design)
    }

    /// Power flowing in (+) or out (−) of the battery, in watts.
    public var batteryWatts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }

    /// Manufacture date of the device itself (from a dated serial number).
    public var deviceManufactureDate: Date? {
        kind == .mac ? MachineInfo.manufactureDate(serial: deviceSerial) : nil
    }

    public var batteryAge: DateComponents? {
        guard let d = batteryManufactureDate else { return nil }
        return Calendar.current.dateComponents([.year, .month], from: d, to: timestamp)
    }
}

/// A UPS seen by macOS (USB HID) or by a NUT server.
public struct UPSSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String                     // "iops:<name>" or "nut:<host>/<ups>"
    public var name: String
    public var source: String                 // "USB (macOS)" or "NUT host:port"
    public var timestamp: Date
    public var chargePercent: Double?
    public var onBattery: Bool?
    public var runtimeSeconds: Int?
    public var loadPercent: Double?
    public var inputVoltage: Double?
    public var outputVoltage: Double?
    public var batteryVoltage: Double?
    public var status: String?                // NUT ups.status (OL, OB, LB, CHRG…)
    public var manufacturer: String?
    public var model: String?
    public var serial: String?
    public var batteryDate: String?
    public var raw: [String: String]

    public init(id: String, name: String, source: String, timestamp: Date = Date()) {
        self.id = id
        self.name = name
        self.source = source
        self.timestamp = timestamp
        self.raw = [:]
    }

    public var lowBattery: Bool {
        status?.split(separator: " ").contains("LB") ?? false
    }
}
