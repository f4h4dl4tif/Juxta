import AppKit
import SwiftUI

struct CanvasCell {
    var text: String?            // nil = filler (no line on this side)
    var lineNumber: Int?
    var style: CellStyle = .normal
    var highlights: [NSRange] = []
    static let filler = CanvasCell(text: nil, lineNumber: nil, style: .filler)
}

struct OverviewMark {
    var rows: Range<Int>
    var style: CellStyle
}

protocol CanvasDataSource: AnyObject {
    var rowCount: Int { get }
    var paneCount: Int { get }
    var maxColumns: Int { get }
    func cell(row: Int, pane: Int) -> CanvasCell
    func overviewMarks() -> [OverviewMark]
    /// Rows that start a difference section and get copy arrows in the centre gutter (2-pane only).
    func arrowRows() -> [Int: Int]
    func isEditable(pane: Int) -> Bool
}

extension CanvasDataSource {
    func arrowRows() -> [Int: Int] { [:] }
    func isEditable(pane: Int) -> Bool { false }
}

/// A fast, fully custom-drawn multi-pane grid used by every compare view. Only visible rows are
/// drawn, attributed lines are cached, and scrolling is driven directly by trackpad deltas so
/// momentum feels native while all panes stay perfectly locked together.
final class DiffCanvas: NSView, NSTextFieldDelegate {
    weak var dataSource: CanvasDataSource?

    var onCurrentRowChanged: ((Int) -> Void)?
    var onArrow: ((Int, Bool) -> Void)?                 // blockID, toRight
    var onEditCommit: ((Int, Int, String) -> Void)?      // row, pane, text
    var onDelete: ((ClosedRange<Int>, Int) -> Void)?     // rows, pane
    var onInsertLine: ((Int, Int) -> Void)?              // after row, pane
    var onDoubleClick: ((Int, Int) -> Void)?
    var menuProvider: ((Int, Int) -> NSMenu?)?
    var onScroll: (() -> Void)?

    var showArrows = false
    /// When false, the line-number gutter stays hidden regardless of preferences (hex view).
    var allowsLineNumbers = true
    var showLineNumbers = true { didSet { needsDisplay = true } }
    var showWhitespace = false { didSet { invalidateCache() } }
    var tabWidth = 4 { didSet { invalidateCache() } }
    var searchText: String = "" { didSet { if oldValue != searchText { invalidateCache() } } }
    var searchCaseSensitive = false
    var paneWeights: [CGFloat]? = nil

    private(set) var font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private(set) var lineHeight: CGFloat = 18
    private var charWidth: CGFloat = 7.5
    private var baseline: CGFloat = 13

    private(set) var offsetY: CGFloat = 0
    private var offsetX: CGFloat = 0
    private(set) var currentRow = 0
    private var anchorRow = 0
    private(set) var selection: ClosedRange<Int>? = nil
    private(set) var activePane = 0

    private var cache: [Int: NSAttributedString] = [:]
    private var lnCache: [Int: NSAttributedString] = [:]
    private var marks: [OverviewMark] = []
    private var arrows: [Int: Int] = [:]
    private var rowCount = 0
    private var paneCount = 2
    private var maxCols = 0

    private var editor: NSTextField?
    private var editingCell: (row: Int, pane: Int)?
    private var animTimer: Timer?
    private var draggingOverview = false
    private var draggingSelection = false

    let overviewWidth: CGFloat = 16
    var gutterWidth: CGFloat { showArrows && paneCount == 2 ? 34 : 1 }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setFont(Prefs.shared.editorFont)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFont(_ f: NSFont) {
        font = f
        let lm = NSLayoutManager()
        lineHeight = ceil(lm.defaultLineHeight(for: f) + 3)
        charWidth = ("M" as NSString).size(withAttributes: [.font: f]).width
        baseline = ceil(f.ascender) + 1.5
        invalidateCache()
        clampOffsets()
    }

