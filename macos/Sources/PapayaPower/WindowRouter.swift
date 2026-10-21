import SwiftUI
import AppKit

/// One window at a time: going to Details closes the PapayaPower window (the menu bar's expand
/// button brings it back), and History opens inside Details rather than in a window of its own.
struct ShowDetailsAction {
    var model: AppModel
    var openWindow: OpenWindowAction

    @MainActor
    func callAsFunction(_ item: SidebarItem? = nil) {
        if let item { model.detailsSelection = item }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "details")
        Self.close(id: "main")
    }

    /// SwiftUI names a `Window` scene's NSWindow after its id ("main", or "main-AppWindow-1").
    @MainActor
    static func close(id: String) {
        for w in NSApp.windows {
            guard let raw = w.identifier?.rawValue else { continue }
            if raw == id || raw.hasPrefix(id + "-") { w.close() }
        }
    }
}

/// `@ShowDetails var showDetails` then `showDetails(.history)`.
@propertyWrapper
struct ShowDetails: DynamicProperty {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var wrappedValue: ShowDetailsAction { ShowDetailsAction(model: model, openWindow: openWindow) }
}
