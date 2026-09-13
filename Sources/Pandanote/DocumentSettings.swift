import SwiftUI
import PandanoteCore

struct PublicationControl: Decodable, Identifiable {
    var id: String { key }
    let key: String, label: String, group: String, value: String, prompt: String, kind: String
    let allowed: [String]?
    let locked: Bool?
    let reason: String?
    let source: String?
}
struct PublicationSettings: Decodable {
    let template: String, templateName: String, engine: String, yaml: String, templateExample: String
    let hasFrontmatter: Bool
    let controls: [PublicationControl]
    let diagnostics: [Diagnostic]
    struct Diagnostic: Decodable { let message: String, severity: String }
}

@MainActor final class DocumentSettingsModel: ObservableObject {
    @Published var settings: PublicationSettings?
    @Published var changes: [String: String] = [:]
    @Published var yaml = ""
    @Published var template = ""
    @Published var group = "Document"
    @Published var draft: String
    @Published var busy = false
    @Published var error: String?
    @Published var yamlChanged = false
    let base: String
    let file: URL?
    let root: URL?
    init(workspace: Workspace) { base = workspace.text; draft = workspace.text; file = workspace.selected; root = workspace.root }
    var hasPending: Bool { !changes.isEmpty || yamlChanged || template != settings?.template }
    func load(workspace: Workspace, parameters: [String: Any]? = nil) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let data = try await workspace.engineRequest(parameters == nil ? "settings" : "edit-settings", text: draft, root: root, file: file, parameters: parameters ?? [:])
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if result["success"] as? Bool != true { throw EngineFailure.failed(result["message"] as? String ?? "Settings could not be read.") }
            settings = try JSONDecoder().decode(PublicationSettings.self, from: data)
            if let text = result["text"] as? String { draft = text }
            yaml = settings!.yaml; template = settings!.template; changes = [:]; yamlChanged = false
        } catch { self.error = error.localizedDescription }
    }
    func preview(workspace: Workspace) async {
        if yamlChanged { await load(workspace: workspace, parameters: ["yaml":yaml]) }
        else { await load(workspace: workspace, parameters: ["template":template, "changes":changes.map { ["key":$0.key, "value":$0.value] }]) }
    }
}

