import SwiftUI

/// The Settings window: Brave's sections in Brave's order, in a native sidebar.
struct SettingsView: View {
    @Bindable var selection: SettingsSelection
    /// Lives here rather than in the import dialog so an import survives closing it.
    @State private var importModel = ImportModel()

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.sidebar, selection: $selection.section) { section in
                SettingsSidebarRow(section: section)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationTitle(selection.section.title)
        }
        .frame(minWidth: 740, minHeight: 520)
        .sheet(isPresented: $selection.isImportPresented) {
            ImportView(model: importModel)
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection.section {
        case .getStarted, .importData: GetStartedSettingsView(selection: selection)
        case .appearance: AppearanceSettingsView()
        case .content: ContentSettingsView()
        case .shields: ShieldsSettingsView()
        case .privacy: PrivacySettingsView()
        case .agents: AgentSettingsView()
        case .search: SearchSettingsView()
        case .extensions: ExtensionsSettingsView()
        case .passwords: PasswordsSettingsView()
        case .downloads: DownloadsSettingsView()
        case .system: SystemSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            Image(systemName: section.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(section.tint.gradient, in: .rect(cornerRadius: 5))
        }
    }
}

extension SettingsSection {
    static let sidebar: [SettingsSection] = allCases.filter { $0 != .importData }

    var title: String {
        switch self {
        case .getStarted: "Get started"
        case .appearance: "Appearance"
        case .content: "Content"
        case .shields: "Shields"
        case .privacy: "Privacy and security"
        case .agents: "Claude"
        case .search: "Search engine"
        case .extensions: "Extensions"
        case .passwords: "Autofill and passwords"
        case .downloads: "Downloads"
        case .system: "System"
        case .about: "About Bamboo"
        case .importData: "Import bookmarks and settings"
        }
    }

    var symbol: String {
        switch self {
        case .getStarted: "flag.fill"
        case .appearance: "paintbrush.fill"
        case .content: "textformat.size"
        case .shields: "shield.lefthalf.filled"
        case .privacy: "hand.raised.fill"
        case .agents: "sparkles"
        case .search: "magnifyingglass"
        case .extensions: "puzzlepiece.extension.fill"
        case .passwords: "key.fill"
        case .downloads: "arrow.down.circle.fill"
        case .system: "gearshape.fill"
        case .about: "info.circle.fill"
        case .importData: "square.and.arrow.down.fill"
        }
    }

    var tint: Color {
        let tint: SpaceTint = switch self {
        case .getStarted, .shields: .bamboo
        case .appearance, .agents: .lavender
        case .content, .search, .downloads, .importData: .ocean
        case .privacy: .ocean
        case .extensions, .passwords: .sunset
        case .system, .about: .graphite
        }
        return Theme.palette(tint).accent
    }
}
