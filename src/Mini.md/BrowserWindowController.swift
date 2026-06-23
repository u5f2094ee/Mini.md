import AppKit

private enum DocumentMode {
    case preview
    case editing
}

private enum UnsavedEditChoice {
    case save
    case discard
    case cancel
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, BrowserWindowCommandHandling {
    var isEditingDocument: Bool { documentMode == .editing }
    var isSearchActive: Bool { !searchBarView.isHidden }

    private let fileURL: URL
    var documentFileURL: URL { fileURL }
    var onWindowWillClose: (() -> Void)?

    private let renderView: MarkdownRenderView
    private let editorView: MarkdownEditorView
    private let renderer = MarkdownRenderer()
    private let htmlExporter = MarkdownHTMLExporter()
    private let container: RoundedContentView
    private let titlebarView: DocumentTitlebarView?
    private let fallbackEditedIndicatorView: EditedIndicatorView?
    private let loadingBackdropView: DocumentLoadingBackdropView
    private let searchBarView = MarkdownSearchBarView(frame: .zero)
    private let hudView = MiniMDHUDView(frame: .zero)
    private var searchBarWidthConstraint: NSLayoutConstraint!
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private let usesNativeTabs: Bool
    private let titlebarHeight: CGFloat

    private var documentMode: DocumentMode = .preview
    private var sourceEncoding: String.Encoding = .utf8
    private var originalTextAtEditStart = ""
    private var isDirty = false
    private var highlightConfigurationObserver: NSObjectProtocol?

    private var activeSearchTarget: MarkdownSearchTarget {
        documentMode == .editing ? editorView : renderView
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.renderView = MarkdownRenderView(frame: .zero)
        self.editorView = MarkdownEditorView(frame: .zero)
        HighlightConfigurationMonitor.shared.start()
        let settings = MiniMDSettingsManager.shared.settings()
        self.container = RoundedContentView(frame: .zero)
        self.usesNativeTabs = settings.tabsEnabled
        self.titlebarHeight = settings.titlebarVisible ? DocumentTitlebarView.height(usesNativeTabs: settings.tabsEnabled) : 0
        self.titlebarView = settings.titlebarVisible ? DocumentTitlebarView(fileURL: fileURL, usesNativeTabs: settings.tabsEnabled) : nil
        self.fallbackEditedIndicatorView = settings.titlebarVisible ? nil : EditedIndicatorView(frame: .zero)
        self.loadingBackdropView = DocumentLoadingBackdropView(frame: .zero)

        let frame = ThemeManager.shared.restoredWindowFrame()
        let window = BrowserWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        container.translatesAutoresizingMaskIntoConstraints = false
        renderView.translatesAutoresizingMaskIntoConstraints = false
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorView.isHidden = true

        container.addSubview(renderView)
        container.addSubview(editorView)
        container.addSubview(loadingBackdropView)
        renderView.setTopContentInset(titlebarHeight)
        editorView.setTopContentInset(titlebarHeight)
        loadingBackdropView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        hudView.translatesAutoresizingMaskIntoConstraints = false

        if let titlebarView {
            titlebarView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(titlebarView)

            NSLayoutConstraint.activate([
                titlebarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                titlebarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                titlebarView.topAnchor.constraint(equalTo: container.topAnchor),
                titlebarView.heightAnchor.constraint(equalToConstant: titlebarHeight),

                renderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                renderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                renderView.topAnchor.constraint(equalTo: container.topAnchor),
                renderView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                editorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                editorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                editorView.topAnchor.constraint(equalTo: container.topAnchor),
                editorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                loadingBackdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                loadingBackdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                loadingBackdropView.topAnchor.constraint(equalTo: container.topAnchor),
                loadingBackdropView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        } else {
            let dragStrip = DragStripView(frame: .zero)
            dragStrip.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(dragStrip)

            NSLayoutConstraint.activate([
                renderView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                renderView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                renderView.topAnchor.constraint(equalTo: container.topAnchor),
                renderView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                editorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                editorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                editorView.topAnchor.constraint(equalTo: container.topAnchor),
                editorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                loadingBackdropView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                loadingBackdropView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                loadingBackdropView.topAnchor.constraint(equalTo: container.topAnchor),
                loadingBackdropView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                dragStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                dragStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                dragStrip.topAnchor.constraint(equalTo: container.topAnchor),
                dragStrip.heightAnchor.constraint(equalToConstant: 24)
            ])

            if let fallbackEditedIndicatorView {
                fallbackEditedIndicatorView.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(fallbackEditedIndicatorView, positioned: .above, relativeTo: nil)
                NSLayoutConstraint.activate([
                    fallbackEditedIndicatorView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                    fallbackEditedIndicatorView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                    fallbackEditedIndicatorView.widthAnchor.constraint(equalToConstant: EditedIndicatorView.size),
                    fallbackEditedIndicatorView.heightAnchor.constraint(equalToConstant: EditedIndicatorView.size)
                ])
            }
        }

        container.addSubview(searchBarView, positioned: .above, relativeTo: nil)
        container.addSubview(hudView, positioned: .above, relativeTo: nil)
        let searchTopOffset: CGFloat = settings.titlebarVisible ? titlebarHeight + 10 : 32
        let initialSearchBarSize = MarkdownSearchBarView.preferredSize(for: .findOnly)
        searchBarWidthConstraint = searchBarView.widthAnchor.constraint(equalToConstant: initialSearchBarSize.width)
        searchBarHeightConstraint = searchBarView.heightAnchor.constraint(equalToConstant: initialSearchBarSize.height)
        NSLayoutConstraint.activate([
            searchBarView.topAnchor.constraint(equalTo: container.topAnchor, constant: searchTopOffset),
            searchBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            searchBarWidthConstraint,
            searchBarHeightConstraint,

            hudView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hudView.topAnchor.constraint(equalTo: container.topAnchor, constant: searchTopOffset),
            hudView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40)
        ])

        window.contentView = container
        window.commandHandler = nil
        window.title = fileURL.lastPathComponent
        window.representedURL = fileURL
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = true
        window.collectionBehavior = [.fullScreenNone]
        window.tabbingMode = settings.tabsEnabled ? .preferred : .disallowed
        window.minSize = NSSize(width: 420, height: 320)
        window.isMovableByWindowBackground = true

        [.closeButton, .miniaturizeButton, .zoomButton]
            .forEach { window.standardWindowButton($0)?.isHidden = !settings.titlebarVisible }
        [.documentIconButton, .documentVersionsButton]
            .forEach { window.standardWindowButton($0)?.isHidden = true }

        super.init(window: window)

        window.delegate = self
        window.commandHandler = self
        observeHighlightConfigurationChanges()
        renderView.onDocumentDidFinishLoad = { [weak self] in
            guard let self else { return }
            self.loadingBackdropView.hide()
            self.refreshActiveSearchResults()
        }
        editorView.onTextChanged = { [weak self] text in
            self?.handleEditedTextChanged(text)
        }
        searchBarView.onQueryChanged = { [weak self] _ in
            self?.refreshActiveSearchResults()
        }
        searchBarView.onNext = { [weak self] in
            self?.activeSearchTarget.activateNextSearchMatch { state in
                self?.applySearchResultState(state)
            }
        }
        searchBarView.onReplace = { [weak self] in
            self?.replaceCurrentSearchMatch()
        }
        searchBarView.onReplaceAll = { [weak self] in
            self?.replaceAllSearchMatches()
        }
        searchBarView.onCancel = { [weak self] in
            _ = self?.dismissSearchIfActive()
        }
        openInitialDocument(defaultOpenMode: settings.openMode(for: fileURL))
    }

    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        if let highlightConfigurationObserver {
            NotificationCenter.default.removeObserver(highlightConfigurationObserver)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        stabilizeIntegratedTitlebarControls()
        activeSearchTarget.focus()
    }

    func windowDidResize(_ notification: Notification) {
        stabilizeIntegratedTitlebarControls()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        stabilizeIntegratedTitlebarControls()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard documentMode == .editing, isDirty else {
            return true
        }

        switch confirmUnsavedEditsForClose() {
        case .save:
            return saveEditedDocumentForCurrentBuffer()
        case .discard:
            updateEditedState(false)
            return true
        case .cancel:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let frame = window?.frame {
            ThemeManager.shared.saveWindowFrame(frame)
        }

        if let onWindowWillClose {
            onWindowWillClose()
        } else {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func selectRenderedContent() {
        guard documentMode == .preview else { return }
        renderView.selectAll()
    }

    func copyRenderedSelection() {
        guard documentMode == .preview else { return }
        renderView.copySelection()
    }

    func closeCurrentInstance() {
        if let frame = window?.frame {
            ThemeManager.shared.saveWindowFrame(frame)
        }
        window?.performClose(nil)
    }

    func quitCurrentInstance() {
        closeCurrentInstance()
    }

    func toggleThemePreference() {
        _ = ThemeManager.shared.toggleExplicitTheme()
        let resolved = ThemeManager.shared.resolvedThemePalette()

        if documentMode == .editing {
            applyEditingTheme(resolved)
            refreshActiveSearchResults()
        } else {
            loadCurrentDocument()
        }
    }

    func refreshCurrentDocument() {
        if documentMode == .editing {
            refreshEditedDocumentFromDisk()
            return
        }

        loadCurrentDocument()
        renderView.focus()
    }

    func printCurrentDocument() {
        switch documentMode {
        case .preview:
            renderView.printDocument(named: fileURL.lastPathComponent)
        case .editing:
            editorView.printDocument(named: fileURL.lastPathComponent)
        }
    }

    func exportCurrentDocumentAsHTML() {
        let settings = MiniMDSettingsManager.shared.settings()
        let exportSettings = settings.htmlExport
        let markdownSource = documentMode == .editing ? editorView.text : nil
        let fileURL = self.fileURL
        let exporter = self.htmlExporter

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try exporter.export(
                    fileURL: fileURL,
                    markdownSource: markdownSource,
                    settings: exportSettings
                )
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let outputURL):
                    self.hudView.show(message: "Exported \(outputURL.lastPathComponent)")
                case .failure(let error):
                    self.presentError("Could not export HTML.", error: error)
                }
            }
        }
    }

    func zoomRenderedContentIn() {
        guard documentMode == .preview else { return }
        renderView.increaseContentZoom()
    }

    func zoomRenderedContentOut() {
        guard documentMode == .preview else { return }
        renderView.decreaseContentZoom()
    }

    func resetRenderedContentZoom() {
        guard documentMode == .preview else { return }
        renderView.resetContentZoom()
    }

    func zoomEditedContentIn() {
        guard documentMode == .editing else { return }
        editorView.increaseContentZoom()
    }

    func zoomEditedContentOut() {
        guard documentMode == .editing else { return }
        editorView.decreaseContentZoom()
    }

    func selectNextDocumentTab() {
        window?.selectNextTab(nil)
    }

    func toggleEditMode() {
        switch documentMode {
        case .preview:
            _ = enterEditMode()
        case .editing:
            leaveEditMode()
        }
    }

    func saveEditedDocument() {
        guard documentMode == .editing else {
            return
        }

        _ = saveEditedDocumentForCurrentBuffer()
    }

    func performEditorCommand(_ command: MarkdownEditorCommand) -> Bool {
        guard documentMode == .editing else {
            return false
        }

        if !searchBarView.isHidden,
           searchBarView.ownsFirstResponder(in: window) {
            return false
        }

        return editorView.perform(command)
    }

    func openSettingsFile() {
        let manager = MiniMDSettingsManager.shared
        _ = manager.settings()

        guard FileManager.default.fileExists(atPath: manager.settingsFileURL.path) else {
            presentError("Could not open settings.json.", detail: "Mini.md could not create \(manager.settingsFileURL.path).")
            return
        }

        if !NSWorkspace.shared.open(manager.settingsFileURL) {
            NSWorkspace.shared.activateFileViewerSelecting([manager.settingsFileURL])
        }
    }

    func showTitlebarPathMenu(atWindowLocation location: NSPoint) -> Bool {
        guard canShowTitlebarPathMenu(atWindowLocation: location) else {
            return false
        }

        return titlebarView?.showPathMenu(atWindowLocation: location) ?? false
    }

    func canShowTitlebarPathMenu(atWindowLocation location: NSPoint) -> Bool {
        titlebarView?.containsPathMenuLocation(location) ?? false
    }

    func toggleSearch() {
        if searchBarView.isHidden {
            let mode: MarkdownFindBarMode = documentMode == .editing ? .findAndReplace : .findOnly
            showSearchBar(mode: mode)
        } else {
            _ = dismissSearchIfActive()
        }
    }

    func showFindAndReplace() {
        guard documentMode == .editing else {
            return
        }

        showSearchBar(mode: .findAndReplace)
    }

    func dismissSearchIfActive() -> Bool {
        guard !searchBarView.isHidden else {
            return false
        }

        let target = activeSearchTarget
        searchBarView.hideAndClear()
        target.clearSearchHighlightsPreservingScroll()
        target.focus()
        return true
    }

    private func showSearchBar(mode: MarkdownFindBarMode) {
        updateSearchBarLayout(for: mode)
        searchBarView.show(in: window, mode: mode)
        refreshActiveSearchResults()
    }

    private func updateSearchBarLayout(for mode: MarkdownFindBarMode) {
        let size = MarkdownSearchBarView.preferredSize(for: mode)
        searchBarWidthConstraint.constant = size.width
        searchBarHeightConstraint.constant = size.height
        container.layoutSubtreeIfNeeded()
    }

    private func openInitialDocument(defaultOpenMode: MiniMDDefaultOpenMode) {
        switch defaultOpenMode {
        case .render:
            updateDocumentTitle()
            loadCurrentDocument()
        case .edit:
            if !enterEditMode() {
                updateDocumentTitle()
                loadCurrentDocument()
            }
        }
    }

    @discardableResult
    private func enterEditMode() -> Bool {
        guard documentMode == .preview else { return false }

        _ = dismissSearchIfActive()

        do {
            var detectedEncoding = String.Encoding.utf8
            let source = try String(contentsOf: fileURL, usedEncoding: &detectedEncoding)
            sourceEncoding = detectedEncoding
            originalTextAtEditStart = source
            editorView.text = source

            documentMode = .editing
            renderView.isHidden = true
            editorView.isHidden = false
            loadingBackdropView.hide()
            applyEditingTheme(ThemeManager.shared.resolvedThemePalette())
            editorView.refreshKeywordHighlightingNow()
            updateEditedState(false)
            editorView.focus()
            stabilizeIntegratedTitlebarControls()
            return true
        } catch {
            presentError("Could not open this Markdown file for editing.", error: error)
            return false
        }
    }

    private func leaveEditMode() {
        guard documentMode == .editing else { return }

        _ = dismissSearchIfActive()

        if isDirty {
            switch confirmUnsavedEditsForPreview() {
            case .save:
                guard saveEditedDocumentForCurrentBuffer() else { return }
                exitToPreviewAndRender()
            case .discard:
                updateEditedState(false)
                exitToPreviewAndRender()
            case .cancel:
                editorView.focus()
            }
        } else {
            exitToPreviewAndRender()
        }
    }

    private func exitToPreviewAndRender() {
        documentMode = .preview
        editorView.isHidden = true
        renderView.isHidden = false
        updateDocumentTitle()
        loadCurrentDocument()
        renderView.focus()
        stabilizeIntegratedTitlebarControls()
    }

    @discardableResult
    private func saveEditedDocumentForCurrentBuffer() -> Bool {
        guard documentMode == .editing else {
            return false
        }

        do {
            try editorView.text.write(to: fileURL, atomically: true, encoding: sourceEncoding)
            originalTextAtEditStart = editorView.text
            updateEditedState(false)
            editorView.applyHighlightsAfterSave()
            refreshActiveSearchResults()
            return true
        } catch {
            updateEditedState(true)
            presentError("Could not save this Markdown file.", error: error)
            editorView.focus()
            return false
        }
    }

    private func refreshEditedDocumentFromDisk() {
        if isDirty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Discard unsaved edits?"
            alert.informativeText = "Refreshing will reload this Markdown file from disk."
            alert.addButton(withTitle: "Discard and Reload")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                editorView.focus()
                return
            }
        }

