import SwiftUI
import PandanoteCore

@MainActor final class SourceControlModel: ObservableObject {
    @Published var snapshot: GitSnapshot?
    @Published var selected = Set<String>()
    @Published var diff = "Choose a changed file to inspect its diff."
    @Published var file: String?
    @Published var message = ""
    @Published var name = ""
    @Published var email = ""
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var reviews: [ChangeProposal] = []
    @Published var tab = "Working changes"
    let repository: GitRepository?
    private var diffGeneration = 0
    init(root: URL?) { repository = root.map(GitRepository.init) }
    func refresh(workspace: Workspace) async {
        guard !busy, let repository else { return }
        busy = true; error = nil
        defer { busy = false }
        do { if let vault = workspace.vault { reviews = try ChangeArchive(vault: vault).list() } }
        catch { self.error = error.localizedDescription }
        do {
            snapshot = try await repository.snapshot()
            selected.formIntersection(Set(snapshot!.changes.map(\.path)))
            if name.isEmpty { name = snapshot!.authorName }; if email.isEmpty { email = snapshot!.authorEmail }
            if let file, !snapshot!.changes.contains(where: { $0.path == file }) { self.file = nil; diff = "Choose a changed file to inspect its diff." }
        } catch { snapshot = nil; self.error = error.localizedDescription }
    }
    func inspect(_ path: String) async {
        guard let repository, let snapshot else { return }
        file = path; diffGeneration += 1
        let generation = diffGeneration
        do { let value = try await repository.diff(path: path, snapshot: snapshot); if generation == diffGeneration { diff = value.isEmpty ? "The working file matches HEAD. There may be separate staged changes; Pandanote commits the working file shown here." : value } }
        catch { self.error = error.localizedDescription }
    }
    func history(_ hash: String) async {
        guard let repository else { return }
        diffGeneration += 1; let generation = diffGeneration
        do { let value = try await repository.commitDiff(hash); if generation == diffGeneration { diff = value } }
        catch { self.error = error.localizedDescription }
    }
    func initialize(workspace: Workspace) async {
        guard !busy, let repository else { return }; busy = true
        do { try await repository.initialize(); busy = false; await refresh(workspace: workspace) }
        catch { self.error = error.localizedDescription; busy = false }
    }
    func commit(workspace: Workspace) async {
        guard !busy, let repository, let snapshot else { return }
        busy = true; error = nil
        guard await workspace.save() else { busy = false; return }
        do {
            let hash = try await repository.commit(paths: Array(selected), message: message, expected: snapshot, authorName: name, authorEmail: email)
            notice = "Committed \(hash.prefix(8)) locally."; message = ""; selected = []; busy = false
            await refresh(workspace: workspace)
        } catch { self.error = error.localizedDescription; busy = false }
    }
}

struct SourceControlView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var model: SourceControlModel
    @Environment(\.dismiss) var dismiss
    init(workspace: Workspace) { self.workspace = workspace; _model = StateObject(wrappedValue: SourceControlModel(root: workspace.root)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Changes & Git").font(.title2)
                    Text(model.snapshot.map { "\($0.branch) · \($0.changes.count) changed files" } ?? "Track revisions in this vault").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { if await workspace.save() { await model.refresh(workspace: workspace); if let file = model.file { await model.inspect(file) } } } }.disabled(model.busy)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Picker("View", selection: $model.tab) { ForEach(["Working changes", "Commit history", "AI reviews"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            if model.tab == "AI reviews" { reviews }
            else {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.tab == "Working changes", let snapshot = model.snapshot {
                                if snapshot.changes.isEmpty { Label("Working tree clean", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                                ForEach(snapshot.changes) { change in
                                    HStack(alignment: .top) {
                                        Toggle("Include \(change.path)", isOn: Binding(get: { model.selected.contains(change.path) }, set: { if $0 { model.selected.insert(change.path); Task { await model.inspect(change.path) } } else { model.selected.remove(change.path) } })).labelsHidden()
                                        Button { Task { await model.inspect(change.path) } } label: {
                                            HStack(alignment: .top, spacing: 6) { Text(change.status).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary); Text(change.path).font(.system(size: 12)).multilineTextAlignment(.leading); Spacer() }.padding(6).background(model.file == change.path ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(RegionButtonStyle())
                                    }
                                }
                            } else if model.tab == "Commit history", let snapshot = model.snapshot {
                                if snapshot.commits.isEmpty { Text("Your first commit will appear here.").foregroundStyle(.secondary) }
                                ForEach(snapshot.commits) { commit in
                                    Button { Task { await model.history(commit.hash) } } label: {
                                        VStack(alignment: .leading, spacing: 5) { Text(commit.title).font(.system(size: 12, weight: .medium)); Text("\(commit.hash.prefix(8)) · \(commit.author)").font(.caption2).foregroundStyle(.secondary); Text(commit.date).font(.caption2).foregroundStyle(.tertiary) }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    }.buttonStyle(RegionButtonStyle())
                                }
                            } else {
                                Text("Save named versions of your writing, inspect diffs, and retain a complete local Git history.").font(.callout)
                                Button("Start Git tracking") { Task { await model.initialize(workspace: workspace) } }.disabled(model.busy)
                            }
                        }.padding(16)
                    }.frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
                    ScrollView([.horizontal, .vertical]) { Text(model.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(18) }.frame(minWidth: 400)
                }
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
            Divider()
            if model.tab == "Working changes", model.snapshot != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("Commit name", text: $model.name); TextField("Commit email", text: $model.email) }.textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Describe this revision…", text: $model.message).textFieldStyle(.roundedBorder)
                        Button("Commit \(model.selected.count) files") { Task { await model.commit(workspace: workspace) } }.buttonStyle(.borderedProminent).disabled(model.busy || model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.name.isEmpty || model.email.isEmpty)
                    }
                    Text("Commits include the selected working files. Other staged files stay staged. Local commits only; Git hooks and remote sync are not run.").font(.caption).foregroundStyle(.secondary)
                }.padding(18)
            }
        }.frame(width: 1020, height: 720).task { await model.refresh(workspace: workspace) }
    }
    var reviews: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.reviews.isEmpty { Text("AI revisions you request will appear here, including accepted and rejected proposals.").foregroundStyle(.secondary).padding(20) }
                ForEach(model.reviews) { proposal in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { Text(proposal.relativePath).font(.headline); Spacer(); Text(proposal.decision.capitalized).font(.caption).foregroundStyle(.secondary) }
                        Text(proposal.instruction).font(.callout)
                        Text("\(proposal.provider) · \(proposal.created.formatted())").font(.caption).foregroundStyle(.secondary)
                        if proposal.decision == "pending" {
                            Button("Open review") {
                                guard let root = workspace.root else { return }
                                Task {
                                    await workspace.selectAndWait(root.appendingPathComponent(proposal.relativePath))
                                    guard workspace.selected == root.appendingPathComponent(proposal.relativePath) else { return }
                                    dismiss(); workspace.reviewProposal = proposal
                                }
                            }
                        } else { DisclosureGroup("Inspect revision") { DiffContent(before: proposal.original, after: proposal.replacement) } }
                    }.padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
