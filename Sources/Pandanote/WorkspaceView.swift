import SwiftUI
import AppKit
import PandanoteCore

private let sage = Color(red: 0.27, green: 0.47, blue: 0.36)

private func documentDisplayName(for url: URL) -> String {
    ["md", "markdown"].contains(url.pathExtension.lowercased())
        ? url.deletingPathExtension().lastPathComponent
        : url.lastPathComponent
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            if workspace.root == nil { WelcomeView(workspace: workspace) }
            else {
                HSplitView {
                    if workspace.showLibrary { LibraryView(workspace: workspace).frame(minWidth: 215, idealWidth: 240, maxWidth: 290) }
                    VStack(spacing: 0) {
                        documentTabs
                        if workspace.selected == nil { ContentUnavailableView("Your next idea starts here", systemImage: "square.and.pencil", description: Text("Create a note or open a vault to begin.")) }
                        else { editor }
                    }.frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity)
                    if workspace.showFindReplace {
                        FindReplacePanel(workspace: workspace)
                            .frame(minWidth: 330, idealWidth: 370, maxWidth: 460)
                    } else if workspace.showInspector {
                        InspectorView(workspace: workspace).frame(minWidth: 255, idealWidth: 290, maxWidth: 380)
                    }
                }
                statusBar
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Pandanote")
        .toolbar {
            ToolbarItem(placement: .navigation) { Button { workspace.showLibrary.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle library") }
            ToolbarItem(placement: .navigation) { HStack(spacing: 7) { PandaSymbol().frame(width: 23, height: 23); Text(workspace.root?.lastPathComponent ?? "Pandanote").font(.system(size: 13, weight: .semibold)) } }
            ToolbarItemGroup(placement: .principal) {
                Picker("Editor layout", selection: $workspace.mode) {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(EditorMode.source)
                    Label("Side by side", systemImage: "rectangle.split.2x1").tag(EditorMode.split)
                    Label("Reading", systemImage: "doc.richtext").tag(EditorMode.reading)
                }.pickerStyle(.segmented).frame(width: 170).help("Source, side by side, or reading")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.openFind() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Find and replace")
                    .help("Find and replace (⌘F)")
                    .disabled(workspace.root == nil)
                Button { workspace.perform("compile") } label: { Label(workspace.busy ? "Building…" : "Build PDF", systemImage: "arrow.up.document") }.disabled(workspace.busy || workspace.fileOperationInProgress || workspace.selected == nil)
                Button { workspace.inspector = .assistant; workspace.showInspector.toggle() } label: { Image(systemName: "sparkles") }.help("Writing assistant")
                Button { workspace.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle inspector")
            }
        }
        .alert("Pandanote", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .sheet(isPresented: $workspace.showHistory) { HistoryView(workspace: workspace) }
        .sheet(isPresented: $workspace.showDocumentSettings) { DocumentSettingsView(workspace: workspace) }
        .sheet(item: $workspace.reviewProposal) { proposal in RevisionReviewView(workspace: workspace, proposal: proposal) }
        .sheet(isPresented: $workspace.showChanges) { SourceControlView(workspace: workspace) }
    }
    var documentTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs, id: \.path) { url in
                    HStack(spacing: 0) {
                        Button { workspace.select(url) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(workspace.selected == url ? sage : .secondary)
                                Text(documentDisplayName(for: url)).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 8)
                                if workspace.selected == url && workspace.dirty { Circle().fill(sage).frame(width: 5, height: 5) }
                            }.padding(.leading, 14).padding(.trailing, 8).frame(minWidth: 115).frame(height: 41).contentShape(Rectangle())
                        }.buttonStyle(RegionButtonStyle())
                            .accessibilityLabel("Open \(url.lastPathComponent)")
                        Button { workspace.closeTab(url) } label: { Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 28, height: 41).contentShape(Rectangle()) }.buttonStyle(RegionButtonStyle()).help("Close \(url.lastPathComponent)")
                            .accessibilityLabel("Close \(url.lastPathComponent)")
                            .disabled(workspace.fileOperationInProgress)
                    }.frame(height: 41)
                        .background(workspace.selected == url ? Color(nsColor: .textBackgroundColor) : .clear)
                        .overlay(alignment: .bottom) { if workspace.selected == url { Rectangle().fill(sage.opacity(0.8)).frame(height: 2) } }
                        .contentShape(Rectangle())
                        .help(url.path)
                        .contextMenu { WorkspaceTabMenu(workspace: workspace, url: url) }
                    Divider().frame(height: 24)
                }
                Button { workspace.newNote() } label: { Image(systemName: "plus").font(.system(size: 11)).padding(14) }.buttonStyle(RegionButtonStyle())
                    .accessibilityLabel("New note")
                    .help("New note")
                    .disabled(workspace.fileOperationInProgress)
                    .contextMenu { WorkspaceCreationMenu(workspace: workspace, directory: workspace.root) }
            }
        }.background(.quaternary.opacity(0.2)).overlay(alignment: .bottom) { Divider() }
            .contentShape(Rectangle())
            .contextMenu {
                WorkspaceCreationMenu(workspace: workspace, directory: workspace.root)
                if !workspace.tabs.isEmpty {
                    Divider()
                    Button("Close All Tabs") { workspace.closeAllTabs() }
                        .disabled(workspace.fileOperationInProgress)
                }
            }
    }
    var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspace.selected?.lastPathComponent ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if workspace.selection.length > 0 {
                    Button { workspace.assistant.captureSelection(workspace: workspace) } label: { Label("Ask AI", systemImage: "sparkles").font(.caption) }
                        .help("Attach highlighted passage to the assistant (⇧⌘A)")
                }
                Button { workspace.renameSelected() } label: { Image(systemName: "pencil").frame(width: 28, height: 28) }.buttonStyle(RegionButtonStyle()).help("Rename note")
                    .accessibilityLabel("Rename note")
                    .disabled(workspace.fileOperationInProgress || workspace.busy)
                Button { if let selected = workspace.selected { workspace.toggleFavorite(selected) } } label: { Image(systemName: workspace.favorites.contains(workspace.selected?.path ?? "") ? "star.fill" : "star").frame(width: 28, height: 28) }.buttonStyle(RegionButtonStyle()).help("Favorite")
                    .accessibilityLabel(workspace.favorites.contains(workspace.selected?.path ?? "") ? "Remove from Favorites" : "Add to Favorites")
                    .disabled(workspace.fileOperationInProgress)
                Menu {
                    if let url = workspace.selected {
                        WorkspaceItemMenu(workspace: workspace, url: url, showsOpen: false, showsCreation: false)
                    }
                    Divider()
                    Button("Note History") { workspace.showHistory = true }
                    Button("Export HTML…") { workspace.exportHTML() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 20)
                    .accessibilityLabel("Note actions")
                    .help("Note actions")
            }.padding(.horizontal, 20).frame(height: 36)
            Divider()
            if workspace.conflict {
                HStack { Text("Changed outside Pandanote. Your edits are preserved."); Spacer(); Button("Save a copy") { workspace.saveCopy() }; Button("Reload disk version") { workspace.reload() } }.font(.caption).padding(10).background(.orange.opacity(0.15))
            }
            HSplitView {
                NativeEditor(workspace: workspace).frame(minWidth: workspace.mode == .reading ? 0 : 220, maxWidth: workspace.mode == .reading ? 0 : .infinity).opacity(workspace.mode == .reading ? 0 : 1)
                if workspace.mode != .source {
                    VStack(spacing: 0) {
                        HStack {
                            Text(workspace.showPDF ? "PUBLICATION" : "LIVE PREVIEW").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                            if workspace.showPDF, workspace.pdfSource != workspace.text { Text("Rebuild for latest edits").font(.caption2).foregroundStyle(.orange) }
                            Spacer()
                            if workspace.pdfURL != nil { Picker("Preview", selection: $workspace.showPDF) { Text("Draft").tag(false); Text("PDF").tag(true) }.pickerStyle(.segmented).frame(width: 110) }
                        }.padding(.horizontal, 20).frame(height: 34)
                        Divider()
                        if workspace.showPDF, let document = workspace.pdfDocument { NativePDFView(document: document) }
                        else if workspace.previewHTML.isEmpty { ContentUnavailableView("Preparing your page", systemImage: "doc.richtext", description: Text(workspace.status)) }
                        else { MarkdownPreview(html: workspace.previewHTML, onNote: workspace.openWikiLink) }
                    }.frame(minWidth: 230)
                }
            }
            if workspace.showLog {
                Divider()
                HStack { Label("Inkwell output", systemImage: "terminal").font(.caption); Spacer(); if let url = workspace.logURL { Button("Open full log") { NSWorkspace.shared.open(url) }.font(.caption) }; Button { workspace.showLog = false } label: { Image(systemName: "xmark") }.buttonStyle(RegionButtonStyle()) }.padding(10)
                ScrollView { Text(workspace.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 145).background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
    var statusBar: some View {
        HStack(spacing: 15) {
            HStack(spacing: 5) { Circle().fill(workspace.conflict ? .orange : sage).frame(width: 5, height: 5); Text(workspace.status).lineLimit(1) }
            Spacer()
            if let activity = workspace.buildActivity {
                ProgressView().controlSize(.mini)
                Text(activity).help("Inkwell is working in the background. You can keep writing or switch notes.")
            } else if let notice = workspace.buildNotice {
                Text(notice).lineLimit(1).help(notice)
            }
            if workspace.hasBuiltPDF { Button("View PDF") { workspace.revealBuiltPDF() }.buttonStyle(RegionButtonStyle()) }
            Text("\(workspace.words) words")
            Text("\(max(1, Int(ceil(Double(workspace.words) / 220)))) min read")
            Text("UTF-8")
            Button { workspace.showLog.toggle() } label: { Label("Inkwell", systemImage: "terminal") }.buttonStyle(RegionButtonStyle())
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 17).frame(height: 27).overlay(alignment: .top) { Divider() }
    }
}

struct LibraryView: View {
    @ObservedObject var workspace: Workspace

    private var creationDirectory: URL? {
        guard let root = workspace.root else { return nil }
        guard workspace.filter.hasPrefix("folder:") else { return root }
        return root.appendingPathComponent(String(workspace.filter.dropFirst(7)), isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary); Spacer(); Menu { Button("Open vault…") { workspace.chooseVault() }; ForEach(workspace.recentVaults, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { workspace.openVault(URL(fileURLWithPath: path)) } } } label: { Image(systemName: "folder.badge.plus") }.menuStyle(.borderlessButton).frame(width: 22) }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 14)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.tertiary); TextField("Search your notes", text: $workspace.query).textFieldStyle(.plain); if !workspace.query.isEmpty { Button { workspace.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(RegionButtonStyle()) } }.font(.system(size: 12)).padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 15)
            VStack(spacing: 3) {
                filterRow("All notes", icon: "square.stack", count: workspace.notes.count)
                filterRow("Favorites", icon: "star", count: workspace.favorites.count)
                filterRow("Tasks", icon: "checklist", count: workspace.notes.filter { $0.text.contains("- [") }.count)
            }.padding(.horizontal, 10)
            if !workspace.folders.isEmpty {
                Text("FOLDERS").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 8)
                ScrollView { VStack(spacing: 1) { ForEach(workspace.folders, id: \.self) { folder in
                    Button { workspace.filter = "folder:" + folder } label: {
                        HStack {
                            Image(systemName: workspace.filter == "folder:" + folder ? "folder.fill" : "folder").foregroundStyle(sage.opacity(0.8))
                            Text(folder).lineLimit(1)
                            Spacer()
                        }.font(.system(size: 12)).padding(.vertical, 6).padding(.horizontal, 18)
                            .background(workspace.filter == "folder:" + folder ? sage.opacity(0.10) : .clear)
                            .contentShape(Rectangle())
                    }.buttonStyle(RegionButtonStyle())
                        .accessibilityLabel("Folder \(folder)")
                        .contextMenu {
                            if let root = workspace.root {
                                WorkspaceItemMenu(workspace: workspace, url: root.appendingPathComponent(folder, isDirectory: true), isDirectory: true)
                            }
                        }
                } } }.frame(maxHeight: 90)
            }
            HStack { Text(workspace.query.isEmpty ? "NOTES" : "RESULTS").tracking(1.3); Spacer(); Text("\(workspace.filteredNotes.count)") }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.filteredNotes) { note in
                        Button { workspace.select(note.url) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 5) { if workspace.pinned.contains(note.id) { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(sage) }; Text(documentDisplayName(for: note.url)).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(minLength: 0) }
                                Text(note.excerpt).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                HStack { Text(note.modified, style: .date); Spacer(); if let tag = note.tags.first { Text("#" + tag).foregroundStyle(sage) } }.font(.system(size: 9)).foregroundStyle(.tertiary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(workspace.selected == note.url ? sage.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(RegionButtonStyle())
                        .accessibilityLabel("Open \(documentDisplayName(for: note.url))")
                        .help(note.relativePath)
                        .contextMenu { WorkspaceItemMenu(workspace: workspace, url: note.url) }
                    }
                }.padding(.horizontal, 8)
                if workspace.filteredNotes.isEmpty { Text("No notes found").font(.caption).foregroundStyle(.secondary).padding(20) }
            }
            if !workspace.allTags.isEmpty {
                Divider().padding(.top, 8)
                ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(workspace.allTags.prefix(15), id: \.self) { tag in Button { workspace.filter = "#" + tag } label: { Text("#" + tag).font(.system(size: 10)).foregroundStyle(sage).padding(.horizontal, 8).padding(.vertical, 5).background(sage.opacity(workspace.filter == "#" + tag ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle()) }.buttonStyle(RegionButtonStyle()) } }.padding(12) }
            }
            Divider()
            HStack {
                Button { workspace.newNote(in: creationDirectory) } label: { Label("New note", systemImage: "square.and.pencil").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle()) }.buttonStyle(RegionButtonStyle())
                    .disabled(workspace.fileOperationInProgress)
                Menu { WorkspaceCreationMenu(workspace: workspace, directory: creationDirectory) } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).frame(width: 18)
                    .accessibilityLabel("New item")
                    .help("New note, file, or folder")
                    .disabled(workspace.fileOperationInProgress)
            }.padding(17)
        }.background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .contextMenu { WorkspaceLibraryMenu(workspace: workspace, directory: creationDirectory) }
    }
    func filterRow(_ name: String, icon: String, count: Int) -> some View {
        Button { workspace.filter = name } label: { HStack(spacing: 9) { Image(systemName: icon).frame(width: 16).foregroundStyle(workspace.filter == name ? sage : .secondary); Text(name); Spacer(); Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary) }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8).background(workspace.filter == name ? sage.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(RegionButtonStyle())
    }
}

