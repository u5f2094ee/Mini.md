import Cocoa
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL
        let resourceBundle = Bundle(for: PreviewProvider.self)
        let baseTag = "<base href=\"\(MarkdownRenderer.escapeAttribute(fileURL.deletingLastPathComponent().absoluteString))\">"

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 1000, height: 720)) { replyToUpdate in
            let attachmentStore = QuickLookAttachmentStore()
            let renderer = MarkdownRenderer()
            let theme = Self.resolvedPreviewTheme()
            let palette = MiniMDThemePalette.default(for: theme)
            let options = MarkdownRenderer.RenderOptions(
                resourceBundle: resourceBundle,
                headExtras: baseTag,
                imageSourceResolver: { rawSource, sourceFileURL in
                    attachmentStore.previewSource(for: rawSource, sourceFileURL: sourceFileURL)
                },
                themePalette: palette
            )

            let html: String
            do {
                html = try renderer.render(fileURL: fileURL, theme: theme, options: options)
            } catch {
                html = Self.errorHTML(for: fileURL, error: error, theme: theme, palette: palette, baseTag: baseTag)
            }

            replyToUpdate.stringEncoding = .utf8
            replyToUpdate.attachments = attachmentStore.attachments
            replyToUpdate.title = fileURL.lastPathComponent
            return Data(html.utf8)
        }

        reply.stringEncoding = .utf8
        reply.title = fileURL.lastPathComponent
        return reply
    }

    private static func resolvedPreviewTheme() -> DocumentTheme {
        let defaults = UserDefaults.standard
        let appDomainPreference = defaults.persistentDomain(forName: ThemeStorage.appDefaultsDomain)?[ThemeStorage.preferenceKey] as? String
        let rawPreference = appDomainPreference ?? defaults.string(forKey: ThemeStorage.preferenceKey)

        if let rawValue = rawPreference,
           let preference = ThemePreference(rawValue: rawValue) {
            switch preference {
            case .light:
                return .light
            case .dark:
                return .dark
            case .system:
                break
            }
        }

        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua ? .dark : .light
    }

    private static func errorHTML(
        for fileURL: URL,
        error: Error,
        theme: DocumentTheme,
        palette: MiniMDThemePalette,
        baseTag: String
    ) -> String {
        let safeTitle = MarkdownRenderer.escapeHTML(fileURL.lastPathComponent)
        let safeError = MarkdownRenderer.escapeHTML(error.localizedDescription)
        let css = MarkdownRenderer.errorPageCSS(theme: theme, palette: palette)

        return """
        <!doctype html>
        <html data-theme="\(theme.rawValue)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(safeTitle)</title>
        \(baseTag)
        <style>\(css)</style>
        </head>
        <body>
        <main id="markdown-body">
        <h1>\(safeTitle)</h1>
        <p class="render-error">Could not render this Markdown file in Quick Look.</p>
        <pre><code>\(safeError)</code></pre>
        </main>
        </body>
        </html>
        """
    }
}

private final class QuickLookAttachmentStore {
    private(set) var attachments: [String: QLPreviewReplyAttachment] = [:]

    func previewSource(for rawSource: String, sourceFileURL: URL) -> String {
        let trimmedSource = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty,
              shouldAttach(trimmedSource),
              let fileURL = resolvedFileURL(from: trimmedSource, sourceFileURL: sourceFileURL),
              let data = try? Data(contentsOf: fileURL) else {
            return rawSource
        }

        let contentType = UTType(filenameExtension: fileURL.pathExtension) ?? .data
        let identifier = "image-\(attachments.count)"
        attachments[identifier] = QLPreviewReplyAttachment(data: data, contentType: contentType)
        return "cid:\(identifier)"
    }

    private func shouldAttach(_ source: String) -> Bool {
        if source.hasPrefix("#") {
            return false
        }

        guard let scheme = URL(string: source)?.scheme?.lowercased() else {
            return true
        }

        return scheme == "file"
    }

    private func resolvedFileURL(from source: String, sourceFileURL: URL) -> URL? {
        let sourceWithoutFragment = String(source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let decodedSource = sourceWithoutFragment.removingPercentEncoding ?? sourceWithoutFragment

        if let url = URL(string: decodedSource), url.isFileURL {
            return url
        }

        if decodedSource.hasPrefix("/") {
            return URL(fileURLWithPath: decodedSource)
        }

        return sourceFileURL.deletingLastPathComponent().appendingPathComponent(decodedSource)
    }
}
