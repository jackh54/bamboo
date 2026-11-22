import SwiftUI

struct AppearanceSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        AppearanceChoice(mode: mode, isSelected: settings.appearance == mode) {
                            settings.appearance = mode
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } header: {
                Text("Theme")
            }

            Section("Tabs") {
                Toggle("Use vertical tabs", isOn: Binding {
                    settings.tabLayout == .vertical
                } set: {
                    settings.tabLayout = $0 ? .vertical : .horizontal
                })
                Picker("Sidebar position", selection: $settings.sidebarPosition) {
                    Text("Left").tag(SidebarPosition.left)
                    Text("Right").tag(SidebarPosition.right)
                }
                .pickerStyle(.segmented)
                .disabled(settings.tabLayout != .vertical)
            }

            Section("Toolbar") {
                Toggle("Show home button", isOn: $settings.showHomeButton)
                Picker("Show bookmarks bar", selection: $settings.bookmarksBarVisibility) {
                    Text("Always").tag(BookmarksBarVisibility.always)
                    Text("Never").tag(BookmarksBarVisibility.never)
                    Text("Only on new tab").tag(BookmarksBarVisibility.newTabOnly)
                }
                Toggle(isOn: $settings.showFullURLs) {
                    Text("Always show full URLs")
                    Text("Otherwise the address bar shows just the site’s name.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A miniature browser window in the mode's colours, like System Settings' appearance picker.
private struct AppearanceChoice: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 8) {
                thumbnail
                    .frame(width: 112, height: 72)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                          lineWidth: isSelected ? 3 : 1)
                    }
                Text(title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var title: String {
        switch mode {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @ViewBuilder private var thumbnail: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: 56)
                    }
            }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool

    var body: some View {
        let chrome = dark ? Color(hex: 0x2B2D31) : Color(hex: 0xE9EBEE)
        let page = dark ? Color(hex: 0x1C1D20) : .white
        let line = dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1)
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Theme.palette(.bamboo).accent).frame(width: 18, height: 5)
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(line).frame(width: 22, height: 4)
                }
            }
            .padding(.top, 8)
            .frame(width: 30, alignment: .top)
            RoundedRectangle(cornerRadius: 4)
                .fill(page)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(line).frame(width: 40, height: 5)
                        Capsule().fill(line).frame(width: 52, height: 4)
                        Capsule().fill(line).frame(width: 30, height: 4)
                    }
                    .padding(8)
                }
                .padding(.vertical, 5)
        }
        .padding(.leading, 5)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome)
    }
}