private struct WorkspaceCreationMenu: View {
    @ObservedObject var workspace: Workspace
    let directory: URL?

    var body: some View {
        Group {
            Button("New Note", systemImage: "square.and.pencil") { workspace.newNote(in: directory) }
            Button("New File…", systemImage: "doc.badge.plus") { workspace.newFile(in: directory) }
            Button("New Folder…", systemImage: "folder.badge.plus") { workspace.newFolder(in: directory) }
            Menu("New from Template") {
                Button("Daily Note") { workspace.newNote(kind: "Daily note", in: directory) }
                Button("Research Paper") { workspace.newNote(kind: "Research paper", in: directory) }
            }
        }.disabled(workspace.root == nil || workspace.fileOperationInProgress)
    }
}

private struct WorkspacePathMenu: View {
    @ObservedObject var workspace: Workspace
    let url: URL

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") { workspace.revealInFinder(url) }
        Button("Copy Path", systemImage: "doc.on.clipboard") { workspace.copyPath(url) }
        Button("Copy Relative Path") { workspace.copyPath(url, relative: true) }
    }
}

private struct WorkspaceItemMenu: View {
    @ObservedObject var workspace: Workspace
    let url: URL
    var isDirectory = false
    var showsOpen = true
    var showsCreation = true

    private var relativeDirectory: String {
        guard let root = workspace.root else { return "" }
        return String(url.path.dropFirst(root.path.count + 1))
    }

