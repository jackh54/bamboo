# Bamboo

A fast, private web browser for macOS that uses little memory, blocks ads and trackers out of the box, and can be driven by AI agents, including Claude.

Bamboo uses WebKit (the engine behind Safari) for pages, a native AppKit and SwiftUI interface laid out like Brave, and a Rust core for ad blocking, browsing data, importing and the agent server.

## Install

Download `Bamboo.dmg` from the [latest release](https://github.com/jackh54/bamboo/releases/latest), open it and drag Bamboo to Applications. Requires macOS 15 or later on Apple silicon or Intel.

Bamboo updates itself: it checks GitHub Releases every six hours and installs signed updates in the background.

## Features

**Browsing.** Horizontal tabs and toolbar like Brave, or vertical tabs. Pinned tabs, spaces and profiles with separate cookies, private windows, a bookmarks bar, an address bar with history, bookmark, open-tab and search suggestions, a command palette (⌘K), find in page, Reader, downloads, session restore, and Chrome and Brave keyboard shortcuts.

**Low memory.** Tabs you haven't looked at for 30 minutes (configurable as Memory Saver) unload and come back exactly where they were, history included. Restored sessions only load the tab you're looking at. Ad blocking runs inside WebKit's own rule engine rather than in the app, and filter lists are compiled in a short-lived helper process so the browser doesn't keep that memory.

**Shields.** Ads, trackers, cookie notices and malware domains are blocked by default using EasyList, EasyPrivacy, the uBlock Origin lists, Peter Lowe's list and the EasyList Cookie List, updated daily. Cosmetic filtering and scriptlets come from Brave's adblock-rust engine. Per site you can turn shields down, block scripts or turn on Lockdown Mode. Custom filter lists and rules are supported.

**Privacy.** Tracking parameters (`utm_*`, `fbclid`, `gclid` and others) are removed from links, Global Privacy Control is sent, connections are upgraded to HTTPS (or HTTPS-only if you prefer), audible autoplay is blocked, and there is a Clear Browsing Data sheet and an option to clear data on quit. Nothing is sent to Bamboo; there are no accounts or telemetry.

**Import.** Bookmarks, history, cookies (so you stay signed in), saved passwords and search engines from Brave, Chrome, Edge, Arc, Vivaldi, Opera and Chromium. Bookmarks, history and cookies from Firefox, and bookmarks and history from Safari. macOS asks you to allow access to the other browser's data and Keychain entry.

**Passwords.** Saved in your macOS Keychain, filled from a menu on login forms, and protected by Touch ID or your Mac password before you can see, copy, edit or export them.

**Claude.** A side panel (⌘J) for asking Claude about the page you're on, or letting it work through the page for you with the same tools agents use. It uses your own Anthropic API key, stored in the Keychain.

**Built for agents.** Bamboo runs an [MCP](https://modelcontextprotocol.io) server, so Claude Code, Claude Desktop and other MCP clients can open tabs, read pages, take snapshots and screenshots, click, type and fill forms. Agents can only control tabs they opened or that you hand over (Tab ▸ Let Agents Control This Tab), and those tabs are outlined in the tab strip. Running JavaScript and reading history are off unless you turn them on.

## Connect Claude

In Bamboo, open Settings ▸ Claude and use **Add to Claude Code** or **Add to Claude Desktop**. To do it by hand:

```bash
claude mcp add --scope user bamboo -- /Applications/Bamboo.app/Contents/MacOS/bamboo-mcp
```

For Claude Desktop or another MCP client, add a stdio server whose command is `/Applications/Bamboo.app/Contents/MacOS/bamboo-mcp`. The bridge starts Bamboo if it isn't running. The server only listens on a socket in your Library folder that other users and web pages can't reach.

## Build from source

You need Xcode 27 or later, Rust (via [rustup](https://rustup.rs)) and XcodeGen.

```bash
brew install xcodegen
git clone https://github.com/jackh54/bamboo.git
cd bamboo
make run
```

`make test` runs the Rust and app tests and `make lint` runs rustfmt and clippy. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit together, and [CONTRIBUTING.md](CONTRIBUTING.md) covers the workflow.

## Not supported yet

- Chrome extensions. The importer lists the extensions you had, but Bamboo can't run them.
- Importing passwords from Firefox.
- Syncing between devices.

## Releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org). release-please opens a release pull request; merging it builds, signs, notarizes and publishes the release and its update feed. See [docs/RELEASING.md](docs/RELEASING.md).

## License

MIT. See [LICENSE](LICENSE). Filter lists and adblock resources are fetched from their publishers under their own licenses.
