import AppKit
import SwiftUI
import CoreGraphics

enum ImageMode: String, CaseIterable { case sideBySide = "Side by Side", difference = "Difference", blend = "Blend", swipe = "Swipe" }

final class ImageSession: BaseSession {
    @Published var leftURL: URL?
    @Published var rightURL: URL?
    @Published private(set) var left: NSImage?
    @Published private(set) var right: NSImage?
    @Published private(set) var diff: NSImage?
    @Published private(set) var diffPixels = 0
    @Published private(set) var totalPixels = 0
    @Published var mode: ImageMode = .sideBySide
    @Published var tolerance: Double = 8 { didSet { computeDiff() } }
    @Published var blend: Double = 0.5
    @Published var swipe: Double = 0.5
    @Published var zoom: CGFloat? = nil     // nil = fit
    @Published var pan: CGSize = .zero

    init(left: URL?, right: URL?) {
        super.init(kind: .image)
        leftURL = left; rightURL = right
        load()
    }

    override var recentPaths: [String] { [leftURL?.path ?? "", rightURL?.path ?? ""] }

    func load() {
        left = leftURL.flatMap { NSImage(contentsOf: $0) }
        right = rightURL.flatMap { NSImage(contentsOf: $0) }
        title = "\(leftURL?.lastPathComponent ?? "—") ↔ \(rightURL?.lastPathComponent ?? "—")"
        computeDiff()
    }

    func setURL(_ u: URL, side: Int) {
        if side == 0 { leftURL = u } else { rightURL = u }
        Recents.shared.add(kind: .image, paths: recentPaths)
        load()
    }

    func pixelSize(_ i: NSImage?) -> CGSize {
        guard let i, let rep = i.representations.first else { return .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var canvasSize: CGSize {
        let a = pixelSize(left), b = pixelSize(right)
        return CGSize(width: max(a.width, b.width, 1), height: max(a.height, b.height, 1))
    }

    private static func rgba(_ img: NSImage, w: Int, h: Int) -> [UInt8]? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw at native pixel size, top-left aligned.
        ctx.draw(cg, in: CGRect(x: 0, y: h - cg.height, width: cg.width, height: cg.height))
        return buf
    }

    func computeDiff() {
        guard let l = left, let r = right else { diff = nil; diffPixels = 0; return }
        let size = canvasSize
        let w = Int(size.width), h = Int(size.height), tol = Int(tolerance)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let a = Self.rgba(l, w: w, h: h), let b = Self.rgba(r, w: w, h: h) else { return }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            var count = 0
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])), abs(Int(a[i + 3]) - Int(b[i + 3])))
                if d > tol {
                    count += 1
                    out[i] = 255; out[i + 1] = 40; out[i + 2] = 70; out[i + 3] = 255
                } else {
                    let g = UInt8((Int(a[i]) * 3 + Int(a[i + 1]) * 6 + Int(a[i + 2])) / 10)
                    let v = UInt8(170 + Int(g) / 3)
                    out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = 255
                }
            }
            let provider = CGDataProvider(data: Data(out) as CFData)!
            let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let img = NSImage(cgImage: cg, size: NSSize(width: w, height: h))
            DispatchQueue.main.async {
                self?.diff = img; self?.diffPixels = count; self?.totalPixels = w * h
            }
        }
    }

    override func handle(_ cmd: AppCommand) -> Bool {
        switch cmd {
        case .reload: load()
        case .swap: Swift.swap(&leftURL, &rightURL); load()
        default: return false
        }
        return true
    }
}

struct ImageCompareView: View {
    @ObservedObject var s: ImageSession
    @State private var dragStart: CGSize? = nil
    @State private var zoomStart: CGFloat? = nil

