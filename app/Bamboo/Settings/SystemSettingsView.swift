import SwiftUI

struct SystemSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    private static let defaultTimeout = 30
    private static let timeouts = [5, 15, 30, 60, 120, 240]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding {
                    settings.hibernateAfterMinutes > 0
                } set: { isOn in
                    settings.hibernateAfterMinutes = isOn ? Self.defaultTimeout : 0
                }) {
                    Text("Memory Saver")
                    Text("Frees memory from tabs you haven’t used for a while. They reload where you left off when you go back. Tabs playing media or using the camera or microphone stay loaded.")
                }
                if settings.hibernateAfterMinutes > 0 {
                    Picker("Free memory from tabs inactive for", selection: $settings.hibernateAfterMinutes) {
                        ForEach(Self.timeouts, id: \.self) { minutes in
                            Text(Self.describe(minutes)).tag(minutes)
                        }
                    }
                }
            } header: {
                Text("Performance")
            }

            Section {
                Toggle("Warn me before quitting", isOn: $settings.warnBeforeQuitting)
            }

            Section {
                Toggle(isOn: $settings.developerToolsEnabled) {
                    Text("Developer tools")
                    Text("Adds Inspect Element to the page menu and lets Safari’s Web Inspector attach. Applies to tabs opened after you change it.")
                }
            } header: {
                Text("Developers")
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ minutes: Int) -> String {
        switch minutes {
        case ..<60: "\(minutes) minutes"
        case 60: "1 hour"
        default: "\(minutes / 60) hours"
        }
    }
}