    var body: some View {
        Group {
            if showsOpen {
                if isDirectory {
                    Button("Show Notes in Folder", systemImage: "folder") {
                        workspace.filter = "folder:" + relativeDirectory
                        workspace.query = ""
                    }
                } else {
                    Button("Open", systemImage: "doc.text") { workspace.select(url) }
                }
                Divider()
            }
            if showsCreation {
                WorkspaceCreationMenu(workspace: workspace, directory: isDirectory ? url : url.deletingLastPathComponent())
                Divider()
            }
            Button("Rename…", systemImage: "pencil") { workspace.rename(url) }
                .disabled(workspace.busy)
            Button("Duplicate", systemImage: "plus.square.on.square") { workspace.duplicate(url) }
            Button("Move to…", systemImage: "folder.badge.arrowshape.forward") { workspace.move(url) }
                .disabled(workspace.busy)
            Divider()
            WorkspacePathMenu(workspace: workspace, url: url)
            if !isDirectory {
                Divider()
                Button(workspace.favorites.contains(url.path) ? "Remove from Favorites" : "Add to Favorites", systemImage: workspace.favorites.contains(url.path) ? "star.slash" : "star") {
                    workspace.toggleFavorite(url)
                }
                Button(workspace.pinned.contains(url.path) ? "Unpin Note" : "Pin Note", systemImage: workspace.pinned.contains(url.path) ? "pin.slash" : "pin") {
                    workspace.togglePin(url)
                }
            }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) { workspace.delete(url) }
                .disabled(workspace.busy)
        }.disabled(workspace.fileOperationInProgress)
    }
}

