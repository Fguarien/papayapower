import SwiftUI
import AppKit

/// The Help window. Its text is docs/HELP.md, shipped in the app's Resources, so macOS, Linux
/// and the repository read the same page. Sections in a sidebar, the section's text on the right.
struct HelpView: View {
    @State private var selection: String?
    let sections = HelpDocument.load()

    var body: some View {
        NavigationSplitView {
            List(sections, id: \.title, selection: $selection) { s in
                Text(s.title)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ScrollView {
                if let s = sections.first(where: { $0.title == selection }) ?? sections.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(s.title).font(.title2.bold()).padding(.bottom, 4)
                        ForEach(Array(s.blocks.enumerated()), id: \.offset) { _, b in
                            block(b)
                        }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(24)
                    .textSelection(.enabled)
                }
            }
        }
        .onAppear { if selection == nil { selection = sections.first?.title } }
    }

    @ViewBuilder
    func block(_ b: HelpDocument.Block) -> some View {
        switch b {
        case .paragraph(let t):
            Text(HelpDocument.inline(t)).fixedSize(horizontal: false, vertical: true)
        case .bullet(let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(HelpDocument.inline(t)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum HelpDocument {
    enum Block { case paragraph(String), bullet(String) }
    struct Section { var title: String; var blocks: [Block] }

    /// "## Title" opens a section, "- " is a bullet, anything else a paragraph. The text before
    /// the first "##" becomes "About".
    static func load() -> [Section] {
        guard let url = Bundle.main.url(forResource: "HELP", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [Section(title: "Help", blocks: [.paragraph("The help file is missing from this build. See https://github.com/Fguarien/papayapower/blob/main/docs/HELP.md")])]
        }
        var out: [Section] = []
        var current = Section(title: "About", blocks: [])
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") || line.isEmpty { continue }
            if line.hasPrefix("## ") {
                if !current.blocks.isEmpty { out.append(current) }
                current = Section(title: String(line.dropFirst(3)), blocks: [])
            } else if line.hasPrefix("- ") {
                current.blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                current.blocks.append(.paragraph(line))
            }
        }
        if !current.blocks.isEmpty { out.append(current) }
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

struct HelpButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "help")
        } label: { Image(systemName: "questionmark.circle").font(.system(size: 14)) }
            .buttonStyle(.borderless)
            .help("PapayaPower Help")
    }
}

/// Help › PapayaPower Help (⌘?), replacing the system entry that looks for a help book.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("PapayaPower Help") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
