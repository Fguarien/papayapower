import SwiftUI
import AppKit
import PapayaCore

/// The small panel that drops from the menu bar: the essentials only, and an expand button
/// that opens the PapayaPower window (the tabbed view).
struct CompactMenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if let b = model.mac {
                    CompactBattery(b: b)
                } else {
                    CompactFleet()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            Divider().padding(.horizontal, 12)
            HStack {
                Text("\(AppModel.version) (\(AppModel.build))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                SettingsButton()
                HelpButton()
                Spacer()
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Open the PapayaPower window")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }
}

/// One battery, coconutBattery style: two bars and three lines.
struct CompactBattery: View {
    var b: BatterySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThinBar(title: "Battery Charge", value: b.chargePercent, color: Fmt.chargeTint(b.chargePercent))
            ThinBar(title: "Battery Health", value: b.health.map { $0 * 100 }, color: ThinBar.healthColor(b.health))
            VStack(spacing: 8) {
                if b.fullyCharged == true {
                    line("Status", "Fully charged")
                } else if b.isCharging == true {
                    line("Time until full", b.timeToFull.map(ThinBar.duration) ?? "Calculating…")
                } else if b.externalConnected == false {
                    line("Time remaining", b.timeToEmpty.map(ThinBar.duration) ?? "Calculating…")
                } else {
                    line("Status", "On power adapter")
                }
                line("Cycles", b.cycleCount.map(String.init) ?? "—")
                line("Temperature", b.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
            }
        }
    }

    func line(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(v).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }
    }
}

/// A Mac without a battery (the master): one short bar per device it knows.
struct CompactFleet: View {
    @EnvironmentObject var model: AppModel

    struct Item: Identifiable {
        var id: String
        var name: String
        var value: Double?
        var color: Color
        var detail: String
    }

    var items: [Item] {
        var out: [Item] = []
        for u in model.ups {
            out.append(Item(id: u.id, name: "UPS · \(u.name)", value: u.chargePercent,
                            color: u.onBattery == true ? .orange : .green,
                            detail: u.onBattery == true ? "on battery" : "on mains"))
        }
        let peerBatteries = model.isMaster ? model.peers.compactMap(\.readings).flatMap(\.batteries) : []
        for b in model.ios + peerBatteries {
            out.append(Item(id: b.deviceID, name: b.deviceName, value: b.chargePercent,
                            color: Fmt.chargeTint(b.chargePercent),
                            detail: b.health.map { String(format: "health %.0f %%", $0 * 100) } ?? ""))
        }
        return out
    }

    var body: some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "powerplug").font(.system(size: 24)).foregroundStyle(.secondary)
                Text("This Mac has no battery").font(.system(size: 14, weight: .semibold))
                Text(model.isMaster ? "No other computer found yet." : "Connect an iPhone or a UPS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            ForEach(items) { i in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(i.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(i.value.map { String(format: "%.0f%%", $0) } ?? "—")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                    ProgressBar(fraction: (i.value ?? 0) / 100, color: i.color)
                    if !i.detail.isEmpty {
                        Text(i.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ThinBar: View {
    var title: String
    var value: Double?        // percent
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(value.map { String(format: "%.1f%%", $0) } ?? "—")
                    .font(.system(size: 15, weight: .semibold)).monospacedDigit()
            }
            ProgressBar(fraction: (value ?? 0) / 100, color: color)
        }
    }

    static func healthColor(_ h: Double?) -> Color {
        Fmt.healthTint(h)
    }

    /// "1m", "45m", "2h 05m".
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h " + String(format: "%02dm", minutes % 60)
    }
}

struct ProgressBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 8)
    }
}

struct SettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink { Image(systemName: "gearshape.fill").font(.system(size: 14)) }
                .buttonStyle(.borderless)
                .help("Settings")
        } else {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: { Image(systemName: "gearshape.fill").font(.system(size: 14)) }
                .buttonStyle(.borderless)
                .help("Settings")
        }
    }
}
