import AppKit
import SwiftUI

/// ⌘K: fuzzy search over the window's tabs, its spaces and the browser's
/// commands. Commands that are menu items run through the same responder-chain
/// action as the menu, enabled and titled by the same validation.
struct CommandPalette: View {
    let model: BrowserWindowModel
    @State private var entries: [PaletteEntry] = []
    @State private var results: [PaletteEntry] = []
    @State private var selection = 0
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                CommandField(
                    placeholder: "Search tabs and commands",
                    onEdit: { text, _ in
                        results = PaletteEntry.ranked(entries, matching: text)
                        selection = 0
                        return nil
                    },
                    onMove: { offset in
                        guard !results.isEmpty else { return }
                        selection = (selection + offset + results.count) % results.count
                    },
                    onSubmit: { _ in
                        if let entry = results[safe: selection] { run(entry) }
                    },
                    onCancel: { model.isCommandPaletteVisible = false })
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if results.isEmpty {
                if !entries.isEmpty {
                    Divider().opacity(0.6)
                    Text("No tabs or commands match")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                }
            } else {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                PaletteRow(entry: entry, isSelected: index == selection, accent: accent)
                                    .onHover { if $0 { selection = index } }
                                    .onTapGesture { run(entry) }
                            }
                        }
                        .padding(6)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(height: min(CGFloat(results.count) * (PaletteRow.height + 2) + 12, 392))
                    .onChange(of: selection) { _, index in
                        if let entry = results[safe: index] { proxy.scrollTo(entry.id) }
                    }
                }
            }
        }
        .floatingSurface()
        .onAppear {
            entries = PaletteEntry.all(for: model)
            results = PaletteEntry.ranked(entries, matching: "")
        }
    }

    private func run(_ entry: PaletteEntry) {
        model.isCommandPaletteVisible = false
        entry.perform()
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry
    let isSelected: Bool
    let accent: Color

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 11) {
            Group {
                switch entry.icon {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(isSelected ? 1 : 0.75)
                case .tab(let tab):
                    FaviconView(image: tab.favicon, host: tab.url?.host(), size: 16)
                }
            }
            .frame(width: 18, height: 18)
            Text(entry.title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(1)
            if let detail = entry.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? accent : .clear)
        }
        .contentShape(Rectangle())
    }
}

struct PaletteEntry: Identifiable {
    enum Icon {
        case symbol(String)
        case tab(Tab)
    }

    enum Kind: Int {
        case command, space, tab
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    let icon: Icon
    let shortcut: String?
    let perform: @MainActor () -> Void

