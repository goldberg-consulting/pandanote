import AppKit
import XCTest
@testable import Pandanote

final class NativeEditorTests: XCTestCase {
    @MainActor func test_documentReload_when_markedTextIsBeyondNewDocument_expectsCompositionClearedAndNoStaleUndo() async {
        let (editor, delegate) = makeEditor("A long document with an unfinished ")
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        delegate.undo.beginUndoGrouping()
        editor.setMarkedText("prediction 🐼", selectedRange: NSRange(location: 13, length: 0), replacementRange: NSRange(location: end, length: 0))
        delegate.undo.endUndoGrouping()
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertGreaterThan(editor.markedRange().location, 1)

        editor.replaceDocumentText("x")

        XCTAssertEqual(editor.string, "x")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(delegate.undo.canUndo)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        delegate.undo.beginUndoGrouping()
        editor.insertText("y", replacementRange: editor.selectedRange())
        delegate.undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "xy")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, "x")
    }

    @MainActor func test_documentReplacement_when_composing_expectsOneNamedUndoAndPreservedEditability() async {
        let (editor, delegate) = makeEditor("Before ")
        delegate.undo.beginUndoGrouping()
        editor.setMarkedText("café 🐼", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: 7, length: 0))
        delegate.undo.endUndoGrouping()
        let original = editor.string
        XCTAssertTrue(editor.hasMarkedText())
        editor.isEditable = false

        editor.replaceDocumentText("After", undoLabel: "Find and replace")

        XCTAssertEqual(editor.string, "After")
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(delegate.undo.undoActionName, "Find and replace")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, original)
        delegate.undo.redo()
        XCTAssertEqual(editor.string, "After")
    }

    @MainActor func test_formatting_when_selectionContainsUnicode_expectsNativeUndoAndPreservedSelection() async {
        let original = "# 🐼\nA café with 🧑🏽‍💻."
        let passage = "café with 🧑🏽‍💻"
        let (editor, delegate) = makeEditor(original)
        editor.setSelectedRange((original as NSString).range(of: passage))

        editor.makeSelectionBold(nil)

        XCTAssertEqual(editor.string, "# 🐼\nA **café with 🧑🏽‍💻**.")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), passage)
        XCTAssertEqual(delegate.changeCount, 1)
        XCTAssertEqual(delegate.undo.undoActionName, "Bold")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, original)
        delegate.undo.redo()
        XCTAssertEqual(editor.string, "# 🐼\nA **café with 🧑🏽‍💻**.")

        editor.setSelectedRange((editor.string as NSString).range(of: passage))
        editor.makeSelectionBold(nil)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), passage)
    }

    @MainActor func test_formatting_when_caretIsEmpty_expectsPairedMarkupAndCaretInside() async {
        let (editor, delegate) = makeEditor("🐼")
        editor.setSelectedRange(NSRange(location: 2, length: 0))

        editor.makeSelectionInlineCode(nil)

        XCTAssertEqual(editor.string, "🐼``")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        delegate.undo.undo()
        XCTAssertEqual(editor.string, "🐼")
    }

    @MainActor func test_duplicateLines_when_selectionEndsAtNextLine_expectsOnlySelectedLinesDuplicated() async {
        let original = "one 🐼\r\ntwo e\u{301}\r\nthree"
        let selected = "two e\u{301}\r\n"
        let (editor, delegate) = makeEditor(original)
        editor.setSelectedRange((original as NSString).range(of: selected))

        editor.duplicateSelectedLines(nil)

        XCTAssertEqual(editor.string, "one 🐼\r\ntwo e\u{301}\r\ntwo e\u{301}\r\nthree")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), selected)
        XCTAssertEqual(delegate.undo.undoActionName, "Duplicate Lines")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, original)
        delegate.undo.redo()
        XCTAssertEqual(editor.string, "one 🐼\r\ntwo e\u{301}\r\ntwo e\u{301}\r\nthree")
    }

    @MainActor func test_duplicateLines_when_lastLineHasNoTerminator_expectsDocumentLineEndingAndUnicodeSelection() async {
        let original = "first\r\n🐼 café"
        let (editor, delegate) = makeEditor(original)
        editor.setSelectedRange((original as NSString).range(of: "🐼"))

        editor.duplicateSelectedLines(nil)

        XCTAssertEqual(editor.string, "first\r\n🐼 café\r\n🐼 café")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "🐼")
        XCTAssertEqual(editor.selectedRange().location, ("first\r\n🐼 café\r\n" as NSString).length)
        delegate.undo.undo()
        XCTAssertEqual(editor.string, original)
    }

    @MainActor func test_deleteLines_when_finalLineHasNoTerminator_expectsPrecedingLineEndingRemovedAndUndo() async {
        let original = "first 🐼\r\nlast e\u{301}"
        let (editor, delegate) = makeEditor(original)
        editor.setSelectedRange((original as NSString).range(of: "e\u{301}"))

        editor.deleteSelectedLines(nil)

        XCTAssertEqual(editor.string, "first 🐼")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: ("first 🐼" as NSString).length, length: 0))
        XCTAssertEqual(delegate.undo.undoActionName, "Delete Lines")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, original)
    }

    @MainActor func test_deleteLines_when_finalLineIsEmpty_expectsOnlyTrailingLineEndingRemoved() async {
        let (editor, delegate) = makeEditor("first\n🐼\n")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        editor.deleteSelectedLines(nil)

        XCTAssertEqual(editor.string, "first\n🐼")
        delegate.undo.undo()
        XCTAssertEqual(editor.string, "first\n🐼\n")
    }

    @MainActor func test_editing_when_documentIsLocked_expectsDisabledCommandsAndUnchangedText() async {
        let (editor, delegate) = makeEditor("A selected passage 🐼")
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.onRefactor = { _, _ in XCTFail("A locked document must not start a revision") }
        editor.onExtractSelection = { _ in XCTFail("A locked document must not extract text") }
        editor.isEditable = false
        for action in ["refactorSelection:", "extractSelection:", "makeSelectionBold:", "duplicateSelectedLines:", "deleteSelectedLines:"] {
            let item = NSMenuItem(title: "Action", action: NSSelectorFromString(action), keyEquivalent: "")
            XCTAssertFalse(editor.validateUserInterfaceItem(item), action)
        }

        editor.makeSelectionBold(nil)
        editor.duplicateSelectedLines(nil)
        editor.deleteSelectedLines(nil)

        XCTAssertEqual(editor.string, "A selected passage 🐼")
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_editing_when_delegateVetoesChange_expectsNoMutationOrSelectionMovement() async {
        let (editor, delegate) = makeEditor("🐼")
        delegate.rejectChanges = true
        let range = NSRange(location: 0, length: 2)
        editor.setSelectedRange(range)

        editor.makeSelectionBold(nil)

        XCTAssertEqual(editor.string, "🐼")
        XCTAssertEqual(editor.selectedRange(), range)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_searchHighlights_when_matchingUnicode_expectsTemporaryBackgroundAndUnchangedDocument() async throws {
        let source = "# 🐼 café"
        let (editor, delegate) = makeEditor(source)
        let layout = try XCTUnwrap(editor.layoutManager)
        let match = (source as NSString).range(of: "🐼")
        let all = NSRange(location: 0, length: (source as NSString).length)
        editor.textStorage?.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: all)
        layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: all)
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemGreen, forCharacterRange: NSRange(location: 0, length: 1))

        editor.showSearchMatches([match], active: match, source: source)

        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: match.location, effectiveRange: nil))
        XCTAssertEqual(editor.textStorage?.attribute(.foregroundColor, at: match.location, effectiveRange: nil) as? NSColor, .systemPurple)
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(delegate.changeCount, 0)
        XCTAssertFalse(delegate.undo.canUndo)

        editor.clearSearchHighlights()

        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: match.location, effectiveRange: nil))
        XCTAssertEqual(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor, .systemGreen)
        XCTAssertEqual(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: match.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    @MainActor func test_searchHighlights_when_matchCountExceedsLimit_expectsBoundedHighlightsAndVisibleActiveMatch() async throws {
        let count = MarkdownTextView.maximumHighlightedSearchMatches + 5
        let source = String(repeating: "x", count: count)
        let (editor, delegate) = makeEditor(source)
        let layout = try XCTUnwrap(editor.layoutManager)
        let matches = (0..<count).map { NSRange(location: $0, length: 1) }

        editor.showSearchMatches(matches, active: matches.last, source: source)

        let ordinary = try XCTUnwrap(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor)
        let active = try XCTUnwrap(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: count - 1, effectiveRange: nil) as? NSColor)
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: MarkdownTextView.maximumHighlightedSearchMatches, effectiveRange: nil))
        XCTAssertGreaterThan(active.alphaComponent, ordinary.alphaComponent)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_searchHighlights_when_resultSnapshotIsStale_expectsOldHighlightsCleared() async throws {
        let source = "🐼 word"
        let (editor, delegate) = makeEditor(source)
        let layout = try XCTUnwrap(editor.layoutManager)
        let match = (source as NSString).range(of: "word")
        editor.showSearchMatches([match], active: nil, source: source)

        editor.showSearchMatches([match], active: match, source: "An outdated document")

        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: match.location, effectiveRange: nil))
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_searchNavigation_when_snapshotMatches_expectsFullUnicodeRangeAndNoDocumentMutation() async {
        let source = "Before 🧑🏽‍💻 café after"
        let (editor, delegate) = makeEditor(source)
        let file = URL(fileURLWithPath: "/tmp/Search.md")
        let match = (source as NSString).range(of: "🧑🏽‍💻 café")

        XCTAssertTrue(editor.selectSearchMatch(match, in: file, source: source, currentFile: file, focusEditor: false))

        XCTAssertEqual(editor.selectedRange(), match)
        XCTAssertEqual((source as NSString).substring(with: editor.selectedRange()), "🧑🏽‍💻 café")
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(delegate.changeCount, 0)
        XCTAssertFalse(delegate.undo.canUndo)
    }

    @MainActor func test_searchNavigation_when_snapshotOrRangeIsInvalid_expectsSelectionUnchanged() async {
        let source = "🐼 word"
        let (editor, delegate) = makeEditor(source)
        let file = URL(fileURLWithPath: "/tmp/Search.md")
        let original = NSRange(location: 0, length: 0)
        editor.setSelectedRange(original)
        let match = (source as NSString).range(of: "word")

        XCTAssertFalse(editor.selectSearchMatch(match, in: file, source: source, currentFile: URL(fileURLWithPath: "/tmp/Other.md"), focusEditor: true))
        XCTAssertFalse(editor.selectSearchMatch(match, in: file, source: "Outdated text", currentFile: file, focusEditor: true))
        for range in [NSRange(location: 1, length: 1), NSRange(location: 1, length: 0), NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: Int.max)] {
            XCTAssertFalse(editor.selectSearchMatch(range, in: file, source: source, currentFile: file, focusEditor: true))
        }

        XCTAssertEqual(editor.selectedRange(), original)
        XCTAssertEqual(delegate.changeCount, 0)
        XCTAssertTrue(editor.selectSearchMatch(NSRange(location: 2, length: 0), in: file, source: source, currentFile: file, focusEditor: false))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
    }

    @MainActor func test_searchNavigation_when_focusIsNotRequested_expectsSearchFieldToKeepFocus() async {
        let source = "A matching passage"
        let (editor, delegate) = makeEditor(source)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let file = URL(fileURLWithPath: "/tmp/Search.md")
        let match = (source as NSString).range(of: "matching")

        XCTAssertTrue(editor.selectSearchMatch(match, in: file, source: source, currentFile: file, focusEditor: false))
        XCTAssertTrue(window.firstResponder === field)
        XCTAssertTrue(editor.selectSearchMatch(match, in: file, source: source, currentFile: file, focusEditor: true))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_findSelectedText_when_selectionContainsUnicodeAndRegexCharacters_expectsExactQuery() async {
        let source = "Before a+b 🐼 after"
        let (editor, delegate) = makeEditor(source)
        editor.hasDocument = { true }
        editor.setSelectedRange((source as NSString).range(of: "a+b 🐼"))
        var capturedText: String?
        var replacementRequested = true
        editor.onFind = { replace, selectedText in
            replacementRequested = replace
            capturedText = selectedText
        }

        editor.findSelectedText(nil)

        XCTAssertEqual(capturedText, "a+b 🐼")
        XCTAssertFalse(replacementRequested)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor func test_nativeFinderActions_when_invoked_expectsCustomSearchRoutes() async {
        let (editor, delegate) = makeEditor("Find 🐼")
        editor.hasDocument = { true }
        editor.setSelectedRange(NSRange(location: 5, length: 2))
        var requests: [(Bool, String?)] = []
        var nextCount = 0
        var previousCount = 0
        var closeCount = 0
        editor.onFind = { requests.append(($0, $1)) }
        editor.onFindNext = { nextCount += 1 }
        editor.onFindPrevious = { previousCount += 1 }
        editor.onCloseFind = { closeCount += 1 }
        for action: NSTextFinder.Action in [.showFindInterface, .showReplaceInterface, .setSearchString, .nextMatch, .previousMatch, .hideFindInterface] {
            let item = NSMenuItem(title: "Find", action: #selector(editor.performTextFinderAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            XCTAssertTrue(editor.validateUserInterfaceItem(item))
            editor.performTextFinderAction(item)
        }

        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[0].0)
        XCTAssertNil(requests[0].1)
        XCTAssertTrue(requests[1].0)
        XCTAssertNil(requests[1].1)
        XCTAssertEqual(requests[2].1, "🐼")
        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(delegate.changeCount, 0)
    }

    @MainActor private func makeEditor(_ text: String) -> (MarkdownTextView, EditorDelegate) {
        _ = NSApplication.shared
        let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = EditorDelegate()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = text
        editor.delegate = delegate
        return (editor, delegate)
    }

    @MainActor private final class EditorDelegate: NSObject, NSTextViewDelegate {
        let undo = UndoManager()
        var changeCount = 0
        var rejectChanges = false

        override init() {
            super.init()
            undo.groupsByEvent = false
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
        func textDidChange(_ notification: Notification) { changeCount += 1 }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            !rejectChanges
        }
    }
}
