import Foundation

struct HighlightFileSignature: Equatable {
    let modificationTime: TimeInterval
    let size: UInt64
}

final class HighlightConfigurationStore: @unchecked Sendable {
    static let shared = HighlightConfigurationStore()

    let configurationDirectoryURL: URL
    let configurationFileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedConfiguration: HighlightConfiguration?
    private var cachedSignature: HighlightFileSignature?
    private var lastGoodConfiguration: HighlightConfiguration?

    init(
        configurationDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mini.md", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.configurationDirectoryURL = configurationDirectoryURL
        self.configurationFileURL = configurationDirectoryURL.appendingPathComponent("highlight.json")
        self.fileManager = fileManager
    }

    func configuration() -> HighlightConfiguration {
        ensureConfigurationFile()
        let signature = fileSignature()

        lock.lock()
        if let cachedConfiguration,
           cachedSignature == signature {
            lock.unlock()
            return cachedConfiguration
        }
        let previousGood = lastGoodConfiguration
        lock.unlock()

        guard let data = try? Data(contentsOf: configurationFileURL) else {
            return cacheAndReturn(.empty, signature: signature, markAsLastGood: false)
        }

        let parsedConfiguration = Self.parse(
            data: data,
            previousGoodConfiguration: previousGood,
            sourceDescription: configurationFileURL.path
        )
        return cacheAndReturn(parsedConfiguration, signature: signature, markAsLastGood: true)
    }

    func ensureConfigurationFile() {
        do {
            try fileManager.createDirectory(at: configurationDirectoryURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: configurationFileURL.path) {
                try Self.defaultConfigurationTemplate.write(to: configurationFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Mini.md could not create highlight configuration %@: %@", configurationFileURL.path, String(describing: error))
        }
    }

    func invalidateCache() {
        lock.lock()
        cachedConfiguration = nil
        cachedSignature = nil
        lock.unlock()
    }

    func currentFileSignature() -> HighlightFileSignature? {
        fileSignature()
    }

    func refreshAfterFileSystemEvent(previousSignature: inout HighlightFileSignature?) -> Bool {
        ensureConfigurationFile()
        let newSignature = fileSignature()
        guard newSignature != previousSignature else {
            return false
        }

        previousSignature = newSignature
        invalidateCache()
        return true
    }

    static func parse(
        data: Data,
        previousGoodConfiguration: HighlightConfiguration?,
        sourceDescription: String
    ) -> HighlightConfiguration {
        do {
            guard let text = String(data: data, encoding: .utf8),
                  let jsonData = removingCommentLines(from: text).data(using: .utf8) else {
                NSLog("Mini.md highlight configuration is not valid UTF-8: %@", sourceDescription)
                return previousGoodConfiguration ?? .empty
            }

            guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                NSLog("Mini.md highlight configuration is not a JSON object: %@", sourceDescription)
                return previousGoodConfiguration ?? .empty
            }

            return HighlightConfiguration(
                enabled: true,
                light: parseThemeConfiguration(root["light"], themeName: "light", sourceDescription: sourceDescription),
                dark: parseThemeConfiguration(root["dark"], themeName: "dark", sourceDescription: sourceDescription)
            )
        } catch {
            NSLog("Mini.md could not parse highlight configuration %@: %@", sourceDescription, String(describing: error))
            return previousGoodConfiguration ?? .empty
        }
    }

    private static func removingCommentLines(from text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func cacheAndReturn(
        _ configuration: HighlightConfiguration,
        signature: HighlightFileSignature?,
        markAsLastGood: Bool
    ) -> HighlightConfiguration {
        lock.lock()
        cachedConfiguration = configuration
        cachedSignature = signature
        if markAsLastGood {
            lastGoodConfiguration = configuration
        }
        lock.unlock()
        return configuration
    }

    private func fileSignature() -> HighlightFileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: configurationFileURL.path) else {
            return nil
        }

        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return HighlightFileSignature(modificationTime: modificationTime, size: size)
    }

    private static func parseThemeConfiguration(
        _ rawValue: Any?,
        themeName: String,
        sourceDescription: String
    ) -> HighlightThemeConfiguration {
        guard let dictionary = rawValue as? [String: Any] else {
            NSLog("Mini.md highlight configuration missing %@ theme object in %@", themeName, sourceDescription)
            return .empty
        }

        let markdownColors = parseMarkdownColors(
            dictionary["markdown"],
            themeName: themeName,
            sourceDescription: sourceDescription
        )
        let inlineColors = parseInlineColors(
            dictionary["inline"],
            themeName: themeName,
            sourceDescription: sourceDescription
        )
        let keywordRules = parseKeywordRules(
            dictionary["keywords"],
            themeName: themeName,
            sourceDescription: sourceDescription
        )

        return HighlightThemeConfiguration(
            markdownColors: markdownColors,
            inlineColors: inlineColors,
            keywordRules: keywordRules
        )
    }

