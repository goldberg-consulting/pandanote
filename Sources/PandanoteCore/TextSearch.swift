import Foundation

/// Controls literal or regular-expression matching in a document.
public struct TextSearchOptions: Equatable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regularExpression: Bool

    /// Creates matching options; plain text searches are case insensitive by default.
    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regularExpression: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regularExpression = regularExpression
    }
}

/// A match with UTF-16 editor coordinates and a bounded excerpt of its first line.
public struct TextSearchMatch: Identifiable, Sendable {
    public var id: Int { range.location }
    public let range: NSRange
    public let line: Int
    public let column: Int
    public let preview: String
    public let previewMatchRange: NSRange
    public let matchedText: String
    fileprivate let captureRanges: [NSRange]
    fileprivate let source: String
    fileprivate let searchID: UUID
    fileprivate let query: String
    fileprivate let options: TextSearchOptions
}

/// Contains ordered, nonoverlapping matches and whether the match limit omitted results.
public struct TextSearchResult: Sendable {
    public let matches: [TextSearchMatch]
    public let isTruncated: Bool
}

/// Contains the updated document after a complete replacement operation.
public struct TextSearchReplacementResult: Sendable {
    public let text: String
    public let replacementCount: Int
}

/// Describes search input, timeout, and stale-result failures that can be shown in the UI.
public enum TextSearchError: LocalizedError {
    case invalidPattern(String)
    case invalidRange
    case invalidLimit
    case timedOut
    case truncated
    case staleMatch
    case matchingFailed
    case replacementTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let message): return "Invalid regular expression: \(message)"
        case .invalidRange: return "The search selection is no longer valid. Select the passage again."
        case .invalidLimit: return "The search limit and time limit must be greater than zero."
        case .timedOut: return "The search took too long. Simplify the expression or narrow the search."
        case .truncated: return "There are more matches than the search limit. Narrow the search before replacing all."
        case .staleMatch: return "The document or search changed. Search again before replacing."
        case .matchingFailed: return "The regular expression could not finish matching. Simplify the expression and try again."
        case .replacementTooLarge: return "The replacement would produce too much text. Narrow the search or shorten the replacement."
        }
    }
}

/// Finds and replaces text without modifying files. Run large searches away from the main actor.
public enum TextSearch {
    /// Finds matches within the optional UTF-16 selection while preserving surrounding regex context.
    public static func find(
        in text: String,
        query: String,
        options: TextSearchOptions = .init(),
        range: NSRange? = nil,
        maximumMatches: Int = 10_000,
        timeLimit: TimeInterval = 2,
        isCancelled: () -> Bool = { false }
    ) throws -> TextSearchResult {
        let started = ProcessInfo.processInfo.systemUptime
        let scan = try scan(in: text, query: query, options: options, range: range,
                            maximumMatches: maximumMatches, timeLimit: timeLimit, isCancelled: isCancelled)
        guard !scan.results.isEmpty else { return TextSearchResult(matches: [], isTruncated: scan.isTruncated) }
        let source = text as NSString
        let lines = try LineIndex(source) {
            try checkBudget(started: started, timeLimit: timeLimit, isCancelled: isCancelled)
        }
        let searchID = UUID()
        var matches: [TextSearchMatch] = []
        matches.reserveCapacity(scan.results.count)
        for result in scan.results {
            try checkBudget(started: started, timeLimit: timeLimit, isCancelled: isCancelled)
            let context = lines.context(for: result.range, in: source)
            let captureRanges = (0..<result.numberOfRanges).map { result.range(at: $0) }
            matches.append(TextSearchMatch(
                range: result.range, line: context.line, column: context.column,
                preview: context.preview, previewMatchRange: context.highlight,
                matchedText: source.substring(with: result.range), captureRanges: captureRanges,
                source: text, searchID: searchID, query: query, options: options
            ))
        }
        try checkBudget(started: started, timeLimit: timeLimit, isCancelled: isCancelled)
        return TextSearchResult(matches: matches, isTruncated: scan.isTruncated)
    }

