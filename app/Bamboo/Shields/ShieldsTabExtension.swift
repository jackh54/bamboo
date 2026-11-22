import WebKit

/// Applies shields to every tab: the network rule lists, per-page cosmetic filtering and
/// scriptlets, generic element hiding, the blocked-request count, and per-site JavaScript
/// and Lockdown Mode.
@MainActor
final class ShieldsTabExtension: NSObject, TabExtension, WKScriptMessageHandlerWithReply {
    /// Shields' own scripts run in an isolated world, so pages can't see them or post to their handlers.
    private static let world = WKContentWorld.world(name: "BambooShields")
    private static let hideHandler = "bambooShieldsHide"
    private static let requestsHandler = "bambooShieldsRequests"
    /// Upper bounds on one message, matching the batch sizes the scripts send.
    private static let maxNames = 5000
    private static let maxRequests = 500

    private struct Page {
        let url: URL
        let exceptions: [String]
        let generichide: Bool
    }

    private let genericHidingScript = WKUserScript(
        bundled: "shields-hide", injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: ShieldsTabExtension.world)
    private let requestsScript = WKUserScript(
        bundled: "shields-requests", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: ShieldsTabExtension.world)
    /// The cosmetic script of each controller's latest page. Keyed by controller, not tab,
    /// because popups share their opener's controller.
    private let cosmeticScripts = NSMapTable<WKUserContentController, WKUserScript>.weakToStrongObjects()
    /// Pages with shields on, by tab.
    private var pages: [Tab.ID: Page] = [:]

    private var shields: ShieldsManager { AppServices.shared.shields }