    func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
        lnCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    /// Re-reads row count and overview from the data source. Keeps scroll position.
    func reload(keepRow: Bool = true) {
        cancelEdit()
        rowCount = dataSource?.rowCount ?? 0
        paneCount = max(1, dataSource?.paneCount ?? 1)
        maxCols = dataSource?.maxColumns ?? 0
        marks = dataSource?.overviewMarks() ?? []
        arrows = showArrows ? (dataSource?.arrowRows() ?? [:]) : [:]
        if !keepRow { currentRow = 0; selection = nil; offsetY = 0 }
        currentRow = min(currentRow, max(0, rowCount - 1))
        if let s = selection, s.upperBound >= rowCount { selection = nil }
        invalidateCache()
        clampOffsets()
    }

    // MARK: Geometry

    private var visibleHeight: CGFloat { bounds.height }
    private var contentHeight: CGFloat { CGFloat(rowCount) * lineHeight }
    private var maxOffsetY: CGFloat { max(0, contentHeight - visibleHeight + lineHeight * 2) }

    private var lineNumberWidth: CGFloat {
        guard showLineNumbers else { return 6 }
        let digits = max(3, String(max(rowCount, 1)).count)
        return CGFloat(digits) * charWidth * 0.92 + 16
    }

    /// Rect of each pane (including line-number gutter), left to right.
    func paneRects() -> [NSRect] {
        let avail = bounds.width - overviewWidth - (paneCount > 1 ? gutterWidth + CGFloat(max(0, paneCount - 2)) : 0)
        var rects: [NSRect] = []
        var x: CGFloat = 0
        let weights = paneWeights ?? Array(repeating: 1, count: paneCount)
        let total = weights.reduce(0, +)
        for p in 0..<paneCount {
            let w = floor(avail * weights[p] / total)
            rects.append(NSRect(x: x, y: 0, width: w, height: bounds.height))
            x += w + (p == 0 ? gutterWidth : 1)
        }
        return rects
    }

    private func textRect(_ pane: NSRect) -> NSRect {
        NSRect(x: pane.minX + lineNumberWidth, y: 0, width: max(0, pane.width - lineNumberWidth), height: pane.height)
    }

    private var maxOffsetX: CGFloat {
        guard let r = paneRects().first else { return 0 }
        return max(0, CGFloat(maxCols + 4) * charWidth - textRect(r).width)
    }

    private func clampOffsets() {
        offsetY = min(max(0, offsetY), maxOffsetY)
        offsetX = min(max(0, offsetX), maxOffsetX)
        positionEditor()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOffsets()
    }

    func row(at y: CGFloat) -> Int { Int((y + offsetY) / lineHeight) }

