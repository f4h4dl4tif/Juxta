import AppKit
import SwiftUI
import JuxtaCore

final class MergeSession: BaseSession {
    @Published var urls: [URL?]                 // left, base, right
    @Published private(set) var docs: [TextDocument] = [TextDocument(), TextDocument(), TextDocument()]
    @Published private(set) var chunks: [MergeChunk] = []
    @Published var currentChunk: Int? = nil
    @Published var outputURL: URL? = nil
    @Published var options = CompareOptions() { didSet { if options != oldValue { remerge() } } }

    let top = DiffCanvas()
    let bottom = DiffCanvas()
    private lazy var topSource = MergeTopSource(self)
    private lazy var outSource = MergeOutputSource(self)
    private(set) var topRows: [(chunk: Int, offset: Int)] = []
    private(set) var outRows: [(chunk: Int, offset: Int, text: String, marker: Bool)] = []
    private var chunkTopStart: [Int] = []
    private var chunkOutStart: [Int] = []
    private var undoStack: [[MergeChunk]] = []
    private var redoStack: [[MergeChunk]] = []

    init(left: URL?, base: URL?, right: URL?) {
        urls = [left, base, right]
        super.init(kind: .merge)
        top.dataSource = topSource
        bottom.dataSource = outSource
        top.onCurrentRowChanged = { [weak self] r in self?.selectFromTop(r) }
        bottom.onCurrentRowChanged = { [weak self] r in self?.selectFromOutput(r) }
        bottom.onEditCommit = { [weak self] row, _, text in self?.editOutput(row: row, text: text) }
        bottom.onDelete = { [weak self] rows, _ in self?.deleteOutput(rows: rows) }
        top.menuProvider = { [weak self] _, _ in self?.menu() }
        bottom.menuProvider = { [weak self] _, _ in self?.menu() }
        for i in 0..<3 { load(i) }
        remerge()
    }

    override var recentPaths: [String] { urls.map { $0?.path ?? "" } }

    func load(_ i: Int) {
        if let u = urls[i] {
            do { docs[i] = try TextDocument.load(u) }
            catch { _ = runAlert("Couldn't open \(u.lastPathComponent)", error.localizedDescription, style: .warning) }
        } else { docs[i] = TextDocument() }
        let names = urls.map { $0?.lastPathComponent ?? "—" }
        title = "Merge: \(names[0]) ⇄ \(names[2])"
    }

    func setURL(_ u: URL, index: Int) {
        urls[index] = u
        load(index)
        Recents.shared.add(kind: .merge, paths: recentPaths)
        remerge()
    }

    var left: [String] { docs[0].lines }
    var base: [String] { docs[1].lines }
    var right: [String] { docs[2].lines }

    func remerge() {
        chunks = Merge3.merge(base: base, left: left, right: right, options: options)
        undoStack.removeAll(); redoStack.removeAll()
        isDirty = false
        rebuild()
        if let c = chunks.firstIndex(where: { $0.kind == .conflict }) ?? chunks.firstIndex(where: { $0.isChange }) { select(c) }
    }

    func rebuild() {
        topRows.removeAll(); outRows.removeAll()
        chunkTopStart = []; chunkOutStart = []
        for (ci, c) in chunks.enumerated() {
            chunkTopStart.append(topRows.count)
            let n = max(c.left.count, c.base.count, c.right.count)
            for k in 0..<n { topRows.append((ci, k)) }
            chunkOutStart.append(outRows.count)
            if let lines = Merge3.lines(for: c, base: base, left: left, right: right) {
                for (k, t) in lines.enumerated() { outRows.append((ci, k, t, false)) }
            } else {
                outRows.append((ci, -1, "<<<<<<< \(urls[0]?.lastPathComponent ?? "LEFT")", true))
                for t in left[c.left] { outRows.append((ci, -1, t, true)) }
                outRows.append((ci, -1, "=======", true))
                for t in right[c.right] { outRows.append((ci, -1, t, true)) }
                outRows.append((ci, -1, ">>>>>>> \(urls[2]?.lastPathComponent ?? "RIGHT")", true))
            }
        }
        top.reload(); bottom.reload()
    }

    var conflicts: Int { chunks.filter { $0.kind == .conflict }.count }
    var unresolved: Int { chunks.filter { $0.resolution == .unresolved }.count }
    var changes: Int { chunks.filter { $0.isChange }.count }

    // MARK: Selection

