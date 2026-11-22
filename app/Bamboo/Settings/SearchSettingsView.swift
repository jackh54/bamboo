import SwiftUI

struct SearchSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    private var engine: SearchEngine { SearchEngine.engine(settings.searchEngine) }

    var body: some View {
        Form {
            Section {
                Picker("Search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.all) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Search engine used in the address bar")
            } footer: {
                Text("Bamboo searches with it when what you type isn’t a web address.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show search suggestions", isOn: $settings.searchSuggestionsEnabled)
                    .disabled(!engine.supportsSuggestions)
            } footer: {
                Text(engine.supportsSuggestions
                     ? "As you type in the address bar, Bamboo sends what you type to \(engine.name) to suggest searches."
                     : "\(engine.name) doesn’t offer search suggestions.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
