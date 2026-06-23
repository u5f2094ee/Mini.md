import AppKit
import QuartzCore

enum MarkdownEditorCommand {
    case selectAll
    case copy
    case cut
    case paste
    case undo
    case redo
}

enum MarkdownFindBarMode {
    case findOnly
    case findAndReplace
}

private struct StandardTextEditingShortcut {
    let action: Selector
    let editorCommand: MarkdownEditorCommand
}

@MainActor
protocol BrowserWindowCommandHandling: AnyObject {
    var isEditingDocument: Bool { get }
    var isSearchActive: Bool { get }

    func selectRenderedContent()
    func copyRenderedSelection()
    func closeCurrentInstance()
    func quitCurrentInstance()
    func toggleThemePreference()
    func refreshCurrentDocument()
    func printCurrentDocument()
    func exportCurrentDocumentAsHTML()
    func zoomRenderedContentIn()
    func zoomRenderedContentOut()
    func resetRenderedContentZoom()
    func zoomEditedContentIn()
    func zoomEditedContentOut()
    func selectNextDocumentTab()
    func toggleEditMode()
    func saveEditedDocument()
    func performEditorCommand(_ command: MarkdownEditorCommand) -> Bool
    func openSettingsFile()
    func showTitlebarPathMenu(atWindowLocation location: NSPoint) -> Bool
    func toggleSearch()
    func showFindAndReplace()
    func dismissSearchIfActive() -> Bool
}

final class BrowserWindow: NSWindow {
    weak var commandHandler: BrowserWindowCommandHandling?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if isTitlebarPathMenuEvent(event),
           commandHandler?.showTitlebarPathMenu(atWindowLocation: event.locationInWindow) == true {
            return
        }

        if event.type == .leftMouseDown, shouldDragWindow(for: event) {
            performDrag(with: event)
            return
        }

        if event.type == .keyDown, handleKeyDown(event) {
            return
        }

