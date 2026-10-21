import Foundation

/// iPhone / iPad batteries, over USB or Wi-Fi, through Apple's own MobileDevice framework
/// (the one Finder uses to talk to devices). It is loaded at run time with dlopen: when it is
/// missing or its interface changes, iOS support is simply reported as unavailable.
///
/// Protocol: lockdown session → `com.apple.mobile.battery` domain (charge), then the
/// `com.apple.mobile.diagnostics_relay` service, request `IORegistry` for the battery entry —
/// the same request open-source tools send (`idevicediagnostics ioregentry AppleSmartBattery`).
/// The device must already trust this Mac (tap "Trust" once over USB). For Wi-Fi, enable
/// "Show this iPhone when on Wi-Fi" in Finder once.
public final class IOSDevices: @unchecked Sendable {
    public static let shared = IOSDevices()

    public enum Interface: Int, Sendable { case unknown = 0, usb = 1, wifi = 2 }

    // MobileDevice C entry points.
    private typealias NotifyCB = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias Subscribe = @convention(c) (NotifyCB, UInt32, UInt32, UnsafeMutableRawPointer?,
                                                  UnsafeMutablePointer<UnsafeMutableRawPointer?>, CFDictionary?) -> Int32
    private typealias Unsubscribe = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    private typealias DevFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias CopyValue = @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias CopyID = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
    private typealias StartService = @convention(c) (UnsafeMutableRawPointer, CFString, CFDictionary?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias SendMsg = @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32
    private typealias RecvMsg = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>,
                                                UnsafeMutablePointer<Int>?) -> Int32
    private typealias ConnFn = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> Void

    private struct API {
        var subscribe: Subscribe
        var unsubscribe: Unsubscribe
        var connect: DevFn
        var disconnect: DevFn
        var isPaired: DevFn
        var validatePairing: DevFn
        var startSession: DevFn
        var stopSession: DevFn
        var copyValue: CopyValue
        var copyID: CopyID
        var interfaceType: DevFn
        var startService: StartService
        var send: SendMsg
        var receive: RecvMsg
        var invalidate: ConnFn
        var retain: Retain
        var release: Retain
    }

    private let api: API?
    private let lock = NSLock()
    private var found: [String: (UnsafeMutableRawPointer, Interface)] = [:]

    public var isAvailable: Bool { api != nil }

    private init() {
        let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let h = dlopen(path, RTLD_NOW) else { api = nil; return }
        func sym<T>(_ n: String, _: T.Type) -> T? {
            guard let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let sub = sym("AMDeviceNotificationSubscribeWithOptions", Subscribe.self),
              let unsub = sym("AMDeviceNotificationUnsubscribe", Unsubscribe.self),
              let con = sym("AMDeviceConnect", DevFn.self),
              let dis = sym("AMDeviceDisconnect", DevFn.self),
              let paired = sym("AMDeviceIsPaired", DevFn.self),
              let valid = sym("AMDeviceValidatePairing", DevFn.self),
              let start = sym("AMDeviceStartSession", DevFn.self),
              let stop = sym("AMDeviceStopSession", DevFn.self),
              let copy = sym("AMDeviceCopyValue", CopyValue.self),
              let cid = sym("AMDeviceCopyDeviceIdentifier", CopyID.self),
              let itf = sym("AMDeviceGetInterfaceType", DevFn.self),
              let svc = sym("AMDeviceSecureStartService", StartService.self),
              let snd = sym("AMDServiceConnectionSendMessage", SendMsg.self),
              let rcv = sym("AMDServiceConnectionReceiveMessage", RecvMsg.self),
              let inv = sym("AMDServiceConnectionInvalidate", ConnFn.self),
              let ret = sym("AMDeviceRetain", Retain.self),
              let rel = sym("AMDeviceRelease", Retain.self)
        else { api = nil; return }
        api = API(subscribe: sub, unsubscribe: unsub, connect: con, disconnect: dis, isPaired: paired,
                  validatePairing: valid, startSession: start, stopSession: stop, copyValue: copy,
                  copyID: cid, interfaceType: itf, startService: svc, send: snd, receive: rcv,
                  invalidate: inv, retain: ret, release: rel)
    }

    /// Discovers devices for `timeout` seconds, then reads each one. Blocking: call it off the
    /// main thread. A device seen over both USB and Wi-Fi is read once, preferring USB.
    public func readAll(timeout: TimeInterval = 6) -> [BatterySnapshot] {
        guard let api else { return [] }
        lock.lock()
        found = [:]
        lock.unlock()

        let cb: NotifyCB = { info, ctx in
            guard let info, let ctx else { return }
            let me = Unmanaged<IOSDevices>.fromOpaque(ctx).takeUnretainedValue()
            let dev = info.load(as: UnsafeMutableRawPointer?.self)
            let msg = info.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer?>.size, as: UInt32.self)
            guard let dev, msg == 1 else { return }   // 1 = connected
            me.register(dev)
        }
        var note: UnsafeMutableRawPointer?
        let options = ["NotificationOptionSearchForPairedDevices": true] as CFDictionary
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard api.subscribe(cb, 0, 0, ctx, &note, options) == 0 else { return [] }
        CFRunLoopRunInMode(.defaultMode, timeout, false)
        _ = api.unsubscribe(note)

        lock.lock()
        let devices = found
        found = [:]
        lock.unlock()

        var out: [BatterySnapshot] = []
        for (_, (dev, itf)) in devices {
            if let s = read(dev, interface: itf) { out.append(s) }
            api.release(dev)
        }
        return out.sorted { $0.deviceName < $1.deviceName }
    }

