import WebKit

/// Applies a site's saved camera and microphone permissions and page zoom.
///
/// Camera and microphone: Allow grants, Deny refuses, and Ask leaves the decision to WebKit,
/// which asks the user. Geolocation is not handled: before macOS 27, WebKit on macOS has no
/// public hook for it and denies every request the UI delegate doesn't answer, so sites can't
/// read the location. macOS 27 adds `WKUIDelegate.webView(_:requestGeolocationPermissionFor:initiatedBy:)`;
/// answering it from `SiteSettings.location` needs a matching `TabExtension` hook.
@MainActor
final class SiteSettingsTabExtension: TabExtension {
    func didCreate(_ webView: WKWebView, for tab: Tab) {
        webView.pageZoom = AppServices.shared.settings.defaultPageZoom
    }

    /// A zoom saved for the site wins over the default; otherwise the tab keeps whatever
    /// zoom the user set while browsing.
    func didCommitNavigation(in tab: Tab) {
        guard let webView = tab.webView, let host = tab.url?.host(),
              let zoom = tab.profile.siteSettings(for: host)?.zoom, zoom != 1, webView.pageZoom != zoom
        else { return }
        webView.pageZoom = zoom
    }

    func mediaCapturePermission(for origin: WKSecurityOrigin, type: WKMediaCaptureType, in tab: Tab) async -> WKPermissionDecision? {
        guard let site = tab.profile.siteSettings(for: origin.host) else { return nil }
        return Self.decision(for: type, site: site)
    }

    static func decision(for type: WKMediaCaptureType, site: SiteSettings) -> WKPermissionDecision? {
        let states: [PermissionState] = switch type {
        case .camera: [site.camera]
        case .microphone: [site.microphone]
        case .cameraAndMicrophone: [site.camera, site.microphone]
        @unknown default: []
        }
        if states.contains(.deny) { return .deny }
        if !states.isEmpty, states.allSatisfy({ $0 == .allow }) { return .grant }
        return nil
    }
}
