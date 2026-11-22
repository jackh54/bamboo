import SwiftUI

/// Bamboo can't run browser extensions yet. This lists the ones installed in the user's
/// other browsers so they know what they'd be missing, read fresh each time it opens.
struct ExtensionsSettingsView: View {
    @State private var found: [(source: SourceProfile, extensions: [ImportedExtension])]?
    @State private var failures: [String] = []

    var body: some View {
        Form {
            Section {
                Label {
                    Text("Bamboo doesn’t support browser extensions yet")
                    Text("Shields already block ads and trackers, the job most people install an extension for.")
                } icon: {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(Theme.palette(.sunset).accent)
                }
            }

            if let found {
                if found.isEmpty && failures.isEmpty {
                    Section {
                        Text("No extensions were found in your other browsers.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(found, id: \.source.profileDir) { entry in
                    Section("\(entry.source.browserName), \(entry.source.profileName)") {
                        ForEach(entry.extensions, id: \.id) { item in
                            LabeledContent {
                                Text("Not supported yet")
                                    .foregroundStyle(.secondary)
                            } label: {
                                Text(item.name)
                                Text("Version \(item.version)\(item.enabled ? "" : ", turned off")")
                            }
                        }
                    }
                }
                if !failures.isEmpty {
                    Section("Couldn’t read") {
                        ForEach(failures, id: \.self) { Text($0).foregroundStyle(.secondary) }
                    }
                }
            } else {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Looking at your other browsers…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private func load() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let results = await Task.detached(priority: .userInitiated) {
            let session = ImportSession()
            return discoverProfiles(homeDir: home).filter { $0.kinds.contains(.extensions) }.map { source in
                (source, Result { try session.importProfile(profile: source, request: ImportRequest(kinds: [.extensions], historySinceMs: nil)) })
            }
        }.value
        var listed: [(source: SourceProfile, extensions: [ImportedExtension])] = []
        var problems: [String] = []
        for (source, result) in results {
            switch result {
            case .success(let bundle) where !bundle.extensions.isEmpty:
                listed.append((source, bundle.extensions))
            case .success:
                break
            case .failure(let error):
                problems.append("\(source.browserName), \(source.profileName): \(userFacingMessage(error))")
            }
        }
        found = listed
        failures = problems
    }
}
