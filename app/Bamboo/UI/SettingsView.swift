import SwiftUI

struct SettingsView: View {
    @Bindable var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection.section) { section in
                Text(section.rawValue).tag(section)
            }
        } detail: {
            switch selection.section {
            case .agents: AgentSettingsView()
            default: Text(selection.section.rawValue) // STUB(phase1)
            }
        }
    }
}
