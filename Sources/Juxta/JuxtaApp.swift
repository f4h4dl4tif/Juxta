import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        // Developer aid: JUXTA_SNAPSHOT=/path.png writes a picture of the main window after launch.
        if let path = ProcessInfo.processInfo.environment["JUXTA_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["JUXTA_SNAPSHOT_DELAY"] ?? "") ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView?.superview ?? w.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                if ProcessInfo.processInfo.environment["JUXTA_SNAPSHOT_QUIT"] != nil { exit(0) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for t in AppModel.shared.tabs { if let s = t.session, !s.confirmClose() { return .terminateCancel } }
        return .terminateNow
    }
}

@main
struct JuxtaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel.shared
    @StateObject private var prefs = Prefs.shared

    init() {
        // Paths on the command line are handled by AppModel, not as AppKit "open document" events
        // (which would suppress the main window).
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        Window("Juxta", id: "main") {
            MainView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { AppModel.shared.enqueueOpen($0) }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1380, height: 860)
        .commands { JuxtaCommands(app: app, prefs: prefs) }

        Settings {
            SettingsView()
        }
    }
}

struct JuxtaCommands: Commands {
    let app: AppModel
    let prefs: Prefs

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.newHomeTab() }.keyboardShortcut("t")
            Menu("New Session") {
                ForEach(SessionKind.allCases) { k in
                    Button(k.title) { app.open(k) }
                }
            }
            Divider()
            Button("Open Files to Compare…") { openPanel() }.keyboardShortcut("o")
            Divider()
            Button("Close Tab") { app.closeCurrent() }.keyboardShortcut("w")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { app.perform(.save) }.keyboardShortcut("s")
            Button("Reload") { app.perform(.reload) }.keyboardShortcut("r")
            Divider()
            Button("Export HTML Report…") { app.perform(.exportReport) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Patch…") { app.perform(.exportPatch) }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { app.perform(.undo) }.keyboardShortcut("z")
            Button("Redo") { app.perform(.redo) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { app.perform(.find) }.keyboardShortcut("f")
            Button("Find Next") { app.perform(.findNext) }.keyboardShortcut("g")
            Button("Find Previous") { app.perform(.findPrev) }.keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Go to Line…") { app.perform(.gotoLine) }.keyboardShortcut("l")
        }
        CommandMenu("Compare") {
            Button("Next Difference") { app.perform(.nextDiff) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Difference") { app.perform(.prevDiff) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("First Difference") { app.perform(.firstDiff) }.keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            Button("Last Difference") { app.perform(.lastDiff) }.keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            Divider()
            Button("Copy to Right") { app.perform(.copyToRight) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Copy to Left") { app.perform(.copyToLeft) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Swap Sides") { app.perform(.swap) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Show All") { app.perform(.showAll) }.keyboardShortcut("1", modifiers: [.command, .control])
            Button("Show Differences") { app.perform(.showDiffs) }.keyboardShortcut("2", modifiers: [.command, .control])
            Button("Show Same") { app.perform(.showSame) }.keyboardShortcut("3", modifiers: [.command, .control])
            Button("Show Context") { app.perform(.showContext) }.keyboardShortcut("4", modifiers: [.command, .control])
            Divider()
            Button("Expand All") { app.perform(.expandAll) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Collapse All") { app.perform(.collapseAll) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { prefs.fontSize = min(28, prefs.fontSize + 1) }.keyboardShortcut("+")
            Button("Smaller Text") { prefs.fontSize = max(8, prefs.fontSize - 1) }.keyboardShortcut("-")
            Button("Actual Size") { prefs.fontSize = 12.5 }.keyboardShortcut("0")
            Divider()
            Button("Next Tab") { app.selectTab(offset: 1) }.keyboardShortcut("}", modifiers: [.command, .shift])
            Button("Previous Tab") { app.selectTab(offset: -1) }.keyboardShortcut("{", modifiers: [.command, .shift])
            Divider()
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "Choose two files or folders (or three files for a merge)"
        if p.runModal() == .OK { app.openAuto(p.urls) }
    }
}

struct MainView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip()
            ZStack {
                ForEach(app.tabs) { tab in
                    TabContentView(tab: tab)
                        .opacity(tab.id == app.selected ? 1 : 0)
                        .allowsHitTesting(tab.id == app.selected)
                        .accessibilityHidden(tab.id != app.selected)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct TabContentView: View {
    let tab: Tab
    var body: some View {
        if let s = tab.session as? TextSession { TextCompareView(s: s) }
        else if let s = tab.session as? FolderSession { FolderCompareView(s: s) }
        else if let s = tab.session as? MergeSession { MergeView(s: s) }
        else if let s = tab.session as? TableSession { TableCompareView(s: s) }
        else if let s = tab.session as? HexSession { HexCompareView(s: s) }
        else if let s = tab.session as? ImageSession { ImageCompareView(s: s) }
        else { HomeView() }
    }
}

// MARK: - Tab strip

struct TabStrip: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 78)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(app.tabs) { tab in
                        TabItem(tab: tab, selected: tab.id == app.selected)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    Button { app.newHomeTab() } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New Tab (⌘T)")
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 40)
        .background(.bar)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jSeparator).frame(height: 1) }
    }
}

/// Lets empty tab-strip space drag the window like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with e: NSEvent) {
            if e.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: e) }
        }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TabItem: View {
    @EnvironmentObject var app: AppModel
    let tab: Tab
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            if let s = tab.session { SessionTabLabel(s: s) }
            else {
                Image(systemName: "house.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text("Home").font(.system(size: 12, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            Button { app.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hover ? 0.1 : 0)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hover || selected ? 1 : 0)
        }
        .padding(.leading, 11).padding(.trailing, 6)
        .frame(height: 28)
        .frame(minWidth: 120, maxWidth: 240)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color(nsColor: .controlBackgroundColor) : (hover ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1.5, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { app.selected = tab.id }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            Button("Close Tab") { app.close(tab.id) }
            Button("Close Other Tabs") { for t in app.tabs where t.id != tab.id { app.close(t.id) } }
        }
    }
}

struct SessionTabLabel: View {
    @ObservedObject var s: BaseSession
    @EnvironmentObject var app: AppModel
    var body: some View {
        Image(systemName: s.kind.icon).font(.system(size: 11)).foregroundStyle(s.kind.tint)
        Text(s.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        if s.isDirty { Circle().fill(Color.jChanged).frame(width: 6, height: 6) }
    }
}
