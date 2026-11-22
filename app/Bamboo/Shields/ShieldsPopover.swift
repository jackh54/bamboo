import SwiftUI

/// Per-site shields controls, shown from the address bar's shields badge.
struct ShieldsPopover: View {
    let tab: Tab

    var body: some View {
        Text("\(tab.blockedRequestCount) blocked") // STUB(phase1)
            .padding()
    }
}
