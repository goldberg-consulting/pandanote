import SwiftUI
import PandanoteCore

private let findAccent = Color(red: 0.27, green: 0.47, blue: 0.36)

struct FindReplacePanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var search: FindReplaceController
    @State private var showsPathFilters = false
    @State private var collapsedFileIDs: Set<String> = []
    @FocusState private var focusedField: Field?

    private enum Field { case query, replacement }

    init(workspace: Workspace) {
        self.workspace = workspace
        _search = ObservedObject(wrappedValue: workspace.findReplace)
    }

    private var canUseResults: Bool {
        !search.isSearching && !search.isApplying && search.errorMessage == nil && search.totalMatchCount > 0
    }

    private var activeMatchPosition: Int? {
        guard let id = search.activeMatchID,
              let index = search.resultGroups.flatMap(\.matches).firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchControls
            Divider()
            resultSummary
            Divider()
            results
            if search.showReplace {
                Divider()
                replacementActions
            }
            if search.canUndoReplacement || search.backupURL != nil {
                Divider()
                recoveryActions
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .query }
        .onChange(of: search.focusRequest) { _, _ in focusedField = .query }
        .onExitCommand { search.close() }
        .sheet(item: Binding(get: { search.preview }, set: { if $0 == nil { search.dismissPreview() } })) { preview in
            FindReplacementReview(search: search, preview: preview)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(findAccent).accessibilityHidden(true)
            Text("FIND AND REPLACE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            Spacer()
            Button { search.refreshResults() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 26, height: 26)
            }
            .buttonStyle(RegionButtonStyle())
            .disabled(search.isSearching || search.isApplying)
            .accessibilityLabel("Refresh search results")
            .help("Refresh search results from the current note and vault")
            Button { search.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26)
            }
            .buttonStyle(RegionButtonStyle())
            .accessibilityLabel("Close find and replace")
            .help("Close find and replace (Escape)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("Search scope", selection: $search.scope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Choose the current note, captured selection, or all notes in the vault")

            if search.scope == .selection {
                Button { search.captureSelection() } label: {
                    Label("Use Current Selection", systemImage: "selection.pin.in.out")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(workspace.selected == nil || workspace.selection.length == 0)
                .help("Search only the passage currently selected in the editor")
            }

            HStack(alignment: .top, spacing: 7) {
                Button { search.showReplace.toggle() } label: {
                    Image(systemName: search.showReplace ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 29)
                }
                .buttonStyle(RegionButtonStyle())
                .accessibilityLabel(search.showReplace ? "Hide replacement field" : "Show replacement field")
                .help(search.showReplace ? "Hide replacement field" : "Show replacement field")
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Find", text: $search.query, axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .query)
                        .accessibilityLabel("Find text")
                        .onSubmit { search.nextMatch() }
                    if search.showReplace {
                        TextField("Replace with", text: $search.replacement, axis: .vertical)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .replacement)
                            .accessibilityLabel("Replacement text")
                            .help(search.usesRegex ? "Use $1, $2, and so on for capture groups; $0 inserts the full match" : "Leave empty to remove matched text")
                    }
                }
            }

            HStack(spacing: 7) {
                FindOptionButton(title: "Match case", symbol: "Aa", help: "Match uppercase and lowercase exactly", isOn: $search.caseSensitive)
                FindOptionButton(title: "Match whole word", symbol: "ab", help: "Match complete words only", isOn: $search.wholeWord)
                FindOptionButton(title: "Use regular expression", symbol: ".*", help: "Search with a regular expression", isOn: $search.usesRegex)
                Spacer()
                if search.scope == .vault {
                    Button { showsPathFilters.toggle() } label: {
                        Label("Files", systemImage: "line.3.horizontal.decrease")
                            .font(.system(size: 11))
                            .foregroundStyle(showsPathFilters || !search.includeGlobs.isEmpty || !search.excludeGlobs.isEmpty ? findAccent : .secondary)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(RegionButtonStyle())
                    .accessibilityLabel(showsPathFilters ? "Hide file filters" : "Show file filters")
                    .help("Filter notes by path")
                }
            }

            if search.showReplace && search.usesRegex {
                Text("Capture groups: $1, $2… · Full match: $0")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if search.scope == .vault && showsPathFilters {
                VStack(alignment: .leading, spacing: 7) {
                    pathFilter("Files to include", placeholder: "e.g. projects/**, *.md", text: $search.includeGlobs)
                    pathFilter("Files to exclude", placeholder: "e.g. archive/**", text: $search.excludeGlobs)
                    Text("Separate patterns with commas. ** matches folders.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .disabled(search.isApplying)
    }

    private func pathFilter(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel(title)
        }
    }

    private var resultSummary: some View {
        HStack(spacing: 5) {
            if search.isSearching || search.isApplying { ProgressView().controlSize(.mini) }
            Text(resultSummaryText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(resultSummaryText)
            Spacer(minLength: 4)
            if let position = activeMatchPosition, canUseResults {
                Text("\(position) / \(search.totalMatchCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Match \(position) of \(search.totalMatchCount)")
            }
            Button { search.previousMatch() } label: {
                Image(systemName: "chevron.up").font(.system(size: 11)).frame(width: 25, height: 26)
            }
            .buttonStyle(RegionButtonStyle())
            .disabled(!canUseResults)
            .accessibilityLabel("Previous match")
            .help("Previous match (⇧⌘G)")
            Button { search.nextMatch() } label: {
                Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 25, height: 26)
            }
            .buttonStyle(RegionButtonStyle())
            .disabled(!canUseResults)
            .accessibilityLabel("Next match")
            .help("Next match (⌘G)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var resultSummaryText: String {
        if search.isApplying { return "Applying replacements…" }
        if search.isSearching { return "Searching…" }
        if search.query.isEmpty { return "Ready to search" }
        if search.errorMessage != nil { return "Search needs attention" }
        let count = search.totalMatchCount
        let qualifier = search.isTruncated ? "+" : ""
        let matches = "\(count)\(qualifier) \(count == 1 ? "match" : "matches")"
        guard search.scope == .vault else { return matches }
        let files = search.resultGroups.count
        return "\(matches) in \(files) \(files == 1 ? "note" : "notes")"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let error = search.errorMessage {
                        FindMessage(title: "Check your search", detail: error, symbol: "exclamationmark.magnifyingglass")
                    } else if search.query.isEmpty {
                        FindMessage(title: "Find the right words", detail: "Search a note, a selection, or your whole vault. Use case, whole word, and regular expression options to refine your results.", symbol: "text.magnifyingglass")
                    } else if search.totalMatchCount == 0 && !search.isSearching {
                        FindMessage(title: "No matches", detail: "Try another phrase or adjust your search options and file filters.", symbol: "magnifyingglass")
                    } else {
                        ForEach(search.resultGroups) { group in resultGroup(group) }
                    }
                    if search.isTruncated {
                        Label("Results are limited. Narrow the search to preview every replacement.", systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                    if let message = search.statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                }
            }
            .onChange(of: search.activeMatchID) { _, id in
                guard let id else { return }
                if let group = search.resultGroups.first(where: { $0.matches.contains(where: { $0.id == id }) }) {
                    collapsedFileIDs.remove(group.id)
                }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultGroup(_ group: SearchFileResult) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Button {
                if collapsedFileIDs.contains(group.id) { collapsedFileIDs.remove(group.id) }
                else { collapsedFileIDs.insert(group.id) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: collapsedFileIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Image(systemName: "doc.text").foregroundStyle(findAccent)
                    Text(group.relativePath).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    Text("\(group.matches.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(RegionButtonStyle())
            .help(group.relativePath)
            .accessibilityLabel("\(group.relativePath), \(group.matches.count) matches")
            .accessibilityHint(collapsedFileIDs.contains(group.id) ? "Expand results" : "Collapse results")
            if !collapsedFileIDs.contains(group.id) {
                ForEach(group.matches) { match in
                    Button { search.selectMatch(id: match.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text("\(match.line)")
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 26, alignment: .trailing)
                            highlightedPreview(match)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.leading, 19)
                        .padding(.trailing, 13)
                        .padding(.vertical, 7)
                        .background(search.activeMatchID == match.id ? findAccent.opacity(0.13) : .clear)
                        .overlay(alignment: .leading) {
                            if search.activeMatchID == match.id { Rectangle().fill(findAccent).frame(width: 2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RegionButtonStyle())
                    .disabled(search.isApplying || search.isSearching)
                    .accessibilityLabel("Line \(match.line), column \(match.column): \(match.preview)")
                    .accessibilityHint("Open this match in \(group.relativePath)")
                    .accessibilityAddTraits(search.activeMatchID == match.id ? .isSelected : [])
                    .id(match.id)
                }
            }
        }
        .padding(.bottom, 5)
    }

    private func highlightedPreview(_ match: SearchResultMatch) -> Text {
        guard let range = Range(match.previewMatchRange, in: match.preview) else { return Text(match.preview) }
        let before = String(match.preview[..<range.lowerBound])
        let matched = String(match.preview[range])
        let after = String(match.preview[range.upperBound...])
        return Text(before) + Text(matched.isEmpty ? "│" : matched).bold().foregroundColor(findAccent) + Text(after)
    }

    private var replacementActions: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Button("Replace Selected") { search.replaceCurrent() }
                    .disabled(!canUseResults || search.activeMatchID == nil || workspace.fileOperationInProgress)
                    .help("Replace the active search match, then move to the next match")
                Spacer(minLength: 0)
                Button("Preview Replace All…") { search.previewReplaceAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(findAccent)
                    .disabled(!canUseResults || search.isTruncated || workspace.fileOperationInProgress)
                    .help("Review replacements and choose which notes to change")
            }
            .controlSize(.small)
            Text("Review changes before replacing across notes.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 7) {
            if search.canUndoReplacement {
                Button { search.undoLastReplacement() } label: {
                    Label("Undo Last Replacement", systemImage: "arrow.uturn.backward")
                }
                .disabled(search.isApplying || workspace.fileOperationInProgress)
                .help("Restore the notes changed by the most recent replacement")
            }
            if let backupURL = search.backupURL {
                Button { workspace.revealInFinder(backupURL) } label: {
                    Label("Reveal Backup in Finder", systemImage: "folder")
                }
                .help("Original note snapshots are saved locally before replacements are applied")
            }
        }
        .font(.system(size: 11))
        .buttonStyle(RegionButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct FindReplacementReview: View {
    @ObservedObject var search: FindReplaceController
    let preview: ReplacementPreview
    @State private var visibleChangeCounts: [String: Int] = [:]

    private var selectedFileCount: Int {
        preview.files.filter { search.previewFileIDs.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Review replacements").font(.title2)
                    Text("\(preview.matchCount) replacements in \(preview.fileCount) \(preview.fileCount == 1 ? "note" : "notes")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(findAccent)
                    .accessibilityHidden(true)
            }
            .padding(22)
            HStack(spacing: 8) {
                Text("Choose the notes to change.").font(.system(size: 12))
                Spacer()
                Text("Before").foregroundStyle(.red)
                Image(systemName: "arrow.right").accessibilityHidden(true)
                Text("After").foregroundStyle(findAccent)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(preview.files) { file in previewFile(file) }
                }
                .padding(20)
            }
            if let error = search.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }
            Divider()
            HStack(spacing: 12) {
                if search.isApplying { ProgressView().controlSize(.small) }
                Text("\(search.includedReplacementCount) replacements · \(selectedFileCount) \(selectedFileCount == 1 ? "note" : "notes") selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { search.dismissPreview() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(search.isApplying)
                Button(search.isApplying ? "Applying…" : "Apply Replacements") { search.applyPreview() }
                    .buttonStyle(.borderedProminent)
                    .tint(findAccent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(search.isApplying || search.includedReplacementCount == 0)
            }
            .padding(18)
        }
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(search.isApplying)
    }

    private func previewFile(_ file: FileReplacementPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { search.previewFileIDs.contains(file.id) }, set: { _ in search.togglePreviewFile(file.id) })) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(findAccent).accessibilityHidden(true)
                    Text(file.relativePath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(file.replacementCount) \(file.replacementCount == 1 ? "replacement" : "replacements")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .disabled(search.isApplying)
            .accessibilityLabel("Include \(file.relativePath), \(file.replacementCount) replacements")
            .padding(12)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(file.changes.prefix(visibleChangeCounts[file.id] ?? 20)) { change in
                    Divider()
                    Text("LINE \(change.line)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    ReplacementExcerpt(label: "−", text: change.before, color: .red)
                    ReplacementExcerpt(label: "+", text: change.after, color: findAccent)
                }
                if file.changes.count > (visibleChangeCounts[file.id] ?? 20) {
                    Button {
                        visibleChangeCounts[file.id] = min(file.changes.count, (visibleChangeCounts[file.id] ?? 20) + 20)
                    } label: {
                        Label("Show more changes (\(file.changes.count - (visibleChangeCounts[file.id] ?? 20)) remaining)", systemImage: "chevron.down")
                            .font(.system(size: 11))
                            .padding(12)
                    }
                    .buttonStyle(RegionButtonStyle())
                    .accessibilityLabel("Show more changes in \(file.relativePath)")
                }
                if min(file.changes.count, visibleChangeCounts[file.id] ?? 20) < file.replacementCount {
                    Text("Showing \(min(file.changes.count, visibleChangeCounts[file.id] ?? 20)) of \(file.replacementCount) replacements. Applying includes every replacement in this note.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
            }
            .opacity(search.previewFileIDs.contains(file.id) ? 1 : 0.45)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.10)) }
    }
}

private struct FindOptionButton: View {
    let title: String
    let symbol: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(symbol)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? findAccent : .secondary)
                .frame(width: 30, height: 28)
                .background(isOn ? findAccent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isOn ? findAccent.opacity(0.45) : Color.primary.opacity(0.12))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(help)
    }
}

private struct FindMessage: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(findAccent.opacity(0.75))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 26)
        .padding(.vertical, 38)
    }
}

private struct ReplacementExcerpt: View {
    let label: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityLabel(label == "−" ? "Before replacement" : "After replacement")
            Text(text.isEmpty ? "[empty]" : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.07))
    }
}
