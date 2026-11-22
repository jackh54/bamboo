import SwiftUI

/// The new tab page, laid out like Brave's: a full-bleed background in the
/// space's colours, Shields stats at the top left, the clock at the top
/// right, a search box and top sites in the middle, and Customize.
struct NewTabPage: View {
    let model: BrowserWindowModel
    @State private var topSites: [HistoryEntry] = []
    @State private var stats: PrivacyStats?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let settings = AppServices.shared.settings
        let space = model.selectedSpace
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        if settings.newTabShowsStats, !model.isPrivate, let stats {
                            StatsWidget(stats: stats)
                                .transition(.opacity)
                        }
                        Spacer(minLength: 24)
                        if settings.newTabShowsClock {
                            ClockWidget()
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 40)
                    VStack(spacing: 30) {
                        SearchBox(model: model)
                        if model.isPrivate {
                            PrivateWindowNote()
                        } else if settings.newTabShowsTopSites, !topSites.isEmpty {
                            TopSites(model: model, sites: topSites)
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 40)
                    HStack {
                        Spacer()
                        CustomizeButton(appColorScheme: colorScheme)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background {
            NewTabBackground(tint: model.isPrivate ? .lavender : space.tint, isPrivate: model.isPrivate,
                             showsImage: settings.newTabShowsBackground)
        }
        // Text sits on a deep background, so it is drawn light whatever the appearance.
        .environment(\.colorScheme, settings.newTabShowsBackground ? .dark : colorScheme)
        .animation(Theme.Motion.standard, value: settings.newTabShowsStats)
        .animation(Theme.Motion.standard, value: settings.newTabShowsClock)
        .animation(Theme.Motion.standard, value: settings.newTabShowsTopSites)
        .task(id: space.id) { load(space) }
    }

    private func load(_ space: Space) {
        guard !model.isPrivate else { return }
        let store = space.profile.store
        do {
            topSites = try store.topSites(limit: 8)
            // Like Brave, the counters run from the first day, not a recent window.
            stats = try store.privacyStats(sinceMs: 0, top: 0)
        } catch {
            AppServices.shared.reportNonFatal(error, "Loading the new tab page")
        }
    }
}

/// A soft mesh of the space's colours, deepened so white text reads on it.
private struct NewTabBackground: View {
    let tint: SpaceTint
    let isPrivate: Bool
    let showsImage: Bool

    var body: some View {
        ZStack {
            if showsImage {
                let palette = Theme.palette(tint)
                let light = palette.gradient[0]
                let deep = palette.gradient[1]
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0, 0], [0.55, 0], [1, 0],
                        [0, 0.45], [0.62, 0.52], [1, 0.4],
                        [0, 1], [0.45, 1], [1, 1],
                    ],
                    colors: [
                        deep.mix(with: .black, by: 0.35), light.mix(with: .black, by: 0.5), deep.mix(with: .black, by: 0.6),
                        light.mix(with: .black, by: 0.42), deep.mix(with: .black, by: 0.45), light.mix(with: .black, by: 0.62),
                        deep.mix(with: .black, by: 0.72), deep.mix(with: .black, by: 0.62), deep.mix(with: .black, by: 0.8),
                    ])
                BambooGrove()
                // A vignette keeps the corners, where the widgets sit, calm.
                RadialGradient(colors: [.clear, .black.opacity(isPrivate ? 0.45 : 0.3)],
                               center: .center, startRadius: 200, endRadius: 900)
            } else {
                Theme.Colors.card
            }
        }
        .animation(Theme.Motion.standard, value: tint)
    }
}

/// A faint grove of stalks along both edges: the browser's name, drawn.
private struct BambooGrove: View {
    private struct Stalk {
        let x: CGFloat
        let width: CGFloat
        let tilt: Double
        let nodeSpacing: CGFloat
    }

    /// Fixed, so the grove is the same on every new tab.
    private static let stalks = [
        Stalk(x: 0.035, width: 18, tilt: -0.02, nodeSpacing: 150),
        Stalk(x: 0.1, width: 27, tilt: 0.012, nodeSpacing: 205),
        Stalk(x: 0.165, width: 14, tilt: -0.006, nodeSpacing: 135),
        Stalk(x: 0.83, width: 22, tilt: 0.016, nodeSpacing: 175),
        Stalk(x: 0.9, width: 32, tilt: -0.01, nodeSpacing: 225),
        Stalk(x: 0.965, width: 16, tilt: 0.022, nodeSpacing: 150),
    ]