    /// Replaces every match only when the search completes without truncation or cancellation.
    public static func replacing(
        in text: String,
        query: String,
        replacement: String,
        options: TextSearchOptions = .init(),
        range: NSRange? = nil,
        maximumMatches: Int = 10_000,
        timeLimit: TimeInterval = 2,
        maximumReplacementLength: Int = 16 * 1_024 * 1_024,
        isCancelled: () -> Bool = { false }
    ) throws -> TextSearchReplacementResult {
        guard maximumReplacementLength > 0 else { throw TextSearchError.invalidLimit }
        let started = ProcessInfo.processInfo.systemUptime
        let scan = try scan(in: text, query: query, options: options, range: range,
                            maximumMatches: maximumMatches, timeLimit: timeLimit, isCancelled: isCancelled)
        guard !scan.isTruncated else { throw TextSearchError.truncated }
        guard let expression = scan.expression else {
            return TextSearchReplacementResult(text: text, replacementCount: 0)
        }
        let output = NSMutableString(string: text)
        let template = ReplacementTemplate(replacement, expression: expression, isRegex: options.regularExpression)
        var remaining = maximumReplacementLength
        for result in scan.results.reversed() {
            try checkBudget(started: started, timeLimit: timeLimit, isCancelled: isCancelled)
            try template.checkLength(ranges: (0..<result.numberOfRanges).map { result.range(at: $0) }, limit: remaining)
            let value = options.regularExpression
                ? expression.replacementString(for: result, in: text, offset: 0, template: replacement)
                : replacement
            let length = (value as NSString).length
            guard length <= remaining else { throw TextSearchError.replacementTooLarge }
            remaining -= length
            output.replaceCharacters(in: result.range, with: value)
        }
        try checkBudget(started: started, timeLimit: timeLimit, isCancelled: isCancelled)
        return TextSearchReplacementResult(text: output as String, replacementCount: scan.results.count)
    }

    /// Expands regex captures for one existing match; literal replacements preserve dollar signs and backslashes.
    public static func replacement(
        for match: TextSearchMatch,
        in text: String,
        query: String,
        replacement: String,
        options: TextSearchOptions = .init(),
        maximumReplacementLength: Int = 16 * 1_024 * 1_024
    ) throws -> String {
        let values = try replacements(for: [match], in: text, query: query, replacement: replacement,
                                      options: options, maximumReplacementLength: maximumReplacementLength)
        guard let value = values.first else { throw TextSearchError.staleMatch }
        return value
    }

