import SwiftUI
import JuxtaCore

struct SettingsView: View {
    @ObservedObject var p = Prefs.shared

    var body: some View {
        TabView {
            Form {
                Picker("Font", selection: $p.fontName) {
                    ForEach(["SF Mono", "Menlo", "Monaco", "Courier New"], id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Slider(value: $p.fontSize, in: 9...24, step: 0.5) { Text("Size") }
                    Text(String(format: "%.1f pt", p.fontSize)).monospacedDigit().frame(width: 56)
                }
                Stepper("Tab width: \(p.tabWidth)", value: $p.tabWidth, in: 1...12)
                Toggle("Show line numbers", isOn: $p.showLineNumbers)
                Toggle("Show whitespace characters", isOn: $p.showWhitespace)
                Toggle("Show line details pane", isOn: $p.showDetailPane)
                Stepper("Context lines: \(p.contextLines)", value: $p.contextLines, in: 0...20)
                Toggle(isOn: $p.glassTheme) {
                    Text("Liquid Glass theme")
                    Text(GlassTheme.isSupported
                         ? "Use Liquid Glass for tabs, toolbars and cards. Compared text stays on solid panes."
                         : "Requires macOS 26.")
                }
                .disabled(!GlassTheme.isSupported)
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "textformat") }

            Form {
                Picker("Whitespace", selection: $p.defaultWhitespace) {
                    ForEach(WhitespaceRule.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("Ignore case", isOn: $p.defaultIgnoreCase)
                VStack(alignment: .leading) {
                    Text("Unimportant text patterns (regex, one per line)")
                    TextEditor(text: $p.ignorePatterns).font(.system(.body, design: .monospaced)).frame(height: 90)
                }
                Text("These defaults apply to new text compare sessions.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Text Rules", systemImage: "slider.horizontal.3") }

            Form {
                TextField("Excluded names", text: $p.folderExcludes)
                Text("Semicolon-separated wildcards, e.g. .git;*.o;build").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Folders", systemImage: "folder") }

            Form {
                Text("Open sessions from Terminal:").font(.headline)
                Text("open -a Juxta --args <left> <right> [<third>]").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Two folders open a folder compare, three files open a text merge, images open a picture compare, binaries open a hex compare.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("Command Line", systemImage: "terminal") }
        }
        .frame(width: 520, height: 400)
    }
}