    private func register(_ dev: UnsafeMutableRawPointer) {
        guard let api else { return }
        let id = api.copyID(dev)?.takeRetainedValue() as String? ?? UUID().uuidString
        let itf = Interface(rawValue: Int(api.interfaceType(dev))) ?? .unknown
        lock.lock(); defer { lock.unlock() }
        if let existing = found[id], existing.1 == .usb { return }
        if let existing = found[id] { api.release(existing.0) }
        api.retain(dev)
        found[id] = (dev, itf)
    }

    private func read(_ dev: UnsafeMutableRawPointer, interface: Interface) -> BatterySnapshot? {
        guard let api else { return nil }
        guard api.connect(dev) == 0 else { return nil }
        defer { _ = api.disconnect(dev) }
        guard api.isPaired(dev) != 0, api.validatePairing(dev) == 0, api.startSession(dev) == 0 else { return nil }
        defer { _ = api.stopSession(dev) }

        func value(_ domain: String?, _ key: String?) -> Any? {
            api.copyValue(dev, domain as CFString?, key as CFString?)?.takeRetainedValue()
        }
        let udid = value(nil, "UniqueDeviceID") as? String ?? api.copyID(dev)?.takeRetainedValue() as String? ?? "?"
        let name = value(nil, "DeviceName") as? String ?? "iOS device"
        var s = BatterySnapshot(kind: .ios, deviceID: udid, deviceName: name)
        s.model = value(nil, "ProductType") as? String
        if let v = value(nil, "ProductVersion") as? String {
            let os = (value(nil, "DeviceClass") as? String) == "iPad" ? "iPadOS" : "iOS"
            s.osVersion = "\(os) \(v)"
        }
        s.deviceSerial = value(nil, "SerialNumber") as? String
        var raw: [String: String] = ["Interface": interface == .wifi ? "Wi-Fi" : "USB"]
        if let battery = value("com.apple.mobile.battery", nil) as? [String: Any] {
            if let c = int(battery["BatteryCurrentCapacity"]) { s.chargePercent = Double(c) }
            s.isCharging = bool(battery["BatteryIsCharging"])
            s.externalConnected = bool(battery["ExternalConnected"]) ?? bool(battery["ExternalChargeCapable"])
            s.fullyCharged = bool(battery["FullyCharged"])
            raw.merge(MacBattery.flatten(battery, prefix: "lockdown")) { a, _ in a }
        }

        if let reg = diagnosticsBattery(dev) {
            let percent = s.chargePercent
            MacBattery.fill(&s, from: reg)
            // The lockdown percentage is what the device's status bar shows.
            if let percent { s.chargePercent = percent }
            raw.merge(s.raw) { a, _ in a }
        }
        s.raw = raw
        return s
    }

    /// Asks the diagnostics relay for the battery's IORegistry entry. Newer devices name it
    /// differently; each name is tried in turn.
    private func diagnosticsBattery(_ dev: UnsafeMutableRawPointer) -> [String: Any]? {
        guard let api else { return nil }
        var conn: UnsafeMutableRawPointer?
        guard api.startService(dev, "com.apple.mobile.diagnostics_relay" as CFString, nil, &conn) == 0,
              let conn else { return nil }
        defer {
            _ = api.send(conn, ["Request": "Goodbye"] as CFDictionary, 200)
            api.invalidate(conn)
        }
        let requests: [[String: String]] = [
            ["Request": "IORegistry", "EntryClass": "AppleSmartBattery"],
            ["Request": "IORegistry", "EntryClass": "IOPMPowerSource"],
            ["Request": "IORegistry", "EntryName": "AppleARMPMUCharger"],
        ]
        for req in requests {
            guard api.send(conn, req as CFDictionary, 200) == 0 else { continue }   // 200 = binary plist
            var reply: Unmanaged<CFPropertyList>?
            guard api.receive(conn, &reply, nil) == 0,
                  let dict = reply?.takeRetainedValue() as? [String: Any],
                  (dict["Status"] as? String) == "Success",
                  let diag = dict["Diagnostics"] as? [String: Any],
                  let reg = diag["IORegistry"] as? [String: Any],
                  reg["DesignCapacity"] != nil || reg["CycleCount"] != nil
            else { continue }
            return reg
        }
        return nil
    }
}
