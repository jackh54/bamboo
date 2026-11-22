import AppKit

/// The menu bar, built in code. Items have a nil target so their actions go
/// down the responder chain: window actions land on the key window's
/// `BrowserWindowController`, app actions on `AppDelegate`.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(historyMenu()))
        main.addItem(submenu(bookmarksMenu()))
        main.addItem(submenu(tabMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Bamboo")
        menu.addItem(item("About Bamboo", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(item("Import Browser Data…", #selector(AppDelegate.showImport(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Bamboo", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Bamboo", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(BrowserWindowController.newTab(_:)), "t"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift]))
        menu.addItem(item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]))
        menu.addItem(item("Open Location…", #selector(BrowserWindowController.openLocation(_:)), "l"))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Page URL", #selector(BrowserWindowController.copyPageURL(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"))
        find.addItem(item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"))
        find.addItem(item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]))
        menu.addItem(submenu(find))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // ⌘S stays free for Save Page, as in Brave and Chrome.
        menu.addItem(item("Hide Sidebar", #selector(BrowserWindowController.toggleBrowserSidebar(_:)), "s", [.control, .command]))
        menu.addItem(item("Ask Claude", #selector(BrowserWindowController.toggleAssistant(_:)), "j"))
        menu.addItem(item("Command Palette", #selector(BrowserWindowController.showCommandPalette(_:)), "k"))
        let spaces = NSMenu(title: "Spaces")
        for index in 1...9 {
            // The controller retitles these with the window's space names.
            let entry = item("Space \(index)", #selector(BrowserWindowController.selectSpaceByIndex(_:)), "\(index)", [.control])
            entry.tag = index
            spaces.addItem(entry)
        }
        menu.addItem(submenu(spaces))
        menu.addItem(.separator())
        menu.addItem(item("Always Show Bookmarks Bar", #selector(BrowserWindowController.toggleBookmarksBar(_:)), "b", [.command, .shift]))
        menu.addItem(item("Use Vertical Tabs", #selector(BrowserWindowController.toggleTabLayout(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        menu.addItem(item("Reload Ignoring Cache", #selector(BrowserWindowController.reloadFromOrigin(_:)), "r", [.command, .shift]))
        menu.addItem(item("Stop", #selector(BrowserWindowController.stopLoading(_:)), "."))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Reader", #selector(BrowserWindowController.toggleReader(_:)), "r", [.command, .option]))
        menu.addItem(item("Web Inspector", #selector(BrowserWindowController.showWebInspector(_:)), "i", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func historyMenu() -> NSMenu {
        let menu = NSMenu(title: "History")
        menu.addItem(item("Back", #selector(BrowserWindowController.goBack(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"))
        menu.addItem(item("Home", #selector(BrowserWindowController.goHome(_:)), "h", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show All History", #selector(BrowserWindowController.showHistory(_:)), "y"))
        menu.addItem(item("Clear Browsing Data…", #selector(AppDelegate.showClearBrowsingData(_:)), "\u{8}", [.command, .shift]))
        return menu
    }

    private static func bookmarksMenu() -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        menu.addItem(item("Bookmark This Page", #selector(BrowserWindowController.bookmarkPage(_:)), "d"))
        menu.addItem(item("Show Bookmarks", #selector(BrowserWindowController.showBookmarks(_:)), "b", [.command, .option]))
        return menu
    }

    private static func tabMenu() -> NSMenu {
        let menu = NSMenu(title: "Tab")
        menu.addItem(item("Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "\t", [.control]))
        menu.addItem(item("Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "\t", [.control, .shift]))
        menu.addItem(item("Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), "]", [.command, .shift], alternate: true))
        menu.addItem(item("Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), "[", [.command, .shift], alternate: true))
        let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        menu.addItem(item("Show Next Tab", #selector(BrowserWindowController.selectNextTab(_:)), rightArrow, [.command, .option], alternate: true))
        menu.addItem(item("Show Previous Tab", #selector(BrowserWindowController.selectPreviousTab(_:)), leftArrow, [.command, .option], alternate: true))
        menu.addItem(.separator())
        for index in 1...9 {
            let title = index == 9 ? "Select Last Tab" : "Select Tab \(index)"
            let entry = item(title, #selector(BrowserWindowController.selectTabByIndex(_:)), "\(index)")
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Pin Tab", #selector(BrowserWindowController.togglePinTab(_:))))
        menu.addItem(item("Duplicate Tab", #selector(BrowserWindowController.duplicateTab(_:))))
        menu.addItem(item("Let Agents Control This Tab", #selector(BrowserWindowController.toggleAgentControl(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Downloads", #selector(BrowserWindowController.showDownloads(_:)), "l", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Bamboo on GitHub", #selector(AppDelegate.openProjectPage(_:))))
        menu.addItem(item("Report an Issue…", #selector(AppDelegate.reportIssue(_:))))
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command], alternate: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if alternate {
            // A second shortcut for the same command, hidden from the menu.
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
