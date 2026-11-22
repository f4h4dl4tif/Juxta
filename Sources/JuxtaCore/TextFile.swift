import Foundation

public enum LineEnding: String, CaseIterable, Codable, Sendable {
    case lf = "LF", crlf = "CRLF", cr = "CR"
    public var string: String { self == .lf ? "\n" : self == .crlf ? "\r\n" : "\r" }
    public var label: String { self == .lf ? "Unix (LF)" : self == .crlf ? "Windows (CRLF)" : "Classic Mac (CR)" }
}

public enum TextEncodingKind: String, CaseIterable, Codable, Sendable {
    case utf8 = "UTF-8", utf8BOM = "UTF-8 BOM", utf16LE = "UTF-16 LE", utf16BE = "UTF-16 BE", latin1 = "Western (Windows-1252)"
    var foundation: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .windowsCP1252
        }
    }
}

/// A decoded text document: its lines plus everything needed to write it back unchanged.
public struct TextDocument: Sendable {
    public var lines: [String]
    public var encoding: TextEncodingKind
    public var lineEnding: LineEnding
    public var trailingNewline: Bool
    public var isBinary: Bool

    public init(lines: [String] = [], encoding: TextEncodingKind = .utf8, lineEnding: LineEnding = .lf, trailingNewline: Bool = true, isBinary: Bool = false) {
        self.lines = lines; self.encoding = encoding; self.lineEnding = lineEnding
        self.trailingNewline = trailingNewline; self.isBinary = isBinary
    }

    public static func load(_ url: URL) throws -> TextDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return decode(data)
    }

    public static func decode(_ data: Data) -> TextDocument {
        var enc: TextEncodingKind = .utf8
        var body = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { enc = .utf8BOM; body = data.dropFirst(3) }
        else if data.starts(with: [0xFF, 0xFE]) { enc = .utf16LE; body = data.dropFirst(2) }
        else if data.starts(with: [0xFE, 0xFF]) { enc = .utf16BE; body = data.dropFirst(2) }
        var text: String
        if let s = String(data: body, encoding: enc.foundation) { text = s }
        else if let s = String(data: body, encoding: .windowsCP1252) { text = s; enc = .latin1 }
        else { text = String(decoding: body, as: UTF8.self) }
        let binary = enc != .utf16LE && enc != .utf16BE && looksBinary(data)
        return fromString(text, encoding: enc, isBinary: binary)
    }

    public static func fromString(_ text: String, encoding: TextEncodingKind = .utf8, isBinary: Bool = false) -> TextDocument {
        var crlf = 0, lf = 0, cr = 0
        var lines: [String] = []
        let u = text.utf8
        var start = u.startIndex
        var idx = u.startIndex
        while idx != u.endIndex {
            let c = u[idx]
            if c == 0x0A || c == 0x0D {
                lines.append(String(text[start..<idx]))
                var next = u.index(after: idx)
                if c == 0x0D, next != u.endIndex, u[next] == 0x0A { crlf += 1; next = u.index(after: next) }
                else if c == 0x0D { cr += 1 } else { lf += 1 }
                idx = next; start = next
            } else {
                idx = u.index(after: idx)
            }
        }
        var trailing = true
        if start != u.endIndex { lines.append(String(text[start..<u.endIndex])); trailing = false }
        else if lines.isEmpty { trailing = false }
        let ending: LineEnding = crlf >= lf && crlf >= cr && crlf > 0 ? .crlf : (cr > lf ? .cr : .lf)
        return TextDocument(lines: lines, encoding: encoding, lineEnding: ending, trailingNewline: trailing, isBinary: isBinary)
    }

    public static func looksBinary(_ data: Data) -> Bool {
        let n = min(data.count, 8000)
        if n == 0 { return false }
        var nul = 0
        data.prefix(n).forEach { if $0 == 0 { nul += 1 } }
        return nul > 0
    }

    public var text: String {
        var s = lines.joined(separator: lineEnding.string)
        if trailingNewline && !lines.isEmpty { s += lineEnding.string }
        return s
    }

    public func encoded() -> Data {
        var d = Data()
        switch encoding {
        case .utf8BOM: d.append(contentsOf: [0xEF, 0xBB, 0xBF])
        case .utf16LE: d.append(contentsOf: [0xFF, 0xFE])
        case .utf16BE: d.append(contentsOf: [0xFE, 0xFF])
        default: break
        }
        d.append(text.data(using: encoding.foundation, allowLossyConversion: true) ?? Data())
        return d
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
