import AppKit
import SwiftUI
import JuxtaCore

enum FolderFilter: String, CaseIterable {
    case all = "All", diffs = "Diffs", same = "Same", orphans = "Orphans", newerLeft = "Newer Left", newerRight = "Newer Right"
}

final class FolderSession: BaseSession {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published var settings = FolderCompareSettings() { didSet { if settings != oldValue { rescan() } } }
    @Published private(set) var root: FolderNode?
    @Published var expanded: Set<String> = []
    @Published var filter: FolderFilter = .all { didSet { rebuild() } }
    @Published var quickFilter = "" { didSet { rebuild() } }
    @Published private(set) var visible: [FolderNode] = []
    @Published var selection: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var progress = ""
    @Published private(set) var summary = FolderSummary()
    @Published var showSync: Bool
    @Published var syncMode: SyncMode = .updateRight { didSet { replan() } }
    @Published private(set) var plan: [SyncAction] = []
    private var nodes: [String: FolderNode] = [:]
    private var scanID = 0
    private var cancelFlag = false

    init(left: URL?, right: URL?, syncMode: Bool) {
        self.showSync = syncMode
        super.init(kind: syncMode ? .sync : .folder)
        settings.excludePatterns = Prefs.shared.folderExcludes
        leftURL = left; rightURL = right
        refreshTitle()
        rescan()
    }

    override var recentPaths: [String] { [leftURL?.path ?? "", rightURL?.path ?? ""] }

    private func refreshTitle() {
        let l = leftURL?.lastPathComponent ?? "—", r = rightURL?.lastPathComponent ?? "—"
        title = l == r ? l : "\(l) ↔ \(r)"
    }

    func setURL(_ u: URL, side: Int) {
        if side == 0 { leftURL = u } else { rightURL = u }
        refreshTitle()
        Recents.shared.add(kind: kind, paths: recentPaths)
        expanded.removeAll()
        rescan()
    }

    // MARK: Scanning

