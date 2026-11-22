import SwiftUI

/// Offer to save the credentials in `tab.passwordSaveOffer`, shown above the page. The login
/// is saved for the origin the page submitted from, whatever the tab shows by then.
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
                    Text(replacesSavedPassword
                         ? "Update the saved password for \(Self.site(offer.login))?"
                         : "Save password for \(Self.site(offer.login))?")
                        .font(.headline)
                    Text(errorMessage ?? (offer.login.username.isEmpty ? "No username" : offer.login.username))
                        .font(.subheadline)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button("Never for This Site") {
                    AppServices.shared.settings.neverSavePasswordHosts.append(offer.login.host)
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

    /// The host alone for an ordinary HTTPS site; the full origin when it is plain HTTP or
    /// uses another port, so the user sees exactly where the password will be used.
    private static func site(_ login: SavedLogin) -> String {
        login.isSecure && login.port == nil ? login.host : login.origin
    }

    private func check(_ offer: PasswordSaveOffer) {
        errorMessage = nil
        do {
            replacesSavedPassword = try AppServices.shared.passwords
                .logins(forHost: offer.login.host, isSecure: offer.login.isSecure)
                .contains { $0.username == offer.login.username && $0.port == offer.login.port }
        } catch {
            errorMessage = "Couldn't read saved passwords: \(error.localizedDescription)"
        }
    }

    private func save(_ offer: PasswordSaveOffer) {
        do {
            try AppServices.shared.passwords.save(offer.login, password: offer.password)
            tab.passwordSaveOffer = nil
        } catch {
            errorMessage = "Couldn't save the password: \(error.localizedDescription)"
        }
    }
}
