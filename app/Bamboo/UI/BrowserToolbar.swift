import AppKit
import SwiftUI

/// Brave's toolbar: back, forward, reload, home, the address bar with the
/// bookmark star, Shields, then Claude, downloads, the space avatar and the
/// main menu.
struct BrowserToolbar: View {
    let model: BrowserWindowModel

    var body: some View {
        let tab = model.selectedTab
        let settings = AppServices.shared.settings
        HStack(spacing: 2) {
            Button { tab?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!(tab?.canGoBack ?? false))
                .help("Back (⌘[)")
            Button { tab?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!(tab?.canGoForward ?? false))
                .help("Forward (⌘])")
            Button {
                guard let tab else { return }
                if tab.isLoading { tab.stopLoading() } else { tab.reload() }
            } label: {
                Image(systemName: tab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(tab?.url == nil)
            .help(tab?.isLoading == true ? "Stop (⌘.)" : "Reload (⌘R)")
            if settings.showHomeButton {
                Button {
                    NSApp.sendAction(#selector(BrowserWindowController.goHome(_:)), to: nil, from: nil)
                } label: { Image(systemName: "house") }
                    .help("Home (⇧⌘H)")
            }

            AddressField(model: model)
                .padding(.horizontal, 6)

            ShieldsButton(tab: tab)
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)
            Button {
                withAnimation(Theme.Motion.spring) { model.isAssistantVisible.toggle() }
            } label: {
                Image(systemName: "sparkle")
                    .foregroundStyle(model.isAssistantVisible ? AnyShapeStyle(Theme.palette(model.selectedSpace.tint).accent)
                                     : AnyShapeStyle(.secondary))
            }
            .help(model.isAssistantVisible ? "Hide Claude (⌘J)" : "Ask Claude (⌘J)")
            DownloadsButton(model: model)
            SpaceAvatarMenu(model: model)
            MainMenuButton(model: model)
        }
        .buttonStyle(.chrome(size: 30))
        .padding(.horizontal, 8)
        .frame(height: Theme.Metrics.toolbarHeight)
    }
}

// MARK: - Address bar

/// The omnibox. It shows the page's address; clicking it, ⌘L or ⌘T turns it
/// into a field with suggestions dropping down beneath it.
private struct AddressField: View {
    let model: BrowserWindowModel
    @State private var suggestions: CommandBarSuggestions?
    @State private var isHovered = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let tab = model.selectedTab
        let isEditing = suggestions != nil
        HStack(spacing: 7) {
            SiteInfoButton(tab: tab, isEditing: isEditing)
            if let suggestions {
                CommandField(
                    placeholder: "Search \(SearchEngine.engine(AppServices.shared.settings.searchEngine).name) or type a URL",
                    initialText: tab?.url?.absoluteString ?? "",
                    fontSize: 13.5,
                    onEdit: { text, allowsCompletion in suggestions.update(text, allowsCompletion: allowsCompletion) },
                    onMove: { suggestions.moveSelection(by: $0) },
                    onSubmit: { _ in
                        if let item = suggestions.items[safe: suggestions.selection] { activate(item, in: suggestions) }
                    },
                    onCancel: endEditing,
                    onEndEditing: endEditing)
            } else {
                DisplayedAddress(tab: tab)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: beginEditing)
                if let url = tab?.url {
                    BookmarkStar(url: url, profile: model.selectedSpace.profile)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isEditing ? Theme.Colors.card : isHovered ? Theme.Colors.pressedRow : Theme.Colors.field)
                .shadow(color: .black.opacity(isEditing ? 0.12 : 0), radius: 6, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
                .opacity(isEditing ? 1 : 0)
        }
        .overlay(alignment: .topLeading) {
            if let suggestions, !suggestions.items.isEmpty {
                SuggestionList(suggestions: suggestions) { activate($0, in: suggestions) }
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 38)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isEditing)
        .animation(Theme.Motion.quick, value: isHovered)
        // One handler for both, because ⌘T selects a new tab and asks for focus at once.
        .onChange(of: FocusTrigger(request: model.addressBarFocusRequest, tabID: model.selectedTab?.id)) { old, new in
            if new.request != old.request {
                beginEditing()
            } else {
                endEditing()
            }
        }
    }

    private struct FocusTrigger: Equatable {
        let request: Int
        let tabID: Tab.ID?
    }

    private func beginEditing() {
        // A fresh model each time, so the field starts from the page's address.
        suggestions = nil
        suggestions = CommandBarSuggestions(window: model)
    }

    private func endEditing() {
        suggestions = nil
    }

    private func activate(_ item: CommandBarSuggestions.Item, in suggestions: CommandBarSuggestions) {
        endEditing()
        suggestions.activate(item)
    }
}

/// The address with the host in full colour and the rest dimmed, as Chrome and Brave do.
private struct DisplayedAddress: View {
    let tab: Tab?

    var body: some View {
        Group {
            if let url = tab?.url {
                let (host, rest) = Self.parts(of: url)
                Text("\(Text(host).foregroundStyle(.primary))\(Text(rest).foregroundStyle(.secondary))")
            } else {
                Text("Search \(SearchEngine.engine(AppServices.shared.settings.searchEngine).name) or type a URL")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private static func parts(of url: URL) -> (String, String) {
        if AppServices.shared.settings.showFullURLs {
            return ("", url.absoluteString)
        }
        guard let host = url.host(), url.scheme == "https" || url.scheme == "http" else {
            return (url.absoluteString, "")
        }
        let shownHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = url.path()
        if let query = url.query() { rest += "?" + query }
        return (shownHost, rest == "/" ? "" : rest)
    }
}

private struct SuggestionList: View {
    let suggestions: CommandBarSuggestions
    let activate: (CommandBarSuggestions.Item) -> Void
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 2) {
            ForEach(Array(suggestions.items.enumerated()), id: \.element.id) { index, item in
                CommandBarRow(item: item, isSelected: index == suggestions.selection, accent: accent)
                    .onHover { if $0 { suggestions.selection = index } }
                    // Acts on mouse-down: the click moves focus out of the address
                    // field, which closes this list before a mouse-up could arrive.
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in activate(item) })
            }
        }
        .padding(6)
        .background(Theme.Colors.card, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .animation(Theme.Motion.quick, value: suggestions.items.map(\.id))
    }
}

/// The lock at the left of the address bar; it explains the connection.
private struct SiteInfoButton: View {
    let tab: Tab?
    let isEditing: Bool
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Group {
                if isEditing || tab?.url == nil {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    SecurityIcon(tab: tab)
                }
            }
            .frame(width: 24, height: 24)
            .background(Circle().fill(Theme.Colors.field).opacity(tab?.url == nil || isEditing ? 0 : 1))
        }
        .buttonStyle(.plain)
        .disabled(tab?.url == nil || isEditing)
        .help("View site information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let tab { SiteInfo(tab: tab) }
        }
    }
}

