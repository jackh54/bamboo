import AppKit
import Observation
import WebKit

/// One tool call, as shown in the agent activity log.
struct AgentActivity: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    /// The MCP client's name, or "Claude" for the side panel.
    let actor: String
    let tool: String
    let summary: String
    let tabID: UUID?
    let isError: Bool
}

/// Whoever calls tools: one MCP client, or the Claude panel of one window.
/// Tools without a `tab_id` act on `currentTab`, the tab this caller most
/// recently opened or selected.
@MainActor
final class AgentSession {
    let id: String
    var name: String
    weak var currentTab: Tab?
    /// A tab this caller may use whatever the access setting: the Claude
    /// panel's current tab during an agent-mode run. Other callers and popups
    /// opened from the tab get nothing from it.
    weak var grantedTab: Tab?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Runs the browser tools for MCP clients and the Claude panel. Arguments have
/// already been validated and normalized against `tool_specs()`. Access rules
/// are enforced here, whatever the caller: private tabs are never reachable,
/// and with `.agentTabsOnly` only agent-controlled tabs and the caller's own
/// granted tab are.
@MainActor
@Observable
final class BrowserToolExecutor {
    private(set) var recentActivity: [AgentActivity] = []
    private var activityByTab: [Tab.ID: [AgentActivity]] = [:]

    @ObservationIgnored private let world = WKContentWorld.world(name: "bamboo-agent")
    @ObservationIgnored private lazy var hostWindow = makeHostWindow()

    private static let snapshotScript = loadScript("agent-snapshot")
    private static let readScript = loadScript("agent-read")
    private static let pageLoadLimit: Duration = .seconds(30)
    private static let activityLimit = 200

    private var settings: AppSettings { AppServices.shared.settings }
    private var windows: WindowManager { AppServices.shared.windows }

    func activity(for tab: Tab) -> [AgentActivity] {
        activityByTab[tab.id] ?? []
    }

    func canAccess(_ tab: Tab, for session: AgentSession) -> Bool {
        guard !tab.isPrivate else { return false }
        return settings.agentAccess == .allTabs || tab.isAgentControlled || session.grantedTab === tab
    }

    func run(_ tool: String, arguments: JSONValue, session: AgentSession) async -> ToolOutcome {
        let outcome = await withTimeout(Self.timeLimit(tool, arguments), tool: tool) {
            do {
                return try await self.perform(tool, arguments, session)
            } catch {
                return Self.failure(Self.message(for: error))
            }
        }
        let tabID = arguments["tab_id"]?.string.flatMap(UUID.init(uuidString:)) ?? session.currentTab?.id
        record(AgentActivity(
            date: .now, actor: session.name, tool: tool, summary: Self.summary(tool, arguments),
            tabID: tabID, isError: outcome.isError))
        return outcome
    }

    /// The page as Markdown, for the Claude panel's page context.
    func pageMarkdown(_ tab: Tab) async throws -> String {
        let webView = try prepareWebView(tab)
        return try await readPage(webView)
    }

    // MARK: - Dispatch

