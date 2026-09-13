import SwiftUI
import PandanoteCore
import AppKit
import WebKit
import PDFKit

struct NativeEditor: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var findReplace: FindReplaceController
    @AppStorage("editorFontSize") var fontSize = 14.0
    @AppStorage("editorFont") var fontName = "SF Mono"
    init(workspace: Workspace) {
        self.workspace = workspace
        self.findReplace = workspace.findReplace
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let editor = MarkdownTextView()
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = true; editor.usesFindBar = false; editor.isIncrementalSearchingEnabled = false
        editor.writingToolsBehavior = .complete
        editor.textContainerInset = NSSize(width: 26, height: 26)
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.onFile = { [weak workspace] url in workspace?.addAttachment(url) }
        editor.onAskAI = { [weak workspace] range in
            guard let workspace else { return }
            workspace.selection = range
            workspace.assistant.captureSelection(workspace: workspace)
        }
        editor.canRefactor = { [weak workspace] in
            guard let workspace else { return false }
            return workspace.selected != nil && !workspace.assistant.busy && !workspace.fileOperationInProgress
        }
        editor.onRefactor = { [weak workspace] range, instruction in
            guard let workspace, !workspace.assistant.busy, !workspace.fileOperationInProgress else { return }
            workspace.selection = range
            workspace.assistant.captureSelection(workspace: workspace)
            guard workspace.assistant.error == nil else { return }
            workspace.assistant.ask(workspace: workspace, instruction: instruction, revision: true)
        }
        editor.canExtractSelection = { [weak workspace] in
            guard let workspace else { return false }
            return workspace.selected != nil && !workspace.fileOperationInProgress
        }
        editor.onExtractSelection = { [weak workspace] range in
            guard let workspace else { return }
            workspace.selection = range
            workspace.extractSelectionToNote()
        }
        editor.hasDocument = { [weak workspace] in workspace?.selected != nil }
        editor.onRevealInFinder = { [weak workspace] in
            guard let workspace, let file = workspace.selected else { return }
            workspace.revealInFinder(file)
        }
        editor.onCopyPath = { [weak workspace] relative in
            guard let workspace, let file = workspace.selected else { return }
            workspace.copyPath(file, relative: relative)
        }
        editor.onFind = { [weak workspace] replace, selectedText in
            workspace?.openFind(replace: replace, selectedText: selectedText)
        }
        editor.onFindNext = { [weak findReplace] in findReplace?.nextMatch() }
        editor.onFindPrevious = { [weak findReplace] in findReplace?.previousMatch() }
        editor.onCloseFind = { [weak findReplace] in findReplace?.close() }
        editor.canNavigateSearch = { [weak findReplace] in
            guard let findReplace else { return false }
            return findReplace.totalMatchCount > 0 && !findReplace.isSearching && !findReplace.isApplying
        }
        editor.setAccessibilityLabel("Markdown editor")
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? MarkdownTextView else { return }
        editor.isEditable = !workspace.fileOperationInProgress
        let changedDocument = context.coordinator.file != workspace.selected
        if changedDocument { editor.undoManager?.removeAllActions() }
        if editor.string != workspace.text {
            let selection = editor.selectedRange()
            context.coordinator.updating = true
            if !changedDocument, let change = workspace.pendingReplacement, change.file == workspace.selected, change.before == editor.string, change.after == workspace.text {
                editor.replaceDocumentText(change.after, undoLabel: change.label)
                workspace.pendingReplacement = nil
            } else { editor.replaceDocumentText(workspace.text); workspace.pendingReplacement = nil }
            if changedDocument { editor.undoManager?.removeAllActions(); editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.scrollToBeginningOfDocument(nil) }
            else { editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0)) }
            context.coordinator.updating = false
            let file = workspace.selected, range = editor.selectedRange()
            Task { @MainActor [weak workspace, weak editor] in
                guard let workspace, workspace.selected == file, editor?.selectedRange() == range else { return }
                workspace.selection = range
            }
        }
        context.coordinator.file = workspace.selected
        context.coordinator.highlight()
        if let jump = workspace.jump {
            editor.setSelectedRange(NSRange(location: min(jump, (editor.string as NSString).length), length: 0)); editor.scrollRangeToVisible(editor.selectedRange()); editor.window?.makeFirstResponder(editor)
            Task { @MainActor [weak workspace] in
                if workspace?.jump == jump { workspace?.jump = nil }
            }
        }
        if let insertion = workspace.editorInsertion {
            Task { @MainActor [weak workspace, weak editor] in
                guard let workspace, let editor, workspace.editorInsertion == insertion, !workspace.fileOperationInProgress else { return }
                workspace.editorInsertion = nil
                editor.insertText(insertion, replacementRange: editor.selectedRange())
                editor.window?.makeFirstResponder(editor)
            }
        }
        if let file = workspace.selected {
            editor.showSearchMatches(findReplace.currentMatches(for: file, source: editor.string),
                                     active: findReplace.activeMatch(for: file, source: editor.string), source: editor.string)
        } else { editor.clearSearchHighlights() }
        if let navigation = findReplace.navigation, context.coordinator.handledSearchNavigation != navigation.id {
            context.coordinator.handledSearchNavigation = navigation.id
            context.coordinator.updating = true
            let applied = editor.selectSearchMatch(navigation.range, in: navigation.file, source: navigation.source,
                                                   currentFile: workspace.selected, focusEditor: navigation.focusEditor)
            context.coordinator.updating = false
            Task { @MainActor [weak workspace, weak findReplace, weak editor] in
                if applied, let workspace, workspace.selected == navigation.file, editor?.string == navigation.source,
                   editor?.selectedRange() == navigation.range {
                    workspace.selection = navigation.range
                }
                findReplace?.consumeNavigation(id: navigation.id)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        weak var editor: NSTextView?
        var updating = false
        var file: URL?
        var lastHighlight = ""
        var lastSize = 0.0
        var lastFont = ""
        var handledSearchNavigation: UUID?
        init(_ parent: NativeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor else { return }
            parent.workspace.edit(editor.string); highlight()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor else { return }
            parent.workspace.selection = editor.selectedRange()
        }
        func highlight() {
            guard let editor, let storage = editor.textStorage else { return }
            // Input methods and inline completion own the marked text's
            // attributes until composition finishes.
            guard !editor.hasMarkedText() else { return }
            guard editor.string != lastHighlight || parent.fontSize != lastSize || parent.fontName != lastFont else { return }
            lastHighlight = editor.string; lastSize = parent.fontSize; lastFont = parent.fontName
            let font = NSFont(name: parent.fontName, size: parent.fontSize) ?? NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            editor.font = font; editor.backgroundColor = .textBackgroundColor; editor.insertionPointColor = .labelColor
            let all = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 6
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: all)
            let rules: [(String, NSColor)] = [
                ("(?s)\\A---\\n.*?\\n---", .secondaryLabelColor),
                ("(?m)^#{1,6} .*$", NSColor(calibratedRed: 0.30, green: 0.53, blue: 0.39, alpha: 1)),
                ("(?m)^>.*$", .secondaryLabelColor),
                ("`[^`\\n]+`", .systemOrange),
                ("\\*\\*[^*]+\\*\\*", .systemBrown),
                ("\\[.*?\\]\\(.*?\\)|\\[\\[.*?\\]\\]|@[\\w:-]+", .systemTeal),
                ("(?m)^```.*$", .systemPurple),
                ("\\$[^$\\n]+\\$", .systemPurple)
            ]
            for (pattern, color) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: editor.string, range: all) { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
            }
            storage.endEditing()
            editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        }
    }
}

