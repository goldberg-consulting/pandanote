import SwiftUI
import AppKit
import PandanoteCore

@main struct PandanoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var workspace = Workspace()
    @AppStorage("appearance") private var appearance = "System"
    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceView(workspace: workspace)
                .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
                .tint(Color(red: 0.27, green: 0.47, blue: 0.36))
                .onAppear {
                    delegate.workspace = workspace
                    LauncherController.shared.workspace = workspace
                    LauncherController.shared.openWorkspace = { openWindow(id: "workspace") }
                    if let i = CommandLine.arguments.firstIndex(of: "--vault"), CommandLine.arguments.count > i + 1 { workspace.openVault(URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
                }
                .onOpenURL { url in
                    Task {
                        await workspace.openVaultAndWait(url.deletingLastPathComponent())
                        await workspace.selectAndWait(url)
                    }
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Search Applications and Notes…") { LauncherController.shared.show() }
                Divider()
                Button("New Note") { workspace.newNote() }.keyboardShortcut("n").disabled(workspace.root == nil)
                Button("New File…") { workspace.newFile() }.disabled(workspace.root == nil || workspace.fileOperationInProgress)
                Button("New Folder…") { workspace.newFolder() }.disabled(workspace.root == nil || workspace.fileOperationInProgress)
                Button("Daily Note") { workspace.newNote(kind: "Daily note") }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Vault…") { workspace.chooseVault() }.keyboardShortcut("o")
                Menu("Recent Vaults") { ForEach(workspace.recentVaults, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { workspace.openVault(URL(fileURLWithPath: path)) } } }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { Task { await workspace.save() } }.keyboardShortcut("s")
                Button("Export HTML…") { workspace.exportHTML() }
                Button("Reveal in Finder") { if let url = workspace.selected { workspace.revealInFinder(url) } }.disabled(workspace.selected == nil)
                Divider()
                Button("Rename…") { workspace.renameSelected() }.disabled(workspace.selected == nil || workspace.fileOperationInProgress || workspace.busy)
                Button("Duplicate") { if let url = workspace.selected { workspace.duplicate(url) } }.disabled(workspace.selected == nil || workspace.fileOperationInProgress)
                Button("Move to Folder…") { if let url = workspace.selected { workspace.move(url) } }.disabled(workspace.selected == nil || workspace.fileOperationInProgress || workspace.busy)
                Button("Move to Trash…") { if let url = workspace.selected { workspace.delete(url) } }.disabled(workspace.selected == nil || workspace.fileOperationInProgress || workspace.busy)
                Divider()
                Button("Close Note") { if let url = workspace.selected { workspace.closeTab(url) } }.keyboardShortcut("w").disabled(workspace.selected == nil || workspace.fileOperationInProgress)
                Button("Close All Notes") { workspace.closeAllTabs() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(workspace.tabs.isEmpty || workspace.fileOperationInProgress)
            }
            CommandGroup(after: .textEditing) {
                Menu("Find") {
                    Button("Find…") { workspace.openFind() }.keyboardShortcut("f")
                    Button("Find and Replace…") { workspace.openFind(replace: true) }.keyboardShortcut("f", modifiers: [.command, .option])
                    Button("Find in Vault…") { workspace.openFind(inVault: true) }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Replace in Vault…") { workspace.openFind(replace: true, inVault: true) }.keyboardShortcut("h", modifiers: [.command, .shift])
                    Divider()
                    Button("Find Next") { workspace.findReplace.nextMatch() }.keyboardShortcut("g")
                    Button("Find Previous") { workspace.findReplace.previousMatch() }.keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("Use Selection for Find") {
                        if AIPassageContext.isValid(range: workspace.selection, in: workspace.text) {
                            workspace.openFind(selectedText: (workspace.text as NSString).substring(with: workspace.selection))
                        }
                    }.keyboardShortcut("e", modifiers: [.command, .option])
                }.disabled(workspace.root == nil)
            }
            CommandMenu("Writing") {
                Button("Toggle Source / Reading") { workspace.mode = workspace.mode == .source ? .reading : .source }.keyboardShortcut("e")
                Button("Side by Side") { workspace.mode = .split }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Focus Mode") { workspace.showLibrary.toggle(); workspace.showInspector = !workspace.showLibrary ? false : true }.keyboardShortcut("f", modifiers: [.command, .option, .shift])
                Button("Ask AI about Selection") { workspace.assistant.captureSelection(workspace: workspace) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(workspace.selected == nil || !AIPassageContext.isValid(range: workspace.selection, in: workspace.text))
                Divider()
                Button("Build PDF") { workspace.perform("compile") }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(workspace.busy)
                Button("Run Code Blocks…") { workspace.perform("run") }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(workspace.busy)
                Button("Inspect Code Variables") { workspace.showVariables() }.disabled(workspace.selected == nil)
                Button("Set Up Inkwell Workspace") { workspace.perform("setup") }
                Button("Note History") { workspace.showHistory = true }
                Button("Document Settings…") { workspace.showDocumentSettings = true }.keyboardShortcut(",", modifiers: [.command, .option]).disabled(workspace.selected == nil)
                Button("Changes & Git…") { Task { if await workspace.save() { workspace.showChanges = true } } }.keyboardShortcut("g", modifiers: [.command, .option, .shift]).disabled(workspace.root == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { workspace.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Button("Writing Assistant") { workspace.inspector = .assistant; workspace.showInspector = true }.keyboardShortcut("j")
            }
        }
        Settings { PreferencesView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: Workspace?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); LauncherController.shared.registerShortcut() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.save()) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