    private static func parseMarkdownColors(
        _ rawValue: Any?,
        themeName: String,
        sourceDescription: String
    ) -> [MarkdownLineKind: HighlightColor] {
        guard let dictionary = rawValue as? [String: Any] else {
            return [:]
        }

        var result: [MarkdownLineKind: HighlightColor] = [:]
        for kind in MarkdownLineKind.allCases {
            guard let rawColor = dictionary[kind.rawValue] else {
                continue
            }

            guard let color = HighlightColor.parse(rawColor) else {
                NSLog("Mini.md ignored invalid %@ markdown color %@ in %@", themeName, kind.rawValue, sourceDescription)
                continue
            }

            result[kind] = color
        }
        return result
    }

    private static func parseInlineColors(
        _ rawValue: Any?,
        themeName: String,
        sourceDescription: String
    ) -> [InlineHighlightKind: HighlightColor] {
        guard let dictionary = rawValue as? [String: Any] else {
            return [:]
        }

        var result: [InlineHighlightKind: HighlightColor] = [:]
        for kind in InlineHighlightKind.allCases {
            guard let rawColor = dictionary[kind.rawValue] else {
                continue
            }

            guard let color = HighlightColor.parse(rawColor) else {
                NSLog("Mini.md ignored invalid %@ inline color %@ in %@", themeName, kind.rawValue, sourceDescription)
                continue
            }

            result[kind] = color
        }
        return result
    }

    private static func parseKeywordRules(
        _ rawValue: Any?,
        themeName: String,
        sourceDescription: String
    ) -> [HighlightKeywordRule] {
        guard let rawRules = rawValue as? [Any] else {
            return []
        }

        var result: [HighlightKeywordRule] = []
        for (index, rawRule) in rawRules.enumerated() {
            guard let dictionary = rawRule as? [String: Any] else {
                NSLog("Mini.md ignored non-object %@ keyword rule %d in %@", themeName, index, sourceDescription)
                continue
            }

            guard let keyword = dictionary["keyword"] as? String,
                  !keyword.isEmpty else {
                NSLog("Mini.md ignored %@ keyword rule %d with missing keyword in %@", themeName, index, sourceDescription)
                continue
            }

            let rawScope = dictionary["scope"] as? String ?? HighlightScope.keyword.rawValue
            guard let scope = HighlightScope(rawValue: rawScope) else {
                NSLog("Mini.md ignored %@ keyword rule %d with invalid scope in %@", themeName, index, sourceDescription)
                continue
            }

            guard let color = HighlightColor.parse(dictionary["color"]) else {
                NSLog("Mini.md ignored %@ keyword rule %d with invalid color in %@", themeName, index, sourceDescription)
                continue
            }

            result.append(HighlightKeywordRule(keyword: keyword, scope: scope, color: color))
        }
        return result
    }

    private static let defaultConfigurationTemplate = """
    {
      // highlight.json controls only colors and keyword rules.
      // Enable or disable edit/render highlighting in ~/Mini.md/settings.json.
      // Use #RRGGBB colors. Unknown fields are ignored.
      //
      // Supported markdown keys:
      // heading1, heading2, heading3, heading4, heading5, heading6,
      // unorderedList, orderedList, quote.
      //
      // Supported inline keys:
      // quotedText, boldText, inlineCode.
      //
      // keywords is an array of literal, case-sensitive string rules.
      // scope "keyword" colors only the matched text.
      // scope "line" colors the entire source line in edit mode and the nearest block in render mode.
      //
      // Markdown syntax markers that disappear after rendering, such as ``` fences,
      // are not visible in render mode. Fence marker keywords are matched only as
      // ordinary standalone marker lines in edit mode and do not expand to code contents.
      "light": {
        "markdown": {
          "heading1": "#0B57D0",
          "heading2": "#5E35B1",
          "heading3": "#00796B",
          "heading4": "#5F6368",
          "heading5": "#5F6368",
          "heading6": "#5F6368",
          "unorderedList": "#7A4D00",
          "orderedList": "#7A4D00",
          "quote": "#188038"
        },
        "inline": {
          "quotedText": "#A142F4",
          "boldText": "#B06000",
          "inlineCode": "#0B57D0"
        },
        "keywords": [
          {
            "keyword": "ERROR",
            "scope": "line",
            "color": "#B00020"
          },
          {
            "keyword": "WARNING",
            "scope": "line",
            "color": "#B26A00"
          }
        ]
      },
      "dark": {
        "markdown": {
          "heading1": "#8AB4F8",
          "heading2": "#C58AF9",
          "heading3": "#81C995",
          "heading4": "#BDC1C6",
          "heading5": "#BDC1C6",
          "heading6": "#BDC1C6",
          "unorderedList": "#FDD663",
          "orderedList": "#FDD663",
          "quote": "#81C995"
        },
        "inline": {
          "quotedText": "#D7AEFB",
          "boldText": "#FFD166",
          "inlineCode": "#8AB4F8"
        },
        "keywords": [
          {
            "keyword": "ERROR",
            "scope": "line",
            "color": "#FF6B6B"
          },
          {
            "keyword": "WARNING",
            "scope": "line",
            "color": "#FFD166"
          }
        ]
      }
    }
    """
}
