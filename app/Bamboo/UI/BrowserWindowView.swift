import SwiftUI

/// Root view of a browser window. STUB(phase1): minimal layout, replaced by the full UI.
struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel
    @State private var address = ""

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                List(model.selectedSpace.allTabs) { tab in
                    Button(tab.title.isEmpty ? (tab.url?.host() ?? "New Tab") : tab.title) {
                        model.select(tab)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: Theme.Metrics.sidebarWidth)
            }
            VStack(spacing: 0) {
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                    .onSubmit(openAddress)
                if let tab = model.selectedTab, tab.url != nil {
                    WebContentView(tab: tab)
                } else {
                    Color.clear
                }
            }
            if model.isAssistantVisible {
                AssistantPanel(window: model)
                    .frame(width: Theme.Metrics.assistantWidth)
            }
        }
        .sheet(isPresented: $model.isClearBrowsingDataVisible) {
            ClearBrowsingDataView(window: model)
        }
    }

    private func openAddress() {
        guard let input = AddressInput.parse(address) else { return }
        let url = switch input {
        case .url(let url): url
        case .search(let query): SearchEngine.engine(AppServices.shared.settings.searchEngine).searchURL(for: query)
        }
        if let tab = model.selectedTab {
            tab.load(url)
        } else {
            model.newTab(url: url)
        }
    }
}
