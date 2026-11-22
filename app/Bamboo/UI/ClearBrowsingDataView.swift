import SwiftUI

/// Sheet for History > Clear Browsing Data…, presented by BrowserWindowView.
struct ClearBrowsingDataView: View {
    let window: BrowserWindowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            Text("Clear Browsing Data") // STUB(phase1)
            Button("Done") { dismiss() }
        }
        .padding()
    }
}
