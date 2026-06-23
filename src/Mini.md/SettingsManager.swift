import AppKit
import Darwin
import Foundation

struct MiniMDKeyboardShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              let eventKey = event.charactersIgnoringModifiers?.lowercased(),
              eventKey == key || (key == "=" && eventKey == "+") else {
            return false
        }

        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return relevantFlags == modifiers
    }

    static func isDisabled(_ rawValue: String) -> Bool {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["disabled", "none", "off"].contains(normalized)
    }

    static func parse(_ rawValue: String) -> MiniMDKeyboardShortcut? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        guard !isDisabled(normalized) else { return nil }

        let parts = normalized.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }

        let key: String
        let modifierParts: ArraySlice<String>
        if parts.count >= 3, parts.suffix(2).allSatisfy({ $0.isEmpty }) {
            key = "+"
            modifierParts = parts.dropLast(2)
        } else if let parsedKey = normalizedKey(parts.last ?? "") {
            key = parsedKey
            modifierParts = parts.dropLast()
        } else {
            return nil
        }

        var modifiers = NSEvent.ModifierFlags()
        for modifier in modifierParts {
            switch modifier {
            case "command", "cmd":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "option", "opt", "alt":
                modifiers.insert(.option)
            case "control", "ctrl":
                modifiers.insert(.control)
            default:
                return nil
            }
        }

        guard modifiers.contains(.command) else { return nil }
        return MiniMDKeyboardShortcut(key: key, modifiers: modifiers)
    }

    private static func normalizedKey(_ rawKey: String) -> String? {
        switch rawKey {
        case "plus":
            return "+"
        case "equal", "equals":
            return "="
        case "minus", "hyphen":
            return "-"
        case "zero":
            return "0"
        default:
            return rawKey.count == 1 ? rawKey : nil
        }
    }
}

enum MiniMDDefaultOpenMode: Equatable {
    case render
    case edit

    static func parse(_ rawValue: String) -> MiniMDDefaultOpenMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "render", "preview", "rendered":
            return .render
        case "edit", "editing", "editor":
            return .edit
        default:
            return nil
        }
    }
}

enum MiniMDFileNameMatchType: Equatable {
    case exact
    case prefix
    case suffix
    case contains
    case regex

    static func parse(_ rawValue: String) -> MiniMDFileNameMatchType? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "exact", "equals", "name":
            return .exact
        case "prefix", "startswith", "starts-with":
            return .prefix
        case "suffix", "endswith", "ends-with":
            return .suffix
        case "contains", "keyword", "keywords", "substring":
            return .contains
        case "regex", "regularexpression", "regular-expression":
            return .regex
        default:
            return nil
        }
    }
}

struct MiniMDHTMLExportSettings: Equatable {
    let defaultZoom: CGFloat
    let contentWidthPX: CGFloat
    let printMarginMM: CGFloat

    static let defaults = MiniMDHTMLExportSettings(
        defaultZoom: 1.0,
        contentWidthPX: 980,
        printMarginMM: 8
    )
}

struct MiniMDFileOpenModeRule {
    let mode: MiniMDDefaultOpenMode
    let matchType: MiniMDFileNameMatchType
    let patterns: [String]
    let caseSensitive: Bool

    private let regexes: [NSRegularExpression]

    init(
        mode: MiniMDDefaultOpenMode,
        matchType: MiniMDFileNameMatchType,
        patterns: [String],
        caseSensitive: Bool
    ) {
        self.mode = mode
        self.matchType = matchType
        self.patterns = patterns
        self.caseSensitive = caseSensitive

        if matchType == .regex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            self.regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: options) }
        } else {
            self.regexes = []
        }
    }

    func matches(fileName: String) -> Bool {
        switch matchType {
        case .exact, .prefix, .suffix, .contains:
            let candidate = caseSensitive ? fileName : fileName.lowercased()
            return patterns.contains { pattern in
                guard !pattern.isEmpty else { return false }
                let normalizedPattern = caseSensitive ? pattern : pattern.lowercased()

                switch matchType {
                case .exact:
                    return candidate == normalizedPattern
                case .prefix:
                    return candidate.hasPrefix(normalizedPattern)
                case .suffix:
                    return candidate.hasSuffix(normalizedPattern)
                case .contains:
                    return candidate.contains(normalizedPattern)
                case .regex:
                    return false
                }
            }
        case .regex:
            let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
            return regexes.contains { regex in
                regex.firstMatch(in: fileName, range: range) != nil
            }
        }
    }
}

