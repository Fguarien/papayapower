import SwiftUI
import UniformTypeIdentifiers
import PapayaCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "battery.75") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            HistorySettings().tabItem { Label("History", systemImage: "clock") }
            UPSSettings().tabItem { Label("UPS", systemImage: "powerplug") }
            ExportSettings().tabItem { Label("Monitoring", systemImage: "antenna.radiowaves.left.and.right") }
            PrintingSettings().tabItem { Label("Printing", systemImage: "printer") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.refreshSeconds) private var refresh = 10
    @AppStorage(Pref.iosEnabled) private var ios = true
    @AppStorage(Pref.iosScanSeconds) private var iosScan = 120
    @AppStorage(Pref.shareOnNetwork) private var share = true
    @AppStorage(Pref.role) private var role = "member"
    @AppStorage(Pref.networkKey) private var networkKey = ""

    var body: some View {
        Form {
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            Picker("Refresh every", selection: $refresh) {
                ForEach([2, 5, 10, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
            }
            .onChange(of: refresh) { _ in model.schedule() }
            Toggle("Look for iPhone and iPad", isOn: $ios)
                .disabled(!IOSDevices.shared.isAvailable)
            Picker("Scan devices every", selection: $iosScan) {
                ForEach([60, 120, 300, 900], id: \.self) { Text("\($0 / 60) min").tag($0) }
            }
            .disabled(!ios)
            .onChange(of: iosScan) { _ in model.schedule() }
            Text("A device must trust this Mac (tap “Trust” once over USB). For Wi-Fi, enable “Show this iPhone when on Wi-Fi” in Finder.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Local network") {
                Picker("Role", selection: $role) {
                    Text("Member — sees only its own readings").tag("member")
                    Text("Master — sees every computer").tag("master")
                }
                .onChange(of: role) { _ in model.applyNetworkPrefs() }
                Toggle("Share this Mac's readings with the master", isOn: $share)
                    .onChange(of: share) { _ in model.applyNetworkPrefs() }
                SecureField("Network key (optional)", text: $networkKey)
                Text("A master finds every computer running PapayaPower, saves their readings in its history and publishes them to the Pushgateway. With a network key, members answer only a master that has the same key. Read-only, local addresses only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.menuBarEnabled) private var menuBar = true
    @AppStorage(Pref.menuBarShowIcon) private var showIcon = true
    @AppStorage(Pref.menuBarStyle) private var style = MenuBarStyle.percent.rawValue
    @AppStorage(Pref.menuBarSource) private var source = "auto"

    var body: some View {
        Form {
            Toggle("Show PapayaPower in the menu bar", isOn: $menuBar)
            Group {
                Toggle("Battery icon", isOn: $showIcon)
                Picker("Text", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Follow", selection: $source) {
                    Text("Automatic").tag("auto")
                    if model.mac != nil { Text("This Mac").tag("mac") }
                    ForEach(model.ios, id: \.deviceID) { Text($0.deviceName).tag("ios:" + $0.deviceID) }
                    ForEach(model.ups) { Text("UPS · " + $0.name).tag("ups:" + $0.id) }
                }
                LabeledContent("Preview") {
                    MenuBarLabel().environmentObject(model)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                }
            }
            .disabled(!menuBar)
            Text("Automatic follows this Mac's battery; on a Mac without one, a UPS (the one on battery first), then an iPhone or iPad.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct NotificationSettings: View {
    @AppStorage(Pref.notifyEnabled) private var enabled = true
    @AppStorage(Pref.notifyPercent) private var percent = 15
    @AppStorage(Pref.notifyMinutes) private var minutes = 0
    @AppStorage(Pref.notifyIOSPercent) private var iosPercent = 0
    @AppStorage(Pref.notifyUPS) private var ups = true

    var body: some View {
        Form {
            Toggle("Send notifications", isOn: $enabled)
            Group {
                stepper("Mac battery below \(percent) %", $percent, 0...95)
                stepper(minutes == 0 ? "Mac remaining time: off" : "Mac remaining time below \(minutes) min",
                        $minutes, 0...120)
                stepper(iosPercent == 0 ? "iPhone / iPad: off" : "iPhone / iPad below \(iosPercent) %",
                        $iosPercent, 0...95)
                Toggle("UPS switches to battery or runs low", isOn: $ups)
            }
            .disabled(!enabled)
            Text("Each alert fires once when the threshold is crossed, and re-arms when the level is back above it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Stepper first, text on its right — same column as the checkboxes.
    func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Stepper(title, value: value, in: range, step: 5).labelsHidden()
            Text(title).monospacedDigit()
        }
    }
}

struct HistorySettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.autoSave) private var autoSave = AutoSave.daily.rawValue

    var body: some View {
        Form {
            Picker("Save readings automatically", selection: $autoSave) {
                ForEach(AutoSave.allCases) { Text($0.label).tag($0.rawValue) }
            }
            if let url = model.history?.url {
                LabeledContent("Database") {
                    Button(url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link)
                }
            }
            Text("Readings stay on this Mac. ⌘S saves one now.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UPSSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.nutHosts) private var hosts = ""

    var body: some View {
        Form {
            Text("A UPS plugged into this Mac by USB is detected by macOS itself — nothing to set up.")
                .font(.callout)
            TextField("NUT servers", text: $hosts, prompt: Text("nas.local, 10.0.0.5:3493"))
                .onSubmit { model.refresh() }
            Text("Network UPS Tools servers (upsd) to read, comma-separated. Read-only: no login needed.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = model.nutError {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            Button("Test now") { model.refresh() }
        }
    }
}

struct ExportSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.pushEnabled) private var enabled = false
    @AppStorage(Pref.pushURL) private var url = ""
    @AppStorage(Pref.pushUser) private var user = ""
    @AppStorage(Pref.pushSeconds) private var seconds = 300
    @State private var password = Keychain.get("pushgateway") ?? ""

    var body: some View {
        Form {
            Toggle("Publish to a Prometheus Pushgateway", isOn: $enabled)
            Group {
                TextField("URL", text: $url, prompt: Text("http://pushgateway:9091"))
                TextField("User", text: $user)
                SecureField("Password", text: $password)
                    .onSubmit { Keychain.set("pushgateway", password) }
                Picker("Every", selection: $seconds) {
                    ForEach([60, 300, 900], id: \.self) { Text("\($0 / 60) min").tag($0) }
                }
                .onChange(of: seconds) { _ in model.schedule() }
                HStack {
                    Button("Push now") {
                        Keychain.set("pushgateway", password)
                        model.push()
                    }
                    if let (date, result) = model.lastPush {
                        Text("\(date.formatted(date: .omitted, time: .standard)): \(result)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
            Text("Metrics papaya_battery_* and papaya_ups_*, job “papayapower”, instance = this Mac's name. The password is kept in the Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { Keychain.set("pushgateway", password) }
    }
}

struct PrintingSettings: View {
    @AppStorage(Pref.macTemplate) private var macTemplate = ""
    @AppStorage(Pref.iosTemplate) private var iosTemplate = ""

    var body: some View {
        Form {
            templateRow("Mac report template", $macTemplate)
            templateRow("iPhone / iPad report template", $iosTemplate)
            Text("An HTML file with placeholders such as $MAC_BATTERY_HEALTH_PERCENT, $MAC_BATTERY_CYCLECOUNT, $IOS_BATTERY_MAH, $REPORT_CREATION. Leave empty for the built-in template.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save Built-in Templates…") { ReportPrinter.saveDefaultTemplates() }
        }
    }

    func templateRow(_ title: String, _ binding: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(binding.wrappedValue.isEmpty ? "Built-in" : (binding.wrappedValue as NSString).lastPathComponent)
                    .foregroundStyle(.secondary)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.html]
                    if p.runModal() == .OK, let u = p.url { binding.wrappedValue = u.path }
                }
                if !binding.wrappedValue.isEmpty {
                    Button("Reset") { binding.wrappedValue = "" }
                }
            }
        }
    }
}
