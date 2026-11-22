import Foundation

public struct Table: Sendable {
    public var rows: [[String]]
    public var delimiter: Character
    public var columnCount: Int { rows.map(\.count).max() ?? 0 }

    public init(rows: [[String]], delimiter: Character) { self.rows = rows; self.delimiter = delimiter }

    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.prefix(20_000)
        let lines = sample.split(whereSeparator: \.isNewline).prefix(20)
        var best: Character = ",", bestScore = -1.0
        for d in [",", "\t", ";", "|"] as [Character] {
            let counts = lines.map { $0.filter { $0 == d }.count }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = Double(counts.filter { $0 == first }.count) / Double(counts.count)
            let score = consistent * 10 + Double(first) * 0.01
            if score > bestScore { bestScore = score; best = d }
        }
        return best
    }

    /// RFC 4180 style parser (quoted fields, doubled quotes, embedded newlines).
    public static func parse(_ text: String, delimiter: Character? = nil) -> Table {
        let d = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == d {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return Table(rows: rows, delimiter: d)
    }
}

public enum TableRowKind: Sendable { case same, changed, leftOnly, rightOnly }

public struct TableRowPair: Sendable {
    public var left: Int
    public var right: Int
    public var kind: TableRowKind
    public var changedColumns: Set<Int>
}

public enum TableDiff {
    /// Align rows either by a key column (matching keys pair up) or by row-content diff.
    public static func compare(_ a: Table, _ b: Table, keyColumn: Int?, hasHeader: Bool,
                               ignoreCase: Bool = false, trim: Bool = true) -> [TableRowPair] {
        func norm(_ s: String) -> String {
            var v = trim ? s.trimmingCharacters(in: .whitespaces) : s
            if ignoreCase { v = v.lowercased() }
            return v
        }
        func cellsDiffer(_ l: [String], _ r: [String]) -> Set<Int> {
            var set = Set<Int>()
            for c in 0..<max(l.count, r.count) {
                let x = c < l.count ? norm(l[c]) : "", y = c < r.count ? norm(r[c]) : ""
                if x != y { set.insert(c) }
            }
            return set
        }
        var out: [TableRowPair] = []
        let start = hasHeader ? 1 : 0
        if hasHeader, !a.rows.isEmpty || !b.rows.isEmpty {
            let l = a.rows.first ?? [], r = b.rows.first ?? []
            let ch = cellsDiffer(l, r)
            out.append(TableRowPair(left: a.rows.isEmpty ? -1 : 0, right: b.rows.isEmpty ? -1 : 0,
                                    kind: ch.isEmpty ? .same : .changed, changedColumns: ch))
        }
        let la = Array(max(0, min(start, a.rows.count))..<a.rows.count)
        let lb = Array(max(0, min(start, b.rows.count))..<b.rows.count)
        if let key = keyColumn {
            var index: [String: [Int]] = [:]
            for j in lb { index[norm(key < b.rows[j].count ? b.rows[j][key] : ""), default: []].append(j) }
            var usedB = Set<Int>()
            var matchOf: [Int: Int] = [:]
            for i in la {
                let k = norm(key < a.rows[i].count ? a.rows[i][key] : "")
                if var list = index[k], !list.isEmpty {
                    let j = list.removeFirst(); index[k] = list
                    usedB.insert(j); matchOf[i] = j
                }
            }
            // Walk left rows in order; right-only rows are emitted just before the first matched
            // right row that follows them.
            var bp = 0
            for i in la {
                if let j = matchOf[i] {
                    while bp < lb.count && lb[bp] < j {
                        if !usedB.contains(lb[bp]) { out.append(TableRowPair(left: -1, right: lb[bp], kind: .rightOnly, changedColumns: [])) }
                        bp += 1
                    }
                    let ch = cellsDiffer(a.rows[i], b.rows[j])
                    out.append(TableRowPair(left: i, right: j, kind: ch.isEmpty ? .same : .changed, changedColumns: ch))
                } else {
                    out.append(TableRowPair(left: i, right: -1, kind: .leftOnly, changedColumns: []))
                }
            }
            while bp < lb.count {
                if !usedB.contains(lb[bp]) { out.append(TableRowPair(left: -1, right: lb[bp], kind: .rightOnly, changedColumns: [])) }
                bp += 1
            }
            return out
        }
        var interner = Interner<String>()
        let ta = la.map { interner.id(a.rows[$0].map(norm).joined(separator: "\u{1F}")) }
        let tb = lb.map { interner.id(b.rows[$0].map(norm).joined(separator: "\u{1F}")) }
        let m = Myers.matches(ta, tb)
        var i = 0, j = 0
        func gap(_ ei: Int, _ ej: Int) {
            while i < ei && j < ej {
                let ch = cellsDiffer(a.rows[la[i]], b.rows[lb[j]])
                out.append(TableRowPair(left: la[i], right: lb[j], kind: .changed, changedColumns: ch)); i += 1; j += 1
            }
            while i < ei { out.append(TableRowPair(left: la[i], right: -1, kind: .leftOnly, changedColumns: [])); i += 1 }
            while j < ej { out.append(TableRowPair(left: -1, right: lb[j], kind: .rightOnly, changedColumns: [])); j += 1 }
        }
        for (x, y) in m {
            gap(x, y)
            out.append(TableRowPair(left: la[x], right: lb[y], kind: .same, changedColumns: [])); i = x + 1; j = y + 1
        }
        gap(la.count, lb.count)
        return out
    }
}
