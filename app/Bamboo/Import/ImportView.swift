import AppKit
import SwiftUI

/// The "Import bookmarks and settings" dialog, laid out like Brave's: pick a browser profile,
/// tick what to bring over, import, then see what arrived.
struct ImportView: View {
    @Bindable var model: ImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosenDestination: ImportModel.Destination?

    private var profiles: ProfileManager { AppServices.shared.profiles }

    /// Several profiles go into separate Bamboo profiles unless the user picks one.
    private var destination: ImportModel.Destination {
        let separate = model.selectedSources.count > 1
        switch chosenDestination {
        case .matchingProfiles? where separate:
            return .matchingProfiles
        case .profile(let id)? where profiles.profile(id: id) != nil:
            return .profile(id)
        default:
            return separate ? .matchingProfiles : .profile(profiles.defaultProfile.id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .choosing:
                Text("Import bookmarks and settings")
                    .font(.title3.weight(.semibold))
                chooser
            case .importing(let kind, let profileName, let step, let total):
                Text("Importing…")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(step - 1), total: Double(total))
                    Text("\(profileName.map { "\($0): " } ?? "")\(kind.title), \(step) of \(total)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            case .finished(let summary):
                ImportSummaryView(summary: summary) {
                    model.finish()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            if model.sources == nil {
                await model.discover()
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        if let sources = model.sources {
            let browsers = model.browsers
            let blocked = sources.filter { $0.accessError != nil }

            if browsers.isEmpty && blocked.isEmpty {
                Text("Bamboo didn’t find another browser on this Mac. It can import from Brave, Chrome, Edge, Arc, Vivaldi, Opera, Chromium, Firefox and Safari.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !browsers.isEmpty {
                Picker("From", selection: Binding { model.selectedBrowser } set: { model.select($0) }) {
                    ForEach(browsers) { browser in
                        Label {
                            Text(browser.name)
                        } icon: {
                            BrowserIcon(browser: browser.kind)
                        }
                        .tag(Optional(browser.kind))
                    }
                }
            }

            ForEach(blocked, id: \.profileDir) { source in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS is blocking Bamboo from reading \(source.browserName). Allow Bamboo in Full Disk Access, then quit and reopen Bamboo.")
                            .fixedSize(horizontal: false, vertical: true)
                        FullDiskAccessButton()
                    }
                }
                .font(.callout)
            }

            if let browser = model.chosenBrowser {
                if browser.profiles.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select profiles to import:")
                        ForEach(browser.profiles, id: \.profileDir) { source in
                            Toggle(source.profileName, isOn: Binding {
                                model.selectedProfileDirectories.contains(source.profileDir)
                            } set: { isOn in
                                model.setProfile(source.profileDir, selected: isOn)
                            })
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(.leading, 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Select items to import:")
                    ForEach(model.availableKinds, id: \.self) { kind in
                        Toggle(isOn: Binding {
                            model.kinds.contains(kind)
                        } set: { isOn in
                            if isOn { model.kinds.insert(kind) } else { model.kinds.remove(kind) }
                        }) {
                            Text(kind.title)
                            if kind == .extensions {
                                Text("Listed only: Bamboo can’t run extensions yet")
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 2)

                if model.selectedSources.count > 1 || profiles.profiles.count > 1 {
                    Picker("Import into", selection: Binding { destination } set: { chosenDestination = $0 }) {
                        if model.selectedSources.count > 1 {
                            Text("A separate profile for each").tag(ImportModel.Destination.matchingProfiles)
                        }
                        ForEach(profiles.profiles) { Text($0.name).tag(ImportModel.Destination.profile($0.id)) }
                    }
                    if destination == .matchingProfiles {
                        Text("Each \(browser.name) profile goes into the Bamboo profile with the same name. Bamboo creates the ones you don’t have.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let chosenKinds = model.availableKinds.filter(model.kinds.contains)
                if chosenKinds.contains(.passwords) || chosenKinds.contains(.cookies) {
                    Text("macOS will ask to let Bamboo use “\(browser.name) Safe Storage” from your keychain. Choose Allow so Bamboo can decrypt passwords and cookies.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    let sources = model.selectedSources
                    let destination = destination
                    Task { await model.run(sources, into: destination) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Looking for other browsers…").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImportSummaryView: View {
    let summary: ImportSummary
    let done: () -> Void
    @State private var isEngineSwitched = false

    private var settings: AppSettings { AppServices.shared.settings }
    private var succeeded: Bool { summary.succeeded }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(succeeded ? Theme.palette(.bamboo).accent : .orange)
            Text(succeeded ? "Your bookmarks and settings are ready" : "Some items couldn’t be imported")
                .font(.title3.weight(.semibold))
        }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.profiles) { profile in
                if summary.profiles.count > 1 {
                    Text(profile.profileName)
                        .font(.headline)
                        .padding(.top, 4)
                }
                ForEach(profile.results) { result in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.kind.title)
                            Text(result.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: result.succeeded ? "checkmark" : "xmark")
                            .foregroundStyle(result.succeeded ? Theme.palette(.bamboo).accent : .red)
                    }
                }
            }
        }

        if summary.needsFullDiskAccess {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS kept Bamboo from reading some of \(summary.browserName)’s data. Allow Bamboo in Full Disk Access, quit and reopen Bamboo, then import again.")
                    .fixedSize(horizontal: false, vertical: true)
                FullDiskAccessButton()
            }
            .font(.callout)
        }

        if let engine = summary.matchingEngine, engine != settings.searchEngine || isEngineSwitched {
            HStack {
                Text(isEngineSwitched
                     ? "Bamboo now searches with \(SearchEngine.engine(engine).name)."
                     : "\(summary.browserName) searches with \(SearchEngine.engine(engine).name).")
                Spacer()
                if !isEngineSwitched {
                    Button("Use \(SearchEngine.engine(engine).name)") {
                        settings.searchEngine = engine
                        isEngineSwitched = true
                    }
                }
            }
        }

        if !summary.extensions.isEmpty {
            DisclosureGroup("Extensions in \(summary.browserName)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.extensions, id: \.id) { item in
                        LabeledContent(item.name, value: "Not supported yet")
                    }
                }
                .padding(.top, 4)
            }
        }

        if !summary.warnings.isEmpty {
            DisclosureGroup("Notes") {
                Text(summary.warnings.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }

        HStack {
            Spacer()
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct FullDiskAccessButton: View {
    var body: some View {
        Button("Open Full Disk Access Settings") {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
                preconditionFailure("Invalid System Settings URL")
            }
            NSWorkspace.shared.open(url)
        }
    }
}

/// The browser's app icon when it's installed, else a globe.
private struct BrowserIcon: View {
    let browser: BrowserKind

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        } else {
            Image(systemName: "globe")
        }
    }
}

extension BrowserKind {
    var bundleIdentifier: String {
        switch self {
        case .brave: "com.brave.Browser"
        case .braveBeta: "com.brave.Browser.beta"
        case .braveNightly: "com.brave.Browser.nightly"
        case .chrome: "com.google.Chrome"
        case .chromeBeta: "com.google.Chrome.beta"
        case .chromeCanary: "com.google.Chrome.canary"
        case .chromium: "org.chromium.Chromium"
        case .edge: "com.microsoft.edgemac"
        case .arc: "company.thebrowser.Browser"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .firefox: "org.mozilla.firefox"
        case .safari: "com.apple.Safari"
        }
    }
}

extension ImportKind {
    /// Brave's names for each item in its import dialog.
    var title: String {
        switch self {
        case .bookmarks: "Favorites/Bookmarks"
        case .history: "Browsing history"
        case .cookies: "Cookies"
        case .passwords: "Saved passwords"
        case .searchEngines: "Search engines"
        case .extensions: "Extensions"
        }
    }
}