private struct WorkspaceTabMenu: View {
    @ObservedObject var workspace: Workspace
    let url: URL

    var body: some View {
        Group {
            Button("Close", systemImage: "xmark") { workspace.closeTab(url) }
            Button("Close Others") { workspace.closeOtherTabs(url) }
                .disabled(workspace.tabs.count < 2)
            Button("Close to the Right") { workspace.closeTabsToRight(of: url) }
                .disabled(workspace.tabs.last == url)
            Button("Close All") { workspace.closeAllTabs() }
            Divider()
            WorkspaceItemMenu(workspace: workspace, url: url, showsOpen: false, showsCreation: false)
        }.disabled(workspace.fileOperationInProgress)
    }
}

private struct WorkspaceLibraryMenu: View {
    @ObservedObject var workspace: Workspace
    let directory: URL?

    var body: some View {
        WorkspaceCreationMenu(workspace: workspace, directory: directory)
        Divider()
        if let directory { WorkspacePathMenu(workspace: workspace, url: directory) }
        Button("Refresh", systemImage: "arrow.clockwise") { workspace.refresh() }
            .disabled(workspace.fileOperationInProgress)
    }
}

struct InspectorView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button { workspace.inspector = tab } label: { Text(tab.rawValue).font(.system(size: 11, weight: workspace.inspector == tab ? .semibold : .regular)).foregroundStyle(workspace.inspector == tab ? .primary : .secondary).frame(maxWidth: .infinity).frame(height: 41).overlay(alignment: .bottom) { if workspace.inspector == tab { Rectangle().fill(sage).frame(height: 2) } } }.buttonStyle(RegionButtonStyle())
            } }
            Divider()
            switch workspace.inspector {
            case .outline: outlinePanel
            case .inkwell: inkwellPanel
            case .variables: VariablesPanel(workspace: workspace)
            case .assistant: AssistantPanel(workspace: workspace)
            }
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }
    var outlinePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("ON THIS PAGE")
                ForEach(workspace.outline) { heading in
                    Button { workspace.jump = heading.offset; if workspace.mode == .reading { workspace.mode = .split } } label: { HStack(alignment: .top, spacing: 9) { Text(String(heading.level)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 12); Text(heading.title).font(.system(size: 12, weight: heading.level == 1 ? .medium : .regular)).multilineTextAlignment(.leading); Spacer(minLength: 0) }.padding(.vertical, 9).padding(.leading, CGFloat(heading.level - 1) * 10) }.buttonStyle(RegionButtonStyle())
                }
                if workspace.outline.isEmpty { Text("Headings make a home here.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 15) }
                Divider().padding(.vertical, 22)
                sectionLabel("DOCUMENT")
                detail("Words", "\(workspace.words)")
                detail("Reading time", "\(max(1, Int(ceil(Double(workspace.words) / 220)))) min")
                detail("Characters", "\(workspace.text.count)")
                if let note = workspace.notes.first(where: { $0.url == workspace.selected }) { detail("Modified", note.modified.formatted(date: .abbreviated, time: .shortened)) }
                Divider().padding(.vertical, 22)
                sectionLabel("CONNECTIONS")
                let backlinks = workspace.notes.filter { $0.url != workspace.selected && $0.text.contains("[[\(workspace.title)") }
                ForEach(backlinks) { note in Button { workspace.select(note.url) } label: { Label(note.title, systemImage: "link").font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle()) }.buttonStyle(RegionButtonStyle()) }
                if backlinks.isEmpty { Text("Link to this note with [[\(workspace.title)]].").font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
            }.padding(20)
        }
    }
    var inkwellPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: "book.closed.fill").font(.title2).foregroundStyle(sage); VStack(alignment: .leading, spacing: 3) { Text("Made for publication").font(.system(size: 14, weight: .semibold)); Text("Powered by Inkwell").font(.caption).foregroundStyle(.secondary) } }.padding(.vertical, 6)
                Text("Your notes, code, and references. One finished document.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { workspace.perform("compile") } label: { Label("Build PDF", systemImage: "arrow.up.document").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(workspace.busy)
                Button { workspace.perform("run") } label: { Label("Run Code Blocks…", systemImage: "play").frame(maxWidth: .infinity) }.disabled(workspace.busy)
                Button { workspace.showVariables() } label: { Label("Inspect Variables", systemImage: "shippingbox").frame(maxWidth: .infinity) }
                Button("Set up this workspace") { workspace.perform("setup") }.font(.caption).disabled(workspace.busy)
                Divider().padding(.vertical, 6)
                sectionLabel("PUBLICATION TEMPLATE")
                Text(workspace.publicationSummary).font(.system(size: 12, weight: .medium))
                Button("Document settings…", systemImage: "slider.horizontal.3") { workspace.showDocumentSettings = true }.disabled(workspace.selected == nil || workspace.selected?.pathExtension == "tex")
                Text("Configure the Inkwell preamble: template, typography, tables, references, code, and custom LaTeX. Each control includes guidance.").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 6)
                sectionLabel("REFERENCES")
                if workspace.references.isEmpty { Text("Add a .bib file to .inkwell/references, then refresh to see your citation keys.").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(Array(workspace.references.enumerated()), id: \.offset) { _, entry in
                    Button { if let key = entry["key"] as? String { workspace.editorInsertion = "[@\(key)]" } } label: { Text("@" + (entry["key"] as? String ?? "")).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle()) }.buttonStyle(RegionButtonStyle())
                }
                Button("Refresh tools & references") { Task { await workspace.loadEngineInfo() } }.font(.caption)
                Divider().padding(.vertical, 6)
                sectionLabel("LOCAL TOOLS")
                ForEach(Array(workspace.tools.enumerated()), id: \.offset) { _, tool in
                    HStack { Circle().fill(tool["available"] as? Bool == true ? sage : .orange).frame(width: 5, height: 5); Text(tool["name"] as? String ?? "").font(.system(size: 11, design: .monospaced)); Spacer(); Text(tool["available"] as? Bool == true ? "Ready" : "Missing").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }.padding(20)
        }
    }
    func sectionLabel(_ value: String) -> some View { Text(value).font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary).padding(.bottom, 7) }
    func detail(_ label: String, _ value: String) -> some View { HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.system(size: 11)).padding(.vertical, 6) }
}

