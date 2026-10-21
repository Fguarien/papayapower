import Foundation
import SQLite3

/// One saved battery reading, as stored in the history.
public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var timestamp: Date
    public var kind: DeviceKind
    public var deviceID: String
    public var deviceName: String
    public var chargePercent: Double?
    public var cycleCount: Int?
    public var fullChargeCapacity: Int?
    public var designCapacity: Int?
    public var temperature: Double?
    public var snapshot: BatterySnapshot?

    public var health: Double? {
        guard let f = fullChargeCapacity, let d = designCapacity, d > 0 else { return nil }
        return Double(f) / Double(d)
    }
}

/// The battery history: a small SQLite file in Application Support. Thread-safe.
public final class HistoryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    public let url: URL

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PapayaPower", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.sqlite")
    }

    public init(url: URL = HistoryStore.defaultURL()) throws {
        self.url = url
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "PapayaPower", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(url.path)"])
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS reading (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                device_id TEXT NOT NULL,
                device_name TEXT NOT NULL,
                charge REAL, cycles INTEGER, full_mah INTEGER, design_mah INTEGER, temp REAL,
                snapshot TEXT
            );
            CREATE INDEX IF NOT EXISTS reading_device ON reading(device_id, ts);
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "PapayaPower", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    public func save(_ s: BatterySnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT INTO reading(ts,kind,device_id,device_name,charge,cycles,full_mah,design_mah,temp,snapshot) VALUES(?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, s.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(st, 2, s.kind.rawValue, -1, Self.transient)
        sqlite3_bind_text(st, 3, s.deviceID, -1, Self.transient)
        sqlite3_bind_text(st, 4, s.deviceName, -1, Self.transient)
        bind(st, 5, s.chargePercent)
        bind(st, 6, s.cycleCount)
        bind(st, 7, s.fullChargeCapacity)
        bind(st, 8, s.designCapacity)
        bind(st, 9, s.temperature)
        var slim = s
        slim.raw = [:]
        if let json = try? JSONEncoder().encode(slim) {
            sqlite3_bind_text(st, 10, String(decoding: json, as: UTF8.self), -1, Self.transient)
        } else {
            sqlite3_bind_null(st, 10)
        }
        return sqlite3_step(st) == SQLITE_DONE
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(st, i, Int64(v)) } else { sqlite3_bind_null(st, i) }
    }

    /// Entries, newest first, optionally for one device.
    public func entries(deviceID: String? = nil, limit: Int = 5000) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT id,ts,kind,device_id,device_name,charge,cycles,full_mah,design_mah,temp,snapshot FROM reading"
            + (deviceID == nil ? "" : " WHERE device_id = ?") + " ORDER BY ts DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var i: Int32 = 1
        if let deviceID { sqlite3_bind_text(st, i, deviceID, -1, Self.transient); i += 1 }
        sqlite3_bind_int64(st, i, Int64(limit))
        var out: [HistoryEntry] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func dbl(_ c: Int32) -> Double? { sqlite3_column_type(st, c) == SQLITE_NULL ? nil : sqlite3_column_double(st, c) }
            func num(_ c: Int32) -> Int? { sqlite3_column_type(st, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, c)) }
            func txt(_ c: Int32) -> String? { sqlite3_column_text(st, c).map { String(cString: $0) } }
            let snap = txt(10).flatMap { try? JSONDecoder().decode(BatterySnapshot.self, from: Data($0.utf8)) }
            out.append(HistoryEntry(
                id: sqlite3_column_int64(st, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                kind: DeviceKind(rawValue: txt(2) ?? "mac") ?? .mac,
                deviceID: txt(3) ?? "", deviceName: txt(4) ?? "",
                chargePercent: dbl(5), cycleCount: num(6), fullChargeCapacity: num(7),
                designCapacity: num(8), temperature: dbl(9), snapshot: snap))
        }
        return out
    }

    /// Devices present in the history: (id, name, kind), most recently seen first.
    public func devices() -> [(id: String, name: String, kind: DeviceKind)] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "SELECT device_id, device_name, kind, MAX(ts) m FROM reading GROUP BY device_id ORDER BY m DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [(String, String, DeviceKind)] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(st, 0))
            let name = String(cString: sqlite3_column_text(st, 1))
            let kind = DeviceKind(rawValue: String(cString: sqlite3_column_text(st, 2))) ?? .mac
            out.append((id, name, kind))
        }
        return out.map { (id: $0.0, name: $0.1, kind: $0.2) }
    }

    public func lastSaved(deviceID: String) -> Date? {
        entries(deviceID: deviceID, limit: 1).first?.timestamp
    }

    public func delete(ids: [Int64]) {
        lock.lock(); defer { lock.unlock() }
        for id in ids { try? exec("DELETE FROM reading WHERE id = \(id)") }
    }

    public func deleteAll(deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM reading WHERE device_id = ?", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, deviceID, -1, Self.transient)
        sqlite3_step(st)
    }

    /// CSV export (RFC 4180), oldest first.
    public func csv(deviceID: String? = nil) -> String {
        var lines = ["timestamp,kind,device_id,device_name,charge_percent,cycles,full_mah,design_mah,health_percent,temperature_c"]
        let iso = ISO8601DateFormatter()
        for e in entries(deviceID: deviceID, limit: Int.max / 2).reversed() {
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            func o<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "" }
            lines.append([iso.string(from: e.timestamp), e.kind.rawValue, q(e.deviceID), q(e.deviceName),
                          o(e.chargePercent.map { String(format: "%.1f", $0) }), o(e.cycleCount),
                          o(e.fullChargeCapacity), o(e.designCapacity),
                          o(e.health.map { String(format: "%.1f", $0 * 100) }),
                          o(e.temperature.map { String(format: "%.1f", $0) })].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
