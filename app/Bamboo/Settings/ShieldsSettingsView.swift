import SwiftUI

struct ShieldsSettingsView: View {
    private let shields = AppServices.shared.shields
    @Bindable private var settings = AppServices.shared.settings
    @State private var stats: BlockingStats?
    @State private var newListAddress = ""
    @State private var customRules = ""
    @State private var savedCustomRules = ""
    @State private var errorMessage: String?

    private static let builtInCategories: [ListCategory] = [.ads, .privacy, .annoyances, .cookieNotices, .security, .regional]

    var body: some View {
        Form {
            Section {
                if let stats {
                    ProtectionSummary(stats: stats)
                }
            } footer: {
                HStack {
                    Text("Counted across all profiles. Private windows aren’t counted.")
                    Spacer()
                    Button("Reset Statistics", action: resetStats)
                        .buttonStyle(.link)
                        .disabled(stats?.total == 0)
                }
                .foregroundStyle(.secondary)
            }

            defaultsSection

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            updateSection

            ForEach(Self.builtInCategories, id: \.self) { category in
                let lists = shields.lists.filter { $0.builtin && $0.category == category }
                if !lists.isEmpty {
                    Section(category.title) {
                        ForEach(lists, id: \.id) { listToggle($0) }
                    }
                }
            }

            customListsSection
            customRulesSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadStats()
            customRules = shields.engine.customRules()
            savedCustomRules = customRules
        }
        .onChange(of: settings.blockTrackersAndAds) { shields.applyToOpenTabs() }
    }

    /// Brave's "Shields defaults": what every site gets unless its Shields panel says otherwise.
    private var defaultsSection: some View {
        Section {
            Toggle(isOn: $settings.blockTrackersAndAds) {
                Text("Trackers & ads blocking")
                Text("Blocks ads, trackers and the other things your filter lists below cover.")
            }
            Picker(selection: $settings.httpsMode) {
                Text("Standard").tag(HTTPSMode.upgrade)
                Text("Strict").tag(HTTPSMode.httpsOnly)
            } label: {
                Text("Upgrade connections to HTTPS")
                Text(settings.httpsMode == .upgrade
                     ? "Tries HTTPS first and falls back to HTTP when a site doesn’t support it."
                     : "Warns you before loading any site without HTTPS. Local addresses are left alone.")
            }
            Toggle(isOn: $settings.blockScripts) {
                Text("Block scripts")
                Text("Turns JavaScript off on every site with shields up. Many sites break without it.")
            }
        } header: {
            Text("Shields defaults")
        } footer: {
            Text("Change these for one site from the Shields panel in the address bar. Changes apply as pages load.")
                .foregroundStyle(.secondary)
        }
    }

