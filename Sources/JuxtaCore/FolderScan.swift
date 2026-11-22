import Foundation

public struct FileMeta: Sendable, Hashable {
    public var url: URL
    public var size: Int64
    public var modified: Date
    public var isDirectory: Bool
    public var isHidden: Bool
}

public enum FolderStatus: String, Sendable {
    case same, leftNewer, rightNewer, different, leftOnly, rightOnly, folderDiffers
    public var isDifference: Bool { self != .same }
    public var isOrphan: Bool { self == .leftOnly || self == .rightOnly }
}

public enum FolderCriteria: String, CaseIterable, Codable, Sendable {
    case sizeAndTime = "Size & modified time"
    case timeOnly = "Modified time"
    case size = "Size"
    case content = "Binary content"
}

public struct FolderCompareSettings: Codable, Equatable, Sendable {
    public var criteria: FolderCriteria = .sizeAndTime
    public var timeTolerance: Double = 2
    public var includeHidden = false
    public var includePatterns = ""       // "*.swift;*.md"
    public var excludePatterns = ".git;.DS_Store;node_modules;.build"
    public init() {}

    func patterns(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    func matches(_ name: String, _ pats: [String]) -> Bool {
        pats.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }
    public func accepts(name: String, isDirectory: Bool, hidden: Bool) -> Bool {
        if !includeHidden && hidden { return false }
        if matches(name, patterns(excludePatterns)) { return false }
        if !isDirectory {
            let inc = patterns(includePatterns)
            if !inc.isEmpty && !matches(name, inc) { return false }
        }
        return true
    }
}

public final class FolderNode: Identifiable, @unchecked Sendable {
    public let id: String          // relative path
    public let name: String
    public var left: FileMeta?
    public var right: FileMeta?
    public var children: [FolderNode] = []
    public var status: FolderStatus = .same
    public let depth: Int

    public init(id: String, name: String, depth: Int, left: FileMeta?, right: FileMeta?) {
        self.id = id; self.name = name; self.depth = depth; self.left = left; self.right = right
    }
    public var isDirectory: Bool { (left?.isDirectory ?? false) || (right?.isDirectory ?? false) }

