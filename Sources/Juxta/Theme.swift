import AppKit
import SwiftUI

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

/// Visual meaning of a cell in any compare grid.
enum CellStyle: UInt8 {
    case normal, changed, orphan, unimportant, filler, conflict, header, takenLeft, takenRight, base, missing
}

enum Palette {
    static let changedBG = NSColor.dynamic(light: .rgb(255, 236, 236), dark: .rgb(78, 36, 42))
    static let changedHL = NSColor.dynamic(light: .rgb(255, 178, 178), dark: .rgb(150, 52, 62))
    static let changedMark = NSColor.dynamic(light: .rgb(232, 72, 85), dark: .rgb(255, 99, 110))
    static let orphanBG = NSColor.dynamic(light: .rgb(240, 234, 255), dark: .rgb(56, 44, 92))
    static let orphanMark = NSColor.dynamic(light: .rgb(137, 98, 230), dark: .rgb(170, 140, 255))
    static let unimportantBG = NSColor.dynamic(light: .rgb(235, 242, 252), dark: .rgb(34, 48, 70))
    static let unimportantHL = NSColor.dynamic(light: .rgb(198, 218, 245), dark: .rgb(52, 76, 112))
    static let unimportantMark = NSColor.dynamic(light: .rgb(120, 150, 200), dark: .rgb(110, 140, 190))
    static let fillerBG = NSColor.dynamic(light: .rgb(246, 246, 248), dark: .rgb(30, 30, 33))
    static let fillerHatch = NSColor.dynamic(light: .rgb(226, 226, 232), dark: .rgb(44, 44, 49))
    static let conflictBG = NSColor.dynamic(light: .rgb(255, 240, 214), dark: .rgb(82, 58, 22))
    static let conflictHL = NSColor.dynamic(light: .rgb(255, 205, 130), dark: .rgb(150, 100, 30))
    static let conflictMark = NSColor.dynamic(light: .rgb(240, 150, 30), dark: .rgb(255, 170, 60))
    static let takenLeftBG = NSColor.dynamic(light: .rgb(230, 246, 236), dark: .rgb(28, 64, 44))
    static let takenRightBG = NSColor.dynamic(light: .rgb(228, 240, 255), dark: .rgb(28, 50, 82))
    static let addedMark = NSColor.dynamic(light: .rgb(46, 160, 90), dark: .rgb(80, 200, 120))
    static let headerBG = NSColor.dynamic(light: .rgb(240, 241, 245), dark: .rgb(40, 41, 46))
    static let editorBG = NSColor.dynamic(light: .white, dark: .rgb(24, 24, 27))
    static let gutterBG = NSColor.dynamic(light: .rgb(248, 248, 250), dark: .rgb(30, 30, 34))
    static let lineNumber = NSColor.dynamic(light: .rgb(160, 162, 172), dark: .rgb(100, 102, 112))
    static let separator = NSColor.dynamic(light: .rgb(226, 227, 232), dark: .rgb(52, 53, 58))
    static let searchHL = NSColor.dynamic(light: .rgb(255, 230, 80, 0.85), dark: .rgb(200, 170, 20, 0.7))
    static let text = NSColor.labelColor
    static let dimText = NSColor.secondaryLabelColor

    static func background(_ s: CellStyle) -> NSColor? {
        switch s {
        case .normal: return nil
        case .changed: return changedBG
        case .orphan: return orphanBG
        case .unimportant: return unimportantBG
        case .filler, .missing: return fillerBG
        case .conflict: return conflictBG
        case .header: return headerBG
        case .takenLeft: return takenLeftBG
        case .takenRight: return takenRightBG
        case .base: return nil
        }
    }
    static func highlight(_ s: CellStyle) -> NSColor {
        switch s {
        case .unimportant: return unimportantHL
        case .conflict: return conflictHL
        case .orphan: return orphanBG
        default: return changedHL
        }
    }
    static func mark(_ s: CellStyle) -> NSColor {
        switch s {
        case .orphan: return orphanMark
        case .unimportant: return unimportantMark
        case .conflict: return conflictMark
        case .takenLeft, .takenRight: return addedMark
        default: return changedMark
        }
    }
}

extension Color {
    static let jChanged = Color(nsColor: Palette.changedMark)
    static let jOrphan = Color(nsColor: Palette.orphanMark)
    static let jUnimportant = Color(nsColor: Palette.unimportantMark)
    static let jConflict = Color(nsColor: Palette.conflictMark)
    static let jAdded = Color(nsColor: Palette.addedMark)
    static let jSeparator = Color(nsColor: Palette.separator)
    static let jGutter = Color(nsColor: Palette.gutterBG)
    static let jEditor = Color(nsColor: Palette.editorBG)
}

