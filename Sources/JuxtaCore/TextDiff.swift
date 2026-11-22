import Foundation

public enum WhitespaceRule: String, CaseIterable, Codable, Sendable {
    case compare = "Compare whitespace"
    case leadingTrailing = "Ignore leading/trailing"
    case changes = "Ignore whitespace changes"
    case all = "Ignore all whitespace"
}

/// Comparison rules. Differences that only exist because of an ignored rule are reported as
/// *unimportant* rather than hidden, mirroring how professional compare tools present them.
public struct CompareOptions: Equatable, Codable, Sendable {
    public var whitespace: WhitespaceRule = .compare
    public var ignoreCase = false
    public var ignoreBlankLines = false
    /// Regular expressions whose matches are ignored (e.g. timestamps, version stamps).
    public var ignorePatterns: [String] = []
    public init() {}

    public func normalize(_ line: String, regexes: [NSRegularExpression]) -> String {
        var s = line
        if !regexes.isEmpty {
            for r in regexes {
                s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }
        }
        switch whitespace {
        case .compare: break
        case .leadingTrailing: s = s.trimmingCharacters(in: .whitespaces)
        case .changes:
            s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        case .all: s.removeAll(where: { $0 == " " || $0 == "\t" })
        }
        if ignoreCase { s = s.lowercased() }
        return s
    }

    public func compiledPatterns() -> [NSRegularExpression] {
        ignorePatterns.compactMap { $0.isEmpty ? nil : try? NSRegularExpression(pattern: $0) }
    }

    public var isDefault: Bool { self == CompareOptions() }
}

public enum RowKind: UInt8, Sendable { case same, changed, leftOnly, rightOnly }

public struct DiffRow: Sendable {
    public var left: Int      // line index or -1
    public var right: Int     // line index or -1
    public var kind: RowKind
    public var unimportant: Bool
    public var block: Int     // difference section index or -1
    public init(left: Int, right: Int, kind: RowKind, unimportant: Bool = false, block: Int = -1) {
        self.left = left; self.right = right; self.kind = kind; self.unimportant = unimportant; self.block = block
    }
}

public struct DiffBlock: Sendable {
    public var rows: Range<Int>
    public var unimportant: Bool
}

public struct DiffStats: Sendable {
    public var sections = 0
    public var importantSections = 0
    public var changedLines = 0
    public var leftOnlyLines = 0
    public var rightOnlyLines = 0
    public var sameLines = 0
    public var identical: Bool { sections == 0 }
    public var onlyUnimportant: Bool { sections > 0 && importantSections == 0 }
}

public struct DiffResult: Sendable {
    public var rows: [DiffRow]
    public var blocks: [DiffBlock]
    public var stats: DiffStats
    public static let empty = DiffResult(rows: [], blocks: [], stats: DiffStats())
}

public enum TextDiff {
    public static func compare(left: [String], right: [String], options: CompareOptions) -> DiffResult {
        let regexes = options.compiledPatterns()
        var interner = Interner<String>()
        let normL = left.map { options.normalize($0, regexes: regexes) }
        let normR = right.map { options.normalize($0, regexes: regexes) }
        let isBlank: (String) -> Bool = { $0.allSatisfy { $0 == " " || $0 == "\t" } }

        var tokL: [Int] = [], tokR: [Int] = [], mapL: [Int] = [], mapR: [Int] = []
        tokL.reserveCapacity(left.count); tokR.reserveCapacity(right.count)
        for (i, s) in normL.enumerated() {
            if options.ignoreBlankLines && isBlank(left[i]) { continue }
            tokL.append(interner.id(s)); mapL.append(i)
        }
        for (j, s) in normR.enumerated() {
            if options.ignoreBlankLines && isBlank(right[j]) { continue }
            tokR.append(interner.id(s)); mapR.append(j)
        }
        let matched = Myers.matches(tokL, tokR).map { (mapL[$0.0], mapR[$0.1]) }

        var rows: [DiffRow] = []
        rows.reserveCapacity(max(left.count, right.count) + 16)
        var i = 0, j = 0
        func emitGap(_ li: Range<Int>, _ rj: Range<Int>) {
            for (l, r) in align(Array(li), Array(rj), left, right) {
                if l >= 0 && r >= 0 {
                    let unimp = normL[l] == normR[r]
                    rows.append(DiffRow(left: l, right: r, kind: .changed, unimportant: unimp))
                } else if l >= 0 {
                    rows.append(DiffRow(left: l, right: -1, kind: .leftOnly,
                                        unimportant: options.ignoreBlankLines && isBlank(left[l])))
                } else {
                    rows.append(DiffRow(left: -1, right: r, kind: .rightOnly,
                                        unimportant: options.ignoreBlankLines && isBlank(right[r])))
                }
            }
        }
        for (mi, mj) in matched {
            if mi > i || mj > j { emitGap(i..<mi, j..<mj) }
            if left[mi] == right[mj] {
                rows.append(DiffRow(left: mi, right: mj, kind: .same))
            } else {
                rows.append(DiffRow(left: mi, right: mj, kind: .changed, unimportant: true))
            }
            i = mi + 1; j = mj + 1
        }
        if i < left.count || j < right.count { emitGap(i..<left.count, j..<right.count) }

        // Group contiguous non-identical rows into difference sections.
        var blocks: [DiffBlock] = []
        var stats = DiffStats()
        var k = 0
        while k < rows.count {
            if rows[k].kind == .same { stats.sameLines += 1; k += 1; continue }
            let start = k
            var allUnimportant = true
            while k < rows.count && rows[k].kind != .same {
                rows[k].block = blocks.count
                if !rows[k].unimportant { allUnimportant = false }
                switch rows[k].kind {
                case .changed: stats.changedLines += 1
                case .leftOnly: stats.leftOnlyLines += 1
                case .rightOnly: stats.rightOnlyLines += 1
                case .same: break
                }
                k += 1
            }
            blocks.append(DiffBlock(rows: start..<k, unimportant: allUnimportant))
        }
        stats.sections = blocks.count
        stats.importantSections = blocks.filter { !$0.unimportant }.count
        return DiffResult(rows: rows, blocks: blocks, stats: stats)
    }

