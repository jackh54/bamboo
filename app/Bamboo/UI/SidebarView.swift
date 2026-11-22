import AppKit
import SwiftUI

/// The sidebar: window controls, the address pill, pinned tabs, the tab list
/// and the space switcher. It sits on the translucent window backdrop.
struct SidebarView: View {
    let model: BrowserWindowModel
    /// On the window's leading edge, where the traffic lights are.
    let isLeading: Bool
    let titlebarHeight: CGFloat

    var body: some View {
        let space = model.selectedSpace
        VStack(spacing: 8) {
            SidebarControls(model: model, leavesRoomForTrafficLights: isLeading)
                .frame(height: titlebarHeight)
            AddressPill(model: model)
            ScrollView(.vertical) {
                TabSections(model: model, space: space)
                    .id(space.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .scrollIndicators(.automatic)
            .scrollContentBackground(.hidden)
            SidebarBottomBar(model: model)
        }
        .padding(.bottom, 6)
    }
}

// MARK: - Controls

private struct SidebarControls: View {
    let model: BrowserWindowModel
    let leavesRoomForTrafficLights: Bool

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 2) {
            if leavesRoomForTrafficLights {
                Color.clear.frame(width: Theme.Metrics.trafficLightsWidth - Theme.Metrics.contentInset)
            }
            // Left empty so the title bar underneath still drags and zooms the window.
            Spacer()
            Button {
                withAnimation(Theme.Motion.spring) { model.isSidebarVisible = false }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Hide Sidebar (⌃⌘S)")
            Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!(tab?.canGoBack ?? false))
                .help("Back")
            Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!(tab?.canGoForward ?? false))
                .help("Forward")
            Button {
                guard let tab else { return }
                if tab.isLoading { tab.stopLoading() } else { tab.reload() }
            } label: {
                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(tab?.url == nil)
            .help(tab?.isLoading == true ? "Stop" : "Reload")
        }
        .buttonStyle(.chrome)
    }
}

/// The page's address at the top of the sidebar. Clicking it opens the command bar.
struct AddressPill: View {
    let model: BrowserWindowModel
    /// The smaller pill used in the title strip when the sidebar is hidden.
    var isCompact = false
    @State private var isHovered = false

