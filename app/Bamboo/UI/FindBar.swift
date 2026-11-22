import SwiftUI

/// Find on page (⌘F), floating at the top right of the page. Typing searches
/// as you go; Return finds the next match and ⇧Return the previous one.
struct FindBar: View {
    let model: BrowserWindowModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            CommandField(
                placeholder: "Find on page",
                initialText: model.findQuery,
                fontSize: 13,
                onEdit: { text, _ in
                    model.findQuery = text
                    model.findQueryMatched = nil
                    if !text.isEmpty { model.findInPage(backwards: false) }
                    return nil
                },
                onSubmit: { modifiers in model.findInPage(backwards: modifiers.contains(.shift)) },
                onCancel: { model.closeFindBar() })
                .frame(width: 190)
            if model.findQueryMatched == false {
                Text("Not found")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize()
                    .transition(.opacity)
            }
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)
            Group {
                Button { model.findInPage(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .help("Previous Match (⇧⌘G)")
                Button { model.findInPage(backwards: false) } label: { Image(systemName: "chevron.down") }
                    .help("Next Match (⌘G)")
            }
            .disabled(model.findQuery.isEmpty)
            Button { model.closeFindBar() } label: { Image(systemName: "xmark") }
                .help("Done")
        }
        .buttonStyle(.chrome(size: 24))
        .padding(.horizontal, 6)
        .frame(height: 38)
        .floatingSurface(cornerRadius: 11)
        .animation(Theme.Motion.quick, value: model.findQueryMatched)
    }
}
