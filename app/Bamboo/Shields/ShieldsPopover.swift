import SwiftUI

/// The Shields panel for the current site, shown from the address bar's shields badge.
/// Laid out like Brave's: the site, a big Shields UP/DOWN switch, what was blocked, and
/// advanced per-site controls.
struct ShieldsPopover: View {
    let tab: Tab
    @State private var site: SiteSettings?
    @State private var showsAdvanced = false
    @State private var errorMessage: String?

    private var settings: AppSettings { AppServices.shared.settings }

    private var host: String? {
        guard let url = tab.url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url.host()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let host, let site {
                header(host: host, isUp: site.shieldsUp)
                if site.shieldsUp {
                    blockedCount
                    Divider()
                    advancedControls(site)
                } else {
                    Text("Bamboo isn’t blocking anything on \(host). Turn shields up if the site still works without them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }
            } else if host == nil {
                Text("Shields work on websites. Open one to change its shields.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
            // Saving would leave a record of the site in the profile.
            if tab.isPrivate, host != nil {
                Text("Shields can’t be changed for a site in a private window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], 16)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .bottom], 16)
            }
            Divider()
            Button("Global Shields settings") {
                SettingsWindowController.shared.show(section: .shields)
            }
            .buttonStyle(.link)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
        .task(id: host) { load() }
    }

    private func header(host: String, isUp: Bool) -> some View {
        let palette = Theme.palette(isUp ? .bamboo : .graphite)
        return VStack(spacing: 10) {
            Image(systemName: isUp ? "checkmark.shield.fill" : "shield.slash.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 2) {
                Text(isUp ? "Shields are UP" : "Shields are DOWN")
                    .font(.title2.weight(.bold))
                Text("for \(host)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            Toggle("Shields", isOn: Binding(get: { isUp }, set: setShields))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .tint(.white.opacity(0.35))
                .disabled(tab.isPrivate)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(LinearGradient(colors: palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        .animation(Theme.Motion.standard, value: isUp)
    }

    private var blockedCount: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tab.blockedRequestCount, format: .number)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(tab.blockedRequestCount)))
            Text("Trackers & ads blocked")
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func advancedControls(_ site: SiteSettings) -> some View {
        DisclosureGroup("Advanced controls", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: binding(\.shieldsEnabled, in: site)) {
                    Text("Trackers & ads blocking")
                    if !settings.blockTrackersAndAds {
                        Text("Off for every site in Shields settings.")
                    }
                }
                .disabled(!settings.blockTrackersAndAds)

                Toggle(isOn: Binding {
                    SiteShields(site, defaults: settings).blocksScripts
                } set: { blocks in
                    update { $0.javascriptEnabled = !blocks }
                }) {
                    Text("Block scripts")
                    Text(settings.blockScripts ? "On for every site in Shields settings." : "Sites that need JavaScript may break.")
                }
                .disabled(settings.blockScripts)

                Toggle(isOn: binding(\.lockdownMode, in: site)) {
                    Text("Lockdown Mode")
                    Text("Turns off complex web features attackers exploit.")
                }

                if !tab.blockedHosts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blocked on this page")
                            .font(.subheadline.weight(.semibold))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(tab.blockedHosts.sorted(), id: \.self) { blockedHost in
                                    Text(blockedHost)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(tab.isPrivate)
            .padding(.top, 10)
        }
        .padding(16)
    }

    /// Shields down turns every protection off for the site; up turns blocking back on.
    private func setShields(_ up: Bool) {
        update { site in
            site.shieldsEnabled = up
            if !up {
                site.javascriptEnabled = true
                site.lockdownMode = false
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SiteSettings, Bool>, in site: SiteSettings) -> Binding<Bool> {
        Binding {
            site[keyPath: keyPath]
        } set: { value in
            update { $0[keyPath: keyPath] = value }
        }
    }

    /// Saves the change at once and reloads the page so it takes effect.
    private func update(_ change: (inout SiteSettings) -> Void) {
        guard var updated = site else { return }
        change(&updated)
        do {
            try tab.profile.store.saveSiteSettings(settings: updated)
            site = updated
            errorMessage = nil
            tab.reload()
        } catch {
            errorMessage = "Couldn’t save the shields for this site: \(userFacingMessage(error))"
        }
    }

    private func load() {
        guard let host else {
            site = nil
            return
        }
        do {
            site = try tab.profile.store.siteSettings(host: host)
            errorMessage = nil
        } catch {
            site = nil
            errorMessage = "Couldn’t read the shields for this site: \(userFacingMessage(error))"
        }
    }
}
