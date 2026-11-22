import SwiftUI

/// The floating address bar for ⌘L and ⌘T: type an address or a search,
/// or pick an open tab, a bookmark, a history entry or a search suggestion.
struct CommandBar: View {
    let model: BrowserWindowModel
    let dismiss: () -> Void
    @State private var suggestions: CommandBarSuggestions
    @Environment(\.spaceAccent) private var accent

    init(model: BrowserWindowModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        _suggestions = State(initialValue: CommandBarSuggestions(window: model))
    }

    var body: some View {
        let items = suggestions.items
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                CommandField(
                    placeholder: "Search or enter address",
                    initialText: model.selectedTab?.url?.absoluteString ?? "",
                    onEdit: { text, allowsCompletion in suggestions.update(text, allowsCompletion: allowsCompletion) },
                    onMove: { suggestions.moveSelection(by: $0) },
                    onSubmit: { _ in
                        if let item = suggestions.items[safe: suggestions.selection] { activate(item) }
                    },
                    onCancel: dismiss)
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if !items.isEmpty {
                Divider().opacity(0.6)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CommandBarRow(item: item, isSelected: index == suggestions.selection, accent: accent)
                            .onHover { if $0 { suggestions.selection = index } }
                            .onTapGesture { activate(item) }
                    }
                }
                .padding(6)
            }
        }
        .floatingSurface()
        .animation(Theme.Motion.quick, value: items.map(\.id))
    }

    private func activate(_ item: CommandBarSuggestions.Item) {
        suggestions.activate(item)
        dismiss()
    }
}

/// One suggestion in the command bar or the address bar's drop-down.
struct CommandBarRow: View {
    let item: CommandBarSuggestions.Item
    let isSelected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 11) {
            icon
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: subtitle == nil ? 36 : 44)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? accent : .clear)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .open(let url, _, let source):
            if source == .typed {
                Image(systemName: "globe").font(.system(size: 14)).opacity(0.75)
            } else {
                FaviconView(host: url.host(), size: 16)
            }
        case .search:
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).opacity(0.75)
        case .tab(let tab):
            FaviconView(image: tab.favicon, host: tab.url?.host(), size: 16)
        case .askClaude:
            Image(systemName: "sparkle").font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(accent))
        }
    }

    private var title: String {
        switch item {
        case .open(let url, let title, _): title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.displayAddress(url)
        case .search(let query, _): query
        case .tab(let tab): tab.displayTitle
        case .askClaude(let prompt): "Ask Claude: “\(prompt)”"
        }
    }

    private var subtitle: String? {
        switch item {
        case .open(let url, let title, _): title.flatMap { $0.isEmpty ? nil : Self.displayAddress(url) }
        case .search(_, let isSuggestion):
            isSuggestion ? nil : "Search with \(SearchEngine.engine(AppServices.shared.settings.searchEngine).name)"
        case .tab(let tab): tab.url.map(Self.displayAddress)
        case .askClaude: nil
        }
    }

    private var hint: String? {
        switch item {
        case .open(_, _, .bookmark): "Bookmark"
        case .tab: "Switch to Tab"
        case .askClaude: "⌘J"
        default: isSelected ? "↩" : nil
        }
    }

    private static func displayAddress(_ url: URL) -> String {
        let text = url.absoluteString
        for prefix in ["https://www.", "http://www.", "https://", "http://"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }
}

/// What the command bar offers for the current input. Local results (open tabs,
/// history, bookmarks) come synchronously from the profile store; search
/// suggestions arrive from the search engine a moment later.
@MainActor
@Observable
final class CommandBarSuggestions {
    enum Source: Equatable {
        case typed, history, bookmark
    }

    enum Item: Identifiable {
        case open(URL, title: String?, source: Source)
        case search(String, isSuggestion: Bool)
        case tab(Tab)
        case askClaude(String)

        var id: String {
            switch self {
            case .open(let url, _, _): "open:\(url.absoluteString)"
            case .search(let query, _): "search:\(query)"
            case .tab(let tab): "tab:\(tab.id)"
            case .askClaude(let prompt): "claude:\(prompt)"
            }
        }
    }

    private(set) var items: [Item] = []
    var selection = 0

    @ObservationIgnored private let window: BrowserWindowModel
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var completion: Suggestion?
    @ObservationIgnored private var storeSuggestions: [Suggestion] = []
    @ObservationIgnored private var searchSuggestions: [String] = []
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    private static let session = URLSession(configuration: .ephemeral)
    private static let suggestionDelay = Duration.milliseconds(140)

