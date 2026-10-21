import Foundation
import SwiftUI
import UserNotifications
import ServiceManagement
import PapayaCore

/// User preferences, persisted in UserDefaults.
enum Pref {
    static let refreshSeconds = "refreshSeconds"           // Int, Mac battery + local UPS
    static let iosEnabled = "iosEnabled"                   // Bool
    static let iosScanSeconds = "iosScanSeconds"           // Int
    static let menuBarEnabled = "menuBarEnabled"           // Bool
    static let menuBarStyle = "menuBarStyle"               // MenuBarStyle raw value
    static let menuBarShowIcon = "menuBarShowIcon"         // Bool
    static let menuBarSource = "menuBarSource"             // "auto" | "mac" | "ios:<id>" | "ups:<id>"
    static let autoSave = "autoSave"                       // AutoSave raw value
    static let notifyEnabled = "notifyEnabled"             // Bool
    static let notifyPercent = "notifyPercent"             // Int
    static let notifyMinutes = "notifyMinutes"             // Int (0 = off)
    static let notifyIOSPercent = "notifyIOSPercent"       // Int (0 = off)
    static let notifyUPS = "notifyUPS"                     // Bool
    static let nutHosts = "nutHosts"                       // String, comma-separated host[:port]
    static let pushEnabled = "pushEnabled"                 // Bool
    static let pushURL = "pushURL"                         // String
    static let pushUser = "pushUser"                       // String (password in Keychain)
    static let pushSeconds = "pushSeconds"                 // Int
    static let shareOnNetwork = "shareOnNetwork"           // Bool
    static let role = "role"                               // "member" | "master"
    static let networkKey = "networkKey"                   // String (optional shared key)
    static let macTemplate = "macTemplate"                 // String, path to custom HTML
    static let iosTemplate = "iosTemplate"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshSeconds: 10, iosEnabled: true, iosScanSeconds: 120,
            menuBarEnabled: true, menuBarStyle: MenuBarStyle.percent.rawValue,
            menuBarShowIcon: true, menuBarSource: "auto",
            autoSave: AutoSave.daily.rawValue,
            notifyEnabled: true, notifyPercent: 15, notifyMinutes: 0, notifyIOSPercent: 0, notifyUPS: true,
            nutHosts: "", pushEnabled: false, pushURL: "", pushUser: "", pushSeconds: 300,
            macTemplate: "", iosTemplate: "", shareOnNetwork: true, role: "member", networkKey: "",
        ])
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percent, time, watts, health, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return "Charge (%)"
        case .time: return "Time remaining"
        case .watts: return "Battery power (W)"
        case .health: return "Battery health (%)"
        case .iconOnly: return "Icon only"
        }
    }
}

