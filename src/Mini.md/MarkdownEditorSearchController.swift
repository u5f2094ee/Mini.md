import AppKit

@MainActor
final class MarkdownEditorSearchController {
    private weak var textView: NSTextView?
    private var matches: [NSRange] = []
    private var activeIndex = -1
    private let searchOptions: NSString.CompareOptions = [.caseInsensitive]
    // Replacement is intentionally stricter than search: case-sensitive literal text only.
    private let replacementOptions: NSString.CompareOptions = []

    init(textView: NSTextView) {
        self.textView = textView
    }

    func highlight(query: String, theme: DocumentTheme) -> SearchResultState {
        clearHighlightAttributesOnly()
        matches.removeAll()
        activeIndex = -1

        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return state()
        }

        let source = textView.string as NSString
        guard source.length > 0 else {
            return state()
        }

        matches = ranges(of: literalQuery, in: source, options: searchOptions)
        activeIndex = matches.isEmpty ? -1 : 0
        applyHighlights(theme: theme)
        return state()
    }

    func next(theme: DocumentTheme) -> SearchResultState {
        guard !matches.isEmpty else {
            return state()
        }

        activeIndex = activeIndex < 0 ? 0 : (activeIndex + 1) % matches.count
        applyHighlights(theme: theme)
        scrollToActiveMatch()
        return state()
    }

    func clear(preserveScroll: Bool) {
        let origin = currentScrollOrigin()
        clearHighlightAttributesOnly()
        matches.removeAll()
        activeIndex = -1

        if preserveScroll, let origin {
            restoreScrollOrigin(origin)
        }
    }

    func reapply(theme: DocumentTheme) {
        applyHighlights(theme: theme)
    }

    func hasCaseSensitiveReplacementMatch(query: String) -> Bool {
        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return false
        }

        let source = textView.string as NSString
        return !ranges(of: literalQuery, in: source, options: replacementOptions).isEmpty
    }

    func canReplaceCurrentCaseSensitiveMatch(query: String) -> Bool {
        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return false
        }

        let source = textView.string as NSString
        let replacementMatches = ranges(of: literalQuery, in: source, options: replacementOptions)
        return currentReplacementRange(from: replacementMatches, in: textView) != nil
    }

    func replaceCurrent(query: String, replacement: String, theme: DocumentTheme) -> SearchResultState {
        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return state()
        }

        let source = textView.string as NSString
        let replacementMatches = ranges(of: literalQuery, in: source, options: replacementOptions)
        guard !replacementMatches.isEmpty,
              let targetRange = currentReplacementRange(from: replacementMatches, in: textView) else {
            NSSound.beep()
            return highlight(query: query, theme: theme)
        }

        clearHighlightAttributesOnly()
        textView.insertText(replacement, replacementRange: targetRange)

        let nextLocation = targetRange.location + (replacement as NSString).length
        return highlight(query: query, theme: theme, preferredActiveLocation: nextLocation, scrollToActive: true)
    }

    func replaceAll(query: String, replacement: String, theme: DocumentTheme) -> SearchResultState {
        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return state()
        }

        let source = textView.string as NSString
        let replacementMatches = ranges(of: literalQuery, in: source, options: replacementOptions)
        guard !replacementMatches.isEmpty else {
            NSSound.beep()
            return highlight(query: query, theme: theme)
        }

        clearHighlightAttributesOnly()
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        for range in replacementMatches.reversed() {
            textView.insertText(replacement, replacementRange: range)
        }
        undoManager?.setActionName("Replace All")
        undoManager?.endUndoGrouping()

        return highlight(query: query, theme: theme, preferredActiveLocation: 0, scrollToActive: false)
    }

    private func highlight(
        query: String,
        theme: DocumentTheme,
        preferredActiveLocation: Int,
        scrollToActive: Bool
    ) -> SearchResultState {
        clearHighlightAttributesOnly()
        matches.removeAll()
        activeIndex = -1

        guard let literalQuery = literalQuery(from: query),
              let textView else {
            return state()
        }

        let source = textView.string as NSString
        matches = ranges(of: literalQuery, in: source, options: searchOptions)
        if !matches.isEmpty {
            activeIndex = matches.firstIndex { $0.location >= preferredActiveLocation } ?? 0
        }
        applyHighlights(theme: theme)

        if scrollToActive {
            scrollToActiveMatch()
        }

        return state()
    }

    private func state() -> SearchResultState {
        SearchResultState(count: matches.count, activeIndex: activeIndex >= 0 ? activeIndex : nil)
    }

    private func literalQuery(from query: String) -> String? {
        guard !query.isEmpty,
              query.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil else {
            return nil
        }

        return query
    }

    private func currentReplacementRange(from replacementMatches: [NSRange], in textView: NSTextView) -> NSRange? {
        if matches.indices.contains(activeIndex) {
            let activeRange = matches[activeIndex]
            return replacementMatches.first { $0.location == activeRange.location && $0.length == activeRange.length }
        }

        let selectedLocation = textView.selectedRange().location
        return replacementMatches.first(where: { $0.location >= selectedLocation }) ?? replacementMatches.first
    }

    private func ranges(
        of query: String,
        in source: NSString,
        options: NSString.CompareOptions
    ) -> [NSRange] {
        guard source.length > 0 else {
            return []
        }

        var foundRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(of: query, options: options, range: searchRange)
            guard found.location != NSNotFound else {
                break
            }

            if !shouldSkipMatch(found, query: query, in: source) {
                foundRanges.append(found)
            }

            let nextLocation = found.location + max(found.length, 1)
            guard nextLocation <= source.length else {
                break
            }

            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }

        return foundRanges
    }

    private func shouldSkipMatch(_ range: NSRange, query: String, in source: NSString) -> Bool {
        guard isMarkdownHeadingPrefixQuery(query),
              range.location > 0 else {
            return false
        }

        return source.substring(with: NSRange(location: range.location - 1, length: 1)) == "#"
    }

    private func isMarkdownHeadingPrefixQuery(_ query: String) -> Bool {
        guard query.hasSuffix(" ") else {
            return false
        }

        let hashPrefix = query.dropLast()
        guard !hashPrefix.isEmpty, hashPrefix.count <= 6 else {
            return false
        }

        return hashPrefix.allSatisfy { $0 == "#" }
    }

    private func applyHighlights(theme: DocumentTheme) {
        guard let textView,
              let layoutManager = textView.layoutManager else {
            return
        }

        clearHighlightAttributesOnly()
        let textLength = (textView.string as NSString).length
        let normalColor = normalHighlightColor(for: theme)
        let activeColor = activeHighlightColor(for: theme)

        for range in matches where NSMaxRange(range) <= textLength {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: normalColor, forCharacterRange: range)
        }

        if matches.indices.contains(activeIndex) {
            let activeRange = matches[activeIndex]
            if NSMaxRange(activeRange) <= textLength {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: activeColor, forCharacterRange: activeRange)
            }
        }
    }

    private func clearHighlightAttributesOnly() {
        guard let textView,
              let layoutManager = textView.layoutManager else {
            return
        }

        let textLength = (textView.string as NSString).length
        for range in matches where NSMaxRange(range) <= textLength {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    private func scrollToActiveMatch() {
        guard let textView,
              matches.indices.contains(activeIndex) else {
            return
        }

        textView.scrollRangeToVisible(matches[activeIndex])
    }

    private func currentScrollOrigin() -> NSPoint? {
        textView?.enclosingScrollView?.contentView.bounds.origin
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        guard let scrollView = textView?.enclosingScrollView else {
            return
        }

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func normalHighlightColor(for theme: DocumentTheme) -> NSColor {
        switch theme {
        case .light:
            return NSColor(srgbRed: 1.0, green: 0.88, blue: 0.35, alpha: 0.72)
        case .dark:
            return NSColor(srgbRed: 1.0, green: 0.78, blue: 0.28, alpha: 0.42)
        }
    }

    private func activeHighlightColor(for theme: DocumentTheme) -> NSColor {
        switch theme {
        case .light:
            return NSColor(srgbRed: 1.0, green: 0.55, blue: 0.18, alpha: 0.88)
        case .dark:
            return NSColor(srgbRed: 1.0, green: 0.48, blue: 0.13, alpha: 0.78)
        }
    }
}