private struct SiteInfo: View {
    let tab: Tab

    var body: some View {
        let isSecure = tab.url?.scheme == "https" && tab.hasOnlySecureContent
        VStack(alignment: .leading, spacing: 10) {
            Text(tab.url?.host() ?? tab.displayTitle)
                .font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSecure ? "lock.fill" : "lock.open.fill")
                    .foregroundStyle(isSecure ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isSecure ? "Connection is secure" : "Connection is not secure")
                        .font(.system(size: 12.5, weight: .medium))
                    Text(isSecure
                         ? "Information you send to this site, like passwords or card numbers, is encrypted."
                         : "Don't enter passwords or card numbers here. Someone on your network could see them.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
    }
}

/// ☆ inside the address bar: bookmarks the page, or removes the bookmark.
private struct BookmarkStar: View {
    let url: URL
    let profile: Profile
    @State private var isBookmarked = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        Button {
            NSApp.sendAction(#selector(BrowserWindowController.bookmarkPage(_:)), to: nil, from: nil)
        } label: {
            Image(systemName: isBookmarked ? "star.fill" : "star")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isBookmarked ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.chrome(size: 26))
        .help(isBookmarked ? "Edit bookmark for this tab (⌘D)" : "Bookmark this tab (⌘D)")
        .task(id: "\(url.absoluteString)#\(BookmarksRevision.shared.value)") {
            do {
                isBookmarked = try !profile.store.bookmarksForUrl(url: url.absoluteString).isEmpty
            } catch {
                AppServices.shared.reportNonFatal(error, "Checking whether the page is bookmarked")
            }
        }
    }
}

// MARK: - Shields, space avatar, main menu

/// Brave's lion button: Shields for this site, with what it blocked as a badge.
private struct ShieldsButton: View {
    let tab: Tab?
    @State private var isPresented = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let count = tab?.blockedRequestCount ?? 0
        Button {
            isPresented = true
        } label: {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tab?.url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text(count > 99 ? "99+" : "\(count)")
                            .font(.system(size: 8.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .padding(.horizontal, 3.5)
                            .frame(minWidth: 14, minHeight: 13)
                            .background(Capsule().fill(Color(nsColor: .labelColor).opacity(0.82)))
                            .offset(x: 9, y: -7)
                            .contentTransition(.numericText(value: Double(count)))
                    }
                }
        }
        .disabled(tab?.url == nil)
        .help(count == 1 ? "Shields blocked 1 request on this page" : "Shields blocked \(count) requests on this page")
        .animation(Theme.Motion.quick, value: count)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let tab { ShieldsPopover(tab: tab) }
        }
    }
}

/// The space's icon on its colour, like Brave's profile avatar. Its menu switches
/// spaces, opens the space editor, and brings up another profile's window.
private struct SpaceAvatarMenu: View {
    let model: BrowserWindowModel
    @State private var editorTarget: SpaceEditorTarget?