    private var syncing = false
    func select(_ c: Int, reveal: Bool = true) {
        guard c >= 0, c < chunks.count else { return }
        currentChunk = c
        syncing = true
        let ts = chunkTopStart[c], te = max(ts, (c + 1 < chunkTopStart.count ? chunkTopStart[c + 1] : topRows.count) - 1)
        let os = chunkOutStart[c], oe = max(os, (c + 1 < chunkOutStart.count ? chunkOutStart[c + 1] : outRows.count) - 1)
        if reveal {
            if ts < topRows.count { top.select(rows: ts...te) }
            if os < outRows.count { bottom.select(rows: os...oe) }
        }
        syncing = false
    }

    private func selectFromTop(_ r: Int) {
        guard !syncing, r < topRows.count else { return }
        let c = topRows[r].chunk
        currentChunk = c
        let os = chunkOutStart[c]
        if os < outRows.count { syncing = true; bottom.setCurrentRow(os, center: true); syncing = false }
    }

    private func selectFromOutput(_ r: Int) {
        guard !syncing, r < outRows.count else { return }
        let c = outRows[r].chunk
        currentChunk = c
        let ts = chunkTopStart[c]
        if ts < topRows.count { syncing = true; top.setCurrentRow(ts, center: true); syncing = false }
    }

    func navigate(forward: Bool, conflictsOnly: Bool) {
        let cur = currentChunk ?? (forward ? -1 : chunks.count)
        let cands = chunks.indices.filter { conflictsOnly ? chunks[$0].kind == .conflict : chunks[$0].isChange }
        if let n = forward ? cands.first(where: { $0 > cur }) : cands.last(where: { $0 < cur }) { select(n) } else { NSSound.beep() }
    }

    // MARK: Resolution

    private func pushUndo() { undoStack.append(chunks); redoStack.removeAll(); isDirty = true }

    func resolve(_ r: MergeResolution) {
        guard let c = currentChunk, chunks[c].isChange else { NSSound.beep(); return }
        pushUndo()
        chunks[c].resolution = r
        rebuild()
        select(c)
    }

    func resolveAll(_ r: MergeResolution, conflictsOnly: Bool = true) {
        pushUndo()
        for i in chunks.indices where conflictsOnly ? chunks[i].kind == .conflict : chunks[i].isChange { chunks[i].resolution = r }
        rebuild()
    }

    func editOutput(row: Int, text: String) {
        guard row < outRows.count else { return }
        let o = outRows[row]
        guard !o.marker, var lines = Merge3.lines(for: chunks[o.chunk], base: base, left: left, right: right) else {
            NSSound.beep(); return
        }
        pushUndo()
        lines[o.offset] = text
        chunks[o.chunk].resolution = .custom(lines)
        rebuild(); select(o.chunk, reveal: false)
    }

    func deleteOutput(rows: ClosedRange<Int>) {
        var byChunk: [Int: Set<Int>] = [:]
        for r in rows where r < outRows.count && !outRows[r].marker { byChunk[outRows[r].chunk, default: []].insert(outRows[r].offset) }
        guard !byChunk.isEmpty else { NSSound.beep(); return }
        pushUndo()
        for (c, offs) in byChunk {
            let lines = Merge3.lines(for: chunks[c], base: base, left: left, right: right) ?? []
            chunks[c].resolution = .custom(lines.enumerated().filter { !offs.contains($0.offset) }.map(\.element))
        }
        rebuild()
    }

    func undo() { guard let s = undoStack.popLast() else { NSSound.beep(); return }; redoStack.append(chunks); chunks = s; rebuild() }
    func redo() { guard let s = redoStack.popLast() else { NSSound.beep(); return }; undoStack.append(chunks); chunks = s; rebuild() }

