import AppKit
import WebKit

/// Finds, fetches and caches site icons. After a page loads, a script in an
/// isolated world lists the page's `<link rel=icon>` and apple-touch-icon
/// hrefs; the best one (or /favicon.ico) is fetched without cookies, scaled
/// down and cached by host in memory and under Application Support/Bamboo/Favicons.
/// Private tabs never write to the disk cache.
@MainActor
final class FaviconLoader: TabExtension {
    static let shared = FaviconLoader()

    /// Icons are stored at this size in pixels, enough for a 32-point tile on a Retina display.
    private static let storedPixelSize: CGFloat = 64
    private static let maxDownloadBytes = 1 << 20
    private static let linksScript = """
        return [...document.querySelectorAll(
            'link[rel~="icon" i], link[rel~="apple-touch-icon" i], link[rel~="apple-touch-icon-precomposed" i]'
        )].map(link => [link.href, link.getAttribute("sizes") || "", link.rel.toLowerCase()]);
        """

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    private let session: URLSession
    private let world = WKContentWorld.world(name: "BambooFavicons")
    /// Hosts fetched this launch; others are refreshed once even if cached on disk.
    private var fetchedHosts: Set<String> = []
    private var tasks: [Tab.ID: Task<Void, Never>] = [:]

    private init() {
        directory = AppPaths.applicationSupport.appendingPathComponent("Favicons", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            fatalError("Cannot create \(directory.path): \(error)")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
        memory.countLimit = 500
    }

    /// The cached icon for a host, from memory or disk.
    func icon(forHost host: String) -> NSImage? {
        if let image = memory.object(forKey: host as NSString) { return image }
        let file = fileURL(forHost: host)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let image = NSImage(contentsOf: file) else {
            AppServices.shared.reportNonFatal(CocoaError(.fileReadCorruptFile), "Reading cached favicon \(file.lastPathComponent)")
            return nil
        }
        memory.setObject(image, forKey: host as NSString)
        return image
    }

    // MARK: - TabExtension

    func didCommitNavigation(in tab: Tab) {
        tab.favicon = tab.url?.host().flatMap(icon(forHost:))
    }

    func didFinishNavigation(in tab: Tab) {
        guard let webView = tab.webView, let pageURL = tab.url, let host = pageURL.host(),
              pageURL.scheme == "https" || pageURL.scheme == "http"
        else { return }
        if fetchedHosts.contains(host) {
            tab.favicon = icon(forHost: host)
            return
        }
        tasks[tab.id]?.cancel()
        tasks[tab.id] = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            await self.load(host: host, pageURL: pageURL, webView: webView, tab: tab)
        }
    }

    func willClose(_ tab: Tab) {
        tasks.removeValue(forKey: tab.id)?.cancel()
    }

    // MARK: - Loading

    private func load(host: String, pageURL: URL, webView: WKWebView, tab: Tab) async {
        let links: [[String]]
        do {
            links = try await webView.callAsyncJavaScript(Self.linksScript, contentWorld: world) as? [[String]] ?? []
        } catch is WKError {
            // The page navigated away or its process ended while the script ran;
            // the next finished load tries again.
            return
        } catch {
            AppServices.shared.reportNonFatal(error, "Collecting favicon links on \(host)")
            return
        }

        var candidates = Self.rankedCandidates(links)
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL {
            candidates.append(fallback)
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return }
            guard let image = await fetchIcon(candidate) else { continue }
            fetchedHosts.insert(host)
            memory.setObject(image, forKey: host as NSString)
            if !tab.isPrivate {
                store(image, forHost: host)
            }
            if tab.url?.host() == host {
                tab.favicon = image
            }
            return
        }
        // The site has no icon we can use; remember that so we don't ask again this launch.
        fetchedHosts.insert(host)
    }

    /// Icon URLs best first: the smallest declared size of at least 64 px,
    /// then larger ones, then icons that declare no size.
    private static func rankedCandidates(_ links: [[String]]) -> [URL] {
        let sized = links.compactMap { link -> (url: URL, size: Int)? in
            guard link.count == 3, let url = URL(string: link[0]),
                  url.scheme == "https" || url.scheme == "http" || url.scheme == "data"
            else { return nil }
            let declared = link[1].lowercased().split(separator: " ").compactMap { token -> Int? in
                token == "any" ? 512 : token.split(separator: "x").first.flatMap { Int($0) }
            }.max()
            // Apple touch icons are 180 px when they don't say.
            let size = declared ?? (link[2].contains("apple-touch-icon") ? 180 : 0)
            return (url, size)
        }
        let preferred = sized.filter { $0.size >= Int(storedPixelSize) }.sorted { $0.size < $1.size }
        let smaller = sized.filter { $0.size > 0 && $0.size < Int(storedPixelSize) }.sorted { $0.size > $1.size }
        let unsized = sized.filter { $0.size == 0 }
        return (preferred + smaller + unsized).map(\.url)
    }

    /// Downloads and scales an icon. A failed request, an error status or data
    /// that isn't an image means this candidate is unusable, not that something
    /// broke, so the caller moves on to the next one.
    private func fetchIcon(_ url: URL) async -> NSImage? {
        let data: Data
        if url.scheme == "data" {
            guard let decoded = try? Data(contentsOf: url) else { return nil }
            data = decoded
        } else {
            do {
                let (body, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
                data = body
            } catch {
                return nil
            }
        }
        guard data.count <= Self.maxDownloadBytes, let image = NSImage(data: data), image.isValid else { return nil }
        return Self.scaled(image)
    }

    private static func scaled(_ image: NSImage) -> NSImage {
        let largest = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        // Vector icons report no pixel size and draw sharply at any size.
        let side = largest > 0 ? min(Int(storedPixelSize), largest) : Int(storedPixelSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { preconditionFailure("Cannot allocate a \(side)px bitmap") }

        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let drawSize = aspect >= 1
            ? NSSize(width: CGFloat(side), height: CGFloat(side) / aspect)
            : NSSize(width: CGFloat(side) * aspect, height: CGFloat(side))
        let rect = NSRect(x: (CGFloat(side) - drawSize.width) / 2, y: (CGFloat(side) - drawSize.height) / 2,
                          width: drawSize.width, height: drawSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        // ICO files hold several sizes; drawing picks the one closest to the target.
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(bitmap)
        return result
    }

    private func store(_ image: NSImage, forHost host: String) {
        guard let bitmap = image.representations.first as? NSBitmapImageRep,
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        do {
            try png.write(to: fileURL(forHost: host), options: .atomic)
        } catch {
            AppServices.shared.reportNonFatal(error, "Saving favicon for \(host)")
        }
    }

    private func fileURL(forHost host: String) -> URL {
        // Hosts can't contain "/", but IPv6 literals contain ":", which Finder shows oddly.
        let name = host.replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }
}
