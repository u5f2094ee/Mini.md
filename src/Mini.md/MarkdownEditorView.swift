import AppKit

@MainActor
final class MarkdownEditorView: NSView, NSTextViewDelegate, MarkdownSearchTarget {
    private enum ContentZoom {
        static let defaultFontSize: CGFloat = 14
        static let minimumFontSize: CGFloat = 10
        static let maximumFontSize: CGFloat = 28
        static let step: CGFloat = 1
    }

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let searchController: MarkdownEditorSearchController
    private let keywordHighlighter: MarkdownKeywordHighlighter
    private var currentTheme: DocumentTheme = .light
    private var currentPalette: MiniMDThemePalette = .defaultLight
    private var editorFontSize: CGFloat
    private var isSettingText = false
    private var isReplacingText = false
    private var topContentInset: CGFloat = 0
    private var highlightConfigurationObserver: NSObjectProtocol?

    var onTextChanged: ((String) -> Void)?

    var text: String {
        get { textView.string }
        set {
            isSettingText = true
            textView.string = newValue
            textView.undoManager?.removeAllActions()
            searchController.clear(preserveScroll: false)
            keywordHighlighter.applyNow(to: textView, theme: currentTheme, reason: .textAssigned)
            isSettingText = false
        }
    }

    override init(frame frameRect: NSRect) {
        self.scrollView = NSScrollView(frame: .zero)
        self.textView = NSTextView(frame: .zero)
        self.searchController = MarkdownEditorSearchController(textView: textView)
        self.keywordHighlighter = MarkdownKeywordHighlighter()
        self.editorFontSize = Self.defaultEditorFontSize()
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        if let highlightConfigurationObserver {
            NotificationCenter.default.removeObserver(highlightConfigurationObserver)
        }
        keywordHighlighter.cancelScheduledApply()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    @discardableResult
    func perform(_ command: MarkdownEditorCommand) -> Bool {
        focus()

        switch command {
        case .selectAll:
            textView.selectAll(nil)
            return true
        case .copy:
            textView.copy(nil)
            return true
        case .cut:
            return performMutatingTextCommand {
                textView.cut(nil)
            }
        case .paste:
            return performMutatingTextCommand {
                textView.paste(nil)
            }
        case .undo:
            guard let undoManager = textView.undoManager,
                  undoManager.canUndo else {
                NSSound.beep()
                return true
            }

            let previousText = textView.string
            undoManager.undo()
            notifyIfTextChanged(from: previousText)
            return true
        case .redo:
            guard let undoManager = textView.undoManager,
                  undoManager.canRedo else {
                NSSound.beep()
                return true
            }

            let previousText = textView.string
            undoManager.redo()
            notifyIfTextChanged(from: previousText)
            return true
        }
    }

    func setTopContentInset(_ inset: CGFloat) {
        topContentInset = max(0, inset)
        updateContentInsets()
    }

    func increaseContentZoom() {
        setEditorFontSize(editorFontSize + ContentZoom.step)
    }

    func decreaseContentZoom() {
        setEditorFontSize(editorFontSize - ContentZoom.step)
    }

    func printDocument(named jobTitle: String) {
        focus()

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func applyTheme(_ resolved: MiniMDResolvedTheme) {
        currentTheme = resolved.theme
        currentPalette = resolved.palette
        let backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: resolved.palette)
        let textColor = MiniMDWindowTheme.foregroundColor(for: resolved.palette)

        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        scrollView.backgroundColor = backgroundColor
        textView.backgroundColor = backgroundColor
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        applyEditorFont(textColor: textColor)
        searchController.reapply(theme: resolved.theme)
        keywordHighlighter.applyNow(to: textView, theme: resolved.theme, reason: .themeChanged)
    }

    func refreshKeywordHighlightingNow() {
        keywordHighlighter.applyNow(to: textView, theme: currentTheme, reason: .manualReload)
    }

    func applyHighlightsAfterSave() {
        keywordHighlighter.applyNow(to: textView, theme: currentTheme, reason: .documentSaved)
    }

    func scrollRatio() -> CGFloat {
        guard let documentView = scrollView.documentView else {
            return 0
        }

        let visibleHeight = scrollView.contentView.bounds.height
        let scrollableHeight = max(documentView.bounds.height - visibleHeight, 1)
        return min(max(scrollView.contentView.bounds.origin.y / scrollableHeight, 0), 1)
    }

    func restoreScrollRatio(_ ratio: CGFloat) {
        guard let documentView = scrollView.documentView else {
            return
        }

        let visibleHeight = scrollView.contentView.bounds.height
        let scrollableHeight = max(documentView.bounds.height - visibleHeight, 0)
        let y = min(max(ratio, 0), 1) * scrollableHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func updateSearchQuery(_ query: String, completion: ((SearchResultState) -> Void)?) {
        let state = searchController.highlight(query: query, theme: currentTheme)
        completion?(state)
    }

    func activateNextSearchMatch(completion: ((SearchResultState) -> Void)?) {
        let state = searchController.next(theme: currentTheme)
        completion?(state)
    }

    func hasCaseSensitiveReplacementMatch(query: String) -> Bool {
        searchController.hasCaseSensitiveReplacementMatch(query: query)
    }

    func canReplaceCurrentSearchMatch(query: String) -> Bool {
        searchController.canReplaceCurrentCaseSensitiveMatch(query: query)
    }

    func replaceCurrentSearchMatch(query: String, replacement: String) -> SearchResultState {
        performReplacingText {
            searchController.replaceCurrent(query: query, replacement: replacement, theme: currentTheme)
        }
    }

    func replaceAllSearchMatches(query: String, replacement: String) -> SearchResultState {
        performReplacingText {
            searchController.replaceAll(query: query, replacement: replacement, theme: currentTheme)
        }
    }

    func clearSearchHighlightsPreservingScroll() {
        searchController.clear(preserveScroll: true)
    }

    func textDidChange(_ notification: Notification) {
        guard !isSettingText, !isReplacingText else {
            return
        }

        onTextChanged?(textView.string)
        keywordHighlighter.markNeedsRefresh()
    }

    @discardableResult
    private func performMutatingTextCommand(_ command: () -> Void) -> Bool {
        let previousText = textView.string
        command()
        notifyIfTextChanged(from: previousText)
        return true
    }

    private func notifyIfTextChanged(from previousText: String) {
        guard !isSettingText,
              !isReplacingText,
              textView.string != previousText else {
            return
        }

        onTextChanged?(textView.string)
        keywordHighlighter.markNeedsRefresh()
    }

    private func performReplacingText(_ replacement: () -> SearchResultState) -> SearchResultState {
        let previousText = textView.string
        isReplacingText = true
        let state = replacement()
        isReplacingText = false

        if textView.string != previousText {
            onTextChanged?(textView.string)
            keywordHighlighter.applyNow(to: textView, theme: currentTheme, reason: .manualReload)
        }

        return state
    }

    private func configure() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = editorFont()
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateContentInsets()
        applyTheme(ThemeManager.shared.resolvedThemePalette())
        observeHighlightConfigurationChanges()
    }

    private func updateContentInsets() {
        scrollView.contentInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: topContentInset, left: 0, bottom: 0, right: 0)
    }

