import Foundation

public enum MergeChunkKind: Sendable { case stable, leftChange, rightChange, bothSame, conflict }

public enum MergeResolution: Equatable, Sendable {
    case unresolved, left, right, base, leftThenRight, rightThenLeft
    case custom([String])
}

/// One aligned region of a three-way merge.
public struct MergeChunk: Identifiable, Sendable {
    public let id: Int
    public var base: Range<Int>
    public var left: Range<Int>
    public var right: Range<Int>
    public var kind: MergeChunkKind
    public var resolution: MergeResolution
    public var isChange: Bool { kind != .stable }
}

public enum Merge3 {
    /// Classic diff3: anchors on base lines that both sides kept, and classifies every region between anchors.
    public static func merge(base: [String], left: [String], right: [String], options: CompareOptions = CompareOptions()) -> [MergeChunk] {
        let rx = options.compiledPatterns()
        var interner = Interner<String>()
        let tb = base.map { interner.id(options.normalize($0, regexes: rx)) }
        let tl = left.map { interner.id(options.normalize($0, regexes: rx)) }
        let tr = right.map { interner.id(options.normalize($0, regexes: rx)) }
        var mapL = [Int](repeating: -1, count: base.count)
        var mapR = [Int](repeating: -1, count: base.count)
        for (b, l) in Myers.matches(tb, tl) { mapL[b] = l }
        for (b, r) in Myers.matches(tb, tr) { mapR[b] = r }

        var chunks: [MergeChunk] = []
        var i = 0, l = 0, r = 0
        func add(_ b: Range<Int>, _ lr: Range<Int>, _ rr: Range<Int>, stable: Bool) {
            if b.isEmpty && lr.isEmpty && rr.isEmpty { return }
            var kind: MergeChunkKind = .stable
            var res: MergeResolution = .base
            if !stable {
                let bs = Array(tb[b]), ls = Array(tl[lr]), rs = Array(tr[rr])
                let lc = ls != bs, rc = rs != bs
                switch (lc, rc) {
                case (false, false): kind = .stable; res = .base
                case (true, false): kind = .leftChange; res = .left
                case (false, true): kind = .rightChange; res = .right
                case (true, true):
                    if ls == rs { kind = .bothSame; res = .left } else { kind = .conflict; res = .unresolved }
                }
            }
            // Merge adjacent stable regions for a compact model.
            if kind == .stable, let last = chunks.last, last.kind == .stable,
               last.base.upperBound == b.lowerBound, last.left.upperBound == lr.lowerBound, last.right.upperBound == rr.lowerBound {
                chunks[chunks.count - 1].base = last.base.lowerBound..<b.upperBound
                chunks[chunks.count - 1].left = last.left.lowerBound..<lr.upperBound
                chunks[chunks.count - 1].right = last.right.lowerBound..<rr.upperBound
                return
            }
            chunks.append(MergeChunk(id: chunks.count, base: b, left: lr, right: rr, kind: kind, resolution: res))
        }
        while i < base.count || l < left.count || r < right.count {
            if i < base.count && mapL[i] == l && mapR[i] == r {
                add(i..<(i + 1), l..<(l + 1), r..<(r + 1), stable: true)
                i += 1; l += 1; r += 1
                continue
            }
            var j = i
            while j < base.count && !(mapL[j] >= l && mapR[j] >= r && mapL[j] >= 0 && mapR[j] >= 0) { j += 1 }
            let lEnd = j < base.count ? mapL[j] : left.count
            let rEnd = j < base.count ? mapR[j] : right.count
            add(i..<j, l..<lEnd, r..<rEnd, stable: false)
            i = j; l = lEnd; r = rEnd
            if j >= base.count && l >= left.count && r >= right.count { break }
        }
        // Re-number ids sequentially.
        for k in chunks.indices { chunks[k] = MergeChunk(id: k, base: chunks[k].base, left: chunks[k].left, right: chunks[k].right, kind: chunks[k].kind, resolution: chunks[k].resolution) }
        return chunks
    }

    public static func lines(for chunk: MergeChunk, base: [String], left: [String], right: [String]) -> [String]? {
        switch chunk.resolution {
        case .unresolved: return nil
        case .base: return Array(base[chunk.base])
        case .left: return Array(left[chunk.left])
        case .right: return Array(right[chunk.right])
        case .leftThenRight: return Array(left[chunk.left]) + Array(right[chunk.right])
        case .rightThenLeft: return Array(right[chunk.right]) + Array(left[chunk.left])
        case .custom(let c): return c
        }
    }

    /// Output text with git-style conflict markers for unresolved chunks.
    public static func output(_ chunks: [MergeChunk], base: [String], left: [String], right: [String],
                              leftLabel: String = "LEFT", rightLabel: String = "RIGHT") -> [String] {
        var out: [String] = []
        for c in chunks {
            if let ls = lines(for: c, base: base, left: left, right: right) { out += ls }
            else {
                out.append("<<<<<<< \(leftLabel)")
                out += left[c.left]
                out.append("||||||| BASE")
                out += base[c.base]
                out.append("=======")
                out += right[c.right]
                out.append(">>>>>>> \(rightLabel)")
            }
        }
        return out
    }
}
