import SwiftUI
import AppKit
import PandanoteCore

private let variableAccent = Color(red: 0.27, green: 0.47, blue: 0.36)

struct VariablesPanel: View {
    @ObservedObject var workspace: Workspace
    @State private var filter = ""
    @State private var collapsed: Set<String> = []
    @State private var detail: VariableDetail?

    private struct VariableDetail: Identifiable {
        let block: CodeVariableBlock
        let variable: CodeVariable
        var id: String { variable.id }
    }
    private func visibleVariables(_ block: CodeVariableBlock) -> [CodeVariable] {
        block.variables.filter {
            filter.isEmpty || ($0.name + " " + $0.type + " " + $0.preview).localizedCaseInsensitiveContains(filter)
        }
    }
    private func canUse(_ block: CodeVariableBlock) -> Bool {
        workspace.variablesMatchDocument && workspace.variablesError == nil && block.status == "current"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CODE VARIABLES").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    if workspace.variablesChecking { ProgressView().controlSize(.mini) }
                    Button { workspace.schedulePreview() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Refresh variables")
                        .help("Check saved values without running code")
                        .disabled(workspace.variablesChecking || workspace.selected == nil)
                }
                TextField("Filter variables", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .accessibilityLabel("Filter variables")
                Text("Inspect Python values and reuse them in your writing or another block.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(15)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let error = workspace.variablesError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if workspace.variableBlocks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "shippingbox").font(.system(size: 25)).foregroundStyle(variableAccent)
                            Text(workspace.variablesChecking ? "Checking this note…" : "Your values will appear here")
                                .font(.system(size: 13, weight: .medium))
                            Text("Add a Python code block and choose Run Code Blocks. Variables such as a, b, and c are captured automatically; print() is optional.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 12)
                    }
                    ForEach(workspace.variableBlocks) { block in
                        if filter.isEmpty || !visibleVariables(block).isEmpty { blockView(block) }
                    }
                    if !filter.isEmpty && workspace.variableBlocks.allSatisfy({ visibleVariables($0).isEmpty }) {
                        Text("No variables match this filter.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(14)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button { workspace.perform("run") } label: {
                    Label(workspace.busy ? "Working…" : "Run Code Blocks…", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(variableAccent)
                .disabled(workspace.busy || workspace.fileOperationInProgress || workspace.selected == nil)
                Text("Each value has a stable reference tied to its note and block. Changed code must be run again.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14)
        }
        .sheet(item: $detail) { detail in
            VariableReferenceView(variable: detail.variable, block: detail.block)
        }
        .onChange(of: workspace.selected) { _, _ in detail = nil; filter = ""; collapsed = [] }
    }

    private func blockView(_ block: CodeVariableBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Button {
                    if !collapsed.insert(block.id).inserted { collapsed.remove(block.id) }
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: collapsed.contains(block.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 9, height: 15)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.id).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("\(block.language) · Line \(block.startLine) · \(block.variables.count) values")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("\(block.id), \(block.variables.count) variables")
                Button { workspace.jumpToCodeBlock(block) } label: { Image(systemName: "arrow.up.forward") }
                    .font(.system(size: 10)).buttonStyle(.plain)
                    .help("Go to this code block")
                    .accessibilityLabel("Go to \(block.id)")
                    .disabled(!workspace.variablesMatchDocument)
            }.padding(11)

            if !collapsed.contains(block.id) {
                if !canUse(block) {
                    Label(statusText(block), systemImage: block.status == "failed" ? "exclamationmark.triangle" : "clock")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 11).padding(.bottom, 10)
                }
                if let message = block.message, !message.isEmpty, canUse(block) || message != statusText(block) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 11).padding(.bottom, 10)
                }
                ForEach(visibleVariables(block)) { variable in
                    Divider()
                    variableView(variable, block: block)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)) }
    }
    private func statusText(_ block: CodeVariableBlock) -> String {
        if workspace.variablesChecking || !workspace.variablesMatchDocument { return "Checking saved values…" }
        switch block.status {
        case "failed": return "Run failed. Run again after correcting the code."
        case "stale": return "Code or inputs changed. Run again to update values."
        default: return "Run this block to capture its variables."
        }
    }
    private func variableView(_ variable: CodeVariable, block: CodeVariableBlock) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(variable.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Text(variable.type).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    Button("Copy Preview") { copy(variable.preview) }
                    Button("Copy Markdown Reference") { copy(variable.reference) }.disabled(!canUse(block) || !variable.reusable)
                    Button("Copy Python Reference") { copy(variable.pythonReference) }.disabled(!canUse(block) || !variable.reusable)
                    if variable.formattedReference(.decimal) != nil {
                        Menu("Insert with Format") {
                            ForEach(CodeVariableFormat.allCases) { format in
                                Button(format.title) { workspace.insertVariable(variable, from: block, format: format) }
                            }
                        }.disabled(!canUse(block) || !variable.reusable || workspace.fileOperationInProgress)
                    }
                    Button("How to Use…") { detail = VariableDetail(block: block, variable: variable) }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Actions for \(variable.name)")
            }
            Text(variable.preview.isEmpty ? "[empty string]" : variable.preview)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(canUse(block) ? .primary : .secondary)
            if variable.reusable {
                Button { workspace.insertVariable(variable, from: block) } label: {
                    Label("Insert Reference", systemImage: "text.insert").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(variableAccent)
                    .disabled(!canUse(block) || workspace.fileOperationInProgress)
                    .accessibilityLabel("Insert reference to \(variable.name) from \(block.id)")
            } else {
                Text("Inspection only · Export a simple value to reuse it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(11)
    }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct VariableReferenceView: View {
    let variable: CodeVariable
    let block: CodeVariableBlock
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Use \(variable.name)").font(.title2)
            Text("From \(block.id) · \(variable.type)").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    example("Saved preview", variable.preview)
                    if variable.reusable {
                        example("In Markdown prose", variable.reference)
                        Text("Use {cell_id.variable_name} in prose. Give the cell a name with id=\"\(block.id)\" in its opening fence. Rerunning updates the value; renaming the cell or variable requires updating its references. Code examples in backticks stay literal.")
                            .font(.callout).foregroundStyle(.secondary)
                        if variable.formattedReference(.decimal) != nil {
                            ForEach(CodeVariableFormat.allCases) { format in
                                if let reference = variable.formattedReference(format) { example(format.title, reference) }
                            }
                            Text("Edit the number after the dot for 0–12 decimal places, or 1–12 significant digits with g. A comma groups thousands; + shows positive signs. Percent multiplies by 100. Formatting rounds the captured decimal value to nearest, with ties to even, and never changes the Python value. For custom text or dates, format a string in Python and reference that variable.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        example("In another Python block", "```{python depends-on=\"\(block.id)\"}\nvalue = \(variable.pythonReference)\nprint(value)\n```")
                        Text("The dependency runs first and supplies its captured value. Variables with the same name in different blocks remain separate.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    example("Legacy reference (still supported)", "{{\(variable.id)}}")
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 580, height: 560)
    }
    private func example(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                    .controlSize(.small)
            }
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
