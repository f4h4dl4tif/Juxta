import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JuxtaCore

enum ViewFilter: String, CaseIterable { case all = "All", diffs = "Diffs", same = "Same", context = "Context" }

final class TextSession: BaseSession, CanvasDataSource {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published var leftLabel: String? = nil      // e.g. "Clipboard"
    @Published var rightLabel: String? = nil
    @Published private(set) var left = TextDocument()
    @Published private(set) var right = TextDocument()
    @Published var leftDirty = false { didSet { refreshTitle() } }
    @Published var rightDirty = false { didSet { refreshTitle() } }
    @Published var options = CompareOptions() { didSet { if options != oldValue { recompute() } } }
    @Published var filter: ViewFilter = .all { didSet { if filter != oldValue { rebuildDisplay(); canvas.reload(keepRow: false) } } }
    @Published private(set) var result = DiffResult.empty
    @Published var currentRow = 0
    @Published var busy = false
    @Published var showFind = false
    @Published var searchText = "" { didSet { canvas.searchText = searchText; updateMatchCount() } }
    @Published var matchCount = 0
    @Published var importantOnly = true

    let canvas = DiffCanvas()
    private(set) var display: [Int] = []
    private var blockStarts: [Int] = []
    private var marks: [OverviewMark] = []
    private var intra: [Int: ([NSRange], [NSRange])] = [:]
    private var undoStack: [(TextDocument, TextDocument, Bool, Bool)] = []
    private var redoStack: [(TextDocument, TextDocument, Bool, Bool)] = []
    private var generation = 0
    private var afterCompute: (() -> Void)?
    private var maxCols = 0

    init(left: URL?, right: URL?) {
        super.init(kind: .text)
        let p = Prefs.shared
        options.whitespace = WhitespaceRule(rawValue: p.defaultWhitespace) ?? .compare
        options.ignoreCase = p.defaultIgnoreCase
        options.ignorePatterns = p.ignorePatterns.split(separator: "\n").map(String.init)
        canvas.dataSource = self
        canvas.showArrows = true
        canvas.onCurrentRowChanged = { [weak self] r in self?.currentRow = r }
        canvas.onArrow = { [weak self] block, toRight in self?.copyBlock(block, toRight: toRight) }
        canvas.onEditCommit = { [weak self] row, pane, text in self?.editLine(row: row, pane: pane, text: text) }
        canvas.onDelete = { [weak self] rows, pane in self?.deleteLines(rows: rows, pane: pane) }
        canvas.onInsertLine = { [weak self] row, pane in self?.insertLine(after: row, pane: pane) }
        canvas.menuProvider = { [weak self] row, pane in self?.contextMenu(row: row, pane: pane) }
        leftURL = left; rightURL = right
        loadSide(0); loadSide(1)
        recompute(resetPosition: true)
    }

    override var recentPaths: [String] { [leftURL?.path ?? "", rightURL?.path ?? ""] }

    private func refreshTitle() {
        let l = leftLabel ?? leftURL?.lastPathComponent ?? "Untitled"
        let r = rightLabel ?? rightURL?.lastPathComponent ?? "Untitled"
        title = l == r ? l : "\(l) ↔ \(r)"
        isDirty = leftDirty || rightDirty
    }

    // MARK: Loading

    func loadSide(_ side: Int) {
        let url = side == 0 ? leftURL : rightURL
        var doc = TextDocument()
        if let url {
            do { doc = try TextDocument.load(url) }
            catch { _ = runAlert("Couldn't open \(url.lastPathComponent)", error.localizedDescription, style: .warning) }
        }
        if side == 0 { left = doc; leftDirty = false; leftLabel = nil } else { right = doc; rightDirty = false; rightLabel = nil }
        refreshTitle()
    }

    func setURL(_ url: URL, side: Int) {
        if side == 0 { leftURL = url } else { rightURL = url }
        loadSide(side)
        undoStack.removeAll(); redoStack.removeAll()
        Recents.shared.add(kind: .text, paths: recentPaths)
        recompute(resetPosition: true)
    }

