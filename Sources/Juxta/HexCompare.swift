import AppKit
import SwiftUI
import JuxtaCore

final class HexSession: BaseSession, CanvasDataSource {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var a = Data()
    @Published private(set) var b = Data()
    @Published private(set) var diffBytes = 0
    @Published private(set) var analysing = false
    @Published var currentRow = 0
    @Published var bytesPerRow = 16 { didSet { analyse() } }

    let canvas = DiffCanvas()
    private var rowDiff: [Bool] = []
    private var marks: [OverviewMark] = []
    private var gen = 0

    init(left: URL?, right: URL?) {
        super.init(kind: .hex)
        leftURL = left; rightURL = right
        canvas.dataSource = self
        canvas.showLineNumbers = false
        canvas.allowsLineNumbers = false
        canvas.onCurrentRowChanged = { [weak self] r in self?.currentRow = r }
        load()
    }

    override var recentPaths: [String] { [leftURL?.path ?? "", rightURL?.path ?? ""] }

    func load() {
        a = leftURL.flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) } ?? Data()
        b = rightURL.flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) } ?? Data()
        title = "\(leftURL?.lastPathComponent ?? "—") ↔ \(rightURL?.lastPathComponent ?? "—")"
        analyse()
    }

    func setURL(_ u: URL, side: Int) {
        if side == 0 { leftURL = u } else { rightURL = u }
        Recents.shared.add(kind: .hex, paths: recentPaths)
        load()
    }

    private func analyse() {
        gen += 1
        let g = gen, a = a, b = b, bpr = bytesPerRow
        analysing = true
        rowDiff = []
        marks = []
        canvas.reload()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = (max(a.count, b.count) + bpr - 1) / bpr
            var flags = [Bool](repeating: false, count: rows)
            var count = 0
            a.withUnsafeBytes { pa in
                b.withUnsafeBytes { pb in
                    let n = min(a.count, b.count)
                    for i in 0..<n where pa[i] != pb[i] { count += 1; flags[i / bpr] = true }
                }
            }
            let longer = max(a.count, b.count), shorter = min(a.count, b.count)
            count += longer - shorter
            if longer > shorter { for r in (shorter / bpr)..<rows { flags[r] = true } }
            var marks: [OverviewMark] = []
            var k = 0
            while k < rows {
                if !flags[k] { k += 1; continue }
                let s = k; while k < rows && flags[k] { k += 1 }
                marks.append(OverviewMark(rows: s..<k, style: .changed))
            }
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }
                self.rowDiff = flags; self.marks = marks; self.diffBytes = count; self.analysing = false
                self.canvas.reload()
                if let first = flags.firstIndex(of: true) { self.canvas.setCurrentRow(first, center: true, animated: false) }
            }
        }
    }

    var rowCount: Int { (max(a.count, b.count) + bytesPerRow - 1) / bytesPerRow }
    var paneCount: Int { 2 }
    var maxColumns: Int { 10 + bytesPerRow * 3 + 2 + bytesPerRow + 2 }
    func overviewMarks() -> [OverviewMark] { marks }

    private static let hex: [Character] = Array("0123456789ABCDEF")

    func cell(row: Int, pane: Int) -> CanvasCell {
        let data = pane == 0 ? a : b, other = pane == 0 ? b : a
        let start = row * bytesPerRow
        guard start < data.count else { return .filler }
        var hexPart = "", ascii = ""
        var hl: [NSRange] = []
        let prefix = String(format: "%08X  ", start)
        let base = prefix.utf16.count
        let asciiBase = base + bytesPerRow * 3 + 1
        var differs = false
        data.withUnsafeBytes { p in
            other.withUnsafeBytes { q in
                for i in 0..<bytesPerRow {
                    let o = start + i
                    if o < data.count {
                        let v = p[o]
                        hexPart.append(Self.hex[Int(v >> 4)]); hexPart.append(Self.hex[Int(v & 15)]); hexPart.append(" ")
                        ascii.append(v >= 32 && v < 127 ? Character(UnicodeScalar(v)) : "·")
                        if o >= other.count || q[o] != v {
                            differs = true
                            hl.append(NSRange(location: base + i * 3, length: 2))
                            hl.append(NSRange(location: asciiBase + i, length: 1))
                        }
                    } else {
                        hexPart += "   "
                    }
                }
            }
        }
        return CanvasCell(text: prefix + hexPart + " " + ascii, lineNumber: nil, style: differs ? .changed : .normal, highlights: hl)
    }

    func step(_ forward: Bool) {
        guard !rowDiff.isEmpty else { return }
        var k = currentRow
        // skip the current run of differing rows first
        while k >= 0 && k < rowDiff.count && rowDiff[k] { k += forward ? 1 : -1 }
        while k >= 0 && k < rowDiff.count && !rowDiff[k] { k += forward ? 1 : -1 }
        if !forward { while k > 0 && rowDiff[k - 1] { k -= 1 } }
        if k >= 0 && k < rowDiff.count { canvas.setCurrentRow(k, center: true) } else { NSSound.beep() }
    }

    func goToOffset() {
        let al = NSAlert()
        al.messageText = "Go to Offset"
        al.informativeText = "Decimal, or hexadecimal with 0x prefix."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        al.accessoryView = f
        al.addButton(withTitle: "Go"); al.addButton(withTitle: "Cancel")
        al.window.initialFirstResponder = f
        guard al.runModal() == .alertFirstButtonReturn else { return }
        let t = f.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let v = t.hasPrefix("0x") ? Int(t.dropFirst(2), radix: 16) : Int(t)
        if let v { canvas.setCurrentRow(v / bytesPerRow, center: true) }
    }

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .nextDiff: step(true)
        case .prevDiff: step(false)
        case .reload: load()
        case .gotoLine: goToOffset()
        case .swap: Swift.swap(&leftURL, &rightURL); load()
        default: return false
        }
        return true
    }
}

