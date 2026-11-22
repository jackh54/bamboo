import SwiftUI

/// Root view of a browser window. By default it is laid out like Brave: tabs
/// across the title bar, a toolbar with the address bar, the bookmarks bar and
/// the page. With vertical tabs (Settings ▸ Appearance ▸ Tabs) the tabs move
/// into a sidebar and the page becomes an inset card.
struct BrowserWindowView: View {
    @Bindable var model: BrowserWindowModel
    /// The floating command bar, which ⌘L and ⌘T open in the vertical layout.
    @State private var isCommandBarVisible = false

    private var settings: AppSettings { AppServices.shared.settings }

    var body: some View {
        let palette = Theme.palette(model.selectedSpace.tint)
        GeometryReader { proxy in
            // The window's toolbar sets the title bar height; full screen has none.
            let titlebarHeight = max(proxy.safeAreaInsets.top, Theme.Metrics.titlebarHeight)
            Group {
                if settings.tabLayout == .vertical {
                    VerticalLayout(model: model, isCommandBarVisible: $isCommandBarVisible, titlebarHeight: titlebarHeight)
                } else {
                    HorizontalLayout(model: model, titlebarHeight: titlebarHeight)
                }
            }
            // The layouts place their own content under the title bar.
            .ignoresSafeArea()
            .transition(.opacity)
        }
        .ignoresSafeArea()
        .environment(\.spaceAccent, palette.accent)
        .tint(palette.accent)
        .animation(Theme.Motion.standard, value: settings.tabLayout)
        .onChange(of: model.addressBarFocusRequest) {
            model.isCommandPaletteVisible = false
            // The horizontal layout's address bar focuses itself.
            if settings.tabLayout == .vertical { isCommandBarVisible = true }
        }
        .onChange(of: model.isCommandPaletteVisible) { _, isVisible in
            if isVisible { isCommandBarVisible = false }
        }
        .sheet(isPresented: $model.isClearBrowsingDataVisible) {
            ClearBrowsingDataView(window: model)
        }
    }
}

// MARK: - Horizontal (Brave)

private struct HorizontalLayout: View {
    let model: BrowserWindowModel
    let titlebarHeight: CGFloat

    var body: some View {
        let showsBookmarksBar = switch AppServices.shared.settings.bookmarksBar {
        case .always: true
        case .never: false
        case .newTabOnly: model.selectedTab?.url == nil
        }
        VStack(spacing: 0) {
            TabStrip(model: model, height: titlebarHeight)
                .background { WindowBackdrop(palette: Theme.palette(model.selectedSpace.tint), isPrivate: model.isPrivate) }
            VStack(spacing: 0) {
                BrowserToolbar(model: model)
                    .zIndex(1)
                if showsBookmarksBar {
                    BookmarksBar(model: model)
                        .transition(.opacity)
                }
            }
            // Stops at the tab strip instead of reaching up into the title bar's safe area.
            .background(Theme.Colors.toolbar, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Colors.hairline).frame(height: 0.5)
            }
            .zIndex(1)
            HStack(spacing: 0) {
                PageContent(model: model, cornerRadius: 0)
                    .overlay { LibraryOverlay(model: model) }
                    .overlay { CommandOverlay(model: model, isCommandBarVisible: .constant(false)) }
                if model.isAssistantVisible {
                    AssistantPanel(window: model)
                        .frame(width: Theme.Metrics.assistantWidth)
                        .background(Theme.Colors.card, ignoresSafeAreaEdges: [])
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.Colors.hairline).frame(width: 0.5)
                        }
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Theme.Colors.card, ignoresSafeAreaEdges: [])
        }
        .animation(Theme.Motion.standard, value: showsBookmarksBar)
        .animation(Theme.Motion.spring, value: model.isAssistantVisible)
    }
}

// MARK: - Vertical (sidebar)

private struct VerticalLayout: View {
    let model: BrowserWindowModel
    @Binding var isCommandBarVisible: Bool
    let titlebarHeight: CGFloat
    /// The sidebar width while the user drags its edge; saved to settings when the drag ends.
    @State private var liveSidebarWidth: CGFloat?
    @State private var dragStartWidth: CGFloat?

