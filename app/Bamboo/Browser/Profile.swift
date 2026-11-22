import Foundation
import Observation
import WebKit

/// A browsing profile: its own cookies and site data (WKWebsiteDataStore) and its
/// own history and bookmarks database. Private windows borrow a profile's
/// bookmarks but use a throwaway data store and record no history.
@MainActor
@Observable
final class Profile: Identifiable {
    let id: UUID
    var name: String
    var symbol: String
    let isDefault: Bool
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    @ObservationIgnored let store: Store

    init(record: ProfileRecord) {
        id = record.id
        name = record.name
        symbol = record.symbol
        isDefault = record.isDefault
        dataStore = record.isDefault && !AppEnvironment.isRunningTests
            ? .default() : WKWebsiteDataStore(forIdentifier: record.id)
        let databasePath = AppPaths.profileDirectory(record.id).appendingPathComponent("profile.sqlite").path
        do {
            store = try Store.open(path: databasePath)
        } catch {
            fatalError("Cannot open profile database at \(databasePath): \(error)")
        }
    }

    var record: ProfileRecord {
        ProfileRecord(id: id, name: name, symbol: symbol, isDefault: isDefault)
    }
}

struct ProfileRecord: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var isDefault: Bool
}

@MainActor
@Observable
final class ProfileManager {
    private(set) var profiles: [Profile]

    init() {
        let records = Self.loadRecords()
        profiles = records.map(Profile.init(record:))
        if records != profiles.map(\.record) || !FileManager.default.fileExists(atPath: AppPaths.profilesFile.path) {
            save()
        }
    }

    var defaultProfile: Profile {
        guard let profile = profiles.first(where: \.isDefault) else {
            preconditionFailure("profiles.json has no default profile")
        }
        return profile
    }

    func profile(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// The profile called `name`, created when there isn't one.
    func profile(named name: String) -> Profile {
        profiles.first { $0.name == name } ?? createProfile(name: name, symbol: "person.crop.circle")
    }

    @discardableResult
    func createProfile(name: String, symbol: String) -> Profile {
        let profile = Profile(record: ProfileRecord(id: UUID(), name: name, symbol: symbol, isDefault: false))
        profiles.append(profile)
        save()
        return profile
    }

    /// Deletes a non-default profile with all its website data and its database.
    func deleteProfile(_ profile: Profile) async throws {
        precondition(!profile.isDefault, "The default profile cannot be deleted")
        profiles.removeAll { $0.id == profile.id }
        save()
        try await WKWebsiteDataStore.remove(forIdentifier: profile.id)
        try FileManager.default.removeItem(at: AppPaths.profileDirectory(profile.id))
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(profiles.map(\.record))
            try data.write(to: AppPaths.profilesFile, options: .atomic)
        } catch {
            fatalError("Cannot write \(AppPaths.profilesFile.path): \(error)")
        }
    }

    private static func loadRecords() -> [ProfileRecord] {
        let url = AppPaths.profilesFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [ProfileRecord(id: UUID(), name: "Personal", symbol: "person.crop.circle", isDefault: true)]
        }
        do {
            return try JSONDecoder().decode([ProfileRecord].self, from: Data(contentsOf: url))
        } catch {
            fatalError("Cannot read \(url.path): \(error)")
        }
    }
}
