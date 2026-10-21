import AppKit
import WebKit
import UniformTypeIdentifiers
import PapayaCore

/// Renders a report template to HTML, then prints it through WebKit or saves it.
@MainActor
enum ReportPrinter {
    private static var pending: [PrintJob] = []

    static func html(for s: BatterySnapshot) -> String {
        let key = s.kind == .ios ? Pref.iosTemplate : Pref.macTemplate
        let path = UserDefaults.standard.string(forKey: key) ?? ""
        let template = (path.isEmpty ? nil : try? String(contentsOfFile: path, encoding: .utf8))
            ?? Report.defaultTemplate(kind: s.kind)
        return Report.render(template: template, variables: Report.variables(for: s, appVersion: AppModel.version))
    }

    static func print(_ s: BatterySnapshot?) {
        guard let s else { return }
        let job = PrintJob(html: html(for: s))
        pending.append(job)
        job.start { pending.removeAll { $0 === job } }
    }

    static func export(_ s: BatterySnapshot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(s.deviceName) battery report.html"
        if panel.runModal() == .OK, let url = panel.url {
            try? html(for: s).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func saveDefaultTemplates() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        try? Report.defaultTemplate(kind: .mac).write(to: dir.appendingPathComponent("template_mac.html"), atomically: true, encoding: .utf8)
        try? Report.defaultTemplate(kind: .ios).write(to: dir.appendingPathComponent("template_ios.html"), atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("template_mac.html")])
    }
}

/// Loads HTML in an off-screen web view and runs the print panel once it has rendered.
@MainActor
final class PrintJob: NSObject, WKNavigationDelegate {
    let html: String
    private var web: WKWebView?
    private var done: (() -> Void)?

    init(html: String) { self.html = html }

    func start(done: @escaping () -> Void) {
        self.done = done
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100))
        w.navigationDelegate = self
        web = w
        w.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let info = NSPrintInfo.shared
            info.topMargin = 36
            info.bottomMargin = 36
            let op = webView.printOperation(with: info)
            op.view?.frame = webView.bounds
            op.showsPrintPanel = true
            op.run()
            self.web = nil
            self.done?()
        }
    }
}