struct MiniMDSettings {
    let defaultTheme: ThemePreference
    let themeColors: [DocumentTheme: MiniMDThemePalette]
    let defaultOpenMode: MiniMDDefaultOpenMode
    let fileOpenModeRules: [MiniMDFileOpenModeRule]
    let titlebarVisible: Bool
    let themeToggleShortcut: MiniMDKeyboardShortcut?
    let refreshShortcut: MiniMDKeyboardShortcut?
    let zoomInShortcut: MiniMDKeyboardShortcut?
    let zoomOutShortcut: MiniMDKeyboardShortcut?
    let defaultRenderZoom: CGFloat
    let defaultEditZoom: CGFloat
    let editSyntaxHighlightingEnabled: Bool
    let renderSyntaxHighlightingEnabled: Bool
    let htmlExport: MiniMDHTMLExportSettings
    let singleInstancePerFile: Bool
    let rememberWindowFrame: Bool
    let rememberContentZoom: Bool
    let tabsEnabled: Bool
    let keepAliveAfterLastWindowClosed: Bool
    let keepAliveIdleTimeoutSeconds: TimeInterval

    static let defaults = MiniMDSettings(
        defaultTheme: .system,
        themeColors: [
            .light: .defaultLight,
            .dark: .defaultDark
        ],
        defaultOpenMode: .render,
        fileOpenModeRules: [],
        titlebarVisible: true,
        themeToggleShortcut: MiniMDKeyboardShortcut(key: "t", modifiers: [.command]),
        refreshShortcut: MiniMDKeyboardShortcut(key: "r", modifiers: [.command]),
        zoomInShortcut: MiniMDKeyboardShortcut(key: "=", modifiers: [.command]),
        zoomOutShortcut: MiniMDKeyboardShortcut(key: "-", modifiers: [.command]),
        defaultRenderZoom: 1.0,
        defaultEditZoom: 1.0,
        editSyntaxHighlightingEnabled: true,
        renderSyntaxHighlightingEnabled: false,
        htmlExport: .defaults,
        singleInstancePerFile: true,
        rememberWindowFrame: true,
        rememberContentZoom: true,
        tabsEnabled: false,
        keepAliveAfterLastWindowClosed: false,
        keepAliveIdleTimeoutSeconds: 300
    )

    func openMode(for fileURL: URL) -> MiniMDDefaultOpenMode {
        let fileName = fileURL.lastPathComponent
        return fileOpenModeRules.first { $0.matches(fileName: fileName) }?.mode ?? defaultOpenMode
    }

    func palette(for theme: DocumentTheme) -> MiniMDThemePalette {
        themeColors[theme] ?? .default(for: theme)
    }
}

@MainActor
final class MiniMDSettingsManager {
    static let shared = MiniMDSettingsManager()

    let settingsDirectoryURL: URL
    let settingsFileURL: URL

    private let fileManager: FileManager
    private var cachedSettings: MiniMDSettings?
    private var cachedSettingsModificationDate: Date?