    var body: some View {
        Canvas { context, size in
            let height = size.height * 1.15
            for stalk in Self.stalks {
                var stalkContext = context
                stalkContext.translateBy(x: stalk.x * size.width, y: size.height)
                stalkContext.rotate(by: .radians(stalk.tilt))
                let culm = CGRect(x: -stalk.width / 2, y: -height, width: stalk.width, height: height)
                stalkContext.fill(Path(roundedRect: culm, cornerRadius: stalk.width / 2), with: .color(.white.opacity(0.04)))
                var nodeY = -stalk.nodeSpacing * 0.7
                while nodeY > -height {
                    let node = CGRect(x: -stalk.width / 2 - 2, y: nodeY, width: stalk.width + 4, height: 3)
                    stalkContext.fill(Path(roundedRect: node, cornerRadius: 1.5), with: .color(.white.opacity(0.06)))
                    nodeY -= stalk.nodeSpacing
                }
            }
        }
        .blur(radius: 0.6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct StatsWidget: View {
    let stats: PrivacyStats
    @Environment(\.spaceAccent) private var accent

    /// Rough averages for a blocked tracker or ad request; the page says these are estimates.
    private static let bytesSavedPerBlock: Int64 = 40_000
    private static let secondsSavedPerBlock = 0.05

    var body: some View {
        let blocked = stats.blockedTotal
        HStack(alignment: .top, spacing: 30) {
            Stat(value: blocked.formatted(), label: "Trackers & ads\nblocked", tint: accent.mix(with: .white, by: 0.35))
            Stat(value: (Int64(blocked) * Self.bytesSavedPerBlock).formatted(.byteCount(style: .file, spellsOutZero: false)),
                 label: "Bandwidth\nsaved", tint: .primary)
            Stat(value: Self.timeSaved(Double(blocked) * Self.secondsSavedPerBlock), label: "Time\nsaved", tint: .primary)
        }
        .help("Bandwidth and time saved are estimates based on how many requests Shields blocked.")
    }

    private struct Stat: View {
        let value: String
        let label: String
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private static func timeSaved(_ seconds: Double) -> String {
        let duration = Duration.seconds(seconds)
        if seconds < 60 { return duration.formatted(.units(allowed: [.seconds], width: .abbreviated)) }
        return duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

private struct ClockWidget: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.date, format: .dateTime.hour().minute())
                    .font(.system(size: 44, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Looks like a search field; typing happens in the address bar, so there is one place to search from.
private struct SearchBox: View {
    let model: BrowserWindowModel
    @State private var isHovered = false

    var body: some View {
        let engine = SearchEngine.engine(AppServices.shared.settings.searchEngine)
        Button {
            model.addressBarFocusRequest += 1
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                Text(model.isPrivate ? "Search privately with \(engine.name)" : "Search the web with \(engine.name)")
                    .font(.system(size: 15))
                Spacer(minLength: 8)
                Text("⌘L")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .frame(maxWidth: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(isHovered ? 0.28 : 0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: isHovered ? 16 : 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isHovered)
    }
}

private struct TopSites: View {
    let model: BrowserWindowModel
    let sites: [HistoryEntry]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sites, id: \.url) { site in
                TopSiteTile(model: model, site: site)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TopSiteTile: View {
    let model: BrowserWindowModel
    let site: HistoryEntry
    @State private var isHovered = false

    var body: some View {
        let url = URL(string: site.url)
        let host = url?.host()
        Button {
            guard let url else { return }
            if let tab = model.selectedTab { tab.load(url) } else { model.newTab(url: url) }
        } label: {
            VStack(spacing: 7) {
                FaviconView(host: host, size: 26)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .scaleEffect(isHovered ? 1.05 : 1)
                Text(Self.label(site, host: host))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 76)
            .padding(.vertical, 8)
            .background(isHovered ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.spring, value: isHovered)
        .help(site.title ?? site.url)
    }

    private static func label(_ site: HistoryEntry, host: String?) -> String {
        guard let host else { return site.title ?? site.url }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return name.split(separator: ".").first.map(String.init)?.capitalized ?? name
    }
}

private struct PrivateWindowNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("This is a private window")
                    .font(.system(size: 14, weight: .semibold))
                Text("Bamboo won't remember the pages you visit here. Cookies and site data are deleted when you close the window, and search suggestions are off.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Brave's "Customize": what the page shows, and when the bookmarks bar appears.
private struct CustomizeButton: View {
    /// The window's own appearance; the page around the button is always drawn dark.
    let appColorScheme: ColorScheme
    @State private var isPresented = false

    var body: some View {
        @Bindable var settings = AppServices.shared.settings
        Button {
            isPresented = true
        } label: {
            Label("Customize", systemImage: "slider.horizontal.3")
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Form {
                Toggle("Background", isOn: $settings.newTabShowsBackground)
                Toggle("Clock", isOn: $settings.newTabShowsClock)
                Toggle("Shields stats", isOn: $settings.newTabShowsStats)
                Toggle("Top sites", isOn: $settings.newTabShowsTopSites)
                Picker("Show bookmarks", selection: $settings.bookmarksBar) {
                    Text("Always").tag(BookmarksBarVisibility.always)
                    Text("Never").tag(BookmarksBarVisibility.never)
                    Text("Only on the new tab page").tag(BookmarksBarVisibility.newTabOnly)
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, appColorScheme)
        }
    }
}
