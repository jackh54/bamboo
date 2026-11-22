import Foundation
import Observation
import WebKit

/// Owns the Rust shields engine and keeps WebKit's content rule lists in sync with it:
/// compiles the current build at launch, downloads stale filter lists every day, and
/// applies each new build to every open web view.
@MainActor
@Observable
final class ShieldsManager {
    @ObservationIgnored let engine: Shields

    /// The compiled rule lists of the current build. Added to every web view whose site has shields on.
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var build: ShieldsBuild?
    private(set) var lists: [FilterListInfo] = []
    private(set) var isUpdating = false
    /// Why the last update or rebuild failed, one line per problem; shown in Settings.
    private(set) var lastError: String?

    /// Set when the catalog or custom rules changed and the next update must rebuild.
    @ObservationIgnored private var needsRebuild = false
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    static let ruleListPrefix = "bamboo-shields-"
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    init() {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("FilterLists").path
        do {
            engine = try Shields.open(stateDir: AppPaths.shieldsDirectory.path, bundledListsDir: bundled)
        } catch {
            fatalError("Cannot open shields state: \(error)")
        }
    }

    /// The most recent download of any enabled list.
    var lastUpdated: Date? {
        lists.filter(\.enabled).compactMap(\.lastUpdatedMs).max()
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    func start() {
        lists = engine.lists()
        updateTask = Task { [weak self] in
            await self?.loadBuild()
            while !Task.isCancelled {
                await self?.update(force: false)
                // Hourly checks keep lists within a day of fresh even when the Mac sleeps through a scheduled time.
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Downloads every enabled list not updated in the last day (every enabled list when
    /// `force`) and the scriptlet resources, then rebuilds if anything changed.
    func update(force: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let maxAge = force ? 0 : Self.dayMs
        let engine = engine
        var failures: [String] = []
        for list in engine.staleLists(maxAgeMs: maxAge, nowMs: Self.nowMs) {
            do {
                let text = try await Self.download(list.url)
                _ = try await Task.detached(priority: .utility) {
                    try engine.updateList(id: list.id, text: text, nowMs: Self.nowMs)
                }.value
                needsRebuild = true
            } catch {
                failures.append("\(list.title): \(userFacingMessage(error))")
            }
        }
        if engine.resourcesStale(maxAgeMs: maxAge, nowMs: Self.nowMs) {
            do {
                let json = try await Self.download(engine.resourcesUrl())
                _ = try await Task.detached(priority: .utility) {
                    try engine.updateResources(json: json, nowMs: Self.nowMs)
                }.value
                needsRebuild = true
            } catch {
                failures.append("Scriptlet resources: \(userFacingMessage(error))")
            }
        }
        // Loops because Settings can change the catalog while a rebuild is running.
        while needsRebuild {
            needsRebuild = false
            do {
                try await apply(rebuild())
            } catch {
                needsRebuild = true
                failures.append("Building rules: \(userFacingMessage(error))")
                break
            }
        }
        lists = engine.lists()
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    // MARK: - Catalog changes from Settings

    func setList(_ id: String, enabled: Bool) throws {
        try engine.setListEnabled(id: id, enabled: enabled)
        catalogChanged()
    }

    func addCustomList(url: URL) throws {
        _ = try engine.addCustomList(title: url.host() ?? url.absoluteString, url: url.absoluteString)
        catalogChanged()
    }

    func removeCustomList(_ id: String) throws {
        try engine.removeCustomList(id: id)
        catalogChanged()
    }

    func setCustomRules(_ rules: String) throws {
        try engine.setCustomRules(rules: rules)
        catalogChanged()
    }

    private func catalogChanged() {
        lists = engine.lists()
        needsRebuild = true
        Task { await update(force: false) }
    }

    // MARK: - Building and applying

    /// Marked as updating so a catalog change made meanwhile waits for the update that follows,
    /// instead of its build being replaced by this older one.
    private func loadBuild() async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            if let current = try engine.currentBuild() {
                try await apply(current)
            } else {
                try await apply(rebuild())
            }
        } catch {
            lastError = "Loading shields: \(userFacingMessage(error))"
        }
    }

    private func rebuild() async throws -> ShieldsBuild {
        let engine = engine
        return try await Task.detached(priority: .utility) { try engine.rebuild() }.value
    }

    private func apply(_ build: ShieldsBuild) async throws {
        let compiled = try await Self.compile(build.ruleSets, in: .default())
        let previous = ruleLists
        ruleLists = compiled
        self.build = build
        applyToOpenTabs(replacing: previous)
    }

    /// Puts the current rule lists on every open web view whose page blocks trackers and ads,
    /// and takes them off the others. Settings calls this when the Shields defaults change;
    /// cosmetic filtering follows at each tab's next navigation.
    func applyToOpenTabs(replacing previous: [WKContentRuleList] = []) {
        let defaults = AppServices.shared.settings
        for tab in AppServices.shared.windows.allTabs {
            guard let controller = tab.webView?.configuration.userContentController else { continue }
            previous.forEach(controller.remove)
            let site = tab.url?.host().flatMap { tab.profile.siteSettings(for: $0) }
            if SiteShields(site, defaults: defaults).blocksTrackersAndAds {
                ruleLists.forEach(controller.add)
            } else {
                ruleLists.forEach(controller.remove)
            }
        }
    }

    /// Compiles rule sets into `store`, reusing lists compiled earlier under the same
    /// identifier, and removes Bamboo lists the rule sets no longer include.
    static func compile(_ ruleSets: [ContentRuleSet], in store: WKContentRuleListStore) async throws -> [WKContentRuleList] {
        let available = Set(await store.availableIdentifiers() ?? [])
        var compiled: [WKContentRuleList] = []
        for ruleSet in ruleSets {
            if available.contains(ruleSet.identifier) {
                do {
                    if let list = try await store.contentRuleList(forIdentifier: ruleSet.identifier) {
                        compiled.append(list)
                        continue
                    }
                } catch {
                    // Lists compiled by an older WebKit can't be loaded; compiling again replaces them.
                }
            }
            guard let list = try await store.compileContentRuleList(
                forIdentifier: ruleSet.identifier, encodedContentRuleList: ruleSet.json)
            else { throw UpdateError.notCompiled(ruleSet.identifier) }
            compiled.append(list)
        }
        let current = Set(ruleSets.map(\.identifier))
        for identifier in available where identifier.hasPrefix(ruleListPrefix) && !current.contains(identifier) {
            try await store.removeContentRuleList(forIdentifier: identifier)
        }
        return compiled
    }

    // MARK: - Errors and downloads

    enum UpdateError: LocalizedError {
        case invalidURL(String)
        case status(Int)
        case notText
        case notCompiled(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let address): "“\(address)” is not a valid URL."
            case .status(let code): "The server answered HTTP \(code)."
            case .notText: "The download is not UTF-8 text."
            case .notCompiled(let identifier): "WebKit returned no rule list for \(identifier)."
            }
        }
    }

    private static func download(_ address: String) async throws -> String {
        guard let url = URL(string: address) else { throw UpdateError.invalidURL(address) }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.status(status) }
        guard let text = String(data: data, encoding: .utf8) else { throw UpdateError.notText }
        return text
    }

    private nonisolated static var nowMs: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }
}