    private static let defaultSettingsTemplate = """
    {
      // defaultTheme: options are "system", "light", "dark".
      // Controls the theme used when Markdown is rendered.
      "defaultTheme": "system",

      // themeColors: custom foreground/background colors for each resolved document theme.
      // Supported hex formats are "#RRGGBB", "RRGGBB", "#RGB", or "RGB".
      // Invalid or missing color fields fall back independently.
      "themeColors": {
        "light": {
          "foreground": "#25292E",
          "background": "#FBFAF7"
        },
        "dark": {
          "foreground": "#EFEAD8",
          "background": "#252525"
        }
      },

      // defaultOpenMode: options are "render" or "edit".
      // Used when no fileOpenModeRules entry matches the Markdown file name.
      "defaultOpenMode": "render",

      // fileOpenModeRules: ordered first-match-wins rules against the Markdown file name.
      // matchType options are "exact", "prefix", "suffix", "contains", or "regex".
      // Each rule can use "pattern": "..." or "patterns": ["...", "..."].
      // Example:
      // "fileOpenModeRules": [
      //   { "mode": "render", "matchType": "prefix", "pattern": "AI_" },
      //   { "mode": "render", "matchType": "exact", "patterns": ["AGENTS.md", "HISTORY_LOG.md", "MEMORY.md", "WORKSPACE_MAP.md"] }
      // ],
      "fileOpenModeRules": [],

      // titlebarVisible: options are true or false.
      // When true, the app shows native macOS window controls and the current file name.
      "titlebarVisible": true,

      // themeToggleShortcut: examples are "command+t", "command+e", or "disabled".
      // Controls the keyboard shortcut for toggling between light and dark themes.
      "themeToggleShortcut": "command+t",

      // refreshShortcut: examples are "command+r", "shift+command+r", or "disabled".
      // Controls the keyboard shortcut for reloading the current Markdown file from disk.
      "refreshShortcut": "command+r",

      // defaultRenderZoom: number from 0.5 to 3.0. 1.0 means 100%.
      // Used after settings.json changes or when no current remembered render zoom matches this configured default.
      "defaultRenderZoom": 1.0,

      // defaultEditZoom: number from 0.71 to 2.0. 1.0 means the normal editor font size.
      // Used as the initial edit-mode text zoom ratio.
      "defaultEditZoom": 1.0,

      // editSyntaxHighlightingEnabled: options are true or false.
      // Enables syntax highlighting while editing Markdown source text.
      // Colors and rules are configured in ~/Mini.md/highlight.json.
      "editSyntaxHighlightingEnabled": true,

      // renderSyntaxHighlightingEnabled: options are true or false.
      // Enables highlight.json colors/rules in rendered preview mode.
      // highlight.json stores light/dark colors for Markdown structures, inline spans, and literal keyword rules.
      // Markdown syntax markers that disappear after rendering, such as ``` fences, are not visible in render mode.
      "renderSyntaxHighlightingEnabled": false,

      // htmlExport: controls direct Markdown-to-HTML export with Command-Shift-E.
      // defaultZoom scales exported text, headings, tables, code, and print typography while keeping page width stable.
      // 1.0 means normal size; smaller values fit more content.
      // contentWidthPX controls the browser/screen content width. 980 matches the previous default.
      // printMarginMM controls A4 print margins on all four sides. Smaller values reduce blank paper edges.
      "htmlExport": {
        "defaultZoom": 1.0,
        "contentWidthPX": 980,
        "printMarginMM": 8
      },

      // zoomInShortcut: examples are "command+=", "command+plus", or "disabled".
      // Controls the keyboard shortcut for rendered-content page zoom in.
      "zoomInShortcut": "command+=",

      // zoomOutShortcut: examples are "command+-", "command+minus", or "disabled".
      // Controls the keyboard shortcut for rendered-content page zoom out.
      "zoomOutShortcut": "command+-",

      // singleInstancePerFile: options are true or false.
      // When true, opening the same real Markdown file again activates the existing window.
      "singleInstancePerFile": true,

      // rememberWindowFrame: options are true or false.
      // When true, the app reuses the last saved window position and size.
      "rememberWindowFrame": true,

      // rememberContentZoom: options are true or false.
      // When true, Cmd+= and Cmd+- page zoom changes are reused by new Markdown windows.
      "rememberContentZoom": true,

      // tabsEnabled: options are true or false.
      // When true, Markdown files opened on the same active macOS desktop are added as tabs to an existing Mini.md window.
      // Windows on other desktops are not reused.
      "tabsEnabled": false,

      // keepAliveAfterLastWindowClosed: options are true or false.
      // When true, Mini.md keeps its app process alive after the last window closes to reduce later launch overhead.
      "keepAliveAfterLastWindowClosed": false,

      // keepAliveIdleTimeoutSeconds: number of seconds, 0 disables the timeout.
      // Used only when keepAliveAfterLastWindowClosed is true. Only one idle Mini.md process is kept warm.
      "keepAliveIdleTimeoutSeconds": 300
    }
    """

    private static let defaultThemeColorsSettingsEntry = """
      // themeColors: custom foreground/background colors for each resolved document theme.
      // Supported hex formats are "#RRGGBB", "RRGGBB", "#RGB", or "RGB".
      // Invalid or missing color fields fall back independently.
      "themeColors": {
        "light": {
          "foreground": "#25292E",
          "background": "#FBFAF7"
        },
        "dark": {
          "foreground": "#EFEAD8",
          "background": "#252525"
        }
      },
    """

    private static let defaultRenderZoomSettingsEntry = """
      // defaultRenderZoom: number from 0.5 to 3.0. 1.0 means 100%.
      // Used after settings.json changes or when no current remembered render zoom matches this configured default.
      "defaultRenderZoom": 1.0,

    """

    private static let defaultEditZoomSettingsEntry = """
      // defaultEditZoom: number from 0.71 to 2.0. 1.0 means the normal editor font size.
      // Used as the initial edit-mode text zoom ratio.
      "defaultEditZoom": 1.0,

    """

    private static let editSyntaxHighlightingSettingsEntry = """
      // editSyntaxHighlightingEnabled: options are true or false.
      // Enables syntax highlighting while editing Markdown source text.
      // Colors and rules are configured in ~/Mini.md/highlight.json.
      "editSyntaxHighlightingEnabled": true,

    """

