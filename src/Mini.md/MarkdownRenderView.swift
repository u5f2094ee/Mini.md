import AppKit
import WebKit

final class MarkdownRenderView: NSView, WKNavigationDelegate {
    private static let savedContentZoomKey = "MiniMD.ContentZoom"
    private static let savedContentZoomDefaultRenderZoomKey = "MiniMD.ContentZoomDefaultRenderZoom"
    private static let savedContentZoomSettingsVersionKey = "MiniMD.ContentZoomSettingsVersion"
    private static let documentRevealDelay: TimeInterval = 0.04

    private enum ContentZoom {
        static let defaultValue: CGFloat = 1.0
        static let minimum: CGFloat = 0.5
        static let maximum: CGFloat = 3.0
        static let step: CGFloat = 0.1
    }

    private let webView: WKWebView
    private var contentZoom = ContentZoom.defaultValue
    private var topContentInset: CGFloat = 0
    private var hasLoadedDocument = false
    private var preparedPlaceholderTheme: DocumentTheme?
    private var preparedPlaceholderPalette: MiniMDThemePalette?
    private var pendingDocumentLoad = false

    var onDocumentDidFinishLoad: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        contentZoom = Self.restoredContentZoom()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func loadHTML(_ html: String, baseURL: URL) {
        hasLoadedDocument = true
        pendingDocumentLoad = true
        webView.loadHTMLString(htmlWithTopContentInset(html), baseURL: baseURL)
    }

    func setTopContentInset(_ inset: CGFloat) {
        topContentInset = max(0, inset)
    }

    func prepareForTheme(_ resolved: MiniMDResolvedTheme) {
        let backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: resolved.palette)
        layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.underPageBackgroundColor = backgroundColor

        guard !hasLoadedDocument,
              preparedPlaceholderTheme != resolved.theme || preparedPlaceholderPalette != resolved.palette else {
            return
        }

