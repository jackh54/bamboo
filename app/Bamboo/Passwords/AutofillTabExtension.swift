import AppKit
import WebKit

/// Offers saved logins when the user focuses a login field, fills the one they pick, and
/// offers to save credentials the page submits (`Tab.passwordSaveOffer`).
@MainActor
final class AutofillTabExtension: NSObject, TabExtension, WKScriptMessageHandler {
    /// The autofill script runs in an isolated world: pages can't call its fill function or
    /// post fake submissions to its handler.
    private static let world = WKContentWorld.world(name: "BambooAutofill")
    private static let handlerName = "bambooAutofill"
    private static let maxFieldLength = 4096

    private struct FillTarget {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let passwords: PasswordStore
    }

    private let script = WKUserScript(
        bundled: "autofill-forms", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: AutofillTabExtension.world)
    /// Where the login picked from the open menu goes.
    private var fillTarget: FillTarget?

    private var settings: AppSettings { AppServices.shared.settings }

    func configure(_ configuration: WKWebViewConfiguration, for tab: Tab) {
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard let webView = message.webView, let tab = AppServices.shared.windows.tab(for: webView),
              message.frameInfo.isMainFrame, origin.protocol == "https" || origin.protocol == "http",
              !origin.host.isEmpty, let body = message.body as? [String: Any]
        else { return }

        switch body["type"] as? String {
        case "focus":
            guard let x = body["x"] as? Double, let y = body["y"] as? Double,
                  let width = body["width"] as? Double, let height = body["height"] as? Double
            else { return AppServices.shared.reportNonFatal(MessageError.malformed, "Autofill focus message") }
            showLogins(for: origin, below: CGRect(x: x, y: y, width: width, height: height), frame: message.frameInfo,
                       in: webView, from: tab.profile.passwords)
        case "submit":
            guard let username = body["username"] as? String, let password = body["password"] as? String,
                  username.count <= Self.maxFieldLength, password.count <= Self.maxFieldLength
            else { return AppServices.shared.reportNonFatal(MessageError.malformed, "Autofill submit message") }
            offerToSave(username: username, password: password, origin: origin, in: tab)
        default:
            AppServices.shared.reportNonFatal(MessageError.malformed, "Autofill message")
        }
    }

    private enum MessageError: Error {
        case malformed
    }

    // MARK: - Filling

    private func showLogins(
        for origin: WKSecurityOrigin, below rect: CGRect, frame: WKFrameInfo, in webView: WKWebView,
        from passwords: PasswordStore
    ) {
        guard settings.autofillPasswords else { return }
        let port = origin.port == 0 ? nil : origin.port
        let logins: [SavedLogin]
        do {
            logins = try passwords.logins(forHost: origin.host, isSecure: origin.protocol == "https")
                .filter { $0.port == port }
        } catch {
            return AppServices.shared.reportNonFatal(error, "Looking up saved logins")
        }
        guard !logins.isEmpty else { return }

        let menu = NSMenu()
        for login in logins {
            let item = NSMenuItem(title: login.username.isEmpty ? "No username" : login.username,
                                  action: #selector(fill(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = login
            item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Passwords…", action: #selector(managePasswords(_:)), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)

        fillTarget = FillTarget(webView: webView, frame: frame, passwords: passwords)
        // The rect is in CSS pixels of the viewport.
        let scale = webView.pageZoom * webView.magnification
        let bottom = (rect.maxY + 4) * scale
        let point = NSPoint(x: rect.minX * scale, y: webView.isFlipped ? bottom : webView.bounds.height - bottom)
        // Opened after the message handler returns; the menu runs its own event loop.
        Task { menu.popUp(positioning: nil, at: point, in: webView) }
    }

    @objc private func fill(_ item: NSMenuItem) {
        guard let login = item.representedObject as? SavedLogin, let target = fillTarget,
              let webView = target.webView
        else { return }
        let password: String
        do {
            password = try target.passwords.password(for: login)
        } catch {
            if (error as? KeychainError)?.status != errSecUserCanceled {
                _ = webView.presentError(error)
            }
            return
        }
        Task {
            do {
                // Arguments, not string interpolation: the values never become script source.
                _ = try await webView.callAsyncJavaScript(
                    "return bambooAutofillFill(origin, username, password)",
                    arguments: ["origin": login.origin, "username": login.username, "password": password],
                    in: target.frame, contentWorld: Self.world)
            } catch {
                AppServices.shared.reportNonFatal(error, "Filling a saved login")
            }
        }
    }

    @objc private func managePasswords(_ item: NSMenuItem) {
        SettingsWindowController.shared.show(section: .passwords)
    }

    // MARK: - Saving

    /// The offer belongs to the origin it was made on; once the tab shows another origin,
    /// saving from the banner could be mistaken for saving for the page now on screen.
    func didCommitNavigation(in tab: Tab) {
        guard let offer = tab.passwordSaveOffer,
              !Self.offer(offer, survivesCommitOf: tab.webView?.url)
        else { return }
        tab.passwordSaveOffer = nil
    }

    static func offer(_ offer: PasswordSaveOffer, survivesCommitOf url: URL?) -> Bool {
        url.flatMap { SavedLogin(origin: $0, username: offer.login.username) }?.origin == offer.login.origin
    }

    private func offerToSave(username: String, password: String, origin: WKSecurityOrigin, in tab: Tab) {
        guard !tab.isPrivate, settings.offerToSavePasswords, !password.isEmpty,
              !settings.neverSavePasswordHosts.contains(origin.host)
        else { return }
        let login = SavedLogin(origin, username: username)
        let passwords = tab.profile.passwords
        let saved: SavedLogin?
        do {
            saved = try passwords.logins(forHost: login.host, isSecure: login.isSecure)
                .first { $0.username == username && $0.port == login.port }
        } catch {
            return AppServices.shared.reportNonFatal(error, "Looking up saved logins")
        }
        // When the stored password can't be read (the user declined a Keychain prompt) the
        // passwords can't be compared, and offering is right: saving replaces what's stored.
        if let saved, (try? passwords.password(for: saved)) == password { return }
        let offer = PasswordSaveOffer(login: login, password: password)
        if tab.passwordSaveOffer != offer {
            tab.passwordSaveOffer = offer
        }
    }
}

extension SavedLogin {
    /// A login for the page's security origin, which WebKit reports with port 0 for the
    /// scheme's default port.
    @MainActor
    init(_ origin: WKSecurityOrigin, username: String) {
        self.init(host: origin.host, isSecure: origin.protocol == "https",
                  port: origin.port == 0 ? nil : origin.port, username: username, modified: nil)
    }
}
