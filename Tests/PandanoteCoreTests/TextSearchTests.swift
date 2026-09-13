import Foundation
import XCTest
@testable import PandanoteCore

final class TextSearchTests: XCTestCase {
    func test_literalSearch_whenOptionsChange_expectsCaseAndUnicodeWordBoundaries() throws {
        let text = "cat Cat scatter cat_ cat2 caté cat猫 cat\u{301} 🐼cat!"
        let plain = try TextSearch.find(in: text, query: "cat")
        XCTAssertEqual(plain.matches.count, 9)
        let whole = try TextSearch.find(in: text, query: "cat", options: .init(wholeWord: true))
        XCTAssertEqual(whole.matches.map(\.matchedText), ["cat", "Cat", "cat"])
        let exact = try TextSearch.find(in: text, query: "cat", options: .init(caseSensitive: true, wholeWord: true))
        XCTAssertEqual(exact.matches.count, 2)
    }

    func test_literalSearch_whenQueryContainsMetacharacters_expectsLiteralMatches() throws {
        let result = try TextSearch.find(in: "a.b aXb [a]", query: "a.b")
        XCTAssertEqual(result.matches.map(\.range), [NSRange(location: 0, length: 3)])
        let replacement = try TextSearch.replacing(in: "a.b", query: "a.b", replacement: "$1\\new")
        XCTAssertEqual(replacement.text, "$1\\new")
    }

    func test_regexSearch_whenUsingCaptures_expectsWholeMatchAndOptionalCaptureExpansion() throws {
        let text = "ID: 12; ID: 30 kg"
        let query = #"ID: (\d+)( kg)?"#
        let options = TextSearchOptions(regularExpression: true)
        let matches = try TextSearch.find(in: text, query: query, options: options).matches
        let values = try TextSearch.replacements(for: matches, in: text, query: query,
                                                replacement: "$1$2 [$0]", options: options)
        XCTAssertEqual(values, ["12 [ID: 12]", "30 kg [ID: 30 kg]"])
        let updated = try TextSearch.replacing(in: text, query: query, replacement: "$1$2 [$0]", options: options)
        XCTAssertEqual(updated.text, "12 [ID: 12]; 30 kg [ID: 30 kg]")
        XCTAssertEqual(updated.replacementCount, 2)
    }

    func test_selectionSearch_whenContextFallsOutsideSelection_expectsOriginalBoundaries() throws {
        let options = TextSearchOptions(regularExpression: true)
        let text = "before cat after"
        let selection = (text as NSString).range(of: "cat")
        XCTAssertEqual(try TextSearch.find(in: text, query: "(?<=before )cat(?= after)",
                                          options: options, range: selection).matches.count, 1)
        XCTAssertTrue(try TextSearch.find(in: text, query: "^cat$", options: options, range: selection).matches.isEmpty)
        XCTAssertTrue(try TextSearch.find(in: "scatter", query: "cat", options: .init(wholeWord: true),
                                         range: NSRange(location: 1, length: 3)).matches.isEmpty)
        let replaced = try TextSearch.replacing(in: "cat cat cat", query: "cat", replacement: "dog",
                                                range: NSRange(location: 4, length: 3))
        XCTAssertEqual(replaced.text, "cat dog cat")
    }

    func test_multilineRegex_whenUsingAnchors_expectsEveryLineAndMultilineReplacements() throws {
        let text = "first\nsecond\nthird"
        let options = TextSearchOptions(regularExpression: true)
        let result = try TextSearch.find(in: text, query: "^", options: options)
        XCTAssertEqual(result.matches.map(\.line), [1, 2, 3])
        XCTAssertEqual(try TextSearch.replacing(in: text, query: "^", replacement: "> ", options: options).text,
                       "> first\n> second\n> third")
        XCTAssertEqual(try TextSearch.replacing(in: "a a", query: "a", replacement: "b\nc").text, "b\nc b\nc")
    }

    func test_zeroWidthRegex_whenReplacementAddsText_expectsFiniteOriginalMatches() throws {
        let options = TextSearchOptions(regularExpression: true)
        let result = try TextSearch.replacing(in: "aa", query: "(?=a)|$", replacement: "x", options: options)
        XCTAssertEqual(result.text, "xaxax")
        XCTAssertEqual(result.replacementCount, 3)
        let matches = try TextSearch.find(in: "aa", query: "(?=a)|$", options: options).matches
        XCTAssertEqual(try TextSearch.replacements(for: matches, in: "aa", query: "(?=a)|$",
                                                 replacement: "$0x", options: options), ["x", "x", "x"])
    }

