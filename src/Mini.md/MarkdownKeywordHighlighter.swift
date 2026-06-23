import AppKit

struct HighlightApplication: Sendable {
    let range: NSRange
    let color: HighlightColor
}

enum HighlightRefreshReason {
    case enteredEditMode
    case documentSaved
    case themeChanged
    case configurationChanged
    case textAssigned
    case manualReload
}

@MainActor
final class MarkdownKeywordHighlighter {
    private enum DocumentSize {
        static let normalLimit = 1_000_000
    }

    private let configurationStore: HighlightConfigurationStore
    private let calculationQueue = DispatchQueue(label: "com.openai-codex.zhangzheng.minimd.keyword-highlighter", qos: .userInitiated)
    private var appliedRanges: [NSRange] = []
    private var pendingWorkItem: DispatchWorkItem?
    private var generation = 0
    private var highlightNeedsRefresh = false

    init(configurationStore: HighlightConfigurationStore = .shared) {
        self.configurationStore = configurationStore
    }

    func applyNow(
        to textView: NSTextView,
        theme: DocumentTheme,
        reason: HighlightRefreshReason = .manualReload
    ) {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        highlightNeedsRefresh = false
        generation += 1
        applySnapshot(textView.string, to: textView, theme: theme, generation: generation)
    }

