import Foundation
import Observation

enum StartupBehavior: String, CaseIterable, Codable, Sendable {
    case restoreSession, newTab
}

enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark
}

enum SidebarPosition: String, CaseIterable, Codable, Sendable {
    case left, right
}

/// Brave's "Use vertical tabs": tabs across the top, or the sidebar.
enum TabLayout: String, CaseIterable, Codable, Sendable {
    case horizontal, vertical
}

/// Brave's "Show bookmarks" choice for the bookmarks bar.
enum BookmarksBarVisibility: String, CaseIterable, Codable, Sendable {
    case always, never, newTabOnly
}

enum ReaderFont: String, CaseIterable, Codable, Sendable {
    case serif, sans
}

enum ReaderTheme: String, CaseIterable, Codable, Sendable {
    /// Light or dark, following the window's appearance.
    case system, light, sepia, dark
}

enum HTTPSMode: String, CaseIterable, Codable, Sendable {
    /// Try HTTPS first and fall back to HTTP when the site has no HTTPS.
    case upgrade
    /// Refuse plain HTTP unless the user approves it per site.
    case httpsOnly
}

enum AutoplayPolicy: String, CaseIterable, Codable, Sendable {
    case allow, blockAudible, blockAll
}

enum AgentAccess: String, CaseIterable, Codable, Sendable {
    /// Agents control only tabs they opened or that the user handed over.
    case agentTabsOnly
    /// Agents can see and control every non-private tab.
    case allTabs
}

