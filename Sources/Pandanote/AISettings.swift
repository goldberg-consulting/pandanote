import SwiftUI
import PandanoteCore

@MainActor
struct AISettingsView: View {
    @AppStorage("aiProvider") private var providerName = AIProvider.apple.rawValue
    @AppStorage("openAIModel") private var openAIModel = ""
    @AppStorage("anthropicModel") private var anthropicModel = ""
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @AppStorage("aiModel") private var compatibleModel = ""
    @AppStorage("ollamaURL") private var ollamaURL = "http://localhost:11434"
    @AppStorage("aiBaseURL") private var baseURL = ""
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var keyStatus = ""
    @State private var keyError = false

    private var provider: AIProvider { AIProvider(rawValue: providerName) ?? .apple }

    var body: some View {
        Form {
            Section {
                Picker("Default provider", selection: $providerName) {
                    ForEach(AIProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider.rawValue)
                    }
                }
                Text("Used for the writing assistant and any team member without a provider override.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            providerSettings

            if provider == .openAI || provider == .anthropic || provider == .compatible {
                Section("API key for \(provider.rawValue)") {
                    Label(hasSavedKey ? "Key saved in Keychain" : "No key saved", systemImage: hasSavedKey ? "lock.shield" : "key")
                        .foregroundStyle(.secondary)
                    SecureField(hasSavedKey ? "New API key" : "API key", text: $key)
                        .accessibilityLabel("\(provider.rawValue) API key")
                    HStack {
                        Button("Save key") { saveKey() }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear saved key", role: .destructive) { clearKey() }
                            .disabled(!hasSavedKey)
                    }
                    if !keyStatus.isEmpty {
                        Text(keyStatus).font(.caption)
                            .foregroundStyle(keyError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                    Text("Each provider has its own key. Keys are stored in macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Writing with AI") {
                Text("Highlight a passage and choose Ask AI about Selection. In the assistant, type @ to include a note.")
                Text("Use Writing Team to choose an orchestrator, arrange agents, and save writing skills and rules. Revisions open for review before you apply them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshKeyStatus() }
        .onChange(of: providerName) { _, _ in
            key = ""
            keyStatus = ""
            keyError = false
            refreshKeyStatus()
        }
        .onDisappear { key = "" }
    }

    @ViewBuilder private var providerSettings: some View {
        switch provider {
        case .apple:
            Section("Apple Intelligence") {
                Text("Uses Apple’s on-device language model on supported Macs running macOS 26. Enable Apple Intelligence in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .openAI:
            Section("OpenAI") {
                TextField("Model ID", text: $openAIModel)
                    .accessibilityLabel("OpenAI model ID")
                Text("Enter a model ID available to your OpenAI API account. An API account and API key are required.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SettingsDocumentationLink("OpenAI models", address: "https://developers.openai.com/api/docs/models")
                    Spacer()
                    SettingsDocumentationLink("Get an OpenAI API key", address: "https://platform.openai.com/api-keys")
                }
            }
        case .anthropic:
            Section("Anthropic") {
                TextField("Model ID", text: $anthropicModel)
                    .accessibilityLabel("Claude model ID")
                Text("Enter a Claude model ID available to your Anthropic API account. An API account and API key are required.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    SettingsDocumentationLink("Claude models", address: "https://platform.claude.com/docs/en/models/overview")
                    Spacer()
                    SettingsDocumentationLink("Get an Anthropic API key", address: "https://platform.claude.com/settings/keys")
                }
            }
        case .ollama:
            Section("Ollama") {
                TextField("Server URL", text: $ollamaURL)
                    .accessibilityLabel("Ollama server URL")
                TextField("Installed model name", text: $ollamaModel)
                    .accessibilityLabel("Ollama model name")
                Text("Ollama must be running with the chosen model installed. Requests are sent to this server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .compatible:
            Section("Compatible API") {
                TextField("Base URL (ending in /v1)", text: $baseURL)
                    .accessibilityLabel("Compatible API base URL")
                TextField("Model ID", text: $compatibleModel)
                    .accessibilityLabel("Compatible API model ID")
                Text("Use a service that supports the OpenAI chat completions format. Requests and included notes are sent to this server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshKeyStatus() {
        hasSavedKey = provider != .apple && provider != .ollama && !Keychain.read(provider: provider).isEmpty
    }

    private func saveKey() {
        do {
            try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
            key = ""
            hasSavedKey = true
            keyStatus = "Saved securely in Keychain."
            keyError = false
        } catch {
            keyStatus = error.localizedDescription
            keyError = true
        }
    }

    private func clearKey() {
        do {
            try Keychain.save("", provider: provider)
            key = ""
            hasSavedKey = false
            keyStatus = "Saved key cleared."
            keyError = false
        } catch {
            keyStatus = error.localizedDescription
            keyError = true
        }
    }
}

private struct SettingsDocumentationLink: View {
    let title: String
    let address: String

    init(_ title: String, address: String) {
        self.title = title
        self.address = address
    }

    var body: some View {
        if let url = URL(string: address) {
            Link(title, destination: url).font(.caption)
        }
    }
}

@MainActor
struct WritingTeamSettingsView: View {
    @ObservedObject private var store = WritingTeamStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use writing team", isOn: $store.configuration.useTeam)
                        .font(.headline)
                    Text("The orchestrator makes a plan, enabled agents contribute in the order below, and the orchestrator writes the final response.")
                        .font(.callout)
                    Text("Team requests make multiple model calls and can incur additional API charges. Agents can use different providers; configure each provider’s model and API key in AI settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Orchestrator") {
                    WritingAgentFields(agent: $store.configuration.orchestrator)
                        .padding(8)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Agents").font(.headline)
                        Spacer()
                        Button("Add agent", systemImage: "plus") {
                            store.configuration.agents.append(WritingAgent(name: "New agent", instructions: ""))
                        }
                    }
                    Text("Each agent receives the plan and earlier agents’ contributions. Use the arrows to change the order.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.configuration.agents.isEmpty {
                        Text("No agents yet. The orchestrator can still plan and write the final response.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach($store.configuration.agents, id: \.id) { $agent in
                        let agentID = agent.id
                        WritingAgentCard(
                            agent: $agent,
                            canMoveUp: store.configuration.agents.first?.id != agentID,
                            canMoveDown: store.configuration.agents.last?.id != agentID,
                            moveUp: { moveAgent(agentID, by: -1) },
                            moveDown: { moveAgent(agentID, by: 1) },
                            delete: { store.configuration.agents.removeAll { $0.id == agentID } }
                        )
                    }
                }

                WritingGuidanceSection(
                    title: "Skills",
                    singular: "skill",
                    explanation: "Reusable writing methods, such as restructuring an argument or editing for clarity.",
                    guidance: $store.configuration.skills
                )
                WritingGuidanceSection(
                    title: "Rules",
                    singular: "rule",
                    explanation: "Standing instructions for tone, terminology, citations, and other writing preferences.",
                    guidance: $store.configuration.rules
                )

                Text("Changes save automatically. Enabled skills and rules guide every request, including when the team is off. Mention a skill or rule with @ in the assistant to use it for one request.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moveAgent(_ id: UUID, by offset: Int) {
        guard let index = store.configuration.agents.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard store.configuration.agents.indices.contains(destination) else { return }
        store.configuration.agents.swapAt(index, destination)
    }
}

private struct WritingAgentFields: View {
    @Binding var agent: WritingAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $agent.name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Agent name")
            SettingsInstructionEditor(title: "Instructions", text: $agent.instructions)
            Picker("Provider", selection: $agent.provider) {
                Text("Use selected provider").tag(nil as AIProvider?)
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(Optional(provider))
                }
            }
            if agent.provider != .apple {
                TextField("Model override (optional)", text: $agent.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Agent model override")
                Text("Leave blank to use this provider’s model from AI settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WritingAgentCard: View {
    @Binding var agent: WritingAgent
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let delete: () -> Void
    @State private var expanded = false

    private var displayName: String { agent.name.isEmpty ? "Untitled agent" : agent.name }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enabled", isOn: $agent.enabled)
                        .labelsHidden()
                        .accessibilityLabel("Enable \(displayName)")
                    DisclosureGroup(displayName, isExpanded: $expanded) {
                        EmptyView()
                    }
                    Spacer()
                    Button(action: moveUp) { Image(systemName: "arrow.up") }
                        .disabled(!canMoveUp)
                        .help("Move agent earlier")
                        .accessibilityLabel("Move \(displayName) earlier")
                    Button(action: moveDown) { Image(systemName: "arrow.down") }
                        .disabled(!canMoveDown)
                        .help("Move agent later")
                        .accessibilityLabel("Move \(displayName) later")
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help("Delete agent")
                        .accessibilityLabel("Delete \(displayName)")
                }
                if expanded { WritingAgentFields(agent: $agent) }
            }.padding(8)
        }
    }
}

private struct WritingGuidanceSection: View {
    let title: String
    let singular: String
    let explanation: String
    @Binding var guidance: [WritingGuidance]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Add \(singular)", systemImage: "plus") {
                    guidance.append(WritingGuidance(name: "New \(singular)", instructions: ""))
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            if guidance.isEmpty {
                Text("No \(title.lowercased()) yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($guidance, id: \.id) { $item in
                let itemID = item.id
                WritingGuidanceCard(guidance: $item, kind: singular) {
                    guidance.removeAll { $0.id == itemID }
                }
            }
        }
    }
}

private struct WritingGuidanceCard: View {
    @Binding var guidance: WritingGuidance
    let kind: String
    let delete: () -> Void
    @State private var expanded = false

    private var displayName: String { guidance.name.isEmpty ? "Untitled \(kind)" : guidance.name }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Enabled", isOn: $guidance.enabled)
                        .labelsHidden()
                        .accessibilityLabel("Enable \(displayName)")
                    DisclosureGroup(displayName, isExpanded: $expanded) {
                        EmptyView()
                    }
                    Spacer()
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help("Delete \(kind)")
                        .accessibilityLabel("Delete \(displayName)")
                }
                if expanded {
                    TextField("Name", text: $guidance.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(kind.capitalized) name")
                    SettingsInstructionEditor(title: "Instructions", text: $guidance.instructions)
                }
            }.padding(8)
        }
    }
}

private struct SettingsInstructionEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80, idealHeight: 100, maxHeight: 160)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .accessibilityLabel(title)
        }
    }
}
