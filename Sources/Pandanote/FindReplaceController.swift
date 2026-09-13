import SwiftUI
import AppKit
import PandanoteCore

// Search snapshots use UTF-16 offsets, the same coordinate system as NSTextView.
enum SearchScope: String, CaseIterable {
    case note, selection, vault
    var title: String { switch self { case .note: return "Note"; case .selection: return "Selection"; case .vault: return "Vault" } }
}
struct SearchResultMatch: Identifiable, Sendable {
    let id: String
    let core: TextSearchMatch
    var range: NSRange { core.range }
    var line: Int { core.line }
    var column: Int { core.column }
    var preview: String { core.preview }
    var previewMatchRange: NSRange { core.previewMatchRange }
}
struct SearchFileResult: Identifiable, Sendable {
    var id: String { file.path }
    let file: URL
    let relativePath: String
    let source: String
    let matches: [SearchResultMatch]
}
struct ReplacementPreviewChange: Identifiable, Sendable {
    let id: Int
    let line: Int
    let before: String
    let after: String
}
struct FileReplacementPreview: Identifiable, Sendable {
    let file: URL
    let change: ReplacementFileChange
    let changes: [ReplacementPreviewChange]
    var id: String { file.path }
    var relativePath: String { change.relativePath }
    var before: String { change.before }
    var after: String { change.after }
    var replacementCount: Int { change.replacementCount }
}
struct ReplacementPreview: Identifiable, Sendable {
    let id = UUID()
    let root: URL
    let files: [FileReplacementPreview]
    var matchCount: Int { files.reduce(0) { $0 + $1.replacementCount } }
    var fileCount: Int { files.count }
}
struct SearchNavigation {
    let id = UUID()
    let file: URL
    let source: String
    let range: NSRange
    let focusEditor: Bool
}
private final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class FindReplaceController: ObservableObject {
    weak var workspace: Workspace?
    @Published var query = "" { didSet { if query != oldValue { configurationChanged() } } }
    @Published var replacement = "" {
        didSet {
            if replacement != oldValue {
                invalidatePreview()
                errorMessage = nil; statusMessage = nil
            }
        }
    }
    @Published var scope: SearchScope = .note {
        didSet {
            guard scope != oldValue else { return }
            if scope == .selection { captureSelection() }
            else { selectionContext = nil; configurationChanged() }
        }
    }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { configurationChanged() } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { configurationChanged() } } }
    @Published var usesRegex = false { didSet { if usesRegex != oldValue { configurationChanged() } } }
    @Published var includeGlobs = "" { didSet { if includeGlobs != oldValue { configurationChanged() } } }
    @Published var excludeGlobs = "" { didSet { if excludeGlobs != oldValue { configurationChanged() } } }
    @Published var showReplace = false
    @Published var focusRequest = UUID()
    @Published private(set) var isSearching = false
    @Published private(set) var isApplying = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var resultGroups: [SearchFileResult] = []
    @Published private(set) var activeMatchID: String?
    @Published private(set) var isTruncated = false
    @Published private(set) var preview: ReplacementPreview?
    @Published private(set) var previewFileIDs: Set<String> = []
    @Published private(set) var navigation: SearchNavigation?
    @Published private(set) var backupURL: URL?
    @Published private(set) var canUndoReplacement = false
    private var undoBatch: (root: URL, changes: [ReplacementFileChange])?
    private var searchTask: Task<Void, Never>?
    private var cancellation: SearchCancellation?
    private var searchID = UUID()
    private var previewID = UUID()
    private var isNavigating = false
    private var navigationID = UUID()
    private var preparingPreview = false
    private var selectionContext: (file: URL, source: String, range: NSRange)?
    var totalMatchCount: Int { resultGroups.reduce(0) { $0 + $1.matches.count } }
    var includedReplacementCount: Int { preview?.files.filter { previewFileIDs.contains($0.id) }.reduce(0) { $0 + $1.replacementCount } ?? 0 }
    var options: TextSearchOptions { .init(caseSensitive: caseSensitive, wholeWord: wholeWord, regularExpression: usesRegex) }
    private var allMatches: [(SearchFileResult, SearchResultMatch)] { resultGroups.flatMap { group in group.matches.map { (group, $0) } } }

    func open(replace: Bool, selectedText: String?, inVault: Bool) {
        guard let workspace, workspace.root != nil else { return }
        workspace.showFindReplace = true
        showReplace = replace
        if inVault { scope = .vault }
        else if scope == .vault { scope = .note }
        if let selectedText, !selectedText.isEmpty {
            query = selectedText
            // Finding a literal selection must not interpret its punctuation as regex.
            usesRegex = false
        }
        focusRequest = UUID()
        requestSearch()
    }
    func close() {
        guard !isApplying else { return }
        workspace?.showFindReplace = false
        invalidatePreview()
        cancelSearch(); isSearching = false; navigation = nil
        objectWillChange.send()
    }
    func resetForVault() {
        cancelSearch(); invalidatePreview()
        resultGroups = []; activeMatchID = nil; navigation = nil
        selectionContext = nil; undoBatch = nil; canUndoReplacement = false; backupURL = nil
        errorMessage = nil; statusMessage = nil; isSearching = false
        if scope == .selection { scope = .note }
        requestSearch()
    }
    func captureSelection() {
        guard let workspace, let file = workspace.selected,
              AIPassageContext.isValid(range: workspace.selection, in: workspace.text) else {
            selectionContext = nil; requestSearch(); return
        }
        selectionContext = (file, workspace.text, workspace.selection)
        requestSearch()
    }
    func documentDidChange() {
        guard !isApplying, !isNavigating else { return }
        invalidatePreview()
        requestSearch()
    }
    private func configurationChanged() {
        statusMessage = nil
        invalidatePreview()
        requestSearch()
    }
    private func invalidatePreview() {
        previewID = UUID(); preview = nil; previewFileIDs = []
        if preparingPreview { preparingPreview = false; isSearching = false }
    }
    private func cancelSearch() {
        cancellation?.cancel(); searchTask?.cancel(); searchTask = nil; searchID = UUID()
        navigationID = UUID(); isNavigating = false
    }
    func refreshResults() { requestSearch(immediate: true) }
    func searchNow() async { requestSearch(immediate: true); await searchTask?.value }
    private func requestSearch(immediate: Bool = false) {
        invalidatePreview()
        cancelSearch()
        guard let workspace, workspace.showFindReplace, !isApplying else { isSearching = false; return }
        errorMessage = nil; navigation = nil
        guard !query.isEmpty, let root = workspace.root else {
            resultGroups = []; activeMatchID = nil; isTruncated = false; isSearching = false; return
        }
        let capturedScope = scope, selected = workspace.selected, source = workspace.text
        let range: NSRange?
        if capturedScope == .selection {
            guard let context = selectionContext, context.file == selected, context.source == source else {
                resultGroups = []; activeMatchID = nil; isSearching = false
                errorMessage = "Select a passage in the editor, then choose Use Current Selection."
                return
            }
            range = context.range
        } else { range = nil }
        guard capturedScope == .vault || selected != nil else {
            resultGroups = []; activeMatchID = nil; isSearching = false
            errorMessage = "Open a note to search it."; return
        }
        let query = query, options = options, include = includeGlobs, exclude = excludeGlobs
        let id = UUID(), token = SearchCancellation()
        searchID = id; cancellation = token; isSearching = true
        searchTask = Task { [weak self] in
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(220)) }
                let result = try await BackgroundWork.run { () -> ([SearchFileResult], Bool) in
                    let vault = Vault(root: root)
                    var documents: [(URL, String, String)]
                    var inputTruncated = false
                    if capturedScope == .vault {
                        let filter = try PathGlobFilter(include: include, exclude: exclude)
                        let scanned = try SearchDocumentReader.read(vault: vault, filter: filter, cancelled: { token.cancelled })
                        documents = scanned.documents.map { ($0.0, $0.1, $0.0 == selected ? source : $0.2) }
                        inputTruncated = scanned.truncated
                        if let selected, vault.contains(selected), !documents.contains(where: { $0.0 == selected }) {
                            let path = String(selected.path.dropFirst(vault.root.path.count + 1))
                            if filter.matches(path) { documents.append((selected, path, source)) }
                        }
                    } else if let selected {
                        documents = [(selected, String(selected.path.dropFirst(vault.root.path.count + 1)), source)]
                    } else { documents = [] }
                    var groups: [SearchFileResult] = [], count = 0, byteCount = 0, truncated = inputTruncated
                    let started = ProcessInfo.processInfo.systemUptime
                    for (file, path, text) in documents.sorted(by: { $0.1.localizedStandardCompare($1.1) == .orderedAscending }) {
                        if token.cancelled { throw CancellationError() }
                        byteCount += text.utf8.count
                        if count >= 10_000 || byteCount > 128_000_000 || ProcessInfo.processInfo.systemUptime - started > 15 {
                            truncated = true; break
                        }
                        let found = try TextSearch.find(in: text, query: query, options: options, range: range,
                                                        maximumMatches: 10_000 - count, timeLimit: 1, isCancelled: { token.cancelled })
                        if !found.matches.isEmpty {
                            groups.append(SearchFileResult(file: file, relativePath: path, source: text,
                                matches: found.matches.map { SearchResultMatch(id: file.path + ":\($0.range.location):\($0.range.length)", core: $0) }))
                            count += found.matches.count
                        }
                        if found.isTruncated { truncated = true; break }
                    }
                    // Compile even when no files pass the filter, so invalid patterns remain visible.
                    if documents.isEmpty { _ = try TextSearch.find(in: "", query: query, options: options) }
                    return (groups, truncated)
                }
                guard let self, searchID == id, !token.cancelled, self.workspace?.root == root else { return }
                resultGroups = result.0; isTruncated = result.1; isSearching = false
                if !allMatches.contains(where: { $0.1.id == self.activeMatchID }) { activeMatchID = allMatches.first?.1.id }
            } catch is CancellationError { }
            catch {
                guard let self, searchID == id, !token.cancelled else { return }
                resultGroups = []; activeMatchID = nil; isTruncated = false
                errorMessage = error.localizedDescription; isSearching = false
            }
        }
    }
    func currentMatches(for file: URL, source: String) -> [NSRange] {
        guard workspace?.showFindReplace == true else { return [] }
        return resultGroups.first(where: { $0.file == file && $0.source == source })?.matches.prefix(2_000).map(\.range) ?? []
    }
    func activeMatch(for file: URL, source: String) -> NSRange? {
        guard workspace?.showFindReplace == true else { return nil }
        return resultGroups.first(where: { $0.file == file && $0.source == source })?.matches.first(where: { $0.id == activeMatchID })?.range
    }
    func consumeNavigation(id: UUID) { if navigation?.id == id { navigation = nil } }
    func nextMatch() { navigate(step: 1) }
    func previousMatch() { navigate(step: -1) }
    private func navigate(step: Int) {
        guard !isSearching, !isApplying, !allMatches.isEmpty else { return }
        let matches = allMatches
        let current = matches.firstIndex { $0.1.id == activeMatchID }
        var index = current ?? (step > 0 ? 0 : matches.count - 1)
        if let current, matches[current].0.file == workspace?.selected, matches[current].1.range == workspace?.selection {
            index = (current + step + matches.count) % matches.count
            if (step > 0 && index <= current) || (step < 0 && index >= current) { statusMessage = "Wrapped to the \(step > 0 ? "first" : "last") match." }
        }
        selectMatch(id: matches[index].1.id)
    }
    func selectMatch(id: String) {
        guard !isSearching, !isApplying, let (group, match) = allMatches.first(where: { $0.1.id == id }) else { return }
        let id = UUID(), version = searchID
        navigationID = id
        Task { await selectMatchAndWait(group: group, match: match, id: id, version: version) }
    }
    private func selectMatchAndWait(group: SearchFileResult, match: SearchResultMatch, id: UUID, version: UUID) async {
        guard let workspace, !workspace.fileOperationInProgress, navigationID == id, searchID == version else { return }
        isNavigating = true
        defer { if navigationID == id { isNavigating = false } }
        await workspace.selectAndWait(group.file)
        guard navigationID == id, searchID == version, workspace.showFindReplace else { return }
        guard workspace.selected == group.file, workspace.text == group.source else {
            errorMessage = "This result changed. The search has been refreshed."; requestSearch(); return
        }
        activeMatchID = match.id
        if workspace.mode == .reading { workspace.mode = .source }
        workspace.showPDF = false
        navigation = SearchNavigation(file: group.file, source: group.source, range: match.range, focusEditor: true)
        workspace.selection = match.range
    }
    func replaceCurrent() { Task { await replaceCurrentAndWait() } }
    func replaceCurrentAndWait() async {
        guard !isSearching, !isApplying, let workspace, let root = workspace.root,
              let (group, match) = allMatches.first(where: { $0.1.id == activeMatchID }) else { return }
        do {
            let expanded = try TextSearch.replacement(for: match.core, in: group.source, query: query, replacement: replacement, options: options)
            let after = (group.source as NSString).replacingCharacters(in: match.range, with: expanded)
            let change = ReplacementFileChange(relativePath: group.relativePath, before: group.source, after: after, replacementCount: 1)
            isApplying = true
            let result = await workspace.applySearchChanges([change], in: root)
            isApplying = false
            record(result, root: root)
            if !result.applied.isEmpty {
                updateSelectionScope(for: result.applied)
                statusMessage = "Replaced one match."
            }
            await searchNow()
            if let failure = result.failure { errorMessage = failure }
            if !result.applied.isEmpty, let next = resultGroups.first(where: { $0.file == group.file })?.matches.first(where: { $0.range.location >= match.range.location + (expanded as NSString).length }) {
                selectMatch(id: next.id)
            }
        } catch { isApplying = false; errorMessage = error.localizedDescription }
    }
    func previewReplaceAll() { Task { await previewReplaceAllAndWait() } }
    func previewReplaceAllAndWait() async {
        guard !isSearching, !isApplying, !isTruncated, !resultGroups.isEmpty, let workspace, let root = workspace.root else { return }
        let id = UUID(); previewID = id
        let groups = resultGroups, query = query, replacement = replacement, options = options
        isSearching = true; preparingPreview = true
        do {
            let files = try await BackgroundWork.run { () -> [FileReplacementPreview] in
                var outputBytes = 0
                return try groups.compactMap { group in
                    let expanded = try TextSearch.replacements(for: group.matches.map(\.core), in: group.source, query: query, replacement: replacement, options: options)
                    let updated = NSMutableString(string: group.source)
                    for (match, value) in zip(group.matches, expanded).reversed() { updated.replaceCharacters(in: match.range, with: value) }
                    let after = updated as String
                    guard after.utf8.count <= 8_000_000 else { throw VaultError.tooLarge }
                    outputBytes += after.utf8.count
                    guard outputBytes <= 128_000_000 else { throw EngineFailure.failed("The replacement output is too large. Narrow the search to fewer files.") }
                    guard after != group.source else { return nil }
                    let snippets = zip(group.matches, expanded).prefix(50).enumerated().map { index, pair in
                        let (match, value) = pair
                        let before = match.preview
                        let after = (before as NSString).replacingCharacters(in: match.previewMatchRange, with: value)
                        return ReplacementPreviewChange(id: index, line: match.line, before: String(before.prefix(300)), after: String(after.prefix(300)))
                    }
                    return FileReplacementPreview(file: group.file, change: ReplacementFileChange(relativePath: group.relativePath,
                        before: group.source, after: after, replacementCount: group.matches.count), changes: snippets)
                }
            }
            guard previewID == id, self.workspace?.root == root else { return }
            isSearching = false; preparingPreview = false
            if files.isEmpty { statusMessage = "The replacement would not change any text."; return }
            preview = ReplacementPreview(root: root, files: files)
            previewFileIDs = Set(files.map(\.id))
        } catch {
            guard previewID == id else { return }
            isSearching = false; preparingPreview = false; errorMessage = error.localizedDescription
        }
    }
    func togglePreviewFile(_ id: String) { if !previewFileIDs.insert(id).inserted { previewFileIDs.remove(id) } }
    func dismissPreview() { guard !isApplying else { return }; invalidatePreview() }
    func applyPreview() { Task { await applyPreviewAndWait() } }
    func applyPreviewAndWait() async {
        guard !isApplying, let preview, let workspace, workspace.root == preview.root else { return }
        let changes = preview.files.filter { previewFileIDs.contains($0.id) }.map(\.change)
        guard !changes.isEmpty else { return }
        isApplying = true
        let result = await workspace.applySearchChanges(changes, in: preview.root)
        isApplying = false
        record(result, root: preview.root)
        updateSelectionScope(for: result.applied)
        invalidatePreview()
        if result.failure == nil { statusMessage = "Replaced \(result.applied.reduce(0) { $0 + $1.replacementCount }) matches in \(result.applied.count) file(s)." }
        await searchNow()
        if let failure = result.failure { errorMessage = failure }
    }
    private func record(_ result: ReplacementBatchResult, root: URL) {
        if !result.applied.isEmpty { undoBatch = (root, result.applied); canUndoReplacement = true }
        if let backup = result.backupURL { backupURL = backup }
        if let failure = result.failure { errorMessage = failure }
    }
    private func updateSelectionScope(for changes: [ReplacementFileChange]) {
        guard let context = selectionContext, let workspace,
              let change = changes.first(where: { workspace.root?.appendingPathComponent($0.relativePath) == context.file }), context.source == change.before else { return }
        selectionContext = (context.file, change.after, NSRange(location: context.range.location,
            length: context.range.length + (change.after as NSString).length - (change.before as NSString).length))
    }
    func undoLastReplacement() { Task { await undoLastReplacementAndWait() } }
    func undoLastReplacementAndWait() async {
        guard !isApplying, let undoBatch, let workspace, workspace.root == undoBatch.root else { return }
        isApplying = true
        let result = await workspace.applySearchChanges(undoBatch.changes, in: undoBatch.root, undo: true)
        isApplying = false
        // A selection captured after the batch may be shifted by changes outside it.
        // Recapture rather than applying the entire document's length delta to it.
        if let context = selectionContext, result.applied.contains(where: {
            undoBatch.root.appendingPathComponent($0.relativePath) == context.file
        }) { selectionContext = nil }
        if result.failure == nil {
            self.undoBatch = nil; canUndoReplacement = false; statusMessage = "Replacement undone."
        }
        await searchNow()
        if let failure = result.failure { errorMessage = failure }
    }
}