/// User preferences shared by every session.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    @AppStorage("fontSize") var fontSize: Double = 12.5 { willSet { objectWillChange.send() } }
    @AppStorage("fontName") var fontName: String = "SF Mono" { willSet { objectWillChange.send() } }
    @AppStorage("tabWidth") var tabWidth: Int = 4 { willSet { objectWillChange.send() } }
    @AppStorage("contextLines") var contextLines: Int = 3 { willSet { objectWillChange.send() } }
    @AppStorage("showLineNumbers") var showLineNumbers: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("showWhitespace") var showWhitespace: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("showDetailPane") var showDetailPane: Bool = true { willSet { objectWillChange.send() } }
    @AppStorage("defaultWhitespace") var defaultWhitespace: String = "Compare whitespace" { willSet { objectWillChange.send() } }
    @AppStorage("defaultIgnoreCase") var defaultIgnoreCase: Bool = false { willSet { objectWillChange.send() } }
    @AppStorage("ignorePatterns") var ignorePatterns: String = "" { willSet { objectWillChange.send() } }
    @AppStorage("folderExcludes") var folderExcludes: String = ".git;.DS_Store;node_modules;.build;DerivedData" { willSet { objectWillChange.send() } }

    var editorFont: NSFont {
        let size = CGFloat(fontSize)
        if fontName == "SF Mono" { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Reusable SwiftUI pieces

struct ToolButton: View {
    let icon: String
    let label: String
    var tint: Color? = nil
    var enabled = true
    var active = false
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? Color.accentColor : (tint ?? Color.primary))
                    .frame(height: 18)
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(active ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 46)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.07) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .onHover { hover = $0 }
        .help(help ?? label)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct ToolDivider: View {
    var body: some View { Rectangle().fill(Color.jSeparator).frame(width: 1, height: 30).padding(.horizontal, 4) }
}

struct Toolbar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
    }
}

/// A path field with browse button, recents and drag-and-drop.
struct PathField: View {
    let placeholder: String
    @Binding var url: URL?
    var directories = false
    var dirty = false
    var readOnlyLabel: String? = nil
    var onPick: (URL) -> Void
    @State private var targeted = false
    @State private var editing = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: directories ? "folder.fill" : "doc.text.fill")
                .foregroundStyle(directories ? Color.accentColor : .secondary)
                .font(.system(size: 12))
            if let readOnlyLabel {
                Text(readOnlyLabel).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField(placeholder, text: $editing)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit { commitTyped() }
                    .onAppear { editing = url?.path ?? "" }
                    .onChange(of: url) { _, v in if !focused { editing = v?.path ?? "" } }
            }
            if dirty {
                Circle().fill(Color.jChanged).frame(width: 7, height: 7).help("Unsaved changes")
            }
            Menu {
                ForEach(Recents.shared.paths(directories: directories), id: \.self) { p in
                    Button((p as NSString).abbreviatingWithTildeInPath) { pick(URL(fileURLWithPath: p)) }
                }
            } label: { Image(systemName: "clock") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Recent")
            Button { browse() } label: { Image(systemName: "ellipsis.circle") }
                .buttonStyle(.borderless)
                .help("Browse…")
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : (focused ? Color.accentColor.opacity(0.6) : Color.jSeparator), lineWidth: targeted ? 2 : 1)
        )
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { DispatchQueue.main.async { pick(u) } }
            }
            return true
        }
    }

    func commitTyped() {
        let p = (editing as NSString).expandingTildeInPath
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { NSSound.beep(); return }
        pick(URL(fileURLWithPath: p))
    }

    func pick(_ u: URL) {
        url = u
        editing = u.path
        Recents.shared.addPath(u.path, directory: directories)
        onPick(u)
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        if panel.runModal() == .OK, let u = panel.url { pick(u) }
    }
}

struct StatusBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 14) { content }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
    }
}

struct StatChip: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).monospacedDigit()
        }
    }
}

/// A small pill shown in the pane header (encoding, line endings…).
struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

func runAlert(_ title: String, _ message: String, buttons: [String] = ["OK"], style: NSAlert.Style = .informational) -> Int {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = message
    a.alertStyle = style
    for b in buttons { a.addButton(withTitle: b) }
    let r = a.runModal()
    return r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

let shortDate: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .short
    f.timeStyle = .short
    return f
}()

extension View {
    /// Styles a Menu so its custom icon-over-label content renders like a ToolButton.
    func toolMenu() -> some View {
        self.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
