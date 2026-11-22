import Foundation

/// On-disk locations. Everything lives under ~/Library/Application Support/Bamboo,
/// created with owner-only permissions.
enum AppPaths {
    static let applicationSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return makeDirectory(base.appendingPathComponent("Bamboo", isDirectory: true))
    }()

    /// The agent socket path must stay under the 104-byte `sun_path` limit,
    /// which a home directory with a long user name can exceed; fail loudly if so.
    static let agentSocket: URL = {
        let url = applicationSupport.appendingPathComponent("agent.sock")
        precondition(url.path.utf8.count < 104, "Agent socket path too long: \(url.path)")
        return url
    }()

    static let shieldsDirectory = makeDirectory(applicationSupport.appendingPathComponent("Shields", isDirectory: true))
    static let profilesDirectory = makeDirectory(applicationSupport.appendingPathComponent("Profiles", isDirectory: true))
    static let profilesFile = applicationSupport.appendingPathComponent("profiles.json")
    static let sessionFile = applicationSupport.appendingPathComponent("session.json")

    static func profileDirectory(_ id: UUID) -> URL {
        makeDirectory(profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    private static func makeDirectory(_ url: URL) -> URL {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            fatalError("Cannot create \(url.path): \(error)")
        }
        return url
    }
}