    private func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Take Left") { [weak self] in self?.resolve(.left) })
        m.addItem(ClosureMenuItem(title: "Take Right") { [weak self] in self?.resolve(.right) })
        m.addItem(ClosureMenuItem(title: "Take Left, then Right") { [weak self] in self?.resolve(.leftThenRight) })
        m.addItem(ClosureMenuItem(title: "Take Right, then Left") { [weak self] in self?.resolve(.rightThenLeft) })
        m.addItem(ClosureMenuItem(title: "Take Base") { [weak self] in self?.resolve(.base) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Mark Unresolved") { [weak self] in self?.resolve(.unresolved) })
        return m
    }

    // MARK: Saving

    var outputLines: [String] {
        Merge3.output(chunks, base: base, left: left, right: right,
                      leftLabel: urls[0]?.lastPathComponent ?? "LEFT", rightLabel: urls[2]?.lastPathComponent ?? "RIGHT")
    }

    func save(as forceAsk: Bool = false) {
        if unresolved > 0, runAlert("\(unresolved) conflict\(unresolved == 1 ? " is" : "s are") unresolved",
                                    "Unresolved conflicts are written with conflict markers.", buttons: ["Save Anyway", "Cancel"], style: .warning) != 0 { return }
        var url = outputURL
        if url == nil || forceAsk {
            let p = NSSavePanel()
            p.nameFieldStringValue = urls[1]?.lastPathComponent ?? "merged.txt"
            if let d = urls[1]?.deletingLastPathComponent() { p.directoryURL = d }
            guard p.runModal() == .OK else { return }
            url = p.url
        }
        guard let url else { return }
        var doc = docs[1]
        if doc.lines.isEmpty { doc = docs[0] }
        doc.lines = outputLines
        do { try doc.write(to: url); outputURL = url; isDirty = false }
        catch { _ = runAlert("Couldn't save", error.localizedDescription, style: .warning) }
    }

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .nextDiff: navigate(forward: true, conflictsOnly: false)
        case .prevDiff: navigate(forward: false, conflictsOnly: false)
        case .firstDiff: currentChunk = nil; navigate(forward: true, conflictsOnly: false)
        case .lastDiff: currentChunk = nil; navigate(forward: false, conflictsOnly: false)
        case .copyToLeft: resolve(.left)
        case .copyToRight: resolve(.right)
        case .save, .saveAll: save()
        case .reload: for i in 0..<3 { load(i) }; remerge()
        case .undo: if bottom.window?.firstResponder is NSTextView { return false }; undo()
        case .redo: if bottom.window?.firstResponder is NSTextView { return false }; redo()
        default: return false
        }
        return true
    }
}

final class MergeTopSource: CanvasDataSource {
    unowned let s: MergeSession
    init(_ s: MergeSession) { self.s = s }
    var rowCount: Int { s.topRows.count }
    var paneCount: Int { 3 }
    var maxColumns: Int { 400 }

    func cell(row: Int, pane: Int) -> CanvasCell {
        guard row < s.topRows.count else { return .filler }
        let (ci, off) = s.topRows[row]
        let c = s.chunks[ci]
        let range = pane == 0 ? c.left : pane == 1 ? c.base : c.right
        guard off < range.count else { return .filler }
        let lines = pane == 0 ? s.left : pane == 1 ? s.base : s.right
        let idx = range.lowerBound + off
        var cell = CanvasCell(text: lines[idx], lineNumber: idx + 1)
        switch c.kind {
        case .stable: cell.style = .normal
        case .conflict: cell.style = .conflict
        case .leftChange: cell.style = pane == 0 ? .changed : .normal
        case .rightChange: cell.style = pane == 2 ? .changed : .normal
        case .bothSame: cell.style = pane == 1 ? .normal : .changed
        }
        if cell.style != .normal && pane != 1 && off < c.base.count {
            let hl = TextDiff.intraline(s.base[c.base.lowerBound + off], lines[idx])
            cell.highlights = hl.right
        }
        return cell
    }

    func overviewMarks() -> [OverviewMark] {
        var out: [OverviewMark] = []
        var k = 0
        while k < s.topRows.count {
            let c = s.chunks[s.topRows[k].chunk]
            let start = k
            while k < s.topRows.count && s.topRows[k].chunk == c.id { k += 1 }
            if c.isChange { out.append(OverviewMark(rows: start..<k, style: c.kind == .conflict ? .conflict : .changed)) }
        }
        return out
    }
}

final class MergeOutputSource: CanvasDataSource {
    unowned let s: MergeSession
    init(_ s: MergeSession) { self.s = s }
    var rowCount: Int { s.outRows.count }
    var paneCount: Int { 1 }
    var maxColumns: Int { 400 }
    func isEditable(pane: Int) -> Bool { true }

    func cell(row: Int, pane: Int) -> CanvasCell {
        guard row < s.outRows.count else { return .filler }
        let o = s.outRows[row]
        let c = s.chunks[o.chunk]
        var cell = CanvasCell(text: o.text, lineNumber: o.marker ? nil : row + 1)
        if o.marker { cell.style = .conflict; return cell }
        switch c.resolution {
        case .base: cell.style = c.isChange ? .unimportant : .normal
        case .left, .leftThenRight: cell.style = c.isChange ? .takenLeft : .normal
        case .right, .rightThenLeft: cell.style = c.isChange ? .takenRight : .normal
        case .custom: cell.style = .changed
        case .unresolved: cell.style = .conflict
        }
        return cell
    }

    func overviewMarks() -> [OverviewMark] {
        var out: [OverviewMark] = []
        var k = 0
        while k < s.outRows.count {
            let c = s.chunks[s.outRows[k].chunk]
            let start = k
            while k < s.outRows.count && s.outRows[k].chunk == c.id { k += 1 }
            if c.isChange { out.append(OverviewMark(rows: start..<k, style: c.resolution == .unresolved ? .conflict : .takenLeft)) }
        }
        return out
    }
}

