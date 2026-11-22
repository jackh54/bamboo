# Releasing Bamboo

Releases are automatic. Merging the release pull request is the only manual step.

## How a release flows

1. Commits land on `main` with [Conventional Commits](https://www.conventionalcommits.org) messages.
2. `.github/workflows/release-please.yml` keeps a "chore(main): release x.y.z" pull request open. It holds the next version (from the commit types) and the changelog, and it bumps the version in `Cargo.toml`, `Cargo.lock` and `app/project.yml`.
3. Merging that PR makes release-please create the tag `vX.Y.Z` and the GitHub release (with the changelog as its notes).
4. The same workflow then calls `.github/workflows/release.yml` with the tag. (A release created with `GITHUB_TOKEN` doesn't trigger other workflows, so the call is explicit.) The release workflow:
   - fetches the filter lists listed in `crates/bamboo-shields/catalog.json` into `app/Bamboo/Resources/FilterLists`, which the app bundles;
   - builds the Rust core for arm64 and x86_64 with the `dist` profile and joins them with `lipo`;
   - archives a universal Release app, with the commit count as `CURRENT_PROJECT_VERSION` (Sparkle compares it, so it only ever grows) and the tag as `MARKETING_VERSION`;
   - signs the app inside-out with the Developer ID certificate, notarizes it and staples the ticket (`scripts/release/sign-app.sh`, `notarize.sh`);
   - packages `Bamboo-X.Y.Z.dmg` and `Bamboo-X.Y.Z.zip` (`package.sh`), then signs, notarizes and staples the DMG;
   - generates `appcast.xml`, signed with the Sparkle EdDSA key (`appcast.sh`);
   - uploads the DMG, the zip, `appcast.xml` and `SHA256SUMS` to the release.
5. Installed copies of Bamboo check `https://github.com/jackh54/bamboo/releases/latest/download/appcast.xml` every six hours, verify the EdDSA signature of the zip and install it.

Between steps 3 and 4 finishing, the latest release has no `appcast.xml` yet, so update checks in that window find nothing. That is harmless.

### Cutting a release

Review the open release PR (the version and the changelog), then merge it. Watch the "Release Please" run: its `release` job is the build. Check the release page afterwards for the four assets.

To make the first release `0.1.0` instead of the `0.2.0` release-please computes from a `0.1.0` baseline, put `Release-As: 0.1.0` in the footer of a commit on `main`.

release-please opens its PR with `GITHUB_TOKEN`, so CI doesn't run on that PR automatically. If branch protection requires CI on it, either push an empty commit to the release branch by hand, or give `release-please.yml` a fine-grained personal access token (`token:` input of the action) instead.

If a new crate is added to the workspace nothing needs changing: `release-please-config.json` updates every `Cargo.lock` entry that has no registry source, which is exactly the workspace crates.

### Retrying and rehearsing

Run the workflow by hand: **Actions > Release > Run workflow**, or

```bash
gh workflow run release.yml -f tag=v0.2.0 -f dry_run=true
```

A dry run builds, signs and packages everything exactly like a release and attaches the DMG, zip, appcast and checksums to the workflow run, but publishes nothing. With `dry_run=false` it publishes (use that to retry a release whose build failed; `gh release upload --clobber` replaces assets). The tag has to exist. Before the first release, rehearse with a throwaway tag (`git tag v0.0.1 && git push origin v0.0.1`, delete it afterwards).

## Secrets

Set these under **Settings > Secrets and actions > Actions** or with `gh secret set` (repository: `jackh54/bamboo`).

| Secret | Needed | What it is |
|---|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | always | Signs the update archive. The release fails without it, because an unsigned appcast makes every install reject updates. |
| `APPLE_DEVELOPER_ID_P12` | for notarized builds | Base64 of the Developer ID Application certificate with its private key. |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | for notarized builds | Password you chose when exporting the .p12. |
| `APPLE_TEAM_ID` | for notarized builds | 10-character Team ID, used to pick the right identity from the .p12. |
| `APPLE_API_KEY_ID` | for notarized builds | Key ID of the App Store Connect API key. |
| `APPLE_API_ISSUER_ID` | for notarized builds | Issuer ID shown on the same page. |
| `APPLE_API_KEY_P8` | for notarized builds | Base64 of the `.p8` private key file. |

All six `APPLE_*` secrets are set together or not at all. With none set, the release still ships, ad-hoc signed and not notarized (see below). With only some set, the release fails and lists the missing ones.

### Sparkle EdDSA key

The key pair was generated with Sparkle's `generate_keys`. The public half is `SUPublicEDKey` in `app/project.yml`; the private half is in the maintainer's login Keychain and exported to a file outside the repository (`~/.bamboo-secrets/sparkle_ed_private_key` in the commands below). To create one from scratch:

```bash
scripts/release/fetch-sparkle.sh /tmp/sparkle
/tmp/sparkle/bin/generate_keys      # stores the key in the login Keychain, prints the public key
mkdir -p -m 700 ~/.bamboo-secrets
/tmp/sparkle/bin/generate_keys -x ~/.bamboo-secrets/sparkle_ed_private_key
chmod 600 ~/.bamboo-secrets/sparkle_ed_private_key
gh secret set SPARKLE_ED_PRIVATE_KEY < ~/.bamboo-secrets/sparkle_ed_private_key
```

Put the printed public key into `SUPublicEDKey` in `app/project.yml`. Keep a backup of the private key somewhere safe (a password manager): if it is lost, apps already installed can't verify updates signed with a new key unless they are Developer ID signed (see Key rotation).

### Developer ID certificate (`APPLE_DEVELOPER_ID_P12`, `APPLE_DEVELOPER_ID_P12_PASSWORD`, `APPLE_TEAM_ID`)

Needs a paid Apple Developer Program membership; only the Account Holder can create Developer ID certificates.

1. Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority. Enter your email, choose "Saved to disk".
2. developer.apple.com > Certificates, Identifiers & Profiles > Certificates > add > **Developer ID Application**. Upload the request and download the `.cer`.
3. Double-click the `.cer` to install it into the login keychain.
4. In Keychain Access > My Certificates, expand "Developer ID Application: ..." so the private key shows under it, select the certificate row, File > Export Items, format `.p12`, and choose a password.
5. Store them:

   ```bash
   base64 -i DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_P12
   gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD      # paste the password when prompted
   gh secret set APPLE_TEAM_ID                         # Membership details on developer.apple.com
   ```

6. Delete the `.p12` from disk.

### Notarization API key (`APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8`)

1. appstoreconnect.apple.com > Users and Access > Integrations > App Store Connect API > Team Keys.
2. Generate a key with the **Developer** role. Download the `AuthKey_XXXXXXXXXX.p8` (Apple lets you download it once).
3. The Key ID is in the key's row and the Issuer ID is at the top of the page.

   ```bash
   gh secret set APPLE_API_KEY_ID
   gh secret set APPLE_API_ISSUER_ID
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set APPLE_API_KEY_P8
   ```

## Builds without Apple credentials

If the `APPLE_*` secrets are missing, `release.yml` signs ad-hoc, skips notarization, prints a `::warning::` annotation and appends a "Not notarized" section to the release notes. Consequences:

- **First launch.** Gatekeeper blocks the app. The user opens it once, then allows it under System Settings > Privacy & Security > Open Anyway. On macOS 15 and later, Control-click > Open no longer bypasses the block.
- **Updates still install.** Sparkle accepts an update when its EdDSA signature is valid against the `SUPublicEDKey` of the installed app. Apple code signing is not required for that. The update is checked as follows (`SUUpdateValidator.m` and `SUCodeSigningVerifier.m` in Sparkle 2.10.1):
  - The update must still be code signed if the installed app is: removing code signing is rejected, but an ad-hoc signature counts as signed. The new bundle's signature must also be intact.
  - The archive's EdDSA signature is verified against the installed app's public key. If it passes, the update is accepted ("Either DSA must be valid, or Apple Code Signing must be valid"), whether or not the code signing identities match.
  - Sparkle's XPC connections only get a team-ID requirement when the host app has a team ID, so ad-hoc apps work with the unmodified XPC services.
  - Updating from an ad-hoc build to a Developer ID build is allowed for the same reason.
- **No hardened runtime.** `sign-app.sh` leaves it off for ad-hoc signatures. With it on, library validation refuses the ad-hoc Sparkle.framework (there is no shared Team ID) and the app exits in dyld at launch; the Xcode archive itself has this problem. Developer ID builds keep it.
- **Permissions reset.** An ad-hoc signature identifies the app by its code hash, which changes with every build. macOS therefore treats each update as a new app for camera, microphone and location permissions and for Keychain item access, and asks again.

This was established by reading Sparkle's source; no update was installed end to end on an ad-hoc build.

## Testing an update locally

Build two versions with different build numbers and serve the appcast from localhost. From a built core (`scripts/build-core.sh --universal`, or without `--universal` and `BAMBOO_ARCHS=arm64` for this Mac only):

```bash
xcodegen generate --spec app/project.yml --project app
scripts/release/build-app.sh 0.1.0 1 /tmp/bamboo/old && scripts/release/sign-app.sh /tmp/bamboo/old/Bamboo.app -
scripts/release/build-app.sh 0.1.1 2 /tmp/bamboo/new && scripts/release/sign-app.sh /tmp/bamboo/new/Bamboo.app -
scripts/release/package.sh /tmp/bamboo/new/Bamboo.app 0.1.1 /tmp/bamboo/packages
mkdir /tmp/bamboo/serve && cp /tmp/bamboo/packages/Bamboo-0.1.1.zip /tmp/bamboo/serve/

scripts/release/fetch-sparkle.sh /tmp/bamboo/sparkle
/tmp/bamboo/sparkle/bin/generate_appcast --ed-key-file - --maximum-deltas 0 \
  --download-url-prefix http://localhost:8000/ /tmp/bamboo/serve < ~/.bamboo-secrets/sparkle_ed_private_key

# Point the old build at the local feed, re-sign it, run it, and serve the update.
plutil -replace SUFeedURL -string http://localhost:8000/appcast.xml /tmp/bamboo/old/Bamboo.app/Contents/Info.plist
scripts/release/sign-app.sh /tmp/bamboo/old/Bamboo.app -
(cd /tmp/bamboo/serve && python3 -m http.server 8000) &
open /tmp/bamboo/old/Bamboo.app      # Bamboo > Check for Updates
```

`BAMBOO_ARCHS=arm64` goes in front of `build-app.sh` on a Mac without the x86_64 Rust target. Release builds start the updater and debug builds never do, so test with the Release build above. Bamboo then offers 0.1.1 and relaunches into it.

## Key rotation

- **Sparkle EdDSA key.** Sparkle accepts an update when the EdDSA signature or the Apple code signature validates. To rotate, generate a new key, publish one release that carries the *new* `SUPublicEDKey` but is signed with the *old* private key, then switch `SPARKLE_ED_PRIVATE_KEY` to the new key for later releases. Installs that are Developer ID signed with the same team can also move to a new key after a loss, because the code signature carries the update. An ad-hoc install whose key is lost cannot be updated and has to be reinstalled.
- **Developer ID certificate.** Certificates expire after five years. Create a new one, export a new `.p12`, and update the two `APPLE_DEVELOPER_ID_P12*` secrets. Sparkle keeps working across the change because the EdDSA key is unchanged.
- **App Store Connect API key.** Create a new key, update the three `APPLE_API_*` secrets, then revoke the old one.
- **If a secret leaks,** rotate it as above first, then delete the old one from where it leaked.

## Sparkle upgrades

`scripts/release/fetch-sparkle.sh` pins the Sparkle tools by version and SHA-256 (the digest GitHub publishes for the release asset). When bumping Sparkle in `app/project.yml`, update both values there as well. The signing steps in `sign-app.sh` follow [Sparkle's code-signing guidance](https://sparkle-project.org/documentation/sandboxing/); re-read it on a major upgrade.
