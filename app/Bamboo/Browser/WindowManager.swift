import AppKit
import Observation
import WebKit

/// Owns every browser window. Agents, external URL opens and session restore
/// go through here.
@MainActor
@Observable
final class WindowManager {
    private(set) var controllers: [BrowserWindowController] = []
    @ObservationIgnored private weak var lastActiveController: BrowserWindowController?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var models: [BrowserWindowModel] { controllers.map(\.model) }

    /// The key window's model, else the most recently active window.
    var frontmost: BrowserWindowModel? {
        if let key = NSApp.keyWindow?.windowController as? BrowserWindowController { return key.model }
        return lastActiveController?.model ?? controllers.last?.model
    }

    var frontmostNonPrivate: BrowserWindowModel? {
        if let front = frontmost, !front.isPrivate { return front }
        return controllers.last { !$0.model.isPrivate }?.model
    }

    var allTabs: [Tab] { models.flatMap(\.allTabs) }

    // MARK: - Windows

    @discardableResult
    func newWindow(isPrivate: Bool = false) -> BrowserWindowModel {
        let model = BrowserWindowModel(profile: AppServices.shared.profiles.defaultProfile, isPrivate: isPrivate)
        show(model, frame: nil)
        model.newTab()
        return model
    }

    func show(_ model: BrowserWindowModel, frame: NSRect?) {
        let controller = BrowserWindowController(model: model)
        if let frame {
            controller.window?.setFrame(frame, display: false)
        } else if let front = NSApp.keyWindow {
            controller.window?.setFrameTopLeftPoint(
                NSPoint(x: front.frame.minX + 24, y: front.frame.maxY - 24))
        } else {
            controller.window?.center()
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    func controller(for model: BrowserWindowModel) -> BrowserWindowController? {
        controllers.first { $0.model === model }
    }

    func windowDidBecomeKey(_ controller: BrowserWindowController) {
        lastActiveController = controller
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        controller.model.tearDown()
        controllers.removeAll { $0 === controller }
        sessionDidChange()
    }

    /// Opens a URL handed to us by another app.
    func open(_ url: URL) {
        let model = frontmostNonPrivate ?? newWindow()
        if let tab = model.selectedTab, tab.url == nil {
            tab.load(url)
        } else {
            model.newTab(url: url)
        }
        controller(for: model)?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Tabs

    func windowModel(containing tab: Tab) -> BrowserWindowModel? {
        models.first { $0.space(containing: tab) != nil }
    }

    func tab(id: UUID) -> Tab? {
        allTabs.first { $0.id == id }
    }

    func tab(for webView: WKWebView?) -> Tab? {
        (webView as? BambooWebView)?.tab
    }

    /// Opens a background tab for an AI agent in the frontmost normal window.
    /// The web view is created at once so the agent can work while it is hidden.
    func openAgentTab(url: URL?) -> Tab {
        let model = frontmostNonPrivate ?? newWindow()
        let tab = model.newTab(url: url, select: model.selectedTab == nil)
        tab.isAgentControlled = true
        tab.ensureWebView()
        return tab
    }

    /// Selects the tab and brings its window to the front.
    func focus(_ tab: Tab) {
        guard let model = windowModel(containing: tab) else { return }
        model.select(tab)
        controller(for: model)?.window?.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        windowModel(containing: tab)?.close(tab)
    }

    /// Unloads background tabs that have not been looked at for `minutes`.
    func hibernateIdleTabs(olderThan minutes: Int) async {
        let cutoff = Date.now.addingTimeInterval(-Double(minutes) * 60)
        for model in models {
            let visible = model.selectedTab
            for tab in model.allTabs where tab !== visible && !tab.isHibernated
                && !tab.isAgentControlled && tab.lastActivatedAt < cutoff {
                await tab.hibernate()
            }
        }
    }

    // MARK: - Session restore

    /// Saves the session shortly after the last change.
    func sessionDidChange() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    func saveSession() {
        saveTask?.cancel()
        let windows = controllers.filter { !$0.model.isPrivate }.map { controller in
            WindowSessionState(model: controller.model, frame: controller.window?.frame ?? .zero)
        }
        SessionStore.save(SessionState(windows: windows))
    }

    /// Recreates the windows from the last session. Tabs come back hibernated
    /// and only the selected tab of each window loads.
    func restoreSession() -> Bool {
        guard let session = SessionStore.load(), !session.windows.isEmpty else { return false }
        let profiles = AppServices.shared.profiles
        for window in session.windows {
            let spaces = window.spaces.map { state -> Space in
                let profile = profiles.profile(id: state.profileID) ?? profiles.defaultProfile
                let space = Space(id: state.id, name: state.name, symbol: state.symbol, tint: state.tint, profile: profile)
                space.pinnedTabs = state.pinnedTabs.map { Tab(restoring: $0, profile: profile, dataStore: profile.dataStore) }
                space.tabs = state.tabs.map { Tab(restoring: $0, profile: profile, dataStore: profile.dataStore) }
                space.selectedTabID = state.selectedTabID
                return space
            }
            guard let first = spaces.first else { continue }
            let selected = spaces.contains { $0.id == window.selectedSpaceID } ? window.selectedSpaceID : first.id
            let model = BrowserWindowModel(isPrivate: false, spaces: spaces, selectedSpaceID: selected)
            show(model, frame: window.frame.isEmpty ? nil : window.frame)
            if let tab = model.selectedTab {
                model.select(tab)
            }
        }
        return !controllers.isEmpty
    }
}

struct SessionState: Codable {
    var windows: [WindowSessionState]
}

struct WindowSessionState: Codable {
    var frame: NSRect
    var selectedSpaceID: UUID
    var spaces: [SpaceSessionState]

    @MainActor
    init(model: BrowserWindowModel, frame: NSRect) {
        self.frame = frame
        selectedSpaceID = model.selectedSpaceID
        spaces = model.spaces.map(SpaceSessionState.init(space:))
    }
}

struct SpaceSessionState: Codable {
    var id: UUID
    var name: String
    var symbol: String
    var tint: SpaceTint
    var profileID: UUID
    var selectedTabID: UUID?
    var pinnedTabs: [TabSessionState]
    var tabs: [TabSessionState]

    @MainActor
    init(space: Space) {
        id = space.id
        name = space.name
        symbol = space.symbol
        tint = space.tint
        profileID = space.profile.id
        selectedTabID = space.selectedTabID
        pinnedTabs = space.pinnedTabs.map(\.sessionState)
        tabs = space.tabs.filter { $0.url != nil }.map(\.sessionState)
    }
}

enum SessionStore {
    static func save(_ session: SessionState) {
        do {
            let data = try JSONEncoder().encode(session)
            try data.write(to: AppPaths.sessionFile, options: .atomic)
        } catch {
            NSLog("Bamboo: failed to save session: \(error)")
        }
    }

    /// Returns nil when there is no saved session. A corrupt file is moved
    /// aside (so the next save doesn't overwrite the evidence) and reported.
    static func load() -> SessionState? {
        let url = AppPaths.sessionFile
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: url))
        } catch {
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            NSLog("Bamboo: could not read session (moved to \(aside.lastPathComponent)): \(error)")
            return nil
        }
    }
}
