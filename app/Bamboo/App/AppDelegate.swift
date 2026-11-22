import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: AppServices { AppServices.shared }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            services.windows.open(url)
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

    @objc func newWindow(_ sender: Any?) {
        services.windows.newWindow()
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
