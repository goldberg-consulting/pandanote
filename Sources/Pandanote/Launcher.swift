import AppKit
import SwiftUI
import Carbon

struct LauncherItem: Identifiable, Equatable {
    let url: URL
    let title: String
    let detail: String
    let isApplication: Bool
    var id: String { url.path }

    static func matching(_ items: [LauncherItem], query: String) -> [LauncherItem] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return Array(items.filter { item in
            let text = normalized(item.title + " " + item.detail)
            return words.allSatisfy { text.contains($0) }
        }.sorted { a, b in
            let query = words.joined(separator: " ")
            func rank(_ item: LauncherItem) -> Int {
                let title = normalized(item.title)
                if title == query { return 0 }
                if title.hasPrefix(query) { return 1 }
                return item.isApplication ? 2 : 3
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.prefix(40))
    }

    // Enumerate application folders directly so this works independently of Spotlight's index.
    static func applications(in roots: [URL]) -> [LauncherItem] {
        var found: [String: LauncherItem] = [:]
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries where url.pathExtension.lowercased() == "app" {
                entries.skipDescendants()
                let bundle = Bundle(url: url)
                let title = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let key = url.resolvingSymlinksInPath().path
                found[key] = LauncherItem(url: url, title: title, detail: url.deletingLastPathComponent().path, isApplication: true)
            }
        }
        return Array(found.values)
    }
}

@MainActor final class LauncherController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LauncherController()
    @Published var query = ""
    @Published var applications: [LauncherItem] = []
    @Published var selectedID: String?
    @Published var shortcutNotice: String?
    @Published var launchError: String?
    weak var workspace: Workspace?
    var openWorkspace: (() -> Void)?
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?
    private var fallbackKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var indexTask: Task<Void, Never>?
    private var keyMonitor: Any?

    func registerShortcut() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in LauncherController.shared.toggle() }
            return noErr
        }, 1, &event, nil, &handler)
        guard status == noErr else {
            shortcutNotice = "Global search shortcut could not be registered. Open Search from Pandanote’s File menu."
            return
        }
        let signature: OSType = 0x50414E44
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey), EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        let fallback = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &fallbackKey)
        if result != noErr {
            shortcutNotice = "Command–Space is in use. In System Settings → Keyboard → Keyboard Shortcuts → Spotlight, turn off ‘Show Spotlight search’, then click Retry." + (fallback == noErr ? " Use Option–Command–Space in the meantime." : " Open Search from Pandanote’s File menu in the meantime.")
        } else { shortcutNotice = nil }
    }

    func retryShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let fallbackKey { UnregisterEventHotKey(fallbackKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; fallbackKey = nil; handler = nil
        registerShortcut()
    }

    func toggle() {
        if panel?.isVisible == true { dismiss(); return }
        show()
    }

    func show() {
        query = ""; selectedID = nil; launchError = nil
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Pandanote Search"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isFloatingPanel = true
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: LauncherView(controller: self))
            panel = window
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                switch event.keyCode {
                case 53: self.dismiss(); return nil
                case 125, 126:
                    NotificationCenter.default.post(name: .launcherMove, object: event.keyCode == 125 ? 1 : -1)
                    return nil
                case 36, 76:
                    NotificationCenter.default.post(name: .launcherOpen, object: nil)
                    return nil
                default: return event
                }
            }
        }
        if let panel, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - frame.height * 0.15))
            panel.makeKeyAndOrderFront(nil)
        }
        indexTask?.cancel()
        indexTask = Task {
            let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"].map { URL(fileURLWithPath: $0) }
            let items = await Task.detached(priority: .userInitiated) { LauncherItem.applications(in: roots) }.value
            guard !Task.isCancelled else { return }
            applications = items
        }
    }

    func dismiss() { panel?.orderOut(nil) }
    func windowDidResignKey(_ notification: Notification) { dismiss() }

    func open(_ item: LauncherItem) {
        launchError = nil
        if item.isApplication {
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                Task { @MainActor in
                    if let error { self.launchError = error.localizedDescription }
                    else { self.dismiss() }
                }
            }
        } else if let workspace {
            dismiss()
            openWorkspace?()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0 !== panel && $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            Task { await workspace.selectAndWait(item.url) }
        }
    }
}

private struct LauncherView: View {
    @ObservedObject var controller: LauncherController
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                TextField("Search applications and notes", text: $controller.query)
                    .textFieldStyle(.plain).font(.title2).focused($searchFocused)
            }.padding(22)
            Divider()
            if let workspace = controller.workspace {
                LauncherResults(controller: controller, workspace: workspace)
            }
            if let notice = controller.shortcutNotice {
                HStack { Text(notice).font(.caption); Button("Retry") { controller.retryShortcut() } }.padding(12)
            }
            if let error = controller.launchError { Text(error).foregroundStyle(.red).padding(8) }
            HStack {
                Text("↑ ↓ to select · Return to open · Esc to dismiss")
                Spacer()
                Text("Pandanote")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 680, height: 510)
        .background(.regularMaterial)
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in searchFocused = true }
        .onExitCommand { controller.dismiss() }
    }
}

private struct LauncherResults: View {
    @ObservedObject var controller: LauncherController
    @ObservedObject var workspace: Workspace
    var results: [LauncherItem] {
        LauncherItem.matching(controller.applications + workspace.notes.map {
            LauncherItem(url: $0.url, title: $0.title, detail: $0.relativePath, isApplication: false)
        }, query: controller.query)
    }
    var body: some View {
        let items = results
        ScrollViewReader { proxy in
            List(selection: $controller.selectedID) {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).lineLimit(1)
                            Text(item.isApplication ? "Application · \(item.detail)" : item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.padding(.vertical, 4).contentShape(Rectangle())
                        .onTapGesture { controller.open(item) }.tag(item.id).id(item.id)
                }
            }.listStyle(.plain)
            .overlay { if items.isEmpty { Text("No applications or notes found").foregroundStyle(.secondary) } }
            .onChange(of: items, initial: true) { _, new in controller.selectedID = new.first?.id }
            .onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
            .onReceive(NotificationCenter.default.publisher(for: .launcherMove)) { notification in
                let delta = notification.object as? Int ?? 1
                let index = items.firstIndex { $0.id == controller.selectedID } ?? 0
                guard !items.isEmpty else { return }
                controller.selectedID = items[min(max(index + delta, 0), items.count - 1)].id
            }
            .onReceive(NotificationCenter.default.publisher(for: .launcherOpen)) { _ in
                if let item = items.first(where: { $0.id == controller.selectedID }) ?? items.first { controller.open(item) }
            }
        }
    }
}

private extension Notification.Name {
    static let launcherMove = Notification.Name("PandanoteLauncherMove")
    static let launcherOpen = Notification.Name("PandanoteLauncherOpen")
}
