import SwiftUI

struct PreferencesView: View {
    @AppStorage("nodePath") var nodePath = ""
    @AppStorage("editorFontSize") var fontSize = 14.0
    @AppStorage("editorFont") var font = "SF Mono"
    @AppStorage("autosave") var autosave = true
    @AppStorage("appearance") var appearance = "System"
    @ObservedObject private var launcher = LauncherController.shared
    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                Picker("Editor font", selection: $font) { ForEach(["SF Mono", "Menlo", "Monaco", "Georgia"], id: \.self) { Text($0) } }
                Slider(value: $fontSize, in: 11...22, step: 1) { Text("Text size: \(Int(fontSize))") }
                Toggle("Save automatically", isOn: $autosave)
                Text("Notes are plain files. Previous versions are kept in the vault’s .pandanote folder.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).tabItem { Label("Writing", systemImage: "pencil.line") }
            Form {
                Text("Search from anywhere").font(.headline)
                Text("Command–Space opens a floating search for applications and notes in your current vault. Pandanote must be running; its main window can be closed.")
                Text("If Spotlight opens instead, turn off ‘Show Spotlight search’ in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, then retry below.").font(.caption)
                if let notice = launcher.shortcutNotice { Text(notice).foregroundStyle(.secondary) }
                Button("Retry Command–Space") { launcher.retryShortcut() }
                Button("Open Search") { launcher.show() }
            }.formStyle(.grouped).tabItem { Label("Search", systemImage: "magnifyingglass") }
            AISettingsView().tabItem { Label("AI", systemImage: "sparkles") }
            WritingTeamSettingsView().tabItem { Label("Writing team", systemImage: "person.3") }
            Form {
                Text("Powered by Inkwell").font(.headline)
                TextField("Custom Node executable (optional)", text: $nodePath)
                Text("Pandanote uses the same Inkwell compiler, runnable blocks, templates, bibliography resolver, and workspace format as your extension. Node runs the publishing tools; the app and editor are native Swift and AppKit.").font(.caption).foregroundStyle(.secondary)
                Link("Inkwell source and license", destination: URL(string: "https://github.com/goldberg-consulting/measured.one.inkwell-extension")!)
            }.formStyle(.grouped).tabItem { Label("Publishing", systemImage: "book.closed") }
        }.frame(width: 700, height: 640).padding(12)
    }
}