    func test_matchMetadata_whenTextContainsEmojiAndCRLF_expectsUTF16Coordinates() throws {
        let text = "🐼 cat\r\nα cat\rcat\n"
        let matches = try TextSearch.find(in: text, query: "cat").matches
        XCTAssertEqual(matches.map(\.range), [NSRange(location: 3, length: 3), NSRange(location: 10, length: 3),
                                              NSRange(location: 14, length: 3)])
        XCTAssertEqual(matches.map(\.line), [1, 2, 3])
        XCTAssertEqual(matches.map(\.column), [4, 3, 1])
        XCTAssertEqual(matches.map(\.preview), ["🐼 cat", "α cat", "cat"])
        XCTAssertEqual(matches[0].previewMatchRange, NSRange(location: 3, length: 3))
    }

    func test_preview_whenLineIsLong_expectsBoundedExcerptWithoutSplitSurrogates() throws {
        let text = String(repeating: "🐼", count: 500) + "needle" + String(repeating: "🐼", count: 500)
        let matches = try TextSearch.find(in: text, query: "needle").matches
        let match = try XCTUnwrap(matches.first)
        XCTAssertLessThanOrEqual((match.preview as NSString).length, 182)
        XCTAssertTrue(match.preview.hasPrefix("…"))
        XCTAssertTrue(match.preview.hasSuffix("…"))
        XCTAssertFalse(match.preview.contains("�"))
        XCTAssertEqual((match.preview as NSString).substring(with: match.previewMatchRange), "needle")
    }

    func test_matchLimit_whenMoreMatchesExist_expectsTruncationAndReplaceAllRejection() throws {
        let result = try TextSearch.find(in: "a a a", query: "a", maximumMatches: 2)
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertTrue(result.isTruncated)
        XCTAssertFalse(try TextSearch.find(in: "a a", query: "a", maximumMatches: 2).isTruncated)
        XCTAssertThrowsError(try TextSearch.replacing(in: "a a a", query: "a", replacement: "b", maximumMatches: 2)) {
            guard case TextSearchError.truncated = $0 else { return XCTFail("Expected a truncation error") }
        }
    }

    func test_invalidInput_whenPatternOrRangeIsInvalid_expectsActionableErrors() {
        XCTAssertThrowsError(try TextSearch.find(in: "text", query: "[", options: .init(regularExpression: true))) {
            guard case TextSearchError.invalidPattern = $0 else { return XCTFail("Expected a pattern error") }
        }
        for range in [NSRange(location: 1, length: 1), NSRange(location: 0, length: 3),
                      NSRange(location: NSNotFound, length: 1)] {
            XCTAssertThrowsError(try TextSearch.find(in: "🐼", query: ".", range: range))
        }
        XCTAssertThrowsError(try TextSearch.find(in: "text", query: "text", maximumMatches: 0))
        XCTAssertThrowsError(try TextSearch.find(in: "text", query: "text", timeLimit: .infinity))
    }

