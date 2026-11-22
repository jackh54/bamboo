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

    struct ProfileResults: Identifiable {
        let profileDir: String
        let profileName: String
        var results: [Result] = []
        var id: String { profileDir }
    }

    let browserName: String
    var profiles: [ProfileResults] = []
    var warnings: [String] = []
    var extensions: [ImportedExtension] = []
    /// The source browser's default search engine, when Bamboo has it built in.
    var matchingEngine: SearchEngineID?
    /// macOS privacy protection blocked a kind; the user has to grant Full Disk Access.
    var needsFullDiskAccess = false

    var succeeded: Bool {
        profiles.allSatisfy { $0.results.allSatisfy(\.succeeded) }
    }
}

/// The import flow's state. SettingsView owns it, so an import keeps going while the user
/// looks at other settings.
@MainActor
@Observable
final class ImportModel {
    enum Phase {
        case choosing
        /// `profileName` is set when more than one profile is being imported.
        case importing(ImportKind, profileName: String?, step: Int, of: Int)
        case finished(ImportSummary)
    }

    /// Where an import goes.
    enum Destination: Hashable {
        /// Each source profile into the Bamboo profile with its name, created when missing,
        /// so profiles stay separate as they were in the other browser.
        case matchingProfiles
        case profile(Profile.ID)
    }

    /// A browser Bamboo can read, with its profiles in the order they were found.
    struct Browser: Identifiable {
        let kind: BrowserKind
        let name: String
        var profiles: [SourceProfile]
        var id: BrowserKind { kind }
    }

    /// Nil until the first look for other browsers finishes.
    private(set) var sources: [SourceProfile]?
    private(set) var selectedBrowser: BrowserKind?
    private(set) var selectedProfileDirectories: Set<String> = []
    var kinds: Set<ImportKind> = []
    private(set) var phase = Phase.choosing

    /// The order kinds are imported and listed in.
    static let kindOrder: [ImportKind] = [.bookmarks, .history, .passwords, .cookies, .searchEngines, .extensions]

    var browsers: [Browser] {
        var browsers: [Browser] = []
        for source in sources ?? [] where source.accessError == nil {
            if let index = browsers.firstIndex(where: { $0.kind == source.browser }) {
                browsers[index].profiles.append(source)
            } else {
                browsers.append(Browser(kind: source.browser, name: source.browserName, profiles: [source]))
            }
        }
        return browsers
    }

    var chosenBrowser: Browser? {
        browsers.first { $0.kind == selectedBrowser }
    }

    /// The ticked profiles of the chosen browser.
    var selectedSources: [SourceProfile] {
        chosenBrowser?.profiles.filter { selectedProfileDirectories.contains($0.profileDir) } ?? []
    }

    /// What the ticked profiles have, in import order.
    var availableKinds: [ImportKind] {
        let present = Set(selectedSources.flatMap(\.kinds))
        return Self.kindOrder.filter(present.contains)
    }

    var canImport: Bool {
        availableKinds.contains(where: kinds.contains)
    }

    func discover() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached(priority: .userInitiated) { discoverProfiles(homeDir: home) }.value
        sources = found
        if chosenBrowser == nil {
            select(browsers.first?.kind)
        }
    }

    /// Chooses a browser with all of its profiles and everything they have.
    func select(_ browser: BrowserKind?) {
        selectedBrowser = browser
        let profiles = chosenBrowser?.profiles ?? []
        selectedProfileDirectories = Set(profiles.map(\.profileDir))
        kinds = Set(profiles.flatMap(\.kinds))
    }

    func setProfile(_ profileDir: String, selected: Bool) {
        if selected {
            selectedProfileDirectories.insert(profileDir)
        } else {
            selectedProfileDirectories.remove(profileDir)
        }
    }

    /// Imports each selected kind of each profile on its own, so one that fails (the user
    /// denies Keychain access, say) doesn't stop the others. The run shares one session,
    /// so macOS asks for the browser's Keychain key once.
    func run(_ sources: [SourceProfile], into destination: Destination) async {
        guard let first = sources.first else {
            preconditionFailure("Import started with no profiles")
        }
        let namesProfiles = sources.count > 1
        // Separate profiles each get their own "Imported from Brave" folder.
        let foldersNameProfile = namesProfiles && destination != .matchingProfiles
        var profile = AppServices.shared.profiles.defaultProfile
        let steps = sources.flatMap { source in
            Self.kindOrder.filter { kinds.contains($0) && source.kinds.contains($0) }.map { (source, $0) }
        }
        let session = ImportSession()
        var summary = ImportSummary(browserName: first.browserName)
        for (index, (source, kind)) in steps.enumerated() {
            phase = .importing(kind, profileName: namesProfiles ? source.profileName : nil, step: index + 1, of: steps.count)
            if summary.profiles.last?.profileDir != source.profileDir {
                summary.profiles.append(.init(profileDir: source.profileDir, profileName: source.profileName))
                profile = Self.profile(for: source, in: destination)
            }
            let result: ImportSummary.Result
            do {
                let request = ImportRequest(kinds: [kind], historySinceMs: nil)
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try session.importProfile(profile: source, request: request)
                }.value
                summary.warnings += bundle.warnings.map { namesProfiles ? "\(source.profileName): \($0)" : $0 }
                let detail = try await apply(kind, from: bundle, into: profile, namingProfile: foldersNameProfile, summary: &summary)
                result = .init(kind: kind, detail: detail, succeeded: true)
            } catch {
                if case ImportError.PermissionDenied = error {
                    summary.needsFullDiskAccess = true
                }
                result = .init(kind: kind, detail: userFacingMessage(error), succeeded: false)
            }
            summary.profiles[summary.profiles.count - 1].results.append(result)
        }
        phase = .finished(summary)
    }

    private static func profile(for source: SourceProfile, in destination: Destination) -> Profile {
        let profiles = AppServices.shared.profiles
        switch destination {
        case .matchingProfiles:
            return profiles.profile(named: source.profileName)
        case .profile(let id):
            guard let profile = profiles.profile(id: id) else {
                preconditionFailure("The import's target profile \(id) no longer exists")
            }
            return profile
        }
    }

    func finish() {
        phase = .choosing
    }

    private func apply(
        _ kind: ImportKind, from bundle: ImportBundle, into profile: Profile, namingProfile: Bool,
        summary: inout ImportSummary
    ) async throws -> String {
        let store = profile.store
        switch kind {
        case .bookmarks:
            let title = ImportMapping.bookmarksFolderTitle(for: bundle.source, namingProfile: namingProfile)
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
            let added = try profile.passwords.saveNew(logins)
            var detail = Self.counted(added, "password")
            if logins.count > added {
                detail += ", skipped \(logins.count - added) already saved"
            }
            if bundle.logins.count > logins.count {
                detail += ", skipped \(bundle.logins.count - logins.count) not for websites"
            }
            return detail

        case .searchEngines:
            if summary.matchingEngine == nil {
                summary.matchingEngine = ImportMapping.builtInEngine(matching: bundle.searchEngines)
            }
            return "Found \(Self.counted(bundle.searchEngines.count, "search engine"))"

        case .extensions:
            let listed = Set(summary.extensions.map(\.id))
            summary.extensions += bundle.extensions.filter { !listed.contains($0.id) }
            return "Found \(Self.counted(bundle.extensions.count, "extension")). Bamboo can't run extensions yet."
        }
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
    }
}