    func pasteClipboard(side: Int) {
        guard let s = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        pushUndo()
        let doc = TextDocument.fromString(s)
        if side == 0 { left = doc; leftURL = nil; leftLabel = "Clipboard"; leftDirty = false }
        else { right = doc; rightURL = nil; rightLabel = "Clipboard"; rightDirty = false }
        refreshTitle()
        recompute(resetPosition: true)
    }

    // MARK: Diffing

    func recompute(resetPosition: Bool = false) {
        generation += 1
        let gen = generation
        let l = left.lines, r = right.lines, o = options
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = TextDiff.compare(left: l, right: r, options: o)
            let cols = max(l.lazy.map { $0.utf16.count }.max() ?? 0, r.lazy.map { $0.utf16.count }.max() ?? 0)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.result = res
                self.maxCols = min(cols, 6000)
                self.intra.removeAll()
                self.rebuildDisplay()
                self.busy = false
                self.canvas.reload(keepRow: !resetPosition)
                self.updateMatchCount()
                if resetPosition, self.filter == .all, let first = self.blockStarts.first(where: { $0 >= 0 }) {
                    self.canvas.setCurrentRow(first, center: true, animated: false)
                    self.canvas.select(rows: first...self.lastDisplayRow(ofBlockAt: first))
                }
                let after = self.afterCompute; self.afterCompute = nil; after?()
            }
        }
    }

    private func rebuildDisplay() {
        let rows = result.rows
        switch filter {
        case .all: display = Array(rows.indices)
        case .diffs: display = rows.indices.filter { rows[$0].kind != .same }
        case .same: display = rows.indices.filter { rows[$0].kind == .same }
        case .context:
            let n = Prefs.shared.contextLines
            var keep = [Bool](repeating: false, count: rows.count)
            for b in result.blocks {
                for k in max(0, b.rows.lowerBound - n)..<min(rows.count, b.rows.upperBound + n) { keep[k] = true }
            }
            display = rows.indices.filter { keep[$0] }
        }
        blockStarts = Array(repeating: -1, count: result.blocks.count)
        marks.removeAll()
        var k = 0
        while k < display.count {
            let row = rows[display[k]]
            guard row.block >= 0 else { k += 1; continue }
            let b = row.block
            if blockStarts[b] < 0 { blockStarts[b] = k }
            let start = k
            let style = styleFor(row)
            while k < display.count && rows[display[k]].block == b && styleFor(rows[display[k]]) == style { k += 1 }
            marks.append(OverviewMark(rows: start..<k, style: style))
        }
    }

    private func styleFor(_ r: DiffRow) -> CellStyle {
        switch r.kind {
        case .same: return .normal
        case .changed: return r.unimportant ? .unimportant : .changed
        case .leftOnly, .rightOnly: return r.unimportant ? .unimportant : .orphan
        }
    }

    private func lastDisplayRow(ofBlockAt start: Int) -> Int {
        guard start < display.count else { return start }
        let b = result.rows[display[start]].block
        var k = start
        while k + 1 < display.count && result.rows[display[k + 1]].block == b { k += 1 }
        return k
    }

    // MARK: CanvasDataSource

    var rowCount: Int { display.count }
    var paneCount: Int { 2 }
    var maxColumns: Int { maxCols }
    func isEditable(pane: Int) -> Bool { true }
    func overviewMarks() -> [OverviewMark] { marks }
    func arrowRows() -> [Int: Int] {
        var d: [Int: Int] = [:]
        for (b, s) in blockStarts.enumerated() where s >= 0 { d[s] = b }
        return d
    }

    func cell(row: Int, pane: Int) -> CanvasCell {
        guard row < display.count else { return .filler }
        let ri = display[row]
        let r = result.rows[ri]
        let idx = pane == 0 ? r.left : r.right
        guard idx >= 0 else { return .filler }
        let doc = pane == 0 ? left : right
        guard idx < doc.lines.count else { return .filler }
        let text = doc.lines[idx]
        var cell = CanvasCell(text: text, lineNumber: idx + 1, style: styleFor(r))
        if r.kind == .changed {
            let hl = intraline(ri, r)
            cell.highlights = pane == 0 ? hl.0 : hl.1
        }
        return cell
    }

    private func intraline(_ ri: Int, _ r: DiffRow) -> ([NSRange], [NSRange]) {
        if let c = intra[ri] { return c }
        guard r.left >= 0, r.right >= 0, r.left < left.lines.count, r.right < right.lines.count else { return ([], []) }
        let v = TextDiff.intraline(left.lines[r.left], right.lines[r.right], ignoreCase: options.ignoreCase)
        intra[ri] = v
        return v
    }

    // MARK: Navigation

    private func blockIndices() -> [Int] {
        result.blocks.indices.filter { blockStarts[$0] >= 0 && (!importantOnly || !result.blocks[$0].unimportant || result.stats.importantSections == 0) }
    }

    func goToBlock(_ b: Int) {
        let s = blockStarts[b]
        guard s >= 0 else { return }
        canvas.select(rows: s...lastDisplayRow(ofBlockAt: s))
        canvas.window?.makeFirstResponder(canvas)
    }

    func nextDiff() {
        let cur = canvas.selectedRows.upperBound
        if let b = blockIndices().first(where: { blockStarts[$0] > cur }) { goToBlock(b) } else { NSSound.beep() }
    }
    func prevDiff() {
        let cur = canvas.selectedRows.lowerBound
        if let b = blockIndices().last(where: { blockStarts[$0] < cur }) { goToBlock(b) } else { NSSound.beep() }
    }
    func firstDiff() { if let b = blockIndices().first { goToBlock(b) } }
    func lastDiff() { if let b = blockIndices().last { goToBlock(b) } }

    var hasNext: Bool { blockIndices().contains { blockStarts[$0] > currentRow } }
    var hasPrev: Bool { blockIndices().contains { blockStarts[$0] < currentRow } }

    // MARK: Editing

    private func pushUndo() {
        undoStack.append((left, right, leftDirty, rightDirty))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append((left, right, leftDirty, rightDirty))
        (left, right, leftDirty, rightDirty) = s
        recompute()
    }
    func redo() {
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append((left, right, leftDirty, rightDirty))
        (left, right, leftDirty, rightDirty) = s
        recompute()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func mutate(_ side: Int, _ body: (inout [String]) -> Void) {
        if side == 0 { var l = left.lines; body(&l); left.lines = l; leftDirty = true }
        else { var r = right.lines; body(&r); right.lines = r; rightDirty = true }
    }

    /// The line index on `side` at which content belongs for result row `ri`.
    private func insertionPoint(side: Int, resultRow ri: Int) -> Int {
        var q = ri - 1
        while q >= 0 {
            let v = side == 0 ? result.rows[q].left : result.rows[q].right
            if v >= 0 { return v + 1 }
            q -= 1
        }
        return 0
    }

    func copyResultRows(_ range: ClosedRange<Int>, toRight: Bool) {
        let rows = result.rows
        guard range.lowerBound >= 0, range.upperBound < rows.count else { return }
        let src = toRight ? 0 : 1, dst = 1 - src
        let srcDoc = src == 0 ? left : right
        let srcLines = range.compactMap { k -> String? in
            let i = src == 0 ? rows[k].left : rows[k].right
            return i >= 0 ? srcDoc.lines[i] : nil
        }
        let dstIdx = range.compactMap { k -> Int? in
            let i = dst == 0 ? rows[k].left : rows[k].right
            return i >= 0 ? i : nil
        }
        pushUndo()
        mutate(dst) { lines in
            if let lo = dstIdx.min(), let hi = dstIdx.max() { lines.replaceSubrange(lo...hi, with: srcLines) }
            else { lines.insert(contentsOf: srcLines, at: min(insertionPoint(side: dst, resultRow: range.lowerBound), lines.count)) }
        }
        recompute()
    }

    func copyBlock(_ b: Int, toRight: Bool) {
        guard b < result.blocks.count else { return }
        let r = result.blocks[b].rows
        copyResultRows(r.lowerBound...(r.upperBound - 1), toRight: toRight)
    }

    /// Copies the selected rows, or the whole difference section under the cursor.
    func copySelection(toRight: Bool) {
        guard !display.isEmpty else { return }
        let sel = canvas.selectedRows
        let lo = display[min(sel.lowerBound, display.count - 1)], hi = display[min(sel.upperBound, display.count - 1)]
        if lo == hi, result.rows[lo].block >= 0 { copyBlock(result.rows[lo].block, toRight: toRight); return }
        copyResultRows(lo...hi, toRight: toRight)
    }

    func editLine(row: Int, pane: Int, text: String) {
        guard row < display.count else { return }
        let ri = display[row]
        let r = result.rows[ri]
        let idx = pane == 0 ? r.left : r.right
        let doc = pane == 0 ? left : right
        if idx >= 0 && doc.lines[idx] == text { return }
        pushUndo()
        mutate(pane) { lines in
            if idx >= 0 { lines[idx] = text }
            else { lines.insert(text, at: min(insertionPoint(side: pane, resultRow: ri), lines.count)) }
        }
        recompute()
    }

    func insertLine(after row: Int, pane: Int) {
        guard row < display.count else { return }
        let ri = display[row]
        let r = result.rows[ri]
        let idx = pane == 0 ? r.left : r.right
        let at = idx >= 0 ? idx + 1 : insertionPoint(side: pane, resultRow: ri)
        pushUndo()
        mutate(pane) { $0.insert("", at: min(at, $0.count)) }
        afterCompute = { [weak self] in
            guard let self else { return }
            if let dr = self.display.firstIndex(where: { (pane == 0 ? self.result.rows[$0].left : self.result.rows[$0].right) == at }) {
                self.canvas.beginEdit(row: dr, pane: pane)
            }
        }
        recompute()
    }

    func deleteLines(rows: ClosedRange<Int>, pane: Int) {
        let idxs = rows.compactMap { k -> Int? in
            guard k < display.count else { return nil }
            let r = result.rows[display[k]]
            let i = pane == 0 ? r.left : r.right
            return i >= 0 ? i : nil
        }
        guard !idxs.isEmpty else { NSSound.beep(); return }
        pushUndo()
        let set = Set(idxs)
        mutate(pane) { lines in lines = lines.enumerated().filter { !set.contains($0.offset) }.map(\.element) }
        recompute()
    }

    func swap() {
        Swift.swap(&leftURL, &rightURL)
        Swift.swap(&leftLabel, &rightLabel)
        let l = left, ld = leftDirty
        left = right; leftDirty = rightDirty
        right = l; rightDirty = ld
        refreshTitle()
        recompute()
    }

    func reload() {
        if isDirty && runAlert("Reload and discard changes?", "Unsaved edits will be lost.", buttons: ["Reload", "Cancel"], style: .warning) != 0 { return }
        if leftURL != nil { loadSide(0) }
        if rightURL != nil { loadSide(1) }
        undoStack.removeAll(); redoStack.removeAll()
        recompute()
    }

    func setLineEnding(_ e: LineEnding, side: Int) {
        if side == 0 { left.lineEnding = e; leftDirty = true } else { right.lineEnding = e; rightDirty = true }
    }
    func setEncoding(_ e: TextEncodingKind, side: Int) {
        if side == 0 { left.encoding = e; leftDirty = true } else { right.encoding = e; rightDirty = true }
    }

    // MARK: Saving

    @discardableResult
    func save(side: Int, saveAs: Bool = false) -> Bool {
        var url = side == 0 ? leftURL : rightURL
        if url == nil || saveAs {
            let p = NSSavePanel()
            p.nameFieldStringValue = url?.lastPathComponent ?? "Untitled.txt"
            guard p.runModal() == .OK, let u = p.url else { return false }
            url = u
        }
        guard let url else { return false }
        do {
            try (side == 0 ? left : right).write(to: url)
            if side == 0 { leftURL = url; leftDirty = false; leftLabel = nil } else { rightURL = url; rightDirty = false; rightLabel = nil }
            refreshTitle()
            return true
        } catch {
            _ = runAlert("Couldn't save", error.localizedDescription, style: .warning)
            return false
        }
    }

    func saveAll() {
        if leftDirty { save(side: 0) }
        if rightDirty { save(side: 1) }
    }

    // MARK: Find / go to

    private func updateMatchCount() {
        guard !searchText.isEmpty else { matchCount = 0; return }
        let q = searchText.lowercased()
        matchCount = left.lines.reduce(0) { $0 + ($1.lowercased().contains(q) ? 1 : 0) } + right.lines.reduce(0) { $0 + ($1.lowercased().contains(q) ? 1 : 0) }
    }

    func find(forward: Bool) {
        guard !searchText.isEmpty, !display.isEmpty else { return }
        let n = display.count
        var k = currentRow
        for _ in 0..<n {
            k = forward ? (k + 1) % n : (k - 1 + n) % n
            let a = cell(row: k, pane: 0).text ?? "", b = cell(row: k, pane: 1).text ?? ""
            if a.localizedCaseInsensitiveContains(searchText) || b.localizedCaseInsensitiveContains(searchText) {
                canvas.setCurrentRow(k, center: true)
                return
            }
        }
        NSSound.beep()
    }

    func goToLine() {
        let a = NSAlert()
        a.messageText = "Go to Line"
        a.informativeText = "Line number in the left file (prefix with r for the right file, e.g. r120)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Go"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var s = f.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let rightSide = s.hasPrefix("r")
        if rightSide || s.hasPrefix("l") { s.removeFirst() }
        guard let n = Int(s), n > 0 else { return }
        if let k = display.firstIndex(where: { (rightSide ? result.rows[$0].right : result.rows[$0].left) == n - 1 }) {
            canvas.setCurrentRow(k, center: true)
        } else { NSSound.beep() }
    }

    // MARK: Context menu

    private func contextMenu(row: Int, pane: Int) -> NSMenu {
        let m = NSMenu()
        func item(_ t: String, _ key: String = "", _ act: @escaping () -> Void) {
            let i = ClosureMenuItem(title: t, keyEquivalent: key, action: act)
            m.addItem(i)
        }
        item("Copy to Right") { [weak self] in self?.copySelection(toRight: true) }
        item("Copy to Left") { [weak self] in self?.copySelection(toRight: false) }
        m.addItem(.separator())
        item("Edit Line") { [weak self] in self?.canvas.beginEdit(row: row, pane: pane) }
        item("Insert Line Below") { [weak self] in self?.insertLine(after: row, pane: pane) }
        item("Delete Line(s)") { [weak self] in guard let self else { return }; self.deleteLines(rows: self.canvas.selectedRows, pane: pane) }
        m.addItem(.separator())
        item("Copy Text") { [weak self] in self?.canvas.copy(nil) }
        return m
    }

    // MARK: Export

    func exportPatch() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "changes.diff"
        guard p.runModal() == .OK, let u = p.url else { return }
        let text = TextDiff.unifiedPatch(left: left.lines, right: right.lines,
                                         leftName: leftURL?.path ?? "left", rightName: rightURL?.path ?? "right", result: result)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    func exportReport() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Compare Report.html"
        guard p.runModal() == .OK, let u = p.url else { return }
        let html = Report.textHTML(session: self)
        try? html.write(to: u, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(u)
    }

    // MARK: Commands

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .nextDiff: nextDiff()
        case .prevDiff: prevDiff()
        case .firstDiff: firstDiff()
        case .lastDiff: lastDiff()
        case .copyToRight: copySelection(toRight: true)
        case .copyToLeft: copySelection(toRight: false)
        case .save, .saveAll: saveAll()
        case .reload: reload()
        case .swap: swap()
        case .find: withAnimation(.easeOut(duration: 0.15)) { showFind = true }
        case .findNext: find(forward: true)
        case .findPrev: find(forward: false)
        case .gotoLine: goToLine()
        case .undo:
            if canvas.window?.firstResponder is NSTextView { return false }
            undo()
        case .redo:
            if canvas.window?.firstResponder is NSTextView { return false }
            redo()
        case .exportReport: exportReport()
        case .exportPatch: exportPatch()
        case .showAll: filter = .all
        case .showDiffs: filter = .diffs
        case .showSame: filter = .same
        case .showContext: filter = .context
        case .insertLine: insertLine(after: currentRow, pane: 0)
        case .deleteLines: deleteLines(rows: canvas.selectedRows, pane: 0)
        case .editLine: canvas.beginEdit(row: currentRow, pane: 0)
        case .expandAll, .collapseAll: return false
        }
        return true
    }

    override func confirmClose() -> Bool {
        guard isDirty else { return true }
        let r = runAlert("Save changes to “\(title)”?", "Your changes will be lost if you don't save them.",
                         buttons: ["Save", "Don't Save", "Cancel"], style: .warning)
        if r == 0 { saveAll(); return !isDirty }
        return r == 1
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let closure: () -> Void
    init(title: String, keyEquivalent: String = "", action: @escaping () -> Void) {
        closure = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { closure() }
}

// MARK: - View

struct TextCompareView: View {
    @ObservedObject var s: TextSession
    @ObservedObject var prefs = Prefs.shared
    @State private var showPatterns = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                sideHeader(0)
                Color.clear.frame(width: 34)
                sideHeader(1)
                Color.clear.frame(width: 16)
            }
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.jGutter)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
            if s.showFind { FindBar(text: $s.searchText, count: s.matchCount, onNext: { s.find(forward: true) }, onPrev: { s.find(forward: false) }, onClose: { s.showFind = false; s.searchText = "" }) }
            ZStack {
                CanvasHost(canvas: s.canvas)
                if s.result.rows.isEmpty && s.leftURL == nil && s.rightURL == nil {
                    EmptyDropHint(text: "Drop a file on each side, or use the path fields above")
                }
            }
            if prefs.showDetailPane { LineDetailPane(s: s).frame(height: 62) }
            statusBar
        }
        .sheet(isPresented: $showPatterns) { PatternsSheet(options: $s.options) }
    }

    var toolbar: some View {
        Toolbar {
            Group {
                ToolButton(icon: "line.3.horizontal", label: "All", active: s.filter == .all) { s.filter = .all }
                ToolButton(icon: "plus.forwardslash.minus", label: "Diffs", active: s.filter == .diffs) { s.filter = .diffs }
                ToolButton(icon: "equal", label: "Same", active: s.filter == .same) { s.filter = .same }
                ToolButton(icon: "text.line.first.and.arrowtriangle.forward", label: "Context", active: s.filter == .context) { s.filter = .context }
            }
            ToolDivider()
            rulesMenu
            ToolDivider()
            Group {
                ToolButton(icon: "chevron.up.2", label: "First", enabled: s.result.stats.sections > 0) { s.firstDiff() }
                ToolButton(icon: "chevron.up", label: "Prev", enabled: s.result.stats.sections > 0, help: "Previous Difference (⌥⌘↑)") { s.prevDiff() }
                ToolButton(icon: "chevron.down", label: "Next", enabled: s.result.stats.sections > 0, help: "Next Difference (⌥⌘↓)") { s.nextDiff() }
                ToolButton(icon: "chevron.down.2", label: "Last", enabled: s.result.stats.sections > 0) { s.lastDiff() }
            }
            ToolDivider()
            Group {
                ToolButton(icon: "arrowshape.left.fill", label: "Copy Left", tint: .jOrphan, help: "Copy selection or section to the left (⌥⌘←)") { s.copySelection(toRight: false) }
                ToolButton(icon: "arrowshape.right.fill", label: "Copy Right", tint: .jOrphan, help: "Copy selection or section to the right (⌥⌘→)") { s.copySelection(toRight: true) }
            }
            ToolDivider()
            Group {
                ToolButton(icon: "arrow.uturn.backward", label: "Undo", enabled: s.canUndo) { s.undo() }
                ToolButton(icon: "arrow.uturn.forward", label: "Redo", enabled: s.canRedo) { s.redo() }
                ToolButton(icon: "arrow.left.arrow.right", label: "Swap") { s.swap() }
                ToolButton(icon: "arrow.clockwise", label: "Reload") { s.reload() }
                ToolButton(icon: "square.and.arrow.down", label: "Save", enabled: s.isDirty) { s.saveAll() }
            }
            ToolDivider()
            ToolButton(icon: "magnifyingglass", label: "Find", active: s.showFind) { withAnimation(.easeOut(duration: 0.15)) { s.showFind.toggle() } }
            Menu {
                Button("HTML Report…") { s.exportReport() }
                Button("Unified Patch (.diff)…") { s.exportPatch() }
            } label: {
                ToolMenuLabel(icon: "square.and.arrow.up", label: "Export")
            }
            .toolMenu()
            Spacer(minLength: 10)
            if s.busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
        }
    }

    var rulesMenu: some View {
        Menu {
            Picker("Whitespace", selection: $s.options.whitespace) {
                ForEach(WhitespaceRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Ignore Case", isOn: $s.options.ignoreCase)
            Toggle("Ignore Blank Lines", isOn: $s.options.ignoreBlankLines)
            Divider()
            Button("Unimportant Text Patterns…") { showPatterns = true }
            Divider()
            Toggle("Navigate Important Differences Only", isOn: $s.importantOnly)
            Toggle("Show Whitespace", isOn: $prefs.showWhitespace)
            Toggle("Show Line Details", isOn: $prefs.showDetailPane)
        } label: {
            ToolMenuLabel(icon: "slider.horizontal.3", label: "Rules", active: !s.options.isDefault)
        }
        .toolMenu()
    }

    func sideHeader(_ side: Int) -> some View {
        let doc = side == 0 ? s.left : s.right
        return VStack(alignment: .leading, spacing: 4) {
            PathField(placeholder: side == 0 ? "Left file" : "Right file",
                      url: side == 0 ? $s.leftURL : $s.rightURL,
                      dirty: side == 0 ? s.leftDirty : s.rightDirty,
                      readOnlyLabel: side == 0 ? s.leftLabel : s.rightLabel) { u in s.setURL(u, side: side) }
            HStack(spacing: 5) {
                Menu {
                    ForEach(TextEncodingKind.allCases, id: \.self) { e in Button(e.rawValue) { s.setEncoding(e, side: side) } }
                } label: { Pill(text: doc.encoding.rawValue) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Menu {
                    ForEach(LineEnding.allCases, id: \.self) { e in Button(e.label) { s.setLineEnding(e, side: side) } }
                } label: { Pill(text: doc.lineEnding.rawValue) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Pill(text: "\(doc.lines.count) lines")
                if doc.isBinary { Pill(text: "binary").foregroundStyle(.orange) }
                Spacer()
                Button { s.pasteClipboard(side: side) } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless).help("Compare clipboard text on this side")
                Button { s.save(side: side, saveAs: true) } label: { Image(systemName: "square.and.arrow.down.on.square") }
                    .buttonStyle(.borderless).help("Save As…")
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }

    var statusBar: some View {
        StatusBar {
            let st = s.result.stats
            if s.result.rows.isEmpty && s.leftURL == nil && s.rightURL == nil {
                Text("Ready")
            } else if st.identical {
                Label("Files are identical", systemImage: "checkmark.seal.fill").foregroundStyle(Color.jAdded)
            } else if st.onlyUnimportant {
                Label("Only unimportant differences", systemImage: "checkmark.circle").foregroundStyle(Color.jUnimportant)
            } else {
                Text("\(st.importantSections) difference section\(st.importantSections == 1 ? "" : "s")").fontWeight(.medium).foregroundStyle(.primary)
            }
            if st.sections > 0 {
                StatChip(color: .jChanged, text: "\(st.changedLines) changed")
                StatChip(color: .jOrphan, text: "\(st.leftOnlyLines + st.rightOnlyLines) orphan")
                if st.sections != st.importantSections { StatChip(color: .jUnimportant, text: "\(st.sections - st.importantSections) unimportant") }
            }
            Spacer()
            if s.currentRow < s.display.count {
                let r = s.result.rows[s.display[s.currentRow]]
                Text("Ln \(r.left >= 0 ? String(r.left + 1) : "–") : \(r.right >= 0 ? String(r.right + 1) : "–")").monospacedDigit()
            }
            Text(s.filter.rawValue)
        }
    }
}

struct ToolMenuLabel: View {
    let icon: String
    let label: String
    var active = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 15)).frame(height: 18)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
            Text(label).font(.system(size: 10.5)).foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 4).frame(minWidth: 46)
    }
}

