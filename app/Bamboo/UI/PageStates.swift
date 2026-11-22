import SwiftUI

/// Everything a tab can show over its page: the hibernation snapshot, a load
/// error, a crashed page, Reader and a JavaScript dialog.
struct TabOverlays: View {
    let tab: Tab
    let model: BrowserWindowModel

    var body: some View {
        ZStack {
            if let snapshot = tab.hibernationSnapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let error = tab.loadError {
                LoadErrorPage(tab: tab, error: error)
                    .transition(.opacity)
            } else if tab.webContentProcessCrashed {
                CrashedPage(tab: tab)
                    .transition(.opacity)
            }
            if tab.isReaderActive {
                ReaderView(tab: tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }
            if let dialog = tab.pendingDialog {
                DialogCard(dialog: dialog)
                    .id(dialog.id)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.standard, value: tab.hibernationSnapshot == nil)
        .animation(Theme.Motion.standard, value: tab.loadError)
        .animation(Theme.Motion.standard, value: tab.isReaderActive)
        .animation(Theme.Motion.quick, value: tab.pendingDialog?.id)
    }
}

/// A hairline of the space's colour along the top of the card while the page loads.
struct LoadingBar: View {
    let tab: Tab
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(accent)
                .frame(width: proxy.size.width * max(tab.estimatedProgress, 0.06))
                .shadow(color: accent.opacity(0.5), radius: 3)
                .animation(Theme.Motion.standard, value: tab.estimatedProgress)
        }
        .frame(height: 2.5)
        .opacity(tab.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.35).delay(tab.isLoading ? 0 : 0.15), value: tab.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Error and crash pages

private struct LoadErrorPage: View {
    let tab: Tab
    let error: PageLoadError

    var body: some View {
        let copy = ErrorCopy(error)
        PageMessage(symbol: copy.symbol, title: copy.title, message: copy.message,
                    detail: "\(error.domain) \(error.code)", action: "Try Again") {
            tab.loadError = nil
            if let url = error.url { tab.load(url) } else { tab.reload() }
        }
    }
}

private struct CrashedPage: View {
    let tab: Tab

    var body: some View {
        PageMessage(symbol: "exclamationmark.triangle", title: "This page stopped working",
                    message: "Its process quit unexpectedly. Reloading usually brings it back.",
                    detail: nil, action: "Reload Page") {
            tab.reload()
        }
    }
}

private struct PageMessage: View {
    let symbol: String
    let title: String
    let message: String
    let detail: String?
    let action: String
    let perform: () -> Void
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 64, height: 64)
                .background(accent.opacity(0.12), in: Circle())
                .padding(.bottom, 4)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action, action: perform)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.card, ignoresSafeAreaEdges: [])
    }
}

/// Plain words for the load failures people actually hit.
private struct ErrorCopy {
    let symbol: String
    let title: String
    let message: String

    init(_ error: PageLoadError) {
        let host = error.url?.host() ?? "The site"
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            (symbol, title, message) = ("wifi.slash", "You're offline",
                                        "Check your Wi-Fi or network connection, then try again.")
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            (symbol, title, message) = ("magnifyingglass", "Can't find \(host)",
                                        "Check the address for typos. If it's right, the site may be down or blocked by your network.")
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            (symbol, title, message) = ("bolt.horizontal", "\(host) isn't answering",
                                        "The server refused the connection. It may be down or restarting.")
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            (symbol, title, message) = ("clock", "\(host) took too long to respond",
                                        "The site may be overloaded, or your connection may be slow.")
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            (symbol, title, message) = ("wifi.exclamationmark", "The connection dropped",
                                        "Your network went away while the page was loading.")
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate),
             (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot),
             (NSURLErrorDomain, NSURLErrorServerCertificateNotYetValid),
             (NSURLErrorDomain, NSURLErrorClientCertificateRejected):
            (symbol, title, message) = ("lock.trianglebadge.exclamationmark", "This connection isn't private",
                                        "\(host)'s certificate couldn't be verified, so Bamboo stopped before sending anything. Someone may be trying to intercept the connection.")
        case (NSURLErrorDomain, NSURLErrorHTTPTooManyRedirects):
            (symbol, title, message) = ("arrow.triangle.2.circlepath", "\(host) redirected too many times",
                                        "Clearing this site's cookies often fixes it.")
        case (NSURLErrorDomain, NSURLErrorBadURL), (NSURLErrorDomain, NSURLErrorUnsupportedURL):
            (symbol, title, message) = ("link", "Bamboo can't open this address",
                                        "Check the address and try again.")
        case (NSURLErrorDomain, NSURLErrorFileDoesNotExist):
            (symbol, title, message) = ("doc.questionmark", "File not found",
                                        "The file may have been moved, renamed or deleted.")
        case (NSURLErrorDomain, NSURLErrorNoPermissionsToReadFile):
            (symbol, title, message) = ("lock.doc", "Bamboo can't read this file",
                                        "You don't have permission to open it.")
        case ("WebKitErrorDomain", _):
            (symbol, title, message) = ("doc.badge.ellipsis", "Bamboo can't show this page",
                                        error.message)
        default:
            (symbol, title, message) = ("exclamationmark.triangle", "This page couldn't load",
                                        error.message)
        }
    }
}

// MARK: - JavaScript dialogs

/// `alert`, `confirm` and `prompt`, drawn inside the tab. Return accepts and
/// Esc cancels; the card takes keyboard focus from the page while it shows.
private struct DialogCard: View {
    let dialog: JavaScriptDialog
    @State private var text: String
    @FocusState private var focus: Field?

    private enum Field {
        case card, text
    }

    init(dialog: JavaScriptDialog) {
        self.dialog = dialog
        if case .prompt(let defaultText) = dialog.kind {
            _text = State(initialValue: defaultText)
        } else {
            _text = State(initialValue: "")
        }
    }

    var body: some View {
        ZStack {
            Theme.Colors.scrim
            VStack(alignment: .leading, spacing: 12) {
                Text(dialog.origin.isEmpty ? "This page says" : "\(dialog.origin) says")
                    .font(.system(size: 13, weight: .semibold))
                ScrollView(.vertical) {
                    Text(dialog.message)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                if case .prompt = dialog.kind {
                    TextField("", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .text)
                        .onSubmit { dialog.respond(accepted: true, text: text) }
                }
                HStack(spacing: 8) {
                    Spacer()
                    if dialog.kind != .alert {
                        Button("Cancel") { dialog.respond(accepted: false) }
                            .controlSize(.large)
                    }
                    Button("OK") { dialog.respond(accepted: true, text: text) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 400)
            .background(Theme.Colors.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .card)
            .onKeyPress(.return) {
                dialog.respond(accepted: true, text: text)
                return .handled
            }
            .onExitCommand { dialog.respond(accepted: dialog.kind == .alert) }
        }
        .onAppear {
            if case .prompt = dialog.kind { focus = .text } else { focus = .card }
        }
    }
}
