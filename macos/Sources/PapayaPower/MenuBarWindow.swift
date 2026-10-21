import SwiftUI
import AppKit
import PapayaCore

/// The window that drops from the menu bar: three tabs, This Mac / History / iPhone & iPad,
/// plus Network when other computers or UPS units are around.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("menuTab") private var tab = "mac"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TabButton(id: "mac", title: "This Mac", symbol: "waveform", tab: $tab)
                TabButton(id: "history", title: "History", symbol: "archivebox.fill", tab: $tab)
                TabButton(id: "ios", title: "iPhone/iPad", symbol: "iphone", tab: $tab)
                if (model.isMaster && !model.peers.isEmpty) || !model.ups.isEmpty {
                    TabButton(id: "network", title: "Network", symbol: "network", tab: $tab)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()
            Group {
                switch tab {
                case "history": MenuHistoryTab()
                case "ios": MenuIOSTab()
                case "network": MenuNetworkTab()
                default: MenuMacTab()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            MenuFooter()
        }
        .frame(width: 340)
    }
}

struct TabButton: View {
    var id: String
    var title: String
    var symbol: String
    @Binding var tab: String

    var body: some View {
        Button { tab = id } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 22)).frame(height: 26)
                Text(title).font(.system(size: 11))
            }
            .frame(width: 76, height: 50)
            .foregroundStyle(tab == id ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(tab == id ? Color.secondary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Green bar with the value written in its middle.
struct ValueBar: View {
    var fraction: Double?          // 0…1 (clamped for drawing; label shows the real value)
    var label: String
    var tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3).fill(tint)
                    .frame(width: g.size.width * min(1, max(0, fraction ?? 0)))
                Text(label).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
            }
        }
        .frame(height: 20)
    }
}

struct InfoRow: View {
    var key: String
    var value: String?
    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "Unknown").foregroundStyle(value == nil ? .tertiary : .primary)
                .textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ d: Date?) -> String? { d.map { day.string(from: $0) } }

    static func months(since d: Date?) -> String? {
        guard let d else { return nil }
        let m = Calendar.current.dateComponents([.month], from: d, to: Date()).month ?? 0
        return "\(m) months"
    }

    static func mah(_ v: Int?) -> String? {
        v.map { NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal) + " mAh" }
    }

    static func healthTint(_ h: Double?) -> Color {
        guard let h else { return .gray }
        return h < 0.6 ? .red : h < 0.8 ? .orange : .green
    }

    static func chargeTint(_ c: Double?) -> Color {
        guard let c else { return .gray }
        return c < 10 ? .red : c < 20 ? .orange : .green
    }
}

// MARK: - This Mac

struct MenuMacTab: View {
    @EnvironmentObject var model: AppModel
    @State private var macInfo = false
    @State private var batteryInfo = false
    let machine = MachineInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.displayName).font(.system(size: 17, weight: .semibold))
                    if let m = machine.marketingName, m != machine.displayName {
                        Text(m).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            InfoRow(key: "Device Identifier", value: machine.model)
            InfoRow(key: "Manufacture date", value: Fmt.date(machine.manufactureDate))
            HStack {
                Button("Mac Info…") { macInfo = true }
                    .popover(isPresented: $macInfo, arrowEdge: .bottom) { MacInfoPopover() }
                Spacer()
                Button("Battery Info…") { batteryInfo = true }
                    .disabled(model.mac == nil)
                    .popover(isPresented: $batteryInfo, arrowEdge: .bottom) {
                        if let b = model.mac { BatteryInfoPopover(b: b) }
                    }
            }
            .controlSize(.small)
            .padding(.vertical, 4)

            if let b = model.mac {
                BatteryBars(b: b)
                InfoRow(key: "Full Charge Capacity", value: Fmt.mah(b.fullChargeCapacity))
                InfoRow(key: "Design Capacity", value: Fmt.mah(b.designCapacity))
                InfoRow(key: "Manufacture Date", value: Fmt.date(b.batteryManufactureDate))
                InfoRow(key: "Charge Cycles", value: b.cycleCount.map(String.init))
                InfoRow(key: "Battery Temperature", value: b.temperature.map { String(format: "%.1f °C", $0) })
                InfoRow(key: (b.batteryWatts ?? 0) > 0.0005 ? "Charging with" : "Discharging with",
                        value: b.batteryWatts.map { "\(Int(abs($0) * 1000)) mW" })
                InfoRow(key: "Low Power Mode",
                        value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "Enabled" : "Disabled")
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "powerplug").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("This Mac has no battery").font(.system(size: 13, weight: .medium))
                    if let u = model.ups.first {
                        Text("UPS \(u.name): \(u.chargePercent.map { "\(Int($0)) %" } ?? "?") · \(u.onBattery == true ? "on battery" : "on mains")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
    }
}

struct BatteryBars: View {
    var b: BatterySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Battery Charge").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.mah(b.currentCapacity) ?? "").font(.system(size: 12))
            }
            ValueBar(fraction: b.chargePercent.map { $0 / 100 },
                     label: b.chargePercent.map { "\(Int($0.rounded()))%" } ?? "—",
                     tint: Fmt.chargeTint(b.chargePercent))
            Text("Battery Health").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            ValueBar(fraction: b.health, label: b.health.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                     tint: Fmt.healthTint(b.health))
        }
    }
}