struct FindBar: View {
    @Binding var text: String
    let count: Int
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in both files", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onNext)
                .frame(maxWidth: 320)
            if !text.isEmpty { Text("\(count) matching line\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary) }
            Button(action: onPrev) { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
            Button(action: onNext) { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
        .onAppear { focused = true }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Bottom pane that shows the current line pair in full, one above the other, with character highlights.
struct LineDetailPane: View {
    @ObservedObject var s: TextSession

    var body: some View {
        let row = s.currentRow
        let l = s.cell(row: row, pane: 0), r = s.cell(row: row, pane: 1)
        VStack(alignment: .leading, spacing: 2) {
            line(l, label: "L")
            line(r, label: "R")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.jGutter)
        .overlay(alignment: .top) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
    }

    func line(_ c: CanvasCell, label: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 12)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(attributed(c)).font(Font(Prefs.shared.editorFont)).lineLimit(1).textSelection(.enabled)
            }
        }
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(c.text == nil ? Color.clear : Color(nsColor: Palette.background(c.style) ?? .clear)))
    }

    func attributed(_ c: CanvasCell) -> AttributedString {
        guard let t = c.text else { return AttributedString("—") }
        let ns = NSMutableAttributedString(string: t.replacingOccurrences(of: "\t", with: "    "))
        if !t.contains("\t") {
            for h in c.highlights where NSMaxRange(h) <= ns.length {
                ns.addAttribute(.backgroundColor, value: Palette.highlight(c.style), range: h)
            }
        }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(t)
    }
}

struct EmptyDropHint: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }
}

struct PatternsSheet: View {
    @Binding var options: CompareOptions
    @Environment(\.dismiss) var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unimportant Text").font(.headline)
            Text("One regular expression per line. Text matching these patterns is ignored when deciding whether lines are equal; such differences are shown as unimportant.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.jSeparator))
            HStack {
                Menu("Insert Example") {
                    Button("Timestamps  \\d{2}:\\d{2}:\\d{2}") { append("\\d{2}:\\d{2}:\\d{2}") }
                    Button("Dates  \\d{4}-\\d{2}-\\d{2}") { append("\\d{4}-\\d{2}-\\d{2}") }
                    Button("Line comments  //.*$") { append("//.*$") }
                    Button("Hash comments  #.*$") { append("#.*$") }
                    Button("Hex addresses  0x[0-9a-fA-F]+") { append("0x[0-9a-fA-F]+") }
                }.fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    options.ignorePatterns = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
        .onAppear { text = options.ignorePatterns.joined(separator: "\n") }
    }

    func append(_ p: String) { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + p }
}
