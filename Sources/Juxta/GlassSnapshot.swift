import AppKit
import SwiftUI

/// Developer aid: `--glass-snapshot=<dir>` (DEBUG builds only) opens the example sessions and captures
/// each screen with the Liquid Glass theme off and on, light and dark, then quits. Saved settings and
/// recents are restored afterwards.
@MainActor
enum GlassSnapshot {
    static func runIfRequested() {
        #if DEBUG
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--glass-snapshot=") }) else { return }
        run(String(arg.dropFirst("--glass-snapshot=".count)))
        #endif
    }

    #if DEBUG
    private typealias CapFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures a window as it is on screen (real Liquid Glass; cacheDisplay doesn't render glass).
    static func capture(_ window: NSWindow, to path: String) {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let f = unsafeBitCast(sym, to: CapFn.self)
        guard let img = f(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let keys = ["glassTheme", "recentSessions", "recentFiles", "recentDirs"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, d.object(forKey: $0)) })
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Examples").standardizedFileURL
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        // AppModel.open now swaps in a fresh Tab, so no refresh workaround is needed.
        func refreshTabs() {}
        func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Juxta" } }
        func shoot(_ name: String, window: () -> NSWindow?) async {
            for glass in [false, true] {
                Prefs.shared.glassTheme = glass
                for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    NSApp.activate(ignoringOtherApps: true)
                    await sleep(1.2)
                    if let w = window() { capture(w, to: "\(dir)/\(name)-\(glass ? "glass" : "plain")-\(mode).png") }
                }
            }
        }
        Task { @MainActor in
            await sleep(1.5)
            let app = AppModel.shared
            if let w = mainWindow() { w.setContentSize(NSSize(width: 1280, height: 800)); w.center() }
            await shoot("home", window: mainWindow)
            app.open(.text, urls: [examples.appendingPathComponent("left/server.swift"), examples.appendingPathComponent("right/server.swift")])
            refreshTabs()
            await sleep(1.5)
            await shoot("text", window: mainWindow)
            app.newHomeTab()
            app.open(.folder, urls: [examples.appendingPathComponent("left"), examples.appendingPathComponent("right")])
            refreshTabs()
            await sleep(2)
            await shoot("folder", window: mainWindow)
            app.newHomeTab()
            app.open(.merge, urls: [examples.appendingPathComponent("mine.txt"), examples.appendingPathComponent("base.txt"), examples.appendingPathComponent("theirs.txt")])
            refreshTabs()
            await sleep(1.5)
            await shoot("merge", window: mainWindow)
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            await sleep(1.5)
            await shoot("settings", window: { NSApp.windows.first { $0.isVisible && $0.title != "Juxta" && $0.frame.width > 200 } })
            for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            NSApp.appearance = nil
            exit(0)
        }
    }
    #endif
}
