import AppKit
import SwiftUI
import JuxtaCore

final class TableSession: BaseSession, CanvasDataSource {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var a = JuxtaCore.Table(rows: [], delimiter: ",")
    @Published private(set) var b = JuxtaCore.Table(rows: [], delimiter: ",")
    @Published var keyColumn: Int? = nil { didSet { compare() } }
    @Published var hasHeader = true { didSet { compare() } }
    @Published var ignoreCase = false { didSet { compare() } }
    @Published var trim = true { didSet { compare() } }
    @Published var filter: ViewFilter = .all { didSet { rebuild() } }
    @Published private(set) var pairs: [TableRowPair] = []
    @Published var currentRow = 0

    let canvas = DiffCanvas()
    private(set) var display: [Int] = []
    private var widths: [Int] = []
    private var lineCache: [Int: (String, [NSRange])] = [:]

    init(left: URL?, right: URL?) {
        super.init(kind: .table)
        leftURL = left; rightURL = right
        canvas.dataSource = self
        canvas.onCurrentRowChanged = { [weak self] r in self?.currentRow = r }
        load()
    }

    override var recentPaths: [String] { [leftURL?.path ?? "", rightURL?.path ?? ""] }

    func load() {
        func read(_ u: URL?) -> JuxtaCore.Table {
            guard let u, let d = try? TextDocument.load(u) else { return JuxtaCore.Table(rows: [], delimiter: ",") }
            return JuxtaCore.Table.parse(d.lines.joined(separator: "\n"), delimiter: u.pathExtension.lowercased() == "tsv" ? "\t" : nil)
        }
        a = read(leftURL); b = read(rightURL)
        autoKey()
        title = "\(leftURL?.lastPathComponent ?? "—") ↔ \(rightURL?.lastPathComponent ?? "—")"
        compare()
    }

    /// Uses the first column as the row key when its values are unique on both sides (an ID column).
    private func autoKey() {
        func unique(_ t: JuxtaCore.Table) -> Bool {
            let vals = t.rows.dropFirst(hasHeader ? 1 : 0).map { $0.first ?? "" }
            return !vals.isEmpty && Set(vals).count == vals.count && !vals.contains("")
        }
        let k: Int? = unique(a) && unique(b) ? 0 : nil
        if keyColumn != k { keyColumn = k }
    }

    func setURL(_ u: URL, side: Int) {
        if side == 0 { leftURL = u } else { rightURL = u }
        Recents.shared.add(kind: .table, paths: recentPaths)
        load()
    }

    var headers: [String] {
        let n = max(a.columnCount, b.columnCount)
        let h = hasHeader ? (a.rows.first ?? b.rows.first ?? []) : []
        return (0..<n).map { $0 < h.count && !h[$0].isEmpty ? h[$0] : "Column \($0 + 1)" }
    }

    func compare() {
        pairs = TableDiff.compare(a, b, keyColumn: keyColumn, hasHeader: hasHeader, ignoreCase: ignoreCase, trim: trim)
        let n = max(a.columnCount, b.columnCount)
        widths = Array(repeating: 3, count: n)
        for t in [a, b] { for row in t.rows.prefix(5000) { for (i, c) in row.enumerated() where i < n { widths[i] = min(36, max(widths[i], c.count)) } } }
        rebuild()
    }

    func rebuild() {
        switch filter {
        case .all, .context: display = Array(pairs.indices)
        case .diffs: display = pairs.indices.filter { pairs[$0].kind != .same || (hasHeader && $0 == 0) }
        case .same: display = pairs.indices.filter { pairs[$0].kind == .same }
        }
        lineCache.removeAll()
        canvas.reload()
    }

    var stats: (changed: Int, cells: Int, left: Int, right: Int) {
        var s = (0, 0, 0, 0)
        for (i, p) in pairs.enumerated() where !(hasHeader && i == 0) {
            switch p.kind {
            case .changed: s.0 += 1; s.1 += p.changedColumns.count
            case .leftOnly: s.2 += 1
            case .rightOnly: s.3 += 1
            case .same: break
            }
        }
        return s
    }

    private func render(_ row: [String], changed: Set<Int>) -> (String, [NSRange]) {
        var s = "", ranges: [NSRange] = []
        for (i, w) in widths.enumerated() {
            var c = i < row.count ? row[i] : ""
            c = c.replacingOccurrences(of: "\n", with: "⏎")
            if c.count > w { c = String(c.prefix(w - 1)) + "…" }
            let padded = c.padding(toLength: w, withPad: " ", startingAt: 0)
            let start = (s as NSString).length
            s += padded
            if changed.contains(i) { ranges.append(NSRange(location: start, length: (padded as NSString).length)) }
            if i < widths.count - 1 { s += " │ " }
        }
        return (s, ranges)
    }

    // CanvasDataSource
    var rowCount: Int { display.count }
    var paneCount: Int { 2 }
    var maxColumns: Int { widths.reduce(0, +) + widths.count * 3 }

    func cell(row: Int, pane: Int) -> CanvasCell {
        guard row < display.count else { return .filler }
        let p = pairs[display[row]]
        let idx = pane == 0 ? p.left : p.right
        guard idx >= 0 else { return .filler }
        let t = pane == 0 ? a : b
        let key = row * 2 + pane
        let r: (String, [NSRange])
        if let c = lineCache[key] { r = c } else { r = render(t.rows[idx], changed: p.changedColumns); lineCache[key] = r }
        var cell = CanvasCell(text: r.0, lineNumber: idx + 1, highlights: r.1)
        switch p.kind {
        case .same: cell.style = hasHeader && display[row] == 0 ? .header : .normal
        case .changed: cell.style = hasHeader && display[row] == 0 ? .header : .changed
        case .leftOnly, .rightOnly: cell.style = .orphan
        }
        return cell
    }