    func test_search_whenCancelledOrBudgetExpires_expectsNoPartialSuccess() {
        XCTAssertThrowsError(try TextSearch.find(in: "a a", query: "a", isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try TextSearch.replacing(in: "a a", query: "a", replacement: "b", isCancelled: { true }))
        XCTAssertThrowsError(try TextSearch.find(in: "a a", query: "a", timeLimit: 0.000_000_001)) {
            guard case TextSearchError.timedOut = $0 else { return XCTFail("Expected a timeout error") }
        }
        var checks = 0
        XCTAssertThrowsError(try TextSearch.find(in: String(repeating: "a", count: 50_000), query: "z", isCancelled: {
            checks += 1
            return checks > 1
        })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func test_regex_whenPathologicalBacktracking_expectsTimeBudgetToStopSearch() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try TextSearch.find(in: String(repeating: "a", count: 200) + "!", query: "(a+)+$",
                                               options: .init(regularExpression: true), timeLimit: 0.02)) {
            guard case TextSearchError.timedOut = $0 else { return XCTFail("Expected a timeout error") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }

    func test_emptyQuery_whenSearchingOrReplacing_expectsNoMatchesOrEdits() throws {
        XCTAssertTrue(try TextSearch.find(in: "a", query: "").matches.isEmpty)
        XCTAssertEqual(try TextSearch.replacing(in: "a", query: "", replacement: "b").text, "a")
    }

    func test_replacementExpansion_whenMatchOrOptionsChanged_expectsStaleMatchError() throws {
        let match = try XCTUnwrap(TextSearch.find(in: "cat", query: "cat").matches.first)
        XCTAssertThrowsError(try TextSearch.replacement(for: match, in: "dog", query: "cat", replacement: "a"))
        XCTAssertThrowsError(try TextSearch.replacement(for: match, in: "cat", query: "dog", replacement: "a"))
        XCTAssertThrowsError(try TextSearch.replacement(for: match, in: "cat", query: "cat", replacement: "a",
                                                      options: .init(caseSensitive: true)))
        let options = TextSearchOptions(regularExpression: true)
        let contextMatch = try XCTUnwrap(TextSearch.find(in: "acat", query: "(?<=a)cat", options: options).matches.first)
        XCTAssertThrowsError(try TextSearch.replacement(for: contextMatch, in: "bcat", query: "(?<=a)cat",
                                                      replacement: "dog", options: options))
    }

    func test_captureExpansion_whenLookaroundsOverlap_expectsContextCapturesFromOriginalSource() throws {
        let text = "aaaa"
        let options = TextSearchOptions(regularExpression: true)
        let query = "(?=(a+))"
        let matches = try TextSearch.find(in: text, query: query, options: options).matches
        XCTAssertEqual(try TextSearch.replacements(for: matches, in: text, query: query, replacement: "$1",
                                                 options: options), ["aaaa", "aaa", "aa", "a"])
        let duplicateSearch = try TextSearch.find(in: text, query: query, options: options).matches
        XCTAssertEqual(try TextSearch.replacements(for: [matches[0], duplicateSearch[1]], in: text, query: query,
                                                 replacement: "$1", options: options), ["aaaa", "aaa"])
    }

    func test_replacementLimit_whenCapturesMultiplyOutput_expectsRejectionBeforeExpansion() throws {
        let options = TextSearchOptions(regularExpression: true)
        let matches = try TextSearch.find(in: "aaaa", query: "(?=(a+))", options: options).matches
        XCTAssertThrowsError(try TextSearch.replacements(for: matches, in: "aaaa", query: "(?=(a+))", replacement: "$1",
                                                      options: options, maximumReplacementLength: 9)) {
            guard case TextSearchError.replacementTooLarge = $0 else { return XCTFail("Expected a replacement size error") }
        }
        XCTAssertEqual(try TextSearch.replacements(for: matches, in: "aaaa", query: "(?=(a+))", replacement: "$1",
                                                 options: options, maximumReplacementLength: 10), ["aaaa", "aaa", "aa", "a"])
        XCTAssertThrowsError(try TextSearch.replacing(in: "a a", query: "a", replacement: "bbb", maximumReplacementLength: 5))
        XCTAssertEqual(try TextSearch.replacing(in: "a a", query: "a", replacement: "bbb", maximumReplacementLength: 6).text,
                       "bbb bbb")
        let capture = try XCTUnwrap(TextSearch.find(in: "a", query: "(a)", options: options).matches.first)
        for (template, expected) in [("$10", "a0"), ("$99", "9"), ("$00", "a0"), ("\\$1", "$1"),
                                     ("\\n", "n"), ("$$1", "$a"), ("$", "$"), ("\\", ""), ("$2", "")] {
            XCTAssertEqual(try TextSearch.replacement(for: capture, in: "a", query: "(a)", replacement: template,
                                                     options: options, maximumReplacementLength: max(1, expected.utf16.count)), expected)
        }
    }

    func test_globFilter_whenPatternsHaveWildcards_expectsRelativePathMatching() throws {
        let filter = try PathGlobFilter(include: "**/*.md, notes/*.txt\nreadme.?", exclude: "archive/**, **/draft*\nprivate/")
        for path in ["Paper.md", "notes/One.md", "notes/more/Two.md", "notes/One.txt", "readme.a", "docs/readme.b"] {
            XCTAssertTrue(filter.matches(path), path)
        }
        for path in ["One.txt", "notes/more/One.txt", "archive/Paper.md", "notes/draft.md", "private/One.md", "readme.ab"] {
            XCTAssertFalse(filter.matches(path), path)
        }
        XCTAssertTrue(try PathGlobFilter().matches("any/path.any"))
        XCTAssertFalse(try PathGlobFilter(exclude: "archive").matches("notes/archive/file.md"))
        XCTAssertTrue(try PathGlobFilter(include: "./notes/*.md").matches("./notes/file.md"))
        XCTAssertTrue(try PathGlobFilter(include: "a[1].md").matches("a[1].md"))
        XCTAssertFalse(try PathGlobFilter(include: "a[1].md").matches("a1.md"))
    }
}
