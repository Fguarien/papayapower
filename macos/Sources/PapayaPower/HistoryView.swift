import SwiftUI
import Charts
import UniformTypeIdentifiers
import PapayaCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var deviceID: String?
    @State private var selection = Set<HistoryEntry.ID>()
    @State private var metric = Metric.health
    @State private var confirmDelete = false
    @State private var confirmDeleteAll = false

    enum Metric: String, CaseIterable, Identifiable {
        case health = "Health", capacity = "Full charge (mAh)", cycles = "Cycles", temperature = "Temperature"
        var id: String { rawValue }
    }

    var devices: [(id: String, name: String, kind: DeviceKind)] {
        _ = model.historyRevision
        return model.history?.devices() ?? []
    }

    var entries: [HistoryEntry] {
        _ = model.historyRevision
        guard let deviceID else { return [] }
        return model.history?.entries(deviceID: deviceID) ?? []
    }

    var body: some View {
        // Lives in the Details window's detail column: one device picker on top instead of a
        // second sidebar, so the window keeps a single split view.
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Device", selection: $deviceID) {
                    ForEach(devices, id: \.id) { d in
                        Label(d.name, systemImage: d.kind == .ios ? "iphone" : "laptopcomputer").tag(Optional(d.id))
                    }
                }
                .frame(maxWidth: 260)
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            .padding(10)
            .disabled(devices.isEmpty)
            if deviceID == nil {
                ContentUnavailable(title: devices.isEmpty ? "No history yet" : "Select a device",
                                   symbol: "chart.xyaxis.line",
                                   message: devices.isEmpty ? "Readings are saved automatically (Settings › History), or with ⌘S." : "")
            } else {
                chart.frame(height: 220).padding(.horizontal, 16)
                table
            }
        }
        .onAppear { if deviceID == nil { deviceID = devices.first?.id } }
        .toolbar {
            ToolbarItemGroup {
                Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export CSV").disabled(deviceID == nil)
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete selected readings").disabled(selection.isEmpty)
                Menu {
                    Button("Delete History of This Device…", role: .destructive) { confirmDeleteAll = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .help("More").disabled(deviceID == nil)
            }
        }
        .confirmationDialog("Delete \(selection.count) reading(s)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.history?.delete(ids: Array(selection))
                selection = []
                model.historyRevision += 1
            }
        }
        .confirmationDialog("Delete the whole history of this device?", isPresented: $confirmDeleteAll) {
            Button("Delete All", role: .destructive) {
                if let deviceID { model.history?.deleteAll(deviceID: deviceID) }
                deviceID = nil
                model.historyRevision += 1
            }
        }
    }

    func value(_ e: HistoryEntry) -> Double? {
        switch metric {
        case .health: return e.health.map { $0 * 100 }
        case .capacity: return e.fullChargeCapacity.map(Double.init)
        case .cycles: return e.cycleCount.map(Double.init)
        case .temperature: return e.temperature
        }
    }

    @ViewBuilder
    var chart: some View {
        let points = entries.compactMap { e in value(e).map { (e.timestamp, $0) } }
        if points.count < 2 {
            Text("At least two readings are needed for a chart.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points, id: \.0) { p in
                LineMark(x: .value("Date", p.0), y: .value(metric.rawValue, p.1))
                    .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.15))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Date", p.0), y: .value(metric.rawValue, p.1))
                    .symbolSize(14)
                    .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.15))
            }
            .chartYScale(domain: .automatic(includesZero: false))
        }
    }

    var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("Date") { Text($0.timestamp.formatted(date: .abbreviated, time: .shortened)) }
                .width(min: 140, ideal: 160)
            TableColumn("Charge") { Text($0.chargePercent.map { String(format: "%.0f %%", $0) } ?? "—") }
                .width(60)
            TableColumn("Health") { Text($0.health.map { String(format: "%.1f %%", $0 * 100) } ?? "—") }
                .width(70)
            TableColumn("Full / design") { e in
                Text(e.fullChargeCapacity.map { f in "\(f) / \(e.designCapacity.map(String.init) ?? "?") mAh" } ?? "—")
            }
            TableColumn("Cycles") { Text($0.cycleCount.map(String.init) ?? "—") }.width(60)
            TableColumn("Temp.") { Text($0.temperature.map { String(format: "%.1f °C", $0) } ?? "—") }.width(70)
        }
    }

    func exportCSV() {
        guard let history = model.history else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let name = devices.first { $0.id == deviceID }?.name ?? "history"
        panel.nameFieldStringValue = "PapayaPower \(name).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? history.csv(deviceID: deviceID).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