    private func perform(_ tool: String, _ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        switch tool {
        case "tabs_list": return Self.text(tabsList(session))
        case "tab_open": return try await openTab(args, session)
        case "tab_select":
            let tab = try accessibleTab(args, session)
            session.currentTab = tab
            return Self.text("Selected tab \(Self.id(tab)).\n\(pageState(tab))")
        case "tab_close":
            let tab = try accessibleTab(args, session)
            windows.close(tab)
            if session.currentTab === tab { session.currentTab = nil }
            return Self.text("Closed tab \(Self.id(tab)).")
        case "navigate":
            let tab = try accessibleTab(args, session)
            _ = try prepareWebView(tab)
            tab.load(try Self.url(from: try args.required("url")))
            return try await loadResult(tab, verb: "Navigated")
        case "go_back":
            let tab = try accessibleTab(args, session)
            _ = try prepareWebView(tab)
            guard tab.canGoBack else { throw ToolFailure("This tab has no previous page.") }
            tab.goBack()
            return try await loadResult(tab, verb: "Went back")
        case "go_forward":
            let tab = try accessibleTab(args, session)
            _ = try prepareWebView(tab)
            guard tab.canGoForward else { throw ToolFailure("This tab has no next page.") }
            tab.goForward()
            return try await loadResult(tab, verb: "Went forward")
        case "reload":
            let tab = try accessibleTab(args, session)
            _ = try prepareWebView(tab)
            tab.reload()
            return try await loadResult(tab, verb: "Reloaded")
        case "snapshot": return try await snapshot(args, session)
        case "click": return try await click(args, session)
        case "hover": return try await hover(args, session)
        case "type_text": return try await typeText(args, session)
        case "fill_form": return try await fillForm(args, session)
        case "select_option": return try await selectOption(args, session)
        case "press_key": return try await pressKey(args, session)
        case "scroll": return try await scroll(args, session)
        case "screenshot": return try await screenshot(args, session)
        case "read_page":
            let tab = try accessibleTab(args, session)
            let markdown = try await readPage(try prepareWebView(tab))
            return Self.text("Title: \(Self.title(tab))\nURL: \(Self.address(tab))\n\n\(markdown)")
        case "wait_for": return try await waitFor(args, session)
        case "dialog_respond": return try await respondToDialog(args, session)
        case "evaluate": return try await evaluate(args, session)
        case "history_search": return try searchHistory(args, session)
        case "bookmarks_search": return try searchBookmarks(args, session)
        default: throw ToolFailure("Unknown tool \(tool).")
        }
    }

    // MARK: - Tabs

    private func tabsList(_ session: AgentSession) -> String {
        let tabs = windows.allTabs.filter { canAccess($0, for: session) }
        guard !tabs.isEmpty else {
            let scope = settings.agentAccess == .agentTabsOnly
                ? " Agents can use tabs they open and tabs the user hands over (Tab ▸ Let Agents Control This Tab)."
                : ""
            return "No tabs are available to agents.\(scope) Open one with tab_open."
        }
        return tabs.map { tab in
            var line = "- \(Self.id(tab)): \(Self.title(tab)) — \(Self.address(tab))"
            if tab === session.currentTab { line += " (current)" }
            if windows.windowModel(containing: tab)?.selectedTab === tab { line += " (visible to the user)" }
            return line
        }.joined(separator: "\n")
    }

    private func openTab(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let url = try args["url"]?.string.map(Self.url(from:))
        let tab = windows.openAgentTab(url: url)
        session.currentTab = tab
        if args["focus"]?.bool == true {
            windows.focus(tab)
        }
        _ = try prepareWebView(tab)
        guard url != nil else { return Self.text("Opened tab \(Self.id(tab)) with a blank page.") }
        return try await loadResult(tab, verb: "Opened tab \(Self.id(tab)) and loaded")
    }

    private func accessibleTab(_ args: JSONValue, _ session: AgentSession) throws -> Tab {
        if let id = args["tab_id"]?.string {
            guard let uuid = UUID(uuidString: id), let tab = windows.tab(id: uuid), canAccess(tab, for: session) else {
                throw ToolFailure("No tab \(id) is available to agents. Call tabs_list to see the tabs you can use.")
            }
            return tab
        }
        guard let tab = session.currentTab, windows.tab(id: tab.id) != nil, canAccess(tab, for: session) else {
            throw ToolFailure("There is no current tab. Open one with tab_open, or choose one from tabs_list with tab_select.")
        }
        return tab
    }

    /// The tab's web view, created if the tab was hibernated, and placed in the
    /// agent's offscreen window when no browser window shows it: input events
    /// and snapshots need a window, and layout needs a real size.
    private func prepareWebView(_ tab: Tab) throws -> WKWebView {
        if let dialog = tab.pendingDialog {
            throw ToolFailure(Self.dialogNotice(dialog))
        }
        let webView = tab.ensureWebView()
        if webView.window == nil {
            let visibleSize = windows.frontmost?.selectedTab?.webView?.bounds.size ?? .zero
            let size = visibleSize.width > 0 && visibleSize.height > 0 ? visibleSize : CGSize(width: 1280, height: 800)
            hostWindow.setContentSize(size)
            webView.frame = CGRect(origin: .zero, size: size)
            hostWindow.contentView?.addSubview(webView)
        }
        return webView
    }