    var body: some View {
        VStack(spacing: 0) {
            Toolbar {
                ToolButton(icon: "rectangle.split.2x1", label: "Side by Side", active: s.mode == .sideBySide) { s.mode = .sideBySide }
                ToolButton(icon: "square.on.square.intersection.dashed", label: "Difference", active: s.mode == .difference) { s.mode = .difference }
                ToolButton(icon: "circle.lefthalf.filled", label: "Blend", active: s.mode == .blend) { s.mode = .blend }
                ToolButton(icon: "rectangle.lefthalf.inset.filled.arrow.left", label: "Swipe", active: s.mode == .swipe) { s.mode = .swipe }
                ToolDivider()
                ToolButton(icon: "arrow.up.left.and.arrow.down.right", label: "Fit", active: s.zoom == nil) { withAnimation(.easeOut(duration: 0.2)) { s.zoom = nil; s.pan = .zero } }
                ToolButton(icon: "1.magnifyingglass", label: "100%", active: s.zoom == 1) { withAnimation(.easeOut(duration: 0.2)) { s.zoom = 1; s.pan = .zero } }
                ToolButton(icon: "plus.magnifyingglass", label: "Zoom In") { withAnimation(.easeOut(duration: 0.15)) { s.zoom = min(32, (s.zoom ?? 1) * 1.5) } }
                ToolButton(icon: "minus.magnifyingglass", label: "Zoom Out") { withAnimation(.easeOut(duration: 0.15)) { s.zoom = max(0.05, (s.zoom ?? 1) / 1.5) } }
                ToolDivider()
                ToolButton(icon: "arrow.left.arrow.right", label: "Swap") { _ = s.handle(.swap) }
                ToolButton(icon: "arrow.clockwise", label: "Reload") { s.load() }
                Spacer(minLength: 10)
                controls
            }
            HStack(spacing: 0) {
                side(0)
                side(1)
            }
            .padding(.vertical, 7)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.jGutter)
            GeometryReader { geo in
                content(geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .background(Checkerboard())
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { v in
                        if dragStart == nil { dragStart = s.pan }
                        s.pan = CGSize(width: (dragStart?.width ?? 0) + v.translation.width, height: (dragStart?.height ?? 0) + v.translation.height)
                    }.onEnded { _ in dragStart = nil })
                    .simultaneousGesture(MagnifyGesture().onChanged { v in
                        if zoomStart == nil { zoomStart = s.zoom ?? fitScale(geo.size) }
                        s.zoom = min(32, max(0.05, (zoomStart ?? 1) * v.magnification))
                    }.onEnded { _ in zoomStart = nil })
            }
            StatusBar {
                let a = s.pixelSize(s.left), b = s.pixelSize(s.right)
                if s.left != nil && s.right != nil {
                    if s.diffPixels == 0 && s.diff != nil { Label("Images are identical (within tolerance)", systemImage: "checkmark.seal.fill").foregroundStyle(Color.jAdded) }
                    else {
                        let pct = s.totalPixels > 0 ? Double(s.diffPixels) / Double(s.totalPixels) * 100 : 0
                        Text("\(s.diffPixels) differing pixels (\(String(format: "%.2f", pct))%)").fontWeight(.medium).foregroundStyle(.primary)
                    }
                    if a != b { Label("Sizes differ", systemImage: "exclamationmark.triangle").foregroundStyle(Color.jConflict) }
                } else { Text("Ready") }
                Spacer()
                Text("\(Int(a.width))×\(Int(a.height))  ↔  \(Int(b.width))×\(Int(b.height))").monospacedDigit()
                Text(s.zoom.map { "\(Int($0 * 100))%" } ?? "Fit")
            }
        }
    }

    @ViewBuilder var controls: some View {
        switch s.mode {
        case .difference:
            HStack(spacing: 6) { Text("Tolerance").font(.system(size: 11)).foregroundStyle(.secondary); Slider(value: $s.tolerance, in: 0...128).frame(width: 140); Text("\(Int(s.tolerance))").monospacedDigit().font(.system(size: 11)).frame(width: 28) }
        case .blend:
            HStack(spacing: 6) { Text("Left").font(.system(size: 11)); Slider(value: $s.blend, in: 0...1).frame(width: 160); Text("Right").font(.system(size: 11)) }
        case .swipe:
            HStack(spacing: 6) { Text("Swipe").font(.system(size: 11)); Slider(value: $s.swipe, in: 0...1).frame(width: 160) }
        case .sideBySide: EmptyView()
        }
    }

    func side(_ i: Int) -> some View {
        PathField(placeholder: i == 0 ? "Left image" : "Right image", url: i == 0 ? $s.leftURL : $s.rightURL) { s.setURL($0, side: i) }
            .padding(.horizontal, 10).frame(maxWidth: .infinity)
    }

    func fitScale(_ area: CGSize) -> CGFloat {
        let c = s.canvasSize
        let w = s.mode == .sideBySide ? area.width / 2 : area.width
        return min((w - 24) / c.width, (area.height - 24) / c.height, 4)
    }

    func scaled(_ img: NSImage?, scale: CGFloat) -> some View {
        let px = s.pixelSize(img)
        return Group {
            if let img {
                Image(nsImage: img).resizable().interpolation(scale > 2 ? .none : .high)
                    .frame(width: px.width * scale, height: px.height * scale)
            } else { Color.clear.frame(width: 1, height: 1) }
        }
        .frame(width: s.canvasSize.width * scale, height: s.canvasSize.height * scale, alignment: .topLeading)
    }

    @ViewBuilder func content(_ area: CGSize) -> some View {
        let scale = s.zoom ?? fitScale(area)
        switch s.mode {
        case .sideBySide:
            HStack(spacing: 0) {
                scaled(s.left, scale: scale).offset(s.pan).frame(width: area.width / 2, height: area.height).clipped()
                Rectangle().fill(Color.jSeparator).frame(width: 1)
                scaled(s.right, scale: scale).offset(s.pan).frame(width: area.width / 2 - 1, height: area.height).clipped()
            }
        case .difference:
            scaled(s.diff, scale: scale).offset(s.pan)
        case .blend:
            ZStack {
                scaled(s.left, scale: scale)
                scaled(s.right, scale: scale).opacity(s.blend)
            }.offset(s.pan)
        case .swipe:
            ZStack(alignment: .topLeading) {
                scaled(s.right, scale: scale)
                scaled(s.left, scale: scale)
                    .mask(alignment: .leading) { Rectangle().frame(width: s.canvasSize.width * scale * s.swipe) }
                Rectangle().fill(Color.accentColor).frame(width: 2, height: s.canvasSize.height * scale)
                    .offset(x: s.canvasSize.width * scale * s.swipe - 1)
            }.offset(s.pan)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let t: CGFloat = 10
            let light = Color(nsColor: .dynamic(light: .rgb(250, 250, 252), dark: .rgb(34, 34, 38)))
            let dark = Color(nsColor: .dynamic(light: .rgb(236, 236, 240), dark: .rgb(44, 44, 49)))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : t
                while x < size.width { ctx.fill(Path(CGRect(x: x, y: y, width: t, height: t)), with: .color(dark)); x += 2 * t }
                y += t; row += 1
            }
        }
    }
}
