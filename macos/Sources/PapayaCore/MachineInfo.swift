import Foundation
import IOKit

/// Identity of this Mac: model identifier, marketing name, serial, macOS version.
public struct MachineInfo: Sendable {
    public var model: String            // "MacBookAir7,1"
    public var productName: String?     // "MacBook Air (M5, 2026)" on Apple silicon
    public var serial: String?
    public var hostName: String
    public var osVersion: String

    public var displayName: String {
        productName ?? Self.family(of: model)
    }

    /// "11\" MacBook Air (Early 2015)", from the table macOS ships in ServerInformation.framework.
    public var marketingName: String? {
        if let p = productName { return p }
        let path = "/System/Library/PrivateFrameworks/ServerInformation.framework/Resources/en.lproj/SIMachineAttributes.plist"
        guard let d = NSDictionary(contentsOfFile: path) as? [String: Any],
              let m = d[model] as? [String: Any],
              let loc = m["_LOCALIZABLE_"] as? [String: Any] else { return nil }
        return loc["marketingModel"] as? String
    }

    /// Manufacture date encoded in a pre-2021 12-character serial (4th char = year/half,
    /// 5th = week). Randomised serials (Apple silicon era) carry no date: nil.
    public var manufactureDate: Date? { Self.manufactureDate(serial: serial) }

    public static func manufactureDate(serial: String?) -> Date? {
        guard let s = serial, s.count == 12 else { return nil }
        let chars = Array(s.uppercased())
        let years = Array("CDFGHJKLMNPQRSTVWXYZ")
        let weeks = Array("123456789CDFGHJKLMNPQRTVWXY")
        guard let y = years.firstIndex(of: chars[3]), let w = weeks.firstIndex(of: chars[4]) else { return nil }
        let year = 2010 + y / 2
        let week = w + 1 + (y % 2 == 1 ? 26 : 0)
        var c = DateComponents()
        c.weekOfYear = week
        c.yearForWeekOfYear = year
        c.weekday = 2   // Monday
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)
    }

    /// "macOS Sequoia 15.8.1".
    public static func osMarketingName(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let names = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe", 27: "macOS 27"]
        let n = names[v.majorVersion].map { " \($0)" } ?? ""
        return "macOS\(n) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static let current: MachineInfo = {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let model = sysctlString("hw.model") ?? "Mac"
        // Apple silicon: "MacBook Air (M5, 2026)". Intel: the model identifier again — ignore it.
        let product = platformProperty("product-name").flatMap { $0 == model || $0.isEmpty ? nil : $0 }
        return MachineInfo(model: model,
                           productName: product,
                           serial: platformProperty(kIOPlatformSerialNumberKey),
                           hostName: host,
                           osVersion: osMarketingName(v))
    }()

    /// "MacBookAir7,1" → "MacBook Air".
    static func family(of model: String) -> String {
        let base = model.prefix { !$0.isNumber }
        switch base {
        case "MacBookAir": return "MacBook Air"
        case "MacBookPro": return "MacBook Pro"
        case "MacBook": return "MacBook"
        case "MacPro": return "Mac Pro"
        case "Macmini": return "Mac mini"
        case "iMac": return "iMac"
        default: return String(base.isEmpty ? "Mac" : base)
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func platformProperty(_ key: String) -> String? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let v = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let s = v as? String { return s }
        if let d = v as? Data {
            return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        }
        return nil
    }
}