    private static let renderSyntaxHighlightingSettingsEntry = """
      // renderSyntaxHighlightingEnabled: options are true or false.
      // Enables highlight.json colors/rules in rendered preview mode.
      // highlight.json stores light/dark colors for Markdown structures, inline spans, and literal keyword rules.
      // Markdown syntax markers that disappear after rendering, such as ``` fences, are not visible in render mode.
      "renderSyntaxHighlightingEnabled": false,

    """

    private static let htmlExportSettingsEntry = """
      // htmlExport: controls direct Markdown-to-HTML export with Command-Shift-E.
      // defaultZoom scales exported text, headings, tables, code, and print typography while keeping page width stable.
      // 1.0 means normal size; smaller values fit more content.
      // contentWidthPX controls the browser/screen content width. 980 matches the previous default.
      // printMarginMM controls A4 print margins on all four sides. Smaller values reduce blank paper edges.
      "htmlExport": {
        "defaultZoom": 1.0,
        "contentWidthPX": 980,
        "printMarginMM": 8
      },

    """

    private static let keepAliveIdleTimeoutSettingsEntry = """
      // keepAliveIdleTimeoutSeconds: number of seconds, 0 disables the timeout.
      // Used only when keepAliveAfterLastWindowClosed is true. Only one idle Mini.md process is kept warm.
      "keepAliveIdleTimeoutSeconds": 300
    """