    private var settings: AppSettings { AppServices.shared.settings }

    var body: some View {
        let inset = Theme.Metrics.contentInset
        let sidebarLeads = settings.sidebarPosition == .left
        let showsSidebar = model.isSidebarVisible
        let showsTitleStrip = !(showsSidebar && sidebarLeads)

        HStack(spacing: 0) {
            if showsSidebar && sidebarLeads {
                sidebar(leading: true)
            }
            VStack(spacing: 0) {
                if showsTitleStrip {
                    TitleStrip(model: model)
                        .frame(height: titlebarHeight)
                }
                HStack(spacing: inset) {
                    if model.isAssistantVisible && !sidebarLeads {
                        assistantPanel
                    }
                    PageCard(model: model, isCommandBarVisible: $isCommandBarVisible)
                    if model.isAssistantVisible && sidebarLeads {
                        assistantPanel
                    }
                }
                .padding(.top, showsTitleStrip ? 0 : inset)
                .padding(.bottom, inset)
                .padding(.leading, showsSidebar && sidebarLeads ? 0 : inset)
                .padding(.trailing, showsSidebar && !sidebarLeads ? 0 : inset)
            }
            if showsSidebar && !sidebarLeads {
                sidebar(leading: false)
            }
        }
        .animation(Theme.Motion.spring, value: model.isSidebarVisible)
        .animation(Theme.Motion.spring, value: model.isAssistantVisible)
        .animation(Theme.Motion.standard, value: settings.sidebarPosition)
        .background { WindowBackdrop(palette: Theme.palette(model.selectedSpace.tint), isPrivate: model.isPrivate) }
    }

    private var sidebarWidth: CGFloat {
        let range = Theme.Metrics.sidebarWidthRange
        return min(max(liveSidebarWidth ?? settings.sidebarWidth, range.lowerBound), range.upperBound)
    }

    private func sidebar(leading: Bool) -> some View {
        SidebarView(model: model, isLeading: leading, titlebarHeight: titlebarHeight)
            .padding(.horizontal, Theme.Metrics.contentInset)
            .frame(width: sidebarWidth)
            .overlay(alignment: leading ? .trailing : .leading) { resizeHandle(leading: leading) }
            .transition(.move(edge: leading ? .leading : .trailing).combined(with: .opacity))
    }

    private func resizeHandle(leading: Bool) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStartWidth ?? sidebarWidth
                        dragStartWidth = start
                        liveSidebarWidth = start + (leading ? drag.translation.width : -drag.translation.width)
                    }
                    .onEnded { _ in
                        settings.sidebarWidth = Double(sidebarWidth)
                        liveSidebarWidth = nil
                        dragStartWidth = nil
                    })
            .accessibilityHidden(true)
    }

    private var assistantPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.contentCornerRadius, style: .continuous)
        return AssistantPanel(window: model)
            .frame(width: Theme.Metrics.assistantWidth)
            .frame(maxHeight: .infinity)
            .background(Theme.Colors.card, ignoresSafeAreaEdges: [])
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
            .shadow(color: Theme.Colors.cardShadow, radius: 1, y: 0.5)
            .transition(.move(edge: settings.sidebarPosition == .left ? .trailing : .leading).combined(with: .opacity))
    }
}

/// The translucent window material with a wash of the space's colour.
private struct WindowBackdrop: View {
    let palette: Theme.Palette
    let isPrivate: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.13 : 0.18
        ZStack {
            VisualEffectBackground(material: .sidebar)
            LinearGradient(
                colors: [palette.gradient[0].opacity(strength), palette.gradient[1].opacity(strength * 0.35)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if isPrivate {
                Color.black.opacity(colorScheme == .dark ? 0.25 : 0.06)
            } else if colorScheme == .dark {
                Color.black.opacity(0.18)
            }
        }
        .animation(Theme.Motion.standard, value: palette.accent)
    }
}

/// The strip above the page card when the traffic lights have no sidebar to
/// sit in: the sidebar is hidden or on the right.
private struct TitleStrip: View {
    let model: BrowserWindowModel

