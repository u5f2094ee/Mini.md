import AppKit

enum HighlightScope: String, Sendable {
    case keyword
    case line
}

enum MarkdownLineKind: String, CaseIterable, Sendable {
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6
    case unorderedList
    case orderedList
    case quote
}

enum InlineHighlightKind: String, CaseIterable, Sendable {
    case quotedText
    case boldText
    case inlineCode
}

struct HighlightColor: Equatable, Sendable {
    let hex: String
    private let red: Double
    private let green: Double
    private let blue: Double

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: 1
        )
    }

    static func parse(_ rawValue: Any?) -> HighlightColor? {
        guard let rawString = rawValue as? String else {
            return nil
        }

        let value = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 7,
              value.first == "#" else {
            return nil
        }

        let hexDigits = String(value.dropFirst())
        guard hexDigits.unicodeScalars.allSatisfy(isHexDigit),
              let rawNumber = UInt32(hexDigits, radix: 16) else {
            return nil
        }

        let red = Double((rawNumber >> 16) & 0xFF) / 255.0
        let green = Double((rawNumber >> 8) & 0xFF) / 255.0
        let blue = Double(rawNumber & 0xFF) / 255.0

        return HighlightColor(
            hex: "#" + hexDigits.uppercased(),
            red: red,
            green: green,
            blue: blue
        )
    }

    private static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
    }
}

struct HighlightKeywordRule: Sendable {
    let keyword: String
    let scope: HighlightScope
    let color: HighlightColor
}

struct HighlightThemeConfiguration: Sendable {
    let markdownColors: [MarkdownLineKind: HighlightColor]
    let inlineColors: [InlineHighlightKind: HighlightColor]
    let keywordRules: [HighlightKeywordRule]

    static let empty = HighlightThemeConfiguration(
        markdownColors: [:],
        inlineColors: [:],
        keywordRules: []
    )
}

struct HighlightConfiguration: Sendable {
    // Deprecated compatibility field: settings.json owns the edit/render enable switches.
    let enabled: Bool
    let light: HighlightThemeConfiguration
    let dark: HighlightThemeConfiguration

    static let empty = HighlightConfiguration(
        enabled: true,
        light: .empty,
        dark: .empty
    )

    func themeConfiguration(for theme: DocumentTheme) -> HighlightThemeConfiguration {
        switch theme {
        case .light:
            return light
        case .dark:
            return dark
        }
    }
}
