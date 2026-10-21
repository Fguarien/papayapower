import SwiftUI
import PapayaCore

@main
struct PapayaPowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(Pref.menuBarEnabled) private var menuBarEnabled = true

    var body: some Scene {
        // The PapayaPower window: the tabbed view the menu bar panel expands into.
        Window("PapayaPower", id: "main") {
            MenuBarContent()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        // Every detail: overview, lifetime, raw keys, network, UPS, and the history.
        Window("PapayaPower Details", id: "details") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Save Reading to History") {
                    if let m = model.mac { model.saveNow(m) }
                }
                .keyboardShortcut("s")
                .disabled(model.mac == nil)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Report…") { ReportPrinter.print(model.mac) }
                    .keyboardShortcut("p")
                    .disabled(model.mac == nil)
            }
            HelpCommands()
            CommandMenu("Devices") {
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
                Button("Scan for iPhone / iPad") { model.scanIOS() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("PapayaPower Help", id: "help") {
            HelpView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 820, height: 600)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            CompactMenuView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when the window is closed.
        !UserDefaults.standard.bool(forKey: Pref.menuBarEnabled)
    }
}
