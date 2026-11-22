import WebKit

/// Records visits in the profile's history. Private tabs record nothing.
@MainActor
final class HistoryTabExtension: TabExtension {
    private var pendingKinds: [Tab.ID: VisitKind] = [:]

    func decidePolicy(for action: WKNavigationAction, preferences: WKWebpagePreferences, in tab: Tab) async -> NavigationPolicy {
        if action.targetFrame?.isMainFrame ?? false {
            pendingKinds[tab.id] = switch action.navigationType {
            case .linkActivated: .link
            case .formSubmitted, .formResubmitted: .formSubmit
            case .reload: .reload
            case .backForward: .other
            // Loads started by the browser itself: typed in the address bar, a bookmark, a restore.
            case .other: .typed
            @unknown default: .other
            }
        }
        return .allow
    }

    func didCommitNavigation(in tab: Tab) {
        let kind = pendingKinds.removeValue(forKey: tab.id) ?? .other
        guard !tab.isPrivate, let url = tab.url, Self.isRecordable(url) else { return }
        let title = tab.title.isEmpty ? nil : tab.title
        let now = Int64(Date.now.timeIntervalSince1970 * 1000)
        do {
            try tab.profile.store.recordVisit(url: url.absoluteString, title: title, kind: kind, atMs: now)
        } catch {
            AppServices.shared.reportNonFatal(error, "Recording a history visit")
        }
    }

    func didFinishNavigation(in tab: Tab) {
        guard !tab.isPrivate, let url = tab.url, Self.isRecordable(url), !tab.title.isEmpty else { return }
        do {
            try tab.profile.store.setTitle(url: url.absoluteString, title: tab.title)
        } catch {
            AppServices.shared.reportNonFatal(error, "Saving a page title to history")
        }
    }

    func willClose(_ tab: Tab) {
        pendingKinds[tab.id] = nil
    }

    private static func isRecordable(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }
}
