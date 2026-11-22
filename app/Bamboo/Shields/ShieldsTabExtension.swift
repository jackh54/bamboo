import WebKit

/// Applies shields to every tab: the network rule lists, per-page cosmetic filtering and
/// scriptlets, generic element hiding, and per-site JavaScript and Lockdown Mode. The
/// blocked-request count comes from WebKit (see `TabWebViewDelegate`).
@MainActor
final class ShieldsTabExtension: NSObject, TabExtension, WKScriptMessageHandlerWithReply {
    /// Shields' own scripts run in an isolated world, so pages can't see them or post to their handlers.
    private static let world = WKContentWorld.world(name: "BambooShields")
    private static let hideHandler = "bambooShieldsHide"
    /// Upper bound on one message, matching the batch size the script sends.
    private static let maxNames = 5000

    private struct Page {
        let url: URL
        let exceptions: [String]
        let generichide: Bool
    }

    private let genericHidingScript = WKUserScript(
        bundled: "shields-hide", injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: ShieldsTabExtension.world)
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
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.hideHandler)
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


        default:
            replyHandler(nil, "Unknown handler \(message.name)")
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
