import WebKit
import XCTest
@testable import Bamboo

/// Runs the bundled shields, privacy and autofill scripts in a real web view, with a
/// recording handler standing in for the native side.
@MainActor
final class PageScriptTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandlerWithReply {
        var messages: [[String: Any]] = []
        var reply: Any?

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor (Any?, String?) -> Void
        ) {
            messages.append(message.body as? [String: Any] ?? [:])
            replyHandler(reply, nil)
        }
    }

    private let recorder = Recorder()

    private func webView(script: String, world: WKContentWorld, handler: String, html: String,
                         injectionTime: WKUserScriptInjectionTime = .atDocumentStart) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(bundled: script, injectionTime: injectionTime, forMainFrameOnly: true, in: world))
        configuration.userContentController.addScriptMessageHandler(recorder, contentWorld: world, name: handler)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://test.example/"))
        return webView
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out")
    }

    func testRequestsScriptReportsReferencedResources() async throws {
        let html = """
            <html><head><link rel="stylesheet" href="https://cdn.example/site.css"></head>
            <body><img src="https://ads.example/pixel.gif"><script src="https://tracker.example/t.js"></script>
            <iframe src="https://frames.example/ad.html"></iframe><a href="https://example.com">not a resource</a></body></html>
            """
        let webView = webView(script: "shields-requests", world: .world(name: "Test"), handler: "bambooShieldsRequests", html: html)
        try await waitUntil { recorder.messages.flatMap { $0["requests"] as? [[String: String]] ?? [] }.count >= 4 }
        let requests = recorder.messages.flatMap { $0["requests"] as? [[String: String]] ?? [] }
        let byURL = Dictionary(uniqueKeysWithValues: requests.map { ($0["url"]!, $0["type"]!) })
        XCTAssertEqual(byURL, [
            "https://cdn.example/site.css": "stylesheet",
            "https://ads.example/pixel.gif": "image",
            "https://tracker.example/t.js": "script",
            "https://frames.example/ad.html": "subdocument",
        ])
        _ = webView
    }

    func testHideScriptHidesTheSelectorsNativeReturns() async throws {
        recorder.reply = ["#sponsor", ".promo"]
        let html = #"<html><body><div id="sponsor">ad</div><p class="promo text">ad</p><p class="story">news</p></body></html>"#
        let webView = webView(script: "shields-hide", world: .world(name: "Test"), handler: "bambooShieldsHide",
                              html: html, injectionTime: .atDocumentEnd)
        try await waitUntil { !recorder.messages.isEmpty }
        let sent = try XCTUnwrap(recorder.messages.first)
        XCTAssertEqual(Set(sent["ids"] as? [String] ?? []), ["sponsor"])
        XCTAssertEqual(Set(sent["classes"] as? [String] ?? []), ["promo", "text", "story"])

        let display = "getComputedStyle(document.querySelector(%@)).display"
        try await waitUntil {
            try await webView.evaluateJavaScript(String(format: display, "'#sponsor'")) as? String == "none"
        }
        let promo = try await webView.evaluateJavaScript(String(format: display, "'.promo'")) as? String
        let story = try await webView.evaluateJavaScript(String(format: display, "'.story'")) as? String
        XCTAssertEqual(promo, "none")
        XCTAssertEqual(story, "block")
    }

    func testGlobalPrivacyControlIsVisibleToThePage() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(bundled: "privacy-gpc", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>hi</p>", baseURL: URL(string: "https://test.example/"))
        try await waitUntil { !webView.isLoading }
        let signal = try await webView.evaluateJavaScript("navigator.globalPrivacyControl") as? Bool
        XCTAssertEqual(signal, true)
    }

    func testAutofillOffersFillsAndReportsSubmissions() async throws {
        let world = WKContentWorld.world(name: "TestAutofill")
        let html = """
            <html><body><form id="login" action="javascript:void 0">
            <input id="user" type="email" autocomplete="username"><input id="pass" type="password">
            <button id="go" type="submit">Sign in</button></form>
            <script>window.inputEvents = 0; document.addEventListener('input', () => window.inputEvents++);</script>
            </body></html>
            """
        let webView = webView(script: "autofill-forms", world: world, handler: "bambooAutofill", html: html)
        try await waitUntil { !webView.isLoading }

        // A focus the page makes on its own doesn't open the menu; one after user input does.
        _ = try await webView.evaluateJavaScript("document.getElementById('user').focus()")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.messages.isEmpty)
        _ = try await webView.callAsyncJavaScript("""
            document.getElementById('user').blur();
            document.dispatchEvent(new PointerEvent('pointerdown'));
            document.getElementById('pass').focus();
            """, contentWorld: .page)
        try await waitUntil { recorder.messages.contains { $0["type"] as? String == "focus" } }

        let filled = try await webView.callAsyncJavaScript(
            "return bambooAutofillFill(origin, username, password)",
            arguments: ["origin": "https://test.example", "username": "jack@example.com", "password": "s3cret"],
            in: nil, contentWorld: world)
        XCTAssertEqual(filled as? Bool, true)
        let username = try await webView.evaluateJavaScript("document.getElementById('user').value") as? String
        let password = try await webView.evaluateJavaScript("document.getElementById('pass').value") as? String
        let inputEvents = try await webView.evaluateJavaScript("window.inputEvents") as? Int
        XCTAssertEqual(username, "jack@example.com")
        XCTAssertEqual(password, "s3cret")
        XCTAssertEqual(inputEvents, 2)

        let wrongOrigin = try await webView.callAsyncJavaScript(
            "return bambooAutofillFill(origin, username, password)",
            arguments: ["origin": "https://evil.example", "username": "x", "password": "y"], in: nil, contentWorld: world)
        XCTAssertEqual(wrongOrigin as? Bool, false)

        _ = try await webView.evaluateJavaScript("document.getElementById('go').click()")
        try await waitUntil { recorder.messages.contains { $0["type"] as? String == "submit" } }
        let submit = try XCTUnwrap(recorder.messages.first { $0["type"] as? String == "submit" })
        XCTAssertEqual(submit["username"] as? String, "jack@example.com")
        XCTAssertEqual(submit["password"] as? String, "s3cret")
    }

    func testAutofillScriptIsInvisibleToThePage() async throws {
        let webView = webView(script: "autofill-forms", world: .world(name: "TestAutofill"), handler: "bambooAutofill",
                              html: "<p>hi</p>")
        try await waitUntil { !webView.isLoading }
        let type = try await webView.evaluateJavaScript("typeof window.bambooAutofillFill") as? String
        XCTAssertEqual(type, "undefined")
    }
}
