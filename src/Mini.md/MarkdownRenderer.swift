import Foundation

final class MarkdownRenderer: @unchecked Sendable {
    private final class ResourceCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func value(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: String, for key: String) {
            lock.lock()
            values[key] = value
            lock.unlock()
        }
    }

    private static let resourceCache = ResourceCache()

    struct RenderOptions: @unchecked Sendable {
        let resourceBundle: Bundle
        let headExtras: String
        let imageSourceResolver: ((String, URL) -> String)?
        let themePalette: MiniMDThemePalette?
        let renderHighlightConfiguration: HighlightThemeConfiguration?

        init(
            resourceBundle: Bundle = .main,
            headExtras: String = "",
            imageSourceResolver: ((String, URL) -> String)? = nil,
            themePalette: MiniMDThemePalette? = nil,
            renderHighlightConfiguration: HighlightThemeConfiguration? = nil
        ) {
            self.resourceBundle = resourceBundle
            self.headExtras = headExtras
            self.imageSourceResolver = imageSourceResolver
            self.themePalette = themePalette
            self.renderHighlightConfiguration = renderHighlightConfiguration
        }
    }

    private final class RenderContext {
        let fileURL: URL
        let options: RenderOptions
        var containsMermaid = false

        init(fileURL: URL, options: RenderOptions) {
            self.fileURL = fileURL
            self.options = options
        }

        var highlightConfiguration: HighlightThemeConfiguration? {
            options.renderHighlightConfiguration
        }
    }

    private struct FenceStart {
        let marker: String
        let language: String
    }

    private struct ListItem {
        let ordered: Bool
        let text: String
        let taskState: Bool?
        let sourceLine: String
    }

    func render(fileURL: URL, theme: DocumentTheme, options: RenderOptions = RenderOptions()) throws -> String {
        var encoding = String.Encoding.utf8
        let source = try String(contentsOf: fileURL, usedEncoding: &encoding)
        return render(markdown: source, fileURL: fileURL, theme: theme, options: options)
    }

    func render(markdown source: String, fileURL: URL, theme: DocumentTheme, options: RenderOptions = RenderOptions()) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let context = RenderContext(fileURL: fileURL, options: options)
        let body = renderBlocks(lines, context: context)
        let cssName = theme == .dark ? "markdown-dark" : "markdown-light"
        let css = Self.loadResource(named: cssName, extension: "css", bundle: options.resourceBundle, fallback: Self.fallbackCSS(theme: theme))
        let palette = options.themePalette ?? .default(for: theme)
        let themeCSS = Self.themeVariableCSS(palette: palette)
        let mermaid = context.containsMermaid ? Self.mermaidScripts(theme: theme, bundle: options.resourceBundle) : ""
        let title = Self.escapeHTML(fileURL.lastPathComponent)

        return """
        <!doctype html>
        <html data-theme="\(theme.rawValue)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        \(options.headExtras)
        <style>\(css)</style>
        <style>\(themeCSS)</style>
        </head>
        <body>
        <main id="markdown-body">
        \(body)
        </main>
        \(mermaid)
        </body>
        </html>
        """
    }

    private func renderBlocks(_ lines: [String], context: RenderContext) -> String {
        var output: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = parseFenceStart(line) {
                output.append(renderFence(lines, index: &index, fence: fence, context: context))
                continue
            }

            if let heading = parseHeading(line) {
                let id = Self.headingID(from: heading.text)
                let style = Self.styleAttribute(color: blockHighlightColor(markdownKind: heading.kind, sourceLines: [line], context: context))
                output.append("<h\(heading.level) id=\"\(id)\"\(style)>\(renderInline(heading.text, context: context))</h\(heading.level)>")
                index += 1
                continue
            }

            if isHorizontalRule(line) {
                output.append("<hr>")
                index += 1
                continue
            }

            if isTableStart(lines, at: index) {
                output.append(renderTable(lines, index: &index, context: context))
                continue
            }

            if trimmed.hasPrefix(">") {
                output.append(renderBlockquote(lines, index: &index, context: context))
                continue
            }

            if let listItem = parseListItem(line) {
                output.append(renderList(lines, index: &index, firstItem: listItem, context: context))
                continue
            }

            output.append(renderParagraph(lines, index: &index, context: context))
        }

        return output.joined(separator: "\n")
    }

    private func renderFence(_ lines: [String], index: inout Int, fence: FenceStart, context: RenderContext) -> String {
        index += 1
        var codeLines: [String] = []

        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix(fence.marker) {
                index += 1
                break
            }

            codeLines.append(lines[index])
            index += 1
        }

        let code = codeLines.joined(separator: "\n")
        if fence.language.lowercased() == "mermaid" {
            context.containsMermaid = true
            let encodedSource = Data(code.utf8).base64EncodedString()
            return "<div class=\"mermaid\" data-mini-md-mermaid-source=\"\(Self.escapeAttribute(encodedSource))\">\(Self.escapeHTML(code))</div>"
        }

        let languageClass = fence.language.isEmpty ? "" : " class=\"language-\(Self.escapeAttribute(fence.language))\""
        return "<pre><code\(languageClass)>\(Self.escapeHTML(code))</code></pre>"
    }

    private func renderBlockquote(_ lines: [String], index: inout Int, context: RenderContext) -> String {
        var quoteLines: [String] = []
        var sourceLines: [String] = []

        while index < lines.count {
            let sourceLine = lines[index]
            let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }

            var stripped = String(trimmed.dropFirst())
            if stripped.hasPrefix(" ") {
                stripped.removeFirst()
            }
            quoteLines.append(stripped)
            sourceLines.append(sourceLine)
            index += 1
        }

        let style = Self.styleAttribute(color: blockHighlightColor(markdownKind: .quote, sourceLines: sourceLines, context: context))
        return "<blockquote\(style)>\n\(renderBlocks(quoteLines, context: context))\n</blockquote>"
    }

    private func renderList(_ lines: [String], index: inout Int, firstItem: ListItem, context: RenderContext) -> String {
        let ordered = firstItem.ordered
        let tag = ordered ? "ol" : "ul"
        var items: [String] = []
        var currentItem: ListItem? = firstItem

        while let item = currentItem, item.ordered == ordered {
            let checkbox: String
            if let checked = item.taskState {
                checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            } else {
                checkbox = ""
            }

            let kind: MarkdownLineKind = ordered ? .orderedList : .unorderedList
            let style = Self.styleAttribute(color: blockHighlightColor(markdownKind: kind, sourceLines: [item.sourceLine], context: context))
            items.append("<li\(style)>\(checkbox)\(renderInline(item.text, context: context))</li>")
            index += 1

            guard index < lines.count else { break }
            currentItem = parseListItem(lines[index])
        }

        return "<\(tag)>\n\(items.joined(separator: "\n"))\n</\(tag)>"
    }

    private func renderTable(_ lines: [String], index: inout Int, context: RenderContext) -> String {
        let headers = splitTableRow(lines[index])
        let alignments = splitTableRow(lines[index + 1]).map(Self.tableAlignment)
        index += 2

        var bodyRows: [[String]] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains("|"), parseFenceStart(lines[index]) == nil else {
                break
            }

            if isTableSeparator(trimmed) {
                break
            }

            bodyRows.append(splitTableRow(lines[index]))
            index += 1
        }

        let headerHTML = headers.enumerated().map { column, value in
            "<th\(Self.alignmentAttribute(alignments, column: column))>\(renderInline(value, context: context))</th>"
        }.joined()

        let rowsHTML = bodyRows.map { row in
            let cells = row.enumerated().map { column, value in
                "<td\(Self.alignmentAttribute(alignments, column: column))>\(renderInline(value, context: context))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined(separator: "\n")

        return """
        <div class="table-wrap">
        <table>
        <thead><tr>\(headerHTML)</tr></thead>
        <tbody>
        \(rowsHTML)
        </tbody>
        </table>
        </div>
        """
    }

    private func renderParagraph(_ lines: [String], index: inout Int, context: RenderContext) -> String {
        var paragraphLines: [String] = []

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || isStructuralStart(lines, at: index) {
                break
            }

            paragraphLines.append(trimmed)
            index += 1
        }

        let style = Self.styleAttribute(color: blockHighlightColor(markdownKind: nil, sourceLines: paragraphLines, context: context))
        return "<p\(style)>\(renderInline(paragraphLines.joined(separator: " "), context: context))</p>"
    }

    private func blockHighlightColor(
        markdownKind: MarkdownLineKind?,
        sourceLines: [String],
        context: RenderContext
    ) -> HighlightColor? {
        guard let configuration = context.highlightConfiguration else {
            return nil
        }

        for rule in configuration.keywordRules where rule.scope == .line {
            if sourceLines.contains(where: { $0.contains(rule.keyword) }) {
                return rule.color
            }
        }

        guard let markdownKind else {
            return nil
        }
        return configuration.markdownColors[markdownKind]
    }

    private func renderInline(_ text: String, context: RenderContext) -> String {
        var output = ""
        var index = text.startIndex
        var textBuffer = ""

        func flushTextBuffer() {
            guard !textBuffer.isEmpty else {
                return
            }

            output += Self.renderHighlightedTextSegment(textBuffer, context: context)
            textBuffer.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let remaining = text[index...]

            if remaining.hasPrefix("!["),
               let rendered = renderImage(in: text, index: &index, context: context) {
                flushTextBuffer()
                output += rendered
                continue
            }

            if remaining.hasPrefix("["),
               let rendered = renderLink(in: text, index: &index, context: context) {
                flushTextBuffer()
                output += rendered
                continue
            }

            if remaining.hasPrefix("`"),
               let close = text[text.index(after: index)..<text.endIndex].firstIndex(of: "`") {
                flushTextBuffer()
                let contentStart = text.index(after: index)
                let style = Self.styleAttribute(color: context.highlightConfiguration?.inlineColors[.inlineCode])
                output += "<code\(style)>\(Self.escapeHTML(String(text[contentStart..<close])))</code>"
                index = text.index(after: close)
                continue
            }

            if remaining.hasPrefix("~~"),
               let close = text.range(of: "~~", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                flushTextBuffer()
                let contentStart = text.index(index, offsetBy: 2)
                output += "<del>\(renderInline(String(text[contentStart..<close.lowerBound]), context: context))</del>"
                index = close.upperBound
                continue
            }

            if remaining.hasPrefix("**"),
               let close = text.range(of: "**", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                flushTextBuffer()
                let contentStart = text.index(index, offsetBy: 2)
                let style = Self.styleAttribute(color: context.highlightConfiguration?.inlineColors[.boldText])
                output += "<strong\(style)>\(renderInline(String(text[contentStart..<close.lowerBound]), context: context))</strong>"
                index = close.upperBound
                continue
            }

            if remaining.hasPrefix("__"),
               let close = text.range(of: "__", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                flushTextBuffer()
                let contentStart = text.index(index, offsetBy: 2)
                let style = Self.styleAttribute(color: context.highlightConfiguration?.inlineColors[.boldText])
                output += "<strong\(style)>\(renderInline(String(text[contentStart..<close.lowerBound]), context: context))</strong>"
                index = close.upperBound
                continue
            }

            if remaining.hasPrefix("*"),
               !remaining.hasPrefix("**"),
               let close = text[text.index(after: index)..<text.endIndex].firstIndex(of: "*") {
                flushTextBuffer()
                let contentStart = text.index(after: index)
                output += "<em>\(renderInline(String(text[contentStart..<close]), context: context))</em>"
                index = text.index(after: close)
                continue
            }

            if remaining.hasPrefix("_"),
               !remaining.hasPrefix("__"),
               let close = text[text.index(after: index)..<text.endIndex].firstIndex(of: "_") {
                flushTextBuffer()
                let contentStart = text.index(after: index)
                output += "<em>\(renderInline(String(text[contentStart..<close]), context: context))</em>"
                index = text.index(after: close)
                continue
            }

            textBuffer.append(text[index])
            index = text.index(after: index)
        }

        flushTextBuffer()
        return output
    }

    private func renderImage(in text: String, index: inout String.Index, context: RenderContext) -> String? {
        let altStart = text.index(index, offsetBy: 2)
        guard let closeBracket = text[altStart..<text.endIndex].firstIndex(of: "]") else {
            return nil
        }

        let openParen = text.index(after: closeBracket)
        guard openParen < text.endIndex, text[openParen] == "(",
              let closeParen = text[text.index(after: openParen)..<text.endIndex].firstIndex(of: ")") else {
            return nil
        }

        let alt = String(text[altStart..<closeBracket])
        let destination = String(text[text.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
        let resolvedDestination = context.options.imageSourceResolver?(destination, context.fileURL) ?? destination
        index = text.index(after: closeParen)
        return "<img src=\"\(Self.escapeAttribute(resolvedDestination))\" alt=\"\(Self.escapeAttribute(alt))\">"
    }

    private func renderLink(in text: String, index: inout String.Index, context: RenderContext) -> String? {
        let labelStart = text.index(after: index)
        guard let closeBracket = text[labelStart..<text.endIndex].firstIndex(of: "]") else {
            return nil
        }

        let openParen = text.index(after: closeBracket)
        guard openParen < text.endIndex, text[openParen] == "(",
              let closeParen = text[text.index(after: openParen)..<text.endIndex].firstIndex(of: ")") else {
            return nil
        }

        let label = String(text[labelStart..<closeBracket])
        let destination = String(text[text.index(after: openParen)..<closeParen]).trimmingCharacters(in: .whitespaces)
        index = text.index(after: closeParen)
        return "<a href=\"\(Self.escapeAttribute(destination))\">\(renderInline(label, context: context))</a>"
    }

    private static func renderHighlightedTextSegment(_ text: String, context: RenderContext) -> String {
        guard let configuration = context.highlightConfiguration else {
            return escapeHTML(text)
        }

        let keywordRules = configuration.keywordRules.filter { $0.scope == .keyword }
        guard configuration.inlineColors[.quotedText] != nil || !keywordRules.isEmpty else {
            return escapeHTML(text)
        }

        guard let quotedTextColor = configuration.inlineColors[.quotedText] else {
            return renderKeywordHighlightedText(text, rules: keywordRules)
        }

        let source = text as NSString
        let quotedRanges = quotedTextRanges(in: source)
        guard !quotedRanges.isEmpty else {
            return renderKeywordHighlightedText(text, rules: keywordRules)
        }

        var output = ""
        var cursor = 0
        for range in quotedRanges {
            if range.location > cursor {
                output += renderKeywordHighlightedText(
                    source.substring(with: NSRange(location: cursor, length: range.location - cursor)),
                    rules: keywordRules
                )
            }

            output += "<span\(styleAttribute(color: quotedTextColor))>"
            output += renderKeywordHighlightedText(source.substring(with: range), rules: keywordRules)
            output += "</span>"
            cursor = NSMaxRange(range)
        }

        if cursor < source.length {
            output += renderKeywordHighlightedText(
                source.substring(with: NSRange(location: cursor, length: source.length - cursor)),
                rules: keywordRules
            )
        }

        return output
    }

    private static func renderKeywordHighlightedText(_ text: String, rules: [HighlightKeywordRule]) -> String {
        guard !rules.isEmpty else {
            return escapeHTML(text)
        }

        let source = text as NSString
        var output = ""
        var cursor = 0

        while cursor < source.length {
            var bestMatch: (range: NSRange, color: HighlightColor, ruleIndex: Int)?
            let searchRange = NSRange(location: cursor, length: source.length - cursor)

            for (ruleIndex, rule) in rules.enumerated() {
                let found = source.range(of: rule.keyword, options: [], range: searchRange)
                guard found.location != NSNotFound else {
                    continue
                }

                if let current = bestMatch {
                    if found.location < current.range.location ||
                        (found.location == current.range.location && ruleIndex > current.ruleIndex) {
                        bestMatch = (found, rule.color, ruleIndex)
                    }
                } else {
                    bestMatch = (found, rule.color, ruleIndex)
                }
            }

            guard let match = bestMatch else {
                output += escapeHTML(source.substring(with: NSRange(location: cursor, length: source.length - cursor)))
                break
            }

            if match.range.location > cursor {
                output += escapeHTML(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }

            output += "<span\(styleAttribute(color: match.color))>"
            output += escapeHTML(source.substring(with: match.range))
            output += "</span>"
            cursor = match.range.location + max(match.range.length, 1)
        }

        return output
    }

    private static func quotedTextRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0

        while index < source.length {
            let opening = source.character(at: index)
            guard let closing = closingQuote(for: opening) else {
                index += 1
                continue
            }

            if opening == InlineCharacterCode.apostrophe,
               !isValidASCIIQuoteStart(source: source, index: index) {
                index += 1
                continue
            }

            var searchIndex = index + 1
            var didMatch = false
            while searchIndex < source.length,
                  searchIndex - index - 1 <= InlinePatternLimit.maximumQuotedTextLength {
                guard source.character(at: searchIndex) == closing else {
                    searchIndex += 1
                    continue
                }

                let contentLength = searchIndex - index - 1
                guard contentLength > 0 else {
                    break
                }

                if opening == InlineCharacterCode.apostrophe,
                   !isValidASCIIQuoteEnd(source: source, index: searchIndex) {
                    searchIndex += 1
                    continue
                }

                ranges.append(NSRange(location: index, length: searchIndex - index + 1))
                index = searchIndex + 1
                didMatch = true
                break
            }

            if !didMatch {
                index += 1
            }
        }

        return ranges
    }

    private static func closingQuote(for opening: unichar) -> unichar? {
        switch opening {
        case InlineCharacterCode.leftSingleQuote:
            return InlineCharacterCode.rightSingleQuote
        case InlineCharacterCode.leftDoubleQuote:
            return InlineCharacterCode.rightDoubleQuote
        case InlineCharacterCode.doubleQuote:
            return InlineCharacterCode.doubleQuote
        case InlineCharacterCode.apostrophe:
            return InlineCharacterCode.apostrophe
        case InlineCharacterCode.leftCornerBracket:
            return InlineCharacterCode.rightCornerBracket
        case InlineCharacterCode.leftWhiteCornerBracket:
            return InlineCharacterCode.rightWhiteCornerBracket
        default:
            return nil
        }
    }

    private static func isValidASCIIQuoteStart(source: NSString, index: Int) -> Bool {
        guard index > 0 else {
            return true
        }
        return !isASCIILetterOrDigit(source.character(at: index - 1))
    }

    private static func isValidASCIIQuoteEnd(source: NSString, index: Int) -> Bool {
        let nextIndex = index + 1
        guard nextIndex < source.length else {
            return true
        }
        return !isASCIILetterOrDigit(source.character(at: nextIndex))
    }

    private static func isASCIILetterOrDigit(_ character: unichar) -> Bool {
        (character >= 48 && character <= 57) ||
        (character >= 65 && character <= 90) ||
        (character >= 97 && character <= 122)
    }

    private static func styleAttribute(color: HighlightColor?) -> String {
        guard let color else {
            return ""
        }

        return " style=\"color: \(escapeAttribute(color.hex))\""
    }

    private func isStructuralStart(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return parseFenceStart(line) != nil
            || parseHeading(line) != nil
            || isHorizontalRule(line)
            || trimmed.hasPrefix(">")
            || parseListItem(line) != nil
            || isTableStart(lines, at: index)
    }

    private func parseFenceStart(_ line: String) -> FenceStart? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
            return nil
        }

        let marker = String(trimmed.prefix(3))
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return FenceStart(marker: marker, language: language)
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String, kind: MarkdownLineKind)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }

        let afterHashes = trimmed.dropFirst(hashes)
        guard afterHashes.first == " " else { return nil }

        guard let kind = MarkdownLineKind.headingKind(forLevel: hashes) else {
            return nil
        }

        return (hashes, String(afterHashes.dropFirst()).trimmingCharacters(in: .whitespaces), kind)
    }

    private func parseListItem(_ line: String) -> ListItem? {
        let unorderedPattern = #"^\s*[-*+]\s+(\[[ xX]\]\s+)?(.+)$"#
        let orderedPattern = #"^\s*\d+[.)]\s+(\[[ xX]\]\s+)?(.+)$"#

        if let captures = firstMatch(unorderedPattern, in: line) {
            return ListItem(ordered: false, text: captures[1], taskState: Self.taskState(from: captures[0]), sourceLine: line)
        }

        if let captures = firstMatch(orderedPattern, in: line) {
            return ListItem(ordered: true, text: captures[1], taskState: Self.taskState(from: captures[0]), sourceLine: line)
        }

        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.numberOfRanges >= 3 else {
            return nil
        }

        var captures: [String] = []
        for captureIndex in 1..<match.numberOfRanges {
            let captureRange = match.range(at: captureIndex)
            if captureRange.location == NSNotFound {
                captures.append("")
                continue
            }
            guard let range = Range(captureRange, in: text) else {
                captures.append("")
                continue
            }
            captures.append(String(text[range]))
        }

        return captures
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } || compact.allSatisfy { $0 == "*" } || compact.allSatisfy { $0 == "_" }
    }

    private func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count,
              lines[index].contains("|") else {
            return false
        }

        return isTableSeparator(lines[index + 1])
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard cells.count >= 2 else { return false }

        return cells.allSatisfy { cell in
            cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private func splitTableRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") {
            row.removeFirst()
        }
        if row.hasSuffix("|") {
            row.removeLast()
        }

        return row.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAlignment(_ separator: String) -> String? {
        if separator.hasPrefix(":"), separator.hasSuffix(":") {
            return "center"
        }
        if separator.hasSuffix(":") {
            return "right"
        }
        if separator.hasPrefix(":") {
            return "left"
        }
        return nil
    }

    private static func alignmentAttribute(_ alignments: [String?], column: Int) -> String {
        guard alignments.indices.contains(column), let alignment = alignments[column] else {
            return ""
        }
        return " style=\"text-align: \(alignment)\""
    }

    private static func taskState(from raw: String) -> Bool? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized == "[x]" {
            return true
        }
        if normalized == "[ ]" {
            return false
        }
        return nil
    }

    private static func headingID(from text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var previousWasDash = false

        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                result.append("-")
                previousWasDash = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "section" : trimmed
    }

    static func escapeHTML(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "&":
                escaped += "&amp;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&#39;"
            default:
                escaped.append(character)
            }
        }

        return escaped
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeHTML(text)
    }

    private static func javaScriptStringLiteral(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)

        for character in text {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "'":
                escaped += "\\'"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\u{2028}":
                escaped += "\\u2028"
            case "\u{2029}":
                escaped += "\\u2029"
            default:
                escaped.append(character)
            }
        }

        return "'\(escaped)'"
    }

    private static func javaScriptArrayLiteralChunks(_ text: String, chunkSize: Int = 12000) -> String {
        guard !text.isEmpty else {
            return "[]"
        }

        var chunks: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(javaScriptStringLiteral(String(text[index..<end])))
            index = end
        }

        return "[\(chunks.joined(separator: ","))]"
    }

    static func errorPageCSS(theme: DocumentTheme, palette: MiniMDThemePalette? = nil) -> String {
        let resolvedPalette = palette ?? .default(for: theme)
        return fallbackCSS(theme: theme) + "\n" + themeVariableCSS(palette: resolvedPalette)
    }

    private static func themeVariableCSS(palette: MiniMDThemePalette) -> String {
        """
        :root {
          --mini-md-foreground: \(palette.foregroundHex);
          --mini-md-background: \(palette.backgroundHex);
        }

        html,
        body,
        #markdown-body {
          background: var(--mini-md-background);
          color: var(--mini-md-foreground);
        }

        #markdown-body h1,
        #markdown-body h2,
        #markdown-body h3,
        #markdown-body h4,
        #markdown-body h5,
        #markdown-body h6,
        #markdown-body strong {
          color: var(--mini-md-foreground);
        }
        """
    }

    private static func mermaidScripts(theme: DocumentTheme, bundle: Bundle) -> String {
        let mermaidSource = loadResource(named: "mermaid.min", extension: "js", bundle: bundle, fallback: "")
            .replacingOccurrences(
                of: #"globalThis["mermaid"] = globalThis.__esbuild_esm_mermaid_nm["mermaid"].default;"#,
                with: #"globalThis["mermaid"] = __esbuild_esm_mermaid_nm["mermaid"].default || __esbuild_esm_mermaid_nm["mermaid"];"#
            )
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
        let encodedMermaidSource = Data(mermaidSource.utf8).base64EncodedString()
        let mermaidSourceChunks = javaScriptArrayLiteralChunks(encodedMermaidSource)
        let mermaidTheme = theme == .dark ? "dark" : "default"

        if mermaidSource.isEmpty {
            return """
            <script>
            document.querySelectorAll('.mermaid').forEach((element) => {
              element.classList.add('mermaid-error');
              element.innerHTML = '<div class="mermaid-error-title">Mermaid resource is missing.</div><pre>' + element.textContent + '</pre>';
            });
            </script>
            """
        }

        return """
        <script>
        (function () {
          function decodeBase64UTF8(encoded) {
            const binary = window.atob(encoded);
            if (window.TextDecoder) {
              const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
              return new TextDecoder('utf-8').decode(bytes);
            }
            return decodeURIComponent(Array.prototype.map.call(binary, (character) => {
              return '%' + ('00' + character.charCodeAt(0).toString(16)).slice(-2);
            }).join(''));
          }

          try {
            const mermaidBundleSource = decodeBase64UTF8(\(mermaidSourceChunks).join(''));
            new Function(mermaidBundleSource)();
          } catch (error) {
            window.__miniMDMermaidLoadError = error && error.stack ? String(error.stack) : String(error);
            return;
          }

          if (!window.mermaid) {
            window.__miniMDMermaidLoadError = 'Mermaid runtime was not attached.';
            return;
          }

          window.__miniMDMermaidLoadError = '';
        }());
        </script>
        <script>
        (function () {
          function escapeHTML(value) {
            return value
              .replace(/&/g, '&amp;')
              .replace(/</g, '&lt;')
              .replace(/>/g, '&gt;')
              .replace(/"/g, '&quot;')
              .replace(/'/g, '&#39;');
          }

          function mermaidSource(element) {
            const encoded = element.getAttribute('data-mini-md-mermaid-source');
            if (encoded) {
              try {
                const binary = window.atob(encoded);
                if (window.TextDecoder) {
                  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
                  return new TextDecoder('utf-8').decode(bytes);
                }
                return decodeURIComponent(Array.prototype.map.call(binary, (character) => {
                  return '%' + ('00' + character.charCodeAt(0).toString(16)).slice(-2);
                }).join(''));
              } catch (_) {
                return element.textContent || '';
              }
            }
            return element.textContent || '';
          }

          async function renderMermaid() {
            if (!window.mermaid) {
              document.querySelectorAll('.mermaid').forEach((element) => {
                const source = mermaidSource(element);
                const loadError = window.__miniMDMermaidLoadError ? '\\n\\n' + window.__miniMDMermaidLoadError : '';
                element.classList.add('mermaid-error');
                element.innerHTML = '<div class="mermaid-error-title">Mermaid resource is unavailable.</div><pre>' + escapeHTML(source + loadError) + '</pre>';
              });
              return;
            }

            mermaid.initialize({
              startOnLoad: false,
              theme: '\(mermaidTheme)',
              securityLevel: 'loose'
            });

            const blocks = Array.from(document.querySelectorAll('.mermaid'));
            for (let index = 0; index < blocks.length; index += 1) {
              const element = blocks[index];
              const source = mermaidSource(element);
              try {
                const result = await mermaid.render('mini-md-mermaid-' + index + '-' + Date.now(), source);
                element.innerHTML = result.svg;
                if (result.bindFunctions) {
                  result.bindFunctions(element);
                }
              } catch (error) {
                element.classList.add('mermaid-error');
                element.innerHTML = '<div class="mermaid-error-title">Mermaid render error.</div><pre>' + escapeHTML(source) + '</pre>';
              }
            }
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', renderMermaid);
          } else {
            renderMermaid();
          }
        }());
        </script>
        """
    }

    private static func loadResource(named name: String, extension fileExtension: String, bundle: Bundle, fallback: String) -> String {
        let cacheKey = "\(bundle.bundleIdentifier ?? bundle.bundlePath)::\(name).\(fileExtension)"
        if let cachedText = resourceCache.value(for: cacheKey) {
            return cachedText
        }

        let text: String
        if let url = bundle.url(forResource: name, withExtension: fileExtension),
           let data = try? Data(contentsOf: url),
           let loadedText = String(data: data, encoding: .utf8) {
            text = loadedText
        } else {
            text = fallback
        }

        resourceCache.store(text, for: cacheKey)
        return text
    }

    private static func fallbackCSS(theme: DocumentTheme) -> String {
        switch theme {
        case .light:
            return """
            html, body { margin: 0; min-height: 100%; background: var(--mini-md-background, #fbfaf7); color: var(--mini-md-foreground, #25292e); }
            body { font: 16px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
            #markdown-body { box-sizing: border-box; max-width: 1120px; margin: 0 auto; padding: calc(34px + var(--mini-md-window-top-inset, 0px)) 34px 34px; line-height: 1.62; }
            pre, code { font-family: "SF Mono", Menlo, monospace; }
            pre { overflow: auto; padding: 14px; border-radius: 8px; background: #f0f2f3; }
            a { color: #1261a6; }
            img { max-width: 100%; height: auto; }
            table { border-collapse: collapse; width: 100%; }
            th, td { border: 1px solid #d5dadf; padding: 8px 10px; }
            blockquote { margin-left: 0; padding-left: 16px; border-left: 4px solid #ccd3d8; color: #4f5963; }
            """
        case .dark:
            return """
            html, body { margin: 0; min-height: 100%; background: var(--mini-md-background, #252525); color: var(--mini-md-foreground, #efead8); }
            body { font: 16px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
            #markdown-body { box-sizing: border-box; max-width: 1120px; margin: 0 auto; padding: calc(34px + var(--mini-md-window-top-inset, 0px)) 34px 34px; line-height: 1.62; }
            pre, code { font-family: "SF Mono", Menlo, monospace; }
            pre { overflow: auto; padding: 14px; border-radius: 8px; background: #22272d; }
            a { color: #72aee6; }
            img { max-width: 100%; height: auto; }
            table { border-collapse: collapse; width: 100%; }
            th, td { border: 1px solid #3b444f; padding: 8px 10px; }
            blockquote { margin-left: 0; padding-left: 16px; border-left: 4px solid #4d5965; color: #c8c1b6; }
            """
        }
    }

    private enum InlinePatternLimit {
        static let maximumQuotedTextLength = 300
    }

    private enum InlineCharacterCode {
        static let doubleQuote: unichar = 34
        static let apostrophe: unichar = 39
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

private extension MarkdownLineKind {
    static func headingKind(forLevel level: Int) -> MarkdownLineKind? {
        switch level {
        case 1:
            return .heading1
        case 2:
            return .heading2
        case 3:
            return .heading3
        case 4:
            return .heading4
        case 5:
            return .heading5
        case 6:
            return .heading6
        default:
            return nil
        }
    }
}