    func markNeedsRefresh() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        highlightNeedsRefresh = true
        generation += 1
    }

    func clear(from textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else {
            appliedRanges.removeAll()
            return
        }

        let textLength = (textView.string as NSString).length
        for range in appliedRanges {
            guard range.location < textLength else {
                continue
            }

            let clampedRange = NSRange(
                location: range.location,
                length: min(range.length, textLength - range.location)
            )
            guard clampedRange.length > 0 else {
                continue
            }

            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clampedRange)
        }
        appliedRanges.removeAll()
    }

    func invalidateConfigurationAndApply(to textView: NSTextView, theme: DocumentTheme) {
        configurationStore.invalidateCache()
        applyNow(to: textView, theme: theme, reason: .configurationChanged)
    }

    func cancelScheduledApply() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        highlightNeedsRefresh = false
        generation += 1
    }

    nonisolated static func highlightApplications(
        in text: String,
        configuration: HighlightConfiguration,
        theme: DocumentTheme
    ) -> [HighlightApplication] {
        let themeConfiguration = configuration.themeConfiguration(for: theme)
        guard !themeConfiguration.markdownColors.isEmpty ||
              !themeConfiguration.inlineColors.isEmpty ||
              !themeConfiguration.keywordRules.isEmpty else {
            return []
        }

        let source = text as NSString
        guard source.length > 0 else {
            return []
        }

        let lineRules = themeConfiguration.keywordRules.filter { $0.scope == .line }
        let keywordRules = themeConfiguration.keywordRules.filter { $0.scope == .keyword }
        var applications: [HighlightApplication] = []
        var fenceState = MarkdownFenceState()
        var location = 0

        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )

            let lineRange = NSRange(location: location, length: contentsEnd - location)
            if lineRange.length > 0 {
                let lineText = source.substring(with: lineRange) as NSString
                let isFenceMarker = MarkdownLineClassifier.updateFenceState(for: lineText, state: &fenceState)

                if isFenceMarker {
                    appendFenceMarkerKeywordRuleApplications(
                        keywordRules,
                        source: source,
                        lineRange: lineRange,
                        to: &applications
                    )
                    location = lineEnd
                    continue
                }

                if !fenceState.isInsideFence,
                   let kind = MarkdownLineClassifier.classify(lineText),
                   let color = themeConfiguration.markdownColors[kind] {
                    applications.append(HighlightApplication(range: lineRange, color: color))
                }

                appendLineRuleApplications(
                    lineRules,
                    source: source,
                    lineRange: lineRange,
                    to: &applications
                )
                appendInlinePatternApplications(
                    themeConfiguration.inlineColors,
                    source: source,
                    lineRange: lineRange,
                    isInsideFence: fenceState.isInsideFence,
                    to: &applications
                )
                appendKeywordRuleApplications(
                    keywordRules,
                    source: source,
                    lineRange: lineRange,
                    to: &applications
                )
            }

            location = lineEnd
        }

        return applications
    }

    private func applySnapshot(
        _ snapshot: String,
        to textView: NSTextView,
        theme: DocumentTheme,
        generation currentGeneration: Int
    ) {
        clear(from: textView)

        let settings = MiniMDSettingsManager.shared.settings()
        guard settings.editSyntaxHighlightingEnabled,
              !snapshot.isEmpty else {
            return
        }

        let configuration = configurationStore.configuration()
        let length = (snapshot as NSString).length
        if length < DocumentSize.normalLimit {
            let applications = Self.highlightApplications(in: snapshot, configuration: configuration, theme: theme)
            apply(applications, to: textView, generation: currentGeneration)
            return
        }

        calculationQueue.async { [weak self, weak textView, snapshot, configuration, theme, currentGeneration] in
            let applications = Self.highlightApplications(in: snapshot, configuration: configuration, theme: theme)
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView else {
                    return
                }

                Task { @MainActor in
                    self.apply(applications, to: textView, generation: currentGeneration)
                }
            }
        }
    }

    private func apply(
        _ applications: [HighlightApplication],
        to textView: NSTextView,
        generation applicationGeneration: Int
    ) {
        guard applicationGeneration == generation,
              let layoutManager = textView.layoutManager else {
            return
        }

        clear(from: textView)

        let textLength = (textView.string as NSString).length
        for application in applications where NSMaxRange(application.range) <= textLength {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: application.color.nsColor,
                forCharacterRange: application.range
            )
            appliedRanges.append(application.range)
        }
    }

    nonisolated private static func appendFenceMarkerKeywordRuleApplications(
        _ rules: [HighlightKeywordRule],
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        guard !rules.isEmpty else {
            return
        }

        let lineText = source.substring(with: lineRange)
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }

        let leadingWhitespaceLength = leadingWhitespaceCount(in: lineText as NSString)
        let trimmedLength = (trimmed as NSString).length

        for rule in rules where rule.keyword == trimmed {
            applications.append(HighlightApplication(
                range: NSRange(location: lineRange.location + leadingWhitespaceLength, length: trimmedLength),
                color: rule.color
            ))
        }
    }

    nonisolated private static func leadingWhitespaceCount(in lineText: NSString) -> Int {
        var index = 0
        while index < lineText.length {
            let character = lineText.character(at: index)
            guard character == CharacterCode.space || character == CharacterCode.tab else {
                break
            }
            index += 1
        }
        return index
    }

    nonisolated private static func appendLineRuleApplications(
        _ rules: [HighlightKeywordRule],
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        for rule in rules {
            let found = source.range(of: rule.keyword, options: [], range: lineRange)
            if found.location != NSNotFound {
                applications.append(HighlightApplication(range: lineRange, color: rule.color))
            }
        }
    }

    nonisolated private static func appendInlinePatternApplications(
        _ inlineColors: [InlineHighlightKind: HighlightColor],
        source: NSString,
        lineRange: NSRange,
        isInsideFence: Bool,
        to applications: inout [HighlightApplication]
    ) {
        guard !inlineColors.isEmpty else {
            return
        }

        if let color = inlineColors[.quotedText] {
            appendQuotedTextApplications(color: color, source: source, lineRange: lineRange, to: &applications)
        }

        guard !isInsideFence else {
            return
        }

        if let color = inlineColors[.boldText] {
            appendBoldTextApplications(color: color, source: source, lineRange: lineRange, to: &applications)
        }

        if let color = inlineColors[.inlineCode] {
            appendInlineCodeApplications(color: color, source: source, lineRange: lineRange, to: &applications)
        }
    }

    nonisolated private static func appendQuotedTextApplications(
        color: HighlightColor,
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        let lineEnd = NSMaxRange(lineRange)
        var index = lineRange.location

        while index < lineEnd {
            let opening = source.character(at: index)
            guard let closing = closingQuote(for: opening) else {
                index += 1
                continue
            }

            if opening == CharacterCode.apostrophe,
               !isValidASCIIQuoteStart(source: source, index: index, lineRange: lineRange) {
                index += 1
                continue
            }

            var searchIndex = index + 1
            var didMatch = false
            while searchIndex < lineEnd,
                  searchIndex - index - 1 <= InlinePatternLimit.maximumQuotedTextLength {
                guard source.character(at: searchIndex) == closing else {
                    searchIndex += 1
                    continue
                }

                let contentLength = searchIndex - index - 1
                guard contentLength > 0 else {
                    break
                }

                if opening == CharacterCode.apostrophe,
                   !isValidASCIIQuoteEnd(source: source, index: searchIndex, lineRange: lineRange) {
                    searchIndex += 1
                    continue
                }

                applications.append(HighlightApplication(
                    range: NSRange(location: index, length: searchIndex - index + 1),
                    color: color
                ))
                index = searchIndex + 1
                didMatch = true
                break
            }

            if !didMatch {
                index += 1
            }
        }
    }

    nonisolated private static func appendBoldTextApplications(
        color: HighlightColor,
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        let lineEnd = NSMaxRange(lineRange)
        var index = lineRange.location

        while index + 1 < lineEnd {
            guard source.character(at: index) == CharacterCode.asterisk,
                  source.character(at: index + 1) == CharacterCode.asterisk else {
                index += 1
                continue
            }

            let contentStart = index + 2
            var searchIndex = contentStart
            var didMatch = false
            while searchIndex + 1 < lineEnd {
                if source.character(at: searchIndex) == CharacterCode.asterisk,
                   source.character(at: searchIndex + 1) == CharacterCode.asterisk {
                    if searchIndex > contentStart {
                        applications.append(HighlightApplication(
                            range: NSRange(location: index, length: searchIndex - index + 2),
                            color: color
                        ))
                    }
                    index = searchIndex + 2
                    didMatch = true
                    break
                }
                searchIndex += 1
            }

            if !didMatch {
                index += 2
            }
        }
    }

    nonisolated private static func appendInlineCodeApplications(
        color: HighlightColor,
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        let lineEnd = NSMaxRange(lineRange)
        var index = lineRange.location

        while index < lineEnd {
            guard source.character(at: index) == CharacterCode.backtick else {
                index += 1
                continue
            }

            let openingLength = consecutiveCharacterCount(
                CharacterCode.backtick,
                source: source,
                startingAt: index,
                upperBound: lineEnd
            )
            let contentStart = index + openingLength
            var searchIndex = contentStart
            var didMatch = false

            while searchIndex < lineEnd {
                guard source.character(at: searchIndex) == CharacterCode.backtick else {
                    searchIndex += 1
                    continue
                }

                let closingLength = consecutiveCharacterCount(
                    CharacterCode.backtick,
                    source: source,
                    startingAt: searchIndex,
                    upperBound: lineEnd
                )
                if closingLength == openingLength {
                    if searchIndex > contentStart {
                        applications.append(HighlightApplication(
                            range: NSRange(location: index, length: searchIndex - index + closingLength),
                            color: color
                        ))
                    }
                    index = searchIndex + closingLength
                    didMatch = true
                    break
                }

                searchIndex += closingLength
            }

            if !didMatch {
                index = contentStart
            }
        }
    }

    nonisolated private static func appendKeywordRuleApplications(
        _ rules: [HighlightKeywordRule],
        source: NSString,
        lineRange: NSRange,
        to applications: inout [HighlightApplication]
    ) {
        for rule in rules {
            var searchRange = lineRange
            while searchRange.length > 0 {
                let found = source.range(of: rule.keyword, options: [], range: searchRange)
                guard found.location != NSNotFound else {
                    break
                }

                applications.append(HighlightApplication(range: found, color: rule.color))

                let nextLocation = found.location + max(found.length, 1)
                guard nextLocation <= NSMaxRange(lineRange) else {
                    break
                }

                searchRange = NSRange(location: nextLocation, length: NSMaxRange(lineRange) - nextLocation)
            }
        }
    }

    nonisolated private static func closingQuote(for opening: unichar) -> unichar? {
        switch opening {
        case CharacterCode.leftSingleQuote:
            return CharacterCode.rightSingleQuote
        case CharacterCode.leftDoubleQuote:
            return CharacterCode.rightDoubleQuote
        case CharacterCode.doubleQuote:
            return CharacterCode.doubleQuote
        case CharacterCode.apostrophe:
            return CharacterCode.apostrophe
        case CharacterCode.leftCornerBracket:
            return CharacterCode.rightCornerBracket
        case CharacterCode.leftWhiteCornerBracket:
            return CharacterCode.rightWhiteCornerBracket
        default:
            return nil
        }
    }

    nonisolated private static func isValidASCIIQuoteStart(
        source: NSString,
        index: Int,
        lineRange: NSRange
    ) -> Bool {
        guard index > lineRange.location else {
            return true
        }
        return !isASCIILetterOrDigit(source.character(at: index - 1))
    }

    nonisolated private static func isValidASCIIQuoteEnd(
        source: NSString,
        index: Int,
        lineRange: NSRange
    ) -> Bool {
        let nextIndex = index + 1
        guard nextIndex < NSMaxRange(lineRange) else {
            return true
        }
        return !isASCIILetterOrDigit(source.character(at: nextIndex))
    }

    nonisolated private static func consecutiveCharacterCount(
        _ character: unichar,
        source: NSString,
        startingAt index: Int,
        upperBound: Int
    ) -> Int {
        var count = 0
        var cursor = index
        while cursor < upperBound,
              source.character(at: cursor) == character {
            count += 1
            cursor += 1
        }
        return count
    }

    nonisolated private static func isASCIILetterOrDigit(_ character: unichar) -> Bool {
        (character >= 48 && character <= 57) ||
        (character >= 65 && character <= 90) ||
        (character >= 97 && character <= 122)
    }

    private enum InlinePatternLimit {
        static let maximumQuotedTextLength = 300
    }

    private enum CharacterCode {
        static let doubleQuote: unichar = 34
        static let apostrophe: unichar = 39
        static let asterisk: unichar = 42
        static let backtick: unichar = 96
        static let space: unichar = 32
        static let tab: unichar = 9
        static let leftSingleQuote: unichar = 0x2018
        static let rightSingleQuote: unichar = 0x2019
        static let leftDoubleQuote: unichar = 0x201C
        static let rightDoubleQuote: unichar = 0x201D
        static let leftCornerBracket: unichar = 0x300C
        static let rightCornerBracket: unichar = 0x300D
        static let leftWhiteCornerBracket: unichar = 0x300E
        static let rightWhiteCornerBracket: unichar = 0x300F
    }
}