    /// Expands captures for existing matches in order, compiling the expression once without searching again.
    public static func replacements(
        for matches: [TextSearchMatch],
        in text: String,
        query: String,
        replacement: String,
        options: TextSearchOptions = .init(),
        maximumReplacementLength: Int = 16 * 1_024 * 1_024
    ) throws -> [String] {
        guard maximumReplacementLength > 0 else { throw TextSearchError.invalidLimit }
        let expression = try expression(query: query, options: options)
        let template = ReplacementTemplate(replacement, expression: expression, isRegex: options.regularExpression)
        var remaining = maximumReplacementLength
        var validatedSearches: Set<UUID> = []
        return try matches.map { match in
            guard match.query == query, match.options == options else { throw TextSearchError.staleMatch }
            if validatedSearches.insert(match.searchID).inserted {
                guard match.source == text else { throw TextSearchError.staleMatch }
            }
            try template.checkLength(ranges: match.captureRanges, limit: remaining)
            guard options.regularExpression else {
                remaining -= (replacement as NSString).length
                return replacement
            }
            // Foundation copies these ranges while this buffer is alive; no pointer escapes the closure.
            var ranges = match.captureRanges
            return try ranges.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { throw TextSearchError.staleMatch }
                let result = NSTextCheckingResult.regularExpressionCheckingResult(
                    ranges: baseAddress, count: buffer.count, regularExpression: expression
                )
                let value = expression.replacementString(for: result, in: text, offset: 0, template: replacement)
                let length = (value as NSString).length
                guard length <= remaining else { throw TextSearchError.replacementTooLarge }
                remaining -= length
                return value
            }
        }
    }

    private struct ReplacementTemplate {
        let literalLength: Int
        let captures: [Int]

        init(_ template: String, expression: NSRegularExpression, isRegex: Bool) {
            let source = template as NSString
            guard isRegex else { literalLength = source.length; captures = []; return }
            let maximumDigits = String(expression.numberOfCaptureGroups).count
            var literals = 0
            var captures: [Int] = []
            var offset = 0
            while offset < source.length {
                let unit = source.character(at: offset)
                offset += 1
                if unit == 92 {
                    if offset < source.length { literals += 1; offset += 1 }
                } else if unit == 36, offset < source.length, (48...57).contains(source.character(at: offset)) {
                    var group = 0
                    var digits = 0
                    while offset < source.length, digits < maximumDigits, (48...57).contains(source.character(at: offset)) {
                        group = group * 10 + Int(source.character(at: offset) - 48)
                        offset += 1
                        digits += 1
                    }
                    captures.append(group)
                } else { literals += 1 }
            }
            literalLength = literals
            self.captures = captures
        }

        func checkLength(ranges: [NSRange], limit: Int) throws {
            guard literalLength <= limit else { throw TextSearchError.replacementTooLarge }
            var remaining = limit - literalLength
            for group in captures where group < ranges.count && ranges[group].location != NSNotFound {
                guard ranges[group].length <= remaining else { throw TextSearchError.replacementTooLarge }
                remaining -= ranges[group].length
            }
        }
    }

    private struct Scan {
        let expression: NSRegularExpression?
        let results: [NSTextCheckingResult]
        let isTruncated: Bool
    }

    private static func scan(
        in text: String, query: String, options: TextSearchOptions, range: NSRange?,
        maximumMatches: Int, timeLimit: TimeInterval, isCancelled: () -> Bool
    ) throws -> Scan {
        guard maximumMatches > 0, timeLimit > 0, timeLimit.isFinite else { throw TextSearchError.invalidLimit }
        if isCancelled() { throw CancellationError() }
        let source = text as NSString
        let searchRange = range ?? NSRange(location: 0, length: source.length)
        guard valid(searchRange, in: source) else { throw TextSearchError.invalidRange }
        guard !query.isEmpty else { return Scan(expression: nil, results: [], isTruncated: false) }
        let started = ProcessInfo.processInfo.systemUptime
        let expression = try expression(query: query, options: options)
        var results: [NSTextCheckingResult] = []
        var isTruncated = false
        var failure: Error?
        expression.enumerateMatches(
            in: text,
            options: [.reportProgress, .reportCompletion, .withTransparentBounds, .withoutAnchoringBounds],
            range: searchRange
        ) { result, flags, stop in
            if isCancelled() {
                failure = CancellationError()
                stop.pointee = true
            } else if ProcessInfo.processInfo.systemUptime - started >= timeLimit {
                failure = TextSearchError.timedOut
                stop.pointee = true
            } else if flags.contains(.internalError) {
                failure = TextSearchError.matchingFailed
                stop.pointee = true
            } else if let result {
                if results.count == maximumMatches {
                    isTruncated = true
                    stop.pointee = true
                } else {
                    results.append(result)
                }
            }
        }
        if let failure { throw failure }
        if isCancelled() { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime - started >= timeLimit { throw TextSearchError.timedOut }
        return Scan(expression: expression, results: results, isTruncated: isTruncated)
    }

    private static func checkBudget(started: TimeInterval, timeLimit: TimeInterval, isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime - started >= timeLimit { throw TextSearchError.timedOut }
    }

    private static func expression(query: String, options: TextSearchOptions) throws -> NSRegularExpression {
        var pattern = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            // Marks keep a decomposed accent attached to its letter when deciding word boundaries.
            pattern = "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + pattern + ")(?![\\p{L}\\p{M}\\p{N}_])"
        }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do { return try NSRegularExpression(pattern: pattern, options: flags) }
        catch { throw TextSearchError.invalidPattern(error.localizedDescription) }
    }

    private static func valid(_ range: NSRange, in source: NSString) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= source.length,
              range.length <= source.length - range.location else { return false }
        return boundary(range.location, in: source) && boundary(range.location + range.length, in: source)
    }

    private static func boundary(_ offset: Int, in source: NSString) -> Bool {
        guard offset > 0, offset < source.length else { return true }
        return !(0xDC00...0xDFFF).contains(source.character(at: offset))
            || !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
    }

    private struct LineIndex {
        let starts: [Int]
        let ends: [Int]

        init(_ source: NSString, checkBudget: () throws -> Void) throws {
            var starts = [0]
            var ends: [Int] = []
            var offset = 0
            while offset < source.length {
                if offset % 4_096 == 0 { try checkBudget() }
                let unit = source.character(at: offset)
                if unit == 10 || unit == 13 || unit == 0x85 || unit == 0x2028 || unit == 0x2029 {
                    ends.append(offset)
                    offset += 1
                    if unit == 13, offset < source.length, source.character(at: offset) == 10 { offset += 1 }
                    starts.append(offset)
                } else { offset += 1 }
            }
            ends.append(source.length)
            self.starts = starts
            self.ends = ends
        }

        func context(for range: NSRange, in source: NSString) -> (line: Int, column: Int, preview: String, highlight: NSRange) {
            var lower = 0
            var upper = starts.count
            while lower + 1 < upper {
                let middle = (lower + upper) / 2
                if starts[middle] <= range.location { lower = middle } else { upper = middle }
            }
            let lineStart = starts[lower]
            let lineEnd = ends[lower]
            let matchStart = min(range.location, lineEnd)
            var start = max(lineStart, matchStart - 60)
            var end = min(lineEnd, start + 180)
            if !TextSearch.boundary(start, in: source) { start += 1 }
            if !TextSearch.boundary(end, in: source) { end -= 1 }
            let prefix = start > lineStart ? "…" : ""
            let suffix = end < lineEnd ? "…" : ""
            let snippet = source.substring(with: NSRange(location: start, length: max(0, end - start)))
            let highlightStart = min(max(matchStart, start), end)
            let highlightEnd = min(max(NSMaxRange(range), highlightStart), end)
            return (
                lower + 1, range.location - lineStart + 1, prefix + snippet + suffix,
                NSRange(location: (prefix as NSString).length + highlightStart - start, length: highlightEnd - highlightStart)
            )
        }
    }
}