    init(window: BrowserWindowModel) {
        self.window = window
        rebuild()
    }

    /// Takes the typed text and returns the inline completion, if any.
    func update(_ text: String, allowsCompletion: Bool) -> String? {
        query = text.trimmingCharacters(in: .whitespaces)
        storeSuggestions = []
        if !query.isEmpty {
            do {
                storeSuggestions = try window.selectedSpace.profile.store.suggest(input: query, limit: 8)
            } catch {
                AppServices.shared.reportNonFatal(error, "Address bar suggestions")
            }
        }
        completion = allowsCompletion ? storeSuggestions.first { $0.autocomplete != nil } : nil
        fetchSearchSuggestions()
        selection = 0
        rebuild()
        return completion?.autocomplete
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + offset + items.count) % items.count
    }

    /// Opens what the user picked: a page, a search, an open tab or a question for Claude.
    func activate(_ item: Item) {
        switch item {
        case .open(let url, _, _):
            load(url)
        case .search(let query, _):
            load(SearchEngine.engine(AppServices.shared.settings.searchEngine).searchURL(for: query))
        case .tab(let tab):
            // Switching away from the empty tab ⌘T just made leaves nothing behind.
            if let current = window.selectedTab, current.url == nil, current !== tab {
                window.close(current)
            }
            window.select(tab)
        case .askClaude(let prompt):
            window.pendingAssistantPrompt = prompt
            withAnimation(Theme.Motion.spring) { window.isAssistantVisible = true }
        }
    }

    private func load(_ url: URL) {
        if let tab = window.selectedTab {
            tab.load(url)
        } else {
            window.newTab(url: url)
        }
    }

    private func rebuild() {
        guard !query.isEmpty else {
            // Nothing typed yet: offer the tabs used most recently.
            items = window.allTabs
                .filter { $0 !== window.selectedTab && $0.url != nil }
                .sorted { $0.lastActivatedAt > $1.lastActivatedAt }
                .prefix(5)
                .map(Item.tab)
            return
        }

        var result: [Item] = []
        if let completion, let url = URL(string: completion.url) {
            result.append(.open(url, title: completion.title, source: Self.source(completion)))
            result.append(.search(query, isSuggestion: false))
        } else {
            switch AddressInput.parse(query) {
            case .url(let url): result.append(.open(url, title: nil, source: .typed))
            case .search(let text): result.append(.search(text, isSuggestion: false))
            case nil: break
            }
        }

        let needle = query.lowercased()
        result += window.allTabs
            .filter { tab in
                tab !== window.selectedTab && tab.url != nil
                    && (tab.title.lowercased().contains(needle) || tab.url?.absoluteString.lowercased().contains(needle) == true)
            }
            .prefix(3)
            .map(Item.tab)

        result += storeSuggestions
            .filter { $0.url != completion?.url }
            .compactMap { suggestion in
                URL(string: suggestion.url).map { Item.open($0, title: suggestion.title, source: Self.source(suggestion)) }
            }
            .prefix(5)

        result += searchSuggestions
            .filter { $0.lowercased() != needle }
            .prefix(4)
            .map { Item.search($0, isSuggestion: true) }

        result.append(.askClaude(query))

        var seen: Set<String> = []
        items = result.filter { seen.insert($0.id).inserted }
        selection = min(selection, max(items.count - 1, 0))
    }

    private static func source(_ suggestion: Suggestion) -> Source {
        switch suggestion.source {
        case .history: .history
        case .bookmark: .bookmark
        }
    }

    /// Asks the search engine for suggestions, a moment after typing stops.
    /// Only for text that is a search (typed addresses never leave the browser)
    /// and never in private windows.
    private func fetchSearchSuggestions() {
        fetchTask?.cancel()
        let settings = AppServices.shared.settings
        let engine = SearchEngine.engine(settings.searchEngine)
        guard settings.searchSuggestionsEnabled, !window.isPrivate,
              case .search(let text) = AddressInput.parse(query),
              let url = engine.suggestionsURL(for: text)
        else {
            searchSuggestions = []
            return
        }
        fetchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.suggestionDelay)
                let (data, response) = try await Self.session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
                }
                let suggestions = try SearchEngine.parseSuggestions(data)
                guard let self, !Task.isCancelled else { return }
                searchSuggestions = suggestions
                rebuild()
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code != .badServerResponse {
                // Offline, a dropped connection or a cancelled request: this
                // keystroke simply gets no suggestions.
                return
            } catch {
                AppServices.shared.reportNonFatal(error, "Fetching search suggestions from \(engine.name)")
            }
        }
    }
}