struct HexCompareView: View {
    @ObservedObject var s: HexSession

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                ToolButton(icon: "chevron.up", label: "Prev") { s.step(false) }
                ToolButton(icon: "chevron.down", label: "Next") { s.step(true) }
                ToolButton(icon: "number", label: "Go to Offset") { s.goToOffset() }
                ToolDivider()
                Menu {
                    ForEach([8, 16, 24, 32], id: \.self) { n in Button("\(n) bytes per row") { s.bytesPerRow = n } }
                } label: { ToolMenuLabel(icon: "rectangle.split.3x1", label: "\(s.bytesPerRow)/row") }
                    .toolMenu()
                ToolDivider()
                ToolButton(icon: "arrow.left.arrow.right", label: "Swap") { _ = s.handle(.swap) }
                ToolButton(icon: "arrow.clockwise", label: "Reload") { s.load() }
                Spacer()
                if s.analysing { ProgressView().controlSize(.small).padding(.trailing, 8) }
            }
            HStack(spacing: 0) {
                side(0)
                Color.clear.frame(width: 1)
                side(1)
                Color.clear.frame(width: 16)
            }
            .padding(.vertical, 7)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.jGutter)
            CanvasHost(canvas: s.canvas)
            StatusBar {
                if s.a.isEmpty && s.b.isEmpty { Text("Ready") }
                else if s.diffBytes == 0 && !s.analysing { Label("Files are binary identical", systemImage: "checkmark.seal.fill").foregroundStyle(Color.jAdded) }
                else { Text("\(s.diffBytes) differing byte\(s.diffBytes == 1 ? "" : "s")").fontWeight(.medium).foregroundStyle(.primary) }
                Spacer()
                Text(String(format: "Offset 0x%08X", s.currentRow * s.bytesPerRow)).monospacedDigit()
            }
        }
    }

    func side(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PathField(placeholder: i == 0 ? "Left file" : "Right file", url: i == 0 ? $s.leftURL : $s.rightURL) { s.setURL($0, side: i) }
            HStack { Pill(text: "\(i == 0 ? s.a.count : s.b.count) bytes"); Pill(text: String(format: "0x%X", i == 0 ? s.a.count : s.b.count)) }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }
}
