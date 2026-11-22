import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// History, Bookmarks and Downloads in one panel over the page.
struct LibraryOverlay: View {
    let model: BrowserWindowModel

    var body: some View {
        ZStack {
            if let panel = model.libraryPanel {
                Theme.Colors.scrim
                    .onTapGesture { model.libraryPanel = nil }
                    .transition(.opacity)
                LibraryPanelView(model: model, panel: panel)
                    .frame(maxWidth: 760, maxHeight: 700)
                    .padding(28)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.spring, value: model.libraryPanel)
    }
}

private struct LibraryPanelView: View {
    let model: BrowserWindowModel
    let panel: LibraryPanel
    @State private var query = ""

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Library", selection: Binding(get: { panel }, set: { model.libraryPanel = $0 })) {
                    Text("History").tag(LibraryPanel.history)
                    Text("Bookmarks").tag(LibraryPanel.bookmarks)
                    Text("Downloads").tag(LibraryPanel.downloads)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if panel == .downloads {
                    Button("Clear Finished") { AppServices.shared.downloads.clearFinished() }
                        .disabled(!AppServices.shared.downloads.items.contains { $0.state != .downloading })
                } else {
                    LibrarySearchField(
                        prompt: panel == .history ? "Search history" : "Search bookmarks", text: $query)
                }
                Button { model.libraryPanel = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.chrome)
                    .help("Close")
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            Divider()
            Group {
                switch panel {
                case .history: HistoryLibrary(model: model, query: query)
                case .bookmarks: BookmarksLibrary(model: model, query: query)
                case .downloads: DownloadsLibrary()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.card, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
        .onChange(of: panel) { query = "" }
        .onExitCommand { model.libraryPanel = nil }
    }
}

private struct LibrarySearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 240, height: 28)
        .background(Theme.Colors.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// An empty list's message: what goes here and how to fill it.
private struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A list row with the shared hover treatment.
private struct LibraryRowBackground: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Theme.Colors.hoverRow : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

extension BrowserWindowModel {
    /// Opens a page picked in the library: in the current tab if it is empty,
    /// otherwise in a new tab.
    fileprivate func openFromLibrary(_ url: URL, inNewTab: Bool = false) {
        libraryPanel = nil
        if !inNewTab, let tab = selectedTab, tab.url == nil {
            tab.load(url)
        } else {
            newTab(url: url)
        }
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - History

@MainActor
@Observable
private final class HistoryBrowser {
    struct Day: Identifiable {
        let date: Date
        var visits: [HistoryVisit]
        var id: Date { date }
    }

    private(set) var days: [Day] = []
    private(set) var hasMore = false
    private(set) var isSearching = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var query: String?
    @ObservationIgnored private var oldestLoaded: Int64?
    private static let pageSize: UInt32 = 150

    init(store: Store) {
        self.store = store
    }

    func load(query: String) {
        self.query = query.isEmpty ? nil : query
        isSearching = !query.isEmpty
        days = []
        oldestLoaded = nil
        loadMore()
    }

    func loadMore() {
        do {
            let page = try store.visits(query: query, beforeMs: oldestLoaded, limit: Self.pageSize)
            hasMore = page.count == Int(Self.pageSize)
            oldestLoaded = page.last?.visitedAtMs
            let calendar = Calendar.current
            for visit in page {
                let day = calendar.startOfDay(for: visit.visitedAtMs.dateFromMilliseconds)
                if days.last?.date == day {
                    days[days.count - 1].visits.append(visit)
                } else {
                    days.append(Day(date: day, visits: [visit]))
                }
            }
        } catch {
            hasMore = false
            AppServices.shared.reportNonFatal(error, "Loading history")
        }
    }

    func delete(_ url: String) {
        do {
            try store.deleteUrl(url: url)
        } catch {
            NSApp.presentError(error)
            return
        }
        for index in days.indices {
            days[index].visits.removeAll { $0.url == url }
        }
        days.removeAll { $0.visits.isEmpty }
    }
}

private struct HistoryLibrary: View {
    let model: BrowserWindowModel
    let query: String
    @State private var history: HistoryBrowser

    init(model: BrowserWindowModel, query: String) {
        self.model = model
        self.query = query
        _history = State(initialValue: HistoryBrowser(store: model.selectedSpace.profile.store))
    }

    var body: some View {
        Group {
            if history.days.isEmpty {
                if history.isSearching {
                    LibraryEmptyState(symbol: "magnifyingglass", title: "No matches",
                                      message: "No pages in your history match “\(query)”.")
                } else {
                    LibraryEmptyState(symbol: "clock", title: "No history yet",
                                      message: model.isPrivate
                                        ? "Private windows don't add to history. Pages you visit in other windows show up here."
                                        : "Pages you visit show up here, grouped by day.")
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(history.days) { day in
                            Section {
                                ForEach(day.visits, id: \.self) { visit in
                                    HistoryRow(visit: visit, model: model, history: history)
                                }
                            } header: {
                                DayHeader(date: day.date)
                            }
                        }
                        if history.hasMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(12)
                                .onAppear { history.loadMore() }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .task(id: query) {
            if !query.isEmpty {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
            history.load(query: query)
        }
    }
}

private struct DayHeader: View {
    let date: Date

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.card)
    }

    private var title: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct HistoryRow: View {
    let visit: HistoryVisit
    let model: BrowserWindowModel
    let history: HistoryBrowser
    @State private var isHovered = false

    var body: some View {
        let url = URL(string: visit.url)
        HStack(spacing: 10) {
            Text(visit.visitedAtMs.dateFromMilliseconds, format: .dateTime.hour().minute())
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)
            FaviconView(host: url?.host(), size: 16)
            Text(visit.title.flatMap { $0.isEmpty ? nil : $0 } ?? visit.url)
                .font(.system(size: 13))
                .lineLimit(1)
            Text(url?.host() ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 8)
            Button { history.delete(visit.url) } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
            }
            .buttonStyle(.chrome(size: 22))
            .opacity(isHovered ? 1 : 0)
            .help("Remove from History")
        }
        .frame(height: 32)
        .modifier(LibraryRowBackground())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if let url { model.openFromLibrary(url) }
        }
        .contextMenu {
            if let url {
                Button("Open") { model.openFromLibrary(url) }
                Button("Open in New Tab") { model.openFromLibrary(url, inNewTab: true) }
                Button("Copy Link") { copyToPasteboard(visit.url) }
                Divider()
            }
            Button("Remove from History") { history.delete(visit.url) }
        }
    }
}

// MARK: - Bookmarks

@MainActor
@Observable
private final class BookmarkTree {
    struct Row: Identifiable {
        let bookmark: Bookmark
        let depth: Int
        var id: String { bookmark.id }
        var isFolder: Bool { bookmark.url == nil }
    }

    private(set) var rows: [Row] = []
    private(set) var expanded: Set<String> = []
    var renamingID: String?

    @ObservationIgnored private let store: Store
    /// Loaded children by folder id; the `nil` key is the root level.
    @ObservationIgnored private var children: [String?: [Bookmark]] = [:]

    init(store: Store) {
        self.store = store
    }

    func reload() {
        do {
            children = [nil: try store.bookmarkChildren(parentId: nil)]
            for id in expanded {
                children[id] = try store.bookmarkChildren(parentId: id)
            }
        } catch {
            AppServices.shared.reportNonFatal(error, "Loading bookmarks")
        }
        rebuildRows()
    }

    func search(_ query: String) {
        do {
            rows = try store.searchBookmarks(query: query, limit: 300).map { Row(bookmark: $0, depth: 0) }
        } catch {
            AppServices.shared.reportNonFatal(error, "Searching bookmarks")
        }
    }

    func toggle(_ folder: Bookmark) {
        if expanded.remove(folder.id) == nil {
            expanded.insert(folder.id)
        }
        reload()
    }

    func childCount(of parentID: String?) -> Int {
        children[parentID]?.count ?? 0
    }

    func newFolder(in parentID: String?) {
        mutate {
            let folder = try store.addBookmark(parentId: parentID, title: "New Folder", url: nil)
            if let parentID { expanded.insert(parentID) }
            renamingID = folder.id
        }
    }

    func rename(_ bookmark: Bookmark, to title: String) {
        renamingID = nil
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != bookmark.title else { return }
        mutate { try store.updateBookmark(id: bookmark.id, title: trimmed, url: bookmark.url) }
    }

    func delete(_ bookmark: Bookmark) {
        mutate {
            try store.deleteBookmark(id: bookmark.id)
            expanded.remove(bookmark.id)
        }
    }

    /// Moves a dragged item into `parentID` at `position`.
    func move(_ id: String, to parentID: String?, at position: Int) {
        guard id != parentID else { return }
        mutate {
            try store.moveBookmark(id: id, parentId: parentID, position: UInt32(max(position, 0)))
            if let parentID { expanded.insert(parentID) }
        }
    }

    /// Runs a change the user asked for; a failure is shown to them.
    private func mutate(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            NSApp.presentError(error)
        }
        BookmarksRevision.shared.bump()
        reload()
    }

    private func rebuildRows() {
        var result: [Row] = []
        func walk(_ parentID: String?, depth: Int) {
            for bookmark in children[parentID] ?? [] {
                result.append(Row(bookmark: bookmark, depth: depth))
                if bookmark.url == nil, expanded.contains(bookmark.id) {
                    walk(bookmark.id, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 0)
        rows = result
    }
}

private struct BookmarksLibrary: View {
    let model: BrowserWindowModel
    let query: String
    @State private var tree: BookmarkTree
    @State private var isRootDropTargeted = false

    init(model: BrowserWindowModel, query: String) {
        self.model = model
        self.query = query
        _tree = State(initialValue: BookmarkTree(store: model.selectedSpace.profile.store))
    }

    var body: some View {
        VStack(spacing: 0) {
            if tree.rows.isEmpty {
                if query.isEmpty {
                    LibraryEmptyState(symbol: "bookmark", title: "No bookmarks yet",
                                      message: "Press ⌘D on any page to bookmark it, or import bookmarks from another browser in Settings.")
                } else {
                    LibraryEmptyState(symbol: "magnifyingglass", title: "No matches",
                                      message: "No bookmarks match “\(query)”.")
                }
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(tree.rows) { row in
                            BookmarkRow(row: row, tree: tree, model: model, isSearching: !query.isEmpty)
                        }
                    }
                    .padding(8)
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if isRootDropTargeted {
                                Text("Move to top level")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            guard let id = ids.first else { return false }
                            tree.move(id, to: nil, at: tree.childCount(of: nil))
                            return true
                        } isTargeted: { isRootDropTargeted = $0 }
                }
            }
            Divider()
            HStack {
                Button {
                    tree.newFolder(in: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.chrome)
                .labelStyle(.titleAndIcon)
                .disabled(!query.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
        .task(id: query) {
            if query.isEmpty {
                tree.reload()
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                tree.search(query)
            }
        }
    }
}

private struct BookmarkRow: View {
    let row: BookmarkTree.Row
    let tree: BookmarkTree
    let model: BrowserWindowModel
    let isSearching: Bool
    @State private var draftTitle = ""
    @State private var isDropTargeted = false
    @FocusState private var isRenameFocused: Bool
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let bookmark = row.bookmark
        let url = bookmark.url.flatMap(URL.init(string:))
        HStack(spacing: 8) {
            if row.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(tree.expanded.contains(bookmark.id) ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 12)
                FaviconView(host: url?.host(), size: 16)
            }
            if tree.renamingID == bookmark.id {
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($isRenameFocused)
                    .onAppear {
                        draftTitle = bookmark.title
                        isRenameFocused = true
                    }
                    .onSubmit { tree.rename(bookmark, to: draftTitle) }
                    .onExitCommand { tree.renamingID = nil }
            } else {
                Text(bookmark.title.isEmpty ? (bookmark.url ?? "Untitled") : bookmark.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if let host = url?.host() {
                    Text(host)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .frame(height: 32)
        .modifier(LibraryRowBackground())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent, lineWidth: 1.5)
            }
        }
        .onTapGesture {
            if row.isFolder {
                withAnimation(Theme.Motion.quick) { tree.toggle(bookmark) }
            } else if let url {
                model.openFromLibrary(url)
            }
        }
        .contextMenu {
            if let url {
                Button("Open") { model.openFromLibrary(url) }
                Button("Open in New Tab") { model.openFromLibrary(url, inNewTab: true) }
                Button("Copy Link") { copyToPasteboard(url.absoluteString) }
                Divider()
            } else {
                Button("New Folder Inside") { tree.newFolder(in: bookmark.id) }
                    .disabled(isSearching)
            }
            Button("Rename…") { tree.renamingID = bookmark.id }
            Button(row.isFolder ? "Delete Folder and Its Contents" : "Delete Bookmark") { tree.delete(bookmark) }
        }
        .draggable(bookmark.id) {
            Label(bookmark.title, systemImage: row.isFolder ? "folder" : "bookmark").padding(8)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != bookmark.id, !isSearching else { return false }
            if row.isFolder {
                tree.move(id, to: bookmark.id, at: tree.childCount(of: bookmark.id))
            } else {
                tree.move(id, to: bookmark.parentId, at: Int(bookmark.position))
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }
}

// MARK: - Downloads

private struct DownloadsLibrary: View {
    var body: some View {
        let items = AppServices.shared.downloads.items
        if items.isEmpty {
            LibraryEmptyState(symbol: "arrow.down.circle", title: "No downloads",
                              message: "Files you download are saved to your Downloads folder and listed here.")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        DownloadRow(item: item)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(filename: item.filename)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: item.fractionCompleted)
                        .progressViewStyle(.linear)
                        .tint(accent)
                }
                Text(status)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            switch item.state {
            case .downloading:
                Button { item.cancel() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.chrome)
                    .help("Cancel Download")
            case .finished:
                Button { item.revealInFinder() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.chrome)
                    .help("Show in Finder")
            case .failed, .cancelled:
                EmptyView()
            }
        }
        .padding(.vertical, 8)
        .modifier(LibraryRowBackground())
        .onTapGesture(count: 2) {
            if item.state == .finished, let destination = item.destination {
                NSWorkspace.shared.open(destination)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var status: String {
        switch item.state {
        case .downloading:
            let done = item.completedBytes.formatted(.byteCount(style: .file))
            return item.totalBytes > 0 ? "\(done) of \(item.totalBytes.formatted(.byteCount(style: .file)))" : done
        case .finished:
            return item.totalBytes > 0 ? item.totalBytes.formatted(.byteCount(style: .file)) : "Done"
        case .failed(let message):
            return "Failed: \(message)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// The Finder icon for a file type. Its own view so download progress doesn't redraw it.
private struct FileIcon: View {
    let filename: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (filename as NSString).pathExtension) ?? .data))
            .resizable()
            .frame(width: 32, height: 32)
    }
}
