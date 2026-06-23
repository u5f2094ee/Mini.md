import Foundation

enum DocumentTheme: String, Hashable, Sendable {
    case light
    case dark
}

enum ThemePreference: String, Sendable {
    case system
    case light
    case dark
}

struct MiniMDThemePalette: Equatable, Sendable {
    let foregroundHex: String
    let backgroundHex: String

    static let defaultLight = MiniMDThemePalette(
        foregroundHex: "#25292E",
        backgroundHex: "#FBFAF7"
    )

    static let defaultDark = MiniMDThemePalette(
        foregroundHex: "#EFEAD8",
        backgroundHex: "#252525"
    )

    static func `default`(for theme: DocumentTheme) -> MiniMDThemePalette {
        switch theme {
        case .light:
            return defaultLight
        case .dark:
            return defaultDark
        }
    }
}

struct MiniMDResolvedTheme: Equatable, Sendable {
    let theme: DocumentTheme
    let palette: MiniMDThemePalette
}

enum ThemeStorage {
    static let appDefaultsDomain = "com.openai-codex.zhangzheng.minimd"
    static let preferenceKey = "MiniMD.DocumentThemePreference"
}
