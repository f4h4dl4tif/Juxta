import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JuxtaCore

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case text, folder, merge, sync, table, hex, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text Compare"
        case .folder: return "Folder Compare"
        case .merge: return "Text Merge"
        case .sync: return "Folder Sync"
        case .table: return "Table Compare"
        case .hex: return "Hex Compare"
        case .image: return "Picture Compare"
        }
    }
    var icon: String {
        switch self {
        case .text: return "doc.text.magnifyingglass"
        case .folder: return "folder.badge.gearshape"
        case .merge: return "arrow.triangle.merge"
        case .sync: return "arrow.triangle.2.circlepath"
        case .table: return "tablecells"
        case .hex: return "number.square"
        case .image: return "photo.on.rectangle.angled"
        }
    }
    var tint: Color {
        switch self {
        case .text: return .blue
        case .folder: return .orange
        case .merge: return .purple
        case .sync: return .teal
        case .table: return .green
        case .hex: return .gray
        case .image: return .pink
        }
    }
    var blurb: String {
        switch self {
        case .text: return "Side-by-side line & character differences with merging and editing."
        case .folder: return "Compare folder trees by size, date or content and copy changes across."
        case .merge: return "Three-way merge of two changed versions against their common ancestor."
        case .sync: return "Preview and run update or mirror operations between two folders."
        case .table: return "Cell-by-cell comparison of CSV and TSV files, aligned by key column."
        case .hex: return "Byte-level comparison of binary files with offset navigation."
        case .image: return "Pixel differences, blend, swipe and side-by-side views of images."
        }
    }
    var pathCount: Int { self == .merge ? 3 : 2 }
    var usesFolders: Bool { self == .folder || self == .sync }
}

enum AppCommand {
    case nextDiff, prevDiff, firstDiff, lastDiff
    case copyToRight, copyToLeft
    case save, saveAll, reload, swap
    case find, findNext, findPrev, gotoLine
    case undo, redo
    case expandAll, collapseAll
    case exportReport, exportPatch
    case showAll, showDiffs, showSame, showContext
    case insertLine, deleteLines, editLine
}

/// Base class for all session models so the tab strip can observe titles and dirty state.
class BaseSession: ObservableObject, Identifiable {
    let id = UUID()
    let kind: SessionKind
    @Published var title: String
    @Published var isDirty = false
    init(kind: SessionKind) { self.kind = kind; self.title = kind.title }
    func handle(_ cmd: AppCommand) -> Bool { false }
    var recentPaths: [String] { [] }
    /// Asks the user before closing a tab with unsaved changes. Returns false to cancel.
    func confirmClose() -> Bool {
        guard isDirty else { return true }
        let r = runAlert("Save changes to “\(title)”?", "Your changes will be lost if you don't save them.",
                         buttons: ["Save", "Don't Save", "Cancel"], style: .warning)
        if r == 0 { _ = handle(.saveAll); return !isDirty }
        return r == 1
    }
}

struct Tab: Identifiable, Equatable {
    let id = UUID()
    var session: BaseSession?
    static func == (a: Tab, b: Tab) -> Bool { a.id == b.id }
}

struct RecentSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: SessionKind
    var paths: [String]
    var date: Date
}

