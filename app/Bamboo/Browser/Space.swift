import Foundation
import Observation

/// Accent colours a space can use. The UI maps each to its palette in `Theme`.
enum SpaceTint: String, CaseIterable, Codable, Sendable {
    case bamboo, ocean, sunset, lavender, rose, graphite
}

/// A named set of tabs bound to one profile (like Arc's spaces). Pinned tabs
/// stay at the top of the sidebar; each space remembers its own selected tab.
@MainActor
@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    var symbol: String
    var tint: SpaceTint
    var profile: Profile
    var pinnedTabs: [Tab] = []
    var tabs: [Tab] = []
    var selectedTabID: Tab.ID?

    init(id: UUID = UUID(), name: String, symbol: String, tint: SpaceTint, profile: Profile) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.profile = profile
    }

    var allTabs: [Tab] { pinnedTabs + tabs }

    var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return allTabs.first { $0.id == selectedTabID }
    }

    func contains(_ tab: Tab) -> Bool {
        allTabs.contains { $0 === tab }
    }
}
