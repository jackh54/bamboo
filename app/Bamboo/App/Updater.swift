import Sparkle

/// Sparkle auto-updates from the GitHub Releases appcast (see SUFeedURL in project.yml).
/// Debug builds never start the updater so a dev build can't replace itself with a release.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
