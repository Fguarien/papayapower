import SwiftUI
import PapayaCore

enum SidebarItem: Hashable {
    case mac
    case ios(String)
    case ups(String)
    case peerBattery(String, String)   // peer name, device id
    case peerUPS(String, String)       // peer name, ups id
    case history
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.detailsSelection) {
                Section("This Mac") {
                    Label(MachineInfo.current.displayName, systemImage: "laptopcomputer")
                        .tag(SidebarItem.mac)
                }
                Section {
                    ForEach(model.ios, id: \.deviceID) { d in
                        Label(d.deviceName, systemImage: d.model?.hasPrefix("iPad") == true ? "ipad" : "iphone")
                            .badge(d.chargePercent.map { "\(Int($0)) %" } ?? "")
                            .tag(SidebarItem.ios(d.deviceID))
                    }
                    if model.ios.isEmpty {
                        Text(IOSDevices.shared.isAvailable ? "Connect a device by USB, or enable Wi-Fi sync."
                                                           : "iOS support unavailable on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("iPhone & iPad")
                        Spacer()
                        if model.iosScanning { ProgressView().controlSize(.mini) }
                    }
                }
                // Only once a UPS shows up (or a configured NUT server fails, so the error is seen).
                if !model.ups.isEmpty || model.nutError != nil {
                    Section("UPS") {
                        ForEach(model.ups) { u in
                            Label(u.name, systemImage: u.onBattery == true ? "bolt.slash" : "powerplug")
                                .badge(u.chargePercent.map { "\(Int($0)) %" } ?? "")
                                .tag(SidebarItem.ups(u.id))
                        }
                        if let e = model.nutError {
                            Text(e).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if model.isMaster && !model.peers.isEmpty {
                    Section("Network") {
                        ForEach(model.peers) { p in
                            if let r = p.readings {
                                ForEach(r.batteries, id: \.deviceID) { b in
                                    Label {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(b.kind == .mac ? p.name : b.deviceName)
                                            Text(b.kind == .mac ? b.deviceName : "via \(p.name)")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: b.kind == .ios ? "iphone" : "laptopcomputer")
                                    }
                                    .badge(b.chargePercent.map { "\(Int($0)) %" } ?? "")
                                    .tag(SidebarItem.peerBattery(p.name, b.deviceID))
                                }
                                ForEach(r.ups) { u in
                                    Label("\(u.name) · \(p.name)", systemImage: u.onBattery == true ? "bolt.slash" : "powerplug")
                                        .badge(u.chargePercent.map { "\(Int($0)) %" } ?? "")
                                        .tag(SidebarItem.peerUPS(p.name, u.id))
                                }
                                if r.batteries.isEmpty && r.ups.isEmpty {
                                    Label("\(p.name) — no battery", systemImage: "desktopcomputer")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Label("\(p.name) — \(p.error ?? "connecting…")", systemImage: "wifi.exclamationmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("History") {
                    Label("Saved readings", systemImage: "chart.xyaxis.line")
                        .tag(SidebarItem.history)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch model.detailsSelection {
            case .history:
                HistoryView()
            case .mac, .none:
                if let m = model.mac {
                    BatteryDetailView(snapshot: m)
                } else {
                    NoBatteryView()
                }
            case .ios(let id):
                if let d = model.ios.first(where: { $0.deviceID == id }) {
                    BatteryDetailView(snapshot: d)
                } else {
                    ContentUnavailable(title: "Device gone", symbol: "iphone.slash")
                }
            case .ups(let id):
                if let u = model.ups.first(where: { $0.id == id }) {
                    UPSDetailView(ups: u)
                } else {
                    ContentUnavailable(title: "UPS gone", symbol: "powerplug")
                }
            case .peerBattery(let peer, let id):
                if let r = model.peers.first(where: { $0.name == peer })?.readings,
                   let b = r.batteries.first(where: { $0.deviceID == id }) {
                    BatteryDetailView(snapshot: b)
                } else {
                    ContentUnavailable(title: "Not reachable", symbol: "wifi.exclamationmark")
                }
            case .peerUPS(let peer, let id):
                if let r = model.peers.first(where: { $0.name == peer })?.readings,
                   let u = r.ups.first(where: { $0.id == id }) {
                    UPSDetailView(ups: u)
                } else {
                    ContentUnavailable(title: "Not reachable", symbol: "wifi.exclamationmark")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.refresh(); model.scanIOS(); model.fetchPeers() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                HelpButton()
            }
        }
    }
}

struct ContentUnavailable: View {
    var title: String
    var symbol: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            if !message.isEmpty {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NoBatteryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ContentUnavailable(
            title: "This Mac has no battery",
            symbol: "powerplug",
            message: model.ups.isEmpty
                ? "PapayaPower still watches iPhones, iPads and UPS units. Plug a UPS in by USB, or add a NUT server in Settings."
                : "Select a UPS or a device in the sidebar.")
    }
}

// MARK: - Battery detail

struct BatteryDetailView: View {
    @EnvironmentObject var model: AppModel
    var snapshot: BatterySnapshot
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Overview").tag(0)
                Text("Lifetime").tag(1)
                Text("Advanced").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.vertical, 10)

            switch tab {
            case 0: OverviewView(s: snapshot)
            case 1: LifetimeView(s: snapshot)
            default: AdvancedView(raw: snapshot.raw)
            }
        }
        .navigationTitle(snapshot.deviceName)
        .navigationSubtitle([snapshot.model, snapshot.osVersion].compactMap { $0 }.joined(separator: " · "))
        .toolbar {
            ToolbarItemGroup {
                Button { model.saveNow(snapshot) } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save this reading to the history")
                Button { ReportPrinter.print(snapshot) } label: { Image(systemName: "printer") }
                    .help("Print a report")
                Button { ReportPrinter.export(snapshot) } label: { Image(systemName: "doc.richtext") }
                    .help("Export the report as HTML")
            }
        }
    }
}

struct OverviewView: View {
    var s: BatterySnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 40) {
                    Gauge(title: "Current charge", value: s.chargePercent.map { $0 / 100 },
                          caption: chargeCaption, tint: chargeTint)
                    Gauge(title: "Battery health", value: s.health,
                          caption: capacityCaption, tint: healthTint)
                }
                .padding(.top, 8)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    row("Charge cycles", s.cycleCount.map { c in s.designCycleCount.map { "\(c) of \($0)" } ?? "\(c)" })
                    row("Temperature", s.temperature.map(Format.temperature))
                    row("Battery power", s.batteryWatts.map { w in
                        Format.watts(w) + (w > 0.05 ? " (charging)" : w < -0.05 ? " (discharging)" : "")
                    })
                    row("Voltage", s.voltage.map { String(format: "%.2f V", Double($0) / 1000) })
                    row("Power adapter", s.adapterWatts.map { "\($0) W" + (s.adapterName.map { " · \($0)" } ?? "") })
                    row(s.isCharging == true ? "Time to full" : "Time to empty",
                        (s.isCharging == true ? s.timeToFull : s.timeToEmpty).map(Format.minutes))
                    row("Status", status)
                    Divider().gridCellColumns(2)
                    row("Battery manufacturer", s.batteryManufacturer)
                    row("Battery model", s.batteryModel)
                    row("Battery serial", s.batterySerial)
                    row("Manufactured", manufactured)
                    row("Device serial", s.deviceSerial)
                    if let cells = s.cellVoltages, !cells.isEmpty {
                        row("Cell voltages", cells.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " · ") + " V")
                    }
                    if s.permanentFailure == true {
                        row("Permanent failure", "Yes — the gauge flagged this battery")
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                Text("Read \(s.timestamp.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    func row(_ k: String, _ v: String?) -> some View {
        if let v {
            GridRow {
                Text(k).foregroundStyle(.secondary)
                Text(v).textSelection(.enabled)
            }
        }
    }

    var chargeCaption: String {
        if let c = s.currentCapacity, let f = s.fullChargeCapacity, s.kind == .mac || f > 100 {
            return "\(c) of \(f) mAh"
        }
        return s.isCharging == true ? "Charging" : ""
    }

    var capacityCaption: String {
        guard let f = s.fullChargeCapacity, let d = s.designCapacity else { return "Not reported" }
        return "\(f) of \(d) mAh design"
    }

    var status: String? {
        var parts: [String] = []
        if s.externalConnected == true { parts.append("on power adapter") } else if s.externalConnected == false { parts.append("on battery") }
        if s.isCharging == true { parts.append("charging") }
        if s.fullyCharged == true { parts.append("fully charged") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ").capitalizedFirst
    }

    var manufactured: String? {
        guard let d = s.batteryManufactureDate else { return nil }
        var t = d.formatted(date: .abbreviated, time: .omitted)
        if let age = s.batteryAge, let y = age.year, let m = age.month {
            t += " (" + (y > 0 ? "\(y) y " : "") + "\(m) mo)"
        }
        return t
    }

    var chargeTint: Color {
        guard let c = s.chargePercent else { return .gray }
        return c < 15 ? .red : c < 30 ? .orange : .green
    }

    var healthTint: Color {
        guard let h = s.health else { return .gray }
        return h < 0.6 ? .red : h < 0.8 ? .orange : Color(red: 0.95, green: 0.55, blue: 0.15)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A large ring gauge with a percentage in the middle.
struct Gauge: View {
    var title: String
    var value: Double?        // 0…1, may exceed 1
    var caption: String
    var tint: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: min(1, value ?? 0))
                    .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.6), value: value)
                Text(value.map { String(format: "%.1f %%", $0 * 100) } ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 150, height: 150)
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Lifetime

struct LifetimeView: View {
    var s: BatterySnapshot

    var body: some View {
        if let l = s.lifetime {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Minimum").font(.caption).foregroundStyle(.secondary)
                        Text("Average").font(.caption).foregroundStyle(.secondary)
                        Text("Maximum").font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Temperature").foregroundStyle(.secondary)
                        Text(l.minimumTemperature.map(Format.temperature) ?? "—")
                        Text(l.averageTemperature.map(Format.temperature) ?? "—")
                        Text(l.maximumTemperature.map(Format.temperature) ?? "—")
                    }
                    GridRow {
                        Text("Pack voltage").foregroundStyle(.secondary)
                        Text(l.minimumPackVoltage.map(volts) ?? "—")
                        Text("")
                        Text(l.maximumPackVoltage.map(volts) ?? "—")
                    }
                    GridRow {
                        Text("Charge current").foregroundStyle(.secondary)
                        Text(""); Text("")
                        Text(l.maximumChargeCurrent.map { "\($0) mA" } ?? "—")
                    }
                    GridRow {
                        Text("Discharge current").foregroundStyle(.secondary)
                        Text(""); Text("")
                        Text(l.maximumDischargeCurrent.map { "\($0) mA" } ?? "—")
                    }
                    Divider().gridCellColumns(4)
                    GridRow {
                        Text("Operating time").foregroundStyle(.secondary)
                        Text(l.totalOperatingTime.map(hours) ?? "—").gridCellColumns(3)
                    }
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
                Text("Values recorded by the battery's gas gauge since it was made.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        } else {
            ContentUnavailable(title: "No lifetime data", symbol: "clock.badge.questionmark",
                               message: "This battery's gauge does not report lifetime statistics.")
        }
    }

    func volts(_ mv: Int) -> String { String(format: "%.2f V", Double(mv) / 1000) }

    func hours(_ h: Int) -> String {
        let days = Double(h) / 24
        return "\(h) h (\(String(format: "%.0f", days)) days)"
    }
}

// MARK: - Advanced

struct AdvancedView: View {
    var raw: [String: String]
    @State private var filter = ""

    struct Row: Identifiable { var id: String { key }; var key: String; var value: String }

    var rows: [Row] {
        raw.filter { filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.key < $1.key }
            .map { Row(key: $0.key, value: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows) {
                TableColumn("Key", value: \.key).width(min: 180, ideal: 280)
                TableColumn("Value") { Text($0.value).textSelection(.enabled) }
            }
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(rows.count) keys").font(.caption).foregroundStyle(.secondary)
                Button("Copy All") {
                    let text = rows.map { "\($0.key) = \($0.value)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - UPS

struct UPSDetailView: View {
    var ups: UPSSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 40) {
                    Gauge(title: "UPS charge", value: ups.chargePercent.map { $0 / 100 },
                          caption: ups.onBattery == true ? "On battery" : "On mains",
                          tint: ups.onBattery == true ? .orange : .green)
                    if let load = ups.loadPercent {
                        Gauge(title: "Load", value: load / 100, caption: "", tint: load > 80 ? .red : .blue)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 9) {
                    row("Status", ups.status.map(describeStatus))
                    row("Runtime", ups.runtimeSeconds.map { Format.minutes($0 / 60) })
                    row("Input voltage", ups.inputVoltage.map { String(format: "%.0f V", $0) })
                    row("Output voltage", ups.outputVoltage.map { String(format: "%.0f V", $0) })
                    row("Battery voltage", ups.batteryVoltage.map { String(format: "%.1f V", $0) })
                    row("Battery date", ups.batteryDate)
                    Divider().gridCellColumns(2)
                    row("Manufacturer", ups.manufacturer)
                    row("Model", ups.model)
                    row("Serial", ups.serial)
                    row("Source", ups.source)
                }
                .frame(maxWidth: 560, alignment: .leading)
                DisclosureGroup("All variables") {
                    AdvancedView(raw: ups.raw).frame(height: 280)
                }
                .frame(maxWidth: 560)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(ups.name)
        .navigationSubtitle(ups.source)
    }

    @ViewBuilder
    func row(_ k: String, _ v: String?) -> some View {
        if let v {
            GridRow {
                Text(k).foregroundStyle(.secondary)
                Text(v).textSelection(.enabled)
            }
        }
    }

    /// NUT status flags (OL OB LB CHRG…) in plain words.
    func describeStatus(_ s: String) -> String {
        let words: [String: String] = [
            "OL": "on line", "OB": "on battery", "LB": "low battery", "HB": "high battery",
            "RB": "replace battery", "CHRG": "charging", "DISCHRG": "discharging", "BYPASS": "bypass",
            "CAL": "calibrating", "OFF": "off", "OVER": "overloaded", "TRIM": "trimming voltage",
            "BOOST": "boosting voltage", "FSD": "forced shutdown",
        ]
        return s.split(separator: " ").map { words[String($0)] ?? String($0) }.joined(separator: ", ").capitalizedFirst
    }
}
