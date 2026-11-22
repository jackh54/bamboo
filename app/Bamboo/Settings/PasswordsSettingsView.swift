import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

struct PasswordsSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings
    private let profiles = AppServices.shared.profiles
    @State private var profileID: Profile.ID?
    @State private var query = ""
    /// Set once the user authenticates; cleared when they leave this section.
    @State private var isUnlocked = false
    @State private var revealed: [SavedLogin.ID: String] = [:]
    @State private var editing: LoginDraft?
    @State private var deleting: SavedLogin?
    @State private var isExportWarningShown = false
    @State private var errorMessage: String?

    /// Each profile has its own passwords, as in Brave. Starts on the front window's
    /// profile and stays on it until the user picks another.
    private var profile: Profile {
        profileID.flatMap(profiles.profile(id:)) ?? profiles.defaultProfile
    }

    private var passwords: PasswordStore { profile.passwords }

    private var matchingLogins: [SavedLogin] {
        guard !query.isEmpty else { return passwords.logins }
        return passwords.logins.filter {
            $0.host.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.offerToSavePasswords) {
                    Text("Offer to save passwords")
                    Text("Bamboo never offers in private windows.")
                }
                Toggle("Suggest saved passwords when you sign in", isOn: $settings.autofillPasswords)
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if profiles.profiles.count > 1 {
                Section {
                    Picker("Profile", selection: Binding { profile.id } set: { profileID = $0 }) {
                        ForEach(profiles.profiles) { Text($0.name).tag($0.id) }
                    }
                }
            }

            Section {
                if passwords.logins.isEmpty {
                    Text("Passwords you save or import appear here.")
                        .foregroundStyle(.secondary)
                } else if matchingLogins.isEmpty {
                    Text("No saved passwords match “\(query)”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(matchingLogins) { login in
                    LoginRow(
                        login: login, password: revealed[login.id],
                        reveal: { Task { await toggleReveal(login) } },
                        copy: { Task { await copy(login) } },
                        edit: { Task { await edit(login) } },
                        delete: { deleting = login })
                }
            } header: {
                HStack {
                    Text("Password Manager")
                    Spacer()
                    TextField("Search", text: $query, prompt: Text("Search"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 180)
                }
            }

            if !settings.neverSavePasswordHosts.isEmpty {
                Section("Never saved for") {
                    ForEach(settings.neverSavePasswordHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Remove") { settings.neverSavePasswordHosts.removeAll { $0 == host } }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Export Passwords…") { isExportWarningShown = true }
                        .disabled(passwords.logins.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if profileID == nil {
                profileID = AppServices.shared.windows.frontmostNonPrivate?.selectedSpace.profile.id
            }
        }
        .task(id: profile.id) {
            revealed = [:]
            load()
        }
        .onDisappear {
            isUnlocked = false
            revealed = [:]
        }
        .sheet(item: $editing) { draft in
            EditLoginSheet(draft: draft) { username, password in
                try passwords.update(draft.login, username: username, password: password)
                revealed[draft.login.id] = nil
            }
        }
        .confirmationDialog(
            "Delete this password?",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            presenting: deleting
        ) { login in
            Button("Delete Password", role: .destructive) { delete(login) }
        } message: { login in
            Text("Bamboo forgets the password for \(login.username.isEmpty ? "this login" : login.username) on \(login.host). You can’t undo this.")
        }
        .alert("Export your passwords?", isPresented: $isExportWarningShown) {
            Button("Export…") { Task { await export() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file is plain text: anyone who can open it can read every password in it. Delete it once you’ve imported it elsewhere.")
        }
    }

    private func load() {
        do {
            try passwords.reload()
        } catch {
            errorMessage = "Couldn’t read saved passwords: \(error.localizedDescription)"
        }
    }

    private func toggleReveal(_ login: SavedLogin) async {
        if revealed[login.id] != nil {
            revealed[login.id] = nil
        } else if let password = await unlockedPassword(for: login) {
            revealed[login.id] = password
        }
    }

    private func copy(_ login: SavedLogin) async {
        guard let password = await unlockedPassword(for: login) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        // Asks clipboard managers not to keep it (nspasteboard.org convention).
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    private func edit(_ login: SavedLogin) async {
        guard let password = await unlockedPassword(for: login) else { return }
        editing = LoginDraft(login: login, password: password)
    }

    /// Nil when the user doesn't unlock, or switched to another profile meanwhile.
    private func unlockedPassword(for login: SavedLogin) async -> String? {
        let store = passwords
        guard await unlock(), store === passwords else { return nil }
        do {
            let password = try store.password(for: login)
            errorMessage = nil
            return password
        } catch {
            errorMessage = "Couldn’t read the password: \(error.localizedDescription)"
            return nil
        }
    }

    /// Asks for Touch ID or the Mac's password, once per visit to this section.
    private func unlock() async -> Bool {
        if isUnlocked { return true }
        do {
            try await PasswordStore.authenticate(reason: "show your saved passwords")
            isUnlocked = true
            return true
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func delete(_ login: SavedLogin) {
        do {
            try passwords.delete(login)
            revealed[login.id] = nil
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t delete the password: \(error.localizedDescription)"
        }
    }

    private func export() async {
        let store = passwords
        guard await unlock() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Bamboo Passwords.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV(to: url)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t export passwords: \(error.localizedDescription)"
        }
    }
}

private struct LoginDraft: Identifiable {
    let login: SavedLogin
    let password: String
    var id: SavedLogin.ID { login.id }
}

private struct LoginRow: View {
    let login: SavedLogin
    /// The password while it is revealed.
    let password: String?
    let reveal: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SiteMonogram(host: login.host)
            VStack(alignment: .leading, spacing: 1) {
                Text(login.host)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(login.username.isEmpty ? "No username" : login.username)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(password ?? "••••••••")
                .font(.body.monospaced())
                .foregroundStyle(password == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(1)
            Button(action: reveal) {
                Image(systemName: password == nil ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .help(password == nil ? "Show password" : "Hide password")
            Menu {
                Button("Copy Password", action: copy)
                Button("Edit…", action: edit)
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// The site's initial on a colour derived from its name, standing in for a favicon.
private struct SiteMonogram: View {
    let host: String

    private static let tints: [SpaceTint] = [.bamboo, .ocean, .sunset, .lavender, .rose]

    var body: some View {
        let name = host.hasPrefix("www.") ? host.dropFirst(4) : Substring(host)
        let tint = Self.tints[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.tints.count]
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Theme.palette(tint).accent.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

private struct EditLoginSheet: View {
    let draft: LoginDraft
    let save: (_ username: String, _ password: String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Password for \(draft.login.host)")
                .font(.headline)
            Form {
                TextField("Username", text: $username)
                TextField("Password", text: $password)
                    .font(.body.monospaced())
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try save(username, password)
                        dismiss()
                    } catch {
                        errorMessage = "Couldn’t save: \(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            username = draft.login.username
            password = draft.password
        }
    }
}
