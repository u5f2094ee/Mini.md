import Foundation

struct MarkdownFenceMarker: Equatable {
    let character: unichar
    let length: Int
}

struct MarkdownFenceState {
    var openingMarker: MarkdownFenceMarker?

    var isInsideFence: Bool {
        openingMarker != nil
    }
}

enum MarkdownLineClassifier {
    private static let space: unichar = 32
    private static let tab: unichar = 9
    private static let hash: unichar = 35
    private static let dash: unichar = 45
    private static let asterisk: unichar = 42
    private static let plus: unichar = 43
    private static let period: unichar = 46
    private static let rightParenthesis: unichar = 41
    private static let greaterThan: unichar = 62
    private static let backtick: unichar = 96
    private static let tilde: unichar = 126

    static func classify(_ lineText: NSString) -> MarkdownLineKind? {
        guard lineText.length > 0,
              let markerStart = markerStart(in: lineText),
              markerStart < lineText.length else {
            return nil
        }

        let first = lineText.character(at: markerStart)
        if first == hash {
            return headingKind(in: lineText, markerStart: markerStart)
        }

        if first == dash || first == asterisk || first == plus {
            let nextIndex = markerStart + 1
            if isSpaceTabOrEnd(in: lineText, at: nextIndex),
               nextIndex < lineText.length {
                return .unorderedList
            }
            return nil
        }

        if isDigit(first) {
            return orderedListKind(in: lineText, markerStart: markerStart)
        }

        if first == greaterThan,
           isSpaceTabOrEnd(in: lineText, at: markerStart + 1) {
            return .quote
        }

        return nil
    }

    static func updateFenceState(for lineText: NSString, state: inout MarkdownFenceState) -> Bool {
        guard let marker = fenceMarker(in: lineText) else {
            return false
        }

        guard let openingMarker = state.openingMarker else {
            state.openingMarker = marker
            return true
        }

        if marker.character == openingMarker.character,
           marker.length >= openingMarker.length {
            state.openingMarker = nil
            return true
        }

        return false
    }

    private static func fenceMarker(in lineText: NSString) -> MarkdownFenceMarker? {
        guard let markerStart = markerStart(in: lineText),
              markerStart < lineText.length else {
            return nil
        }

        let character = lineText.character(at: markerStart)
        guard character == backtick || character == tilde else {
            return nil
        }

        var index = markerStart
        while index < lineText.length,
              lineText.character(at: index) == character {
            index += 1
        }

        let length = index - markerStart
        guard length >= 3 else {
            return nil
        }

        return MarkdownFenceMarker(character: character, length: length)
    }

    private static func headingKind(in lineText: NSString, markerStart: Int) -> MarkdownLineKind? {
        var index = markerStart
        while index < lineText.length,
              lineText.character(at: index) == hash {
            index += 1
        }

        let level = index - markerStart
        guard (1...6).contains(level),
              isSpaceTabOrEnd(in: lineText, at: index) else {
            return nil
        }

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

    private static func orderedListKind(in lineText: NSString, markerStart: Int) -> MarkdownLineKind? {
        var index = markerStart
        var digitCount = 0
        while index < lineText.length,
              isDigit(lineText.character(at: index)) {
            digitCount += 1
            if digitCount > 9 {
                return nil
            }
            index += 1
        }

        guard digitCount > 0,
              index < lineText.length else {
            return nil
        }

        let marker = lineText.character(at: index)
        guard marker == period || marker == rightParenthesis else {
            return nil
        }

        guard isSpaceTabOrEnd(in: lineText, at: index + 1) else {
            return nil
        }

        return .orderedList
    }

    private static func markerStart(in lineText: NSString) -> Int? {
        var index = 0
        var spaceCount = 0

        while index < lineText.length,
              lineText.character(at: index) == space {
            spaceCount += 1
            if spaceCount > 3 {
                return nil
            }
            index += 1
        }

        return index
    }

    private static func isSpaceTabOrEnd(in lineText: NSString, at index: Int) -> Bool {
        guard index < lineText.length else {
            return true
        }

        let character = lineText.character(at: index)
        return character == space || character == tab
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }
}
