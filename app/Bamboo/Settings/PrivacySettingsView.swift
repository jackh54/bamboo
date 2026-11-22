import AppKit
import SwiftUI

struct PrivacySettingsView: View {
    @Bindable private var settings = AppServices.shared.settings

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear browsing data")
                        Text("History, cookies, cache and more")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear…") {
                        NSApp.sendAction(#selector(AppDelegate.showClearBrowsingData(_:)), to: nil, from: nil)
                    }
                }
                Toggle(isOn: $settings.clearDataOnQuit) {
                    Text("Clear history, cookies and cache when Bamboo quits")
                    Text("Signs you out of websites each time you quit.")
                }
            }

            Section {
                Toggle(isOn: $settings.globalPrivacyControl) {
                    Text("Use Global Privacy Control")
                    Text("Tells websites not to sell or share your data. Some laws require sites to honor it. Applies to tabs opened after you change it.")
                }
                Toggle(isOn: $settings.stripTrackingParameters) {
                    Text("Remove tracking parameters from links")
                    Text("Drops parts of web addresses such as utm_source and fbclid that follow you from site to site.")
                }
            }

            SiteAndShieldsSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// Brave's "Site and Shields settings": every site whose settings differ from the defaults,
/// per profile, each editable or resettable.
private struct SiteAndShieldsSettingsSection: View {
    @State private var profileID: Profile.ID?
    @State private var sites: [SiteSettings] = []
    @State private var editing: SiteEditorTarget?
    @State private var errorMessage: String?

    private var profiles: ProfileManager { AppServices.shared.profiles }

    private var profile: Profile {
        profileID.flatMap(profiles.profile(id:)) ?? profiles.defaultProfile
    }

    var body: some View {
        Section {
            if profiles.profiles.count > 1 {
                Picker("Profile", selection: Binding { profile.id } set: { profileID = $0 }) {
                    ForEach(profiles.profiles) { Text($0.name).tag($0.id) }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if sites.isEmpty {
                Text("Sites where you change shields or permissions appear here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sites, id: \.host) { site in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.host)
                        Text(Self.changes(site))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = SiteEditorTarget(host: site.host) }
                    Button("Reset") { reset(site) }
                }
            }
            HStack {
                Spacer()
                Button("Add Site…") { editing = SiteEditorTarget(host: nil) }
            }
        } header: {
            Text("Site and Shields settings")
        }
        .task(id: profile.id) { load() }
        .sheet(item: $editing, onDismiss: load) { target in
            SiteSettingsEditor(profile: profile, initialHost: target.host)
        }
    }

    private func load() {
        do {
            sites = try profile.store.customizedSites()
            errorMessage = nil
        } catch {
            sites = []
            errorMessage = "Couldn’t read site settings: \(userFacingMessage(error))"
        }
    }

    private func reset(_ site: SiteSettings) {
        do {
            try profile.store.resetSiteSettings(host: site.host)
        } catch {
            errorMessage = "Couldn’t reset \(site.host): \(userFacingMessage(error))"
            return
        }
        load()
    }

    /// What differs from the defaults (shields up, JavaScript on, everything Ask, 100% zoom).
    private static func changes(_ site: SiteSettings) -> String {
        var changes: [String] = []
        if !site.shieldsUp {
            changes.append("Shields down")
        } else {
            if !site.shieldsEnabled { changes.append("Trackers & ads allowed") }
            if !site.javascriptEnabled { changes.append("Scripts blocked") }
            if site.lockdownMode { changes.append("Lockdown Mode") }
        }
        for (name, state) in [("Camera", site.camera), ("Microphone", site.microphone),
                              ("Location", site.location), ("Pop-ups", site.popups)] where state != .ask {
            changes.append("\(name) \(state == .allow ? "allowed" : "blocked")")
        }
        if site.zoom != 1 { changes.append("Zoom \(site.zoom.formatted(.percent.precision(.fractionLength(0))))") }
        return changes.joined(separator: ", ")
    }
}

private struct SiteEditorTarget: Identifiable {
    let id = UUID()
    /// Nil when adding a site; the editor asks for it.
    let host: String?
}

/// Shields and permissions for one site. Each change is saved at once.
private struct SiteSettingsEditor: View {
    let profile: Profile
    let initialHost: String?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var site: SiteSettings?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(site.map { "Settings for \($0.host)" } ?? "Add a site")
                .font(.headline)

            if site == nil {
                TextField("Website", text: $address, prompt: Text("example.com"))
                    .onSubmit(lookUp)
            }

            if let site {
                Form {
                    Section("Shields") {
                        Toggle("Trackers & ads blocking", isOn: binding(\.shieldsEnabled, in: site))
                        Toggle("Block scripts", isOn: Binding { !site.javascriptEnabled } set: { blocks in
                            save { $0.javascriptEnabled = !blocks }
                        })
                        Toggle("Lockdown Mode", isOn: binding(\.lockdownMode, in: site))
                    }
                    Section("Permissions") {
                        Picker("Camera", selection: binding(\.camera, in: site)) { PermissionOptions() }
                        Picker("Microphone", selection: binding(\.microphone, in: site)) { PermissionOptions() }
                    }
                }
                .formStyle(.grouped)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                if site == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue", action: lookUp)
                        .keyboardShortcut(.defaultAction)
                        .disabled(Self.host(from: address) == nil)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let initialHost { load(initialHost) }
        }
    }

    private func lookUp() {
        guard let host = Self.host(from: address) else { return }
        load(host)
    }

    private func load(_ host: String) {
        do {
            site = try profile.store.siteSettings(host: host)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t read the settings for \(host): \(userFacingMessage(error))"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SiteSettings, Value>, in site: SiteSettings) -> Binding<Value> {
        Binding { site[keyPath: keyPath] } set: { value in save { $0[keyPath: keyPath] = value } }
    }

    private func save(_ change: (inout SiteSettings) -> Void) {
        guard var updated = site else { return }
        change(&updated)
        do {
            try profile.store.saveSiteSettings(settings: updated)
            site = updated
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t save: \(userFacingMessage(error))"
        }
    }

    /// "example.com", "https://example.com/page" and "www.example.com" all name a host.
    static func host(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        return url?.host().flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Ask, Allow and Block, for a site permission picker.
private struct PermissionOptions: View {
    var body: some View {
        Text("Ask").tag(PermissionState.ask)
        Text("Allow").tag(PermissionState.allow)
        Text("Block").tag(PermissionState.deny)
    }
}