    func rescan() {
        guard leftURL != nil || rightURL != nil else { return }
        scanID += 1
        let id = scanID
        cancelFlag = false
        scanning = true
        let l = leftURL, r = rightURL, st = settings
        let firstScan = root == nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var last = Date.distantPast
            let tree = FolderScanner.compare(left: l, right: r, settings: st, cancelled: { [weak self] in self?.cancelFlag ?? true || self?.scanID != id }) { path in
                if Date().timeIntervalSince(last) > 0.1 {
                    last = Date()
                    DispatchQueue.main.async { self?.progress = path }
                }
            }
            DispatchQueue.main.async {
                guard let self, id == self.scanID else { return }
                self.root = tree
                self.nodes.removeAll()
                tree.walk { self.nodes[$0.id] = $0 }
                if firstScan || self.expanded.isEmpty {
                    // Expand folders that contain differences so changes are visible immediately.
                    tree.walk { n in if n.depth >= 0 && n.isDirectory && n.status == .folderDiffers && n.depth < 6 { self.expanded.insert(n.id) } }
                }
                self.summary = FolderScanner.summary(tree)
                self.scanning = false
                self.progress = ""
                self.rebuild()
                self.replan()
            }
        }
    }

    func cancelScan() { cancelFlag = true; scanning = false }

    func passes(_ n: FolderNode) -> Bool {
        if !quickFilter.isEmpty && !n.isDirectory && !n.name.localizedCaseInsensitiveContains(quickFilter) { return false }
        switch filter {
        case .all: return true
        case .diffs: return n.status != .same
        case .same: return n.status == .same
        case .orphans: return n.status.isOrphan
        case .newerLeft: return n.status == .leftNewer
        case .newerRight: return n.status == .rightNewer
        }
    }

    /// Whether the node, or something below it, should be listed.
    private func shows(_ n: FolderNode) -> Bool {
        if !n.isDirectory { return passes(n) }
        if filter == .all && quickFilter.isEmpty { return true }
        if passes(n) && quickFilter.isEmpty && n.children.isEmpty { return true }
        return n.children.contains { shows($0) }
    }

    func rebuild() {
        var out: [FolderNode] = []
        let forceOpen = !quickFilter.isEmpty
        func visit(_ n: FolderNode) {
            for c in n.children where shows(c) {
                out.append(c)
                if c.isDirectory && (expanded.contains(c.id) || forceOpen) { visit(c) }
            }
        }
        if let root { visit(root) }
        visible = out
    }

    func toggle(_ n: FolderNode) {
        if expanded.contains(n.id) { expanded.remove(n.id) } else { expanded.insert(n.id) }
        rebuild()
    }

    func expandAll() { root?.walk { if $0.isDirectory && $0.depth >= 0 { expanded.insert($0.id) } }; rebuild() }
    func collapseAll() { expanded.removeAll(); rebuild() }

    func swap() {
        Swift.swap(&leftURL, &rightURL)
        refreshTitle()
        rescan()
    }

    var selectedNodes: [FolderNode] { selection.compactMap { nodes[$0] }.sorted { $0.id < $1.id } }

    // MARK: File operations

    private func destination(for n: FolderNode, side: Int) -> URL? {
        guard let base = side == 0 ? leftURL : rightURL else { return nil }
        var rel = n.id
        if rel.hasSuffix("#L") || rel.hasSuffix("#R") { rel.removeLast(2) }
        if rel.hasPrefix("/") { rel.removeFirst() }
        return base.appendingPathComponent(rel)
    }

    func copy(_ list: [FolderNode], toRight: Bool) {
        let items = list.filter { toRight ? $0.left != nil : $0.right != nil }
        guard !items.isEmpty else { NSSound.beep(); return }
        let names = items.prefix(6).map { "• " + $0.name }.joined(separator: "\n") + (items.count > 6 ? "\n…and \(items.count - 6) more" : "")
        guard runAlert("Copy \(items.count) item\(items.count == 1 ? "" : "s") to the \(toRight ? "right" : "left")?",
                       names + "\n\nExisting items are moved to the Trash first.", buttons: ["Copy", "Cancel"]) == 0 else { return }
        let actions = items.compactMap { n -> SyncAction? in
            guard let dst = destination(for: n, side: toRight ? 1 : 0) else { return nil }
            return SyncAction(kind: toRight ? .copyToRight : .copyToLeft, path: n.name,
                              source: toRight ? n.left?.url : n.right?.url, destination: dst, isDirectory: n.isDirectory)
        }
        run(actions)
    }

    func trash(_ list: [FolderNode], side: Int) {
        let urls = list.compactMap { side == 0 ? $0.left?.url : $0.right?.url }
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard runAlert("Move \(urls.count) item\(urls.count == 1 ? "" : "s") on the \(side == 0 ? "left" : "right") to the Trash?",
                       urls.prefix(6).map { "• " + $0.lastPathComponent }.joined(separator: "\n"), buttons: ["Move to Trash", "Cancel"], style: .warning) == 0 else { return }
        run(urls.map { SyncAction(kind: side == 0 ? .trashLeft : .trashRight, path: $0.lastPathComponent, source: nil, destination: $0, isDirectory: false) })
    }

    func touch(_ list: [FolderNode], toMatch side: Int) {
        // Sets the other side's modification date to this side's, making size-equal files "same".
        for n in list {
            guard let src = side == 0 ? n.left : n.right, let dst = side == 0 ? n.right : n.left else { continue }
            try? FileManager.default.setAttributes([.modificationDate: src.modified], ofItemAtPath: dst.url.path)
        }
        rescan()
    }

    private func run(_ actions: [SyncAction]) {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let errors = SyncPlanner.execute(actions)
            DispatchQueue.main.async {
                guard let self else { return }
                if !errors.isEmpty { _ = runAlert("Some items couldn't be processed", errors.prefix(10).joined(separator: "\n"), style: .warning) }
                self.rescan()
            }
        }
    }

    func open(_ n: FolderNode, as forced: SessionKind? = nil) {
        if n.isDirectory {
            if forced == .folder { AppModel.shared.open(.folder, urls: [n.left?.url, n.right?.url]) } else { toggle(n) }
            return
        }
        let urls = [n.left?.url, n.right?.url]
        let kind = forced ?? AppModel.fileKind(urls.compactMap { $0 })
        AppModel.shared.open(kind, urls: urls)
    }

    func reveal(_ n: FolderNode, side: Int) {
        if let u = side == 0 ? n.left?.url : n.right?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    // MARK: Sync

    func replan() {
        guard let root, let l = leftURL, let r = rightURL else { plan = []; return }
        plan = SyncPlanner.plan(root: root, leftRoot: l, rightRoot: r, mode: syncMode)
    }

    func runSync() {
        guard !plan.isEmpty else { return }
        let copies = plan.filter { $0.kind == .copyToLeft || $0.kind == .copyToRight }.count
        let trashes = plan.count - copies
        guard runAlert("\(syncMode.rawValue)?", "\(copies) copy operation(s) and \(trashes) item(s) moved to the Trash. Replaced files are moved to the Trash first.",
                       buttons: ["Synchronize", "Cancel"], style: trashes > 0 ? .warning : .informational) == 0 else { return }
        run(plan)
    }

    func exportReport() {
        guard let root else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "Folder Report.html"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? Report.folderHTML(root: root, left: leftURL, right: rightURL).write(to: u, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(u)
    }

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .reload: rescan()
        case .swap: swap()
        case .expandAll: expandAll()
        case .collapseAll: collapseAll()
        case .copyToRight: copy(selectedNodes, toRight: true)
        case .copyToLeft: copy(selectedNodes, toRight: false)
        case .showAll: filter = .all
        case .showDiffs: filter = .diffs
        case .showSame: filter = .same
        case .exportReport: exportReport()
        case .nextDiff, .prevDiff:
            let ids = visible.filter { !$0.isDirectory && $0.status != .same }.map(\.id)
            guard !ids.isEmpty else { NSSound.beep(); return true }
            let cur = visible.firstIndex { selection.contains($0.id) } ?? -1
            let pos = visible.indices
            if cmd == .nextDiff, let k = pos.first(where: { $0 > cur && ids.contains(visible[$0].id) }) { selection = [visible[k].id] }
            else if cmd == .prevDiff, let k = pos.last(where: { $0 < max(cur, 0) && ids.contains(visible[$0].id) }) { selection = [visible[k].id] }
            else { NSSound.beep() }
        default: return false
        }
        return true
    }
}

