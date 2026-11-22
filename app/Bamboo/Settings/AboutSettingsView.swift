import AppKit
import Sparkle
import SwiftUI

struct AboutSettingsView: View {
    private var updater: SPUUpdater { AppServices.shared.updater.updater }
    // SPUUpdater isn't observable, so the toggles mirror it and write changes back.
    @State private var checksAutomatically = false
    @State private var downloadsAutomatically = false
    @State private var canCheck = false

    private var version: String {
        guard let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else { preconditionFailure("Info.plist has no version") }
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bamboo")
                            .font(.title2.weight(.semibold))
                        Text(version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Check for Updates") { AppServices.shared.updater.checkForUpdates() }
                        .disabled(!canCheck)
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $checksAutomatically)
                Toggle("Download and install updates automatically", isOn: $downloadsAutomatically)
                    .disabled(!checksAutomatically)
            } header: {
                Text("Updates")
            } footer: {
                #if DEBUG
                Text("Development builds never update themselves.")
                    .foregroundStyle(.secondary)
                #else
                Text("Bamboo checks GitHub for signed updates every 6 hours.")
                    .foregroundStyle(.secondary)
                #endif
            }

            Section {
                Link("Bamboo on GitHub", destination: AppLinks.repository)
                Link("Report an issue", destination: AppLinks.newIssue)
            } footer: {
                Text("Bamboo is open source under the MIT License.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            checksAutomatically = updater.automaticallyChecksForUpdates
            downloadsAutomatically = updater.automaticallyDownloadsUpdates
            canCheck = updater.canCheckForUpdates
        }
        .onChange(of: checksAutomatically) { updater.automaticallyChecksForUpdates = checksAutomatically }
        .onChange(of: downloadsAutomatically) { updater.automaticallyDownloadsUpdates = downloadsAutomatically }
    }
}