/// Bound file reads before materializing a vault-wide result set. Unsupported,
/// hidden, oversized, and linked files follow the library's visibility rules.
private enum SearchDocumentReader {
    static func read(vault: Vault, filter: PathGlobFilter, cancelled: () -> Bool) throws -> (documents: [(URL, String, String)], truncated: Bool) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: vault.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
            enumerationError = error; return false
        }) else { throw EngineFailure.failed("The vault could not be read. Reopen the folder and search again.") }
        let started = ProcessInfo.processInfo.systemUptime
        var documents: [(URL, String, String)] = [], bytes = 0, entriesSeen = 0
        for case let entry as URL in entries {
            if cancelled() { throw CancellationError() }
            entriesSeen += 1
            if entriesSeen > 100_000 || ProcessInfo.processInfo.systemUptime - started > 15 { return (documents, true) }
            let file = entry.standardizedFileURL
            if ["node_modules", "venv", ".venv", "build"].contains(file.lastPathComponent) { entries.skipDescendants(); continue }
            guard ["md", "markdown", "txt", "tex", "bib"].contains(file.pathExtension.lowercased()), vault.contains(file) else { continue }
            let path = String(file.path.dropFirst(vault.root.path.count + 1))
            guard filter.matches(path) else { continue }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 8_000_000 else { continue }
            if bytes + (values.fileSize ?? 0) > 128_000_000 { return (documents, true) }
            guard let text = try? vault.read(file) else { continue }
            bytes += text.utf8.count
            if bytes > 128_000_000 { return (documents, true) }
            documents.append((file, path, text))
        }
        if let enumerationError { throw enumerationError }
        return (documents, false)
    }
}
