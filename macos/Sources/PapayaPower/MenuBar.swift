import SwiftUI
import PapayaCore

/// What the menu bar item follows.
struct MenuBarSubject {
    var percent: Double?
    var charging: Bool
    var plugged: Bool
    var upsOnBattery: Bool
    var timeMinutes: Int?
    var watts: Double?
    var health: Double?
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.menuBarStyle) private var style = MenuBarStyle.percent.rawValue
    @AppStorage(Pref.menuBarShowIcon) private var showIcon = true
    @AppStorage(Pref.menuBarSource) private var source = "auto"

    var body: some View {
        let s = model.menuBarSubject(source: source)
        HStack(spacing: 4) {
            if showIcon || text(s) == nil {
                Image(nsImage: BatteryIcon.image(percent: s?.percent, charging: s?.charging ?? false,
                                                 plugged: s?.plugged ?? false, onUPSBattery: s?.upsOnBattery ?? false))
            }
            if let t = text(s) { Text(t).monospacedDigit() }
        }
    }

    func text(_ s: MenuBarSubject?) -> String? {
        guard let s else { return nil }
        switch MenuBarStyle(rawValue: style) ?? .percent {
        case .percent: return s.percent.map { "\(Int($0.rounded()))%" }
        case .time: return s.timeMinutes.map(Format.minutes) ?? s.percent.map { "\(Int($0.rounded()))%" }
        case .watts: return s.watts.map { String(format: "%+.1fW", $0) }
        case .health: return s.health.map { String(format: "♥%.0f%%", $0 * 100) }
        case .iconOnly: return nil
        }
    }
}