    private func makeHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderFrontRegardless()
        return window
    }

    // MARK: - Page tools

    private func loadResult(_ tab: Tab, verb: String) async throws -> ToolOutcome {
        let finished = await waitForLoad(tab, limit: Self.pageLoadLimit)
        if let error = tab.loadError {
            throw ToolFailure("Couldn't load \(error.url?.absoluteString ?? "the page"): \(error.message)")
        }
        var result = "\(verb) \(Self.address(tab)).\n\(pageState(tab))"
        if !finished {
            result += "\nThe page was still loading after \(Self.pageLoadLimit.components.seconds) s; this is its state so far."
        }
        return Self.text(result + "\nCall snapshot to see the page's elements.")
    }

    private func snapshot(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let outline = try await callAgent(webView, "snapshot()") as? String ?? ""
        let body = outline.isEmpty ? "(The page has no visible content.)" : outline
        return Self.text("Title: \(Self.title(tab))\nURL: \(Self.address(tab))\n\n\(body)")
    }

    private func click(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let ref = try args.required("ref")
        let button = WebViewInput.MouseButton(rawValue: args["button"]?.string ?? "left") ?? .left
        let point = try await actionPoint(ref, in: webView, blockContextMenu: button == .right)
        try WebViewInput.click(webView, at: point, button: button, clickCount: args["double_click"]?.bool == true ? 2 : 1)
        await settle(tab)
        let verb = args["double_click"]?.bool == true ? "Double-clicked" : button == .left ? "Clicked" : "\(button.rawValue.capitalized)-clicked"
        return Self.text("\(verb) \(ref).\n\(pageState(tab))\nCall snapshot to see the result.")
    }

    private func hover(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let ref = try args.required("ref")
        try WebViewInput.hover(webView, at: try await actionPoint(ref, in: webView, blockContextMenu: false))
        await settle(tab)
        return Self.text("Hovering over \(ref). Call snapshot to see anything it revealed.")
    }

    /// Text goes in through WebKit's native text insertion (as from the
    /// keyboard or an input method), so pages get trusted beforeinput/input
    /// events and the value changes inside the engine. Frameworks that track
    /// the value they last set (React's controlled inputs) see a real edit,
    /// and contenteditable editors work too.
    private func typeText(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let ref = try args.required("ref")
        let text = try args.required("text")
        try await type(text, into: ref, clear: args["clear"]?.bool ?? true, in: webView)
        var result = "Typed \(text.count) characters into \(ref)."
        let field = try await callAgent(webView, "fieldValue(ref)", ["ref": ref]) as? [String: Any]
        if let value = field?["value"] as? String, value != text {
            result += " The field now contains " + Self.quoted(value, masked: field?["masked"] as? Bool ?? true) + "."
        }
        if args["submit"]?.bool == true {
            try WebViewInput.press("Enter", modifiers: [], in: webView)
            await settle(tab)
            result += "\nPressed Enter.\n\(pageState(tab))"
        }
        return Self.text(result)
    }

    private func type(_ text: String, into ref: String, clear: Bool, in webView: WKWebView) async throws {
        guard try await callAgent(webView, "focusTextField(ref)", ["ref": ref]) as? Bool == true else {
            throw ToolFailure("Couldn't focus \(ref); the page moved focus elsewhere.")
        }
        webView.window?.makeFirstResponder(webView)
        let placement = clear ? #selector(NSText.selectAll(_:)) : #selector(NSResponder.moveToEndOfDocument(_:))
        webView.tryToPerform(placement, with: nil)
        if text.isEmpty {
            if clear { try WebViewInput.press("Backspace", modifiers: [], in: webView) }
        } else {
            webView.insertText(text)
        }
    }

