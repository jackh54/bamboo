import WebKit
import XCTest
@testable import Bamboo

/// Runs the browser tools against a real web view in an agent tab, which the
/// executor hosts in its offscreen window (the tab is never selected).
@MainActor
final class AgentExecutorTests: XCTestCase {
    private var executor: BrowserToolExecutor!
    private var session: AgentSession!
    private var tab: Tab!

    override func setUp() async throws {
        executor = BrowserToolExecutor()
        session = AgentSession(id: "test", name: "Test")
        tab = AppServices.shared.windows.openAgentTab(url: nil)
        session.currentTab = tab
        tab.ensureWebView().loadHTMLString(Self.fixture, baseURL: URL(string: "https://fixture.bamboo.test/")!)
        try await waitUntil { !self.tab.isLoading && self.tab.title == "Agent Fixture" }
    }

    override func tearDown() async throws {
        tab.pendingDialog?.respond(accepted: false)
        AppServices.shared.windows.close(tab)
        // The test host is a real Bamboo; save now so the fixture tab isn't restored next launch.
        AppServices.shared.windows.saveSession()
    }

    func testSnapshotOutlinesRolesNamesAndStates() async throws {
        let snapshot = try await run("snapshot")
        XCTAssertTrue(snapshot.hasPrefix("Title: Agent Fixture\nURL: https://fixture.bamboo.test/"), snapshot)
        XCTAssertTrue(snapshot.contains(#"- heading "Agent fixture" [level=1] [ref=e"#), snapshot)
        XCTAssertTrue(snapshot.contains(#"- button "Count" [ref=e"#), snapshot)
        XCTAssertTrue(snapshot.contains(#"- textbox "Name" [ref="#), snapshot)
        XCTAssertTrue(line(snapshot, #"textbox "Name""#).hasSuffix(": old"), snapshot)
        XCTAssertTrue(line(snapshot, #"textbox "Password""#).hasSuffix(": ••••••••"), snapshot)
        XCTAssertFalse(snapshot.contains("secret"), "password values are masked")
        XCTAssertTrue(snapshot.contains(#"- checkbox "I agree" [ref="#), snapshot)
        XCTAssertTrue(snapshot.contains(#"- option "United States" [selected]"#), snapshot)
        XCTAssertTrue(snapshot.contains(#"- button "Shadow button" [ref="#), "open shadow roots are walked")
        XCTAssertTrue(snapshot.contains(#"- button "Show more" [collapsed] [ref="#), snapshot)
        XCTAssertTrue(line(snapshot, "Clickable div").contains("- generic [cursor=pointer] [ref="), snapshot)
        XCTAssertTrue(line(snapshot, "Second item").hasSuffix("]: Second item"), "inline markup doesn't split text")
        XCTAssertTrue(line(snapshot, "Second item").contains("- listitem [ref="), snapshot)
        XCTAssertFalse(snapshot.contains("Hidden from agents"), "aria-hidden content is skipped")
        XCTAssertFalse(snapshot.contains("Not displayed"), "display:none content is skipped")

        // Refs stay the same for the same element across snapshots.
        let again = try await run("snapshot")
        XCTAssertEqual(ref(snapshot, #"button "Count""#), ref(again, #"button "Count""#))
    }

    func testClickSendsTrustedNativeEvents() async throws {
        let snapshot = try await run("snapshot")
        let result = try await run("click", ["ref": .string(ref(snapshot, #"button "Count""#))])
        XCTAssertTrue(result.hasPrefix("Clicked e"), result)
        try await waitUntil { try await self.pageText("clicks") == "Clicks: 1 trusted: true" }

        try await run("click", ["ref": .string(ref(snapshot, #"button "Count""#)), "double_click": true])
        try await waitUntil { try await self.pageText("clicks") == "Clicks: 3 trusted: true" }
        let doubleClicks = try await pageValue("window.doubleClicks")
        XCTAssertEqual(doubleClicks as? Int, 1)
    }

    func testClickAccountsForZoomAndMagnification() async throws {
        let snapshot = try await run("snapshot")
        let count = ref(snapshot, #"button "Count""#)
        tab.webView?.pageZoom = 1.5
        try await run("click", ["ref": .string(count)])
        try await waitUntil { try await self.pageText("clicks") == "Clicks: 1 trusted: true" }
        tab.webView?.setMagnification(1.6, centeredAt: CGPoint(x: 300, y: 200))
        try await run("click", ["ref": .string(count)])
        try await waitUntil { try await self.pageText("clicks") == "Clicks: 2 trusted: true" }
    }

    func testRightAndMiddleClicks() async throws {
        let snapshot = try await run("snapshot")
        let target = ref(snapshot, "Clickable div")
        try await run("click", ["ref": .string(target), "button": "right"])
        try await waitUntil { try await self.pageValue("window.contextMenus") as? Int == 1 }
        try await run("click", ["ref": .string(target), "button": "middle"])
        try await waitUntil { try await self.pageValue("window.auxButton") as? Int == 1 }
        // The browser's context menu didn't open and swallow later input.
        try await run("click", ["ref": .string(target)])
        try await waitUntil { try await self.pageValue("window.leftClicks") as? Int == 1 }
    }

    func testClickRefusesObscuredElements() async throws {
        let snapshot = try await run("snapshot")
        let outcome = await executor.run("click", arguments: ["ref": .string(ref(snapshot, #"button "Covered""#))], session: session)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(text(outcome).contains(#"obscured by <div id="cover""#), text(outcome))
    }

    func testTypeTextReplacesAppendsAndSubmits() async throws {
        let snapshot = try await run("snapshot")
        let name = ref(snapshot, #"textbox "Name""#)
        try await run("type_text", ["ref": .string(name), "text": "hello"])
        let replaced = try await pageValue("document.getElementById('name').value")
        XCTAssertEqual(replaced as? String, "hello")
        try await run("type_text", ["ref": .string(name), "text": " world", "clear": false])
        let appended = try await pageValue("document.getElementById('name').value")
        XCTAssertEqual(appended as? String, "hello world")
        let inputEvents = try await pageValue("window.trustedInputs")
        XCTAssertGreaterThan(inputEvents as? Int ?? 0, 0, "input events are trusted")

        let result = try await run("type_text", ["ref": .string(name), "text": "go", "submit": true])
        XCTAssertTrue(result.contains("Pressed Enter."), result)
        try await waitUntil { try await self.pageText("submitted") == "Submitted go" }
    }

    func testTypeTextWorksWithReactStyleControlledInput() async throws {
        let snapshot = try await run("snapshot")
        let controlled = ref(snapshot, #"textbox "Controlled""#)
        try await run("type_text", ["ref": .string(controlled), "text": "react value"])
        try await waitUntil { try await self.pageText("mirror") == "react value" }
        let value = try await pageValue("document.getElementById('controlled').value")
        XCTAssertEqual(value as? String, "react value", "the framework kept the typed value")
    }

    func testPressKeySendsKeyEventsWithModifiers() async throws {
        let snapshot = try await run("snapshot")
        let name = ref(snapshot, #"textbox "Name""#)
        try await run("type_text", ["ref": .string(name), "text": "ab"])
        try await run("press_key", ["key": "Backspace"])
        try await run("press_key", ["key": "Z"])
        try await run("press_key", ["key": "!"])
        try await run("press_key", ["key": "ArrowLeft", "modifiers": ["Shift"]])
        let value = try await pageValue("document.getElementById('name').value")
        XCTAssertEqual(value as? String, "aZ!")
        let keys = try await pageValue("window.keys.join(',')")
        // type_text inserts text without key events; press_key sends real ones.
        XCTAssertEqual(keys as? String, "Backspace,Z,Shift+!,Shift+ArrowLeft")

        try await run("press_key", ["key": "a", "modifiers": ["Meta"]])
        try await run("press_key", ["key": "Backspace"])
        let cleared = try await pageValue("document.getElementById('name').value")
        XCTAssertEqual(cleared as? String, "", "Meta+A selects the field's text")
    }

    func testDialogIsReportedAndAnswered() async throws {
        let snapshot = try await run("snapshot")
        let result = try await run("click", ["ref": .string(ref(snapshot, #"button "Delete""#))])
        XCTAssertTrue(result.contains(#"confirm dialog: "Delete everything?""#), result)
        let blocked = await executor.run("snapshot", arguments: [:], session: session)
        XCTAssertTrue(blocked.isError, "page tools wait for the dialog")
        let answer = try await run("dialog_respond", ["accept": true])
        XCTAssertTrue(answer.hasPrefix("Accepted the confirm dialog"), answer)
        try await waitUntil { try await self.pageText("answer") == "confirmed" }
    }

    func testSelectOptionAndFillForm() async throws {
        let snapshot = try await run("snapshot")
        let country = ref(snapshot, #"combobox "Country""#)
        let selected = try await run("select_option", ["ref": .string(country), "values": ["Canada"]])
        XCTAssertTrue(selected.hasPrefix(#"Selected "Canada""#), selected)
        try await waitUntil { try await self.pageText("country-change") == "ca" }

        let filled = try await run("fill_form", ["fields": [
            ["ref": .string(ref(snapshot, #"textbox "Name""#)), "value": "Filled"],
            ["ref": .string(ref(snapshot, #"checkbox "I agree""#)), "value": "true"],
            ["ref": .string(country), "value": "us"],
        ]])
        XCTAssertTrue(filled.hasPrefix("Filled 3 fields"), filled)
        let values = try await pageValue(
            "[document.getElementById('name').value, document.getElementById('agree').checked, document.getElementById('country').value].join('|')")
        XCTAssertEqual(values as? String, "Filled|true|us")
    }

    func testReadPageGivesMarkdown() async throws {
        let page = try await run("read_page")
        XCTAssertTrue(page.hasPrefix("Title: Agent Fixture\nURL: https://fixture.bamboo.test/"), page)
        XCTAssertTrue(page.contains("# Agent fixture"), page)
        XCTAssertTrue(page.contains("## Details"), page)
        XCTAssertTrue(page.contains("- First item\n- Second **item**"), page)
        XCTAssertTrue(page.contains("[a link](https://fixture.bamboo.test/docs)"), page)
        XCTAssertTrue(page.contains("```swift\nlet x = 1\n```"), page)
        XCTAssertTrue(page.contains("| Name | Value |\n| --- | --- |\n| a | 1 |"), page)
        XCTAssertFalse(page.contains("Hidden from agents"), page)
    }

    func testScrollWaitForAndScreenshot() async throws {
        let scrolled = try await run("scroll", ["direction": "down", "amount": 300])
        XCTAssertTrue(scrolled.hasPrefix("Scrolled down. Now 300 px from the top"), scrolled)

        _ = try await pageValue("setTimeout(() => document.getElementById('later').textContent = 'Ready now', 300), 0")
        let waited = try await run("wait_for", ["text": "Ready now"])
        XCTAssertTrue(waited.hasPrefix(#""Ready now" appeared"#), waited)

        let outcome = await executor.run("screenshot", arguments: ["full_page": true], session: session)
        XCTAssertFalse(outcome.isError, text(outcome))
        guard case .image(let data, let mimeType) = outcome.content.first,
              let image = NSImage(data: Data(base64Encoded: data) ?? Data()),
              let bitmap = image.representations.first
        else { return XCTFail("screenshot has no PNG: \(outcome)") }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertLessThanOrEqual(max(bitmap.pixelsWide, bitmap.pixelsHigh), 1568)
        XCTAssertGreaterThan(bitmap.pixelsHigh, bitmap.pixelsWide, "the full page is taller than the window")
    }

    func testAccessRules() async throws {
        let profile = AppServices.shared.profiles.defaultProfile
        let privateTab = Tab(profile: profile, isPrivate: true, dataStore: .nonPersistent(), url: nil)
        privateTab.isAgentControlled = true
        XCTAssertFalse(executor.canAccess(privateTab), "private tabs are never available")
        let userTab = Tab(profile: profile, isPrivate: false, dataStore: profile.dataStore, url: nil)
        XCTAssertEqual(executor.canAccess(userTab), AppServices.shared.settings.agentAccess == .allTabs)
        XCTAssertTrue(executor.canAccess(tab))

        let unknown = await executor.run("snapshot", arguments: ["tab_id": .string(UUID().uuidString)], session: session)
        XCTAssertTrue(unknown.isError)
        for url in ["file:///etc/hosts", "data:text/html,<title>x</title>"] {
            let navigation = await executor.run("navigate", arguments: ["url": .string(url)], session: session)
            XCTAssertTrue(navigation.isError, "\(url) is refused")
        }
        XCTAssertEqual(tab.title, "Agent Fixture")
        if !AppServices.shared.settings.agentCanEvaluateJavaScript {
            let evaluate = await executor.run("evaluate", arguments: ["expression": "1 + 1"], session: session)
            XCTAssertTrue(evaluate.isError, "evaluate is refused while turned off")
        }
        let list = try await run("tabs_list")
        XCTAssertTrue(list.contains("\(tab.id.uuidString.lowercased()): Agent Fixture — https://fixture.bamboo.test/ (current)"), list)
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ tool: String, _ arguments: JSONValue = [:]) async throws -> String {
        let outcome = await executor.run(tool, arguments: arguments, session: session)
        if outcome.isError {
            throw ToolFailure("\(tool) failed: \(text(outcome))")
        }
        return text(outcome)
    }

    private func text(_ outcome: ToolOutcome) -> String {
        outcome.content.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func line(_ snapshot: String, _ marker: String) -> String {
        snapshot.components(separatedBy: "\n").first { $0.contains(marker) } ?? ""
    }

    private func ref(_ snapshot: String, _ marker: String) -> String {
        let line = line(snapshot, marker)
        guard let match = line.firstMatch(of: /\[ref=(e\d+)\]/) else {
            XCTFail("No ref for \(marker) in:\n\(snapshot)")
            return ""
        }
        return String(match.1)
    }

    private func pageValue(_ expression: String) async throws -> Any? {
        try await tab.webView?.evaluateJavaScript(expression)
    }

    private func pageText(_ id: String) async throws -> String? {
        try await pageValue("document.getElementById('\(id)').textContent") as? String
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw ToolFailure("Timed out waiting for the page") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private static let fixture = """
        <!doctype html>
        <html><head><title>Agent Fixture</title>
        <style>
          body { font: 14px -apple-system; margin: 20px; }
          #cover { position: absolute; left: 0; top: 0; width: 200px; height: 60px; background: rgba(0,0,0,.3); }
          .spacer { height: 2400px; }
        </style></head>
        <body>
          <h1>Agent fixture</h1>
          <p>Read <a href="/docs">a link</a> first.</p>
          <form id="form" onsubmit="event.preventDefault(); document.getElementById('submitted').textContent = 'Submitted ' + document.getElementById('name').value">
            <button type="button" id="counter">Count</button>
            <p id="clicks">Clicks: 0</p>
            <label>Name <input id="name" type="text" value="old"></label>
          </form>
          <p id="submitted"></p>
          <label>Controlled <input id="controlled" type="text"></label>
          <p id="mirror"></p>
          <label>Password <input id="password" type="password" value="secret"></label>
          <label><input id="agree" type="checkbox"> I agree</label>
          <label>Country <select id="country"><option value="us">United States</option><option value="ca">Canada</option></select></label>
          <p id="country-change"></p>
          <button id="delete" onclick="document.getElementById('answer').textContent = confirm('Delete everything?') ? 'confirmed' : 'cancelled'">Delete</button>
          <p id="answer"></p>
          <button aria-expanded="false">Show more</button>
          <div id="clickable" style="cursor: pointer">Clickable div</div>
          <div style="position: relative; height: 60px">
            <button id="covered">Covered</button>
            <div id="cover"></div>
          </div>
          <div aria-hidden="true">Hidden from agents</div>
          <div style="display: none">Not displayed</div>
          <my-widget></my-widget>
          <p id="later"></p>
          <h2>Details</h2>
          <ul><li>First item</li><li>Second <strong>item</strong></li></ul>
          <pre><code class="language-swift">let x = 1</code></pre>
          <table><tr><th>Name</th><th>Value</th></tr><tr><td>a</td><td>1</td></tr></table>
          <div class="spacer"></div>
          <script>
            let clicks = 0;
            window.doubleClicks = 0;
            const counter = document.getElementById('counter');
            counter.addEventListener('click', (event) => {
              clicks += 1;
              document.getElementById('clicks').textContent = 'Clicks: ' + clicks + ' trusted: ' + event.isTrusted;
            });
            counter.addEventListener('dblclick', () => { window.doubleClicks += 1; });

            window.trustedInputs = 0;
            document.getElementById('name').addEventListener('input', (event) => { if (event.isTrusted) window.trustedInputs += 1; });
            window.keys = [];
            document.getElementById('name').addEventListener('keydown', (event) => {
              if (!event.isTrusted) return;
              window.keys.push((event.shiftKey && event.key !== 'Z' ? 'Shift+' : '') + event.key);
            });

            // Like React: the framework remembers the value it last wrote and
            // only treats an input event as a change when the DOM value differs.
            const controlled = document.getElementById('controlled');
            const nativeValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            let tracked = '';
            let state = '';
            Object.defineProperty(controlled, 'value', {
              configurable: true,
              get() { return nativeValue.get.call(this); },
              set(value) { tracked = String(value); nativeValue.set.call(this, value); },
            });
            controlled.addEventListener('input', () => {
              const actual = nativeValue.get.call(controlled);
              if (actual !== tracked) { tracked = actual; state = actual; }
              controlled.value = state;
              document.getElementById('mirror').textContent = state;
            });

            document.getElementById('country').addEventListener('change', (event) => {
              document.getElementById('country-change').textContent = event.target.value;
            });
            const clickable = document.getElementById('clickable');
            window.contextMenus = 0;
            clickable.addEventListener('contextmenu', () => { window.contextMenus += 1; });
            clickable.addEventListener('auxclick', (event) => { window.auxButton = event.button; });
            window.leftClicks = 0;
            clickable.addEventListener('click', () => { window.leftClicks += 1; });

            customElements.define('my-widget', class extends HTMLElement {
              constructor() {
                super();
                const button = document.createElement('button');
                button.textContent = 'Shadow button';
                this.attachShadow({ mode: 'open' }).appendChild(button);
              }
            });
          </script>
        </body></html>
        """
}