        super.sendEvent(event)
    }

    private func isTitlebarPathMenuEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown:
            return true
        case .leftMouseDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return flags.contains(.control)
        default:
            return false
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let relevantFlags = flags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let settings = MiniMDSettingsManager.shared.settings()

        if event.keyCode == 53 {
            if commandHandler?.dismissSearchIfActive() == true {
                return true
            }

            return false
        }

        if relevantFlags == .command,
           (key == "," || event.keyCode == 43) {
            commandHandler?.openSettingsFile()
            return true
        }

        if handleSystemShortcut(relevantFlags: relevantFlags, key: key) {
            return true
        }

        if settings.tabsEnabled,
           relevantFlags == .control,
           event.keyCode == 48 {
            commandHandler?.selectNextDocumentTab()
            return true
        }

        if relevantFlags == [.command, .option],
           key == "f",
           commandHandler?.isEditingDocument == true {
            commandHandler?.showFindAndReplace()
            return true
        }

        if relevantFlags == [.command, .shift],
           key == "e" {
            commandHandler?.exportCurrentDocumentAsHTML()
            return true
        }

        if relevantFlags == .command {
            switch key {
            case "e":
                commandHandler?.toggleEditMode()
                return true
            case "s":
                commandHandler?.saveEditedDocument()
                return true
            case "f":
                commandHandler?.toggleSearch()
                return true
            case "w":
                commandHandler?.closeCurrentInstance()
                return true
            case "q":
                commandHandler?.quitCurrentInstance()
                return true
            default:
                break
            }
        }

        if let textShortcut = standardTextEditingShortcut(for: relevantFlags, key: key) {
            if commandHandler?.isEditingDocument == true {
                if commandHandler?.performEditorCommand(textShortcut.editorCommand) == true {
                    return true
                }

                if NSApp.sendAction(textShortcut.action, to: nil, from: self) {
                    return true
                }

                return false
            }

            if commandHandler?.isSearchActive == true {
                if NSApp.sendAction(textShortcut.action, to: nil, from: self) {
                    return true
                }

                return false
            }
        }

        if let shortcut = settings.themeToggleShortcut,
           shortcut.matches(event) {
            commandHandler?.toggleThemePreference()
            return true
        }

        if let shortcut = settings.refreshShortcut,
           shortcut.matches(event) {
            commandHandler?.refreshCurrentDocument()
            return true
        }

        if commandHandler?.isEditingDocument == true,
           handleEditorZoomShortcut(event, flags: flags) {
            return true
        }

        if commandHandler?.isEditingDocument != true,
           handleRenderZoomShortcut(event, flags: flags, settings: settings) {
            return true
        }

        guard flags.contains(.command),
              let key else {
            return false
        }

        if commandHandler?.isEditingDocument == true {
            return false
        }

        let hasShift = flags.contains(.shift)

        if !hasShift {
            switch key {
            case "a":
                commandHandler?.selectRenderedContent()
                return true
            case "c":
                commandHandler?.copyRenderedSelection()
                return true
            default:
                return false
            }
        }

        return false
    }

    private func handleSystemShortcut(
        relevantFlags: NSEvent.ModifierFlags,
        key: String?
    ) -> Bool {
        guard let key else {
            return false
        }

        if relevantFlags == .command {
            switch key {
            case "h":
                NSApp.hide(nil)
                return true
            case "m":
                miniaturize(nil)
                return true
            case "p":
                commandHandler?.printCurrentDocument()
                return true
            default:
                return false
            }
        }

        return false
    }

    private func standardTextEditingShortcut(
        for relevantFlags: NSEvent.ModifierFlags,
        key: String?
    ) -> StandardTextEditingShortcut? {
        guard let key else { return nil }

        if relevantFlags == .command {
            switch key {
            case "a":
                return StandardTextEditingShortcut(action: #selector(NSResponder.selectAll(_:)), editorCommand: .selectAll)
            case "c":
                return StandardTextEditingShortcut(action: #selector(NSText.copy(_:)), editorCommand: .copy)
            case "x":
                return StandardTextEditingShortcut(action: #selector(NSText.cut(_:)), editorCommand: .cut)
            case "v":
                return StandardTextEditingShortcut(action: #selector(NSText.paste(_:)), editorCommand: .paste)
            case "z":
                return StandardTextEditingShortcut(action: Selector(("undo:")), editorCommand: .undo)
            default:
                return nil
            }
        }

        if relevantFlags == [.command, .shift], key == "z" {
            return StandardTextEditingShortcut(action: Selector(("redo:")), editorCommand: .redo)
        }

        return nil
    }

    private func handleEditorZoomShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        let relevantFlags = flags.intersection([.command, .shift, .option, .control])
        guard relevantFlags == .command else {
            return false
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "=", "+":
            commandHandler?.zoomEditedContentIn()
            return true
        case "-":
            commandHandler?.zoomEditedContentOut()
            return true
        default:
            return false
        }
    }

    private func handleRenderZoomShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags, settings: MiniMDSettings) -> Bool {
        if let shortcut = settings.zoomInShortcut, shortcut.matches(event) {
            commandHandler?.zoomRenderedContentIn()
            return true
        }

        if let shortcut = settings.zoomOutShortcut, shortcut.matches(event) {
            commandHandler?.zoomRenderedContentOut()
            return true
        }

        let relevantFlags = flags.intersection([.command, .shift, .option, .control])
        if relevantFlags == .command,
           event.keyCode == 29 || event.keyCode == 82 || event.charactersIgnoringModifiers == "0" {
            commandHandler?.resetRenderedContentZoom()
            return true
        }

        return false
    }

    private func shouldDragWindow(for event: NSEvent) -> Bool {
        guard let contentView else {
            return false
        }

        let point = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(point) else {
            return false
        }

        let settings = MiniMDSettingsManager.shared.settings()
        let dragHeight = settings.titlebarVisible ? DocumentTitlebarView.height(usesNativeTabs: settings.tabsEnabled) : 24
        let distanceFromTop = contentView.bounds.maxY - point.y
        guard distanceFromTop >= 0, distanceFromTop <= dragHeight else {
            return false
        }

        if settings.titlebarVisible,
           point.x < DocumentTitlebarView.titleLeading - 8 {
            return false
        }

        return true
    }
}

final class RoundedContentView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 16
        static let borderWidth: CGFloat = 0.5
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = Metrics.borderWidth
        layer?.allowsEdgeAntialiasing = true
        layer?.edgeAntialiasingMask = [
            .layerLeftEdge,
            .layerRightEdge,
            .layerTopEdge,
            .layerBottomEdge
        ]
        updateBackingScale()
        let resolved = ThemeManager.shared.resolvedThemePalette()
        applyThemeBackground(resolved.palette)
    }

    func applyThemeBackground(_ palette: MiniMDThemePalette) {
        layer?.backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: palette).cgColor
        layer?.borderColor = MiniMDWindowTheme.windowEdgeColor(for: palette).cgColor
    }

    private func updateBackingScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}

final class DragStripView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class DocumentLoadingBackdropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func applyTheme(_ palette: MiniMDThemePalette) {
        isHidden = false
        layer?.backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: palette).cgColor
    }

    func hide() {
        isHidden = true
    }

    private func configure() {
        wantsLayer = true
        let resolved = ThemeManager.shared.resolvedThemePalette()
        layer?.backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: resolved.palette).cgColor
    }
}