    var body: some View {
        let tab = model.selectedTab
        HStack(spacing: 4) {
            Button {
                model.addressBarFocusRequest += 1
            } label: {
                HStack(spacing: 7) {
                    SecurityIcon(tab: tab)
                    Text(addressText(tab))
                        .font(.system(size: isCompact ? 12 : 12.5, weight: .medium))
                        .foregroundStyle(tab?.url == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 11)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Search or enter address (⌘L)")

            if let tab, tab.url != nil {
                ShieldsBadge(tab: tab, height: isCompact ? 18 : 26)
                    .padding(.trailing, 3)
            }
        }
        .frame(height: isCompact ? 24 : Theme.Metrics.addressPillHeight)
        .background {
            RoundedRectangle(cornerRadius: isCompact ? 7 : 9, style: .continuous)
                .fill(isHovered ? Theme.Colors.pressedRow : Theme.Colors.field)
        }
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isHovered)
    }

    private func addressText(_ tab: Tab?) -> String {
        guard let url = tab?.url else { return "Search or enter address" }
        if AppServices.shared.settings.showFullURLs { return url.absoluteString }
        guard let host = url.host() else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct SecurityIcon: View {
    let tab: Tab?

    var body: some View {
        let (symbol, label, warns) = state
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(warns ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(width: 12)
            .accessibilityLabel(label)
    }

    private var state: (String, String, Bool) {
        guard let tab, let url = tab.url else { return ("magnifyingglass", "Search", false) }
        if tab.loadError != nil { return ("exclamationmark.circle", "The page didn't load", false) }
        switch url.scheme {
        case "https": return tab.hasOnlySecureContent || tab.isLoading
            ? ("lock.fill", "Secure connection", false)
            : ("lock.slash", "Some content on this page isn't secure", true)
        case "http": return ("lock.open.fill", "Not secure", true)
        case "file": return ("doc", "Local file", false)
        default: return ("globe", url.scheme ?? "Page", false)
        }
    }
}

private struct ShieldsBadge: View {
    let tab: Tab
    let height: CGFloat
    @Environment(\.spaceAccent) private var accent
    @State private var isPresented = false

    var body: some View {
        let count = tab.blockedRequestCount
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "shield.lefthalf.filled")
                if count > 0 {
                    Text(count, format: .number)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(count > 0 ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(count > 0 ? accent.opacity(0.13) : .clear, in: Capsule())
            .contentShape(Capsule())
            .animation(Theme.Motion.quick, value: count)
        }
        .buttonStyle(.plain)
        .help(count == 1 ? "Shields blocked 1 request" : "Shields blocked \(count) requests")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ShieldsPopover(tab: tab)
        }
    }
}

// MARK: - Tabs

private struct TabSections: View {
    let model: BrowserWindowModel
    let space: Space
    @State private var isPinZoneTargeted = false
    @State private var isEndZoneTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !space.pinnedTabs.isEmpty {
                PinnedTabsGrid(model: model, space: space)
                    .padding(.bottom, 6)
            }
            pinZone
            if !space.pinnedTabs.isEmpty {
                Divider()
                    .opacity(0.6)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }

            LazyVStack(spacing: 1) {
                ForEach(Array(space.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabRow(tab: tab, model: model, isSelected: space.selectedTabID == tab.id, index: index)
                }
            }
            NewTabRow()
                .dropDestination(for: String.self) { ids, _ in
                    model.dropTab(ids, at: space.tabs.count, pinned: false)
                } isTargeted: { isEndZoneTargeted = $0 }
                .overlay(alignment: .top) { InsertionMark(isVisible: isEndZoneTargeted) }
            Color.clear
                .frame(height: 40)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { ids, _ in
                    model.dropTab(ids, at: space.tabs.count, pinned: false)
                } isTargeted: { isEndZoneTargeted = $0 }
        }
        .animation(Theme.Motion.spring, value: space.tabs.map(\.id))
        .animation(Theme.Motion.spring, value: space.pinnedTabs.map(\.id))
    }

    /// A slim target above the list for pinning by drag; it opens up while a tab hovers it.
    private var pinZone: some View {
        HStack(spacing: 6) {
            Image(systemName: "pin")
            Text("Drop to pin")
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: isPinZoneTargeted ? 34 : 4)
        .opacity(isPinZoneTargeted ? 1 : 0)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.tertiary)
                .opacity(isPinZoneTargeted ? 1 : 0)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            model.dropTab(ids, at: space.pinnedTabs.count, pinned: true)
        } isTargeted: { isPinZoneTargeted = $0 }
        .animation(Theme.Motion.quick, value: isPinZoneTargeted)
    }
}

private struct InsertionMark: View {
    let isVisible: Bool
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        Capsule()
            .fill(accent)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .offset(y: -1)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct TabRow: View {
    let tab: Tab
    let model: BrowserWindowModel
    let isSelected: Bool
    let index: Int
    @State private var isHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 9) {
            TabIcon(tab: tab, size: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if tab.isAgentControlled {
                AgentBadge(tab: tab)
            }
            if isHovered {
                Button { model.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                }
                .buttonStyle(.chrome(size: 20))
                .help("Close Tab (⌘W)")
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: Theme.Metrics.tabRowHeight)
        .background { TabBackground(isSelected: isSelected, isHovered: isHovered) }
        .overlay { if tab.isAgentControlled { AgentGlow(cornerRadius: 9) } }
        .overlay(alignment: .top) { InsertionMark(isVisible: isDropTargeted) }
        .opacity(tab.isHibernated && tab.url != nil && !isSelected ? 0.62 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isHovered)
        .contextMenu { TabContextMenu(tab: tab, model: model) }
        .draggable(tab.id.uuidString) {
            Label(tab.displayTitle, systemImage: "rectangle.on.rectangle")
                .padding(8)
        }
        .dropDestination(for: String.self) { ids, _ in
            model.dropTab(ids, at: index, pinned: false)
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.select(tab) }
    }
}

private struct PinnedTabsGrid: View {
    let model: BrowserWindowModel
    let space: Space

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 50), spacing: 6)], spacing: 6) {
            ForEach(Array(space.pinnedTabs.enumerated()), id: \.element.id) { index, tab in
                PinnedTile(tab: tab, model: model, isSelected: space.selectedTabID == tab.id, index: index)
            }
        }
    }
}