final class Recents: ObservableObject {
    static let shared = Recents()
    @Published private(set) var sessions: [RecentSession] = []
    private var filePaths: [String] = []
    private var dirPaths: [String] = []

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "recentSessions"), let s = try? JSONDecoder().decode([RecentSession].self, from: data) { sessions = s }
        filePaths = d.stringArray(forKey: "recentFiles") ?? []
        dirPaths = d.stringArray(forKey: "recentDirs") ?? []
    }

    func add(kind: SessionKind, paths: [String]) {
        guard paths.filter({ !$0.isEmpty }).count >= 2 else { return }
        sessions.removeAll { $0.kind == kind && $0.paths == paths }
        sessions.insert(RecentSession(kind: kind, paths: paths, date: Date()), at: 0)
        if sessions.count > 40 { sessions.removeLast(sessions.count - 40) }
        save()
    }

    func remove(_ s: RecentSession) { sessions.removeAll { $0.id == s.id }; save() }
    func clear() { sessions.removeAll(); save() }

    func addPath(_ p: String, directory: Bool) {
        if directory { dirPaths.removeAll { $0 == p }; dirPaths.insert(p, at: 0); dirPaths = Array(dirPaths.prefix(15)) }
        else { filePaths.removeAll { $0 == p }; filePaths.insert(p, at: 0); filePaths = Array(filePaths.prefix(15)) }
        UserDefaults.standard.set(filePaths, forKey: "recentFiles")
        UserDefaults.standard.set(dirPaths, forKey: "recentDirs")
    }
    func paths(directories: Bool) -> [String] { directories ? dirPaths : filePaths }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: "recentSessions") }
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var tabs: [Tab] = [Tab(session: nil)]
    @Published var selected: UUID

    init() {
        selected = UUID()
        selected = tabs[0].id
        DispatchQueue.main.async { self.openFromCommandLine() }
    }

    var current: BaseSession? { tabs.first { $0.id == selected }?.session }

    func perform(_ cmd: AppCommand) {
        if let s = current, s.handle(cmd) { return }
        switch cmd {
        case .undo: NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case .redo: NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        default: NSSound.beep()
        }
    }

    func newHomeTab() {
        let t = Tab(session: nil)
        tabs.append(t)
        selected = t.id
    }

    func close(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let s = tabs[idx].session, !s.confirmClose() { return }
        withAnimation(.easeOut(duration: 0.15)) {
            tabs.remove(at: idx)
            if tabs.isEmpty { tabs = [Tab(session: nil)] }
            if selected == id { selected = tabs[min(idx, tabs.count - 1)].id }
        }
    }

    func closeCurrent() {
        if tabs.count == 1 && tabs[0].session == nil { NSApp.keyWindow?.performClose(nil); return }
        close(selected)
    }

    func selectTab(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selected }) else { return }
        selected = tabs[(i + offset + tabs.count) % tabs.count].id
    }

    /// Opens a new session. Replaces the current tab if it is an empty home tab.
    func open(_ kind: SessionKind, urls: [URL?] = []) {
        let session: BaseSession
        switch kind {
        case .text: session = TextSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil)
        case .folder: session = FolderSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil, syncMode: false)
        case .sync: session = FolderSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil, syncMode: true)
        case .merge: session = MergeSession(left: urls[safe: 0] ?? nil, base: urls[safe: 1] ?? nil, right: urls[safe: 2] ?? nil)
        case .table: session = TableSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil)
        case .hex: session = HexSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil)
        case .image: session = ImageSession(left: urls[safe: 0] ?? nil, right: urls[safe: 1] ?? nil)
        }
        let paths = urls.map { $0?.path ?? "" }
        Recents.shared.add(kind: kind, paths: paths)
        withAnimation(.easeOut(duration: 0.15)) {
            if let i = tabs.firstIndex(where: { $0.id == selected }), tabs[i].session == nil {
                // Swap in a fresh Tab (new id) rather than mutating the home tab in place:
                // Tab equality is by id, so an in-place change can leave views showing Home.
                let t = Tab(session: session)
                tabs[i] = t
                selected = t.id
            } else {
                let t = Tab(session: session)
                if let i = tabs.firstIndex(where: { $0.id == selected }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
                selected = t.id
            }
        }
    }

    func reopen(_ r: RecentSession) {
        open(r.kind, urls: r.paths.map { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
    }

    /// Picks the most suitable session type for the given items.
    static func detectKind(_ urls: [URL]) -> SessionKind {
        var isDir: ObjCBool = false
        if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }) { return .folder }
        if urls.count == 3 { return .merge }
        return fileKind(urls)
    }

    static func fileKind(_ urls: [URL]) -> SessionKind {
        let types = urls.compactMap { UTType(filenameExtension: $0.pathExtension) }
        if !types.isEmpty, types.allSatisfy({ $0.conforms(to: .image) }) { return .image }
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        if exts.isSubset(of: ["csv", "tsv"]) { return .table }
        for u in urls {
            if let h = try? FileHandle(forReadingFrom: u) {
                let d = (try? h.read(upToCount: 8000)) ?? Data()
                try? h.close()
                if TextDocument.looksBinary(d) && !(d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF])) { return .hex }
            }
        }
        return .text
    }

    func openAuto(_ urls: [URL]) {
        guard urls.count >= 2 else {
            if let u = urls.first { open(Self.detectKind([u]) == .folder ? .folder : Self.fileKind([u]), urls: [u, nil]) }
            return
        }
        open(Self.detectKind(Array(urls.prefix(3))), urls: Array(urls.prefix(3)))
    }

    private var pendingOpen: [URL] = []
    /// Files opened from Finder arrive one URL at a time; batch them so two files become one session.
    func enqueueOpen(_ url: URL) {
        pendingOpen.append(url)
        let n = pendingOpen.count
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.pendingOpen.count == n else { return }
            let urls = self.pendingOpen; self.pendingOpen = []
            self.openAuto(urls)
        }
    }

    private func openFromCommandLine() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = args.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.count >= 2 { openAuto(urls) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