    func configure(_ configuration: WKWebViewConfiguration, for tab: Tab) {
        let controller = configuration.userContentController
        shields.ruleLists.forEach(controller.add)
        controller.addUserScript(genericHidingScript)
        controller.addUserScript(requestsScript)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.hideHandler)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.requestsHandler)
    }

    func decidePolicy(for action: WKNavigationAction, preferences: WKWebpagePreferences, in tab: Tab) async -> NavigationPolicy {
        guard action.targetFrame?.isMainFrame ?? false, let url = action.request.url,
              url.scheme == "http" || url.scheme == "https", let host = url.host(),
              let controller = tab.webView?.configuration.userContentController
        else { return .allow }

        let site = SiteShields(tab.profile.siteSettings(for: host), defaults: AppServices.shared.settings)
        if site.blocksScripts {
            preferences.allowsContentJavaScript = false
        }
        // Only ever turned on here: setting false would exempt the page from system-wide Lockdown Mode.
        if site.lockdownMode {
            preferences.isLockdownModeEnabled = true
        }

        if site.blocksTrackersAndAds {
            shields.ruleLists.forEach(controller.add)
            let resources = shields.engine.cosmeticResources(pageUrl: url.absoluteString)
            pages[tab.id] = Page(url: url, exceptions: resources.exceptions, generichide: resources.generichide)
            setCosmeticScript(Self.cosmeticSource(resources), in: controller)
        } else {
            shields.ruleLists.forEach(controller.remove)
            pages[tab.id] = nil
            setCosmeticScript(nil, in: controller)
        }
        return .allow
    }

    func willClose(_ tab: Tab) {
        pages[tab.id] = nil
    }

    /// Page-world script for one page: a style sheet hiding the page's cosmetic selectors,
    /// then the scriptlets, which must share the page's JavaScript globals to patch them.
    static func cosmeticSource(_ resources: CosmeticResources) -> String? {
        var source = ""
        if !resources.hideSelectors.isEmpty {
            let css = resources.hideSelectors.map { "\($0) { display: none !important; }" }.joined(separator: "\n")
            // Encoding a String as JSON cannot fail.
            let literal = String(decoding: try! JSONEncoder().encode(css), as: UTF8.self)
            source += """
                (() => {
                  const style = document.createElement('style');
                  style.textContent = \(literal);
                  document.documentElement.appendChild(style);
                })();

                """
        }
        source += resources.injectedScript
        return source.isEmpty ? nil : source
    }

    private func setCosmeticScript(_ source: String?, in controller: WKUserContentController) {
        let previous = cosmeticScripts.object(forKey: controller)
        guard previous != nil || source != nil else { return }
        // WebKit can't remove one user script, so remove them all and put the others back.
        let others = controller.userScripts.filter { $0 !== previous }
        controller.removeAllUserScripts()
        others.forEach(controller.addUserScript)
        if let source {
            let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
            controller.addUserScript(script)
            cosmeticScripts.setObject(script, forKey: controller)
        } else {
            cosmeticScripts.removeObject(forKey: controller)
        }
    }

    // MARK: - Messages from the shields scripts

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let tab = AppServices.shared.windows.tab(for: message.webView),
              let body = message.body as? [String: Any]
        else { return replyHandler(nil, "Unknown tab or malformed message") }
        // Shields are off for this page, or it has gone: the scripts stop on a nil reply.
        guard let page = pages[tab.id] else { return replyHandler(nil, nil) }

        switch message.name {
        case Self.hideHandler:
            guard let classes = body["classes"] as? [String], let ids = body["ids"] as? [String],
                  classes.count <= Self.maxNames, ids.count <= Self.maxNames
            else { return replyHandler(nil, "Malformed hide message") }
            guard !page.generichide else { return replyHandler(nil, nil) }
            replyHandler(shields.engine.hiddenSelectors(classes: classes, ids: ids, exceptions: page.exceptions), nil)

        case Self.requestsHandler:
            guard let entries = body["requests"] as? [[String: Any]], entries.count <= Self.maxRequests
            else { return replyHandler(nil, "Malformed requests message") }
            let requests = entries.compactMap { entry -> ObservedRequest? in
                guard let url = entry["url"] as? String, let type = (entry["type"] as? String).flatMap(Self.requestType)
                else { return nil }
                return ObservedRequest(url: url, requestType: type)
            }
            guard requests.count == entries.count else { return replyHandler(nil, "Malformed request entry") }
            record(shields.engine.checkRequests(pageUrl: page.url.absoluteString, requests: requests), in: tab)
            replyHandler(nil, nil)

        default:
            replyHandler(nil, "Unknown handler \(message.name)")
        }
    }

    private func record(_ blocked: [BlockedRequest], in tab: Tab) {
        guard !blocked.isEmpty else { return }
        tab.blockedRequestCount += blocked.count
        tab.blockedHosts.formUnion(blocked.map(\.host))
        // Which trackers a private page met would hint at where the user went.
        guard !tab.isPrivate else { return }
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        for (host, requests) in Dictionary(grouping: blocked, by: \.host) {
            do {
                try tab.profile.store.recordBlocked(trackerHost: host, count: UInt32(requests.count), atMs: now)
            } catch {
                AppServices.shared.reportNonFatal(error, "Recording blocked requests")
            }
        }
    }

    private static func requestType(_ name: String) -> RequestType? {
        switch name {
        case "subdocument": .subdocument
        case "script": .script
        case "stylesheet": .stylesheet
        case "image": .image
        case "font": .font
        case "media": .media
        case "xhr": .xhr
        case "other": .other
        default: nil
        }
    }
}

/// What shields do on one site: the Shields defaults in Settings combined with the site's
/// own settings from the Shields panel.
@MainActor
struct SiteShields: Equatable {
    let blocksTrackersAndAds: Bool
    let blocksScripts: Bool
    let lockdownMode: Bool

    /// `site` is nil when the site's settings couldn't be read; the defaults apply then.
    init(_ site: SiteSettings?, defaults: AppSettings) {
        let isUp = site?.shieldsUp ?? true
        blocksTrackersAndAds = defaults.blockTrackersAndAds && (site?.shieldsEnabled ?? true)
        blocksScripts = site?.javascriptEnabled == false || (defaults.blockScripts && isUp)
        lockdownMode = site?.lockdownMode ?? false
    }
}

extension SiteSettings {
    /// Shields count as down for a site only once every protection is off for it.
    var shieldsUp: Bool { shieldsEnabled || !javascriptEnabled || lockdownMode }
}

extension Profile {
    /// The site's settings, or nil (meaning the defaults) when the database can't be read.
    func siteSettings(for host: String) -> SiteSettings? {
        do {
            return try store.siteSettings(host: host)
        } catch {
            AppServices.shared.reportNonFatal(error, "Reading site settings")
            return nil
        }
    }
}
