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
        searchEngine = SearchEngineID(rawValue: defaults.string(forKey: Key.searchEngine.rawValue) ?? "") ?? .duckDuckGo
        searchSuggestionsEnabled = defaults.object(forKey: Key.searchSuggestionsEnabled.rawValue) as? Bool ?? true
        stripTrackingParameters = defaults.object(forKey: Key.stripTrackingParameters.rawValue) as? Bool ?? true
        globalPrivacyControl = defaults.object(forKey: Key.globalPrivacyControl.rawValue) as? Bool ?? true
        httpsMode = HTTPSMode(rawValue: defaults.string(forKey: Key.httpsMode.rawValue) ?? "") ?? .upgrade
        autoplayPolicy = AutoplayPolicy(rawValue: defaults.string(forKey: Key.autoplayPolicy.rawValue) ?? "") ?? .blockAudible
        clearDataOnQuit = defaults.object(forKey: Key.clearDataOnQuit.rawValue) as? Bool ?? false
        offerToSavePasswords = defaults.object(forKey: Key.offerToSavePasswords.rawValue) as? Bool ?? true
        autofillPasswords = defaults.object(forKey: Key.autofillPasswords.rawValue) as? Bool ?? true
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
        case appearance, sidebarPosition, showFullURLs
        case searchEngine, searchSuggestionsEnabled
        case stripTrackingParameters, globalPrivacyControl, httpsMode, autoplayPolicy, clearDataOnQuit
        case offerToSavePasswords, autofillPasswords
        case agentServerEnabled, agentAccess, agentCanEvaluateJavaScript, agentCanReadHistory
        case assistantModel, assistantEffort
        case developerToolsEnabled
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