    /// Commands, spaces and tabs for this window, in the order shown before
    /// anything is typed.
    @MainActor
    static func all(for model: BrowserWindowModel) -> [PaletteEntry] {
        let menuCommands: [(String, Selector)] = [
            ("plus.square", #selector(BrowserWindowController.newTab(_:))),
            ("macwindow.badge.plus", #selector(AppDelegate.newWindow(_:))),
            ("eye.slash", #selector(AppDelegate.newPrivateWindow(_:))),
            ("arrow.uturn.backward", #selector(BrowserWindowController.reopenClosedTab(_:))),
            ("sidebar.left", #selector(BrowserWindowController.toggleBrowserSidebar(_:))),
            ("sparkle", #selector(BrowserWindowController.toggleAssistant(_:))),
            ("doc.plaintext", #selector(BrowserWindowController.toggleReader(_:))),
            ("text.magnifyingglass", #selector(BrowserWindowController.showFindBar(_:))),
            ("bookmark", #selector(BrowserWindowController.bookmarkPage(_:))),
            ("clock", #selector(BrowserWindowController.showHistory(_:))),
            ("book", #selector(BrowserWindowController.showBookmarks(_:))),
            ("arrow.down.circle", #selector(BrowserWindowController.showDownloads(_:))),
            ("link", #selector(BrowserWindowController.copyPageURL(_:))),
            ("pin", #selector(BrowserWindowController.togglePinTab(_:))),
            ("cursorarrow.rays", #selector(BrowserWindowController.toggleAgentControl(_:))),
            ("trash", #selector(AppDelegate.showClearBrowsingData(_:))),
            ("square.and.arrow.down", #selector(AppDelegate.showImport(_:))),
            ("gearshape", #selector(AppDelegate.showSettings(_:))),
        ]
        let commands = menuCommands.compactMap { symbol, action -> PaletteEntry? in
            guard let menuItem = MenuLookup.item(for: action), MenuLookup.validate(menuItem) else { return nil }
            return PaletteEntry(
                id: "command:\(NSStringFromSelector(action))", kind: .command,
                title: menuItem.title.replacingOccurrences(of: "…", with: ""), detail: nil,
                icon: .symbol(symbol), shortcut: MenuLookup.shortcut(menuItem)
            ) {
                NSApp.sendAction(action, to: nil, from: nil)
            }
        }

        let spaces = model.spaces.enumerated().compactMap { index, space -> PaletteEntry? in
            guard space.id != model.selectedSpaceID else { return nil }
            return PaletteEntry(
                id: "space:\(space.id)", kind: .space, title: "Switch to \(space.name)", detail: "Space",
                icon: .symbol(space.symbol), shortcut: index < 9 ? "⌃\(index + 1)" : nil
            ) {
                withAnimation(Theme.Motion.standard) { model.selectSpace(space) }
            }
        }

        let tabs = model.allTabs.compactMap { tab -> PaletteEntry? in
            guard tab !== model.selectedTab else { return nil }
            return PaletteEntry(
                id: "tab:\(tab.id)", kind: .tab, title: tab.displayTitle, detail: tab.url?.host(),
                icon: .tab(tab), shortcut: nil
            ) {
                model.select(tab)
            }
        }
        return commands + spaces + tabs
    }

    static func ranked(_ entries: [PaletteEntry], matching query: String) -> [PaletteEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries
            .compactMap { entry -> (PaletteEntry, Int)? in
                let titleScore = fuzzyScore(entry.title.lowercased(), needle)
                let detailScore = entry.detail.flatMap { fuzzyScore($0.lowercased(), needle) }.map { $0 - 4 }
                guard let score = [titleScore, detailScore].compactMap({ $0 }).max() else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.kind.rawValue < $1.0.kind.rawValue }
            .map(\.0)
    }

    /// Scores `needle` as a subsequence of `text`: matches at word starts and
    /// runs of consecutive characters count most. Nil when it doesn't match.
    static func fuzzyScore(_ text: String, _ needle: String) -> Int? {
        let haystack = Array(text)
        var score = 0
        var searchFrom = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[searchFrom...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previous + 1 { score += 3 }
            if found == 0 || " ./-:".contains(haystack[found - 1]) { score += 5 }
            previous = found
            searchFrom = found + 1
        }
        return score - haystack.count / 12
    }
}

/// Reads the main menu so the palette shows each command with the menu's own
/// title, enabled state and shortcut.
@MainActor
private enum MenuLookup {
    static func item(for action: Selector) -> NSMenuItem? {
        guard let menu = NSApp.mainMenu else { return nil }
        return find(action, in: menu)
    }

    /// Runs the same validation the menu bar would.
    static func validate(_ item: NSMenuItem) -> Bool {
        guard let action = item.action, let target = NSApp.target(forAction: action, to: nil, from: item) else { return false }
        return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
    }

    static func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let key = switch item.keyEquivalent {
        case "\u{8}": "⌫"
        case "\t": "⇥"
        default: item.keyEquivalent.uppercased()
        }
        return text + key
    }

    private static func find(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action, !item.isHidden { return item }
            if let submenu = item.submenu, let found = find(action, in: submenu) { return found }
        }
        return nil
    }
}