    var visibleRows: Range<Int> {
        let first = max(0, Int(offsetY / lineHeight))
        let last = min(rowCount, Int((offsetY + visibleHeight) / lineHeight) + 1)
        return first..<max(first, last)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Palette.editorBG.setFill()
        bounds.fill()
        let panes = paneRects()
        let rows = visibleRows

        // Separators and centre gutter.
        Palette.gutterBG.setFill()
        if panes.count > 1 {
            for p in 0..<(panes.count - 1) {
                let x0 = panes[p].maxX, x1 = panes[p + 1].minX
                NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill()
            }
        }
        for (p, pr) in panes.enumerated() {
            // line-number gutter background
            Palette.gutterBG.setFill()
            NSRect(x: pr.minX, y: 0, width: lineNumberWidth, height: bounds.height).fill()
            let tr = textRect(pr)
            for r in rows {
                let y = CGFloat(r) * lineHeight - offsetY
                guard let ds = dataSource else { break }
                let cell = ds.cell(row: r, pane: p)
                let rowRect = NSRect(x: pr.minX, y: y, width: pr.width, height: lineHeight)
                if cell.text == nil {
                    drawFiller(rowRect, ctx: ctx)
                } else if let bg = Palette.background(cell.style) {
                    bg.setFill(); rowRect.fill()
                }
                if let sel = selection, sel.contains(r) {
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(p == activePane ? 0.22 : 0.10).setFill()
                    rowRect.fill()
                }
                if showLineNumbers, let n = cell.lineNumber {
                    let s = lineNumberString(n)
                    let w = s.size().width
                    s.draw(at: NSPoint(x: pr.minX + lineNumberWidth - w - 8, y: y + (lineHeight - s.size().height) / 2))
                }
                if cell.style != .normal && cell.style != .filler && cell.style != .base && cell.style != .header && cell.text != nil {
                    // change bar at the left edge of the text column
                    Palette.mark(cell.style).setFill()
                    NSRect(x: pr.minX + lineNumberWidth - 3, y: y, width: 3, height: lineHeight).fill()
                }
                if let text = cell.text, !text.isEmpty {
                    ctx.saveGState()
                    NSBezierPath(rect: tr).addClip()
                    let a = attributed(row: r, pane: p, cell: cell, text: text)
                    a.draw(at: NSPoint(x: tr.minX + 6 - offsetX, y: y + (lineHeight - font.boundingRectForFont.height) / 2 + 1))
                    ctx.restoreGState()
                }
            }
            // Pane edge
            Palette.separator.setFill()
            NSRect(x: pr.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
            NSRect(x: pr.minX + lineNumberWidth - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        }

        // Current row outline
        if rowCount > 0, rows.contains(currentRow) {
            let y = CGFloat(currentRow) * lineHeight - offsetY
            let r = NSRect(x: 0.5, y: y + 0.5, width: (panes.last?.maxX ?? bounds.width) - 1, height: lineHeight - 1)
            NSColor.controlAccentColor.withAlphaComponent(window?.firstResponder === self ? 0.75 : 0.35).setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            path.lineWidth = 1
            path.stroke()
        }

        if showArrows && panes.count == 2 { drawArrows(panes, rows: rows) }
        drawOverview()
    }

    private func drawFiller(_ r: NSRect, ctx: CGContext) {
        Palette.fillerBG.setFill(); r.fill()
        ctx.saveGState()
        NSBezierPath(rect: r).addClip()
        Palette.fillerHatch.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = r.minX - r.height + CGFloat(Int(offsetY) % 8 == 0 ? 0 : 0)
        let step: CGFloat = 8
        // align hatch to absolute coordinates so it doesn't shimmer while scrolling
        let phase = (r.minY + offsetY).truncatingRemainder(dividingBy: step)
        x -= phase
        while x < r.maxX {
            path.move(to: NSPoint(x: x, y: r.maxY))
            path.line(to: NSPoint(x: x + r.height, y: r.minY))
            x += step
        }
        path.stroke()
        ctx.restoreGState()
    }

    private func drawArrows(_ panes: [NSRect], rows: Range<Int>) {
        let gx = panes[0].maxX
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold)]
        for (row, _) in arrows where rows.contains(row) || rows.lowerBound - 1 == row {
            let y = CGFloat(row) * lineHeight - offsetY
            let left = NSRect(x: gx + 2, y: y + 1, width: 14, height: lineHeight - 2)
            let right = NSRect(x: gx + gutterWidth - 16, y: y + 1, width: 14, height: lineHeight - 2)
            for (rect, glyph) in [(left, "▶"), (right, "◀")] {
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                let s = NSAttributedString(string: glyph, attributes: attrs.merging([.foregroundColor: NSColor.controlAccentColor]) { $1 })
                let sz = s.size()
                s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            }
        }
    }

    private var overviewRect: NSRect { NSRect(x: bounds.width - overviewWidth, y: 0, width: overviewWidth, height: bounds.height) }

    private func drawOverview() {
        let r = overviewRect
        Palette.gutterBG.setFill(); r.fill()
        Palette.separator.setFill()
        NSRect(x: r.minX, y: 0, width: 0.5, height: r.height).fill()
        guard rowCount > 0 else { return }
        let scale = r.height / CGFloat(rowCount)
        for m in marks {
            let y = CGFloat(m.rows.lowerBound) * scale
            let h = max(2, CGFloat(m.rows.count) * scale)
            Palette.mark(m.style).withAlphaComponent(0.85).setFill()
            NSRect(x: r.minX + 3, y: y, width: r.width - 6, height: h).fill()
        }
        // viewport
        let vy = offsetY / lineHeight * scale
        let vh = max(10, visibleHeight / lineHeight * scale)
        let vr = NSRect(x: r.minX + 1, y: vy, width: r.width - 2, height: min(vh, r.height))
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: vr, xRadius: 3, yRadius: 3).fill()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let p = NSBezierPath(roundedRect: vr.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        p.lineWidth = 1; p.stroke()
    }

