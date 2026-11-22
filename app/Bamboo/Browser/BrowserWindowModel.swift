import Foundation
import Observation
import WebKit

/// Panels shown over the page area.
enum LibraryPanel: String, Sendable {
    case history, bookmarks, downloads
}

/// State of one browser window: its spaces and tabs, and which UI is showing.
/// A tab whose `url` is nil shows the new tab page.
@MainActor
@Observable
final class BrowserWindowModel: Identifiable {
    let id = UUID()
    let isPrivate: Bool
    /// Private windows keep cookies and site data in memory only.
    @ObservationIgnored let privateDataStore: WKWebsiteDataStore?

    var spaces: [Space]
    var selectedSpaceID: Space.ID

    var isSidebarVisible = true
    var isAssistantVisible = false
    var isCommandPaletteVisible = false
    var isFindBarVisible = false
    var findQuery = ""
    /// Whether the last find step matched anything (nil before the first search).
    var findQueryMatched: Bool?
    var isClearBrowsingDataVisible = false
    var libraryPanel: LibraryPanel?
    /// Incremented to ask the address bar to take keyboard focus.
    var addressBarFocusRequest = 0
    /// Text for the Claude panel to send next (from the address bar or a context
    /// menu). The panel opens, sends it and sets this back to nil.
    var pendingAssistantPrompt: String?

    struct ClosedTab {
        let state: TabSessionState
        let spaceID: Space.ID
        let index: Int
    }
    private(set) var recentlyClosed: [ClosedTab] = []
    private static let recentlyClosedLimit = 25

    init(isPrivate: Bool, spaces: [Space], selectedSpaceID: Space.ID) {
        precondition(!spaces.isEmpty, "A window needs at least one space")
        self.isPrivate = isPrivate
        privateDataStore = isPrivate ? .nonPersistent() : nil
        self.spaces = spaces
        self.selectedSpaceID = selectedSpaceID
    }

    convenience init(profile: Profile, isPrivate: Bool) {
        let space = Space(
            name: isPrivate ? "Private" : profile.name,
            symbol: isPrivate ? "eye.slash" : "leaf",
            tint: isPrivate ? .graphite : .bamboo,
            profile: profile)
        self.init(isPrivate: isPrivate, spaces: [space], selectedSpaceID: space.id)
    }

    var selectedSpace: Space {
        guard let space = spaces.first(where: { $0.id == selectedSpaceID }) else {
            preconditionFailure("selectedSpaceID \(selectedSpaceID) is not in this window")
        }
        return space
    }

    var selectedTab: Tab? { selectedSpace.selectedTab }

    var allTabs: [Tab] { spaces.flatMap(\.allTabs) }

    func space(containing tab: Tab) -> Space? {
        spaces.first { $0.contains(tab) }
    }

    func dataStore(for space: Space) -> WKWebsiteDataStore {
        privateDataStore ?? space.profile.dataStore
    }

    // MARK: - Opening and selecting tabs

    /// Opens a tab. With an `anchor` it goes right after that tab (and in its space).
    @discardableResult
    func newTab(url: URL? = nil, after anchor: Tab? = nil, select: Bool = true, in space: Space? = nil) -> Tab {
        let space = space ?? anchor.flatMap(self.space(containing:)) ?? selectedSpace
        let tab = Tab(profile: space.profile, isPrivate: isPrivate, dataStore: dataStore(for: space), url: url)
        insert(tab, after: anchor, select: select, in: space)
        return tab
    }

    func insert(_ tab: Tab, after anchor: Tab?, select: Bool, in space: Space? = nil) {
        let space = space ?? anchor.flatMap(self.space(containing:)) ?? selectedSpace
        if let anchor, let index = space.tabs.firstIndex(where: { $0 === anchor }) {
            space.tabs.insert(tab, at: index + 1)
        } else if let anchor, anchor.isPinned {
            space.tabs.insert(tab, at: 0)
        } else {
            space.tabs.append(tab)
        }
        if select {
            self.select(tab)
        }
        sessionChanged()
    }

    func select(_ tab: Tab) {
        guard let space = space(containing: tab) else { return }
        selectedSpaceID = space.id
        space.selectedTabID = tab.id
        tab.lastActivatedAt = .now
        if tab.url != nil {
            tab.ensureWebView()
        }
        sessionChanged()
    }

    func selectSpace(_ space: Space) {
        selectedSpaceID = space.id
        if let tab = space.selectedTab {
            select(tab)
        }
    }

