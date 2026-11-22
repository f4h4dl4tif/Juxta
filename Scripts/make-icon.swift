import AppKit
// Renders the 1024px app icon: a gradient squircle with two offset "document" panes and diff bars.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 92
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.black.setFill(); squircle.fill()
ctx.restoreGState()
squircle.addClip()
let grad = NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.40, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.62, green: 0.30, blue: 0.95, alpha: 1)])!
grad.draw(in: rect, angle: -55)
func pane(_ r: CGRect, _ bars: [(CGFloat, NSColor, CGFloat)]) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: r, xRadius: 40, yRadius: 40).fill()
    ctx.restoreGState()
    var y = r.maxY - 92
    for (w, c, h) in bars {
        c.setFill()
        NSBezierPath(roundedRect: CGRect(x: r.minX + 46, y: y, width: (r.width - 92) * w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        y -= h + 30
    }
}
let gray = NSColor(white: 0.82, alpha: 1)
let red = NSColor(srgbRed: 0.96, green: 0.36, blue: 0.42, alpha: 1)
let violet = NSColor(srgbRed: 0.55, green: 0.42, blue: 0.95, alpha: 1)
pane(CGRect(x: 205, y: 250, width: 300, height: 520), [(0.8, gray, 34), (0.6, gray, 34), (0.9, red, 34), (0.5, gray, 34), (0.7, gray, 34), (0.4, gray, 34)])
pane(CGRect(x: 519, y: 250, width: 300, height: 520), [(0.8, gray, 34), (0.6, gray, 34), (0.75, red, 34), (0.65, violet, 34), (0.5, gray, 34), (0.7, gray, 34)])
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
