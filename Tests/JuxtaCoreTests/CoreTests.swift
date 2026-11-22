import XCTest
@testable import JuxtaCore

final class CoreTests: XCTestCase {
    func testMyersLCS() {
        let a = Array("ABCABBA").map { Int($0.asciiValue!) }
        let b = Array("CBABAC").map { Int($0.asciiValue!) }
        let m = Myers.matches(a, b)
        XCTAssertEqual(m.count, 4)
        for (x, y) in m { XCTAssertEqual(a[x], b[y]) }
        for k in 1..<m.count { XCTAssertLessThan(m[k-1].0, m[k].0); XCTAssertLessThan(m[k-1].1, m[k].1) }
    }

    func testRandomLCSIsValidAndOptimal() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0...4, using: &rng) }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0...4, using: &rng) }
            let m = Myers.matches(a, b)
            for (x, y) in m { XCTAssertEqual(a[x], b[y]) }
            for k in m.indices.dropFirst() { XCTAssertLessThan(m[k-1].0, m[k].0); XCTAssertLessThan(m[k-1].1, m[k].1) }
            XCTAssertEqual(m.count, lcsLength(a, b))
        }
    }

    func lcsLength(_ a: [Int], _ b: [Int]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count { for j in 1...b.count { dp[i][j] = a[i-1] == b[j-1] ? dp[i-1][j-1] + 1 : max(dp[i-1][j], dp[i][j-1]) } }
        return dp[a.count][b.count]
    }

    func testTextDiffRowsAndBlocks() {
        let l = ["one", "two", "three", "four"]
        let r = ["one", "TWO!", "three", "five", "six"]
        let res = TextDiff.compare(left: l, right: r, options: CompareOptions())
        XCTAssertEqual(res.blocks.count, 2)
        XCTAssertEqual(res.rows.first?.kind, .same)
        XCTAssertTrue(res.rows.contains { $0.kind == .rightOnly })
    }

    func testIgnoreWhitespaceIsUnimportant() {
        var o = CompareOptions(); o.whitespace = .all
        let res = TextDiff.compare(left: ["a b"], right: ["ab"], options: o)
        XCTAssertEqual(res.stats.sections, 1)
        XCTAssertEqual(res.stats.importantSections, 0)
    }

    func testLineEndingsRoundTrip() {
        let d = TextDocument.fromString("a\r\nb\r\n")
        XCTAssertEqual(d.lines, ["a", "b"]); XCTAssertEqual(d.lineEnding, .crlf); XCTAssertTrue(d.trailingNewline)
        XCTAssertEqual(d.text, "a\r\nb\r\n")
        let e = TextDocument.fromString("x\ny")
        XCTAssertFalse(e.trailingNewline); XCTAssertEqual(e.text, "x\ny")
    }

    func testMerge3() {
        let base = ["a", "b", "c", "d"]
        let left = ["a", "B", "c", "d"]
        let right = ["a", "b", "c", "D", "e"]
        let ch = Merge3.merge(base: base, left: left, right: right)
        XCTAssertFalse(ch.contains { $0.kind == .conflict })
        XCTAssertEqual(Merge3.output(ch, base: base, left: left, right: right), ["a", "B", "c", "D", "e"])
        let conflict = Merge3.merge(base: base, left: ["a", "X", "c", "d"], right: ["a", "Y", "c", "d"])
        XCTAssertEqual(conflict.filter { $0.kind == .conflict }.count, 1)
    }

    func testCSV() {
        let t = Table.parse("id,name\n1,\"Smith, J\"\n2,\"a \"\"q\"\"\"\n")
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.rows[1][1], "Smith, J")
        XCTAssertEqual(t.rows[2][1], "a \"q\"")
        let u = Table.parse("id,name\n2,b\n1,a\n3,c\n")
        let res = TableDiff.compare(t, u, keyColumn: 0, hasHeader: true)
        XCTAssertTrue(res.contains { $0.kind == .rightOnly })
    }

    func testIntraline() {
        let (l, r) = TextDiff.intraline("let value = 10", "let value = 20")
        XCTAssertEqual(l.count, 1); XCTAssertEqual(r.count, 1)
    }

    func testHugeDifferentFilesFast() {
        let a = (0..<50_000).map { "left line \($0)" }
        let b = (0..<50_000).map { "right line \($0)" }
        let t = Date()
        let res = TextDiff.compare(left: a, right: b, options: CompareOptions())
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        XCTAssertEqual(res.blocks.count, 1)
    }
}