final class MarkdownTextView: NSTextView {
    var onFile: ((URL) -> Void)?
    var onAskAI: ((NSRange) -> Void)?
    var onRefactor: ((NSRange, String) -> Void)?
    var canRefactor: (() -> Bool)?
    var onExtractSelection: ((NSRange) -> Void)?
    var canExtractSelection: (() -> Bool)?
    var hasDocument: (() -> Bool)?
    var onRevealInFinder: (() -> Void)?
    var onCopyPath: ((Bool) -> Void)?
    var onFind: ((Bool, String?) -> Void)?
    var onFindNext: (() -> Void)?
    var onFindPrevious: (() -> Void)?
    var onCloseFind: (() -> Void)?
    var canNavigateSearch: (() -> Bool)?
    static let maximumHighlightedSearchMatches = 2_000
    private static let searchHighlightKey = NSAttributedString.Key("PandanoteSearchHighlight")
    private var searchHighlightSource: String?
    private var searchHighlightRanges: [NSRange] = []
    private var activeSearchHighlight: NSRange?

    /// AppKit keeps marked ranges and typing-undo ranges in the old document.
    /// Finish that input session while those ranges are still valid, before a
    /// file switch, reload, or whole-document replacement can shorten the text.
    func replaceDocumentText(_ replacement: String, undoLabel: String? = nil) {
        if hasMarkedText() {
            unmarkText()
            inputContext?.discardMarkedText()
        }
        breakUndoCoalescing()
        if let undoLabel {
            let wasEditable = isEditable
            isEditable = true
            defer { isEditable = wasEditable }
            undoManager?.beginUndoGrouping()
            insertText(replacement, replacementRange: NSRange(location: 0, length: (string as NSString).length))
            undoManager?.setActionName(undoLabel)
            undoManager?.endUndoGrouping()
        } else {
            undoManager?.removeAllActions()
            string = replacement
            undoManager?.removeAllActions()
        }
        breakUndoCoalescing()
    }