    private init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        self.settingsDirectoryURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Mini.md", isDirectory: true)
        self.settingsFileURL = settingsDirectoryURL.appendingPathComponent("settings.json")
        ensureSettingsFile()
    }

    func settings() -> MiniMDSettings {
        ensureSettingsFile()

        let modificationDate = settingsFileModificationDate()
        if let cachedSettings,
           cachedSettingsModificationDate == modificationDate {
            return cachedSettings
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                NSLog("Mini.md settings file is not valid UTF-8: %@", settingsFileURL.path)
                cacheSettings(.defaults, modificationDate: modificationDate)
                return .defaults
            }

            let jsonText = removingCommentLines(from: text)
            guard let jsonData = jsonText.data(using: .utf8),
                  let dictionary = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                NSLog("Mini.md settings file is not a JSON object: %@", settingsFileURL.path)
                cacheSettings(.defaults, modificationDate: modificationDate)
                return .defaults
            }

            let parsedSettings = parsedSettings(from: dictionary)
            cacheSettings(parsedSettings, modificationDate: modificationDate)
            return parsedSettings
        } catch {
            NSLog("Mini.md could not read settings file %@: %@", settingsFileURL.path, String(describing: error))
            cacheSettings(.defaults, modificationDate: modificationDate)
            return .defaults
        }
    }

    func invalidateCache() {
        cachedSettings = nil
        cachedSettingsModificationDate = nil
    }

    func settingsFileVersionIdentifier() -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: settingsFileURL.path) else {
            return nil
        }

        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(modificationTime):\(fileSize)"
    }

    func updateDefaultTheme(_ preference: ThemePreference) {
        ensureSettingsFile()

        do {
            var text = try String(contentsOf: settingsFileURL, encoding: .utf8)
            let pattern = #""defaultTheme"\s*:\s*"(system|light|dark)""#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)

            if let match = regex.firstMatch(in: text, range: range),
               match.numberOfRanges > 1,
               let valueRange = Range(match.range(at: 1), in: text) {
                text.replaceSubrange(valueRange, with: preference.rawValue)
            } else {
                text = Self.defaultSettingsTemplate.replacingOccurrences(
                    of: #""defaultTheme": "system""#,
                    with: "\"defaultTheme\": \"\(preference.rawValue)\""
                )
            }

            try text.write(to: settingsFileURL, atomically: true, encoding: .utf8)
            cachedSettings = nil
            cachedSettingsModificationDate = nil
        } catch {
            NSLog("Mini.md could not update settings file %@: %@", settingsFileURL.path, String(describing: error))
        }
    }

    private func ensureSettingsFile() {
        do {
            try fileManager.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: settingsFileURL.path) {
                try Self.defaultSettingsTemplate.write(to: settingsFileURL, atomically: true, encoding: .utf8)
                return
            }
            migrateSettingsFileIfNeeded()
        } catch {
            NSLog("Mini.md could not create settings file %@: %@", settingsFileURL.path, String(describing: error))
        }
    }

    private func migrateSettingsFileIfNeeded() {
        guard var text = try? String(contentsOf: settingsFileURL, encoding: .utf8) else {
            return
        }

        var didMigrate = false
        didMigrate = migrateThemeColorsIfNeeded(in: &text) || didMigrate
        didMigrate = migrateThemeToggleShortcutIfNeeded(in: &text) || didMigrate
        didMigrate = insertSettingsEntryIfMissing(
            named: "defaultRenderZoom",
            entry: Self.defaultRenderZoomSettingsEntry,
            beforeCommentForKey: "zoomInShortcut",
            beforeKey: "zoomInShortcut",
            in: &text
        ) || didMigrate
        didMigrate = insertSettingsEntryIfMissing(
            named: "defaultEditZoom",
            entry: Self.defaultEditZoomSettingsEntry,
            beforeCommentForKey: "zoomInShortcut",
            beforeKey: "zoomInShortcut",
            in: &text
        ) || didMigrate
        didMigrate = insertSettingsEntryIfMissing(
            named: "editSyntaxHighlightingEnabled",
            entry: Self.editSyntaxHighlightingSettingsEntry,
            beforeCommentForKey: "zoomInShortcut",
            beforeKey: "zoomInShortcut",
            in: &text
        ) || didMigrate
        didMigrate = insertSettingsEntryIfMissing(
            named: "renderSyntaxHighlightingEnabled",
            entry: Self.renderSyntaxHighlightingSettingsEntry,
            beforeCommentForKey: "zoomInShortcut",
            beforeKey: "zoomInShortcut",
            in: &text
        ) || didMigrate
        didMigrate = insertSettingsEntryIfMissing(
            named: "htmlExport",
            entry: Self.htmlExportSettingsEntry,
            beforeCommentForKey: "zoomInShortcut",
            beforeKey: "zoomInShortcut",
            in: &text
        ) || didMigrate
        didMigrate = migrateHTMLExportSettingsIfNeeded(in: &text) || didMigrate
        didMigrate = appendRootSettingsEntryIfMissing(
            named: "keepAliveIdleTimeoutSeconds",
            entry: Self.keepAliveIdleTimeoutSettingsEntry,
            in: &text
        ) || didMigrate

        guard didMigrate else {
            return
        }

        do {
            try text.write(to: settingsFileURL, atomically: true, encoding: .utf8)
            cachedSettings = nil
            cachedSettingsModificationDate = nil
        } catch {
            NSLog("Mini.md could not migrate settings file %@: %@", settingsFileURL.path, String(describing: error))
        }
    }

    private func migrateThemeColorsIfNeeded(in text: inout String) -> Bool {
        if settingsText(text, containsKey: "themeColors") {
            return false
        }

        let pattern = #""defaultTheme"\s*:\s*"(?:system|light|dark)"\s*,"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: searchRange),
              let insertIndex = Range(match.range, in: text)?.upperBound else {
            return false
        }

        text.insert(contentsOf: "\n\n" + Self.defaultThemeColorsSettingsEntry, at: insertIndex)
        return true
    }

    private func migrateThemeToggleShortcutIfNeeded(in text: inout String) -> Bool {
        let pattern = #""themeToggleShortcut"\s*:\s*"(shift\+command\+e|command\+shift\+e)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return false
        }

        text.replaceSubrange(valueRange, with: "command+t")
        return true
    }

    private func migrateHTMLExportSettingsIfNeeded(in text: inout String) -> Bool {
        guard settingsText(text, containsKey: "htmlExport") else {
            return false
        }

        var didMigrate = false
        didMigrate = insertHTMLExportFieldIfMissing(
            named: "contentWidthPX",
            entry: """
                    // contentWidthPX: exported HTML content width in browser/screen view. 980 matches the previous default.
                    "contentWidthPX": 980
            """,
            in: &text
        ) || didMigrate
        didMigrate = insertHTMLExportFieldIfMissing(
            named: "printMarginMM",
            entry: """
                    // printMarginMM: A4 print margins on all four sides. Smaller values reduce blank paper edges.
                    "printMarginMM": 8
            """,
            in: &text
        ) || didMigrate
        return didMigrate
    }

    private func insertHTMLExportFieldIfMissing(
        named key: String,
        entry: String,
        in text: inout String
    ) -> Bool {
        guard let objectRange = htmlExportObjectRange(in: text) else {
            return false
        }

        let objectText = String(text[objectRange])
        guard !settingsText(objectText, containsKey: key) else {
            return false
        }

        let closingBraceIndex = text.index(before: objectRange.upperBound)
        let objectBodyStart = text.index(after: objectRange.lowerBound)
        let objectBody = text[objectBodyStart..<closingBraceIndex]
        let needsComma = !objectBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !objectBody.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",")
        let insertion = (needsComma ? "," : "") + "\n" + entry + "\n      "
        text.insert(contentsOf: insertion, at: closingBraceIndex)
        return true
    }

    private func htmlExportObjectRange(in text: String) -> Range<String.Index>? {
        guard let keyRange = text.range(of: #""htmlExport"\s*:\s*\{"#, options: .regularExpression),
              let objectStartIndex = text[keyRange].lastIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = objectStartIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return objectStartIndex..<text.index(after: index)
                }
            }
            index = text.index(after: index)
        }

        return nil
    }

    private func insertSettingsEntryIfMissing(
        named key: String,
        entry: String,
        beforeCommentForKey commentKey: String,
        beforeKey: String,
        in text: inout String
    ) -> Bool {
        guard !settingsText(text, containsKey: key) else {
            return false
        }

        let commentAnchor = "      // \(commentKey):"
        if let anchorRange = text.range(of: commentAnchor) {
            text.insert(contentsOf: entry, at: anchorRange.lowerBound)
            return true
        }

        let keyPattern = #"(?m)^\s*"\#(beforeKey)"\s*:"#
        if let keyRange = text.range(of: keyPattern, options: .regularExpression) {
            text.insert(contentsOf: entry, at: keyRange.lowerBound)
            return true
        }

        return false
    }

    private func appendRootSettingsEntryIfMissing(
        named key: String,
        entry: String,
        in text: inout String
    ) -> Bool {
        guard !settingsText(text, containsKey: key) else {
            return false
        }

        guard let closingRange = text.range(of: #"\n\s*}\s*$"#, options: .regularExpression) else {
            return false
        }

        let prefix = text[..<closingRange.lowerBound]
        let needsComma = !prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",")
        let insertion = (needsComma ? "," : "") + "\n\n" + entry
        text.insert(contentsOf: insertion, at: closingRange.lowerBound)
        return true
    }

    private func parsedSettings(from dictionary: [String: Any]) -> MiniMDSettings {
        let defaults = MiniMDSettings.defaults

        let defaultTheme: ThemePreference
        if let rawTheme = dictionary["defaultTheme"] as? String,
           let parsedTheme = ThemePreference(rawValue: rawTheme.lowercased()) {
            defaultTheme = parsedTheme
        } else {
            defaultTheme = defaults.defaultTheme
        }

        let defaultOpenMode: MiniMDDefaultOpenMode
        if let rawOpenMode = dictionary["defaultOpenMode"] as? String,
           let parsedOpenMode = MiniMDDefaultOpenMode.parse(rawOpenMode) {
            defaultOpenMode = parsedOpenMode
        } else {
            defaultOpenMode = defaults.defaultOpenMode
        }

        let themeToggleShortcut = parsedShortcut(named: "themeToggleShortcut", from: dictionary, default: defaults.themeToggleShortcut)
        let refreshShortcut = parsedShortcut(named: "refreshShortcut", from: dictionary, default: defaults.refreshShortcut)
        let zoomInShortcut = parsedShortcut(named: "zoomInShortcut", from: dictionary, default: defaults.zoomInShortcut)
        let zoomOutShortcut = parsedShortcut(named: "zoomOutShortcut", from: dictionary, default: defaults.zoomOutShortcut)
        let defaultRenderZoom = parsedZoomRatio(
            named: "defaultRenderZoom",
            from: dictionary,
            default: defaults.defaultRenderZoom,
            minimum: 0.5,
            maximum: 3.0
        )
        let defaultEditZoom = parsedZoomRatio(
            named: "defaultEditZoom",
            from: dictionary,
            default: defaults.defaultEditZoom,
            minimum: 10.0 / 14.0,
            maximum: 2.0
        )
        let keepAliveIdleTimeoutSeconds = parsedTimeInterval(
            named: "keepAliveIdleTimeoutSeconds",
            from: dictionary,
            default: defaults.keepAliveIdleTimeoutSeconds,
            minimum: 0,
            maximum: 86_400
        )
        let htmlExport = parsedHTMLExportSettings(from: dictionary)

        return MiniMDSettings(
            defaultTheme: defaultTheme,
            themeColors: parsedThemeColors(from: dictionary),
            defaultOpenMode: defaultOpenMode,
            fileOpenModeRules: parsedFileOpenModeRules(from: dictionary),
            titlebarVisible: dictionary["titlebarVisible"] as? Bool ?? defaults.titlebarVisible,
            themeToggleShortcut: themeToggleShortcut,
            refreshShortcut: refreshShortcut,
            zoomInShortcut: zoomInShortcut,
            zoomOutShortcut: zoomOutShortcut,
            defaultRenderZoom: defaultRenderZoom,
            defaultEditZoom: defaultEditZoom,
            editSyntaxHighlightingEnabled: dictionary["editSyntaxHighlightingEnabled"] as? Bool ?? defaults.editSyntaxHighlightingEnabled,
            renderSyntaxHighlightingEnabled: dictionary["renderSyntaxHighlightingEnabled"] as? Bool ?? defaults.renderSyntaxHighlightingEnabled,
            htmlExport: htmlExport,
            singleInstancePerFile: dictionary["singleInstancePerFile"] as? Bool ?? defaults.singleInstancePerFile,
            rememberWindowFrame: dictionary["rememberWindowFrame"] as? Bool ?? defaults.rememberWindowFrame,
            rememberContentZoom: dictionary["rememberContentZoom"] as? Bool ?? defaults.rememberContentZoom,
            tabsEnabled: dictionary["tabsEnabled"] as? Bool ?? defaults.tabsEnabled,
            keepAliveAfterLastWindowClosed: dictionary["keepAliveAfterLastWindowClosed"] as? Bool ?? defaults.keepAliveAfterLastWindowClosed,
            keepAliveIdleTimeoutSeconds: keepAliveIdleTimeoutSeconds
        )
    }

    private func parsedThemeColors(from dictionary: [String: Any]) -> [DocumentTheme: MiniMDThemePalette] {
        let defaults: [DocumentTheme: MiniMDThemePalette] = [
            .light: .defaultLight,
            .dark: .defaultDark
        ]

        guard let rawThemeColors = dictionary["themeColors"] as? [String: Any] else {
            return defaults
        }

        var result = defaults
        for theme in [DocumentTheme.light, DocumentTheme.dark] {
            guard let rawPalette = rawThemeColors[theme.rawValue] as? [String: Any] else {
                continue
            }

            let fallback = defaults[theme] ?? .default(for: theme)
            let foreground = normalizedHexColor(rawPalette["foreground"]) ?? fallback.foregroundHex
            let background = normalizedHexColor(rawPalette["background"]) ?? fallback.backgroundHex

            result[theme] = MiniMDThemePalette(
                foregroundHex: foreground,
                backgroundHex: background
            )
        }

        return result
    }

    private func parsedHTMLExportSettings(from dictionary: [String: Any]) -> MiniMDHTMLExportSettings {
        let defaults = MiniMDHTMLExportSettings.defaults
        guard let rawSettings = dictionary["htmlExport"] as? [String: Any] else {
            return defaults
        }

        return MiniMDHTMLExportSettings(
            defaultZoom: parsedNumber(
                named: "defaultZoom",
                from: rawSettings,
                default: defaults.defaultZoom,
                minimum: 0.5,
                maximum: 3.0
            ),
            contentWidthPX: parsedNumber(
                named: "contentWidthPX",
                from: rawSettings,
                default: defaults.contentWidthPX,
                minimum: 640,
                maximum: 1_600
            ),
            printMarginMM: parsedNumber(
                named: "printMarginMM",
                from: rawSettings,
                default: defaults.printMarginMM,
                minimum: 0,
                maximum: 30
            )
        )
    }

    private func normalizedHexColor(_ rawValue: Any?) -> String? {
        guard let rawString = rawValue as? String else {
            return nil
        }

        var value = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        guard value.count == 6,
              value.allSatisfy(isHexDigit) else {
            return nil
        }

        return "#" + value.uppercased()
    }

    private func isHexDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }

        return CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
    }

    private func parsedFileOpenModeRules(from dictionary: [String: Any]) -> [MiniMDFileOpenModeRule] {
        guard let rawRules = dictionary["fileOpenModeRules"] as? [[String: Any]] else {
            return []
        }

        return rawRules.compactMap { rawRule in
            guard let rawMode = rawRule["mode"] as? String,
                  let mode = MiniMDDefaultOpenMode.parse(rawMode) else {
                return nil
            }

            let rawMatchType = (rawRule["matchType"] as? String) ?? (rawRule["type"] as? String) ?? "contains"
            guard let matchType = MiniMDFileNameMatchType.parse(rawMatchType) else {
                return nil
            }

            let patterns = parsedRulePatterns(from: rawRule)
            guard !patterns.isEmpty else {
                return nil
            }

            return MiniMDFileOpenModeRule(
                mode: mode,
                matchType: matchType,
                patterns: patterns,
                caseSensitive: rawRule["caseSensitive"] as? Bool ?? false
            )
        }
    }

    private func parsedRulePatterns(from rawRule: [String: Any]) -> [String] {
        let candidateValues: [Any?] = [
            rawRule["patterns"],
            rawRule["pattern"],
            rawRule["match"],
            rawRule["matches"],
            rawRule["keywords"],
            rawRule["keyword"]
        ]

        for value in candidateValues {
            if let pattern = value as? String {
                let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }

            if let patterns = value as? [String] {
                return patterns
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }

        return []
    }

    private func parsedShortcut(
        named key: String,
        from dictionary: [String: Any],
        default defaultShortcut: MiniMDKeyboardShortcut?
    ) -> MiniMDKeyboardShortcut? {
        guard let rawShortcut = dictionary[key] as? String else {
            return defaultShortcut
        }

        if MiniMDKeyboardShortcut.isDisabled(rawShortcut) {
            return nil
        }

        return MiniMDKeyboardShortcut.parse(rawShortcut) ?? defaultShortcut
    }

    private func parsedZoomRatio(
        named key: String,
        from dictionary: [String: Any],
        default defaultValue: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let parsedValue: CGFloat?
        if let number = dictionary[key] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            parsedValue = CGFloat(truncating: number)
        } else if let string = dictionary[key] as? String,
                  let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            parsedValue = CGFloat(doubleValue)
        } else {
            parsedValue = nil
        }

        guard let parsedValue,
              parsedValue.isFinite else {
            return defaultValue
        }

        return roundedZoomRatio(parsedValue, minimum: minimum, maximum: maximum)
    }

    private func parsedNumber(
        named key: String,
        from dictionary: [String: Any],
        default defaultValue: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        parsedZoomRatio(
            named: key,
            from: dictionary,
            default: defaultValue,
            minimum: minimum,
            maximum: maximum
        )
    }

    private func roundedZoomRatio(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let clampedValue = min(max(value, minimum), maximum)
        return (clampedValue * 100).rounded() / 100
    }

    private func parsedTimeInterval(
        named key: String,
        from dictionary: [String: Any],
        default defaultValue: TimeInterval,
        minimum: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        let parsedValue: TimeInterval?
        if let number = dictionary[key] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            parsedValue = number.doubleValue
        } else if let string = dictionary[key] as? String,
                  let doubleValue = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            parsedValue = doubleValue
        } else {
            parsedValue = nil
        }

        guard let parsedValue,
              parsedValue.isFinite else {
            return defaultValue
        }

        return min(max(parsedValue, minimum), maximum)
    }

    private func settingsFileModificationDate() -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: settingsFileURL.path) else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }

    private func cacheSettings(_ settings: MiniMDSettings, modificationDate: Date?) {
        cachedSettings = settings
        cachedSettingsModificationDate = modificationDate
    }

    private func settingsText(_ text: String, containsKey key: String) -> Bool {
        let pattern = #""\#(key)"\s*:"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func removingCommentLines(from text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

enum MarkdownFileInstanceLockResult {
    case acquired(MarkdownFileInstanceLock)
    case occupied(canonicalURL: URL, processIdentifier: pid_t?)
    case unavailable(Error)
}

final class MarkdownFileInstanceLock {
    let canonicalURL: URL

    private let fileDescriptor: Int32
    private let lockURL: URL

    private init(canonicalURL: URL, lockURL: URL, fileDescriptor: Int32) {
        self.canonicalURL = canonicalURL
        self.lockURL = lockURL
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        try? FileManager.default.removeItem(at: lockURL)
    }

    static func canonicalFileURL(for fileURL: URL) -> URL {
        fileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    @MainActor
    static func acquire(for fileURL: URL) -> MarkdownFileInstanceLockResult {
        let canonicalURL = canonicalFileURL(for: fileURL)
        let lockDirectoryURL = MiniMDSettingsManager.shared.settingsDirectoryURL.appendingPathComponent("open-file-locks", isDirectory: true)
        let lockURL = lockDirectoryURL.appendingPathComponent(stableHash(for: canonicalURL.path)).appendingPathExtension("lock")

        do {
            try FileManager.default.createDirectory(at: lockDirectoryURL, withIntermediateDirectories: true)
        } catch {
            return .unavailable(error)
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return .unavailable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            writeLockOwner(to: descriptor, canonicalPath: canonicalURL.path)
            return .acquired(MarkdownFileInstanceLock(canonicalURL: canonicalURL, lockURL: lockURL, fileDescriptor: descriptor))
        }

        let processIdentifier = readProcessIdentifier(from: lockURL)
        close(descriptor)
        return .occupied(canonicalURL: canonicalURL, processIdentifier: processIdentifier)
    }

    private static func writeLockOwner(to descriptor: Int32, canonicalPath: String) {
        let ownerText = "\(ProcessInfo.processInfo.processIdentifier)\n\(canonicalPath)\n"
        let data = Data(ownerText.utf8)
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = Darwin.write(descriptor, baseAddress, data.count)
        }
    }

    private static func readProcessIdentifier(from lockURL: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: lockURL),
              let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n").first else {
            return nil
        }

        return pid_t(String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func stableHash(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}

extension Notification.Name {
    static let miniMDActivateFile = Notification.Name("com.openai-codex.zhangzheng.minimd.activateFile")
}