    private func setEditorFontSize(_ fontSize: CGFloat) {
        let clampedSize = min(max(fontSize, ContentZoom.minimumFontSize), ContentZoom.maximumFontSize)
        guard clampedSize != editorFontSize else {
            NSSound.beep()
            return
        }

        let selectedRanges = textView.selectedRanges
        let scrollRatio = scrollRatio()
        editorFontSize = clampedSize
        applyEditorFont(textColor: MiniMDWindowTheme.foregroundColor(for: currentPalette))
        textView.selectedRanges = selectedRanges
        restoreScrollRatio(scrollRatio)
        searchController.reapply(theme: currentTheme)
        keywordHighlighter.applyNow(to: textView, theme: currentTheme)
    }

    private func applyEditorFont(textColor: NSColor) {
        let font = editorFont()
        textView.font = font
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]
    }

    private func editorFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    private static func defaultEditorFontSize() -> CGFloat {
        let scaledSize = ContentZoom.defaultFontSize * MiniMDSettingsManager.shared.settings().defaultEditZoom
        return min(max(scaledSize, ContentZoom.minimumFontSize), ContentZoom.maximumFontSize)
    }

    private func observeHighlightConfigurationChanges() {
        highlightConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .miniMDHighlightConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.keywordHighlighter.invalidateConfigurationAndApply(to: self.textView, theme: self.currentTheme)
            }
        }
    }
}