        do {
            _ = dismissSearchIfActive()
            var detectedEncoding = String.Encoding.utf8
            let source = try String(contentsOf: fileURL, usedEncoding: &detectedEncoding)
            sourceEncoding = detectedEncoding
            originalTextAtEditStart = source
            editorView.text = source
            updateEditedState(false)
            editorView.refreshKeywordHighlightingNow()
            editorView.focus()
        } catch {
            presentError("Could not reload this Markdown file.", error: error)
            editorView.focus()
        }
    }

    private func handleEditedTextChanged(_ text: String) {
        updateEditedState(text != originalTextAtEditStart)

        if isSearchActive {
            refreshActiveSearchResults()
        }
    }

    private func refreshActiveSearchResults() {
        guard isSearchActive else { return }

        activeSearchTarget.updateSearchQuery(searchBarView.currentQuery) { [weak self] state in
            self?.applySearchResultState(state)
        }
    }

    private func replaceCurrentSearchMatch() {
        guard documentMode == .editing else {
            return
        }

        let state = editorView.replaceCurrentSearchMatch(
            query: searchBarView.currentQuery,
            replacement: searchBarView.currentReplacement
        )
        applySearchResultState(state)
    }

    private func replaceAllSearchMatches() {
        guard documentMode == .editing else {
            return
        }

        let state = editorView.replaceAllSearchMatches(
            query: searchBarView.currentQuery,
            replacement: searchBarView.currentReplacement
        )
        applySearchResultState(state)
    }

    private func applySearchResultState(_ state: SearchResultState) {
        searchBarView.updateMatchCount(state.count, activeIndex: state.activeIndex)
        updateReplaceButtonAvailability()
    }

    private func updateReplaceButtonAvailability() {
        let showsReplaceActions = documentMode == .editing && searchBarView.mode == .findAndReplace
        let canReplaceCurrent = showsReplaceActions &&
            editorView.canReplaceCurrentSearchMatch(query: searchBarView.currentQuery)
        let canReplaceAll = showsReplaceActions &&
            editorView.hasCaseSensitiveReplacementMatch(query: searchBarView.currentQuery)
        searchBarView.setReplaceActionsEnabled(replace: canReplaceCurrent, replaceAll: canReplaceAll)
    }

    private func loadCurrentDocument() {
        guard documentMode == .preview else {
            return
        }

        if !searchBarView.isHidden {
            searchBarView.hideAndClear()
            renderView.clearSearchHighlightsPreservingScroll()
        }

        let resolved = ThemeManager.shared.resolvedThemePalette()
        applyWindowTheme(resolved)
        let settings = MiniMDSettingsManager.shared.settings()
        let renderHighlightConfiguration = settings.renderSyntaxHighlightingEnabled
            ? HighlightConfigurationStore.shared.configuration().themeConfiguration(for: resolved.theme)
            : nil
        let fileURL = self.fileURL
        let renderer = self.renderer
        let options = MarkdownRenderer.RenderOptions(
            themePalette: resolved.palette,
            renderHighlightConfiguration: renderHighlightConfiguration
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try renderer.render(fileURL: fileURL, theme: resolved.theme, options: options) }

            DispatchQueue.main.async {
                switch result {
                case .success(let html):
                    self.renderView.loadHTML(html, baseURL: fileURL.deletingLastPathComponent())
                case .failure(let error):
                    self.renderView.loadError(error, fileURL: fileURL, resolved: resolved)
                }
            }
        }
    }

    private func applyWindowTheme(_ resolved: MiniMDResolvedTheme) {
        window?.appearance = MiniMDWindowTheme.windowAppearance(for: resolved.theme)
        container.applyThemeBackground(resolved.palette)
        loadingBackdropView.applyTheme(resolved.palette)
        renderView.prepareForTheme(resolved)
        titlebarView?.applyTheme(resolved)
        fallbackEditedIndicatorView?.applyTheme(resolved)
    }

    private func applyEditingTheme(_ resolved: MiniMDResolvedTheme) {
        window?.appearance = MiniMDWindowTheme.windowAppearance(for: resolved.theme)
        container.applyThemeBackground(resolved.palette)
        titlebarView?.applyTheme(resolved)
        fallbackEditedIndicatorView?.applyTheme(resolved)
        editorView.applyTheme(resolved)
        editorView.refreshKeywordHighlightingNow()
    }

    private func updateEditedState(_ edited: Bool) {
        isDirty = edited
        window?.isDocumentEdited = edited
        titlebarView?.setEdited(edited)
        fallbackEditedIndicatorView?.setEdited(edited)
        updateDocumentTitle()
    }

    private func updateDocumentTitle() {
        let subtitle: String?
        switch documentMode {
        case .preview:
            subtitle = nil
        case .editing:
            subtitle = isDirty ? "Edited" : "Editing"
        }

        if let subtitle {
            window?.title = "\(fileURL.lastPathComponent) - \(subtitle)"
        } else {
            window?.title = fileURL.lastPathComponent
        }
        titlebarView?.updateSubtitle(subtitle)
        stabilizeIntegratedTitlebarControls()
    }

    private func confirmUnsavedEditsForPreview() -> UnsavedEditChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before previewing?"
        alert.informativeText = "This Markdown file has unsaved edits."
        alert.addButton(withTitle: "Save and Preview")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func confirmUnsavedEditsForClose() -> UnsavedEditChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "This Markdown file has unsaved edits."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func presentError(_ message: String, error: Error? = nil, detail: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let detail {
            alert.informativeText = detail
        } else if let error {
            alert.informativeText = error.localizedDescription
        }

        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func layoutIntegratedTitlebarControls() {
        guard titlebarView != nil,
              let window,
              let closeButton = window.standardWindowButton(.closeButton),
              let miniaturizeButton = window.standardWindowButton(.miniaturizeButton),
              let zoomButton = window.standardWindowButton(.zoomButton),
              let buttonSuperview = closeButton.superview else {
            return
        }

        let buttonTopInset = DocumentTitlebarView.trafficLightTopInset(usesNativeTabs: usesNativeTabs)
        let buttonLeftInset = buttonTopInset
        let buttonSpacing: CGFloat = 22
        let y = buttonSuperview.bounds.height - buttonTopInset - closeButton.frame.height

        for (index, button) in [closeButton, miniaturizeButton, zoomButton].enumerated() {
            button.setFrameOrigin(NSPoint(
                x: buttonLeftInset + CGFloat(index) * buttonSpacing,
                y: y
            ))
        }
    }

    private func stabilizeIntegratedTitlebarControls() {
        layoutIntegratedTitlebarControls()
        DispatchQueue.main.async { [weak self] in
            self?.layoutIntegratedTitlebarControls()
        }
    }

    private func observeHighlightConfigurationChanges() {
        highlightConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .miniMDHighlightConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.documentMode == .preview,
                      MiniMDSettingsManager.shared.settings().renderSyntaxHighlightingEnabled else {
                    return
                }

                self.loadCurrentDocument()
            }
        }
    }
}
