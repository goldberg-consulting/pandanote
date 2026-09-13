import AppKit
import SwiftUI
import PandanoteCore

@MainActor
struct AssistantPanel: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var assistant: WritingAssistant
    @ObservedObject private var team = WritingTeamStore.shared
    @AppStorage("aiProvider") private var provider = AIProvider.apple.rawValue
    @FocusState private var composerFocused: Bool
    @State private var showContextOptions = false
    @State private var showTeamSettings = false

    init(workspace: Workspace) {
        self.workspace = workspace
        _assistant = ObservedObject(wrappedValue: workspace.assistant)
    }

    private var mentionQuery: AIMentionQuery? { AIMentionQuery.trailing(in: assistant.prompt) }
    private var filteredCandidates: [AssistantAttachment] {
        let query = mentionQuery?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let attached = Set(assistant.attachments.map(\.id))
        return assistant.mentionCandidates(workspace: workspace).filter { item in
            !attached.contains(item.id) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.kind.rawValue.localizedCaseInsensitiveContains(query))
        }
    }
    private var canCaptureSelection: Bool {
        workspace.selected != nil && AIPassageContext.isValid(range: workspace.selection, in: workspace.text)
    }
    private var canRevise: Bool {
        guard workspace.selected != nil, !assistant.busy else { return false }
        return assistant.scope == "Whole document" ? !workspace.text.isEmpty : assistant.passage != nil || canCaptureSelection
    }
    private var teamSummary: String {
        let mentionedAgents = Set(assistant.attachments.filter { $0.kind == .agent }.compactMap { UUID(uuidString: $0.identifier) })
        let agents = team.configuration.selectedAgents(mentioned: mentionedAgents)
        let hasTeam = team.configuration.useTeam || !agents.isEmpty
        let skillIDs = Set(assistant.attachments.filter { $0.kind == .skill }.map(\.identifier))
        let ruleIDs = Set(assistant.attachments.filter { $0.kind == .rule }.map(\.identifier))
        let guidanceCount = team.configuration.skills.filter { $0.enabled || skillIDs.contains($0.id.uuidString) }.count
            + team.configuration.rules.filter { $0.enabled || ruleIDs.contains($0.id.uuidString) }.count
        let run = hasTeam ? "Orchestrator + \(agents.count) \(agents.count == 1 ? "agent" : "agents")" : "One model"
        return run + " · \(guidanceCount) \(guidanceCount == 1 ? "writing instruction" : "writing instructions")"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                if mentionQuery != nil {
                    mentionResults
                } else {
                    transcript
                }
                requestStatus
                Divider()
                ScrollView { composer }
                    .frame(maxHeight: max(100, min(420, geometry.size.height - 280)))
            }
        }
        .onAppear { composerFocused = true }
        .onChange(of: assistant.composerFocusID) { _, _ in composerFocused = true }
        .sheet(isPresented: $showTeamSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("Writing Team").font(.title2)
                    Spacer()
                    Button("Done") { showTeamSettings = false }
                        .keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                WritingTeamSettingsView()
            }.frame(width: 700, height: 620)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }.disabled(assistant.busy)
            HStack {
                Toggle("Writing team", isOn: $team.configuration.useTeam)
                    .toggleStyle(.checkbox)
                    .disabled(assistant.busy)
                Spacer()
                Button("Manage") { showTeamSettings = true }
                    .accessibilityLabel("Manage writing team, skills, and rules")
            }
            Text(teamSummary).font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(14)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if assistant.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your writing collaborator", systemImage: "sparkles")
                                .font(.headline)
                            Text("Highlight a passage to work on it, or ask a question below. Type @ to add notes, agents, skills, and rules.")
                                .font(.callout).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    ForEach(assistant.messages) { message in
                        messageView(message)
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.padding(14)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: assistant.messages.last?.text) { _, _ in
                if assistant.busy { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
        }
        .frame(minHeight: 110)
    }

    @ViewBuilder private func messageView(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(message.role == "user" ? "You" : "Pandanote")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if !message.text.isEmpty {
                Text(message.text).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if message.role == "assistant", message.complete {
                if let reviewID = message.reviewID {
                    Button("Review revision", systemImage: "doc.text.magnifyingglass") {
                        openReview(reviewID)
                    }.font(.caption)
                } else if !message.text.isEmpty {
                    HStack {
                        Button("Insert") { workspace.editorInsertion = message.text }
                            .disabled(workspace.selected == nil)
                            .help("Insert this response at the editor selection")
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }.font(.caption)
                }
            } else if message.role == "assistant", !assistant.busy {
                Text("Incomplete response").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var mentionResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add to this request").font(.headline)
                Spacer()
                Button { cancelMention() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel mention")
            }.padding(14)
            Text("Keep typing to find a note, agent, skill, or rule.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if filteredCandidates.isEmpty {
                        Text("No matching items. Add agents, skills, and rules in Manage.")
                            .font(.callout).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(filteredCandidates) { item in
                        Button {
                            assistant.attach(item)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? "Untitled \(item.kind.rawValue)" : item.title)
                                        .lineLimit(2)
                                    Text(item.kind.rawValue.capitalized)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus").font(.caption)
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RegionButtonStyle())
                        .accessibilityLabel("Add \(item.kind.rawValue): \(item.title)")
                    }
                }.padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var requestStatus: some View {
        if (assistant.stageStatus != nil && assistant.busy) || assistant.error != nil {
            VStack(alignment: .leading, spacing: 7) {
                if let stage = assistant.stageStatus, assistant.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(stage).font(.caption).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let error = assistant.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let passage = assistant.passage { passageCard(passage) }
            if !assistant.attachments.isEmpty { attachmentChips }

            DisclosureGroup("Context and revision scope", isExpanded: $showContextOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Revise", selection: $assistant.scope) {
                        Text("Selected passage").tag("Selected passage")
                        Text("Whole document").tag("Whole document")
                    }
                    Toggle("Include current note", isOn: $assistant.includeNote)
                    Toggle("Include up to 4 filtered notes", isOn: $assistant.includeSearch)
                }
                .font(.caption)
                .padding(.top, 8)
            }.font(.caption)

            HStack(spacing: 8) {
                Button("Attach selection", systemImage: "text.cursor") {
                    assistant.captureSelection(workspace: workspace)
                }
                .disabled(!canCaptureSelection || assistant.busy)
                .help("Attach the highlighted passage as context")
                Spacer(minLength: 0)
                Button { startMention() } label: {
                    Text("@").font(.system(.body, design: .rounded).weight(.semibold))
                }
                .accessibilityLabel("Mention a note, agent, skill, or rule")
                .help("Add a note, agent, skill, or rule")
            }.controlSize(.small)

            TextField("Ask about your writing…", text: $assistant.prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($composerFocused)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .accessibilityLabel("Message to writing assistant; type at sign to add context")
                .onSubmit {
                    if mentionQuery != nil, let item = filteredCandidates.first { assistant.attach(item) }
                }
                .onExitCommand { if mentionQuery != nil { cancelMention() } }

            HStack(spacing: 8) {
                quickRevision("Reword", instruction: "Reword this passage for clarity while preserving its meaning and voice.")
                quickRevision("Shorten", instruction: "Shorten this passage while preserving its essential meaning, evidence, and citations.")
                quickRevision("Proofread", instruction: "Proofread this passage. Correct grammar, spelling, and punctuation while preserving the author's voice and meaning.")
            }.controlSize(.small)

            HStack {
                SettingsLink { Text("AI settings").font(.caption) }
                Spacer()
                if assistant.busy {
                    Button("Stop") { assistant.stop() }
                } else {
                    Button("Ask") { assistant.ask(workspace: workspace) }
                        .disabled(assistant.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mentionQuery != nil)
                    Button("Revise") { assistant.ask(workspace: workspace, revision: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(assistant.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mentionQuery != nil || !canRevise)
                }
            }.controlSize(.small)

            Text("Included text goes to each selected model or server. Review changes before accepting.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Changes & Git…") {
                Task { if await workspace.save() { workspace.showChanges = true } }
            }.font(.caption).disabled(workspace.root == nil)
        }
        .padding(14)
    }

    private func passageCard(_ passage: AIPassageContext) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Label("Highlighted passage", systemImage: "highlighter")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Button { assistant.passage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove highlighted passage")
            }
            Text(passage.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(passage.text).font(.caption).lineLimit(2)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 6) {
                ForEach(assistant.attachments) { item in
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol)
                        Text(item.title).lineLimit(1)
                        Button { assistant.attachments.removeAll { $0.id == item.id } } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item.kind.rawValue): \(item.title)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("\(item.kind.rawValue.capitalized): \(item.title)")
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func quickRevision(_ label: String, instruction: String) -> some View {
        Button(label) { assistant.ask(workspace: workspace, instruction: instruction, revision: true) }
            .disabled(!canRevise || mentionQuery != nil)
            .help("Create a revision for \(assistant.scope.lowercased())")
            .accessibilityLabel("\(label) \(assistant.scope.lowercased())")
    }

    private func startMention() {
        if mentionQuery == nil {
            if let last = assistant.prompt.last, !last.isWhitespace { assistant.prompt += " " }
            assistant.prompt += "@"
        }
        composerFocused = true
    }

    private func cancelMention() {
        if let query = mentionQuery { assistant.prompt = query.removing(from: assistant.prompt) }
        composerFocused = true
    }

    private func openReview(_ id: UUID) {
        guard let root = workspace.root else { return }
        Task {
            do {
                let reviews = try await BackgroundWork.run { try ChangeArchive(vault: Vault(root: root)).list() }
                guard workspace.root == root else { return }
                if let proposal = reviews.first(where: { $0.id == id }) {
                    if proposal.decision == "pending" { workspace.reviewProposal = proposal }
                    else { workspace.showChanges = true }
                } else {
                    assistant.error = "This revision is no longer available in Changes & Git."
                }
            } catch {
                if workspace.root == root { assistant.error = error.localizedDescription }
            }
        }
    }
}
