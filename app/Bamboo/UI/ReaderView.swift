import SwiftUI
import WebKit

/// Reader: the page's article (found by Mozilla's Readability in an isolated
/// script world) set in a clean column, with font, size and theme controls.
struct ReaderView: View {
    let tab: Tab
    @State private var phase = Phase.loading
    @Environment(\.colorScheme) private var colorScheme

    enum Phase {
        case loading
        case ready(ReaderArticle)
        case unavailable
    }

    var body: some View {
        let settings = AppServices.shared.settings
        let theme = ReaderStyle.resolvedTheme(settings.readerTheme, colorScheme: colorScheme)
        let style = ReaderStyle(font: settings.readerFont, size: settings.readerFontSize, theme: theme)
        ZStack(alignment: .top) {
            Color(nsColor: style.background)
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                VStack(spacing: 10) {
                    Text("Reader isn't available for this page")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Bamboo couldn't find an article here.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Button("Back to Page") { tab.isReaderActive = false }
                        .keyboardShortcut(.defaultAction)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let article):
                ReaderWebView(article: article, style: style, tab: tab)
            }
            ReaderControls(tab: tab)
                .padding(.top, 12)
        }
        .environment(\.colorScheme, theme == .dark ? .dark : .light)
        .task(id: tab.url) { await extract() }
        .onExitCommand { tab.isReaderActive = false }
    }

    private func extract() async {
        guard let webView = tab.webView else {
            phase = .unavailable
            return
        }
        do {
            phase = try await ReaderArticle.extract(from: webView).map(Phase.ready) ?? .unavailable
        } catch is WKError {
            // The page changed or its process ended while Readability ran.
            phase = .unavailable
        } catch {
            AppServices.shared.reportNonFatal(error, "Extracting a Reader article")
            phase = .unavailable
        }
    }
}

private struct ReaderControls: View {
    let tab: Tab

    var body: some View {
        @Bindable var settings = AppServices.shared.settings
        HStack(spacing: 4) {
            Picker("Font", selection: $settings.readerFont) {
                Text("Serif").font(.custom("New York", size: 13)).tag(ReaderFont.serif)
                Text("Sans").tag(ReaderFont.sans)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { settings.readerFontSize = max(settings.readerFontSize - 1, ReaderStyle.sizes.lowerBound) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(settings.readerFontSize <= ReaderStyle.sizes.lowerBound)
            .help("Smaller Text")
            Button { settings.readerFontSize = min(settings.readerFontSize + 1, ReaderStyle.sizes.upperBound) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(settings.readerFontSize >= ReaderStyle.sizes.upperBound)
            .help("Larger Text")

            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
                Button { settings.readerTheme = theme } label: {
                    ThemeSwatch(theme: theme, isSelected: settings.readerTheme == theme)
                }
                .help(theme == .system ? "Match Appearance" : theme.rawValue.capitalized)
                .accessibilityLabel(theme == .system ? "Match appearance" : theme.rawValue.capitalized)
            }

            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { tab.isReaderActive = false } label: { Image(systemName: "xmark") }
                .help("Close Reader (⌥⌘R)")
        }
        .buttonStyle(.chrome(size: 26))
        .padding(.horizontal, 8)
        .frame(height: 40)
        .floatingSurface(cornerRadius: 20)
    }
}

private struct ThemeSwatch: View {
    let theme: ReaderTheme
    let isSelected: Bool
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        ZStack {
            if theme == .system {
                Circle().fill(Color(nsColor: ReaderStyle.background(.light)))
                Circle().trim(from: 0.25, to: 0.75).fill(Color(nsColor: ReaderStyle.background(.dark)))
            } else {
                Circle().fill(Color(nsColor: ReaderStyle.background(theme)))
            }
            Circle().strokeBorder(isSelected ? accent : Theme.Colors.hairline, lineWidth: isSelected ? 2 : 1)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Article

struct ReaderArticle {
    let title: String
    let byline: String
    let siteName: String
    let contentHTML: String
    let wordCount: Int

    /// Articles shorter than this are usually a page Readability misread.
    private static let minimumWords = 80
    @MainActor private static let world = WKContentWorld.world(name: "BambooReader")
    private static let readabilitySource: String = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else {
            fatalError("Readability.js is missing from the app bundle")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Cannot read Readability.js: \(error)")
        }
    }()
    private static let parseScript = """
        const article = new Readability(document.cloneNode(true)).parse();
        if (!article) return null;
        return {
            title: article.title || "",
            byline: article.byline || "",
            siteName: article.siteName || "",
            content: article.content || "",
            words: (article.textContent || "").trim().split(/\\s+/).length,
        };
        """

    /// Runs Readability on a copy of the page. Nil when there is no article.
    @MainActor
    static func extract(from webView: WKWebView) async throws -> ReaderArticle? {
        let script = readabilitySource + "\n" + parseScript
        guard let result = try await webView.callAsyncJavaScript(script, contentWorld: world) as? [String: Any],
              let content = result["content"] as? String,
              let words = result["words"] as? Int, words >= minimumWords
        else { return nil }
        return ReaderArticle(
            title: result["title"] as? String ?? "",
            byline: result["byline"] as? String ?? "",
            siteName: result["siteName"] as? String ?? "",
            contentHTML: content,
            wordCount: words)
    }
}

// MARK: - Rendering

struct ReaderStyle: Equatable {
    var font: ReaderFont
    var size: Int
    /// Never `.system`; resolved against the appearance first.
    var theme: ReaderTheme

    static let sizes = 14...30

    static func resolvedTheme(_ theme: ReaderTheme, colorScheme: ColorScheme) -> ReaderTheme {
        theme == .system ? (colorScheme == .dark ? .dark : .light) : theme
    }

    var background: NSColor { Self.background(theme) }

    static func background(_ theme: ReaderTheme) -> NSColor {
        switch theme {
        case .system, .light: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.98, alpha: 1)
        case .sepia: NSColor(srgbRed: 0.957, green: 0.925, blue: 0.847, alpha: 1)
        case .dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)
        }
    }

    /// Applies this style to a loaded reader page without reloading it.
    var applyScript: String {
        "document.documentElement.dataset.font = '\(font.rawValue)';"
            + "document.documentElement.dataset.theme = '\(theme.rawValue)';"
            + "document.documentElement.style.fontSize = '\(size)px';"
    }
}

/// A JavaScript-free web view showing the article with Bamboo's typography.
/// Links open in the tab and leave Reader.
private struct ReaderWebView: NSViewRepresentable {
    let article: ReaderArticle
    let style: ReaderStyle
    let tab: Tab

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = style.background
        webView.loadHTMLString(ReaderDocument.html(article, style: style), baseURL: nil)
        context.coordinator.appliedStyle = style
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.appliedStyle != style else { return }
        context.coordinator.appliedStyle = style
        webView.underPageBackgroundColor = style.background
        webView.evaluateJavaScript(style.applyScript, completionHandler: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let tab: Tab
        var appliedStyle: ReaderStyle?

        init(tab: Tab) {
            self.tab = tab
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                // Only the article itself (loaded from a string) may load here.
                return navigationAction.request.url?.scheme == "about" ? .allow : .cancel
            }
            tab.isReaderActive = false
            tab.load(url)
            return .cancel
        }
    }
}

