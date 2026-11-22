import AppKit
import SwiftUI

/// Settings sections, in Brave's order. `importData` opens Get started with the import dialog.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case getStarted, appearance, content, shields, privacy, agents, search, extensions, passwords, downloads, system, about
    case importData
    var id: String { rawValue }
}

/// The Settings window (⌘,). Its content is `SettingsView`.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let selection = SettingsSelection()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(selection: selection))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code")
    }

    func show(section: SettingsSection?) {
        if section == .importData {
            selection.section = .getStarted
            selection.isImportPresented = true
        } else if let section {
            selection.section = section
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

@MainActor
@Observable
final class SettingsSelection {
    var section: SettingsSection = .getStarted
    /// The "Import bookmarks and settings" dialog is showing.
    var isImportPresented = false
}
