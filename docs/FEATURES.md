# Pandanote feature inventory

Audited **13 September 2026**, source **0.3.0 (4)** at
[`ead22ed`](https://github.com/goldberg-consulting/pandanote/tree/ead22ed77ec50786179c05f179c83bb0b59ee592).
This inventory describes the native Mac application. It does not imply that a
hosted edition or complete MinkNote/Overleaf parity has shipped.

[View five screenshots of the current app](SCREENSHOTS.md).

**Implemented** means connected to the current app, with the qualifications below.
**Partial** means a useful workflow exists but the larger requested capability is
unfinished. **Remaining** means product work is still required. These are feature
groups, not equally sized tasks; a completion percentage would be misleading.

## Implemented

### Writing and organizing

- **Native Mac workspace:** SwiftUI/AppKit source editor, PDFKit PDF viewer,
  system WebKit reading preview, and the panda icon with its mohawk and red eye.
- **Source, reading, and split layouts:** Markdown syntax coloring, configurable
  font/size, light/dark/system appearance, focus mode, spelling, native Undo,
  and access to macOS Writing Tools where available.
- **Ordinary files:** Markdown, plain text, LaTeX, and BibTeX notes; nested folders;
  recent-vault switching; document tabs; favorites and pins.
- **Navigation:** heading outline, word count, reading time, note links and
  backlinks, text search, tags, folder filters, and task filtering.
- **Comfortable click targets:** rectangular note cards, tabs, folder/filter
  rows, outline items, references, and change entries respond across their area.
- **File and editor actions:** create, rename, duplicate, move, recoverable Trash,
  reveal in Finder, copy paths, tab management, format text, duplicate/delete
  lines, and extract a selected passage into a linked sibling note.
- **Attachments:** image/file drops, clipboard images, collision-resistant
  sibling `i/` storage, and HTML export embedding supported local images.
- **Save and recovery:** autosave, manual save, up to 100 local history snapshots
  per note, coordinated writes, and explicit external-edit conflict recovery.
- **Search launcher:** global shortcut while the app runs, installed-application
  and current-vault filename/path search, keyboard navigation, and workspace
  restoration. This is separate from note-content search.
- **Find and replace:** current note, captured selection, or vault; multiline,
  regular expressions, case/whole-word options, path filters, match navigation,
  highlighted results, replacement previews, per-file inclusion, backups, and
  guarded batch undo.

### Inkwell publishing

- **Shared publishing engine:** the vendored Inkwell engine runs in a separate
  Node process, with workspace setup/migration, template discovery, bibliography
  lookup, and local tool discovery.
- **Configurable preamble:** guided document, template-field, typography, table,
  reference, code, and custom-LaTeX controls; starter settings; field guidance;
  complete YAML editing; validation and preview of preamble changes. Settings
  remain portable in the document, preserving custom metadata and its body.
- **PDF workflow:** real compilation and native viewing, persistent background
  activity, build-source snapshots, stale-output indication, full logs on disk,
  and preservation of the last good PDF after a failed build. Users can keep
  editing or navigate during compilation; completion offers **View PDF**.
- **Executable documents:** explicit Python, R, shell, and Node block execution,
  cached results, provenance, and insertion of results into published documents.
  Normal preview does not execute document code.
- **Python variables:** inspect names/types/values and originating blocks, insert
  stable references into prose, reuse supported typed values in dependent blocks,
  and detect stale or invalid results. Each block runs in its own interpreter.
- **Math and references:** math preview and Inkwell PDF typesetting, bibliography
  keys, template-driven citations/cross-references in publishing, and the upstream
  currency-versus-math delimiter correction.

### AI and change management

- **Provider choice:** Apple Foundation Models, Ollama, OpenAI GPT, Anthropic
  Claude, and compatible endpoints; configurable models and provider-specific
  Keychain credentials.
- **Passage context:** highlight text and attach it to the assistant. The passage
  remains attached while writing a prompt; snapshot checks prevent applying a
  revision to changed text or the wrong note.
- **Mentions:** use `@` to attach notes, agents, skills, and rules. Context chips
  make the attached material visible and removable.
- **Reviewable revisions:** reword, shorten, proofread, or give custom directions;
  inspect a diff, edit the proposal, accept/reject/defer it, and undo an accepted
  replacement as one native edit. Review decisions persist with the vault.
- **Writing teams:** configurable orchestrator, up to eight ordered agents,
  provider/model overrides, reusable prose skills, standing rules, stage progress,
  and cancellation. Earlier contributions feed later stages and the final response.
- **Local Git:** initialize a repository, inspect working-file changes and commit
  history, and commit selected files while preserving unrelated staged content.
  Commit and proposal application check the exact reviewed content.

## Partially complete

- **Visual editing:** reading preview exists but is read-only. A lossless visual
  Markdown editor, with formatting retained when switching modes, remains.
- **Full Inkwell interface:** the engine has capabilities beyond the current
  panels. Still needed: bibliography-entry editing, toolchain installation/repair,
  environment setup, per-block execution/cancellation controls, cache inspection,
  clickable source diagnostics, and complete draft citation/cross-reference parity.
- **LaTeX project support:** `.tex`/`.bib` files open, and direct `.tex` builds use
  **XeLaTeX**. Markdown templates may choose other engines. This is not yet a
  general Overleaf-compatible project manager: compiler/version selection, a
  main-document setting, `.sty`/`.cls` editing in the library, and SyncTeX are missing.
- **Code tooling:** Python variable reuse is implemented for bounded supported
  values; it is not a shared notebook kernel or arbitrary-object transfer.
  Matching variable inspection/reuse for R, Node, and shell remains.
- **Note-link publishing:** draft `[[note links]]` navigate between notes, but the
  gallery's compiled PDF still contains the literal wiki-link notation. Resolve
  links appropriately when publishing a note or a collection.
- **Git workflow:** local review and commits exist. Remote fetch/push, branches,
  merge conflict resolution, hooks, and signed commits require an external Git
  client. Merge/rebase states and signed-commit requirements are refused by the app.
- **Tracked changes:** AI proposals and local history exist. Continuous tracking
  of every author's edits, anchored discussion threads, reviewer roles, and shared
  accept/reject workflows do not yet exist.
- **Folder organization:** context-menu moves work and update app navigation.
  Link rewriting and relative attachment relocation on moves, plus drag-to-organize
  behavior, remain unfinished.
- **Cloud folders:** a vault can live in a synced folder. Provider-specific sync,
  offline placeholders, and multi-device conflict behavior have not been validated.
- **AI portability:** teams/guidance are local preferences; shared project rules,
  team configuration export/sync, and tool-using agents remain. Current agents
  generate text and do not run tools. Live GPT/Claude account checks remain separate
  from the passing protocol fixtures and injected-response tests.
- **Distribution:** build/signing/notarization tooling exists. The README records
  notarization of the current 0.3.0 package as pending; earlier builds' tickets do
  not certify this one. A public installer/update channel remains to be completed.

## Remaining native product work

The original scope includes the reference product's planned features as well as
its released ones. The principal remaining groups are folding and task ordering;
independent document windows; richer media/diagram preview; advanced library
filters and saved/recent searches; theme and journal customization; bulk metadata;
dictation/OCR; encrypted notes and biometric access; clipping and sharing
extensions; publishing; and mobile/Pencil support. Source reference:
[MinkNote roadmap](https://muse23.com/apps/minknote/roadmap.html).

Specific follow-through:

- [ ] Visual editor and documented Markdown round-trip guarantees.
- [ ] Heading/code folding, task reordering, and independent window workspaces.
- [ ] Drag organization with link and attachment repair; richer attachment previews,
  embedded media, and Mermaid rendering in the draft.
- [ ] Saved searches, launcher recent-search history, image-focused filtering,
  customizable library grouping, journal appearance, and broader themes.
- [ ] Batch metadata edits, transcription, image text recognition, and optional
  location metadata/writing achievements.
- [ ] Note encryption/biometrics, share extension, web clipping, rich-paste
  conversion, and publishing to a shareable note URL.
- [ ] Tested cloud-provider behavior and independent iPhone/iPad/Pencil clients.
- [ ] Guided installation of publishing prerequisites, all-template preview/PDF
  checks, accessibility/keyboard audit, and broader device/OS release testing.
- [ ] UI polish from the gallery session: the PDF toolbar's Preview picker label
  clips. Exercise toolbar layouts and text sizing across window widths.

## Hosted edition and ShareLaTeX compatibility

**Not implemented:** browser client, accounts, hosted project storage, server
compilation, multi-user live editing, comments/reviewer roles, project invitations,
remote Git synchronization, or desktop/web synchronization.

Keep the native Mac app and add a browser client around the shared Inkwell engine
and a portable project format. Full LaTeX project portability and collaborative
review are distinct milestones; neither follows merely from displaying a PDF in
a browser. The [web roadmap](WEB-ROADMAP.md) defines requirements and acceptance
checks for both.

## Evidence and limits

The source review covered [workspace/editor UI](../Sources/Pandanote/WorkspaceView.swift),
[document settings](../Sources/Pandanote/DocumentSettings.swift),
[assistant context](../Sources/Pandanote/AssistantPanel.swift),
[team execution](../Sources/PandanoteCore/WritingTeam.swift),
[search](../Sources/Pandanote/FindReplaceController.swift),
[Git transactions](../Sources/PandanoteCore/GitRepository.swift),
[native engine bridge](../Engine/src/bridge.ts), and
[upstream compilation](../Vendor/Inkwell/src/compiler.ts).

The most recent source verification recorded **132 Swift tests and 30 engine
tests passing**. These cover important recovery, background publishing, search,
AI context, Git, and variable workflows, but do not establish full product parity.
See the [README verification notes](../README.md#verification) for live checks and
test details. This documentation-only audit does not claim a fresh run of every
feature, all external AI providers, or every publishing template.