    private var updateSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let lastUpdated = shields.lastUpdated {
                        Text("Filter lists updated \(lastUpdated, format: .relative(presentation: .named))")
                    } else {
                        Text("Filter lists haven’t been downloaded yet")
                    }
                    if let build = shields.build {
                        Text("\(build.networkRules.formatted()) blocking rules and \(build.cosmeticRules.formatted()) hiding rules in use")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if shields.isUpdating {
                    ProgressView().controlSize(.small)
                }
                Button("Update Now") {
                    Task { await shields.update(force: true) }
                }
                .disabled(shields.isUpdating)
            }
            if let build = shields.build, build.unconvertibleRules > 0 {
                Text("\(build.unconvertibleRules.formatted()) rules use features WebKit doesn’t support and are skipped.")
                    .foregroundStyle(.secondary)
            }
            if let lastError = shields.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Content filtering")
        } footer: {
            Text("Enable filter lists to block more. Bamboo downloads new versions of enabled lists once a day.")
                .foregroundStyle(.secondary)
        }
    }

    private var customListsSection: some View {
        Section {
            ForEach(shields.lists.filter { !$0.builtin }, id: \.id) { list in
                HStack {
                    listToggle(list)
                    Button {
                        perform { try shields.removeCustomList(list.id) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(list.title)")
                }
            }
            HStack {
                TextField("Filter list address", text: $newListAddress, prompt: Text("https://example.com/filters.txt"))
                    .labelsHidden()
                    .onSubmit(addList)
                Button("Add", action: addList)
                    .disabled(newListURL == nil)
            }
        } header: {
            Text("Add custom filter lists")
        } footer: {
            Text("Subscribe to any list in Adblock Plus or uBlock Origin format.")
                .foregroundStyle(.secondary)
        }
    }

    private var customRulesSection: some View {
        Section {
            TextEditor(text: $customRules)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Revert") { customRules = savedCustomRules }
                    .disabled(customRules == savedCustomRules)
                Button("Save Rules") {
                    perform {
                        try shields.setCustomRules(customRules)
                        savedCustomRules = customRules
                    }
                }
                .disabled(customRules == savedCustomRules)
            }
        } header: {
            Text("Add custom filters")
        } footer: {
            Text("One filter per line, for example ||ads.example.com^ to block a server or example.com##.banner to hide part of a page.")
                .foregroundStyle(.secondary)
        }
    }

    private func listToggle(_ list: FilterListInfo) -> some View {
        Toggle(isOn: Binding {
            list.enabled
        } set: { enabled in
            perform { try shields.setList(list.id, enabled: enabled) }
        }) {
            Text(list.title)
            if let updated = list.lastUpdatedMs.map({ Date(timeIntervalSince1970: Double($0) / 1000) }) {
                Text("\(list.ruleCount.formatted()) rules, updated \(updated, format: .relative(presentation: .named))")
            } else {
                Text(list.enabled ? "Downloads at the next update" : "Not downloaded")
            }
        }
    }

    private var newListURL: URL? {
        let address = newListAddress.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    private func addList() {
        guard let url = newListURL else { return }
        perform {
            try shields.addCustomList(url: url)
            newListAddress = ""
        }
    }

    private func perform(_ change: () throws -> Void) {
        do {
            try change()
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(error)
        }
    }

    private func loadStats() {
        let since = Int64(Date.now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
        var total: UInt64 = 0
        var byHost: [String: UInt64] = [:]
        do {
            for profile in AppServices.shared.profiles.profiles {
                let profileStats = try profile.store.privacyStats(sinceMs: since, top: 10)
                total += profileStats.blockedTotal
                for tracker in profileStats.topTrackers {
                    byHost[tracker.host, default: 0] += tracker.count
                }
            }
        } catch {
            errorMessage = "Couldn’t read blocking statistics: \(userFacingMessage(error))"
            return
        }
        let top = byHost.sorted { $0.value > $1.value }.prefix(5).map { TrackerCount(host: $0.key, count: $0.value) }
        stats = BlockingStats(total: total, topTrackers: top)
    }

    private func resetStats() {
        perform {
            for profile in AppServices.shared.profiles.profiles {
                try profile.store.clearPrivacyStats()
            }
        }
        loadStats()
    }
}

private struct BlockingStats {
    let total: UInt64
    let topTrackers: [TrackerCount]
}

/// How much shields blocked recently, with the trackers met most often.
private struct ProtectionSummary: View {
    let stats: BlockingStats

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(LinearGradient(colors: Theme.palette(.bamboo).gradient, startPoint: .top, endPoint: .bottom))
                    .padding(.bottom, 6)
                Text(stats.total, format: .number)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("ads and trackers blocked in the last 30 days")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 190, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                if let most = stats.topTrackers.first?.count, most > 0 {
                    Text("Most blocked")
                        .font(.subheadline.weight(.semibold))
                    ForEach(stats.topTrackers, id: \.host) { tracker in
                        TrackerBar(host: tracker.host, count: tracker.count, fraction: Double(tracker.count) / Double(most))
                    }
                } else {
                    Text("The trackers Bamboo blocks most often will show here as you browse.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private struct TrackerBar: View {
        let host: String
        let count: UInt64
        let fraction: Double

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(count, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 5)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Theme.palette(.bamboo).accent)
                                .frame(width: max(5, proxy.size.width * fraction))
                        }
                    }
            }
        }
    }
}

extension ListCategory {
    var title: String {
        switch self {
        case .ads: "Ads"
        case .privacy: "Trackers"
        case .annoyances: "Annoyances"
        case .cookieNotices: "Cookie notices"
        case .security: "Malware and scams"
        case .regional: "Regional ads"
        case .custom: "Custom filter lists"
        }
    }
}