        preparedPlaceholderTheme = resolved.theme
        preparedPlaceholderPalette = resolved.palette
        webView.loadHTMLString(
            Self.blankDocumentHTML(theme: resolved.theme, palette: resolved.palette, insetCSS: topContentInsetCSS()),
            baseURL: nil
        )
    }

    func loadError(_ error: Error, fileURL: URL, resolved: MiniMDResolvedTheme) {
        hasLoadedDocument = true
        pendingDocumentLoad = true
        let safeFileName = MarkdownRenderer.escapeHTML(fileURL.lastPathComponent)
        let safeError = MarkdownRenderer.escapeHTML(error.localizedDescription)
        let css = MarkdownRenderer.errorPageCSS(theme: resolved.theme, palette: resolved.palette) + "\n" + topContentInsetCSS()
        let html = """
        <!doctype html>
        <html data-theme="\(resolved.theme.rawValue)">
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        <main id="markdown-body">
        <h1>\(safeFileName)</h1>
        <p class="render-error">Could not render this Markdown file.</p>
        <pre><code>\(safeError)</code></pre>
        </main>
        </body>
        </html>
        """

        webView.loadHTMLString(htmlWithSearchSupport(html), baseURL: fileURL.deletingLastPathComponent())
    }

    func focus() {
        window?.makeFirstResponder(webView)
    }

    func selectAll() {
        focus()
        let selector = #selector(NSText.selectAll(_:))
        if webView.responds(to: selector) {
            webView.perform(selector, with: nil)
        }

        webView.evaluateJavaScript("""
        const body = document.getElementById('markdown-body') || document.body;
        const range = document.createRange();
        range.selectNodeContents(body);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        """, completionHandler: nil)
    }

    func copySelection() {
        focus()
        let selector = #selector(NSText.copy(_:))
        if webView.responds(to: selector) {
            webView.perform(selector, with: nil)
        } else {
            NSApp.sendAction(selector, to: nil, from: self)
        }

        webView.evaluateJavaScript("document.execCommand('copy');", completionHandler: nil)
    }

    func printDocument(named jobTitle: String) {
        focus()

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true

        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func updateSearchQuery(_ query: String, completion: ((Int, Int?) -> Void)? = nil) {
        let queryLiteral = Self.javascriptStringLiteral(query)
        webView.evaluateJavaScript("window.miniMDSearch ? window.miniMDSearch.highlight(\(queryLiteral)) : { count: 0, index: -1 };") { result, _ in
            let parsed = Self.parseSearchResult(result)
            completion?(parsed.count, parsed.activeIndex)
        }
    }

    func activateNextSearchMatch(completion: ((Int, Int?) -> Void)? = nil) {
        webView.evaluateJavaScript("window.miniMDSearch ? window.miniMDSearch.next() : { count: 0, index: -1 };") { result, _ in
            let parsed = Self.parseSearchResult(result)
            completion?(parsed.count, parsed.activeIndex)
        }
    }

    func clearSearchHighlightsPreservingScroll() {
        webView.evaluateJavaScript("window.miniMDSearch && window.miniMDSearch.clear(true);", completionHandler: nil)
    }

    func increaseContentZoom() {
        setContentZoom(contentZoom + ContentZoom.step)
    }

    func decreaseContentZoom() {
        setContentZoom(contentZoom - ContentZoom.step)
    }

    func resetContentZoom() {
        setContentZoom(ContentZoom.defaultValue)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.pageZoom = contentZoom
        completePendingDocumentLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completePendingDocumentLoad()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completePendingDocumentLoad()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "about", url.fragment != nil {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if url.isFileURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    private func setContentZoom(_ value: CGFloat) {
        let clampedValue = min(max(value, ContentZoom.minimum), ContentZoom.maximum)
        let roundedValue = (clampedValue * 100).rounded() / 100
        contentZoom = roundedValue
        webView.pageZoom = roundedValue
        saveContentZoomIfNeeded(roundedValue)
        focus()
    }

    private func completePendingDocumentLoad() {
        guard pendingDocumentLoad else {
            return
        }

        pendingDocumentLoad = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.documentRevealDelay) { [weak self] in
            self?.onDocumentDidFinishLoad?()
        }
    }

    private func configure() {
        wantsLayer = true
        layer?.masksToBounds = true
        let resolved = ThemeManager.shared.resolvedThemePalette()
        let backgroundColor = MiniMDWindowTheme.documentBackgroundColor(for: resolved.palette)

        layer?.backgroundColor = backgroundColor.cgColor
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.underPageBackgroundColor = backgroundColor
        webView.allowsMagnification = true
        webView.pageZoom = contentZoom
        webView.allowsBackForwardNavigationGestures = false
        preparedPlaceholderTheme = resolved.theme
        preparedPlaceholderPalette = resolved.palette
        webView.loadHTMLString(
            Self.blankDocumentHTML(theme: resolved.theme, palette: resolved.palette, insetCSS: ""),
            baseURL: nil
        )

        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func htmlWithTopContentInset(_ html: String) -> String {
        var adjustedHTML = html
        let css = topContentInsetCSS()

        if !css.isEmpty {
            let style = "<style>\(css)</style>"
            if let headCloseRange = adjustedHTML.range(of: "</head>", options: [.caseInsensitive]) {
                adjustedHTML.insert(contentsOf: style, at: headCloseRange.lowerBound)
            } else {
                adjustedHTML = style + adjustedHTML
            }
        }

        return htmlWithSearchSupport(adjustedHTML)
    }

    private func htmlWithSearchSupport(_ html: String) -> String {
        MarkdownSearchSupport.append(to: html)
    }

    private func topContentInsetCSS() -> String {
        guard topContentInset > 0 else { return "" }

        let roundedInset = Int(ceil(topContentInset))
        return """
        :root {
          --mini-md-window-top-inset: \(roundedInset)px;
        }
        """
    }

    private static func parseSearchResult(_ result: Any?) -> (count: Int, activeIndex: Int?) {
        guard let dictionary = result as? [String: Any] else {
            return (0, nil)
        }

        let count = intValue(dictionary["count"]) ?? 0
        let index = intValue(dictionary["index"]) ?? -1
        return (count, index >= 0 ? index : nil)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let arrayLiteral = String(data: data, encoding: .utf8),
              arrayLiteral.count >= 2 else {
            return "\"\""
        }

        return String(arrayLiteral.dropFirst().dropLast())
    }

    private static func blankDocumentHTML(theme: DocumentTheme, palette: MiniMDThemePalette, insetCSS: String) -> String {
        return """
        <!doctype html>
        <html data-theme="\(theme.rawValue)">
        <head>
        <meta charset="utf-8">
        <style>
        :root {
          --mini-md-foreground: \(palette.foregroundHex);
          --mini-md-background: \(palette.backgroundHex);
        }
        html,
        body {
          margin: 0;
          min-height: 100%;
          background: var(--mini-md-background);
          color: var(--mini-md-foreground);
        }
        \(insetCSS)
        </style>
        </head>
        <body></body>
        </html>
        """
    }

    private static func restoredContentZoom() -> CGFloat {
        let settingsManager = MiniMDSettingsManager.shared
        let settings = settingsManager.settings()
        let defaultZoom = settings.defaultRenderZoom
        guard settings.rememberContentZoom else {
            return defaultZoom
        }

        let savedValue = UserDefaults.standard.double(forKey: savedContentZoomKey)
        guard savedValue > 0 else {
            return defaultZoom
        }

        guard let currentSettingsVersion = settingsManager.settingsFileVersionIdentifier(),
              UserDefaults.standard.string(forKey: savedContentZoomSettingsVersionKey) == currentSettingsVersion else {
            return defaultZoom
        }

        let savedDefaultZoom = CGFloat(UserDefaults.standard.double(forKey: savedContentZoomDefaultRenderZoomKey))
        guard savedDefaultZoom > 0,
              abs(savedDefaultZoom - defaultZoom) < 0.005 else {
            return defaultZoom
        }

        let clampedValue = min(max(CGFloat(savedValue), ContentZoom.minimum), ContentZoom.maximum)
        return (clampedValue * 100).rounded() / 100
    }

    private func saveContentZoomIfNeeded(_ value: CGFloat) {
        let settingsManager = MiniMDSettingsManager.shared
        let settings = settingsManager.settings()
        guard settings.rememberContentZoom else {
            return
        }

        UserDefaults.standard.set(Double(value), forKey: Self.savedContentZoomKey)
        UserDefaults.standard.set(Double(settings.defaultRenderZoom), forKey: Self.savedContentZoomDefaultRenderZoomKey)
        if let settingsVersion = settingsManager.settingsFileVersionIdentifier() {
            UserDefaults.standard.set(settingsVersion, forKey: Self.savedContentZoomSettingsVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.savedContentZoomSettingsVersionKey)
        }
    }
}
