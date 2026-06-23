import AppKit

@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    private let defaults = UserDefaults.standard
    private let frameKey = "MiniMD.LastWindowFrame"
    private let settingsManager = MiniMDSettingsManager.shared

    var preference: ThemePreference {
        get {
            let preference = settingsManager.settings().defaultTheme
            defaults.set(preference.rawValue, forKey: ThemeStorage.preferenceKey)
            return preference
        }
        set {
            settingsManager.updateDefaultTheme(newValue)
            defaults.set(newValue.rawValue, forKey: ThemeStorage.preferenceKey)
            defaults.synchronize()
        }
    }

    private init() {}

    func resolvedTheme() -> DocumentTheme {
        resolvedThemePalette().theme
    }

    func resolvedThemePalette() -> MiniMDResolvedTheme {
        let settings = settingsManager.settings()

        let theme: DocumentTheme
        switch settings.defaultTheme {
        case .light:
            theme = .light
        case .dark:
            theme = .dark
        case .system:
            let matchedAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            theme = matchedAppearance == .darkAqua ? .dark : .light
        }

        return MiniMDResolvedTheme(theme: theme, palette: settings.palette(for: theme))
    }

    func toggleExplicitTheme() -> DocumentTheme {
        let nextTheme: DocumentTheme = resolvedThemePalette().theme == .dark ? .light : .dark
        preference = nextTheme == .dark ? .dark : .light
        return nextTheme
    }

    func restoredWindowFrame() -> NSRect {
        let screen = NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1200, height: 820)

        let baseFrame: NSRect
        if settingsManager.settings().rememberWindowFrame,
           let frameString = defaults.string(forKey: frameKey) {
            baseFrame = NSRectFromString(frameString)
        } else {
            baseFrame = NSRect(
                x: visibleFrame.midX - 500,
                y: visibleFrame.midY - 360,
                width: 1000,
                height: 720
            )
        }

        return constrained(frame: baseFrame, inside: visibleFrame)
    }

    func saveWindowFrame(_ frame: NSRect) {
        guard settingsManager.settings().rememberWindowFrame else { return }
        defaults.set(NSStringFromRect(frame), forKey: frameKey)
    }

    private func constrained(frame: NSRect, inside visibleFrame: NSRect) -> NSRect {
        var adjusted = frame
        adjusted.size.width = min(max(adjusted.width, 420), visibleFrame.width)
        adjusted.size.height = min(max(adjusted.height, 320), visibleFrame.height)

        if adjusted.maxX > visibleFrame.maxX {
            adjusted.origin.x = visibleFrame.maxX - adjusted.width
        }
        if adjusted.minX < visibleFrame.minX {
            adjusted.origin.x = visibleFrame.minX
        }
        if adjusted.maxY > visibleFrame.maxY {
            adjusted.origin.y = visibleFrame.maxY - adjusted.height
        }
        if adjusted.minY < visibleFrame.minY {
            adjusted.origin.y = visibleFrame.minY
        }

        return adjusted
    }
}