struct MergeView: View {
    @ObservedObject var s: MergeSession
    @State private var split: CGFloat = 0.58

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geo in
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            header(0, "Left (yours)")
                            header(1, "Base (common ancestor)")
                            header(2, "Right (theirs)")
                            Color.clear.frame(width: 16)
                        }
                        .padding(.vertical, 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color.jGutter)
                        CanvasHost(canvas: s.top)
                    }
                    .frame(height: max(160, (geo.size.height - 8) * split))
                    SplitHandle(fraction: $split, total: geo.size.height)
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.gearshape").foregroundStyle(Color.jAdded)
                            Text("Output").font(.system(size: 12, weight: .semibold))
                            if let u = s.outputURL { Text((u.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.secondary) }
                            else { Text("not saved yet — double-click a line to edit").font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            if s.unresolved > 0 {
                                Label("\(s.unresolved) unresolved", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.jConflict)
                            } else {
                                Label("All resolved", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.jAdded)
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Color.jGutter)
                        .overlay(alignment: .top) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
                        CanvasHost(canvas: s.bottom)
                    }
                }
            }
            StatusBar {
                Text("\(s.changes) change\(s.changes == 1 ? "" : "s")").fontWeight(.medium).foregroundStyle(.primary)
                StatChip(color: .jChanged, text: "\(s.changes - s.conflicts) auto-merged")
                StatChip(color: .jConflict, text: "\(s.conflicts) conflict\(s.conflicts == 1 ? "" : "s")")
                Spacer()
                if let c = s.currentChunk { Text("Section \(c + 1) of \(s.chunks.count)") }
            }
        }
    }

    var toolbar: some View {
        Toolbar {
            Group {
                ToolButton(icon: "exclamationmark.triangle", label: "Prev Conflict", tint: .jConflict) { s.navigate(forward: false, conflictsOnly: true) }
                ToolButton(icon: "exclamationmark.triangle.fill", label: "Next Conflict", tint: .jConflict) { s.navigate(forward: true, conflictsOnly: true) }
                ToolButton(icon: "chevron.up", label: "Prev Change") { s.navigate(forward: false, conflictsOnly: false) }
                ToolButton(icon: "chevron.down", label: "Next Change") { s.navigate(forward: true, conflictsOnly: false) }
            }
            ToolDivider()
            Group {
                ToolButton(icon: "arrow.down.left", label: "Take Left", tint: .jAdded) { s.resolve(.left) }
                ToolButton(icon: "arrow.down", label: "Take Base") { s.resolve(.base) }
                ToolButton(icon: "arrow.down.right", label: "Take Right", tint: .blue) { s.resolve(.right) }
                ToolButton(icon: "text.append", label: "Left+Right") { s.resolve(.leftThenRight) }
                ToolButton(icon: "text.insert", label: "Right+Left") { s.resolve(.rightThenLeft) }
            }
            Menu {
                Button("All Conflicts → Left") { s.resolveAll(.left) }
                Button("All Conflicts → Right") { s.resolveAll(.right) }
                Divider()
                Button("Reset to Automatic Merge") { s.remerge() }
            } label: { ToolMenuLabel(icon: "wand.and.stars", label: "Resolve All") }
                .toolMenu()
            ToolDivider()
            Menu {
                Picker("Whitespace", selection: $s.options.whitespace) {
                    ForEach(WhitespaceRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Ignore Case", isOn: $s.options.ignoreCase)
            } label: { ToolMenuLabel(icon: "slider.horizontal.3", label: "Rules", active: !s.options.isDefault) }
                .toolMenu()
            ToolButton(icon: "arrow.uturn.backward", label: "Undo") { s.undo() }
            ToolButton(icon: "arrow.uturn.forward", label: "Redo") { s.redo() }
            ToolDivider()
            ToolButton(icon: "square.and.arrow.down", label: "Save") { s.save() }
            ToolButton(icon: "square.and.arrow.down.on.square", label: "Save As") { s.save(as: true) }
            Spacer()
        }
    }

    func header(_ i: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            PathField(placeholder: label, url: Binding(get: { s.urls[i] }, set: { s.urls[i] = $0 })) { s.setURL($0, index: i) }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }
}

struct SplitHandle: View {
    @Binding var fraction: CGFloat
    let total: CGFloat
    @State private var start: CGFloat? = nil
    var body: some View {
        Rectangle().fill(Color.jSeparator).frame(height: 1)
            .padding(.vertical, 3.5)
            .background(Color.jGutter)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if start == nil { start = fraction }
                fraction = min(0.85, max(0.2, (start ?? fraction) + v.translation.height / max(1, total)))
            }.onEnded { _ in start = nil })
    }
}