@MainActor
enum MiniMDWindowTheme {
    static func documentBackgroundColor(for palette: MiniMDThemePalette) -> NSColor {
        parsedColor(palette.backgroundHex)
            ?? parsedColor(MiniMDThemePalette.defaultLight.backgroundHex)
            ?? .windowBackgroundColor
    }

    static func documentBackgroundColor(for theme: DocumentTheme) -> NSColor {
        documentBackgroundColor(for: .default(for: theme))
    }

    static func foregroundColor(for palette: MiniMDThemePalette) -> NSColor {
        parsedColor(palette.foregroundHex)
            ?? parsedColor(MiniMDThemePalette.defaultLight.foregroundHex)
            ?? .labelColor
    }

    static func titleTextColor(for palette: MiniMDThemePalette) -> NSColor {
        foregroundColor(for: palette)
    }

    static func windowEdgeColor(for palette: MiniMDThemePalette) -> NSColor {
        guard let background = documentBackgroundColor(for: palette).usingColorSpace(.sRGB) else {
            return NSColor.white.withAlphaComponent(0.12)
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        if luminance < 0.45 {
            return NSColor.white.withAlphaComponent(0.12)
        }

        return NSColor.black.withAlphaComponent(0.08)
    }

    static func windowAppearance(for theme: DocumentTheme) -> NSAppearance? {
        switch theme {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    private static func parsedColor(_ normalizedHex: String) -> NSColor? {
        let hex = normalizedHex.hasPrefix("#") ? String(normalizedHex.dropFirst()) : normalizedHex
        guard hex.count == 6,
              let value = Int(hex, radix: 16) else {
            return nil
        }

        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }
}

final class DocumentTitlebarView: NSView {
    private enum Metrics {
        static let standardHeight: CGFloat = 52
        static let tabbedHeight: CGFloat = 64
        static let standardTitleCenterY: CGFloat = 25
        static let tabbedTitleCenterY: CGFloat = 20
        static let standardTrafficLightTopInset: CGFloat = 18
        static let tabbedTrafficLightTopInset: CGFloat = 11
        static let pathMenuIconSize = NSSize(width: 16, height: 16)
    }

    static let titleLeading: CGFloat = 96
    static let titleTrailing: CGFloat = 20

    static func height(usesNativeTabs: Bool) -> CGFloat {
        usesNativeTabs ? Metrics.tabbedHeight : Metrics.standardHeight
    }

    static func trafficLightTopInset(usesNativeTabs: Bool) -> CGFloat {
        usesNativeTabs ? Metrics.tabbedTrafficLightTopInset : Metrics.standardTrafficLightTopInset
    }

    private let backdropView = TitlebarBackdropView()
    private let titleLabel: NSTextField
    private let editedIndicatorView = EditedIndicatorView(frame: .zero)
    private let fileURL: URL
    private let usesNativeTabs: Bool
    private var subtitle: String?
    private var currentTheme: DocumentTheme = .light
    private var currentPalette: MiniMDThemePalette = .defaultLight

    private var fileName: String {
        fileURL.lastPathComponent
    }

    init(fileURL: URL, usesNativeTabs: Bool) {
        self.fileURL = fileURL
        self.usesNativeTabs = usesNativeTabs
        self.titleLabel = NSTextField(labelWithString: fileURL.lastPathComponent)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           showPathMenu(atWindowLocation: event.locationInWindow) {
            return
        }

        window?.performDrag(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard showPathMenu(atWindowLocation: event.locationInWindow) else {
            super.rightMouseDown(with: event)
            return
        }
    }

    func applyTheme(_ resolved: MiniMDResolvedTheme) {
        currentTheme = resolved.theme
        currentPalette = resolved.palette
        backdropView.applyTheme(resolved.palette)
        titleLabel.textColor = MiniMDWindowTheme.titleTextColor(for: resolved.palette)
        editedIndicatorView.applyTheme(resolved)
    }

    func updateSubtitle(_ subtitle: String?) {
        self.subtitle = subtitle
        updateTitleText()
        needsLayout = true
    }

    func setEdited(_ edited: Bool) {
        editedIndicatorView.setEdited(edited)
        needsLayout = true
    }

    @discardableResult
    func showPathMenu(atWindowLocation location: NSPoint) -> Bool {
        guard containsPathMenuLocation(location) else {
            return false
        }

        showPathMenu(at: convert(location, from: nil))
        return true
    }

    func containsPathMenuLocation(_ location: NSPoint) -> Bool {
        layoutSubtreeIfNeeded()
        return titlebarPathMenuRect.contains(convert(location, from: nil))
    }

    override func layout() {
        super.layout()

        let labelHeight = ceil(titleLabel.intrinsicContentSize.height)
        let indicatorGap: CGFloat = editedIndicatorView.isHidden ? 0 : 10
        let indicatorWidth: CGFloat = editedIndicatorView.isHidden ? 0 : EditedIndicatorView.size
        let availableWidth = max(0, bounds.width - Self.titleLeading - Self.titleTrailing - indicatorGap - indicatorWidth)
        let titleCenterY = usesNativeTabs ? Metrics.tabbedTitleCenterY : Metrics.standardTitleCenterY
        titleLabel.frame = NSRect(
            x: Self.titleLeading,
            y: titleCenterY - labelHeight / 2,
            width: availableWidth,
            height: labelHeight
        )

        editedIndicatorView.frame = NSRect(
            x: titleLabel.frame.maxX + indicatorGap,
            y: titleCenterY - EditedIndicatorView.size / 2,
            width: EditedIndicatorView.size,
            height: EditedIndicatorView.size
        )
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(titleLabel)

        editedIndicatorView.applyTheme(MiniMDResolvedTheme(theme: currentTheme, palette: currentPalette))
        editedIndicatorView.setEdited(false)
        addSubview(editedIndicatorView)
        updateTitleText()
    }

    private var titlebarPathMenuRect: NSRect {
        if editedIndicatorView.isHidden {
            return titleLabel.frame
        }

        return titleLabel.frame.union(editedIndicatorView.frame)
    }

    private func showPathMenu(at point: NSPoint) {
        let menu = NSMenu()
        pathMenuURLs().forEach { url in
            let item = NSMenuItem(
                title: pathMenuTitle(for: url),
                action: #selector(openPathMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.image = Self.pathMenuIcon(for: url)
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: point, in: self)
    }

    static func pathMenuIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
        icon.size = Metrics.pathMenuIconSize
        return icon
    }

    private func pathMenuURLs() -> [URL] {
        var urls: [URL] = []
        var currentURL = fileURL

        while true {
            urls.append(currentURL)
            let parentURL = currentURL.deletingLastPathComponent()
            guard parentURL.path != currentURL.path else {
                break
            }
            currentURL = parentURL
        }

        return urls
    }

    private func pathMenuTitle(for url: URL) -> String {
        if url.path == "/" {
            return "/"
        }

        let title = url.lastPathComponent
        return title.isEmpty ? url.path : title
    }

    @objc private func openPathMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }

        if url == fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateTitleText() {
        if let subtitle, !subtitle.isEmpty {
            titleLabel.stringValue = "\(fileName) - \(subtitle)"
        } else {
            titleLabel.stringValue = fileName
        }
    }
}

final class EditedIndicatorView: NSView {
    static let size: CGFloat = 7

    private var currentTheme: DocumentTheme = .light
    private var currentPalette: MiniMDThemePalette = .defaultLight
    private var edited = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func applyTheme(_ resolved: MiniMDResolvedTheme) {
        currentTheme = resolved.theme
        currentPalette = resolved.palette
        updateAppearance()
    }

    func setEdited(_ edited: Bool) {
        self.edited = edited
        isHidden = !edited
        updateAppearance()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.masksToBounds = true
        isHidden = true
    }

    private func updateAppearance() {
        let base = MiniMDWindowTheme.foregroundColor(for: currentPalette)
        let alpha: CGFloat = currentTheme == .dark ? 0.9 : 0.82
        layer?.backgroundColor = edited ? base.withAlphaComponent(alpha).cgColor : NSColor.clear.cgColor
    }
}

final class TitlebarBackdropView: NSView {
    private let backgroundView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func applyTheme(_ palette: MiniMDThemePalette) {
        backgroundView.layer?.backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: palette).cgColor
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(backgroundView)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class MiniMDHUDView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(
            width: min(max(labelSize.width + 28, 180), 420),
            height: labelSize.height + 16
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(message: String) {
        hideWorkItem?.cancel()
        label.stringValue = message
        invalidateIntrinsicContentSize()
        isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.animator().alphaValue = 0
            } completionHandler: {
                DispatchQueue.main.async {
                    self.isHidden = true
                }
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }

    private func configure() {
        isHidden = true
        alphaValue = 0
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }
}

final class MarkdownSearchBarView: NSVisualEffectView, NSSearchFieldDelegate {
    private let searchField = NSSearchField(frame: .zero)
    private let replaceField = NSTextField(frame: .zero)
    private let countLabel = NSTextField(labelWithString: "")
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let replaceAllButton = NSButton(title: "All", target: nil, action: nil)

    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onReplace: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var mode: MarkdownFindBarMode = .findOnly

    private var query: String {
        searchField.stringValue
    }

    var currentQuery: String {
        query
    }

    var currentReplacement: String {
        replaceField.stringValue
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func preferredSize(for mode: MarkdownFindBarMode) -> NSSize {
        switch mode {
        case .findOnly:
            return NSSize(width: 282, height: 34)
        case .findAndReplace:
            return NSSize(width: 360, height: 68)
        }
    }

    func show(in window: NSWindow?, mode: MarkdownFindBarMode) {
        applyMode(mode)
        isHidden = false
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func hideAndClear() {
        searchField.stringValue = ""
        replaceField.stringValue = ""
        countLabel.stringValue = ""
        setReplaceActionsEnabled(replace: false, replaceAll: false)
        isHidden = true
    }

    func updateMatchCount(_ count: Int, activeIndex: Int?) {
        guard count > 0 else {
            countLabel.stringValue = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "0"
            return
        }

        if let activeIndex, activeIndex >= 0 {
            countLabel.stringValue = "\(activeIndex + 1)/\(count)"
        } else {
            countLabel.stringValue = "\(count)"
        }
    }

    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        guard let window,
              let firstResponder = window.firstResponder else {
            return false
        }

        if firstResponder === searchField || firstResponder === replaceField {
            return true
        }

        if let firstResponderView = firstResponder as? NSView,
           firstResponderView.isDescendant(of: self) {
            return true
        }

        if let fieldEditor = window.fieldEditor(false, for: searchField),
           firstResponder === fieldEditor {
            return true
        }

        if let fieldEditor = window.fieldEditor(false, for: replaceField),
           firstResponder === fieldEditor {
            return true
        }

        return false
    }

    func setReplaceActionsEnabled(replace: Bool, replaceAll: Bool) {
        replaceButton.isEnabled = replace
        replaceAllButton.isEnabled = replaceAll
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isSearchFieldChange(obj) else {
            return
        }

        notifySearchQueryChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                onReplace?()
                return true
            }

            onNext?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    private func configure() {
        isHidden = true
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.placeholderString = "Search"
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.delegate = self
        replaceField.placeholderString = "Replace with"
        replaceField.focusRingType = .none
        replaceField.lineBreakMode = .byTruncatingTail

        configureReplaceButton(replaceButton, action: #selector(replaceButtonClicked(_:)))
        configureReplaceButton(replaceAllButton, action: #selector(replaceAllButtonClicked(_:)))

        addSubview(searchField)
        addSubview(countLabel)
        addSubview(replaceField)
        addSubview(replaceButton)
        addSubview(replaceAllButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            searchField.heightAnchor.constraint(equalToConstant: 22),
            searchField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),

            replaceField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            replaceField.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            replaceField.heightAnchor.constraint(equalToConstant: 22),
            replaceField.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -8),

            replaceButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceButton.widthAnchor.constraint(equalToConstant: 72),
            replaceButton.trailingAnchor.constraint(equalTo: replaceAllButton.leadingAnchor, constant: -6),

            replaceAllButton.centerYAnchor.constraint(equalTo: replaceField.centerYAnchor),
            replaceAllButton.widthAnchor.constraint(equalToConstant: 44),
            replaceAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        applyMode(.findOnly)
    }

    private func configureReplaceButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        button.setButtonType(.momentaryPushIn)
        button.isEnabled = false
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func applyMode(_ newMode: MarkdownFindBarMode) {
        mode = newMode
        let showsReplaceControls = newMode == .findAndReplace
        searchField.placeholderString = showsReplaceControls ? "Find" : "Search"
        replaceField.isHidden = !showsReplaceControls
        replaceButton.isHidden = !showsReplaceControls
        replaceAllButton.isHidden = !showsReplaceControls
        if !showsReplaceControls {
            setReplaceActionsEnabled(replace: false, replaceAll: false)
        }
    }

    private func isSearchFieldChange(_ notification: Notification) -> Bool {
        if let changedField = notification.object as? NSTextField {
            return changedField === searchField
        }

        if let fieldEditor = notification.object as? NSText {
            return searchField.currentEditor() === fieldEditor
        }

        return false
    }

    private func notifySearchQueryChanged() {
        onQueryChanged?(searchField.stringValue)
    }

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        notifySearchQueryChanged()
    }

    @objc private func replaceButtonClicked(_ sender: NSButton) {
        onReplace?()
    }

    @objc private func replaceAllButtonClicked(_ sender: NSButton) {
        onReplaceAll?()
    }
}
