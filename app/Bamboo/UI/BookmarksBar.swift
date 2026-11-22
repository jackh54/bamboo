import AppKit
import SwiftUI

/// Bumped whenever bookmarks change, so the bookmarks bar, the star in the
/// address bar and open library panels reload.
@MainActor
@Observable
final class BookmarksRevision {
    static let shared = BookmarksRevision()
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

/// Brave's bookmarks bar: the top-level bookmarks and folders, folders
/// opening as menus, and a » menu for whatever doesn't fit.
struct BookmarksBar: View {
    let model: BrowserWindowModel
    @State private var items: [Bookmark] = []
    /// Each item's width, measured when the bookmarks load rather than on every layout.
    @State private var widths: [CGFloat] = []

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let maxItemWidth: CGFloat = 170
    private static let overflowWidth: CGFloat = 30

    var body: some View {
        let profile = model.selectedSpace.profile
        GeometryReader { proxy in
            let visible = visibleCount(in: proxy.size.width - 16)
            HStack(spacing: 2) {
                if items.isEmpty {
                    Text("For quick access, place your bookmarks here on the bookmarks bar.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 6)
                    Button("Import bookmarks…") {
                        NSApp.sendAction(#selector(AppDelegate.showImport(_:)), to: nil, from: nil)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                } else {
                    ForEach(items.prefix(visible), id: \.id) { bookmark in
                        BookmarkBarItem(bookmark: bookmark, model: model)
                    }
                    if visible < items.count {
                        OverflowButton(hidden: Array(items.dropFirst(visible)), model: model)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: proxy.size.height)
        }
        .frame(height: Theme.Metrics.bookmarksBarHeight)
        .task(id: "\(profile.id)#\(BookmarksRevision.shared.value)") {
            do {
                items = try profile.store.bookmarkChildren(parentId: nil)
                widths = items.map { bookmark in
                    let text = (bookmark.title.isEmpty ? (bookmark.url ?? "") : bookmark.title) as NSString
                    return min(text.size(withAttributes: [.font: Self.font]).width.rounded(.up) + 40, Self.maxItemWidth)
                }
            } catch {
                AppServices.shared.reportNonFatal(error, "Loading the bookmarks bar")
            }
        }
    }

    private func visibleCount(in width: CGFloat) -> Int {
        var used: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            let reserve = index == widths.count - 1 ? 0 : Self.overflowWidth
            if used + itemWidth + reserve > width { return index }
            used += itemWidth + 2
        }
        return widths.count
    }
}

private struct BookmarkBarItem: View {
    let bookmark: Bookmark
    let model: BrowserWindowModel
    @State private var anchor = MenuAnchor.Holder()
    @State private var isHovered = false

    var body: some View {
        let url = bookmark.url.flatMap(URL.init(string:))
        Button {
            if let url {
                BookmarkMenuTarget.open(url, in: model)
            } else if let view = anchor.view {
                let menu = NSMenu(title: bookmark.title)
                BookmarkMenus.appendBookmarks(under: bookmark.id, of: model, to: menu)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
            }
        } label: {
            HStack(spacing: 6) {
                if url == nil {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                } else {
                    FaviconView(host: url?.host(), size: 14)
                }
                Text(bookmark.title.isEmpty ? (bookmark.url ?? "Untitled") : bookmark.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: 170)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Theme.Colors.hoverRow : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchor(holder: anchor))
        .onHover { isHovered = $0 }
        .help(bookmark.url ?? bookmark.title)
        .contextMenu {
            if let url {
                Button("Open in New Tab") { model.newTab(url: url, after: model.selectedTab) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                Divider()
            }
            Button(url == nil ? "Delete Folder and Its Contents" : "Delete") {
                do {
                    try model.selectedSpace.profile.store.deleteBookmark(id: bookmark.id)
                } catch {
                    NSApp.presentError(error)
                }
                BookmarksRevision.shared.bump()
            }
        }
    }
}

private struct OverflowButton: View {
    let hidden: [Bookmark]
    let model: BrowserWindowModel
    @State private var anchor = MenuAnchor.Holder()

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            let menu = NSMenu(title: "More Bookmarks")
            for bookmark in hidden {
                menu.addItem(BookmarkMenus.item(for: bookmark, model: model))
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        } label: {
            Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.chrome(size: 24))
        .background(MenuAnchor(holder: anchor))
        .help("More bookmarks")
    }
}

/// Bookmarks as AppKit menu items: folders become submenus filled when opened.
@MainActor
enum BookmarkMenus {
    static func appendBookmarks(under parentID: String?, of model: BrowserWindowModel, to menu: NSMenu) {
        let children: [Bookmark]
        do {
            children = try model.selectedSpace.profile.store.bookmarkChildren(parentId: parentID)
        } catch {
            AppServices.shared.reportNonFatal(error, "Loading bookmarks for a menu")
            return
        }
        if children.isEmpty, parentID != nil {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        if !children.isEmpty, !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for bookmark in children {
            menu.addItem(item(for: bookmark, model: model))
        }
    }

    static func item(for bookmark: Bookmark, model: BrowserWindowModel) -> NSMenuItem {
        let title = bookmark.title.isEmpty ? (bookmark.url ?? "Untitled") : bookmark.title
        guard let url = bookmark.url.flatMap(URL.init(string:)) else {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let submenu = NSMenu(title: title)
            let loader = FolderLoader(folderID: bookmark.id, model: model)
            submenu.delegate = loader
            // Menu delegates are weak; the item keeps the loader alive.
            item.representedObject = loader
            item.submenu = submenu
            return item
        }
        let item = NSMenuItem(title: title, action: #selector(BookmarkMenuTarget.openItem(_:)), keyEquivalent: "")
        item.target = BookmarkMenuTarget.shared
        item.representedObject = url
        item.toolTip = url.absoluteString
        if let icon = url.host().flatMap(FaviconLoader.shared.icon(forHost:))?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    private final class FolderLoader: NSObject, NSMenuDelegate {
        let folderID: String
        let model: BrowserWindowModel

        init(folderID: String, model: BrowserWindowModel) {
            self.folderID = folderID
            self.model = model
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard menu.items.isEmpty else { return }
            BookmarkMenus.appendBookmarks(under: folderID, of: model, to: menu)
        }
    }
}

/// Opens bookmarks chosen from a menu in the window the menu belongs to.
@MainActor
final class BookmarkMenuTarget: NSObject {
    static let shared = BookmarkMenuTarget()

    @objc func openItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let model = AppServices.shared.windows.frontmost else { return }
        Self.open(url, in: model)
    }

    /// ⌘-click opens a background tab; otherwise the page opens in the current tab.
    static func open(_ url: URL, in model: BrowserWindowModel) {
        if NSEvent.modifierFlags.contains(.command) {
            model.newTab(url: url, after: model.selectedTab, select: false)
        } else if let tab = model.selectedTab {
            tab.load(url)
        } else {
            model.newTab(url: url)
        }
    }
}