    private var hasSelection: Bool { AIPassageContext.isValid(range: selectedRange(), in: string) }
    private var hasAISelection: Bool {
        isEditable && onAskAI != nil && hasSelection
    }
    private var canRefactorSelection: Bool {
        isEditable && hasSelection && onRefactor != nil && (canRefactor?() ?? true)
    }
    private var canExtract: Bool {
        isEditable && hasSelection && onExtractSelection != nil && (canExtractSelection?() ?? true)
    }
    private var editableSelection: NSRange? {
        let range = selectedRange()
        return isEditable && isValidTextRange(range) ? range : nil
    }
    private func isValidTextRange(_ range: NSRange) -> Bool {
        let source = string as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location else { return false }
        if range.length > 0 { return AIPassageContext.isValid(range: range, in: string) }
        if range.location > 0, range.location < source.length,
           (0xD800...0xDBFF).contains(source.character(at: range.location - 1)),
           (0xDC00...0xDFFF).contains(source.character(at: range.location)) { return false }
        return true
    }

    func showSearchMatches(_ matches: [NSRange], active: NSRange?, source: String) {
        guard source == string, let layoutManager else { clearSearchHighlights(); return }
        let visibleMatches = matches.prefix(Self.maximumHighlightedSearchMatches).filter { $0.length > 0 && isValidTextRange($0) }
        let activeRange = active.flatMap { $0.length > 0 && isValidTextRange($0) ? $0 : nil }
        guard searchHighlightSource != source || searchHighlightRanges != visibleMatches || activeSearchHighlight != activeRange else { return }
        clearSearchHighlights()
        searchHighlightSource = source
        searchHighlightRanges = visibleMatches
        activeSearchHighlight = activeRange
        for range in visibleMatches {
            layoutManager.addTemporaryAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.25), Self.searchHighlightKey: true], forCharacterRange: range)
        }
        if let activeRange {
            layoutManager.addTemporaryAttributes([.backgroundColor: NSColor.systemOrange.withAlphaComponent(0.55), Self.searchHighlightKey: true], forCharacterRange: activeRange)
        }
    }

    func clearSearchHighlights() {
        defer { searchHighlightSource = nil; searchHighlightRanges = []; activeSearchHighlight = nil }
        guard let layoutManager else { return }
        let length = (string as NSString).length
        var offset = 0
        while offset < length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let marker = layoutManager.temporaryAttribute(Self.searchHighlightKey, atCharacterIndex: offset, effectiveRange: &effectiveRange)
            let end = min(length, NSMaxRange(effectiveRange))
            if marker != nil {
                let range = NSRange(location: offset, length: max(0, end - offset))
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                layoutManager.removeTemporaryAttribute(Self.searchHighlightKey, forCharacterRange: range)
            }
            offset = max(offset + 1, end)
        }
    }

    @discardableResult func selectSearchMatch(_ range: NSRange, in expectedFile: URL, source expectedSource: String,
                                             currentFile: URL?, focusEditor: Bool) -> Bool {
        guard currentFile == expectedFile, string == expectedSource, isValidTextRange(range) else { return false }
        setSelectedRange(range)
        scrollRangeToVisible(range)
        if focusEditor { window?.makeFirstResponder(self) }
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        let refactor = NSMenu(title: "Refactor")
        for (title, instruction) in [
            ("Reword", "Reword this passage for clarity while preserving its meaning and voice."),
            ("Shorten", "Shorten this passage while preserving its essential meaning, evidence, and citations."),
            ("Proofread", "Proofread this passage. Correct grammar, spelling, and punctuation while preserving the author's voice and meaning.")
        ] {
            let item = menuItem(title, action: #selector(refactorSelection(_:)))
            item.representedObject = instruction
            refactor.addItem(item)
        }
        refactor.addItem(.separator())
        refactor.addItem(menuItem("Extract Selection to New Note…", action: #selector(extractSelection(_:))))
        let refactorItem = NSMenuItem(title: "Refactor", action: nil, keyEquivalent: "")
        refactorItem.submenu = refactor

        let format = NSMenu(title: "Format")
        format.addItem(menuItem("Bold", action: #selector(makeSelectionBold(_:))))
        format.addItem(menuItem("Italic", action: #selector(makeSelectionItalic(_:))))
        format.addItem(menuItem("Inline Code", action: #selector(makeSelectionInlineCode(_:))))
        let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        formatItem.submenu = format

        let items = [
            menuItem("Ask AI about Selection", action: #selector(askAIAboutSelection(_:))),
            refactorItem,
            formatItem,
            NSMenuItem.separator(),
            menuItem("Duplicate Lines", action: #selector(duplicateSelectedLines(_:))),
            menuItem("Delete Lines", action: #selector(deleteSelectedLines(_:))),
            NSMenuItem.separator(),
            menuItem("Find Selected Text", action: #selector(findSelectedText(_:))),
            menuItem("Find and Replace…", action: #selector(findAndReplace(_:))),
            NSMenuItem.separator()
        ]
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        menu.addItem(.separator())
        menu.addItem(menuItem("Reveal in Finder", action: #selector(revealInFinder(_:))))
        menu.addItem(menuItem("Copy Path", action: #selector(copyFilePath(_:))))
        menu.addItem(menuItem("Copy Relative Path", action: #selector(copyRelativeFilePath(_:))))
        return menu
    }
    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = validateUserInterfaceItem(item)
        return item
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(askAIAboutSelection(_:)): return hasAISelection
        case #selector(refactorSelection(_:)): return canRefactorSelection
        case #selector(extractSelection(_:)): return canExtract
        case #selector(makeSelectionBold(_:)), #selector(makeSelectionItalic(_:)),
             #selector(makeSelectionInlineCode(_:)), #selector(duplicateSelectedLines(_:)):
            return editableSelection != nil
        case #selector(deleteSelectedLines(_:)): return editableSelection != nil && !string.isEmpty
        case #selector(revealInFinder(_:)): return hasDocument?() == true && onRevealInFinder != nil
        case #selector(copyFilePath(_:)), #selector(copyRelativeFilePath(_:)):
            return hasDocument?() == true && onCopyPath != nil
        case #selector(findSelectedText(_:)): return hasDocument?() == true && onFind != nil && hasSelection
        case #selector(findAndReplace(_:)): return hasDocument?() == true && onFind != nil
        case #selector(performTextFinderAction(_:)):
            switch NSTextFinder.Action(rawValue: item.tag) {
            case .showFindInterface, .showReplaceInterface: return hasDocument?() == true && onFind != nil
            case .setSearchString: return hasDocument?() == true && onFind != nil && hasSelection
            case .nextMatch: return onFindNext != nil && (canNavigateSearch?() ?? true)
            case .previousMatch: return onFindPrevious != nil && (canNavigateSearch?() ?? true)
            case .hideFindInterface: return onCloseFind != nil
            default: return false
            }
        default: return super.validateUserInterfaceItem(item)
        }
    }
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem, validateUserInterfaceItem(item) else { return }
        switch NSTextFinder.Action(rawValue: item.tag) {
        case .showFindInterface: onFind?(false, nil)
        case .showReplaceInterface: findAndReplace(sender)
        case .setSearchString: findSelectedText(sender)
        case .nextMatch: onFindNext?()
        case .previousMatch: onFindPrevious?()
        case .hideFindInterface: onCloseFind?()
        default: break
        }
    }
    @objc private func askAIAboutSelection(_ sender: Any?) {
        guard hasAISelection else { return }
        onAskAI?(selectedRange())
    }
    @objc private func refactorSelection(_ sender: NSMenuItem) {
        guard canRefactorSelection, let instruction = sender.representedObject as? String else { return }
        onRefactor?(selectedRange(), instruction)
    }
    @objc private func extractSelection(_ sender: Any?) {
        guard canExtract else { return }
        onExtractSelection?(selectedRange())
    }
    @objc private func revealInFinder(_ sender: Any?) {
        guard hasDocument?() == true else { return }
        onRevealInFinder?()
    }
    @objc private func copyFilePath(_ sender: Any?) {
        guard hasDocument?() == true else { return }
        onCopyPath?(false)
    }
    @objc private func copyRelativeFilePath(_ sender: Any?) {
        guard hasDocument?() == true else { return }
        onCopyPath?(true)
    }
    @objc func findSelectedText(_ sender: Any?) {
        guard hasDocument?() == true, hasSelection else { return }
        onFind?(false, (string as NSString).substring(with: selectedRange()))
    }
    @objc func findAndReplace(_ sender: Any?) {
        guard hasDocument?() == true else { return }
        onFind?(true, nil)
    }
    @objc func makeSelectionBold(_ sender: Any?) { toggleMarkup("**", label: "Bold") }
    @objc func makeSelectionItalic(_ sender: Any?) { toggleMarkup("_", label: "Italic") }
    @objc func makeSelectionInlineCode(_ sender: Any?) { toggleMarkup("`", label: "Inline Code") }

    private func toggleMarkup(_ marker: String, label: String) {
        guard let selection = editableSelection else { return }
        let source = string as NSString
        let selected = source.substring(with: selection), markerLength = (marker as NSString).length
        if selection.length >= markerLength * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let content = (selected as NSString).substring(with: NSRange(location: markerLength, length: selection.length - markerLength * 2))
            replace(selection, with: content, selection: NSRange(location: selection.location, length: (content as NSString).length), label: label)
        } else if selection.location >= markerLength, NSMaxRange(selection) <= source.length - markerLength,
                  source.substring(with: NSRange(location: selection.location - markerLength, length: markerLength)) == marker,
                  source.substring(with: NSRange(location: NSMaxRange(selection), length: markerLength)) == marker {
            let enclosing = NSRange(location: selection.location - markerLength, length: selection.length + markerLength * 2)
            replace(enclosing, with: selected, selection: NSRange(location: enclosing.location, length: selection.length), label: label)
        } else {
            replace(selection, with: marker + selected + marker,
                    selection: NSRange(location: selection.location + markerLength, length: selection.length), label: label)
        }
    }

    @objc func duplicateSelectedLines(_ sender: Any?) {
        guard let selection = editableSelection else { return }
        let source = string as NSString, lines = selectedLineRange(selection)
        let content = source.substring(with: lines)
        let separator = content.last?.isNewline == true ? "" : preferredLineEnding
        let insertion = NSRange(location: NSMaxRange(lines), length: 0)
        let nextSelection = NSRange(location: insertion.location + (separator as NSString).length + selection.location - lines.location, length: selection.length)
        replace(insertion, with: separator + content, selection: nextSelection, label: "Duplicate Lines")
    }

    @objc func deleteSelectedLines(_ sender: Any?) {
        guard let selection = editableSelection, !string.isEmpty else { return }
        let source = string as NSString
        var lines = selectedLineRange(selection)
        if NSMaxRange(lines) == source.length, lines.location > 0,
           source.substring(with: lines).last?.isNewline != true {
            let previousLength = lines.location >= 2 && source.substring(with: NSRange(location: lines.location - 2, length: 2)) == "\r\n" ? 2 : 1
            lines = NSRange(location: lines.location - previousLength, length: lines.length + previousLength)
        }
        replace(lines, with: "", selection: NSRange(location: lines.location, length: 0), label: "Delete Lines")
    }

    private func selectedLineRange(_ selection: NSRange) -> NSRange {
        // A selection ending at the start of the next line only includes the preceding lines.
        (string as NSString).lineRange(for: NSRange(location: selection.location, length: max(0, selection.length - 1)))
    }
    private var preferredLineEnding: String {
        if string.contains("\r\n") { return "\r\n" }
        return string.contains("\r") ? "\r" : "\n"
    }
    private func replace(_ range: NSRange, with replacement: String, selection: NSRange, label: String) {
        let expected = (string as NSString).replacingCharacters(in: range, with: replacement)
        breakUndoCoalescing()
        let undo = undoManager
        undo?.beginUndoGrouping()
        insertText(replacement, replacementRange: range)
        undo?.setActionName(label)
        undo?.endUndoGrouping()
        breakUndoCoalescing()
        guard string == expected else { return }
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            urls.forEach { onFile?($0) }; return true
        }
        return super.performDragOperation(sender)
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if let data = NSPasteboard.general.data(forType: .png) ?? NSPasteboard.general.data(forType: .tiff), let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted image-\(UUID().uuidString).png")
            do { try png.write(to: file); onFile?(file); try? FileManager.default.removeItem(at: file) } catch { NSSound.beep() }
        } else { super.paste(sender) }
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let html: String
    var onNote: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onNote: onNote) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onNote = onNote
        if context.coordinator.lastHTML != html { context.coordinator.lastHTML = html; view.loadHTMLString(html, baseURL: nil) }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var onNote: (String) -> Void
        init(onNote: @escaping (String) -> Void) { self.onNote = onNote }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
            if url.scheme == "pandanote-note" { onNote(String(url.absoluteString.dropFirst("pandanote-note:".count)).removingPercentEncoding ?? "") }
            else if ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}

struct NativePDFView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}
