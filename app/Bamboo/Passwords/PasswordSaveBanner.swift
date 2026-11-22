import SwiftUI

/// Offer to save the credentials in `tab.passwordSaveOffer`, shown above the page.
struct PasswordSaveBanner: View {
    let tab: Tab
    @State private var replacesSavedPassword = false
    @State private var errorMessage: String?

    var body: some View {
        if let offer = tab.passwordSaveOffer {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.palette(.bamboo).accent, in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(replacesSavedPassword ? "Update the saved password for \(offer.host)?" : "Save password for \(offer.host)?")
                        .font(.headline)
                    Text(errorMessage ?? (offer.username.isEmpty ? "No username" : offer.username))
                        .font(.subheadline)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button("Never for This Site") {
                    AppServices.shared.settings.neverSavePasswordHosts.append(offer.host)
                    tab.passwordSaveOffer = nil
                }
                Button("Not Now") {
                    tab.passwordSaveOffer = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(replacesSavedPassword ? "Update" : "Save") {
                    save(offer)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.palette(.bamboo).accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .task(id: offer) { check(offer) }
        }
    }

    /// The offer only names the host, so the scheme and port come from the page when it is still on that host.
    private func login(for offer: PasswordSaveOffer) -> SavedLogin? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = offer.host
        if let page = tab.url, page.host() == offer.host {
            components.scheme = page.scheme
            components.port = page.port
        }
        return components.url.flatMap { SavedLogin(origin: $0, username: offer.username) }
    }

    private func check(_ offer: PasswordSaveOffer) {
        errorMessage = nil
        guard let login = login(for: offer) else { return }
        do {
            replacesSavedPassword = try AppServices.shared.passwords
                .logins(forHost: login.host, isSecure: login.isSecure)
                .contains { $0.username == login.username && $0.port == login.port }
        } catch {
            errorMessage = "Couldn't read saved passwords: \(error.localizedDescription)"
        }
    }

    private func save(_ offer: PasswordSaveOffer) {
        guard let login = login(for: offer) else {
            errorMessage = "Passwords can only be saved for websites."
            return
        }
        do {
            try AppServices.shared.passwords.save(login, password: offer.password)
            tab.passwordSaveOffer = nil
        } catch {
            errorMessage = "Couldn't save the password: \(error.localizedDescription)"
        }
    }
}
