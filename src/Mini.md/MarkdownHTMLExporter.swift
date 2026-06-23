import AppKit
import Foundation

final class MarkdownHTMLExporter: @unchecked Sendable {
    private let renderer: MarkdownRenderer
    private let resourceBundle: Bundle

    init(renderer: MarkdownRenderer = MarkdownRenderer(), resourceBundle: Bundle = .main) {
        self.renderer = renderer
        self.resourceBundle = resourceBundle
    }

    @discardableResult
    func export(
        fileURL: URL,
        markdownSource: String?,
        settings: MiniMDHTMLExportSettings
    ) throws -> URL {
        let targetURL = fileURL.deletingPathExtension().appendingPathExtension("html")
        let html = try exportHTML(fileURL: fileURL, markdownSource: markdownSource, settings: settings)
        try html.write(to: targetURL, atomically: true, encoding: .utf8)
        return targetURL
    }

    private func exportHTML(
        fileURL: URL,
        markdownSource: String?,
        settings: MiniMDHTMLExportSettings
    ) throws -> String {
        let palette = MiniMDThemePalette(foregroundHex: "#1F2933", backgroundHex: "#F4F6F8")
        let options = MarkdownRenderer.RenderOptions(resourceBundle: resourceBundle, themePalette: palette)
        let html: String
        if let markdownSource {
            html = renderer.render(markdown: markdownSource, fileURL: fileURL, theme: .light, options: options)
        } else {
            html = try renderer.render(fileURL: fileURL, theme: .light, options: options)
        }

        return prepareStandaloneHTML(html, settings: settings)
    }

    private func prepareStandaloneHTML(_ html: String, settings: MiniMDHTMLExportSettings) -> String {
        let withLanguage = html.replacingOccurrences(
            of: "<html data-theme=\"light\">",
            with: "<html lang=\"zh-CN\" data-theme=\"light\">"
        )

        return insertExportCSS(into: withLanguage, settings: settings)
    }