    private func lineNumberString(_ n: Int) -> NSAttributedString {
        if let s = lnCache[n] { return s }
        let s = NSAttributedString(string: String(n), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.86, weight: .regular),
            .foregroundColor: Palette.lineNumber,
        ])
        if lnCache.count > 4000 { lnCache.removeAll() }
        lnCache[n] = s
        return s
    }

    private func attributed(row: Int, pane: Int, cell: CanvasCell, text: String) -> NSAttributedString {
        let key = row &* 8 &+ pane
        if let a = cache[key] { return a }
        var display = text
        var hls = cell.highlights
        let limit = 6000
        if (display as NSString).length > limit { display = String((display as NSString).substring(to: limit)) + " …" }
        if display.contains("\t") || showWhitespace {
            (display, hls) = expand(display, hls)
        }
        let color: NSColor = cell.style == .unimportant ? Palette.unimportantMark : Palette.text
        let a = NSMutableAttributedString(string: display, attributes: [.font: font, .foregroundColor: color])
        let len = a.length
        let hl = Palette.highlight(cell.style)
        for r in hls {
            let rr = NSIntersectionRange(r, NSRange(location: 0, length: len))
            if rr.length > 0 { a.addAttribute(.backgroundColor, value: hl, range: rr) }
        }
        if showWhitespace {
            let ns = display as NSString
            var i = 0
            while i < ns.length {
                let c = ns.character(at: i)
                if c == 0x00B7 || c == 0x2192 { a.addAttribute(.foregroundColor, value: Palette.lineNumber, range: NSRange(location: i, length: 1)) }
                i += 1
            }
        }
        if !searchText.isEmpty {
            let ns = display as NSString
            var range = NSRange(location: 0, length: ns.length)
            let opts: NSString.CompareOptions = searchCaseSensitive ? [] : [.caseInsensitive]
            while range.length > 0 {
                let f = ns.range(of: searchText, options: opts, range: range)
                if f.location == NSNotFound { break }
                a.addAttribute(.backgroundColor, value: Palette.searchHL, range: f)
                let next = f.location + max(1, f.length)
                range = NSRange(location: next, length: ns.length - next)
            }
        }
        if cache.count > 6000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = a
        return a
    }

    /// Expands tabs (and optionally visualises whitespace) while remapping highlight ranges.
    private func expand(_ s: String, _ ranges: [NSRange]) -> (String, [NSRange]) {
        let u = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count + 16)
        var map = [Int](repeating: 0, count: u.count + 1)
        var col = 0
        for (i, c) in u.enumerated() {
            map[i] = out.count
            if c == 9 {
                let n = tabWidth - (col % tabWidth)
                if showWhitespace { out.append(0x2192); out.append(contentsOf: repeatElement(32, count: n - 1)) }
                else { out.append(contentsOf: repeatElement(32, count: n)) }
                col += n
            } else if c == 32 && showWhitespace {
                out.append(0x00B7); col += 1
            } else {
                out.append(c); col += 1
            }
        }
        map[u.count] = out.count
        let rs = ranges.compactMap { r -> NSRange? in
            let s0 = min(max(0, r.location), u.count), e0 = min(max(0, r.location + r.length), u.count)
            let s1 = map[s0], e1 = map[e0]
            return e1 > s1 ? NSRange(location: s1, length: e1 - s1) : nil
        }
        return (String(utf16CodeUnits: out, count: out.count), rs)
    }

    // MARK: Scrolling

    override func scrollWheel(with e: NSEvent) {
        cancelAnimation()
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dx *= lineHeight; dy *= lineHeight * 1.5 }
        if e.modifierFlags.contains(.shift) && dx == 0 { dx = dy; dy = 0 }
        // lock to dominant axis for trackpad gestures
        if abs(dx) > abs(dy) * 1.5 { dy = 0 } else if abs(dy) > abs(dx) * 1.5 { dx = 0 }
        offsetY -= dy
        offsetX -= dx
        clampOffsets()
        onScroll?()
    }

    func setOffsetY(_ y: CGFloat, animated: Bool) {
        let target = min(max(0, y), maxOffsetY)
        guard animated, abs(target - offsetY) > 1 else { offsetY = target; clampOffsets(); onScroll?(); return }
        cancelAnimation()
        let start = offsetY, t0 = CACurrentMediaTime(), dur = 0.22
        animTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - t0) / dur)
            let eased = 1 - pow(1 - p, 3)
            self.offsetY = start + (target - start) * eased
            self.clampOffsets()
            self.onScroll?()
            if p >= 1 { t.invalidate(); self.animTimer = nil }
        }
    }

    private func cancelAnimation() { animTimer?.invalidate(); animTimer = nil }

    /// Scrolls so that `row` is visible; `center` places it about a third from the top.
    func reveal(row: Int, center: Bool = false, animated: Bool = true) {
        let y = CGFloat(row) * lineHeight
        if center {
            setOffsetY(y - visibleHeight / 3, animated: animated)
        } else if y < offsetY {
            setOffsetY(y - lineHeight, animated: animated)
        } else if y + lineHeight > offsetY + visibleHeight {
            setOffsetY(y + lineHeight * 2 - visibleHeight, animated: animated)
        }
    }

    func setCurrentRow(_ r: Int, extend: Bool = false, center: Bool = false, animated: Bool = true) {
        guard rowCount > 0 else { return }
        let row = min(max(0, r), rowCount - 1)
        currentRow = row
        if extend { selection = min(anchorRow, row)...max(anchorRow, row) }
        else { anchorRow = row; selection = row...row }
        reveal(row: row, center: center, animated: animated)
        needsDisplay = true
        onCurrentRowChanged?(row)
    }

    func select(rows: ClosedRange<Int>, center: Bool = true) {
        guard rowCount > 0 else { return }
        let lo = max(0, rows.lowerBound), hi = min(rowCount - 1, rows.upperBound)
        guard lo <= hi else { return }
        anchorRow = lo
        currentRow = lo
        selection = lo...hi
        reveal(row: lo, center: center)
        needsDisplay = true
        onCurrentRowChanged?(lo)
    }

    var selectedRows: ClosedRange<Int> { selection ?? currentRow...currentRow }

    // MARK: Mouse

    private func pane(atX x: CGFloat) -> Int {
        for (i, r) in paneRects().enumerated() where x < r.maxX { return i }
        return paneCount - 1
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if overviewRect.contains(p) { draggingOverview = true; jumpOverview(p.y); return }
        let panes = paneRects()
        if showArrows, panes.count == 2, p.x > panes[0].maxX, p.x < panes[1].minX {
            let r = row(at: p.y)
            if let block = arrows[r] {
                let toRight = p.x < panes[0].maxX + gutterWidth / 2
                onArrow?(block, toRight)
            }
            return
        }
        let r = row(at: p.y)
        guard r < rowCount else { return }
        activePane = pane(atX: p.x)
        if e.clickCount == 2 {
            if dataSource?.isEditable(pane: activePane) == true { beginEdit(row: r, pane: activePane) }
            else { onDoubleClick?(r, activePane) }
            return
        }
        setCurrentRow(r, extend: e.modifierFlags.contains(.shift), animated: false)
        draggingSelection = true
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if draggingOverview { jumpOverview(p.y); return }
        guard draggingSelection else { return }
        if p.y < 0 { offsetY -= lineHeight; clampOffsets() }
        else if p.y > bounds.height { offsetY += lineHeight; clampOffsets() }
        let r = min(max(0, row(at: p.y)), rowCount - 1)
        currentRow = r
        selection = min(anchorRow, r)...max(anchorRow, r)
        needsDisplay = true
        onCurrentRowChanged?(r)
    }

    override func mouseUp(with e: NSEvent) { draggingOverview = false; draggingSelection = false }

    private func jumpOverview(_ y: CGFloat) {
        guard rowCount > 0 else { return }
        let row = CGFloat(rowCount) * min(max(0, y), bounds.height) / bounds.height
        setOffsetY(row * lineHeight - visibleHeight / 2, animated: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p.y)
        guard r < rowCount else { return nil }
        activePane = pane(atX: p.x)
        if !(selection?.contains(r) ?? false) { setCurrentRow(r, animated: false) }
        return menuProvider?(r, activePane)
    }

    override func resetCursorRects() {
        addCursorRect(overviewRect, cursor: .pointingHand)
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        let shift = e.modifierFlags.contains(.shift)
        let page = max(1, Int(visibleHeight / lineHeight) - 2)
        switch e.keyCode {
        case 126: setCurrentRow(e.modifierFlags.contains(.command) ? 0 : currentRow - 1, extend: shift)
        case 125: setCurrentRow(e.modifierFlags.contains(.command) ? rowCount - 1 : currentRow + 1, extend: shift)
        case 116: setCurrentRow(currentRow - page, extend: shift)
        case 121: setCurrentRow(currentRow + page, extend: shift)
        case 115: setCurrentRow(0, extend: shift)
        case 119: setCurrentRow(rowCount - 1, extend: shift)
        case 123: activePane = max(0, activePane - 1); needsDisplay = true
        case 124: activePane = min(paneCount - 1, activePane + 1); needsDisplay = true
        case 36, 76, 120: // return, enter, F2
            if dataSource?.isEditable(pane: activePane) == true {
                if e.modifierFlags.contains(.command) { onInsertLine?(currentRow, activePane) }
                else { beginEdit(row: currentRow, pane: activePane) }
            }
        case 51, 117:
            if dataSource?.isEditable(pane: activePane) == true { onDelete?(selectedRows, activePane) }
        default: super.keyDown(with: e)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let ds = dataSource else { return }
        let lines = selectedRows.compactMap { ds.cell(row: $0, pane: activePane).text }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard rowCount > 0 else { return }
        anchorRow = 0; selection = 0...(rowCount - 1); needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Inline editing

    func beginEdit(row: Int, pane: Int) {
        guard let ds = dataSource, ds.isEditable(pane: pane), row < rowCount else { return }
        cancelEdit()
        setCurrentRow(row, animated: false)
        activePane = pane
        let cell = ds.cell(row: row, pane: pane)
        let f = NSTextField(string: cell.text ?? "")
        f.font = font
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = NSColor.textBackgroundColor
        f.wantsLayer = true
        f.layer?.borderColor = NSColor.controlAccentColor.cgColor
        f.layer?.borderWidth = 1.5
        f.layer?.cornerRadius = 3
        f.delegate = self
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.placeholderString = cell.text == nil ? "New line" : nil
        editor = f
        editingCell = (row, pane)
        addSubview(f)
        positionEditor()
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectedRange = NSRange(location: (cell.text as NSString?)?.length ?? 0, length: 0)
    }

    private func positionEditor() {
        guard let f = editor, let ec = editingCell else { return }
        let pr = paneRects()[min(ec.pane, paneCount - 1)]
        let tr = textRect(pr)
        let y = CGFloat(ec.row) * lineHeight - offsetY
        f.frame = NSRect(x: tr.minX + 2, y: y - 1, width: tr.width - 4, height: lineHeight + 2)
    }

    func cancelEdit() {
        editor?.removeFromSuperview()
        editor = nil
        editingCell = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            cancelEdit(); window?.makeFirstResponder(self); return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            commitEdit(); return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editor != nil { commitEdit() }
    }

    private func commitEdit() {
        guard let f = editor, let ec = editingCell else { return }
        let text = f.stringValue
        editor = nil; editingCell = nil
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        onEditCommit?(ec.row, ec.pane, text)
    }
}

/// Hosts a session-owned DiffCanvas in SwiftUI.
struct CanvasHost: NSViewRepresentable {
    let canvas: DiffCanvas
    @ObservedObject var prefs = Prefs.shared

    func makeNSView(context: Context) -> DiffCanvas { canvas }
    func updateNSView(_ v: DiffCanvas, context: Context) {
        let f = prefs.editorFont
        if v.font.fontName != f.fontName || v.font.pointSize != f.pointSize { v.setFont(f) }
        let ln = prefs.showLineNumbers && v.allowsLineNumbers
        if v.showLineNumbers != ln { v.showLineNumbers = ln }
        if v.tabWidth != prefs.tabWidth { v.tabWidth = prefs.tabWidth }
        if v.showWhitespace != prefs.showWhitespace { v.showWhitespace = prefs.showWhitespace }
    }
}