    public func walk(_ body: (FolderNode) -> Void) {
        body(self)
        for c in children { c.walk(body) }
    }
}

public struct FolderSummary: Sendable {
    public var files = 0, same = 0, different = 0, leftNewer = 0, rightNewer = 0, leftOnly = 0, rightOnly = 0
    public init() {}
}

public enum FolderScanner {
    public static func list(_ url: URL?, settings: FolderCompareSettings) -> [String: FileMeta] {
        guard let url else { return [:] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else { return [:] }
        var out: [String: FileMeta] = [:]
        for item in items {
            let v = try? item.resourceValues(forKeys: Set(keys))
            let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
            let hidden = (v?.isHidden ?? false) || item.lastPathComponent.hasPrefix(".")
            let name = item.lastPathComponent
            guard settings.accepts(name: name, isDirectory: isDir, hidden: hidden) else { continue }
            out[name] = FileMeta(url: item, size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast,
                                 isDirectory: isDir, isHidden: hidden)
        }
        return out
    }

    /// Recursively builds the aligned tree for two folders and classifies every entry.
    public static func compare(left: URL?, right: URL?, settings: FolderCompareSettings,
                               cancelled: @escaping () -> Bool = { false },
                               progress: ((String) -> Void)? = nil) -> FolderNode {
        let root = FolderNode(id: "", name: "", depth: -1,
                              left: left.map { FileMeta(url: $0, size: 0, modified: .distantPast, isDirectory: true, isHidden: false) },
                              right: right.map { FileMeta(url: $0, size: 0, modified: .distantPast, isDirectory: true, isHidden: false) })
        fill(root, settings: settings, cancelled: cancelled, progress: progress)
        return root
    }

    static func fill(_ node: FolderNode, settings: FolderCompareSettings, cancelled: () -> Bool, progress: ((String) -> Void)?) {
        if cancelled() { return }
        progress?(node.id)
        let l = node.left?.isDirectory == true ? list(node.left?.url, settings: settings) : [:]
        let r = node.right?.isDirectory == true ? list(node.right?.url, settings: settings) : [:]
        let names = Set(l.keys).union(r.keys).sorted { a, b in
            let da = (l[a]?.isDirectory ?? r[a]?.isDirectory) ?? false
            let db = (l[b]?.isDirectory ?? r[b]?.isDirectory) ?? false
            if da != db { return da }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        var children: [FolderNode] = []
        for name in names {
            let lm = l[name], rm = r[name]
            // A file on one side and a folder on the other are shown as two separate orphans.
            if let lm, let rm, lm.isDirectory != rm.isDirectory {
                let a = FolderNode(id: node.id + "/" + name + "#L", name: name, depth: node.depth + 1, left: lm, right: nil)
                let b = FolderNode(id: node.id + "/" + name + "#R", name: name, depth: node.depth + 1, left: nil, right: rm)
                for x in [a, b] { if x.isDirectory { fill(x, settings: settings, cancelled: cancelled, progress: progress) }; classify(x, settings: settings); children.append(x) }
                continue
            }
            let child = FolderNode(id: node.id + "/" + name, name: name, depth: node.depth + 1, left: lm, right: rm)
            if child.isDirectory { fill(child, settings: settings, cancelled: cancelled, progress: progress) }
            classify(child, settings: settings)
            children.append(child)
        }
        node.children = children
        if node.depth < 0 { aggregate(node) }
    }

    public static func classify(_ n: FolderNode, settings: FolderCompareSettings) {
        if n.left == nil { n.status = .rightOnly; return }
        if n.right == nil { n.status = .leftOnly; return }
        if n.isDirectory { aggregate(n); return }
        guard let l = n.left, let r = n.right else { return }
        let dt = l.modified.timeIntervalSince(r.modified)
        let timeSame = abs(dt) <= settings.timeTolerance
        switch settings.criteria {
        case .size:
            n.status = l.size == r.size ? .same : .different
        case .timeOnly:
            n.status = timeSame ? .same : (dt > 0 ? .leftNewer : .rightNewer)
        case .sizeAndTime:
            if l.size == r.size && timeSame { n.status = .same }
            else if !timeSame { n.status = dt > 0 ? .leftNewer : .rightNewer }
            else { n.status = .different }
        case .content:
            if l.size != r.size { n.status = .different }
            else { n.status = filesEqual(l.url, r.url) ? .same : .different }
        }
    }

    static func aggregate(_ n: FolderNode) {
        if n.left == nil { n.status = .rightOnly; return }
        if n.right == nil { n.status = .leftOnly; return }
        n.status = n.children.contains { $0.status != .same } ? .folderDiffers : .same
    }

    public static func filesEqual(_ a: URL, _ b: URL) -> Bool {
        guard let fa = try? FileHandle(forReadingFrom: a), let fb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? fa.close(); try? fb.close() }
        while true {
            let da = (try? fa.read(upToCount: 1 << 20)) ?? Data()
            let db = (try? fb.read(upToCount: 1 << 20)) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    public static func summary(_ root: FolderNode) -> FolderSummary {
        var s = FolderSummary()
        root.walk { n in
            guard n.depth >= 0, !n.isDirectory else { return }
            s.files += 1
            switch n.status {
            case .same: s.same += 1
            case .different: s.different += 1
            case .leftNewer: s.leftNewer += 1
            case .rightNewer: s.rightNewer += 1
            case .leftOnly: s.leftOnly += 1
            case .rightOnly: s.rightOnly += 1
            case .folderDiffers: break
            }
        }
        return s
    }
}

// MARK: - Synchronisation planning

public enum SyncMode: String, CaseIterable, Codable, Sendable {
    case updateRight = "Update Right"       // copy newer + orphans → right
    case updateLeft = "Update Left"
    case updateBoth = "Update Both"         // newer wins, orphans copied both ways
    case mirrorToRight = "Mirror to Right"  // make right identical to left (deletes right orphans)
    case mirrorToLeft = "Mirror to Left"

    public var detail: String {
        switch self {
        case .updateRight: return "Copy newer and left-only files to the right. Nothing is deleted."
        case .updateLeft: return "Copy newer and right-only files to the left. Nothing is deleted."
        case .updateBoth: return "Newer files win in both directions; orphans are copied to the other side."
        case .mirrorToRight: return "Make the right folder an exact copy of the left. Right-only items move to the Trash."
        case .mirrorToLeft: return "Make the left folder an exact copy of the right. Left-only items move to the Trash."
        }
    }
}

public enum SyncActionKind: String, Sendable { case copyToRight = "Copy →", copyToLeft = "← Copy", trashRight = "Trash right", trashLeft = "Trash left" }

public struct SyncAction: Identifiable, Sendable {
    public let id = UUID()
    public var kind: SyncActionKind
    public var path: String
    public var source: URL?
    public var destination: URL
    public var isDirectory: Bool
    public init(kind: SyncActionKind, path: String, source: URL?, destination: URL, isDirectory: Bool) {
        self.kind = kind; self.path = path; self.source = source; self.destination = destination; self.isDirectory = isDirectory
    }
}

public enum SyncPlanner {
    public static func plan(root: FolderNode, leftRoot: URL, rightRoot: URL, mode: SyncMode) -> [SyncAction] {
        var actions: [SyncAction] = []
        func rel(_ n: FolderNode) -> String {
            var p = n.id
            if p.hasSuffix("#L") || p.hasSuffix("#R") { p.removeLast(2) }
            return p.hasPrefix("/") ? String(p.dropFirst()) : p
        }
        func visit(_ n: FolderNode) {
            let p = rel(n)
            let lURL = leftRoot.appendingPathComponent(p), rURL = rightRoot.appendingPathComponent(p)
            func copyR() { actions.append(SyncAction(kind: .copyToRight, path: p, source: n.left?.url, destination: rURL, isDirectory: n.isDirectory)) }
            func copyL() { actions.append(SyncAction(kind: .copyToLeft, path: p, source: n.right?.url, destination: lURL, isDirectory: n.isDirectory)) }
            switch n.status {
            case .same: return
            case .folderDiffers: n.children.forEach(visit); return
            case .leftOnly:
                switch mode {
                case .updateRight, .updateBoth, .mirrorToRight: copyR()
                case .mirrorToLeft: actions.append(SyncAction(kind: .trashLeft, path: p, source: nil, destination: lURL, isDirectory: n.isDirectory))
                case .updateLeft: break
                }
            case .rightOnly:
                switch mode {
                case .updateLeft, .updateBoth, .mirrorToLeft: copyL()
                case .mirrorToRight: actions.append(SyncAction(kind: .trashRight, path: p, source: nil, destination: rURL, isDirectory: n.isDirectory))
                case .updateRight: break
                }
            case .leftNewer:
                switch mode { case .updateRight, .updateBoth, .mirrorToRight: copyR(); case .mirrorToLeft: copyL(); case .updateLeft: break }
            case .rightNewer:
                switch mode { case .updateLeft, .updateBoth, .mirrorToLeft: copyL(); case .mirrorToRight: copyR(); case .updateRight: break }
            case .different:
                switch mode { case .mirrorToRight, .updateRight: copyR(); case .mirrorToLeft, .updateLeft: copyL(); case .updateBoth: break }
            }
        }
        root.children.forEach(visit)
        return actions
    }

    /// Executes actions; returns per-action error messages.
    public static func execute(_ actions: [SyncAction]) -> [String] {
        let fm = FileManager.default
        var errors: [String] = []
        for a in actions {
            do {
                switch a.kind {
                case .copyToLeft, .copyToRight:
                    guard let src = a.source else { continue }
                    try fm.createDirectory(at: a.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: a.destination.path) {
                        try fm.trashItem(at: a.destination, resultingItemURL: nil)
                    }
                    try fm.copyItem(at: src, to: a.destination)
                case .trashLeft, .trashRight:
                    try fm.trashItem(at: a.destination, resultingItemURL: nil)
                }
            } catch {
                errors.append("\(a.path): \(error.localizedDescription)")
            }
        }
        return errors
    }
}