// MARK: - View

struct FolderCompareView: View {
    @ObservedObject var s: FolderSession
    @State private var showFilters = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    headers
                    columnHeader
                    list
                }
                if s.showSync {
                    Rectangle().fill(Color.jSeparator).frame(width: 1)
                    SyncPanel(s: s).frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            statusBar
        }
        .sheet(isPresented: $showFilters) { FolderFilterSheet(settings: $s.settings) }
    }

    var toolbar: some View {
        Toolbar {
            Group {
                ToolButton(icon: "line.3.horizontal", label: "All", active: s.filter == .all) { s.filter = .all }
                ToolButton(icon: "plus.forwardslash.minus", label: "Diffs", active: s.filter == .diffs) { s.filter = .diffs }
                ToolButton(icon: "equal", label: "Same", active: s.filter == .same) { s.filter = .same }
                ToolButton(icon: "circle.lefthalf.filled", label: "Orphans", active: s.filter == .orphans) { s.filter = .orphans }
                ToolButton(icon: "arrow.left.to.line", label: "Newer L", active: s.filter == .newerLeft) { s.filter = .newerLeft }
                ToolButton(icon: "arrow.right.to.line", label: "Newer R", active: s.filter == .newerRight) { s.filter = .newerRight }
            }
            ToolDivider()
            Menu {
                Picker("Compare by", selection: $s.settings.criteria) {
                    ForEach(FolderCriteria.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show Hidden Files", isOn: $s.settings.includeHidden)
                Divider()
                Button("Name Filters…") { showFilters = true }
            } label: { ToolMenuLabel(icon: "slider.horizontal.3", label: "Rules", active: s.settings.criteria != .sizeAndTime) }
                .toolMenu()
            ToolButton(icon: "line.3.horizontal.decrease.circle", label: "Filters", active: !s.settings.includePatterns.isEmpty) { showFilters = true }
            ToolDivider()
            Group {
                ToolButton(icon: "arrowshape.left.fill", label: "Copy Left", tint: .jOrphan, enabled: !s.selection.isEmpty) { s.copy(s.selectedNodes, toRight: false) }
                ToolButton(icon: "arrowshape.right.fill", label: "Copy Right", tint: .jOrphan, enabled: !s.selection.isEmpty) { s.copy(s.selectedNodes, toRight: true) }
                ToolButton(icon: "doc.text.magnifyingglass", label: "Compare", enabled: s.selection.count == 1) { if let n = s.selectedNodes.first { s.open(n) } }
            }
            ToolDivider()
            Group {
                ToolButton(icon: "plus.square.on.square", label: "Expand") { s.expandAll() }
                ToolButton(icon: "minus.square", label: "Collapse") { s.collapseAll() }
                ToolButton(icon: "arrow.left.arrow.right", label: "Swap") { s.swap() }
                ToolButton(icon: "arrow.clockwise", label: "Refresh") { s.rescan() }
                ToolButton(icon: "arrow.triangle.2.circlepath", label: "Sync", active: s.showSync) { withAnimation(.easeOut(duration: 0.2)) { s.showSync.toggle() } }
                ToolButton(icon: "square.and.arrow.up", label: "Report") { s.exportReport() }
            }
            Spacer(minLength: 10)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter names", text: $s.quickFilter).textFieldStyle(.plain).frame(width: 140)
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        }
    }

    var headers: some View {
        HStack(spacing: 0) {
            PathField(placeholder: "Left folder", url: $s.leftURL, directories: true) { s.setURL($0, side: 0) }
                .padding(.horizontal, 10)
            Color.clear.frame(width: 30)
            PathField(placeholder: "Right folder", url: $s.rightURL, directories: true) { s.setURL($0, side: 1) }
                .padding(.horizontal, 10)
        }
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.jGutter)
    }

    var columnHeader: some View {
        HStack(spacing: 0) {
            sideColumns
            Color.clear.frame(width: 30)
            sideColumns
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.jGutter)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
    }

    var sideColumns: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
            Text("Size").frame(width: 76, alignment: .trailing)
            Text("Modified").frame(width: 130, alignment: .trailing).padding(.trailing, 10)
        }
    }

    @ViewBuilder var list: some View {
        ZStack {
            List(s.visible, id: \.id, selection: $s.selection) { n in
                FolderRow(n: n, expanded: s.expanded.contains(n.id), forceOpen: !s.quickFilter.isEmpty) { s.toggle(n) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            .environment(\.defaultMinListRowHeight, 22)
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(ids)
            } primaryAction: { ids in
                if let id = ids.first, let n = s.visible.first(where: { $0.id == id }) { s.open(n) }
            }
            if s.scanning {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.regular)
                    Text("Scanning \(s.progress.isEmpty ? "…" : s.progress)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Cancel") { s.cancelScan() }.controlSize(.small)
                }
                .padding(18)
                .frame(maxWidth: 380)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            } else if s.root != nil && s.visible.isEmpty {
                Text(s.filter == .all ? "Both folders are empty" : "Nothing matches the “\(s.filter.rawValue)” filter").foregroundStyle(.secondary)
            } else if s.leftURL == nil && s.rightURL == nil {
                EmptyDropHint(text: "Choose or drop a folder on each side")
            }
        }
    }

    @ViewBuilder func contextMenu(_ ids: Set<String>) -> some View {
        let list = s.visible.filter { ids.contains($0.id) }
        if let n = list.first {
            if list.count == 1 {
                Button(n.isDirectory ? "Compare Folders in New Tab" : "Compare") { s.open(n, as: n.isDirectory ? .folder : nil) }
                if !n.isDirectory {
                    Menu("Compare As") {
                        Button("Text Compare") { s.open(n, as: .text) }
                        Button("Table Compare") { s.open(n, as: .table) }
                        Button("Hex Compare") { s.open(n, as: .hex) }
                        Button("Picture Compare") { s.open(n, as: .image) }
                    }
                }
                Divider()
            }
            Button("Copy to Right →") { s.copy(list, toRight: true) }
            Button("← Copy to Left") { s.copy(list, toRight: false) }
            Divider()
            Button("Make Left Date Match Right") { s.touch(list, toMatch: 1) }
            Button("Make Right Date Match Left") { s.touch(list, toMatch: 0) }
            Divider()
            Button("Reveal Left in Finder") { s.reveal(n, side: 0) }.disabled(n.left == nil)
            Button("Reveal Right in Finder") { s.reveal(n, side: 1) }.disabled(n.right == nil)
            Divider()
            Button("Move Left to Trash") { s.trash(list, side: 0) }
            Button("Move Right to Trash") { s.trash(list, side: 1) }
        }
    }

    var statusBar: some View {
        StatusBar {
            let m = s.summary
            if s.root == nil { Text("Ready") }
            else if m.files == m.same && m.files > 0 { Label("Folders are identical (\(m.files) files)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.jAdded) }
            else { Text("\(m.files) files").fontWeight(.medium).foregroundStyle(.primary) }
            if s.root != nil {
                StatChip(color: .jAdded.opacity(0.6), text: "\(m.same) same")
                StatChip(color: .jChanged, text: "\(m.different + m.leftNewer + m.rightNewer) different")
                StatChip(color: .jOrphan, text: "\(m.leftOnly) left-only")
                StatChip(color: .jOrphan.opacity(0.6), text: "\(m.rightOnly) right-only")
            }
            Spacer()
            if !s.selection.isEmpty { Text("\(s.selection.count) selected") }
            Text(s.settings.criteria.rawValue)
        }
    }
}

struct FolderRow: View {
    let n: FolderNode
    let expanded: Bool
    let forceOpen: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            side(n.left, isLeft: true)
            statusGlyph.frame(width: 30)
            side(n.right, isLeft: false)
        }
        .frame(height: 22)
        .background(rowTint)
    }

    var rowTint: Color {
        switch n.status {
        case .same, .folderDiffers: return .clear
        case .leftOnly, .rightOnly: return Color(nsColor: Palette.orphanBG).opacity(0.55)
        default: return Color(nsColor: Palette.changedBG).opacity(0.55)
        }
    }

    func color(isLeft: Bool) -> Color {
        switch n.status {
        case .same: return .primary
        case .folderDiffers: return .jChanged
        case .leftOnly, .rightOnly: return .jOrphan
        case .different: return .jChanged
        case .leftNewer: return isLeft ? .jChanged : .secondary
        case .rightNewer: return isLeft ? .secondary : .jChanged
        }
    }

    @ViewBuilder func side(_ m: FileMeta?, isLeft: Bool) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(n.depth) * 16 + 4)
            if n.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded || forceOpen ? 90 : 0))
                    .frame(width: 12)
                    .contentShape(Rectangle().inset(by: -5))
                    .onTapGesture(perform: onToggle)
                    .opacity(m == nil ? 0.3 : 1)
            } else { Color.clear.frame(width: 12) }
            if let m {
                Image(nsImage: icon(m.url, dir: m.isDirectory)).resizable().frame(width: 16, height: 16)
                Text(n.name).foregroundStyle(color(isLeft: isLeft)).lineLimit(1).truncationMode(.middle)
                    .fontWeight(n.status == .same ? .regular : .medium)
                Spacer(minLength: 4)
                Text(m.isDirectory ? "" : formatBytes(m.size)).foregroundStyle(.secondary).frame(width: 76, alignment: .trailing).monospacedDigit()
                Text(shortDate.string(from: m.modified)).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing).padding(.trailing, 10).monospacedDigit()
            } else {
                Spacer()
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder var statusGlyph: some View {
        switch n.status {
        case .same: Image(systemName: "equal").foregroundStyle(.tertiary)
        case .leftNewer: Image(systemName: "chevron.left").foregroundStyle(Color.jChanged)
        case .rightNewer: Image(systemName: "chevron.right").foregroundStyle(Color.jChanged)
        case .different, .folderDiffers: Image(systemName: "notequal").foregroundStyle(Color.jChanged)
        case .leftOnly: Image(systemName: "arrow.left.square.fill").foregroundStyle(Color.jOrphan)
        case .rightOnly: Image(systemName: "arrow.right.square.fill").foregroundStyle(Color.jOrphan)
        }
    }
}