/// User preferences, persisted in UserDefaults. A key that was never written
/// takes the default shown here.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    // General
    var startupBehavior: StartupBehavior { didSet { save(startupBehavior.rawValue, .startupBehavior) } }
    /// Minutes before an unused background tab is unloaded to free memory; 0 disables.
    var hibernateAfterMinutes: Int { didSet { save(hibernateAfterMinutes, .hibernateAfterMinutes) } }
    var askWhereToSaveDownloads: Bool { didSet { save(askWhereToSaveDownloads, .askWhereToSaveDownloads) } }
    var warnBeforeQuitting: Bool { didSet { save(warnBeforeQuitting, .warnBeforeQuitting) } }

    // Appearance
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, .appearance) } }
    var sidebarPosition: SidebarPosition { didSet { save(sidebarPosition.rawValue, .sidebarPosition) } }
    var showFullURLs: Bool { didSet { save(showFullURLs, .showFullURLs) } }
    /// Width the user dragged the sidebar to, within `Theme.Metrics.sidebarWidthRange`.
    var sidebarWidth: Double { didSet { save(sidebarWidth, .sidebarWidth) } }

    // Tabs and toolbar
    var tabLayout: TabLayout { didSet { save(tabLayout.rawValue, .tabLayout) } }
    var bookmarksBar: BookmarksBarVisibility { didSet { save(bookmarksBar.rawValue, .bookmarksBar) } }
    var showHomeButton: Bool { didSet { save(showHomeButton, .showHomeButton) } }

    // New tab page (Customize on the page itself)
    var newTabShowsBackground: Bool { didSet { save(newTabShowsBackground, .newTabShowsBackground) } }
    var newTabShowsClock: Bool { didSet { save(newTabShowsClock, .newTabShowsClock) } }
    var newTabShowsStats: Bool { didSet { save(newTabShowsStats, .newTabShowsStats) } }
    var newTabShowsTopSites: Bool { didSet { save(newTabShowsTopSites, .newTabShowsTopSites) } }

    // Reader
    var readerFont: ReaderFont { didSet { save(readerFont.rawValue, .readerFont) } }
    var readerFontSize: Int { didSet { save(readerFontSize, .readerFontSize) } }
    var readerTheme: ReaderTheme { didSet { save(readerTheme.rawValue, .readerTheme) } }

    // Content
    /// Zoom for pages without a zoom of their own in site settings; 1 is 100%.
    var defaultPageZoom: Double { didSet { save(defaultPageZoom, .defaultPageZoom) } }

    // Shields defaults; a site can turn shields down from the Shields panel.
    var blockTrackersAndAds: Bool { didSet { save(blockTrackersAndAds, .blockTrackersAndAds) } }
    var blockScripts: Bool { didSet { save(blockScripts, .blockScripts) } }

    // Search
    var searchEngine: SearchEngineID { didSet { save(searchEngine.rawValue, .searchEngine) } }
    var searchSuggestionsEnabled: Bool { didSet { save(searchSuggestionsEnabled, .searchSuggestionsEnabled) } }

    // Privacy
    var stripTrackingParameters: Bool { didSet { save(stripTrackingParameters, .stripTrackingParameters) } }
    var globalPrivacyControl: Bool { didSet { save(globalPrivacyControl, .globalPrivacyControl) } }
    var httpsMode: HTTPSMode { didSet { save(httpsMode.rawValue, .httpsMode) } }
    var autoplayPolicy: AutoplayPolicy { didSet { save(autoplayPolicy.rawValue, .autoplayPolicy) } }
    var clearDataOnQuit: Bool { didSet { save(clearDataOnQuit, .clearDataOnQuit) } }

    // Passwords
    var offerToSavePasswords: Bool { didSet { save(offerToSavePasswords, .offerToSavePasswords) } }
    var autofillPasswords: Bool { didSet { save(autofillPasswords, .autofillPasswords) } }
    /// Sites where the user chose "Never for This Site" when offered to save a password.
    var neverSavePasswordHosts: [String] { didSet { save(neverSavePasswordHosts, .neverSavePasswordHosts) } }

    // AI and agents
    var agentServerEnabled: Bool { didSet { save(agentServerEnabled, .agentServerEnabled) } }
    var agentAccess: AgentAccess { didSet { save(agentAccess.rawValue, .agentAccess) } }
    var agentCanEvaluateJavaScript: Bool { didSet { save(agentCanEvaluateJavaScript, .agentCanEvaluateJavaScript) } }
    var agentCanReadHistory: Bool { didSet { save(agentCanReadHistory, .agentCanReadHistory) } }
    var assistantModel: String { didSet { save(assistantModel, .assistantModel) } }
    var assistantEffort: String { didSet { save(assistantEffort, .assistantEffort) } }

    // Advanced
    var developerToolsEnabled: Bool { didSet { save(developerToolsEnabled, .developerToolsEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startupBehavior = StartupBehavior(rawValue: defaults.string(forKey: Key.startupBehavior.rawValue) ?? "") ?? .restoreSession
        hibernateAfterMinutes = defaults.object(forKey: Key.hibernateAfterMinutes.rawValue) as? Int ?? 30
        askWhereToSaveDownloads = defaults.object(forKey: Key.askWhereToSaveDownloads.rawValue) as? Bool ?? false
        warnBeforeQuitting = defaults.object(forKey: Key.warnBeforeQuitting.rawValue) as? Bool ?? false
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance.rawValue) ?? "") ?? .system
        sidebarPosition = SidebarPosition(rawValue: defaults.string(forKey: Key.sidebarPosition.rawValue) ?? "") ?? .left
        showFullURLs = defaults.object(forKey: Key.showFullURLs.rawValue) as? Bool ?? false
        sidebarWidth = defaults.object(forKey: Key.sidebarWidth.rawValue) as? Double ?? Double(Theme.Metrics.sidebarWidth)
        tabLayout = TabLayout(rawValue: defaults.string(forKey: Key.tabLayout.rawValue) ?? "") ?? .horizontal
        bookmarksBar = BookmarksBarVisibility(rawValue: defaults.string(forKey: Key.bookmarksBar.rawValue) ?? "") ?? .newTabOnly
        showHomeButton = defaults.object(forKey: Key.showHomeButton.rawValue) as? Bool ?? false
        newTabShowsBackground = defaults.object(forKey: Key.newTabShowsBackground.rawValue) as? Bool ?? true
        newTabShowsClock = defaults.object(forKey: Key.newTabShowsClock.rawValue) as? Bool ?? true
        newTabShowsStats = defaults.object(forKey: Key.newTabShowsStats.rawValue) as? Bool ?? true
        newTabShowsTopSites = defaults.object(forKey: Key.newTabShowsTopSites.rawValue) as? Bool ?? true
        readerFont = ReaderFont(rawValue: defaults.string(forKey: Key.readerFont.rawValue) ?? "") ?? .serif
        readerFontSize = defaults.object(forKey: Key.readerFontSize.rawValue) as? Int ?? 19
        readerTheme = ReaderTheme(rawValue: defaults.string(forKey: Key.readerTheme.rawValue) ?? "") ?? .system
        defaultPageZoom = defaults.object(forKey: Key.defaultPageZoom.rawValue) as? Double ?? 1
        blockTrackersAndAds = defaults.object(forKey: Key.blockTrackersAndAds.rawValue) as? Bool ?? true
        blockScripts = defaults.object(forKey: Key.blockScripts.rawValue) as? Bool ?? false
        searchEngine = SearchEngineID(rawValue: defaults.string(forKey: Key.searchEngine.rawValue) ?? "") ?? .duckDuckGo
        searchSuggestionsEnabled = defaults.object(forKey: Key.searchSuggestionsEnabled.rawValue) as? Bool ?? true
        stripTrackingParameters = defaults.object(forKey: Key.stripTrackingParameters.rawValue) as? Bool ?? true
        globalPrivacyControl = defaults.object(forKey: Key.globalPrivacyControl.rawValue) as? Bool ?? true
        httpsMode = HTTPSMode(rawValue: defaults.string(forKey: Key.httpsMode.rawValue) ?? "") ?? .upgrade
        autoplayPolicy = AutoplayPolicy(rawValue: defaults.string(forKey: Key.autoplayPolicy.rawValue) ?? "") ?? .blockAudible
        clearDataOnQuit = defaults.object(forKey: Key.clearDataOnQuit.rawValue) as? Bool ?? false
        offerToSavePasswords = defaults.object(forKey: Key.offerToSavePasswords.rawValue) as? Bool ?? true
        autofillPasswords = defaults.object(forKey: Key.autofillPasswords.rawValue) as? Bool ?? true
        neverSavePasswordHosts = defaults.stringArray(forKey: Key.neverSavePasswordHosts.rawValue) ?? []
        agentServerEnabled = defaults.object(forKey: Key.agentServerEnabled.rawValue) as? Bool ?? true
        agentAccess = AgentAccess(rawValue: defaults.string(forKey: Key.agentAccess.rawValue) ?? "") ?? .agentTabsOnly
        agentCanEvaluateJavaScript = defaults.object(forKey: Key.agentCanEvaluateJavaScript.rawValue) as? Bool ?? false
        agentCanReadHistory = defaults.object(forKey: Key.agentCanReadHistory.rawValue) as? Bool ?? false
        assistantModel = defaults.string(forKey: Key.assistantModel.rawValue) ?? "claude-opus-5-5"
        assistantEffort = defaults.string(forKey: Key.assistantEffort.rawValue) ?? "medium"
        developerToolsEnabled = defaults.object(forKey: Key.developerToolsEnabled.rawValue) as? Bool ?? false
    }

    private enum Key: String {
        case startupBehavior, hibernateAfterMinutes, askWhereToSaveDownloads, warnBeforeQuitting
        case appearance, sidebarPosition, showFullURLs, sidebarWidth
        case tabLayout, bookmarksBar, showHomeButton
        case newTabShowsBackground, newTabShowsClock, newTabShowsStats, newTabShowsTopSites
        case readerFont, readerFontSize, readerTheme
        case defaultPageZoom, blockTrackersAndAds, blockScripts
        case searchEngine, searchSuggestionsEnabled
        case stripTrackingParameters, globalPrivacyControl, httpsMode, autoplayPolicy, clearDataOnQuit
        case offerToSavePasswords, autofillPasswords, neverSavePasswordHosts
        case agentServerEnabled, agentAccess, agentCanEvaluateJavaScript, agentCanReadHistory
        case assistantModel, assistantEffort
        case developerToolsEnabled
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
