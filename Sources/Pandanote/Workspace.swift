import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import PandanoteCore

enum EditorMode: String, CaseIterable { case source = "Source", split = "Side by side", reading = "Reading" }
enum InspectorTab: String, CaseIterable { case outline = "Outline", inkwell = "Inkwell", variables = "Variables", assistant = "Assistant" }

@MainActor final class Workspace: ObservableObject {
    @Published var root: URL?
    @Published var notes: [NoteFile] = []
    @Published var selected: URL?
    @Published var tabs: [URL] = []
    @Published var text = ""
    @Published var query = ""
    @Published var filter = "All notes"
    @Published var mode: EditorMode = .split
    @Published var inspector: InspectorTab = .outline
    @Published var showInspector = true
    @Published var showLibrary = true
    @Published var showFindReplace = false
    @Published var previewHTML = ""
    @Published var pdfURL: URL?
    @Published var pdfDocument: PDFDocument?
    @Published var buildActivity: String?
    @Published var buildNotice: String?
    @Published var logURL: URL?
    @Published var showPDF = false
    @Published var log = "Build a PDF or run code to see Inkwell’s output here."
    @Published var showLog = false
    @Published var status = "Ready"
    @Published var busy = false
    @Published var fileOperationInProgress = false
    @Published private(set) var directoryPaths: [String] = []
    @Published var error: String?
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var jump: Int?
    @Published var editorInsertion: String?
    @Published var favorites: Set<String> = []
    @Published var pinned: Set<String> = []
    @Published var templates: [[String: String]] = []
    @Published var references: [[String: Any]] = []
    @Published var tools: [[String: Any]] = []
    @Published private(set) var variableBlocks: [CodeVariableBlock] = []
    @Published private(set) var variablesChecking = false
    @Published private(set) var variablesError: String?
    private var variablesFile: URL?
    private var variablesSource: String?
    var variablesMatchDocument: Bool { variablesFile == selected && variablesSource == text && !variablesChecking }
    @Published var recentVaults: [String] = []
    @Published var showHistory = false
    @Published var conflict = false
    @Published var dirty = false
    @Published var showDocumentSettings = false
    @Published var showChanges = false
    @Published var reviewProposal: ChangeProposal?
    @Published var publicationSummary = "Inkwell defaults"
    @Published var pdfSource: String?
    let assistant = WritingAssistant()
    let findReplace = FindReplaceController()
    var pendingReplacement: (file: URL, before: String, after: String, label: String)?
    private var diskText = ""
    private var saveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var diskSaveTask: Task<Bool, Never>?
    private var documentSession = UUID()
    private var contentRevision = 0
    private var generation = 0
    private var shouldSelectInitialNote = false
    private var engine: EngineClient
    private let writeDocument: @Sendable (URL, URL, String, String) throws -> Void
    private let scanVault: @Sendable (Vault) throws -> ([NoteFile], [String])
    private var lastPublication: (root: URL, file: URL, source: String, url: URL, document: PDFDocument)?
    var hasBuiltPDF: Bool { lastPublication != nil }
    var vault: Vault? { root.map(Vault.init) }
    var title: String { selected?.deletingPathExtension().lastPathComponent ?? "Pandanote" }
    var words: Int { MarkdownInfo.words(text) }
    var outline: [Heading] { MarkdownInfo.headings(text) }
    var relativePath: String { guard let root, let selected else { return "" }; return String(selected.path.dropFirst(root.path.count + 1)) }
    var filteredNotes: [NoteFile] {
        notes.filter { note in
            let filterMatches = filter == "All notes" || (filter == "Favorites" && favorites.contains(note.id)) || (filter == "Tasks" && note.text.contains("- [")) || (filter.hasPrefix("#") && note.tags.contains(String(filter.dropFirst()))) || (filter.hasPrefix("folder:") && note.folder == String(filter.dropFirst(7)))
            return filterMatches && (query.isEmpty || (note.title + "\n" + note.text).localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if pinned.contains(a.id) != pinned.contains(b.id) { return pinned.contains(a.id) }
            return a.modified > b.modified
        }
    }
    var allTags: [String] { Array(Set(notes.flatMap(\.tags))).sorted() }
    var folders: [String] { Array(Set(directoryPaths + notes.map(\.folder).filter { !$0.isEmpty })).sorted() }
    init(restoreVault: Bool = true, engine: EngineClient? = nil,
         writeDocument: @escaping @Sendable (URL, URL, String, String) throws -> Void = { root, file, text, expected in
             try Vault(root: root).save(text, to: file, expected: expected)
         }, scanVault: @escaping @Sendable (Vault) throws -> ([NoteFile], [String]) = { vault in
             (try vault.scan(), try vault.directories())
         }) {
        self.writeDocument = writeDocument
        self.scanVault = scanVault
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Engine/out/pandanote-engine.cjs")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Engine/runtime/out/pandanote-engine.cjs")
        self.engine = engine ?? EngineClient(script: bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development)
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        pinned = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
        recentVaults = UserDefaults.standard.stringArray(forKey: "recentVaults") ?? []
        findReplace.workspace = self
        if restoreVault, !CommandLine.arguments.contains("--vault"), let last = UserDefaults.standard.string(forKey: "lastVault"), FileManager.default.fileExists(atPath: last) { openVault(URL(fileURLWithPath: last)) }
    }
    func chooseVault() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Open vault"
        if panel.runModal() == .OK, let url = panel.url { openVault(url) }
    }
    func openVault(_ url: URL) { Task { await openVaultAndWait(url) } }
    func openVaultAndWait(_ url: URL) async {
        guard !fileOperationInProgress else { return }
        guard let resolved = try? await BackgroundWork.run({ url.standardizedFileURL.resolvingSymlinksInPath() }) else { return }
        guard await save(), !fileOperationInProgress else { return }
        refreshTask?.cancel(); refreshTask = nil; refreshID = UUID()
        saveTask?.cancel(); previewTask?.cancel(); generation += 1
        documentSession = UUID(); contentRevision += 1
        assistant.resetForVault()
        root = resolved; selected = nil; notes = []; text = ""; diskText = ""; tabs = []; dirty = false; conflict = false
        clearCodeVariables()
        directoryPaths = []; shouldSelectInitialNote = true
        query = ""; filter = "All notes"; pdfURL = nil; pdfDocument = nil; previewHTML = ""
        reviewProposal = nil; pdfSource = nil; pendingReplacement = nil
        findReplace.resetForVault()
        UserDefaults.standard.set(root!.path, forKey: "lastVault")
        recentVaults.removeAll { $0 == root!.path }; recentVaults.insert(root!.path, at: 0); recentVaults = Array(recentVaults.prefix(8))
        UserDefaults.standard.set(recentVaults, forKey: "recentVaults")
        refresh()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.refresh()
            }
        }
        Task { await loadEngineInfo() }
    }
    func refresh() {
        guard let root, refreshTask == nil, !fileOperationInProgress else { return }
        let revision = contentRevision
        let id = UUID(), scanner = scanVault
        refreshID = id
        refreshTask = Task { [weak self] in
            defer { if self?.refreshID == id { self?.refreshTask = nil } }
            do {
                let (scanned, directories) = try await BackgroundWork.run {
                    try scanner(Vault(root: root))
                }
                guard !Task.isCancelled, let self, self.root == root, refreshID == id, revision == contentRevision, diskSaveTask == nil, !fileOperationInProgress else { return }
                if notes != scanned { notes = scanned }
                if directoryPaths != directories { directoryPaths = directories }
                if let selected, let note = scanned.first(where: { $0.url == selected }) {
                    if note.text != diskText {
                        if dirty { conflict = true; status = "Changed in another app" }
                        else { text = note.text; diskText = note.text; contentRevision += 1; schedulePreview(); findReplace.documentDidChange() }
                    }
                } else if selected == nil, shouldSelectInitialNote, let first = scanned.first { await selectAndWait(first.url) }
            } catch { if !Task.isCancelled, self?.root == root, self?.refreshID == id { self?.error = error.localizedDescription } }
        }
    }
    func select(_ url: URL) { Task { await selectAndWait(url) } }
    func selectAndWait(_ url: URL, duringFileOperation: Bool = false) async {
        guard !fileOperationInProgress || duringFileOperation, url != selected, let root else { return }
        let session = documentSession
        guard await save(), documentSession == session, self.root == root, !fileOperationInProgress || duringFileOperation else { return }
        let revision = contentRevision
        do {
            let contents = try await BackgroundWork.run { try Vault(root: root).read(url) }
            // Typing or another navigation while the provider reads must not be lost.
            guard documentSession == session, contentRevision == revision, self.root == root, !fileOperationInProgress || duringFileOperation else { return }
            saveTask?.cancel(); previewTask?.cancel(); generation += 1
            documentSession = UUID(); contentRevision += 1
            selected = url; text = contents; diskText = contents; dirty = false; conflict = false; selection = NSRange(location: 0, length: 0)
            clearCodeVariables()
            shouldSelectInitialNote = false
            if !tabs.contains(url) { tabs.append(url) }
            pdfURL = nil; pdfDocument = nil; pdfSource = nil; showPDF = false; status = "Saved to disk"
            schedulePreview()
            findReplace.documentDidChange()
        } catch { self.error = error.localizedDescription }
    }
    func edit(_ value: String) {
        contentRevision += 1
        text = value; dirty = text != diskText; status = dirty ? "Editing…" : "Saved to disk"
        saveTask?.cancel()
        if UserDefaults.standard.object(forKey: "autosave") as? Bool ?? true {
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                _ = await self?.save()
            }
        }
        schedulePreview()
        findReplace.documentDidChange()
    }
    func openFind(replace: Bool = false, selectedText: String? = nil, inVault: Bool = false) {
        findReplace.open(replace: replace, selectedText: selectedText, inVault: inVault)
    }
    func applySearchChanges(_ changes: [ReplacementFileChange], in expectedRoot: URL, undo: Bool = false) async -> ReplacementBatchResult {
        func failure(_ message: String) -> ReplacementBatchResult { .init(applied: [], backupURL: nil, failure: message) }
        guard !fileOperationInProgress, !busy, let root, root.standardizedFileURL.path == expectedRoot.standardizedFileURL.path else {
            return failure("Wait for the current file operation or publishing task to finish, and use the vault where the preview was made.")
        }
        fileOperationInProgress = true
        defer { fileOperationInProgress = false; refresh() }
        guard await save(), self.root == root else { return failure(error ?? "Save the current note before replacing.") }
        if let selected, let change = changes.first(where: { root.appendingPathComponent($0.relativePath).standardizedFileURL.path == selected.standardizedFileURL.path }) {
            let expected = undo ? change.after : change.before
            guard text == expected || (undo && text == change.before) else {
                return failure("The open note changed since the preview. Search again before replacing.")
            }
        }
        do {
            let result = try await BackgroundWork.run {
                let vault = Vault(root: root)
                return try undo ? ReplacementBatch.undo(changes, in: vault) : ReplacementBatch.apply(changes, in: vault)
            }
            if let selected, let change = result.applied.first(where: { root.appendingPathComponent($0.relativePath).standardizedFileURL.path == selected.standardizedFileURL.path }) {
                let label = undo ? "Undo replacement batch" : "Find and replace"
                pendingReplacement = (selected, text, change.after, label)
                diskText = change.after; edit(change.after); saveTask?.cancel()
                reviewProposal = nil; status = undo ? "Replacement undone" : "Replacements saved"
            }
            contentRevision += 1
            // Update known cards without holding the editor lock during a vault scan.
            notes = notes.map { note in
                guard let change = result.applied.first(where: { $0.relativePath == note.relativePath }) else { return note }
                return NoteFile(url: note.url, relativePath: note.relativePath, modified: Date(), text: change.after)
            }
            return result
        } catch { return failure(error.localizedDescription) }
    }
    func engineRequest(_ action: String, text: String, root: URL?, file: URL?, parameters: [String: Any] = [:]) async throws -> Data {
        guard let root else { throw EngineFailure.failed("Open a vault first.") }
        return try await engine.call(action: action, root: root, file: file, text: text, nodePath: UserDefaults.standard.string(forKey: "nodePath") ?? "", parameters: parameters)
    }
    @discardableResult func applyDocumentChange(_ replacement: String, base: String, file: URL?, label: String, duringFileOperation: Bool = false) async -> Bool {
        guard !fileOperationInProgress || duringFileOperation else { return false }
        guard let selected, file == selected else { error = ChangeError.wrongDocument.localizedDescription; return false }
        guard text == base else { error = ChangeError.stale.localizedDescription; return false }
        guard await save(), file == self.selected, text == base, let vault else { return false }
        do {
            // The disk comparison is repeated inside the coordinated write.
            try vault.save(replacement, to: selected, expected: base)
            pendingReplacement = (selected, base, replacement, label)
            diskText = replacement; edit(replacement); status = "\(label) saved"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func acceptProposal(_ proposal: ChangeProposal) async -> Bool {
        do {
            let replacement = try proposal.applying(to: text, relativePath: relativePath)
            guard let vault else { return false }
            // Save the edited proposal before touching the note, so it is recoverable.
            try ChangeArchive(vault: vault).store(proposal)
            guard await applyDocumentChange(replacement, base: proposal.base, file: vault.root.appendingPathComponent(proposal.relativePath), label: "AI revision") else { return false }
            var accepted = proposal; accepted.decision = "accepted"
            do { try ChangeArchive(vault: vault).store(accepted) }
            catch { self.error = "The revision was saved, but its review record could not be marked accepted: \(error.localizedDescription)" }
            reviewProposal = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func rejectProposal(_ proposal: ChangeProposal) {
        do {
            guard let vault else { return }
            var rejected = proposal; rejected.decision = "rejected"
            try ChangeArchive(vault: vault).store(rejected); reviewProposal = nil
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func save() async -> Bool {
        let session = documentSession
        // Autosave, Build, navigation and explicit Save share one write. Edits made
        // during that write are saved next against the newly confirmed disk text.
        while dirty || diskSaveTask != nil {
            guard documentSession == session else { return false }
            if let pending = diskSaveTask {
                guard await pending.value else { return false }
                continue
            }
            guard let selected, let root else { return true }
            let snapshot = text, expected = diskText, writer = writeDocument
            let pending = Task { [self] () -> Bool in
                defer { diskSaveTask = nil }
                do {
                    try await BackgroundWork.run { try writer(root, selected, snapshot, expected) }
                    guard documentSession == session else { return false }
                    diskText = snapshot; dirty = text != snapshot; conflict = false; contentRevision += 1
                    status = dirty ? "Editing…" : "Saved to disk"
                    return true
                } catch {
                    self.error = error.localizedDescription; conflict = true; status = "Save needs attention"
                    return false
                }
            }
            diskSaveTask = pending
            guard await pending.value else { return false }
        }
        return documentSession == session
    }
    func reload() { Task { await reloadAndWait() } }
    private func reloadAndWait() async {
        if let pending = diskSaveTask { _ = await pending.value }
        guard let selected, let vault else { return }
        do { saveTask?.cancel(); text = try vault.read(selected); diskText = text; contentRevision += 1; dirty = false; conflict = false; schedulePreview(); findReplace.documentDidChange() }
        catch { self.error = error.localizedDescription }
    }
    func saveCopy() { Task { await saveCopyAndWait() } }
    private func saveCopyAndWait() async {
        if let pending = diskSaveTask { _ = await pending.value }
        guard let vault else { return }
        do { let url = try vault.create(name: title + " — recovered", text: text); dirty = false; conflict = false; contentRevision += 1; await selectAndWait(url); refresh() }
        catch { self.error = error.localizedDescription }
    }
    /// A file operation owns the current vault until its disk and UI changes agree.
    /// Navigation waits; saves still use the existing coordinated write path.
    private func withFileOperation(_ operation: (Vault) async throws -> Void) async {
        guard !fileOperationInProgress, let capturedRoot = root, let vault else { return }
        fileOperationInProgress = true
        var released = false
        defer { if !released { fileOperationInProgress = false }; refresh() }
        guard await save(), root == capturedRoot else { return }
        saveTask?.cancel(); previewTask?.cancel(); generation += 1
        do {
            try await operation(vault)
            contentRevision += 1
            findReplace.documentDidChange()
            let revision = contentRevision, scanner = scanVault
            // Provider enumeration can be slow independently of the mutation.
            // Release this operation's lock before scanning so typing/navigation
            // can resume, without letting this task unlock a newer operation.
            fileOperationInProgress = false; released = true
            schedulePreview()
            let (scanned, directories) = try await BackgroundWork.run { try scanner(vault) }
            if root == capturedRoot, contentRevision == revision, !fileOperationInProgress {
                notes = scanned; directoryPaths = directories
            }
        } catch {
            if root == capturedRoot { self.error = error.localizedDescription }
            schedulePreview()
        }
    }
    private func relativeDirectory(_ directory: URL?, vault: Vault) throws -> String {
        let directory = (directory ?? vault.root).standardizedFileURL
        if directory == vault.root { return "" }
        guard vault.contains(directory) else { throw VaultError.outsideVault }
        return String(directory.path.dropFirst(vault.root.path.count + 1))
    }
    private var creationDirectory: URL? {
        guard let root else { return nil }
        return filter.hasPrefix("folder:") ? root.appendingPathComponent(String(filter.dropFirst(7)), isDirectory: true) : root
    }
    private func promptForName(_ title: String, initial: String, action: String, message: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: action); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func newNote(kind: String = "Note", in directory: URL? = nil) {
        let targetDirectory = directory ?? creationDirectory
        Task { await newNoteAndWait(kind: kind, in: targetDirectory) }
    }
    func newNoteAndWait(kind: String = "Note", in directory: URL? = nil) async {
        await withFileOperation { vault in
            let name = kind == "Daily note" ? Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) : "Untitled"
            let content = kind == "Research paper" ? "---\ntitle: Untitled research\nauthor: \ntemplate: default\n---\n\n# Introduction\n\n# Methods\n\n# Results\n\n# References\n" : "# \(name)\n\n"
            let folder = kind == "Daily note" ? "Journal" : try relativeDirectory(directory ?? creationDirectory, vault: vault)
            let file = try await BackgroundWork.run { try vault.create(name: name, folder: folder, text: content) }
            query = ""; filter = folder.isEmpty ? "All notes" : "folder:" + folder
            await selectAndWait(file, duringFileOperation: true)
            if kind == "Research paper", selected == file { showDocumentSettings = true }
        }
    }
    func newFile(in directory: URL? = nil) {
        guard !fileOperationInProgress,
              let name = promptForName("New file", initial: "Untitled.md", action: "Create", message: "Choose a Markdown (.md), text (.txt), LaTeX (.tex), or bibliography (.bib) filename.") else { return }
        let targetDirectory = directory ?? creationDirectory
        Task { await createFileAndWait(name: name, in: targetDirectory) }
    }
    func createFileAndWait(name: String, in directory: URL? = nil) async {
        await withFileOperation { vault in
            let folder = try relativeDirectory(directory ?? creationDirectory, vault: vault)
            let file = try await BackgroundWork.run { try vault.createFile(name: name, folder: folder) }
            query = ""; filter = folder.isEmpty ? "All notes" : "folder:" + folder
            await selectAndWait(file, duringFileOperation: true)
        }
    }
    func newFolder(in directory: URL? = nil) {
        guard !fileOperationInProgress,
              let name = promptForName("New folder", initial: "Untitled folder", action: "Create") else { return }
        let targetDirectory = directory ?? creationDirectory
        Task { await createFolderAndWait(name: name, in: targetDirectory) }
    }
    func createFolderAndWait(name: String, in directory: URL? = nil) async {
        await withFileOperation { vault in
            let parent = try relativeDirectory(directory ?? creationDirectory, vault: vault)
            let folder = try await BackgroundWork.run { try vault.createFolder(name: name, folder: parent) }
            query = ""; filter = "folder:" + (try relativeDirectory(folder, vault: vault))
            status = "Folder created"
        }
    }
    func renameSelected() { if let selected { rename(selected) } }
    func rename(_ url: URL) {
        guard !fileOperationInProgress,
              let name = promptForName("Rename \(url.lastPathComponent)", initial: url.lastPathComponent, action: "Rename", message: "Links that refer to the old path are not updated automatically.") else { return }
        Task { await renameAndWait(url, to: name) }
    }
    func renameAndWait(_ url: URL, to name: String) async {
        guard !busy else { error = "Wait for publishing to finish before renaming files."; return }
        await withFileOperation { vault in
            let target = try await BackgroundWork.run { try vault.rename(url, to: name) }
            remapItem(from: url, to: target)
            status = "Renamed to \(target.lastPathComponent)"
        }
    }
    func duplicate(_ url: URL) { Task { await duplicateAndWait(url) } }
    func duplicateAndWait(_ url: URL) async {
        await withFileOperation { vault in
            let target = try await BackgroundWork.run { try vault.duplicate(url) }
            let isDirectory = try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if isDirectory {
                query = ""; filter = "folder:" + (try relativeDirectory(target, vault: vault))
            } else {
                query = ""; filter = "All notes"
                await selectAndWait(target, duringFileOperation: true)
            }
            status = "Duplicated \(url.lastPathComponent)"
        }
    }
    func move(_ url: URL) {
        guard !fileOperationInProgress, let root else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Move Here"; panel.message = "Choose a folder inside \(root.lastPathComponent). Links and relative attachment paths are not updated automatically."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await moveAndWait(url, to: destination) }
    }
    func moveAndWait(_ url: URL, to directory: URL) async {
        guard !busy else { error = "Wait for publishing to finish before moving files."; return }
        await withFileOperation { vault in
            let folder = try relativeDirectory(directory, vault: vault)
            let target = try await BackgroundWork.run { try vault.move(url, toFolder: folder) }
            remapItem(from: url, to: target)
            status = "Moved \(target.lastPathComponent)"
        }
    }
    private func isItem(_ candidate: URL, within item: URL) -> Bool {
        candidate.standardizedFileURL.path == item.standardizedFileURL.path || candidate.standardizedFileURL.path.hasPrefix(item.standardizedFileURL.path + "/")
    }
    private func remapItem(from old: URL, to new: URL) {
        func mapped(_ url: URL) -> URL {
            guard isItem(url, within: old) else { return url }
            let suffix = String(url.path.dropFirst(old.path.count))
            return URL(fileURLWithPath: new.path + suffix)
        }
        tabs = tabs.map(mapped)
        favorites = Set(favorites.map { mapped(URL(fileURLWithPath: $0)).path })
        pinned = Set(pinned.map { mapped(URL(fileURLWithPath: $0)).path })
        persistBookmarks()
        if let selected, isItem(selected, within: old) {
            self.selected = mapped(selected); documentSession = UUID(); contentRevision += 1
            pendingReplacement = nil; reviewProposal = nil
            pdfURL = nil; pdfDocument = nil; pdfSource = nil; showPDF = false
        }
        if let publication = lastPublication, isItem(publication.file, within: old) { lastPublication = nil }
        if let root, filter.hasPrefix("folder:") {
            let filteredDirectory = root.appendingPathComponent(String(filter.dropFirst(7)))
            if isItem(filteredDirectory, within: old) {
                filter = "folder:" + String(mapped(filteredDirectory).path.dropFirst(root.path.count + 1))
            }
        }
    }
    func delete(_ url: URL) {
        guard !fileOperationInProgress else { return }
        let alert = NSAlert(); alert.messageText = "Move “\(url.lastPathComponent)” to Trash?"
        alert.informativeText = "Folders include all their contents. You can restore this item from the Finder’s Trash."
        alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await deleteAndWait(url) }
    }
    func deleteAndWait(_ url: URL) async {
        guard !busy else { error = "Wait for publishing to finish before deleting files."; return }
        await withFileOperation { vault in
            try await BackgroundWork.run { try vault.trash(url) }
            tabs.removeAll { isItem($0, within: url) }
            favorites = favorites.filter { !isItem(URL(fileURLWithPath: $0), within: url) }
            pinned = pinned.filter { !isItem(URL(fileURLWithPath: $0), within: url) }
            persistBookmarks()
            if let selected, isItem(selected, within: url) {
                clearDocument()
                if let next = tabs.last { await selectAndWait(next, duringFileOperation: true) }
            }
            if let publication = lastPublication, isItem(publication.file, within: url) { lastPublication = nil }
            if filter.hasPrefix("folder:"), isItem(vault.root.appendingPathComponent(String(filter.dropFirst(7))), within: url) { filter = "All notes" }
            status = "Moved to Trash"
        }
    }
    private func persistBookmarks() {
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
    }
    func toggleFavorite(_ url: URL) { if !favorites.insert(url.path).inserted { favorites.remove(url.path) }; persistBookmarks() }
    func togglePin(_ url: URL) { if !pinned.insert(url.path).inserted { pinned.remove(url.path) }; persistBookmarks() }
    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func copyPath(_ url: URL, relative: Bool = false) {
        let value: String
        if relative, let root, url == root { value = "." }
        else if relative, let vault, vault.contains(url) { value = String(url.path.dropFirst(vault.root.path.count + 1)) }
        else { value = url.path }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    private func clearDocument() {
        saveTask?.cancel(); previewTask?.cancel(); generation += 1
        selected = nil; text = ""; diskText = ""; previewHTML = ""; dirty = false; conflict = false
        clearCodeVariables()
        pdfURL = nil; pdfDocument = nil; pdfSource = nil; showPDF = false
        pendingReplacement = nil; reviewProposal = nil; editorInsertion = nil; jump = nil
        selection = NSRange(location: 0, length: 0)
        documentSession = UUID(); contentRevision += 1; shouldSelectInitialNote = false
        findReplace.documentDidChange()
    }
    func closeTab(_ url: URL) { Task { await closeTabsAndWait([url]) } }
    func closeOtherTabs(_ url: URL) { let closing = tabs.filter { $0 != url }; Task { await closeTabsAndWait(closing) } }
    func closeTabsToRight(of url: URL) {
        guard let index = tabs.firstIndex(of: url) else { return }
        let closing = Array(tabs.dropFirst(index + 1)); Task { await closeTabsAndWait(closing) }
    }
    func closeAllTabs() { let closing = tabs; Task { await closeTabsAndWait(closing) } }
    func closeTabsAndWait(_ closing: [URL]) async {
        guard !fileOperationInProgress else { return }
        let session = documentSession
        guard await save(), !fileOperationInProgress, documentSession == session else { return }
        tabs.removeAll { closing.contains($0) }
        if let selected, closing.contains(selected) {
            clearDocument()
            if let next = tabs.last { await selectAndWait(next) }
        }
    }
    func extractSelectionToNote() {
        guard !fileOperationInProgress, let selected,
              AIPassageContext.isValid(range: selection, in: text) else { return }
        let source = text, range = selection
        guard let name = promptForName("Extract selection to new note", initial: "Extracted note", action: "Extract", message: "The selected passage becomes a sibling note, and a note link takes its place. Undo restores the passage and keeps the new note.") else { return }
        Task { await extractSelectionAndWait(name: name, source: source, range: range, file: selected) }
    }
    func extractSelectionAndWait(name: String, source: String, range: NSRange, file: URL) async {
        await withFileOperation { vault in
            guard selected == file, text == source, AIPassageContext.isValid(range: range, in: source) else { throw ChangeError.stale }
            let passage = (source as NSString).substring(with: range)
            let folder = try relativeDirectory(file.deletingLastPathComponent(), vault: vault)
            let created = try await BackgroundWork.run { try vault.create(name: name, folder: folder, text: passage) }
            // Keep the new note even if the original changed externally. No passage is lost.
            let target = String(created.path.dropFirst(vault.root.path.count + 1))
            let label = created.deletingPathExtension().lastPathComponent
            let link: String
            if target.contains(where: { "[]|".contains($0) }) {
                // Wiki delimiters are legal filename characters. A Markdown link
                // to the same note route keeps these paths unambiguous.
                let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
                let escaped = label.reduce("") { $0 + ("\\[]*_`".contains($1) ? "\\" : "") + String($1) }
                link = "[\(escaped)](pandanote-note:\(encoded))"
            } else { link = "[[\(target)|\(label)]]" }
            let replacement = (source as NSString).replacingCharacters(in: range, with: link)
            guard await applyDocumentChange(replacement, base: source, file: file, label: "Extract selection to note", duringFileOperation: true) else {
                error = "The new note was created at \(created.lastPathComponent), but the original passage was kept because its document changed."
                return
            }
            status = "Extracted to \(created.lastPathComponent)"
        }
    }
    func schedulePreview() {
        previewTask?.cancel(); generation += 1
        let capturedGeneration = generation
        guard let root, let selected else { return }
        let snapshot = text
        variablesChecking = true; variablesError = nil
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            do {
                let data = try await engine.call(action: "preview", root: root, file: selected, text: snapshot, nodePath: UserDefaults.standard.string(forKey: "nodePath") ?? "")
                let result = try await BackgroundWork.run { try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
                let blocks = try await BackgroundWork.run { try CodeVariableBlock.decodeResponse(data) }
                guard !Task.isCancelled, capturedGeneration == generation else { return }
                variableBlocks = blocks; variablesFile = selected; variablesSource = snapshot; variablesChecking = false
                if let html = result["html"] as? String { previewHTML = html; publicationSummary = "\(result["template"] as? String ?? "Inkwell") · \(result["engine"] as? String ?? "")" }
                else { status = result["message"] as? String ?? "Preview unavailable"; variablesError = status }
            } catch {
                if !Task.isCancelled, capturedGeneration == generation {
                    status = error.localizedDescription; variablesError = error.localizedDescription; variablesChecking = false
                }
            }
        }
    }
    private func clearCodeVariables() {
        variableBlocks = []; variablesFile = nil; variablesSource = nil
        variablesChecking = false; variablesError = nil
    }
    func showVariables() {
        findReplace.close()
        inspector = .variables; showInspector = true
    }
    func insertVariable(_ variable: CodeVariable, from block: CodeVariableBlock, format: CodeVariableFormat? = nil) {
        guard !fileOperationInProgress, variablesMatchDocument, block.status == "current", variable.reusable,
              variableBlocks.contains(where: { $0.id == block.id && $0.variables.contains(variable) }) else { return }
        let reference: String
        if let format {
            guard let formatted = variable.formattedReference(format) else { return }
            reference = formatted
        } else { reference = variable.reference }
        if mode == .reading { mode = .source }
        showPDF = false
        editorInsertion = reference
    }
    func jumpToCodeBlock(_ block: CodeVariableBlock) {
        guard variablesMatchDocument, block.startLine > 0 else { return }
        let lines = text.components(separatedBy: "\n")
        guard block.startLine <= lines.count else { return }
        jump = lines.prefix(block.startLine - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        if mode == .reading { mode = .source }
        showPDF = false
    }
    func perform(_ action: String, confirmCodeExecution: Bool = true) {
        guard !busy, !fileOperationInProgress, let root else { return }
        if ["compile", "run"].contains(action), selected == nil { return }
        let capturedFile = selected, snapshot = text
        let nodePath = UserDefaults.standard.string(forKey: "nodePath") ?? ""
        if action == "run", confirmCodeExecution {
            let alert = NSAlert(); alert.messageText = "Run this document’s code?"
            alert.informativeText = "Python, R, shell, and JavaScript blocks run locally with your account’s access. Only run code you trust."
            alert.addButton(withTitle: "Run Code"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        busy = true; buildNotice = nil
        buildActivity = action == "compile" ? "Building PDF…" : action == "run" ? "Running code…" : "Preparing workspace…"
        Task {
            defer { busy = false; buildActivity = nil }
            guard await save() else { buildNotice = "Save needs attention"; return }
            do {
                let data = try await engine.call(action: action, root: root, file: capturedFile, text: snapshot, trusted: ["compile", "run"].contains(action), nodePath: nodePath)
                let result = try await BackgroundWork.run { try PublicationResult(data: data) }
                log = result.log; logURL = result.logURL
                if action == "run", let value = result.text, let capturedFile, self.root == root {
                    if selected == capturedFile && text == snapshot {
                        _ = await applyDocumentChange(value, base: snapshot, file: capturedFile, label: "Code block IDs")
                    } else if selected != capturedFile {
                        try await BackgroundWork.run { try Vault(root: root).save(value, to: capturedFile, expected: snapshot) }
                    } else { log += "\nDocument changed while running. Block IDs were not applied; run again after saving." }
                }
                if action == "run", self.root == root, selected == capturedFile {
                    if text == result.text || text == snapshot {
                        variableBlocks = result.variableBlocks; variablesFile = capturedFile
                        variablesSource = result.text ?? snapshot; variablesChecking = false
                    }
                    showVariables()
                    schedulePreview()
                }
                guard result.success else { buildNotice = result.message; showLog = true; refresh(); return }
                if action == "compile", let pdf = result.pdfURL, let capturedFile {
                    buildActivity = "Preparing PDF…"
                    let document = try await BackgroundWork.run {
                        // Own an in-memory snapshot: rebuilding the same path cannot
                        // mutate a PDF already on screen. No PDFView is used here.
                        guard let document = PDFDocument(data: try Data(contentsOf: pdf)) else {
                            throw EngineFailure.failed("Inkwell built a PDF, but it could not be opened.")
                        }
                        for index in 0..<document.pageCount { _ = document.page(at: index)?.bounds(for: .cropBox) }
                        return document
                    }
                    lastPublication = (root, capturedFile, snapshot, pdf, document)
                    buildNotice = "PDF ready · \(capturedFile.deletingPathExtension().lastPathComponent)"
                } else { buildNotice = result.message }
                if action == "run" { showLog = true; schedulePreview() }
                refresh()
                if action == "setup" { await loadEngineInfo() }
            } catch { log = error.localizedDescription; buildNotice = "Build needs attention"; showLog = true }
        }
    }
    func revealBuiltPDF() {
        guard let publication = lastPublication else { return }
        Task {
            if root != publication.root { await openVaultAndWait(publication.root) }
            if selected != publication.file { await selectAndWait(publication.file) }
            guard root == publication.root, selected == publication.file else { return }
            pdfURL = publication.url; pdfSource = publication.source; pdfDocument = publication.document
            showPDF = true; if mode == .source { mode = .split }
        }
    }
    func loadEngineInfo() async {
        guard let root else { return }
        for action in ["templates", "tools", "references"] {
            do {
                let data = try await engine.call(action: action, root: root, file: selected, text: text, nodePath: UserDefaults.standard.string(forKey: "nodePath") ?? "")
                let result = try await BackgroundWork.run { try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
                guard self.root == root else { return }
                if action == "templates" { templates = result["templates"] as? [[String: String]] ?? [] }
                if action == "tools" { tools = result["tools"] as? [[String: Any]] ?? [] }
                if action == "references" { references = (result["references"] as? [String: Any])?["entries"] as? [[String: Any]] ?? [] }
            } catch { status = error.localizedDescription }
        }
    }
    func addAttachment(_ source: URL) {
        guard !fileOperationInProgress, let selected else { return }
        do {
            let dir = selected.deletingLastPathComponent().appendingPathComponent("i", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = source.deletingPathExtension().lastPathComponent + "-" + UUID().uuidString.prefix(6) + "." + source.pathExtension
            let target = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            let image = ["png", "jpg", "jpeg", "gif", "webp"].contains(source.pathExtension.lowercased())
            editorInsertion = "\(image ? "!" : "")[\(source.lastPathComponent)](i/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))\n"
        } catch { self.error = error.localizedDescription }
    }
    func exportHTML() {
        guard !previewHTML.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = title + ".html"; panel.allowedContentTypes = [.html]
        if panel.runModal() == .OK, let url = panel.url { do { try previewHTML.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription } }
    }
    func openWikiLink(_ title: String) {
        if let note = notes.first(where: { $0.relativePath.localizedCaseInsensitiveCompare(title) == .orderedSame }) { select(note.url) }
        else if let note = notes.first(where: { ($0.relativePath as NSString).deletingPathExtension.localizedCaseInsensitiveCompare(title) == .orderedSame }) { select(note.url) }
        else if let note = notes.first(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame }) { select(note.url) }
        else { query = title; showLibrary = true }
    }
    func openDemo() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Create sample vault here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            var folder = parent.appendingPathComponent("Pandanote Welcome", isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) { folder = parent.appendingPathComponent("Pandanote Welcome \(UUID().uuidString.prefix(4))", isDirectory: true) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let vault = Vault(root: folder)
            _ = try vault.create(name: "A place for your thinking", text: Self.welcome)
            _ = try vault.create(name: "Research notebook", folder: "Research", text: "# Research notebook\n\nGood questions deserve room to breathe.\n\n## Open questions\n\n- [ ] Gather the primary sources\n- [ ] Test the first hypothesis\n- [ ] Turn the results into a paper\n\nReturn to [[A place for your thinking]].\n\n#research #ideas\n")
            Task { await openVaultAndWait(folder); perform("setup") }
        } catch { self.error = error.localizedDescription }
    }
    static let welcome = """
    ---
    title: A place for your thinking
    author: Goldberg Consulting
    template: default
    ---

    # A place for your thinking

    Start with a thought. Follow it somewhere interesting.

    Pandanote brings your notes, research, and publication workflow into one native Mac workspace. Your words live in ordinary Markdown files, right where you put them.

    ## From a note to a paper

    Write in the source editor and see the page take shape beside it. When it is ready, **Build PDF** uses Inkwell’s publishing engine, your chosen template, and your bibliography.

    > A quiet place to write. Powerful tools when you need them.

    ## Thinking with code

    Code belongs alongside the ideas it helps explain. Choose **Run Code** in the Inkwell panel to execute this example.

    ```{python id="welcome-example" display="both"}
    observations = [12, 18, 24, 30]
    average = sum(observations) / len(observations)
    print(f"Average: {average:.1f}")
    ```

    ## Make connections

    Open your [[Research notebook]], add a #research tag, or create a daily note. The outline and word count stay within reach.

    - [x] Find a home for your notes
    - [ ] Write something worth keeping
    - [ ] Build your first PDF

    #welcome #writing
    """
}
