import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices { AppServices.shared }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    /// Links macOS hands over before launch finishes (it does that first when a click
    /// launches Bamboo); nil once launched. Opened after services start, so they don't
    /// race the startup window or miss the tab extensions.
    private var urlsBeforeLaunch: [URL]? = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let urls = urlsBeforeLaunch ?? []
        urlsBeforeLaunch = nil
        services.start(openEmptyWindow: urls.isEmpty)
        urls.forEach(services.windows.open)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urlsBeforeLaunch != nil {
            urlsBeforeLaunch?.append(contentsOf: urls)
        } else {
            urls.forEach(services.windows.open)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            services.windows.newWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if services.settings.warnBeforeQuitting, !services.windows.allTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit Bamboo?"
            alert.informativeText = services.settings.startupBehavior == .restoreSession
                ? "Your windows and tabs will reopen the next time you open Bamboo."
                : "Your open windows and tabs will close."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        // Later, because clearing browsing data on quit has to finish first.
        Task {
            await services.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - App-level menu actions (window-level actions live on BrowserWindowController)

    /// Opens in the front window's profile, as Brave does.
    @objc func newWindow(_ sender: Any?) {
        services.windows.newWindow(profile: services.windows.frontmostNonPrivate?.selectedSpace.profile)
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        services.windows.newWindow(isPrivate: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        services.updater.checkForUpdates()
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(section: nil)
    }

    @objc func showImport(_ sender: Any?) {
        SettingsWindowController.shared.show(section: .importData)
    }

    @objc func showClearBrowsingData(_ sender: Any?) {
        let model = services.windows.frontmost ?? services.windows.newWindow()
        model.isClearBrowsingDataVisible = true
    }

    @objc func openProjectPage(_ sender: Any?) {
        services.windows.open(AppLinks.repository)
    }

    @objc func reportIssue(_ sender: Any?) {
        services.windows.open(AppLinks.newIssue)
    }
}

enum AppLinks {
    static let repository = URL(string: "https://github.com/jackh54/bamboo")!
    static let newIssue = URL(string: "https://github.com/jackh54/bamboo/issues/new/choose")!
}