    private func fillForm(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let fields = args["fields"]?.array ?? []
        var done: [String] = []
        for field in fields {
            let ref = try field.required("ref")
            let value = try field.required("value")
            do {
                switch try await callAgent(webView, "fieldKind(ref)", ["ref": ref]) as? String {
                case "text":
                    try await type(value, into: ref, clear: true, in: webView)
                    done.append("\(ref): typed \(value.count) characters")
                case "checkbox", "radio":
                    guard let checked = Bool(value.lowercased()) else {
                        throw ToolFailure("\(ref) is a checkbox or radio button; its value must be \"true\" or \"false\".")
                    }
                    _ = try await callAgent(webView, "setChecked(ref, checked)", ["ref": ref, "checked": checked])
                    done.append("\(ref): \(checked ? "checked" : "unchecked")")
                case "select":
                    let chosen = try await callAgent(webView, "selectOptions(ref, values)", ["ref": ref, "values": [value]])
                    done.append("\(ref): selected \((chosen as? [String])?.joined(separator: ", ") ?? value)")
                default:
                    throw ToolFailure("\(ref) is not a form field.")
                }
            } catch {
                let progress = done.isEmpty ? "" : " Already filled: \(done.joined(separator: "; "))."
                throw ToolFailure("Couldn't fill \(ref): \(Self.message(for: error))\(progress)")
            }
        }
        await settle(tab)
        return Self.text("Filled \(done.count) fields:\n" + done.map { "- \($0)" }.joined(separator: "\n"))
    }