private struct PinnedTile: View {
    let tab: Tab
    let model: BrowserWindowModel
    let isSelected: Bool
    let index: Int
    @State private var isHovered = false
    @State private var isDropTargeted = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        TabIcon(tab: tab, size: 18)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metrics.pinnedTileHeight)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.Colors.selectedRow : isHovered ? Theme.Colors.pressedRow : Theme.Colors.field)
                    .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1, y: 0.5)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent, lineWidth: 2)
                }
            }
            .overlay { if tab.isAgentControlled { AgentGlow(cornerRadius: 10) } }
            .opacity(tab.isHibernated && !isSelected ? 0.7 : 1)
            .contentShape(Rectangle())
            .onTapGesture { model.select(tab) }
            .onHover { isHovered = $0 }
            .help(tab.displayTitle)
            .contextMenu { TabContextMenu(tab: tab, model: model) }
            .draggable(tab.id.uuidString) { TabIcon(tab: tab, size: 24).padding(8) }
            .dropDestination(for: String.self) { ids, _ in
                model.dropTab(ids, at: index, pinned: true)
            } isTargeted: { isDropTargeted = $0 }
            .accessibilityElement()
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { model.select(tab) }
    }
}

private struct TabBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isSelected ? Theme.Colors.selectedRow : isHovered ? Theme.Colors.hoverRow : .clear)
            .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 1.5, y: 0.5)
    }
}

/// Favicon, or a spinner while the page loads.
struct TabIcon: View {
    let tab: Tab
    let size: CGFloat

    var body: some View {
        ZStack {
            if tab.isLoading && tab.favicon == nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(size / 20)
            } else if tab.url == nil {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
            } else {
                FaviconView(image: tab.favicon, host: tab.url?.host(), size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Marks a tab an AI agent is driving. Clicking it takes the tab back.
struct AgentBadge: View {
    let tab: Tab
    @State private var isHovered = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        Button {
            withAnimation(Theme.Motion.quick) { tab.isAgentControlled = false }
        } label: {
            Text(isHovered ? "Take Back" : "Agent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(accent.opacity(isHovered ? 0.2 : 0.13), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("An agent is controlling this tab. Click to take it back.")
    }
}

/// A slowly breathing outline in the space's tint around agent-controlled tabs.
struct AgentGlow: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceMotion {
            shape.strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                .allowsHitTesting(false)
        } else {
            shape.strokeBorder(accent, lineWidth: 1.5)
                .phaseAnimator([0.35, 0.95]) { content, phase in
                    content
                        .opacity(phase)
                        .shadow(color: accent.opacity(phase * 0.6), radius: 5)
                } animation: { _ in .easeInOut(duration: 1.4) }
                .allowsHitTesting(false)
        }
    }
}

struct TabContextMenu: View {
    let tab: Tab
    let model: BrowserWindowModel

    var body: some View {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") {
            withAnimation(Theme.Motion.spring) { model.togglePin(tab) }
        }
        Button("Duplicate Tab") { model.duplicate(tab) }
            .disabled(tab.url == nil)
        Button("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab.url == nil)
        if !tab.isPrivate {
            Divider()
            Button(tab.isAgentControlled ? "Take Tab Back from Agents" : "Let Agents Control This Tab") {
                tab.isAgentControlled.toggle()
            }
            .disabled(tab.url == nil)
        }
        Divider()
        Button("Close Tab") { model.close(tab) }
        Button("Close Tabs Below") {
            guard let space = model.space(containing: tab),
                  let index = space.allTabs.firstIndex(where: { $0 === tab }) else { return }
            for below in space.allTabs[(index + 1)...] {
                model.close(below)
            }
        }
        .disabled(model.space(containing: tab)?.allTabs.last === tab)
    }
}

private struct NewTabRow: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSApp.sendAction(#selector(BrowserWindowController.newTab(_:)), to: nil, from: nil)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text("New Tab")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: Theme.Metrics.tabRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Theme.Colors.hoverRow : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("New Tab (⌘T)")
    }
}

extension BrowserWindowModel {
    /// Moves a tab dragged within this sidebar (its id as a string) to `index`
    /// of the pinned or regular list.
    func dropTab(_ ids: [String], at index: Int, pinned: Bool) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)),
              let tab = selectedSpace.allTabs.first(where: { $0.id == id })
        else { return false }
        withAnimation(Theme.Motion.spring) { move(tab, to: index, pinned: pinned) }
        return true
    }
}
