import SwiftUI

struct ContentSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    private static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Form {
            Section {
                Picker("Autoplay", selection: $settings.autoplayPolicy) {
                    Text("Allow all").tag(AutoplayPolicy.allow)
                    Text("Block audio and video with sound").tag(AutoplayPolicy.blockAudible)
                    Text("Block all").tag(AutoplayPolicy.blockAll)
                }
            } header: {
                Text("Media")
            } footer: {
                Text("Applies to tabs opened after you change it.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Page zoom", selection: $settings.defaultPageZoom) {
                    ForEach(Self.zoomLevels, id: \.self) { level in
                        Text(level.formatted(.percent.precision(.fractionLength(0)))).tag(level)
                    }
                }
            } footer: {
                Text("Sites with a zoom of their own keep it. Applies to tabs opened after you change it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