enum AutoSave: String, CaseIterable, Identifiable {
    case off, daily, weekly
    var id: String { rawValue }
    var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 86_400
        case .weekly: return 7 * 86_400
        }
    }
    var label: String {
        switch self {
        case .off: return "Never"
        case .daily: return "Once a day"
        case .weekly: return "Once a week"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

    @Published var mac: BatterySnapshot?
    @Published var ios: [BatterySnapshot] = []
    @Published var ups: [UPSSnapshot] = []
    @Published var nutError: String?
    @Published var iosScanning = false
    @Published var lastPush: (Date, String)?
    @Published var historyRevision = 0
    @Published var peers: [Peer] = []

    struct Peer: Identifiable {
        var id: String { name }
        var name: String
        var readings: PeerReadings?
        var error: String?
        var lastSeen: Date?
    }

    /// Readings shared with peers, readable from the network queue.
    private let shared = SharedReadings()
    private lazy var server = PeerServer(key: { AppModel.networkKey() },
                                         provider: { [shared] in shared.get() })
    var isMaster: Bool { defaults.string(forKey: Pref.role) == "master" }
    private lazy var browser = PeerBrowser(ownName: MachineInfo.current.hostName)

    let history: HistoryStore?
    private var timers: [Timer] = []
    private var alerted = Set<String>()   // hysteresis: an alert fires once per crossing

    /// Keeps App Nap from throttling the timers of a menu-bar app with no visible window
    /// (readings, peer fetches and pushes would otherwise stall). System sleep stays allowed.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep], reason: "Battery and UPS monitoring")

    private init() {
        Pref.registerDefaults()
        history = try? HistoryStore()
        refresh()
        schedule()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if UserDefaults.standard.bool(forKey: Pref.iosEnabled) { scanIOS() }
        applyNetworkPrefs()
        // First push once peers and iOS devices had time to answer (a PUT replaces the whole
        // group: pushing before them would erase the previous values).
        Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            self.push()
        }
    }

    // MARK: - Network peers

    func applyNetworkPrefs() {
        if defaults.bool(forKey: Pref.shareOnNetwork) { server.start(name: MachineInfo.current.hostName) } else { server.stop() }
        if isMaster {
            browser.start()
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.fetchPeers() }
        } else {
            browser.stop()
            peers = []
        }
    }

    private func publishShared() {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        shared.set(PeerReadings(host: MachineInfo.current.hostName,
                                platform: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                                version: Self.version,
                                batteries: [mac].compactMap { $0 } + ios, ups: ups))
    }

    func fetchPeers() {
        guard isMaster else { return }
        let b = browser
        let key = Self.networkKey()
        Task {
            let results = await b.fetchAll(key: key)
            var byName = Dictionary(uniqueKeysWithValues: self.peers.map { ($0.name, $0) })
            for name in b.names where byName[name] == nil { byName[name] = Peer(name: name) }
            for (name, r) in results {
                var p = byName[name] ?? Peer(name: name)
                switch r {
                case .success(let readings):
                    p.readings = readings
                    p.error = nil
                    p.lastSeen = Date()
                    for bat in readings.batteries { self.autoSave(bat) }
                case .failure(let e):
                    p.error = e.localizedDescription
                }
                byName[name] = p
            }
            // Forget peers gone from Bonjour for more than a day.
            let alive = Set(b.names)
            self.peers = byName.values
                .filter { alive.contains($0.name) || Date().timeIntervalSince($0.lastSeen ?? .distantPast) < 86_400 }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var defaults: UserDefaults { .standard }

    func schedule() {
        timers.forEach { $0.invalidate() }
        timers = []
        let r = max(2, defaults.integer(forKey: Pref.refreshSeconds))
        timers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(r), repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        })
        let s = max(30, defaults.integer(forKey: Pref.iosScanSeconds))
        timers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(s), repeats: true) { _ in
            Task { @MainActor in
                if UserDefaults.standard.bool(forKey: Pref.iosEnabled) { AppModel.shared.scanIOS() }
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.fetchPeers() }
        })
        let p = max(30, defaults.integer(forKey: Pref.pushSeconds))
        timers.append(Timer.scheduledTimer(withTimeInterval: TimeInterval(p), repeats: true) { _ in
            Task { @MainActor in AppModel.shared.push() }
        })
    }

    // MARK: - Reading

    func refresh() {
        mac = MacBattery.read()
        let local = LocalUPS.read()
        let hosts = nutHosts
        if hosts.isEmpty {
            ups = local
            nutError = nil
        } else {
            Task.detached {
                var found = local
                var errs: [String] = []
                for h in hosts {
                    do { found += try h.read() } catch { errs.append("\(error)") }
                }
                let all = found
                let errors = errs
                await MainActor.run {
                    let m = AppModel.shared
                    m.ups = all
                    m.nutError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                    m.afterRefresh()
                }
            }
            return
        }
        afterRefresh()
    }

    private func afterRefresh() {
        publishShared()
        if let mac { autoSave(mac) }
        checkAlerts()
    }

    var nutHosts: [NUTClient] {
        (defaults.string(forKey: Pref.nutHosts) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { h in
                let p = h.split(separator: ":")
                return NUTClient(host: String(p[0]), port: p.count > 1 ? UInt16(p[1]) ?? 3493 : 3493)
            }
    }

    func scanIOS() {
        guard !iosScanning, IOSDevices.shared.isAvailable else { return }
        iosScanning = true
        // MobileDevice delivers its notifications on a run loop: give it a thread of its own.
        Thread.detachNewThread {
            let found = IOSDevices.shared.readAll(timeout: 6)
            DispatchQueue.main.async {
                let m = AppModel.shared
                m.iosScanning = false
                // Keep devices seen recently even if this scan missed them (Wi-Fi is lossy).
                var byID = Dictionary(uniqueKeysWithValues: m.ios.map { ($0.deviceID, $0) })
                for d in found { byID[d.deviceID] = d }
                m.ios = byID.values
                    .filter { Date().timeIntervalSince($0.timestamp) < 3600 }
                    .sorted { $0.deviceName < $1.deviceName }
                for d in found { m.autoSave(d) }
                m.publishShared()
                m.checkAlerts()
            }
        }
    }

    // MARK: - History

    private func autoSave(_ s: BatterySnapshot) {
        guard let history,
              let interval = AutoSave(rawValue: defaults.string(forKey: Pref.autoSave) ?? "")?.interval else { return }
        if let last = history.lastSaved(deviceID: s.deviceID), Date().timeIntervalSince(last) < interval { return }
        if history.save(s) { historyRevision += 1 }
    }

    func saveNow(_ s: BatterySnapshot) {
        if history?.save(s) == true { historyRevision += 1 }
    }

    // MARK: - Notifications

    private func checkAlerts() {
        guard defaults.bool(forKey: Pref.notifyEnabled) else { return }
        if let m = mac, m.externalConnected == false {
            let pct = defaults.integer(forKey: Pref.notifyPercent)
            if pct > 0, let c = m.chargePercent {
                alert(key: "mac-pct", when: c <= Double(pct), clearWhen: c > Double(pct) + 3,
                      title: "Battery low", body: "This Mac is at \(Int(c)) %.")
            }
            let mins = defaults.integer(forKey: Pref.notifyMinutes)
            if mins > 0, let t = m.timeToEmpty {
                alert(key: "mac-min", when: t <= mins, clearWhen: t > mins + 5,
                      title: "Battery low", body: "About \(Format.minutes(t)) of battery left.")
            }
        } else {
            alerted.remove("mac-pct")
            alerted.remove("mac-min")
        }
        let iosPct = defaults.integer(forKey: Pref.notifyIOSPercent)
        if iosPct > 0 {
            for d in ios {
                guard let c = d.chargePercent else { continue }
                alert(key: "ios-\(d.deviceID)", when: c <= Double(iosPct) && d.isCharging != true,
                      clearWhen: c > Double(iosPct) + 3 || d.isCharging == true,
                      title: "\(d.deviceName) battery low", body: "\(d.deviceName) is at \(Int(c)) %.")
            }
        }
        if defaults.bool(forKey: Pref.notifyUPS) {
            for u in ups {
                alert(key: "ups-ob-\(u.id)", when: u.onBattery == true, clearWhen: u.onBattery == false,
                      title: "\(u.name): on battery",
                      body: "Mains power lost." + (u.runtimeSeconds.map { " Runtime ≈ \(Format.minutes($0 / 60))." } ?? ""))
                alert(key: "ups-lb-\(u.id)", when: u.lowBattery, clearWhen: !u.lowBattery,
                      title: "\(u.name): battery low", body: "The UPS reports a low battery.")
            }
        }
    }

    /// Fires once when `when` becomes true; re-arms only when `clearWhen` holds.
    private func alert(key: String, when: Bool, clearWhen: Bool, title: String, body: String) {
        if when, !alerted.contains(key) {
            alerted.insert(key)
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + UUID().uuidString,
                                                                         content: c, trigger: nil))
        } else if clearWhen {
            alerted.remove(key)
        }
    }

    // MARK: - Pushgateway

    func push() {
        guard defaults.bool(forKey: Pref.pushEnabled),
              let url = URL(string: defaults.string(forKey: Pref.pushURL) ?? ""), url.scheme != nil else { return }
        let user = defaults.string(forKey: Pref.pushUser)
        let gw = Pushgateway(baseURL: url, user: user, password: Self.pushPassword(),
                             instance: MachineInfo.current.hostName)
        // This Mac, its iOS devices, and everything its network peers reported recently.
        let fresh = peers.compactMap { $0.readings }.filter { Date().timeIntervalSince($0.timestamp) < 900 }
        let battery = [mac].compactMap { $0 } + ios + fresh.flatMap { $0.batteries }
        let ups = self.ups + fresh.flatMap { $0.ups }
        guard !battery.isEmpty || !ups.isEmpty else {
            lastPush = (Date(), "skipped: nothing to publish")
            return
        }
        Task {
            let result: String
            do {
                let code = try await gw.push(battery: battery, ups: ups)
                result = (200..<300).contains(code) ? "OK (\(code))" : "HTTP \(code)"
            } catch {
                result = error.localizedDescription
            }
            self.lastPush = (Date(), result)
        }
    }

    // MARK: - Menu bar

    /// The device the menu bar item follows. "auto" = this Mac's battery, else a UPS on
    /// battery, else the first UPS, else the first iPhone/iPad.
    func menuBarSubject(source: String) -> MenuBarSubject? {
        func fromBattery(_ b: BatterySnapshot) -> MenuBarSubject {
            MenuBarSubject(percent: b.chargePercent, charging: b.isCharging == true,
                           plugged: b.externalConnected == true && b.isCharging != true, upsOnBattery: false,
                           timeMinutes: b.isCharging == true ? b.timeToFull : b.timeToEmpty,
                           watts: b.batteryWatts, health: b.health)
        }
        func fromUPS(_ u: UPSSnapshot) -> MenuBarSubject {
            MenuBarSubject(percent: u.chargePercent, charging: false, plugged: u.onBattery != true,
                           upsOnBattery: u.onBattery == true, timeMinutes: u.runtimeSeconds.map { $0 / 60 },
                           watts: nil, health: nil)
        }
        if source.hasPrefix("ios:"), let d = ios.first(where: { "ios:" + $0.deviceID == source }) { return fromBattery(d) }
        if source.hasPrefix("ups:"), let u = ups.first(where: { "ups:" + $0.id == source }) { return fromUPS(u) }
        if source == "mac", let m = mac { return fromBattery(m) }
        if let m = mac { return fromBattery(m) }
        if let u = ups.first(where: { $0.onBattery == true }) ?? ups.first { return fromUPS(u) }
        if let d = ios.first { return fromBattery(d) }
        return nil
    }

    /// Keychain first; else a 0600 file next to the history (lets an administrator provision
    /// the password over SSH without it ever appearing in a command line).
    static func pushPassword() -> String? {
        if let k = Keychain.get("pushgateway"), !k.isEmpty { return k }
        let f = HistoryStore.defaultURL().deletingLastPathComponent().appendingPathComponent("pushgateway.secret")
        return (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Settings first; else `network.key` next to the history, else the machine-wide one.
    nonisolated static func networkKey() -> String {
        if let k = UserDefaults.standard.string(forKey: Pref.networkKey), !k.isEmpty { return k }
        let files = [HistoryStore.defaultURL().deletingLastPathComponent().appendingPathComponent("network.key"),
                     URL(fileURLWithPath: "/Users/Shared/PapayaPower/network.key")]   // machine-wide, set by an admin
        for f in files {
            let k = ((try? String(contentsOf: f, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { return k }
        }
        return ""
    }

    // MARK: - Login item

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("PapayaPower: login item: \(error)")
            }
            objectWillChange.send()
        }
    }
}

/// Lock-protected copy of this Mac's readings for the peer server queue.
final class SharedReadings: @unchecked Sendable {
    private var value: PeerReadings?
    private let lock = NSLock()
    func get() -> PeerReadings? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: PeerReadings) { lock.lock(); value = v; lock.unlock() }
}
