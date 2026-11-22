import Foundation

/// Linear-space Myers O(ND) diff (middle-snake bisection) over integer token sequences.
/// Returns the matched index pairs (a longest common subsequence), ascending in both coordinates.
public enum Myers {
    /// Upper bound on inner-loop work before a sub-range is declared "no commonality". Keeps
    /// pathological inputs (two huge, wholly different files) responsive.
    public static var workBudget = 120_000_000

    public static func matches(_ a: [Int], _ b: [Int]) -> [(Int, Int)] {
        if a.isEmpty || b.isEmpty { return [] }
        // Tokens that never occur on the other side can never be matched. Dropping them first
        // shrinks wildly different inputs to almost nothing.
        let setA = Set(a), setB = Set(b)
        var ia: [Int] = [], ib: [Int] = []
        var fa: [Int] = [], fb: [Int] = []
        ia.reserveCapacity(a.count); ib.reserveCapacity(b.count)
        for (i, t) in a.enumerated() where setB.contains(t) { fa.append(t); ia.append(i) }
        for (j, t) in b.enumerated() where setA.contains(t) { fb.append(t); ib.append(j) }
        if fa.isEmpty || fb.isEmpty { return [] }
        var out: [(Int, Int)] = []
        out.reserveCapacity(min(fa.count, fb.count))
        var budget = workBudget
        fa.withUnsafeBufferPointer { pa in
            fb.withUnsafeBufferPointer { pb in
                diff(pa, 0, fa.count, pb, 0, fb.count, &out, &budget)
            }
        }
        return out.map { (ia[$0.0], ib[$0.1]) }
    }

    private static func diff(_ a: UnsafeBufferPointer<Int>, _ aLo0: Int, _ aHi0: Int,
                             _ b: UnsafeBufferPointer<Int>, _ bLo0: Int, _ bHi0: Int,
                             _ out: inout [(Int, Int)], _ budget: inout Int) {
        var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
        while aLo < aHi && bLo < bHi && a[aLo] == b[bLo] { out.append((aLo, bLo)); aLo += 1; bLo += 1 }
        var suffix = 0
        while aLo < aHi && bLo < bHi && a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1; suffix += 1 }
        if aLo < aHi && bLo < bHi && budget > 0 {
            if let (x, y) = bisect(a, aLo, aHi, b, bLo, bHi, &budget),
               !(x == aLo && y == bLo), !(x == aHi && y == bHi) {
                diff(a, aLo, x, b, bLo, y, &out, &budget)
                diff(a, x, aHi, b, y, bHi, &out, &budget)
            }
        }
        for s in 0..<suffix { out.append((aHi + s, bHi + s)) }
    }

    /// Port of the diff-match-patch bisect: finds the point where forward and reverse paths overlap.
    private static func bisect(_ a: UnsafeBufferPointer<Int>, _ aLo: Int, _ aHi: Int,
                               _ b: UnsafeBufferPointer<Int>, _ bLo: Int, _ bHi: Int,
                               _ budget: inout Int) -> (Int, Int)? {
        let n = aHi - aLo, m = bHi - bLo
        let maxD = (n + m + 1) / 2
        let vOffset = maxD
        let vLength = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: vLength)
        var v2 = [Int](repeating: -1, count: vLength)
        v1[vOffset + 1] = 0
        v2[vOffset + 1] = 0
        let delta = n - m
        let front = delta % 2 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0
        for d in 0..<maxD {
            budget -= 2 * d + 2
            if budget <= 0 { return nil }
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1o = vOffset + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1o - 1] < v1[k1o + 1]) { x1 = v1[k1o + 1] } else { x1 = v1[k1o - 1] + 1 }
                var y1 = x1 - k1
                while x1 < n && y1 < m && a[aLo + x1] == b[bLo + y1] { x1 += 1; y1 += 1 }
                v1[k1o] = x1
                if x1 > n { k1end += 2 }
                else if y1 > m { k1start += 2 }
                else if front {
                    let k2o = vOffset + delta - k1
                    if k2o >= 0 && k2o < vLength && v2[k2o] != -1 {
                        let x2 = n - v2[k2o]
                        if x1 >= x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2o = vOffset + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2o - 1] < v2[k2o + 1]) { x2 = v2[k2o + 1] } else { x2 = v2[k2o - 1] + 1 }
                var y2 = x2 - k2
                while x2 < n && y2 < m && a[aLo + n - x2 - 1] == b[bLo + m - y2 - 1] { x2 += 1; y2 += 1 }
                v2[k2o] = x2
                if x2 > n { k2end += 2 }
                else if y2 > m { k2start += 2 }
                else if !front {
                    let k1o = vOffset + delta - k2
                    if k1o >= 0 && k1o < vLength && v1[k1o] != -1 {
                        let x1 = v1[k1o]
                        let y1 = vOffset + x1 - k1o
                        if x1 >= n - x2 { return (aLo + x1, bLo + y1) }
                    }
                }
                k2 += 2
            }
        }
        return nil
    }
}

/// Maps arbitrary hashable keys to dense integer tokens, shared across the sequences being compared.
public struct Interner<Key: Hashable> {
    private var table: [Key: Int] = [:]
    public init() {}
    public mutating func id(_ k: Key) -> Int {
        if let v = table[k] { return v }
        let v = table.count
        table[k] = v
        return v
    }
}