/// Filters slash-separated relative paths using comma- or newline-separated include and exclude globs.
public struct PathGlobFilter: Sendable {
    private let includes: [NSRegularExpression]
    private let excludes: [NSRegularExpression]

    /// Supports `*`, `**`, and `?`; patterns without a slash match names at any depth.
    public init(include: String = "", exclude: String = "") throws {
        includes = try Self.compile(include)
        excludes = try Self.compile(exclude)
    }

    /// Returns whether a path passes the includes and is not covered by an exclude.
    public func matches(_ relativePath: String) -> Bool {
        let path = relativePath.hasPrefix("./") ? String(relativePath.dropFirst(2)) : relativePath
        let range = NSRange(location: 0, length: (path as NSString).length)
        let included = includes.isEmpty || includes.contains { $0.firstMatch(in: path, range: range) != nil }
        return included && !excludes.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    private static func compile(_ patterns: String) throws -> [NSRegularExpression] {
        try patterns.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { original in
                var glob = original
                if glob.hasPrefix("./") { glob.removeFirst(2) }
                if glob.hasPrefix("/") { glob.removeFirst() }
                if glob.hasSuffix("/") { glob += "**" }
                let characters = Array(glob)
                var pattern = glob.contains("/") ? "^" : "^(?:.*/)?"
                var index = 0
                while index < characters.count {
                    switch characters[index] {
                    case "*":
                        if index + 1 < characters.count, characters[index + 1] == "*" {
                            index += 2
                            if index < characters.count, characters[index] == "/" {
                                pattern += "(?:.*/)?"
                                index += 1
                            } else { pattern += ".*" }
                        } else {
                            pattern += "[^/]*"
                            index += 1
                        }
                    case "?": pattern += "[^/]"; index += 1
                    default: pattern += NSRegularExpression.escapedPattern(for: String(characters[index])); index += 1
                    }
                }
                // Naming a directory also covers its descendants, as in editor search filters.
                pattern += "(?:/.*)?$"
                return try NSRegularExpression(pattern: pattern)
            }
    }
}
