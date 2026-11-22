import SwiftUI

/// Brave-style tabs across the title bar: pinned tabs as favicons at the
/// left, then tabs that share the width and shrink as they multiply, then
/// the new-tab button. The selected tab joins the toolbar below it.
struct TabStrip: View {
    let model: BrowserWindowModel
    let height: CGFloat

    private static let newTabButtonWidth: CGFloat = 36
    private static let trailingRoom: CGFloat = 16

    var body: some View {
        let space = model.selectedSpace
        GeometryReader { proxy in
            let leading = Theme.Metrics.trafficLightsWidth + 6
            let pinnedWidth = CGFloat(space.pinnedTabs.count) * Theme.Metrics.pinnedTabWidth
            let room = proxy.size.width - leading - pinnedWidth - Self.newTabButtonWidth - Self.trailingRoom
                - 2 * Theme.Metrics.tabFlare
            let range = Theme.Metrics.tabWidthRange
            let tabWidth = min(max(room / CGFloat(max(space.tabs.count, 1)), range.lowerBound), range.upperBound)
            let tabsWidth = tabWidth * CGFloat(space.tabs.count)
            let selectedIndex = space.allTabs.firstIndex { $0.id == space.selectedTabID }

            HStack(alignment: .bottom, spacing: 0) {
                // The traffic lights' corner, left to the title bar so it drags the window.
                Spacer().frame(width: leading - Theme.Metrics.tabFlare)
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(Array(space.pinnedTabs.enumerated()), id: \.element.id) { index, tab in
                            StripTab(tab: tab, model: model, width: Theme.Metrics.pinnedTabWidth,
                                     isSelected: index == selectedIndex, showsSeparator: false,
                                     dropIndex: index, isPinned: true)
                        }
                        ForEach(Array(space.tabs.enumerated()), id: \.element.id) { index, tab in
                            let position = space.pinnedTabs.count + index
                            StripTab(tab: tab, model: model, width: tabWidth,
                                     isSelected: position == selectedIndex,
                                     showsSeparator: index > 0 && position != selectedIndex && position - 1 != selectedIndex,
                                     dropIndex: index, isPinned: false)
                        }
                    }
                    .padding(.horizontal, Theme.Metrics.tabFlare)
                    .frame(height: height, alignment: .bottom)
                }
                .scrollIndicators(.never)
                .scrollContentBackground(.hidden)
                .scrollDisabled(tabsWidth <= room)
                .frame(width: min(pinnedWidth + tabsWidth, pinnedWidth + max(room, 0)) + 2 * Theme.Metrics.tabFlare)
                NewTabButton(model: model)
                    .frame(width: Self.newTabButtonWidth, height: height)
                Spacer(minLength: 0)
            }
            .animation(Theme.Motion.spring, value: space.allTabs.map(\.id))
        }
        .frame(height: height)
    }
}

private struct StripTab: View {
    let tab: Tab
    let model: BrowserWindowModel
    let width: CGFloat
    let isSelected: Bool
    let showsSeparator: Bool
    let dropIndex: Int
    let isPinned: Bool
    @State private var isHovered = false
    @State private var isDropTargeted = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let isCompact = isPinned || width < 76
        let showsClose = !isPinned && (isHovered || isSelected) && width >= 62
        HStack(spacing: 7) {
            TabIcon(tab: tab, size: 16)
            if !isCompact {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .mask {
                        // Long titles fade out instead of ending in an ellipsis.
                        LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                if tab.isAgentControlled, width > 150 {
                    AgentBadge(tab: tab)
                }
            }
            if showsClose {
                Button { model.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.chrome(size: 18))
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, isCompact ? 0 : 11)
        .frame(width: width, height: Theme.Metrics.tabHeight, alignment: isCompact ? .center : .leading)
        .background {
            if isSelected {
                ConnectedTabShape(cornerRadius: 9, flare: Theme.Metrics.tabFlare)
                    .fill(Theme.Colors.toolbar)
                    .padding(.horizontal, -Theme.Metrics.tabFlare)
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: -0.5)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Colors.hoverRow)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 1, height: 16)
                .padding(.bottom, 4)
                .opacity(showsSeparator && !isHovered ? 0.7 : 0)
        }
        .overlay {
            if tab.isAgentControlled {
                AgentGlow(cornerRadius: 9)
                    .padding(.horizontal, 2)
                    .padding(.bottom, isSelected ? 0 : 4)
            }
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 2, height: 20)
                .offset(x: -1)
                .opacity(isDropTargeted ? 1 : 0)
        }
        .opacity(tab.isHibernated && tab.url != nil && !isSelected ? 0.62 : 1)
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isHovered)
        .help(tab.displayTitle)
        .contextMenu { TabContextMenu(tab: tab, model: model) }
        .draggable(tab.id.uuidString) {
            Label(tab.displayTitle, systemImage: "rectangle.on.rectangle").padding(8)
        }
        .dropDestination(for: String.self) { ids, _ in
            model.dropTab(ids, at: dropIndex, pinned: isPinned)
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(tab) }
    }
}

/// The selected tab: rounded on top, flaring out at the bottom into the toolbar.
private struct ConnectedTabShape: Shape {
    let cornerRadius: CGFloat
    let flare: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + flare
        let right = rect.maxX - flare
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left, y: rect.minY), radius: flare)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.minY), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: cornerRadius)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: flare)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NewTabButton: View {
    let model: BrowserWindowModel

    var body: some View {
        Button {
            NSApp.sendAction(#selector(BrowserWindowController.newTab(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.chrome(size: 28))
        .help("New Tab (⌘T)")
        .padding(.bottom, 2)
        // Dropping a tab here moves it to the end.
        .dropDestination(for: String.self) { ids, _ in
            model.dropTab(ids, at: model.selectedSpace.tabs.count, pinned: false)
        }
    }
}