private enum ReaderDocument {
    static func html(_ article: ReaderArticle, style: ReaderStyle) -> String {
        let minutes = max(1, Int((Double(article.wordCount) / 230).rounded()))
        let meta = [article.byline, "\(minutes) min read"].filter { !$0.isEmpty }
            .map { "<span>\(escape($0))</span>" }.joined()
        let site = article.siteName.isEmpty ? "" : "<div class=\"site\">\(escape(article.siteName))</div>"
        return """
            <!doctype html>
            <html data-font="\(style.font.rawValue)" data-theme="\(style.theme.rawValue)" style="font-size: \(style.size)px">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; media-src https: http:; style-src 'unsafe-inline'">
            <style>\(css)</style>
            </head>
            <body>
            <header>\(site)<h1 class="title">\(escape(article.title))</h1><div class="meta">\(meta)</div></header>
            <article>\(article.contentHTML)</article>
            </body>
            </html>
            """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
        :root { --bg: #fcfcfa; --text: #1d1d1f; --muted: #6e6e73; --link: #1f7a4f; --rule: rgba(0,0,0,.1); }
        html[data-theme=sepia] { --bg: #f4ecd8; --text: #3b2f20; --muted: #7d6b55; --link: #8a5a1c; --rule: rgba(59,47,32,.16); }
        html[data-theme=dark] { --bg: #1c1c1e; --text: #e6e6e8; --muted: #98989d; --link: #72d39f; --rule: rgba(255,255,255,.12); }
        html { background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; transition: background .25s, color .25s; }
        body { max-width: 34em; margin: 0 auto; padding: 96px 36px 140px; }
        html[data-font=serif] body { font-family: "New York", ui-serif, Georgia, serif; line-height: 1.68; }
        html[data-font=sans] body { font-family: system-ui, -apple-system, sans-serif; line-height: 1.58; }
        header { margin-bottom: 2.2em; padding-bottom: 1.5em; border-bottom: 1px solid var(--rule); }
        .site { font: 600 .74rem system-ui, sans-serif; color: var(--muted); }
        h1.title { font-size: 2.1em; line-height: 1.14; letter-spacing: -.012em; margin: .3em 0 .35em; font-weight: 700; }
        .meta { font: .8rem system-ui, sans-serif; color: var(--muted); }
        .meta span + span { margin-left: 1.4em; }
        article { font-size: 1em; }
        article p { margin: 0 0 1.05em; }
        h2, h3, h4 { line-height: 1.25; margin: 1.8em 0 .6em; }
        img, video, picture { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin: 1.8em 0; }
        figcaption { font: .78rem/1.45 system-ui, sans-serif; color: var(--muted); margin-top: .6em; }
        a { color: var(--link); text-decoration: none; border-bottom: 1px solid color-mix(in srgb, var(--link) 35%, transparent); }
        blockquote { margin: 1.5em 0; padding-left: 1.1em; border-left: 3px solid var(--rule); color: var(--muted); }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: .84em; }
        pre { overflow-x: auto; padding: 1em 1.1em; border-radius: 8px; background: color-mix(in srgb, var(--text) 6%, transparent); line-height: 1.45; }
        hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
        table { border-collapse: collapse; font-size: .86em; }
        td, th { border: 1px solid var(--rule); padding: .4em .65em; }
        ::selection { background: color-mix(in srgb, var(--link) 28%, transparent); }
        """
}
