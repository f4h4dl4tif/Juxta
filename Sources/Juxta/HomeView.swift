import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var recents = Recents.shared
    @State private var query = ""
    @State private var dropTargeted = false

    let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(SessionKind.allCases) { k in SessionCard(kind: k) { app.open(k) } }
                    }
                    dropZone
                }
                .padding(28)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Color.jSeparator).frame(width: 1)
            recentPanel.frame(width: 320)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 1), Color(red: 0.62, green: 0.32, blue: 0.95)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .shadow(color: .purple.opacity(0.35), radius: 8, y: 3)
                Image(systemName: "rectangle.split.2x1.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Juxta").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Compare files, folders, tables, images and binaries — then merge and sync the differences.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 26, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop two files or folders here to compare them")
                .font(.system(size: 13, weight: .medium))
            Text("Three files open a merge. The best session type is picked automatically.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.jSeparator)
                .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Color.accentColor.opacity(0.06) : .clear))
        )
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { app.openAuto($0) }
            return true
        }
    }

    var filteredRecents: [RecentSession] {
        guard !query.isEmpty else { return recents.sessions }
        return recents.sessions.filter { r in r.paths.contains { $0.localizedCaseInsensitiveContains(query) } || r.kind.title.localizedCaseInsensitiveContains(query) }
    }

    var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recents.sessions.isEmpty {
                    Button("Clear") { recents.clear() }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $query).textFieldStyle(.plain)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 14).padding(.bottom, 8)
            if filteredRecents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text("Sessions you open appear here").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredRecents) { r in RecentRow(r: r) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
            }
        }
        .background(Color.jGutter)
    }
}

func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var urls: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u { lock.lock(); urls.append(u); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

struct SessionCard: View {
    let kind: SessionKind
    let action: () -> Void
    @State private var hover = false
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(kind.tint.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: kind.icon).font(.system(size: 19, weight: .medium)).foregroundStyle(kind.tint)
                }
                Text(kind.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(kind.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .modifier(CardSurface(hover: hover, tint: kind.tint, glass: prefs.glassTheme))
            .scaleEffect(hover ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hover)
    }
}

/// Plain: the original solid card. Glass: an interactive glass card.
struct CardSurface: ViewModifier {
    let hover: Bool
    let tint: Color
    let glass: Bool
    func body(content: Content) -> some View {
        if glass, #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? tint.opacity(0.5) : .clear))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(hover ? 0.12 : 0.05), radius: hover ? 10 : 3, y: hover ? 4 : 1)
                )
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hover ? tint.opacity(0.5) : Color.jSeparator))
        }
    }
}

struct RecentRow: View {
    @EnvironmentObject var app: AppModel
    let r: RecentSession
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.kind.icon).foregroundStyle(r.kind.tint).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.paths.map { $0.isEmpty ? "—" : ($0 as NSString).lastPathComponent }.joined(separator: "  ↔  "))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text((r.paths.first(where: { !$0.isEmpty }).map { (($0 as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }) ?? "")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Text("\(r.kind.title) · \(r.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if hover {
                Button { Recents.shared.remove(r) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.reopen(r) }
        .help(r.paths.joined(separator: "\n"))
    }
}