    /// Aligns the lines of a changed region so that similar lines sit side by side and the
    /// rest become orphans. Returns (leftIndex, rightIndex) pairs where -1 means "no line".
    static func align(_ ls: [Int], _ rs: [Int], _ left: [String], _ right: [String]) -> [(Int, Int)] {
        if ls.isEmpty { return rs.map { (-1, $0) } }
        if rs.isEmpty { return ls.map { ($0, -1) } }
        let n = ls.count, m = rs.count
        guard n * m <= 60_000 else {
            var out: [(Int, Int)] = []
            for k in 0..<max(n, m) { out.append((k < n ? ls[k] : -1, k < m ? rs[k] : -1)) }
            return out
        }
        if n == 1 && m == 1 { return [(ls[0], rs[0])] }
        let bl = ls.map { bigrams(left[$0]) }
        let br = rs.map { bigrams(right[$0]) }
        var sim = [Double](repeating: 0, count: n * m)
        for a in 0..<n { for b in 0..<m { sim[a * m + b] = dice(bl[a], br[b]) } }
        let threshold = 0.35
        var dp = [Double](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for a in 1...n {
            for b in 1...m {
                var best = max(dp[(a - 1) * w + b], dp[a * w + b - 1])
                let s = sim[(a - 1) * m + b - 1]
                if s >= threshold { best = max(best, dp[(a - 1) * w + b - 1] + s) }
                dp[a * w + b] = best
            }
        }
        var pairs: [(Int, Int)] = []
        var a = n, b = m
        while a > 0 && b > 0 {
            let s = sim[(a - 1) * m + b - 1]
            if s >= threshold && abs(dp[a * w + b] - (dp[(a - 1) * w + b - 1] + s)) < 1e-9 {
                pairs.append((a - 1, b - 1)); a -= 1; b -= 1
            } else if dp[(a - 1) * w + b] >= dp[a * w + b - 1] { a -= 1 } else { b -= 1 }
        }
        pairs.reverse()
        // When nothing is similar, still pair line-by-line in order: that reads best for edits.
        if pairs.isEmpty {
            var out: [(Int, Int)] = []
            for k in 0..<max(n, m) { out.append((k < n ? ls[k] : -1, k < m ? rs[k] : -1)) }
            return out
        }
        var out: [(Int, Int)] = []
        var pa = 0, pb = 0
        func flush(_ ea: Int, _ eb: Int) {
            // pair leftover lines in order as "changed" rows, then orphans
            while pa < ea && pb < eb { out.append((ls[pa], rs[pb])); pa += 1; pb += 1 }
            while pa < ea { out.append((ls[pa], -1)); pa += 1 }
            while pb < eb { out.append((-1, rs[pb])); pb += 1 }
        }
        for (x, y) in pairs {
            flush(x, y)
            out.append((ls[x], rs[y])); pa = x + 1; pb = y + 1
        }
        flush(n, m)
        return out
    }

    static func bigrams(_ s: String) -> Set<UInt32> {
        let u = Array(s.utf16.lazy.filter { $0 != 32 && $0 != 9 })
        var set = Set<UInt32>()
        if u.count < 2 { if let f = u.first { set.insert(UInt32(f)) }; return set }
        for k in 0..<(u.count - 1) { set.insert(UInt32(u[k]) << 16 | UInt32(u[k + 1])) }
        return set
    }

    static func dice(_ a: Set<UInt32>, _ b: Set<UInt32>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let (small, big) = a.count < b.count ? (a, b) : (b, a)
        var inter = 0
        for x in small where big.contains(x) { inter += 1 }
        return 2 * Double(inter) / Double(a.count + b.count)
    }

    /// Character-level differences within a pair of lines, as UTF-16 ranges for each side.
    public static func intraline(_ l: String, _ r: String, ignoreCase: Bool = false) -> (left: [NSRange], right: [NSRange]) {
        let a = Array(l.utf16), b = Array(r.utf16)
        if a.isEmpty { return ([], b.isEmpty ? [] : [NSRange(location: 0, length: b.count)]) }
        if b.isEmpty { return ([NSRange(location: 0, length: a.count)], []) }
        func tok(_ c: UInt16) -> Int {
            if ignoreCase, c >= 65 && c <= 90 { return Int(c + 32) }
            return Int(c)
        }
        let saved = Myers.workBudget
        Myers.workBudget = 2_000_000
        let m = Myers.matches(a.map(tok), b.map(tok))
        Myers.workBudget = saved
        var matchA = [Bool](repeating: false, count: a.count)
        var matchB = [Bool](repeating: false, count: b.count)
        for (x, y) in m { matchA[x] = true; matchB[y] = true }
        // Absorb tiny equal islands between changes so highlights read as whole words.
        func smooth(_ flags: inout [Bool], _ chars: [UInt16]) {
            var k = 0
            while k < flags.count {
                if flags[k] { k += 1; continue }
                var e = k; while e < flags.count && !flags[e] { e += 1 }
                var s2 = e; while s2 < flags.count && flags[s2] { s2 += 1 }
                if e < flags.count && s2 < flags.count && s2 - e <= 2 && k < e {
                    for q in e..<s2 { flags[q] = false }
                }
                k = e == k ? k + 1 : e
            }
        }
        let ratio = Double(m.count * 2) / Double(a.count + b.count)
        if ratio < 0.3 {
            return ([NSRange(location: 0, length: a.count)], [NSRange(location: 0, length: b.count)])
        }
        smooth(&matchA, a); smooth(&matchB, b)
        func ranges(_ f: [Bool]) -> [NSRange] {
            var out: [NSRange] = []
            var k = 0
            while k < f.count {
                if f[k] { k += 1; continue }
                let s = k; while k < f.count && !f[k] { k += 1 }
                out.append(NSRange(location: s, length: k - s))
            }
            return out
        }
        return (ranges(matchA), ranges(matchB))
    }

    /// Unified diff (patch) text for the two documents.
    public static func unifiedPatch(left: [String], right: [String], leftName: String, rightName: String,
                                    result: DiffResult, context: Int = 3) -> String {
        var out = "--- \(leftName)\n+++ \(rightName)\n"
        let rows = result.rows
        // Group blocks into hunks, merging those whose context overlaps.
        var hunks: [Range<Int>] = []
        for block in result.blocks {
            let s = max(0, block.rows.lowerBound - context)
            let e = min(rows.count, block.rows.upperBound + context)
            if let last = hunks.last, s <= last.upperBound { hunks[hunks.count - 1] = last.lowerBound..<max(e, last.upperBound) }
            else { hunks.append(s..<e) }
        }
        for h in hunks {
            var lStart = -1, rStart = -1, lCount = 0, rCount = 0
            var body = ""
            var dels: [String] = [], adds: [String] = []
            func flush() {
                for d in dels { body += "-\(d)\n" }
                for a in adds { body += "+\(a)\n" }
                dels.removeAll(); adds.removeAll()
            }
            for k in h {
                let row = rows[k]
                if row.left >= 0 && lStart < 0 { lStart = row.left }
                if row.right >= 0 && rStart < 0 { rStart = row.right }
                if row.kind == .same {
                    flush()
                    body += " \(left[row.left])\n"; lCount += 1; rCount += 1
                } else {
                    if row.left >= 0 { dels.append(left[row.left]); lCount += 1 }
                    if row.right >= 0 { adds.append(right[row.right]); rCount += 1 }
                }
            }
            flush()
            if lStart < 0 { lStart = previousIndex(rows, h.lowerBound, left: true) }
            if rStart < 0 { rStart = previousIndex(rows, h.lowerBound, left: false) }
            out += "@@ -\(lCount == 0 ? lStart : lStart + 1),\(lCount) +\(rCount == 0 ? rStart : rStart + 1),\(rCount) @@\n" + body
        }
        return out
    }

    static func previousIndex(_ rows: [DiffRow], _ k: Int, left: Bool) -> Int {
        var q = k - 1
        while q >= 0 { let v = left ? rows[q].left : rows[q].right; if v >= 0 { return v + 1 }; q -= 1 }
        return 0
    }
}