    var body: some View {
        let tab = model.selectedTab
        ZStack {
            if model.isSidebarVisible {
                Text(tab?.displayTitle ?? "New Tab")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Metrics.trafficLightsWidth + 8)
                    .allowsHitTesting(false)
            } else {
                AddressPill(model: model, isCompact: true)
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 200)
                HStack(spacing: 2) {
                    Spacer().frame(width: Theme.Metrics.trafficLightsWidth)
                    Button {
                        withAnimation(Theme.Motion.spring) { model.isSidebarVisible = true }
                    } label: {
                        Image(systemName: AppServices.shared.settings.sidebarPosition == .left ? "sidebar.left" : "sidebar.right")
                    }
                    .help("Show Sidebar (⌃⌘S)")
                    Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!(tab?.canGoBack ?? false))
                        .help("Back")
                    Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!(tab?.canGoForward ?? false))
                        .help("Forward")
                    // Left empty so the title bar underneath still drags and zooms the window.
                    Spacer()
                }
                .buttonStyle(.chrome(size: 24))
            }
        }
    }
}

/// The page as a rounded card, with everything that floats over it.
private struct PageCard: View {
    let model: BrowserWindowModel
    @Binding var isCommandBarVisible: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.contentCornerRadius, style: .continuous)
        PageContent(model: model, cornerRadius: Theme.Metrics.contentCornerRadius)
            .clipShape(shape)
            .background {
                shape.fill(Theme.Colors.card)
                    .shadow(color: Theme.Colors.cardShadow, radius: 1, y: 0.5)
                    .shadow(color: Theme.Colors.cardShadow.opacity(0.6), radius: 12, y: 3)
            }
            .overlay { shape.strokeBorder(Theme.Colors.hairline, lineWidth: 0.5).allowsHitTesting(false) }
            .overlay { LibraryOverlay(model: model) }
            .overlay { CommandOverlay(model: model, isCommandBarVisible: $isCommandBarVisible) }
    }
}

// MARK: - Page

private struct PageContent: View {
    let model: BrowserWindowModel
    let cornerRadius: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            if let tab = model.selectedTab, tab.url != nil {
                WebContentView(tab: tab, cornerRadius: cornerRadius)
                TabOverlays(tab: tab, model: model)
                    .id(tab.id)
            } else {
                NewTabPage(model: model)
            }
            if let tab = model.selectedTab {
                VStack(spacing: 0) {
                    LoadingBar(tab: tab)
                    if tab.passwordSaveOffer != nil {
                        PasswordSaveBanner(tab: tab)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.spring, value: tab.passwordSaveOffer)
            }
            if model.isFindBarVisible, model.selectedTab?.url != nil {
                FindBar(model: model)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.spring, value: model.isFindBarVisible)
    }
}

/// The command palette (⌘K) and, in the vertical layout, the command bar
/// (⌘L, ⌘T), centred over the page.
private struct CommandOverlay: View {
    let model: BrowserWindowModel
    @Binding var isCommandBarVisible: Bool

    var body: some View {
        let isVisible = isCommandBarVisible || model.isCommandPaletteVisible
        GeometryReader { proxy in
            let width = min(Theme.Metrics.commandBarWidth, proxy.size.width - 32)
            ZStack(alignment: .top) {
                if isVisible {
                    Theme.Colors.scrim
                        .opacity(0.6)
                        .onTapGesture { dismiss() }
                        .transition(.opacity)
                }
                Group {
                    if isCommandBarVisible {
                        CommandBar(model: model) { isCommandBarVisible = false }
                    } else if model.isCommandPaletteVisible {
                        CommandPalette(model: model)
                    }
                }
                .frame(width: width)
                .padding(.top, proxy.size.height * 0.14)
                .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .animation(Theme.Motion.spring, value: isCommandBarVisible)
        .animation(Theme.Motion.spring, value: model.isCommandPaletteVisible)
    }

    private func dismiss() {
        isCommandBarVisible = false
        model.isCommandPaletteVisible = false
    }
}
