import SwiftUI

struct DownloadsSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(settings.askWhereToSaveDownloads ? "Chosen for each download" : "Downloads folder")
                        .foregroundStyle(.secondary)
                }
                Toggle("Ask where to save each file before downloading", isOn: $settings.askWhereToSaveDownloads)
            }
        }
        .formStyle(.grouped)
    }
}
