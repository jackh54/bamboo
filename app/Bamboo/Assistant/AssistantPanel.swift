import SwiftUI

/// The Claude side panel. BrowserWindowView shows it when `window.isAssistantVisible`.
struct AssistantPanel: View {
    let window: BrowserWindowModel

    var body: some View {
        Text("Claude") // STUB(phase1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