struct MacInfoPopover: View {
    @ShowDetails private var showDetails
    let m = MachineInfo.current
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac Information").font(.headline)
            InfoRow(key: "Device Identifier", value: m.model)
            InfoRow(key: "Model", value: m.marketingName ?? m.displayName)
            InfoRow(key: "Manufacture date", value: Fmt.date(m.manufactureDate))
            InfoRow(key: "Age", value: Fmt.months(since: m.manufactureDate))
            InfoRow(key: "Serial", value: m.serial)
            InfoRow(key: "OS version", value: m.osVersion)
            Button("More Details…") {
                showDetails(.mac)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct BatteryInfoPopover: View {
    @ShowDetails private var showDetails
    var b: BatterySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery Information").font(.headline)
            InfoRow(key: "Manufacturer", value: b.batteryManufacturer)
            InfoRow(key: "Model", value: b.batteryModel)
            InfoRow(key: "Manufacture date", value: Fmt.date(b.batteryManufactureDate))
            InfoRow(key: "Age", value: Fmt.months(since: b.batteryManufactureDate))
            InfoRow(key: "Loadcycles", value: b.cycleCount.map { c in b.designCycleCount.map { "\(c) of \($0)" } ?? "\(c)" })
            InfoRow(key: "Serial", value: b.batterySerial)
            InfoRow(key: "Battery temperature", value: b.temperature.map { String(format: "%.1f °C", $0) })
            InfoRow(key: "Power adapter", value: b.adapterWatts.map { "\($0) Watt Adapter" } ?? (b.externalConnected == false ? "Not connected" : nil))
            Button("Lifetime Details…") {
                showDetails(.mac)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}

// MARK: - History

struct MenuHistoryTab: View {
    @EnvironmentObject var model: AppModel
    @ShowDetails private var showDetails

    struct Month: Identifiable {
        var id: String { device + period }
        var device: String
        var period: String
        var health: Double?
        var cycles: Int?
    }

    var groups: [(name: String, months: [Month])] {
        _ = model.historyRevision
        guard let h = model.history else { return [] }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return h.devices().map { d in
            let entries = h.entries(deviceID: d.id, limit: 5000)
            let byMonth = Dictionary(grouping: entries) { f.string(from: $0.timestamp) }
            let months = byMonth.keys.sorted(by: >).map { k -> Month in
                let es = byMonth[k]!
                let hs = es.compactMap(\.health)
                return Month(device: d.id, period: k,
                             health: hs.isEmpty ? nil : hs.reduce(0, +) / Double(hs.count),
                             cycles: es.compactMap(\.cycleCount).max())
            }
            let model = entries.first?.snapshot.flatMap { $0.marketingName ?? $0.model }
            return (name: d.name + (model.map { " (\($0))" } ?? ""), months: months)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Date Period").frame(maxWidth: .infinity, alignment: .leading)
                Text("ø Health").frame(width: 80, alignment: .trailing)
                Text("Cycles").frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.name) { g in
                        DisclosureGroup {
                            ForEach(g.months) { m in
                                HStack {
                                    Text(m.period).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                                    Text(m.health.map { String(format: "%.0f%%", $0 * 100) } ?? "—").frame(width: 80, alignment: .trailing)
                                    Text(m.cycles.map(String.init) ?? "—").frame(width: 60, alignment: .trailing)
                                }
                                .font(.system(size: 12)).monospacedDigit()
                            }
                        } label: {
                            Text(g.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if groups.isEmpty {
                        Text("No readings saved yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 330)
            Button("Open History Viewer") {
                showDetails(.history)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - iPhone / iPad

struct MenuIOSTab: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var info = false

    var body: some View {
        if model.ios.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if model.iosScanning { ProgressView().controlSize(.small) }
                Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Please connect an\niPhone or iPad via USB").multilineTextAlignment(.center)
                Text("Devices that trust this Mac and have Wi-Fi sync on appear here too.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Search Again") { model.scanIOS() }.controlSize(.small).disabled(model.iosScanning)
                Spacer()
            }
            .frame(height: 380)
        } else {
            let d = model.ios.first { $0.deviceID == selected } ?? model.ios[0]
            VStack(alignment: .leading, spacing: 10) {
                if model.ios.count > 1 {
                    Picker("", selection: Binding(get: { d.deviceID }, set: { selected = $0 })) {
                        ForEach(model.ios, id: \.deviceID) { Text($0.deviceName).tag($0.deviceID) }
                    }
                    .labelsHidden()
                }
                HStack(spacing: 14) {
                    Image(systemName: d.model?.hasPrefix("iPad") == true ? "ipad" : "iphone")
                        .font(.system(size: 44)).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.deviceName).font(.system(size: 17, weight: .semibold))
                        Text([d.model, d.osVersion].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(d.raw["Interface"] ?? "").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Button("Battery Info…") { info = true }
                    .controlSize(.small)
                    .popover(isPresented: $info, arrowEdge: .bottom) { BatteryInfoPopover(b: d) }
                BatteryBars(b: d)
                InfoRow(key: "Full Charge Capacity", value: Fmt.mah(d.fullChargeCapacity))
                InfoRow(key: "Design Capacity", value: Fmt.mah(d.designCapacity))
                InfoRow(key: "Charge Cycles", value: d.cycleCount.map(String.init))
                InfoRow(key: "Battery Temperature", value: d.temperature.map { String(format: "%.1f °C", $0) })
                InfoRow(key: "Status", value: d.isCharging == true ? "Charging" : d.externalConnected == true ? "Connected to power" : "On battery")
                InfoRow(key: "Serial", value: d.deviceSerial)
            }
        }
    }
}

// MARK: - Network (other computers, UPS)

struct MenuNetworkTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.ups) { u in
                    VStack(alignment: .leading, spacing: 4) {
                        Label("UPS · \(u.name)", systemImage: u.onBattery == true ? "bolt.slash" : "powerplug")
                            .font(.system(size: 13, weight: .semibold))
                        ValueBar(fraction: u.chargePercent.map { $0 / 100 },
                                 label: u.chargePercent.map { "\(Int($0))%" } ?? "—",
                                 tint: u.onBattery == true ? .orange : .green)
                        Text([u.onBattery == true ? "On battery" : "On mains",
                              u.runtimeSeconds.map { "runtime \(Format.minutes($0 / 60))" },
                              u.loadPercent.map { "load \(Int($0)) %" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.isMaster ? model.peers : []) { p in
                    if let r = p.readings {
                        ForEach(r.batteries, id: \.deviceID) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(b.kind == .mac ? "\(p.name) · \(b.marketingName ?? b.deviceName)" : "\(b.deviceName) · via \(p.name)",
                                      systemImage: b.kind == .ios ? "iphone" : "laptopcomputer")
                                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                ValueBar(fraction: b.chargePercent.map { $0 / 100 },
                                         label: b.chargePercent.map { "\(Int($0.rounded()))%" } ?? "—",
                                         tint: Fmt.chargeTint(b.chargePercent))
                                Text([b.health.map { String(format: "health %.1f %%", $0 * 100) },
                                      b.cycleCount.map { "\($0) cycles" },
                                      b.temperature.map { String(format: "%.1f °C", $0) }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(r.ups) { u in
                            Label("UPS \(u.name) · \(p.name): \(u.chargePercent.map { "\(Int($0)) %" } ?? "?")",
                                  systemImage: "powerplug").font(.caption)
                        }
                    } else {
                        Label("\(p.name) — \(p.error ?? "connecting…")", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 380)
    }
}

struct MenuFooter: View {
    @ShowDetails private var showDetails

    var body: some View {
        HStack {
            Button {
                showDetails()
            } label: { Label("More Details…", systemImage: "macwindow") }
            Spacer()
            SettingsButton()
            HelpButton()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
