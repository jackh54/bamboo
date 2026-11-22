import SwiftUI
import WebKit

/// Sheet for History > Clear Browsing Data…, presented by BrowserWindowView. Clears the
/// data of the profile the window's current space uses.
struct ClearBrowsingDataView: View {
    let window: BrowserWindowModel
    @Environment(\.dismiss) private var dismiss
    @State private var range = TimeRange.lastHour
    @State private var history = true
    @State private var siteData = true
    @State private var cache = true
    @State private var downloads = false
    @State private var isClearing = false
    @State private var errorMessage: String?

    enum TimeRange: CaseIterable, Identifiable {
        case lastHour, today, lastWeek, lastFourWeeks, allTime
        var id: Self { self }

        var title: String {
            switch self {
            case .lastHour: "Last hour"
            case .today: "Today"
            case .lastWeek: "Last 7 days"
            case .lastFourWeeks: "Last 4 weeks"
            case .allTime: "All time"
            }
        }

        /// The earliest time to clear from; nil clears everything.
        func start(from now: Date) -> Date? {
            switch self {
            case .lastHour: now.addingTimeInterval(-60 * 60)
            case .today: Calendar.current.startOfDay(for: now)
            case .lastWeek: now.addingTimeInterval(-7 * 24 * 60 * 60)
            case .lastFourWeeks: now.addingTimeInterval(-28 * 24 * 60 * 60)
            case .allTime: nil
            }
        }
    }

    private var kinds: BrowsingDataCleaner.Kinds {
        var kinds: BrowsingDataCleaner.Kinds = []
        if history && !window.isPrivate { kinds.insert(.history) }
        if siteData { kinds.insert(.siteData) }
        if cache { kinds.insert(.cache) }
        return kinds
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.palette(.bamboo).accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clear Browsing Data")
                        .font(.title3.weight(.semibold))
                    Text(window.isPrivate
                         ? "From this private window"
                         : "From the “\(window.selectedSpace.profile.name)” profile")
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                Picker("Time range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    if !window.isPrivate {
                        Toggle(isOn: $history) {
                            Text("History")
                            Text("Pages you visited and searched for")
                        }
                    }
                    Toggle(isOn: $siteData) {
                        Text("Cookies and site data")
                        Text("Signs you out of most websites")
                    }
                    Toggle(isOn: $cache) {
                        Text("Cached images and files")
                        Text("Some pages load more slowly the next time")
                    }
                    Toggle(isOn: $downloads) {
                        Text("Download list")
                        Text("Downloaded files stay on your Mac")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            HStack {
                if isClearing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clear Data", role: .destructive) {
                    Task { await clear() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isClearing || (kinds.isEmpty && !downloads))
            }
            .padding(20)
        }
        .frame(width: 440)
    }

    private func clear() async {
        isClearing = true
        defer { isClearing = false }
        let space = window.selectedSpace
        do {
            try await BrowsingDataCleaner.clear(
                kinds, since: range.start(from: .now), dataStore: window.dataStore(for: space),
                store: window.isPrivate ? nil : space.profile.store)
        } catch {
            errorMessage = "Couldn't clear history: \(userFacingMessage(error))"
            return
        }
        if downloads {
            AppServices.shared.downloads.clearFinished()
        }
        dismiss()
    }
}

/// Removes browsing data from a profile. Used by the Clear Browsing Data sheet and when
/// Bamboo quits with "clear data on quit" on.
@MainActor
enum BrowsingDataCleaner {
    struct Kinds: OptionSet, Sendable {
        let rawValue: Int
        static let history = Kinds(rawValue: 1 << 0)
        static let siteData = Kinds(rawValue: 1 << 1)
        static let cache = Kinds(rawValue: 1 << 2)
        static let everything: Kinds = [.history, .siteData, .cache]
    }

    private static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
    ]

    /// Clears data modified at or after `since` (everything when nil). `store` is nil for
    /// private windows, which record no history.
    static func clear(_ kinds: Kinds, since: Date?, dataStore: WKWebsiteDataStore, store: Store?) async throws {
        var types: Set<String> = []
        if kinds.contains(.cache) {
            types.formUnion(cacheTypes)
        }
        if kinds.contains(.siteData) {
            types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes))
        }
        if !types.isEmpty {
            await dataStore.removeData(ofTypes: types, modifiedSince: since ?? .distantPast)
        }
        if kinds.contains(.history), let store {
            _ = try store.clearHistory(sinceMs: since.map { Int64($0.timeIntervalSince1970 * 1000) })
        }
    }
}