private var iconCache: [String: NSImage] = [:]
func icon(_ url: URL, dir: Bool) -> NSImage {
    let key = dir ? "/dir" : url.pathExtension.lowercased()
    if let i = iconCache[key] { return i }
    let i = dir ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(for: .init(filenameExtension: key) ?? .data)
    iconCache[key] = i
    return i
}

struct SyncPanel: View {
    @ObservedObject var s: FolderSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Synchronize").font(.system(size: 14, weight: .semibold)).padding([.horizontal, .top], 16)
            VStack(spacing: 6) {
                ForEach(SyncMode.allCases, id: \.self) { m in
                    Button { s.syncMode = m } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.syncMode == m ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(s.syncMode == m ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.rawValue).font(.system(size: 12.5, weight: .medium))
                                Text(m.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(s.syncMode == m ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            Divider()
            HStack {
                Text("Preview").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(s.plan.count) action\(s.plan.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if s.plan.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("Nothing to do").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(s.plan) { a in
                    HStack(spacing: 8) {
                        Text(a.kind.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(a.kind == .trashLeft || a.kind == .trashRight ? Color.red : Color.accentColor)
                            .frame(width: 72, alignment: .leading)
                        Image(systemName: a.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(a.path).font(.system(size: 11.5)).lineLimit(1).truncationMode(.head)
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            Button { s.runSync() } label: {
                Label("Synchronize Now", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(s.plan.isEmpty || s.scanning)
            .padding(14)
        }
        .background(Color.jGutter)
    }
}

struct FolderFilterSheet: View {
    @Binding var settings: FolderCompareSettings
    @Environment(\.dismiss) var dismiss
    @State private var include = ""
    @State private var exclude = ""
    @State private var hidden = false
    @State private var tolerance = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folder Filters").font(.headline)
            Form {
                TextField("Include files", text: $include, prompt: Text("*.swift;*.md  (empty = all)"))
                TextField("Exclude", text: $exclude, prompt: Text(".git;node_modules;*.o"))
                Toggle("Include hidden files", isOn: $hidden)
                HStack {
                    Text("Timestamp tolerance")
                    Slider(value: $tolerance, in: 0...3600, step: 1)
                    Text(tolerance < 60 ? "\(Int(tolerance)) s" : "\(Int(tolerance / 60)) min").monospacedDigit().frame(width: 60)
                }
            }
            .formStyle(.grouped)
            Text("Wildcards: * matches anything, ? one character. Separate patterns with semicolons.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    var s = settings
                    s.includePatterns = include; s.excludePatterns = exclude; s.includeHidden = hidden; s.timeTolerance = tolerance
                    settings = s
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
        .onAppear { include = settings.includePatterns; exclude = settings.excludePatterns; hidden = settings.includeHidden; tolerance = settings.timeTolerance }
    }
}