    /// ⌘1…⌘8 select the nth tab of the current space (pinned first); ⌘9 selects the last.
    func selectTab(atShortcutIndex index: Int) {
        let tabs = selectedSpace.allTabs
        guard !tabs.isEmpty else { return }
        let target = index >= 9 ? tabs[tabs.count - 1] : tabs[safe: index - 1]
        if let target {
            select(target)
        }
    }

    func selectAdjacentTab(offset: Int) {
        let tabs = selectedSpace.allTabs
        guard !tabs.isEmpty else { return }
        let current = selectedTab.flatMap { tab in tabs.firstIndex { $0 === tab } } ?? 0
        let next = (current + offset % tabs.count + tabs.count) % tabs.count
        select(tabs[next])
    }

    // MARK: - Closing

    func close(_ tab: Tab) {
        guard let space = space(containing: tab) else { return }
        let wasSelected = space.selectedTabID == tab.id
        let ordered = space.allTabs
        let orderedIndex = ordered.firstIndex { $0 === tab } ?? 0

        let indexInList: Int
        if let index = space.pinnedTabs.firstIndex(where: { $0 === tab }) {
            indexInList = index
            space.pinnedTabs.remove(at: index)
        } else if let index = space.tabs.firstIndex(where: { $0 === tab }) {
            indexInList = index
            space.tabs.remove(at: index)
        } else {
            return
        }

        if !isPrivate, tab.url != nil {
            recentlyClosed.append(ClosedTab(state: tab.sessionState, spaceID: space.id, index: indexInList))
            if recentlyClosed.count > Self.recentlyClosedLimit {
                recentlyClosed.removeFirst()
            }
        }
        tab.close()

        if wasSelected {
            let remaining = space.allTabs
            space.selectedTabID = nil
            if !remaining.isEmpty {
                select(remaining[min(orderedIndex, remaining.count - 1)])
            }
        }
        sessionChanged()
    }

    var canReopenClosedTab: Bool { !recentlyClosed.isEmpty }

    func reopenLastClosedTab() {
        guard let closed = recentlyClosed.popLast() else { return }
        let space = spaces.first { $0.id == closed.spaceID } ?? selectedSpace
        let tab = Tab(restoring: closed.state, profile: space.profile, dataStore: dataStore(for: space))
        if tab.isPinned {
            space.pinnedTabs.insert(tab, at: min(closed.index, space.pinnedTabs.count))
        } else {
            space.tabs.insert(tab, at: min(closed.index, space.tabs.count))
        }
        select(tab)
    }

    // MARK: - Arranging

    func togglePin(_ tab: Tab) {
        guard let space = space(containing: tab) else { return }
        if tab.isPinned {
            space.pinnedTabs.removeAll { $0 === tab }
            space.tabs.insert(tab, at: 0)
        } else {
            space.tabs.removeAll { $0 === tab }
            space.pinnedTabs.append(tab)
        }
        tab.isPinned.toggle()
        sessionChanged()
    }

    /// Moves a tab within its space to `index` of the pinned or regular list.
    func move(_ tab: Tab, to index: Int, pinned: Bool) {
        guard let space = space(containing: tab) else { return }
        space.pinnedTabs.removeAll { $0 === tab }
        space.tabs.removeAll { $0 === tab }
        tab.isPinned = pinned
        if pinned {
            space.pinnedTabs.insert(tab, at: min(max(index, 0), space.pinnedTabs.count))
        } else {
            space.tabs.insert(tab, at: min(max(index, 0), space.tabs.count))
        }
        sessionChanged()
    }

    func duplicate(_ tab: Tab) {
        guard let space = space(containing: tab) else { return }
        var state = tab.sessionState
        state.id = UUID()
        state.isPinned = false
        let copy = Tab(restoring: state, profile: space.profile, dataStore: dataStore(for: space))
        insert(copy, after: tab, select: true, in: space)
    }

    // MARK: - Spaces

    @discardableResult
    func addSpace(name: String, symbol: String, tint: SpaceTint, profile: Profile) -> Space {
        let space = Space(name: name, symbol: symbol, tint: tint, profile: profile)
        spaces.append(space)
        selectSpace(space)
        sessionChanged()
        return space
    }

    func removeSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        space.allTabs.forEach { $0.close() }
        spaces.removeAll { $0 === space }
        if selectedSpaceID == space.id {
            selectSpace(spaces[0])
        }
        sessionChanged()
    }

    /// Closes every tab when the window goes away.
    func tearDown() {
        allTabs.forEach { $0.close() }
    }

    private func sessionChanged() {
        guard !isPrivate else { return }
        AppServices.shared.windows.sessionDidChange()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
