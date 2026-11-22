import Foundation
import JuxtaCore

enum Report {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\t", with: "    ")
    }

    static func highlighted(_ s: String, _ ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else { return esc(s) }
        let ns = s as NSString
        var out = "", pos = 0
        for r in ranges where r.location >= pos && NSMaxRange(r) <= ns.length {
            out += esc(ns.substring(with: NSRange(location: pos, length: r.location - pos)))
            out += "<mark>" + esc(ns.substring(with: r)) + "</mark>"
            pos = NSMaxRange(r)
        }
        out += esc(ns.substring(from: pos))
        return out
    }

    static let css = """
    :root{--bg:#fff;--fg:#1d1d1f;--mute:#8a8a93;--line:#e4e4ea;--chg:#ffecec;--hl:#ffb3b3;--orp:#f0eaff;--unimp:#ebf2fc;--fill:#f6f6f8}
    @media (prefers-color-scheme:dark){:root{--bg:#18181b;--fg:#ececf1;--mute:#72727c;--line:#34353a;--chg:#4e242a;--hl:#96343e;--orp:#382c5c;--unimp:#223046;--fill:#1e1e21}}
    body{background:var(--bg);color:var(--fg);font:13px -apple-system,system-ui,sans-serif;margin:24px}
    h1{font-size:20px;margin:0 0 4px} .meta{color:var(--mute);margin-bottom:16px}
    table{border-collapse:collapse;width:100%;table-layout:fixed;font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
    td{padding:1px 8px;white-space:pre;overflow:hidden;text-overflow:ellipsis;border-right:1px solid var(--line)}
    td.n{width:48px;text-align:right;color:var(--mute);background:var(--fill)}
    tr.c td.t{background:var(--chg)} tr.o td.t{background:var(--orp)} tr.u td.t{background:var(--unimp)}
    td.f{background:repeating-linear-gradient(135deg,var(--fill),var(--fill) 4px,var(--line) 4px,var(--line) 5px)!important}
    mark{background:var(--hl);color:inherit;border-radius:2px} th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line)}
    tr.gap td{background:var(--fill);color:var(--mute);text-align:center}
    """

    static func textHTML(session s: TextSession) -> String {
        let st = s.result.stats
        var rows = ""
        let ctx = Prefs.shared.contextLines
        var keep = [Bool](repeating: false, count: s.result.rows.count)
        for b in s.result.blocks { for k in max(0, b.rows.lowerBound - ctx)..<min(keep.count, b.rows.upperBound + ctx) { keep[k] = true } }
        var gap = false
        for (k, r) in s.result.rows.enumerated() {
            guard keep[k] else { if !gap { rows += "<tr class=gap><td colspan=4>⋯</td></tr>"; gap = true }; continue }
            gap = false
            let cls: String
            switch r.kind { case .same: cls = ""; case .changed: cls = r.unimportant ? "u" : "c"; default: cls = r.unimportant ? "u" : "o" }
            var hl: ([NSRange], [NSRange]) = ([], [])
            if r.kind == .changed { hl = TextDiff.intraline(s.left.lines[r.left], s.right.lines[r.right]) }
            func side(_ idx: Int, _ lines: [String], _ h: [NSRange]) -> String {
                idx >= 0 ? "<td class=n>\(idx + 1)</td><td class=t>\(highlighted(lines[idx], h))</td>" : "<td class=n></td><td class='t f'></td>"
            }
            rows += "<tr class='\(cls)'>" + side(r.left, s.left.lines, hl.0) + side(r.right, s.right.lines, hl.1) + "</tr>\n"
        }
        return """
        <!doctype html><html><head><meta charset=utf-8><title>Text Compare Report</title><style>\(css)</style></head><body>
        <h1>Text Compare Report</h1>
        <div class=meta>\(esc(s.leftURL?.path ?? "Left")) ↔ \(esc(s.rightURL?.path ?? "Right"))<br>
        \(st.importantSections) important difference section(s), \(st.changedLines) changed, \(st.leftOnlyLines) left-only, \(st.rightOnlyLines) right-only lines · Generated \(Date().formatted())</div>
        <table><colgroup><col style="width:48px"><col><col style="width:48px"><col></colgroup>
        <tr><th></th><th>\(esc(s.leftURL?.lastPathComponent ?? "Left"))</th><th></th><th>\(esc(s.rightURL?.lastPathComponent ?? "Right"))</th></tr>
        \(rows)</table></body></html>
        """
    }

    static func folderHTML(root: FolderNode, left: URL?, right: URL?) -> String {
        var rows = ""
        root.walk { n in
            guard n.depth >= 0 else { return }
            let pad = String(repeating: "&nbsp;&nbsp;&nbsp;", count: n.depth)
            let cls = n.status == .same ? "" : (n.status.isOrphan ? "o" : "c")
            func meta(_ m: FileMeta?) -> String {
                guard let m else { return "<td class='t f'></td><td class='t f'></td>" }
                return "<td class=t>\(m.isDirectory ? "" : formatBytes(m.size))</td><td class=t>\(shortDate.string(from: m.modified))</td>"
            }
            rows += "<tr class='\(cls)'><td class=t>\(pad)\(n.isDirectory ? "📁 " : "")\(esc(n.name))</td>\(meta(n.left))<td class=t>\(n.status.rawValue)</td>\(meta(n.right))</tr>\n"
        }
        return """
        <!doctype html><html><head><meta charset=utf-8><title>Folder Compare Report</title><style>\(css) td{white-space:nowrap}</style></head><body>
        <h1>Folder Compare Report</h1><div class=meta>\(esc(left?.path ?? "")) ↔ \(esc(right?.path ?? "")) · Generated \(Date().formatted())</div>
        <table><tr><th>Name</th><th>Left size</th><th>Left modified</th><th>Status</th><th>Right size</th><th>Right modified</th></tr>\(rows)</table></body></html>
        """
    }
}
