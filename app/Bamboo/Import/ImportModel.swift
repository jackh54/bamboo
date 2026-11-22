import Foundation
import Observation

/// What an import brought in, shown when it finishes.
struct ImportSummary {
    struct Result: Identifiable {
        let kind: ImportKind
        let detail: String
        let succeeded: Bool
        var id: ImportKind { kind }
    }

    let browserName: String
    var results: [Result] = []
    var warnings: [String] = []
    var extensions: [ImportedExtension] = []
    /// The source browser's default search engine, when Bamboo has it built in.
    var matchingEngine: SearchEngineID?
    /// macOS privacy protection blocked a kind; the user has to grant Full Disk Access.
    var needsFullDiskAccess = false
}

/// The import flow's state. SettingsView owns it, so an import keeps going while the user
/// looks at other settings.
@MainActor
@Observable
final class ImportModel {
    enum Phase {
        case choosing
        case importing(ImportKind, step: Int, of: Int)
        case finished(ImportSummary)
    }

    /// Nil until the first look for other browsers finishes.
    private(set) var sources: [SourceProfile]?
    private(set) var selectedSourceDirectory: String?
    var kinds: Set<ImportKind> = []
    private(set) var phase = Phase.choosing

    /// The order kinds are imported and listed in.
    static let kindOrder: [ImportKind] = [.bookmarks, .history, .passwords, .cookies, .searchEngines, .extensions]

    var selectedSource: SourceProfile? {
        sources?.first { $0.profileDir == selectedSourceDirectory }
    }

    func discover() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached(priority: .userInitiated) { discoverProfiles(homeDir: home) }.value
        sources = found
        if selectedSource == nil {
            select(found.first { $0.accessError == nil })
        }
    }

    func select(_ source: SourceProfile?) {
        selectedSourceDirectory = source?.profileDir
        kinds = Set(source?.kinds ?? [])
    }

    /// Imports each selected kind on its own, so one that fails (the user denies Keychain
    /// access, say) doesn't stop the others.
    func run(_ source: SourceProfile, into profile: Profile) async {
        let selected = Self.kindOrder.filter { kinds.contains($0) && source.kinds.contains($0) }
        var summary = ImportSummary(browserName: source.browserName)
        for (index, kind) in selected.enumerated() {
            phase = .importing(kind, step: index + 1, of: selected.count)
            do {
                let request = ImportRequest(kinds: [kind], historySinceMs: nil)
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try importProfile(profile: source, request: request)
                }.value
                summary.warnings += bundle.warnings
                let detail = try await apply(kind, from: bundle, into: profile, summary: &summary)
                summary.results.append(.init(kind: kind, detail: detail, succeeded: true))
            } catch {
                if case ImportError.PermissionDenied = error {
                    summary.needsFullDiskAccess = true
                }
                summary.results.append(.init(kind: kind, detail: userFacingMessage(error), succeeded: false))
            }
        }
        phase = .finished(summary)
    }

    func finish() {
        phase = .choosing
    }

    private func apply(
        _ kind: ImportKind, from bundle: ImportBundle, into profile: Profile, summary: inout ImportSummary
    ) async throws -> String {
        let store = profile.store
        switch kind {
        case .bookmarks:
            let title = ImportMapping.bookmarksFolderTitle(for: bundle.source)
            let items = ImportMapping.bookmarks(bundle.bookmarks)
            let count = try await Task.detached { try store.importBookmarks(folderTitle: title, items: items) }.value
            return "\(Self.counted(Int(count), "bookmark")) in “\(title)”"

        case .history:
            let items = ImportMapping.history(bundle.history)
            let count = try await Task.detached { try store.importHistory(items: items) }.value
            return Self.counted(Int(count), "page")

        case .cookies:
            let now = Date.now
            let cookies = bundle.cookies.compactMap { ImportMapping.cookie($0, now: now) }
            for cookie in cookies {
                await profile.dataStore.httpCookieStore.setCookie(cookie)
            }
            let skipped = bundle.cookies.count - cookies.count
            return Self.counted(cookies.count, "cookie") + (skipped > 0 ? ", skipped \(skipped) expired or invalid" : "")

        case .passwords:
            let logins = bundle.logins.compactMap(ImportMapping.login)
            let added = try AppServices.shared.passwords.saveNew(logins)
            var detail = Self.counted(added, "password")
            if logins.count > added {
                detail += ", skipped \(logins.count - added) already saved"
            }
            if bundle.logins.count > logins.count {
                detail += ", skipped \(bundle.logins.count - logins.count) not for websites"
            }
            return detail

        case .searchEngines:
            summary.matchingEngine = ImportMapping.builtInEngine(matching: bundle.searchEngines)
            return "Found \(Self.counted(bundle.searchEngines.count, "search engine"))"

        case .extensions:
            summary.extensions = bundle.extensions
            return "Found \(Self.counted(bundle.extensions.count, "extension")). Bamboo can't run extensions yet."
        }
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
