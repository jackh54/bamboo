# Contributing to Bamboo

Bug reports, ideas and pull requests are welcome. For anything larger than a small fix, open an issue first so we can agree on the approach.

## Setup

You need a Mac with Xcode (the version the CI uses is pinned in `.github/workflows/ci.yml`), a Rust toolchain from [rustup](https://rustup.rs), and XcodeGen:

```bash
brew install xcodegen
make run        # builds the Rust core and the app, then launches a debug build
```

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit together.

## Make targets

| Target | What it does |
|---|---|
| `make core` | Builds the Rust core and the UniFFI Swift bindings |
| `make project` | Generates `app/Bamboo.xcodeproj` from `app/project.yml` |
| `make app` | Core + project + a Debug build |
| `make run` | `make app`, then launches the build |
| `make test` | `cargo test` and the XCTest suite |
| `make lint` | `rustfmt --check` and `clippy -D warnings` |
| `make clean` | Removes build output and generated files |

The Xcode project is generated and not committed: change `app/project.yml`, not the project.

## Pull requests

CI runs `make lint`, the tests and `cargo deny` (licenses, advisories, banned crates). Run `make lint test` before you push.

Keep a pull request to one change, and match the style of the code around it.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org). The release notes and the next version number are generated from them.

```
feat(shields): add per-site cosmetic filtering toggle
fix(import): skip Chrome profiles without a Preferences file
docs: explain tab hibernation
```

Use `feat` for new behaviour (minor bump), `fix` for bug fixes (patch bump) and `perf`, `refactor` or `docs` where they fit. Add `!` after the type, or a `BREAKING CHANGE:` footer, for incompatible changes. `ci`, `build`, `test` and `chore` don't appear in release notes. Squash-merged pull requests use the PR title as the commit message, so give the PR title the same format.

## How releases happen

Nobody tags a release by hand. [release-please](https://github.com/googleapis/release-please-action) keeps a "chore: release" pull request open on `main` with the next version and changelog. Merging it creates the tag and GitHub release, and the release workflow then builds, signs and publishes the app. Installed copies of Bamboo pick the update up from the appcast. [docs/RELEASING.md](docs/RELEASING.md) has the details.
