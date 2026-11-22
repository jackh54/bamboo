import AppKit
import SwiftUI

/// Brave's "Get started": profiles, importing, the default browser and what opens at startup.
struct GetStartedSettingsView: View {
    let selection: SettingsSelection
    @Bindable private var settings = AppServices.shared.settings
    private let profiles = AppServices.shared.profiles
    @State private var deleting: Profile?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(profiles.profiles) { profile in
                    ProfileRow(profile: profile, isInUse: Self.isInUse(profile)) {
                        deleting = profile
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Add New Profile") {
                        profiles.createProfile(name: "Profile \(profiles.profiles.count + 1)", symbol: "person.crop.circle")
                    }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text("Each profile keeps its own cookies, history, bookmarks and site settings. Each space in the sidebar uses one profile.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import bookmarks and settings")
                        Text("From Brave, Chrome, Firefox, Safari and other browsers")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import…") { selection.isImportPresented = true }
                }
            }

            Section("Default browser") {
                DefaultBrowserRow()
            }

            Section("On startup") {
                Picker("On startup", selection: $settings.startupBehavior) {
                    Text("Continue where you left off").tag(StartupBehavior.restoreSession)
                    Text("Open a new window").tag(StartupBehavior.newTab)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete this profile?",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            presenting: deleting
        ) { profile in
            Button("Delete “\(profile.name)”", role: .destructive) {
                Task { await delete(profile) }
            }
        } message: { profile in
            Text("Its cookies, history, bookmarks and site settings are deleted from this Mac. You can’t undo this.")
        }
    }

    /// A profile can't be deleted while a space in an open window uses it.
    private static func isInUse(_ profile: Profile) -> Bool {
        AppServices.shared.windows.models.contains { window in
            window.spaces.contains { $0.profile === profile }
        }
    }

    private func delete(_ profile: Profile) async {
        do {
            try await profiles.deleteProfile(profile)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t delete all of “\(profile.name)”’s data: \(error.localizedDescription)"
        }
    }
}

private struct ProfileRow: View {
    @Bindable var profile: Profile
    let isInUse: Bool
    let delete: () -> Void

    private static let symbols = [
        "person.crop.circle", "briefcase", "house", "graduationcap", "heart", "star", "leaf", "gamecontroller",
    ]

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button {
                        profile.symbol = symbol
                    } label: {
                        Label(symbol, systemImage: symbol)
                            .labelStyle(.iconOnly)
                    }
                }
            } label: {
                Image(systemName: profile.symbol)
                    .font(.system(size: 15))
                    .frame(width: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose an icon")

            TextField("Name", text: $profile.name)
                .labelsHidden()
                .textFieldStyle(.plain)

            if profile.isDefault {
                Text("Default")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Delete…", action: delete)
                    .disabled(isInUse)
                    .help(isInUse ? "Close the spaces that use this profile first." : "Delete this profile and its data")
            }
        }
        .onChange(of: profile.name) { AppServices.shared.profiles.save() }
        .onChange(of: profile.symbol) { AppServices.shared.profiles.save() }
    }
}

/// Whether Bamboo opens web links from other apps, with a button to make it so.
private struct DefaultBrowserRow: View {
    @State private var currentBrowser: URL?
    @State private var errorMessage: String?

    private var isDefault: Bool {
        currentBrowser.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(isDefault ? "Bamboo is your default browser" : "Bamboo isn’t your default browser")
                    .font(.headline)
                Text(errorMessage ?? detail)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if !isDefault {
                Button("Make Default") {
                    Task { await makeDefault() }
                }
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var detail: String {
        if isDefault { return "Links you open in other apps open here." }
        guard let currentBrowser else { return "No app is set to open web links." }
        return "Links you open in other apps open in \(currentBrowser.deletingPathExtension().lastPathComponent)."
    }

    private func refresh() {
        guard let probe = URL(string: "https://example.com") else { preconditionFailure("Invalid probe URL") }
        currentBrowser = NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    private func makeDefault() async {
        do {
            // macOS asks the user to confirm the change.
            for scheme in ["http", "https"] {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
