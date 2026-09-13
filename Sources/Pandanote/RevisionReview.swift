import SwiftUI
import PandanoteCore

struct RevisionReviewView: View {
    @ObservedObject var workspace: Workspace
    @State var proposal: ChangeProposal
    @State private var editing = false
    @Environment(\.dismiss) var dismiss
    var stale: Bool { workspace.relativePath != proposal.relativePath || workspace.text != proposal.base }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Review revision").font(.title2)
                    Text("\(proposal.relativePath) · \(proposal.provider)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review later") { dismiss() }
            }.padding(22)
            Text(proposal.instruction).font(.callout).padding(.horizontal, 22).padding(.bottom, 14)
            if stale { Text("This proposal belongs to an earlier version or another document. Your current text is preserved. Reopen its document or request a fresh revision.").font(.callout).foregroundStyle(.orange).padding(.horizontal, 22).padding(.bottom, 14) }
            Divider()
            HSplitView {
                ScrollView { DiffContent(before: proposal.original, after: proposal.replacement).padding(14) }.frame(minWidth: 420)
                if editing { VStack(alignment: .leading) { Text("Edit the proposed replacement").font(.headline); TextEditor(text: $proposal.replacement).font(.system(size: 13, design: .monospaced)) }.padding(16).frame(minWidth: 280) }
            }
            Divider()
            HStack {
                Toggle("Edit replacement", isOn: $editing).toggleStyle(.checkbox)
                Text("Green adds text. Red removes text.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reject") { workspace.rejectProposal(proposal) }
                Button("Accept revision") { Task { if await workspace.acceptProposal(proposal) { dismiss() } } }.buttonStyle(.borderedProminent).disabled(stale || proposal.decision != "pending" || proposal.replacement == proposal.original)
            }.padding(18)
        }.frame(width: editing ? 1050 : 800, height: 640)
            .onChange(of: proposal.replacement) { _, _ in if let vault = workspace.vault { do { try ChangeArchive(vault: vault).store(proposal) } catch { workspace.error = error.localizedDescription } } }
    }
}