struct DocumentSettingsView: View {
    @ObservedObject var workspace: Workspace
    @StateObject private var model: DocumentSettingsModel
    @Environment(\.dismiss) var dismiss
    init(workspace: Workspace) { self.workspace = workspace; _model = StateObject(wrappedValue: DocumentSettingsModel(workspace: workspace)) }
    let groups = ["Document", "Template fields", "Typography", "Tables", "References", "Code", "LaTeX", "YAML", "Changes", "Template example"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Inkwell document settings").font(.title2)
                    Text("Saved in this note’s preamble. The same settings travel with your file and control Inkwell’s PDF.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            HSplitView {
                List(groups, id: \.self, selection: $model.group) { Text($0).tag($0) }.frame(width: 145)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let settings = model.settings {
                            Label("\(settings.templateName) · \(settings.engine)", systemImage: "doc.badge.gearshape").font(.headline)
                            if !settings.hasFrontmatter {
                                Text("This note has no preamble, so Inkwell uses inherited defaults. Add starter settings or change any control to create one.").font(.callout)
                            }
                            if model.group == "Document" {
                                Picker("Publication template", selection: $model.template) {
                                    ForEach(workspace.templates, id: \.["id"]) { item in Text(item["name"] ?? "Template").tag(item["id"] ?? "default") }
                                }
                                Text("Choose a template, then Update preview to load its controls. Journal templates can lock their own fonts and layout.").font(.caption).foregroundStyle(.secondary)
                                Button("Add starter settings to draft") { Task { await model.load(workspace: workspace, parameters: ["template":model.template,"starter":true]) } }.disabled(model.hasPending)
                            }
                            if model.group == "YAML" {
                                Text("The complete preamble, including any custom Inkwell options. Keep the --- delimiters in the document; edit only the settings here. Validate with Update preview before applying.").font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: Binding(get: { model.yaml }, set: { model.yaml = $0; model.yamlChanged = true })).font(.system(size: 12, design: .monospaced)).frame(minHeight: 350)
                            } else if model.group == "Template example" {
                                Text("Inkwell’s template-specific example. These are placeholders, not your publication details. Copy needed fields into YAML and replace the example names and identifiers.").font(.caption).foregroundStyle(.secondary)
                                Text(settings.templateExample).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            } else if model.group == "Changes" {
                                Text("Review the preamble changes before applying them. Your document body remains unchanged.").font(.caption).foregroundStyle(.secondary)
                                DiffContent(before: model.base, after: model.draft)
                            } else {
                                if model.group == "Template fields", settings.controls.allSatisfy({ $0.group != "Template fields" }) { Text("This template uses the standard Document controls. Custom metadata can be added in YAML.").foregroundStyle(.secondary) }
                                ForEach(settings.controls.filter { $0.group == model.group }) { control in field(control) }
                            }
                            ForEach(Array(settings.diagnostics.enumerated()), id: \.offset) { _, diagnostic in Text(diagnostic.message).font(.caption).foregroundStyle(diagnostic.severity == "error" ? .red : .orange) }
                        } else if !model.busy { Text("Document settings are unavailable.") }
                        if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 550)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.hasPending ? "Update the preview to validate your changes." : "Draft preview approximates typography; the compiled PDF is authoritative.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Update preview") { Task { await model.preview(workspace: workspace); if model.error == nil { model.group = "Changes" } } }.disabled(model.busy || !model.hasPending)
                Button("Apply to document") {
                    Task { if await workspace.applyDocumentChange(model.draft, base: model.base, file: model.file, label: "Document settings") { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(model.busy || model.hasPending || model.draft == model.base)
            }.padding(18)
        }.frame(width: 930, height: 730).task { await model.load(workspace: workspace) }
    }
    @ViewBuilder func field(_ control: PublicationControl) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(control.label).font(.system(size: 13, weight: .semibold)); if control.locked == true { Image(systemName: "lock.fill").font(.caption) }; Spacer(); Text(control.source ?? "template").font(.caption2).foregroundStyle(.tertiary) }
            let binding = Binding(get: { model.changes[control.key] ?? control.value }, set: { if $0 == control.value { model.changes.removeValue(forKey: control.key) } else { model.changes[control.key] = $0 } })
            if control.locked == true { Text(control.value).foregroundStyle(.secondary) }
            else if control.kind == "boolean" { Toggle("Enabled", isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = String($0) })).toggleStyle(.switch).controlSize(.small) }
            else if let allowed = control.allowed { Picker(control.label, selection: binding) { if !allowed.contains(binding.wrappedValue) { Text(binding.wrappedValue.isEmpty ? "Inherited" : binding.wrappedValue).tag(binding.wrappedValue) }; ForEach(allowed, id: \.self) { Text($0).tag($0) } }.labelsHidden() }
            else if ["multiline", "lines", "yaml"].contains(control.kind) { TextEditor(text: binding).font(.system(size: 12, design: .monospaced)).frame(height: control.key == "header-includes" || control.kind == "yaml" ? 180 : 80).overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator)) }
            else { TextField(control.prompt, text: binding).textFieldStyle(.roundedBorder) }
            Text(control.reason ?? control.prompt).font(.caption).foregroundStyle(.secondary)
        }.disabled(model.yamlChanged || model.template != model.settings?.template)
    }
}

struct DiffContent: View {
    let before: String, after: String
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(TextDiff.lines(before: before, after: after)) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.kind).foregroundStyle(line.kind == "+" ? .green : line.kind == "-" ? .red : .secondary).frame(width: 12)
                    Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 3).background(line.kind == "+" ? Color.green.opacity(0.09) : line.kind == "-" ? Color.red.opacity(0.09) : .clear)
            }
        }
    }
}
