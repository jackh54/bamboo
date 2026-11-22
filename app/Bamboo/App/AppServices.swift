import AppKit
import Observation
import os

/// Process-wide services. Created on first use from the main thread; `start()`
/// runs once at launch.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings = AppSettings()
    let profiles = ProfileManager()
    let windows = WindowManager()
    let downloads = DownloadManager()
    let shields = ShieldsManager()
    let agent = AgentHub()
    let updater = Updater()

    /// Features hooked into every tab, in call order. See `TabExtension`.
    private(set) var tabExtensions: [any TabExtension] = []

    private let log = Logger(subsystem: "dev.pandascript.Bamboo", category: "app")
    private var hibernationTask: Task<Void, Never>?

    private init() {}

    func start() {
        tabExtensions = [
            HistoryTabExtension(),
            FaviconLoader.shared,
        ]
        shields.start()
        agent.start()
        applyAppearance()

        let restored = settings.startupBehavior == .restoreSession && windows.restoreSession()
        if !restored {
            windows.newWindow()
        }
        startHibernation()
    }

    func prepareForTermination() {
        windows.saveSession()
        agent.stop()
    }

    /// For failures the browser can keep running through (a history write, a
    /// favicon fetch): logged, and an assertion in debug builds so they get noticed.
    func reportNonFatal(_ error: Error, _ context: String) {
        log.error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        assertionFailure("\(context): \(error)")
    }

    private func applyAppearance() {
        withObservationTracking {
            NSApp.appearance = switch settings.appearance {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        } onChange: {
            Task { @MainActor in AppServices.shared.applyAppearance() }
        }
    }

    private func startHibernation() {
        hibernationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                let minutes = settings.hibernateAfterMinutes
                if minutes > 0 {
                    await windows.hibernateIdleTabs(olderThan: minutes)
                }
            }
        }
    }
}