    private func insertExportCSS(into html: String, settings: MiniMDHTMLExportSettings) -> String {
        let zoom = settings.defaultZoom
        let bodyFontSizePX = cssNumber(16 * zoom)
        let mobileFontSizePX = cssNumber(15 * zoom)
        let h1FontSizePX = cssNumber(32 * zoom)
        let h1SecondaryFontSizePX = cssNumber(24.8 * zoom)
        let h2FontSizePX = cssNumber(22.72 * zoom)
        let h3FontSizePX = cssNumber(18.88 * zoom)
        let hSmallFontSizePX = cssNumber(16.8 * zoom)
        let tableFontSizePX = cssNumber(15.04 * zoom)
        let tableCellPaddingVerticalPX = cssNumber(8 * zoom)
        let tableCellPaddingHorizontalPX = cssNumber(10 * zoom)
        let preCodeFontSizePX = cssNumber(15.2 * zoom)
        let printFontSizePT = cssNumber(11 * zoom)
        let printH1FontSizePT = cssNumber(18 * zoom)
        let printH1SecondaryFontSizePT = cssNumber(15 * zoom)
        let printH2FontSizePT = cssNumber(13.5 * zoom)
        let printTableFontSizePT = cssNumber(9 * zoom)
        let printTableCellPaddingVerticalPX = cssNumber(5 * zoom)
        let printTableCellPaddingHorizontalPX = cssNumber(6 * zoom)
        let contentWidthPX = cssNumber(settings.contentWidthPX)
        let mermaidMaxWidthPX = cssNumber(min(max(settings.contentWidthPX - 180, 680), 860))
        let mermaidFontSizePX = cssNumber(min(max(13 * zoom, 12), 14))
        let mermaidEdgeFontSizePX = cssNumber(min(max(12.2 * zoom, 11.5), 13))
        let printMarginMM = cssNumber(settings.printMarginMM)
        let style = """
        <style id="mini-md-html-export">
        :root {
          color-scheme: light;
          --mini-md-window-top-inset: 0px;
          --mini-md-export-bg: #ffffff;
          --mini-md-export-paper: #ffffff;
          --mini-md-export-text: #1f2933;
          --mini-md-export-muted: #52606d;
          --mini-md-export-border: #d9e2ec;
          --mini-md-export-border-strong: #bcccdc;
          --mini-md-export-head-bg: #f0f4f8;
          --mini-md-export-code-bg: #f7f9fb;
          --mini-md-export-accent: #243b53;
        }
        html,
        body {
          margin: 0 !important;
          min-height: 100% !important;
          background: var(--mini-md-export-bg) !important;
          color: var(--mini-md-export-text) !important;
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", "Helvetica Neue", Arial, sans-serif !important;
          font-size: \(bodyFontSizePX)px !important;
          line-height: 1.68 !important;
          -webkit-font-smoothing: antialiased;
          text-rendering: optimizeLegibility;
        }
        #markdown-body {
          box-sizing: border-box !important;
          max-width: \(contentWidthPX)px !important;
          min-height: auto !important;
          margin: 36px auto !important;
          padding: 42px 54px !important;
          overflow-wrap: break-word !important;
          background: var(--mini-md-export-paper) !important;
          color: var(--mini-md-export-text) !important;
          border: none !important;
          border-radius: 0 !important;
          box-shadow: none !important;
          font-size: \(bodyFontSizePX)px !important;
        }
        #markdown-body h1,
        #markdown-body h2,
        #markdown-body h3,
        #markdown-body h4,
        #markdown-body h5,
        #markdown-body h6 {
          color: var(--mini-md-export-accent) !important;
          line-height: 1.32 !important;
        }
        #markdown-body h1 {
          font-size: \(h1FontSizePX)px !important;
          margin: 0 0 0.35em !important;
          padding-bottom: 0.35em !important;
          border-bottom: 2px solid var(--mini-md-export-border-strong) !important;
        }
        #markdown-body h1 + h1 {
          margin-top: 0.15em !important;
          font-size: \(h1SecondaryFontSizePX)px !important;
          border-bottom: none !important;
          padding-bottom: 0 !important;
          color: #334e68 !important;
        }
        #markdown-body h2 {
          font-size: \(h2FontSizePX)px !important;
          margin: 2.1em 0 0.75em !important;
          padding-top: 0.25em !important;
          padding-bottom: 0 !important;
          border-top: 1px solid var(--mini-md-export-border) !important;
          border-bottom: none !important;
        }
        #markdown-body h3 {
          font-size: \(h3FontSizePX)px !important;
          margin: 1.55em 0 0.55em !important;
        }
        #markdown-body h4,
        #markdown-body h5,
        #markdown-body h6 {
          font-size: \(hSmallFontSizePX)px !important;
          margin: 1.25em 0 0.45em !important;
        }
        #markdown-body p {
          margin: 0.72em 0 !important;
        }
        #markdown-body hr {
          border: none !important;
          border-top: 1px solid var(--mini-md-export-border) !important;
          background: transparent !important;
          margin: 1.5em 0 !important;
        }
        #markdown-body table {
          width: 100% !important;
          border-collapse: collapse !important;
          margin: 1em 0 1.35em !important;
          font-size: \(tableFontSizePX)px !important;
          table-layout: auto !important;
        }
        #markdown-body th,
        #markdown-body td {
          border: 1px solid var(--mini-md-export-border-strong) !important;
          padding: \(tableCellPaddingVerticalPX)px \(tableCellPaddingHorizontalPX)px !important;
          font-size: inherit !important;
          line-height: 1.45 !important;
          vertical-align: top !important;
          text-align: left;
        }
        #markdown-body th {
          background: var(--mini-md-export-head-bg) !important;
          font-weight: 700 !important;
          color: #243b53 !important;
        }
        #markdown-body tbody tr:nth-child(even) td {
          background: #fbfdff !important;
        }
        #markdown-body code {
          font-size: 0.92em !important;
          background: var(--mini-md-export-code-bg) !important;
          border: 1px solid #e6eef5 !important;
          border-radius: 4px !important;
          padding: 0.08em 0.32em !important;
        }
        #markdown-body pre {
          margin: 1em 0 1.25em !important;
          padding: 14px 16px !important;
          overflow-x: auto !important;
          white-space: pre-wrap !important;
          word-break: break-word !important;
          background: var(--mini-md-export-code-bg) !important;
          border: 1px solid var(--mini-md-export-border) !important;
          border-radius: 10px !important;
          box-shadow: none !important;
        }
        #markdown-body pre code {
          padding: 0 !important;
          border: none !important;
          background: transparent !important;
          font-size: \(preCodeFontSizePX)px !important;
          white-space: pre-wrap !important;
        }
        #markdown-body blockquote {
          margin: 1em 0 !important;
          padding: 0.2em 1em !important;
          color: var(--mini-md-export-muted) !important;
          border-left: 4px solid var(--mini-md-export-border-strong) !important;
          background: #f8fafc !important;
        }
        #markdown-body ul,
        #markdown-body ol {
          margin: 0.7em 0 0.9em 1.35em !important;
          padding-left: 1.1em !important;
        }
        #markdown-body li + li {
          margin-top: 0.28em !important;
        }
        #markdown-body a {
          color: #0967d2 !important;
          text-decoration: none !important;
          overflow-wrap: anywhere !important;
        }
        #markdown-body a:hover {
          text-decoration: underline !important;
        }
        #markdown-body .table-wrap {
          overflow-x: auto !important;
        }
        #markdown-body img {
          max-width: 100% !important;
          height: auto !important;
        }
        #markdown-body .mermaid {
          display: block !important;
          margin: 1.2em auto 1.4em !important;
          padding: 12px 0 !important;
          overflow: visible !important;
          text-align: center !important;
          white-space: normal !important;
          line-height: 1.22 !important;
          background: #ffffff !important;
          border: 1px solid var(--mini-md-export-border) !important;
          border-radius: 8px !important;
        }
        #markdown-body .mermaid * {
          line-height: 1.22 !important;
        }
        #markdown-body .mermaid svg {
          display: block !important;
          width: auto !important;
          max-width: min(100%, \(mermaidMaxWidthPX)px) !important;
          height: auto !important;
          margin: 0 auto !important;
          overflow: visible !important;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", Arial, sans-serif !important;
          font-size: \(mermaidFontSizePX)px !important;
        }
        #markdown-body .mermaid svg foreignObject,
        #markdown-body .mermaid svg .label,
        #markdown-body .mermaid svg .nodeLabel,
        #markdown-body .mermaid svg .edgeLabel {
          overflow: visible !important;
        }
        #markdown-body .mermaid svg .nodeLabel,
        #markdown-body .mermaid svg .nodeLabel p,
        #markdown-body .mermaid svg .label,
        #markdown-body .mermaid svg .label p {
          white-space: normal !important;
          word-break: keep-all !important;
          overflow-wrap: normal !important;
          font-size: \(mermaidFontSizePX)px !important;
        }
        #markdown-body .mermaid svg .edgeLabel,
        #markdown-body .mermaid svg .edgeLabel p {
          font-size: \(mermaidEdgeFontSizePX)px !important;
          white-space: nowrap !important;
        }
        #markdown-body .mermaid-error {
          color: #9b1c1c !important;
          text-align: left !important;
          background: #fff5f5 !important;
          border-color: #f5c2c7 !important;
        }
        #markdown-body .mermaid-error pre {
          white-space: pre-wrap !important;
          margin: 0.7em 0 0 !important;
        }
        @media (max-width: 760px) {
          body {
            background: var(--mini-md-export-paper) !important;
            font-size: \(mobileFontSizePX)px !important;
          }
          #markdown-body {
            margin: 0 !important;
            padding: 26px 20px !important;
            border: none !important;
            border-radius: 0 !important;
            box-shadow: none !important;
          }
          #markdown-body h1 {
            font-size: \(cssNumber(26.4 * zoom))px !important;
          }
          #markdown-body h1 + h1 {
            font-size: \(cssNumber(21.12 * zoom))px !important;
          }
          #markdown-body table {
            font-size: \(cssNumber(13.2 * zoom))px !important;
          }
          #markdown-body .table-wrap {
            display: block !important;
            overflow-x: auto !important;
            white-space: nowrap !important;
          }
        }
        @media print {
          @page {
            size: A4;
            margin: \(printMarginMM)mm;
          }
          body {
            background: #ffffff !important;
            color: #000000 !important;
            font-size: \(printFontSizePT)pt !important;
            line-height: 1.48 !important;
          }
          #markdown-body {
            width: auto !important;
            max-width: none !important;
            margin: 0 !important;
            padding: 0 !important;
            border: none !important;
            border-radius: 0 !important;
            box-shadow: none !important;
          }
          #markdown-body h1 {
            font-size: \(printH1FontSizePT)pt !important;
          }
          #markdown-body h1 + h1 {
            font-size: \(printH1SecondaryFontSizePT)pt !important;
          }
          #markdown-body h2 {
            font-size: \(printH2FontSizePT)pt !important;
            page-break-after: avoid;
          }
          #markdown-body h3,
          #markdown-body h4,
          #markdown-body h5,
          #markdown-body h6 {
            page-break-after: avoid;
          }
          #markdown-body table,
          #markdown-body pre,
          #markdown-body blockquote {
            page-break-inside: avoid;
          }
          #markdown-body table {
            font-size: \(printTableFontSizePT)pt !important;
          }
          #markdown-body th,
          #markdown-body td {
            padding: \(printTableCellPaddingVerticalPX)px \(printTableCellPaddingHorizontalPX)px !important;
          }
          #markdown-body a {
            color: #000000 !important;
            text-decoration: none !important;
          }
        }
        </style>
        """

        guard let headRange = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) else {
            return html + "\n" + style
        }

        var result = html
        result.insert(contentsOf: style + "\n", at: headRange.lowerBound)
        return result
    }

    private func cssNumber(_ value: CGFloat) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