    private func selectOption(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let ref = try args.required("ref")
        let values = args["values"]?.array?.compactMap(\.string) ?? []
        let chosen = try await callAgent(webView, "selectOptions(ref, values)", ["ref": ref, "values": values]) as? [String] ?? []
        await settle(tab)
        return Self.text("Selected \(chosen.map { "\"\($0)\"" }.joined(separator: ", ")) in \(ref).\n\(pageState(tab))")
    }

    private func pressKey(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let key = try args.required("key")
        let modifierNames = args["modifiers"]?.array?.compactMap(\.string) ?? []
        webView.window?.makeFirstResponder(webView)
        try WebViewInput.press(key, modifiers: try WebViewInput.modifierFlags(modifierNames), in: webView)
        await settle(tab)
        let chord = (modifierNames + [key]).joined(separator: "+")
        return Self.text("Pressed \(chord).\n\(pageState(tab))")
    }

    private func scroll(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let direction = args["direction"]?.string ?? "down"
        let amount = args["amount"]?.number ?? 600
        let ref: Any = args["ref"]?.string ?? NSNull()
        let position = try await callAgent(
            webView, "scroll(ref, direction, amount)", ["ref": ref, "direction": direction, "amount": amount]) as? [String: Any] ?? [:]
        let top = position["top"] as? Int ?? 0
        let height = position["height"] as? Int ?? 0
        let viewport = position["viewportHeight"] as? Int ?? 0
        let target = (position["scrolledElement"] as? String).map { " inside \($0)" } ?? ""
        return Self.text("Scrolled \(direction)\(target). Now \(top) px from the top of \(height) px (\(viewport) px visible).")
    }

    private func screenshot(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        if args["full_page"]?.bool == true {
            let height = try await webView.callAsyncJavaScript(
                "return document.scrollingElement?.scrollHeight ?? document.documentElement.scrollHeight",
                in: nil, contentWorld: world) as? Double ?? 0
            configuration.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: max(webView.bounds.height, height * webView.pageZoom))
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        let png = try Self.downscaledPNG(image, maxEdge: 1568)
        return ToolOutcome(content: [
            .image(dataBase64: png.data.base64EncodedString(), mimeType: "image/png"),
            .text(text: "Screenshot of \(Self.address(tab)) (\(png.width)×\(png.height) px)."),
        ], isError: false)
    }

    private func waitFor(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        let text = args["text"]?.string
        let gone = args["text_gone"]?.string
        let seconds = min(args["seconds"]?.number ?? (text == nil && gone == nil ? 1 : 10), 30)
        guard text != nil || gone != nil else {
            try await Task.sleep(for: .seconds(seconds))
            return Self.text("Waited \(Self.format(seconds)) s.\n\(pageState(tab))")
        }
        let start = ContinuousClock.now
        while true {
            let pageText = try await callAgent(webView, "pageText()") as? String ?? ""
            let appeared = text.map(pageText.contains) ?? true
            let disappeared = gone.map { !pageText.contains($0) } ?? true
            let elapsed = ContinuousClock.now - start
            if appeared && disappeared {
                let what = [text.map { "\"\($0)\" appeared" }, gone.map { "\"\($0)\" is gone" }].compactMap { $0 }
                return Self.text("\(what.joined(separator: " and ")) after \(Self.format(elapsed)) s.")
            }
            if elapsed > .seconds(seconds) {
                let what = [text.map { "\"\($0)\" to appear" }, gone.map { "\"\($0)\" to disappear" }].compactMap { $0 }
                throw ToolFailure("Waited \(Self.format(seconds)) s for \(what.joined(separator: " and ")); it didn't happen.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func respondToDialog(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        let tab = try accessibleTab(args, session)
        guard let dialog = tab.pendingDialog else { throw ToolFailure("No dialog is open in this tab.") }
        let accept = args["accept"]?.bool ?? true
        var text = args["text"]?.string
        if case .prompt(let defaultText) = dialog.kind, accept, text == nil {
            text = defaultText
        }
        let kind = Self.kindName(dialog.kind)
        dialog.respond(accepted: accept, text: text)
        await settle(tab)
        return Self.text("\(accept ? "Accepted" : "Dismissed") the \(kind) dialog \"\(dialog.message)\".\n\(pageState(tab))")
    }

    private func evaluate(_ args: JSONValue, _ session: AgentSession) async throws -> ToolOutcome {
        guard settings.agentCanEvaluateJavaScript else {
            throw ToolFailure("Running JavaScript is turned off. The user can allow it in Settings ▸ Claude.")
        }
        let tab = try accessibleTab(args, session)
        let webView = try prepareWebView(tab)
        var expression = try args.required("expression").trimmingCharacters(in: .whitespacesAndNewlines)
        while expression.hasSuffix(";") { expression.removeLast() }
        let body = """
            let value = (
            \(expression)
            );
            if (typeof value === 'function') value = value();
            value = await value;
            if (value === undefined) return 'undefined';
            if (value instanceof Node) return value.outerHTML?.slice(0, 5000) ?? String(value);
            return JSON.stringify(value, null, 2) ?? String(value);
            """
        do {
            let result = try await webView.callAsyncJavaScript(body, in: nil, contentWorld: .page) as? String ?? "null"
            return Self.text(result.count > 20_000 ? String(result.prefix(20_000)) + "\n… (cut at 20000 characters)" : result)
        } catch {
            let message = Self.message(for: error)
            let hint = message.contains("SyntaxError") ? "\nevaluate takes one expression; wrap statements in (async () => { … })()." : ""
            throw ToolFailure("JavaScript error: \(message)\(hint)")
        }
    }

    // MARK: - History and bookmarks

    private func searchHistory(_ args: JSONValue, _ session: AgentSession) throws -> ToolOutcome {
        guard settings.agentCanReadHistory else {
            throw ToolFailure("History access is turned off. The user can allow it in Settings ▸ Claude.")
        }
        let query = try args.required("query")
        let entries = try profile(session).store.searchHistory(query: query, limit: Self.limit(args))
        guard !entries.isEmpty else { return Self.text("No history matches \"\(query)\".") }
        let formatter = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return Self.text(entries.map { entry in
            let visited = Date(timeIntervalSince1970: Double(entry.lastVisitMs) / 1000).formatted(formatter)
            return "- \(entry.title ?? "(untitled)") — \(entry.url) (last visited \(visited), \(entry.visitCount) visits)"
        }.joined(separator: "\n"))
    }

    private func searchBookmarks(_ args: JSONValue, _ session: AgentSession) throws -> ToolOutcome {
        guard settings.agentCanReadHistory else {
            throw ToolFailure("Bookmark access is turned off. The user can allow it in Settings ▸ Claude.")
        }
        let query = try args.required("query")
        let bookmarks = try profile(session).store.searchBookmarks(query: query, limit: Self.limit(args))
        guard !bookmarks.isEmpty else { return Self.text("No bookmarks match \"\(query)\".") }
        return Self.text(bookmarks.map { "- \($0.title) — \($0.url ?? "(folder)")" }.joined(separator: "\n"))
    }

    private func profile(_ session: AgentSession) -> Profile {
        session.currentTab.flatMap { canAccess($0, for: session) ? $0.profile : nil } ?? AppServices.shared.profiles.defaultProfile
    }

    // MARK: - Page scripts

    private func callAgent(_ webView: WKWebView, _ call: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let body = Self.snapshotScript + "\nreturn await globalThis.__bambooAgent.\(call);"
        do {
            return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            throw ToolFailure(Self.message(for: error))
        }
    }

    private func readPage(_ webView: WKWebView) async throws -> String {
        do {
            let markdown = try await webView.callAsyncJavaScript(
                "return (\n\(Self.readScript)\n);", in: nil, contentWorld: world) as? String ?? ""
            return markdown.isEmpty ? "(The page has no readable text.)" : markdown
        } catch {
            throw ToolFailure(Self.message(for: error))
        }
    }

    /// The element's centre in the web view's coordinates (points, top-left origin).
    private func actionPoint(_ ref: String, in webView: WKWebView, blockContextMenu: Bool) async throws -> CGPoint {
        let arguments: [String: Any] = ["ref": ref, "blockContextMenu": blockContextMenu]
        guard let point = try await callAgent(webView, "actionPoint(ref, blockContextMenu)", arguments) as? [String: Double],
              let x = point["x"], let y = point["y"]
        else { throw ToolFailure("Couldn't locate \(ref) on the page.") }
        let scale = (point["scale"] ?? 1) * webView.pageZoom
        return CGPoint(x: (x - (point["offsetLeft"] ?? 0)) * scale, y: (y - (point["offsetTop"] ?? 0)) * scale)
    }

    // MARK: - Waiting

    /// Waits until the tab stops loading (or opens a dialog). Returns false on timeout.
    private func waitForLoad(_ tab: Tab, limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        try? await Task.sleep(for: .milliseconds(150))
        while tab.isLoading && tab.pendingDialog == nil {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Gives the page a moment to react to input, and to finish a navigation it started.
    private func settle(_ tab: Tab) async {
        try? await Task.sleep(for: .milliseconds(300))
        if tab.isLoading {
            _ = await waitForLoad(tab, limit: .seconds(10))
        }
    }

    private func withTimeout(
        _ limit: Duration, tool: String, _ body: @escaping @MainActor () async -> ToolOutcome
    ) async -> ToolOutcome {
        await withCheckedContinuation { continuation in
            let race = Race(continuation)
            race.work = Task { race.finish(await body()) }
            race.timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                race.finish(Self.failure("\(tool) didn't finish within \(limit.components.seconds) s."))
            }
        }
    }

    // MARK: - Activity

    private func record(_ activity: AgentActivity) {
        recentActivity.insert(activity, at: 0)
        if recentActivity.count > Self.activityLimit {
            recentActivity.removeLast()
        }
        guard let tabID = activity.tabID else { return }
        activityByTab[tabID, default: []].insert(activity, at: 0)
        if activityByTab[tabID, default: []].count > Self.activityLimit {
            activityByTab[tabID]?.removeLast()
        }
        // Drop the logs of closed tabs now and then.
        if activityByTab.count > 50 {
            let open = Set(windows.allTabs.map(\.id))
            activityByTab = activityByTab.filter { open.contains($0.key) }
        }
    }

    private static func summary(_ tool: String, _ args: JSONValue) -> String {
        let ref = args["ref"]?.string ?? ""
        switch tool {
        case "navigate", "tab_open": return args["url"]?.string ?? "blank page"
        case "click": return args["double_click"]?.bool == true ? "double-click \(ref)" : ref
        case "hover", "select_option": return ref
        case "type_text": return "\(args["text"]?.string?.count ?? 0) characters into \(ref)"
        case "fill_form": return "\(args["fields"]?.array?.count ?? 0) fields"
        case "press_key": return ((args["modifiers"]?.array?.compactMap(\.string) ?? []) + [args["key"]?.string ?? ""]).joined(separator: "+")
        case "scroll": return args["direction"]?.string ?? "down"
        case "wait_for": return args["text"]?.string ?? args["text_gone"]?.string ?? "\(format(args["seconds"]?.number ?? 1)) s"
        case "dialog_respond": return args["accept"]?.bool == false ? "dismiss" : "accept"
        case "evaluate": return String((args["expression"]?.string ?? "").prefix(60))
        case "history_search", "bookmarks_search": return args["query"]?.string ?? ""
        default: return ""
        }
    }

    // MARK: - Formatting

    private func pageState(_ tab: Tab) -> String {
        var lines = ["Title: \(Self.title(tab))", "URL: \(Self.address(tab))"]
        if let dialog = tab.pendingDialog {
            lines.append(Self.dialogNotice(dialog))
        } else if tab.isLoading {
            lines.append("The page is still loading.")
        }
        return lines.joined(separator: "\n")
    }

    private static func dialogNotice(_ dialog: JavaScriptDialog) -> String {
        "The page is showing a \(kindName(dialog.kind)) dialog: \"\(dialog.message)\". Answer it with dialog_respond first."
    }

    private static func kindName(_ kind: JavaScriptDialog.Kind) -> String {
        switch kind {
        case .alert: "alert"
        case .confirm: "confirm"
        case .prompt: "prompt"
        }
    }

    private static func id(_ tab: Tab) -> String { tab.id.uuidString.lowercased() }
    private static func title(_ tab: Tab) -> String { tab.title.isEmpty ? "(untitled)" : tab.title }
    private static func address(_ tab: Tab) -> String { tab.url?.absoluteString ?? "about:blank" }

    private static func quoted(_ value: String, masked: Bool) -> String {
        if masked { return "\(value.count) hidden characters" }
        return value.count > 300 ? "\"\(value.prefix(300))…\"" : "\"\(value)\""
    }

    private static func format(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func format(_ duration: Duration) -> String {
        format(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private static func limit(_ args: JSONValue) -> UInt32 {
        UInt32(max(1, min(args["limit"]?.number ?? 20, 100)))
    }

    /// Web pages only: a `file:` URL would let read_page read the user's local
    /// files. (`javascript:` text never parses as a URL; it becomes a search.)
    private static func url(from text: String) throws -> URL {
        switch AddressInput.parse(text) {
        case .url(let url):
            guard url.scheme == "http" || url.scheme == "https" else {
                throw ToolFailure("Agents can open only http and https pages, not \(url.scheme ?? "this"): URLs.")
            }
            return url
        case .search(let query): return SearchEngine.engine(AppServices.shared.settings.searchEngine).searchURL(for: query)
        case nil: throw ToolFailure("\"\(text)\" is not a URL.")
        }
    }

    private static func text(_ text: String) -> ToolOutcome {
        ToolOutcome(content: [.text(text: text)], isError: false)
    }

    private static func failure(_ message: String) -> ToolOutcome {
        ToolOutcome(content: [.text(text: message)], isError: true)
    }

    private static func message(for error: Error) -> String {
        if let failure = error as? ToolFailure { return failure.message }
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
        }
        return error.localizedDescription
    }

    private static func timeLimit(_ tool: String, _ args: JSONValue) -> Duration {
        switch tool {
        case "navigate", "go_back", "go_forward", "reload", "tab_open": .seconds(40)
        case "wait_for": .seconds(min(args["seconds"]?.number ?? 10, 30) + 10)
        case "fill_form": .seconds(60)
        default: .seconds(30)
        }
    }

    private static func loadScript(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            preconditionFailure("\(name).js is missing from the app bundle")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            preconditionFailure("Cannot read \(name).js: \(error)")
        }
    }

    private static func downscaledPNG(_ image: NSImage, maxEdge: CGFloat) throws -> (data: Data, width: Int, height: Int) {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ToolFailure("The screenshot could not be read.")
        }
        let scale = min(1, maxEdge / CGFloat(max(source.width, source.height)))
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ToolFailure("The screenshot could not be resized.") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
        else { throw ToolFailure("The screenshot could not be encoded as PNG.") }
        return (data, width, height)
    }
}

struct ToolFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Resumes a continuation with whichever of the work or the timer finishes first.
@MainActor
private final class Race {
    private var continuation: CheckedContinuation<ToolOutcome, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<ToolOutcome, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: ToolOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        work?.cancel()
        timer?.cancel()
        continuation.resume(returning: outcome)
    }
}

extension JSONValue {
    /// A string argument the tool can't run without.
    func required(_ key: String) throws -> String {
        guard let value = self[key]?.string else { throw ToolFailure("Missing \"\(key)\".") }
        return value
    }
}