    func overviewMarks() -> [OverviewMark] {
        display.enumerated().compactMap { (k, i) in
            switch pairs[i].kind {
            case .same: return nil
            case .changed: return OverviewMark(rows: k..<(k + 1), style: .changed)
            default: return OverviewMark(rows: k..<(k + 1), style: .orphan)
            }
        }
    }

    func step(_ forward: Bool) {
        let idx = forward ? display.indices.first { $0 > currentRow && pairs[display[$0]].kind != .same }
                          : display.indices.last { $0 < currentRow && pairs[display[$0]].kind != .same }
        if let i = idx { canvas.setCurrentRow(i, center: true) } else { NSSound.beep() }
    }

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .nextDiff: step(true)
        case .prevDiff: step(false)
        case .reload: load()
        case .swap: Swift.swap(&leftURL, &rightURL); load()
        case .showAll: filter = .all
        case .showDiffs: filter = .diffs
        case .showSame: filter = .same
        default: return false
        }
        return true
    }
}

struct TableCompareView: View {
    @ObservedObject var s: TableSession

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                ToolButton(icon: "line.3.horizontal", label: "All", active: s.filter == .all) { s.filter = .all }
                ToolButton(icon: "plus.forwardslash.minus", label: "Diffs", active: s.filter == .diffs) { s.filter = .diffs }
                ToolButton(icon: "equal", label: "Same", active: s.filter == .same) { s.filter = .same }
                ToolDivider()
                ToolButton(icon: "chevron.up", label: "Prev") { s.step(false) }
                ToolButton(icon: "chevron.down", label: "Next") { s.step(true) }
                ToolDivider()
                Menu {
                    Button { s.keyColumn = nil } label: { Text(s.keyColumn == nil ? "✓ Row order (no key)" : "Row order (no key)") }
                    Divider()
                    ForEach(Array(s.headers.enumerated()), id: \.offset) { i, h in
                        Button { s.keyColumn = i } label: { Text((s.keyColumn == i ? "✓ " : "") + h) }
                    }
                } label: { ToolMenuLabel(icon: "key", label: s.keyColumn.map { "Key: \(s.headers[safe: $0] ?? "?")" } ?? "Align: Rows", active: s.keyColumn != nil) }
                    .toolMenu()
                Menu {
                    Toggle("First Row Is Header", isOn: $s.hasHeader)
                    Toggle("Ignore Case", isOn: $s.ignoreCase)
                    Toggle("Trim Cell Whitespace", isOn: $s.trim)
                } label: { ToolMenuLabel(icon: "slider.horizontal.3", label: "Rules") }
                    .toolMenu()
                ToolDivider()
                ToolButton(icon: "arrow.left.arrow.right", label: "Swap") { _ = s.handle(.swap) }
                ToolButton(icon: "arrow.clockwise", label: "Reload") { s.load() }
                Spacer()
            }
            HStack(spacing: 0) {
                PathField(placeholder: "Left CSV/TSV", url: $s.leftURL) { s.setURL($0, side: 0) }.padding(.horizontal, 10)
                Color.clear.frame(width: 1)
                PathField(placeholder: "Right CSV/TSV", url: $s.rightURL) { s.setURL($0, side: 1) }.padding(.horizontal, 10)
                Color.clear.frame(width: 16)
            }
            .padding(.vertical, 7)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.jGutter)
            CanvasHost(canvas: s.canvas)
            cellDetails
            StatusBar {
                let st = s.stats
                Text("\(max(0, s.pairs.count - (s.hasHeader ? 1 : 0))) rows").fontWeight(.medium).foregroundStyle(.primary)
                StatChip(color: .jChanged, text: "\(st.changed) changed rows · \(st.cells) cells")
                StatChip(color: .jOrphan, text: "\(st.left) left-only · \(st.right) right-only")
                Spacer()
                Text("Delimiter: \(s.a.delimiter == "\t" ? "Tab" : String(s.a.delimiter))")
            }
        }
    }

    /// Lists the differing cells of the current row as "column: left → right".
    @ViewBuilder var cellDetails: some View {
        let row = s.currentRow
        if row < s.display.count {
            let p = s.pairs[s.display[row]]
            if p.kind == .changed && !p.changedColumns.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(p.changedColumns.sorted(), id: \.self) { c in
                            let l = p.left >= 0 && c < s.a.rows[p.left].count ? s.a.rows[p.left][c] : ""
                            let r = p.right >= 0 && c < s.b.rows[p.right].count ? s.b.rows[p.right][c] : ""
                            HStack(spacing: 5) {
                                Text(s.headers[safe: c] ?? "").fontWeight(.semibold)
                                Text(l.isEmpty ? "∅" : l).strikethrough().foregroundStyle(Color.jChanged)
                                Image(systemName: "arrow.right").font(.system(size: 9))
                                Text(r.isEmpty ? "∅" : r).foregroundStyle(Color.jAdded)
                            }
                            .font(.system(size: 11.5))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 32)
                .background(Color.jGutter)
                .overlay(alignment: .top) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
            }
        }
    }
}