    var body: some View {
        let space = model.selectedSpace
        let palette = Theme.palette(space.tint)
        Menu {
            Section(model.isPrivate ? "Private window" : "\(space.profile.name) profile") {
                ForEach(model.spaces) { candidate in
                    Toggle(isOn: Binding(
                        get: { candidate.id == model.selectedSpaceID },
                        set: { if $0 { withAnimation(Theme.Motion.standard) { model.selectSpace(candidate) } } })
                    ) {
                        Label(candidate.name, systemImage: candidate.symbol)
                    }
                }
            }
            if !model.isPrivate {
                Divider()
                Button("New Space…") { editorTarget = .new }
                Button("Edit “\(space.name)”…") { editorTarget = .edit(space) }
                Divider()
                Section("Profiles") {
                    ForEach(AppServices.shared.profiles.profiles) { profile in
                        Toggle(isOn: Binding(
                            get: { profile === space.profile },
                            set: { if $0 { AppServices.shared.windows.showWindow(for: profile) } })
                        ) {
                            Label(profile.name, systemImage: profile.symbol)
                        }
                    }
                    Button("Manage Profiles…") { SettingsWindowController.shared.show(section: .getStarted) }
                }
            }
            Divider()
            Toggle("Use Vertical Tabs", isOn: Binding(
                get: { AppServices.shared.settings.tabLayout == .vertical },
                set: { vertical in
                    withAnimation(Theme.Motion.standard) {
                        AppServices.shared.settings.tabLayout = vertical ? .vertical : .horizontal
                    }
                }))
        } label: {
            Image(systemName: space.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(LinearGradient(colors: palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(space.name) space")
        .sheet(item: $editorTarget) { target in
            SpaceEditor(model: model, target: target)
        }
    }
}

/// ⋯ with Brave's main menu. It is an AppKit menu sending the same actions
/// as the menu bar, so it validates and shows shortcuts the same way.
private struct MainMenuButton: View {
    let model: BrowserWindowModel
    @State private var anchor = MenuAnchor.Holder()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = MainMenuContents.make(for: model)
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.maxX - menu.size.width, y: -6), in: view)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
        }
        .background(MenuAnchor(holder: anchor))
        .help("Customize and control Bamboo")
    }
}

/// An invisible AppKit view to pop a menu up from.
struct MenuAnchor: NSViewRepresentable {
    final class Holder {
        weak var view: NSView?
    }

    let holder: Holder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        holder.view = view
    }
}

@MainActor
private enum MainMenuContents {
    static func make(for model: BrowserWindowModel) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("History", #selector(BrowserWindowController.showHistory(_:)), "y"))
        menu.addItem(item("Downloads", #selector(BrowserWindowController.showDownloads(_:)), "l", [.command, .option]))
        let bookmarks = NSMenu(title: "Bookmarks")
        bookmarks.addItem(item("Bookmark This Tab…", #selector(BrowserWindowController.bookmarkPage(_:)), "d"))
        bookmarks.addItem(item("Bookmark Manager", #selector(BrowserWindowController.showBookmarks(_:)), "b", [.command, .option]))
        bookmarks.addItem(item("Always Show Bookmarks Bar", #selector(BrowserWindowController.toggleBookmarksBar(_:)), "b", [.command, .shift]))
        BookmarkMenus.appendBookmarks(under: nil, of: model, to: bookmarks)
        let bookmarksItem = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        bookmarksItem.submenu = bookmarks
        menu.addItem(bookmarksItem)
        menu.addItem(.separator())
        let zoom = NSMenuItem()
        zoom.view = NSHostingView(rootView: ZoomMenuRow(tab: model.selectedTab))
        zoom.view?.frame.size = NSSize(width: 260, height: 30)
        menu.addItem(zoom)
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"))
        menu.addItem(item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"))
        menu.addItem(item("Reader", #selector(BrowserWindowController.toggleReader(_:)), "r", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Clear Browsing Data…", #selector(AppDelegate.showClearBrowsingData(_:)), "\u{8}", [.command, .shift]))
        menu.addItem(item("Import Bookmarks and Settings…", #selector(AppDelegate.showImport(_:))))
        menu.addItem(item("Settings", #selector(AppDelegate.showSettings(_:)), ","))
        let help = NSMenu(title: "Help")
        help.addItem(item("Bamboo on GitHub", #selector(AppDelegate.openProjectPage(_:))))
        help.addItem(item("Report an Issue…", #selector(AppDelegate.reportIssue(_:))))
        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        menu.addItem(helpItem)
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }
}

/// Brave's "Zoom − 100% +" row in the main menu.
private struct ZoomMenuRow: View {
    let tab: Tab?
    @State private var zoom: Double

    init(tab: Tab?) {
        self.tab = tab
        _zoom = State(initialValue: Double(tab?.webView?.pageZoom ?? 1))
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Zoom")
                .padding(.leading, 14)
            Spacer()
            Button { step(#selector(BrowserWindowController.zoomOut(_:))) } label: { Image(systemName: "minus") }
            Text(zoom, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 44)
            Button { step(#selector(BrowserWindowController.zoomIn(_:))) } label: { Image(systemName: "plus") }
            Button {
                NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
            } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Enter Full Screen")
                .padding(.trailing, 8)
        }
        .font(.system(size: 13))
        .buttonStyle(.chrome(size: 24))
        .disabled(tab?.webView == nil)
    }

    private func step(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
        zoom = Double(tab?.webView?.pageZoom ?? 1)
    }
}