struct WelcomeView: View {
    @ObservedObject var workspace: Workspace
    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 22) {
                PandaSymbol().frame(width: 110, height: 110)
                Text("A little room\nfor big ideas.").font(.system(size: 52, weight: .medium, design: .serif)).tracking(-1.5)
                Text("Notes that grow into something more.\nA native Mac home for your writing, research, and Inkwell.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(6)
                HStack(spacing: 12) {
                    Button("Open a folder as a vault…") { workspace.chooseVault() }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Create a sample vault…") { workspace.openDemo() }.controlSize(.large)
                }.padding(.top, 12)
                Text("Your files. Your Mac. Your words.").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 5)
            }
            VStack(alignment: .leading, spacing: 28) {
                welcomeFeature("pencil.line", "Write without friction", "Native editing, Markdown, and live preview.")
                welcomeFeature("link", "Keep ideas connected", "Vaults, folders, tags, and links between notes.")
                welcomeFeature("arrow.up.document", "Publish with Inkwell", "Runnable code and publication-quality PDFs.")
                welcomeFeature("sparkles", "Think with a collaborator", "On-device AI, local models, or your own API.")
            }.frame(width: 270)
        }.padding(60).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func welcomeFeature(_ icon: String, _ title: String, _ body: String) -> some View { HStack(alignment: .top, spacing: 15) { Image(systemName: icon).font(.system(size: 20)).foregroundStyle(sage).frame(width: 28); VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .semibold)); Text(body).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3) } } }
}

struct PandaSymbol: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "PandaSketch", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Sketched panda")
        } else { Image(systemName: "pencil.circle").resizable().scaledToFit() }
    }
}

struct HistoryView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var selected: URL?
    @State private var versionText = ""
    var versions: [URL] { guard let file = workspace.selected else { return [] }; return workspace.vault?.versions(for: file) ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Note history").font(.headline); Spacer(); Button("Done") { dismiss() } }.padding(20)
            HSplitView {
                List(versions, id: \.path, selection: $selected) { url in Text(Date(timeIntervalSince1970: (Double(url.deletingPathExtension().lastPathComponent) ?? 0) * 60).formatted()).font(.caption).tag(url) }.frame(width: 210)
                ScrollView { Text(versionText.isEmpty ? "Choose an earlier version to read it." : versionText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
            }
            HStack { Text("Restore places the selected version in the editor.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Restore version") { workspace.edit(versionText); dismiss() }.disabled(selected == nil) }.padding(20)
        }.frame(width: 800, height: 520).onChange(of: selected) { _, url in if let url { versionText = (try? String(contentsOf: url, encoding: .utf8)) ?? "" } }
    }
}
