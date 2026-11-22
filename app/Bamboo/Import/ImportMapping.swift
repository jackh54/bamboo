import Foundation

/// Converts what the importer read from another browser into what Bamboo's stores take.
enum ImportMapping {
    static func bookmarksFolderTitle(for source: SourceProfile) -> String {
        "Imported from \(source.browserName)"
    }

    static func bookmarks(_ items: [ImportedBookmark]) -> [BookmarkImport] {
        items.map {
            BookmarkImport(localId: $0.localId, parentLocalId: $0.parentLocalId, title: $0.title, url: $0.url, createdMs: $0.createdMs)
        }
    }

    static func history(_ items: [ImportedHistory]) -> [HistoryImport] {
        items.map {
            HistoryImport(url: $0.url, title: $0.title, lastVisitMs: $0.lastVisitMs, visitCount: $0.visitCount)
        }
    }

    /// The cookie for WebKit's cookie store, or nil when it has already expired or
    /// Foundation rejects it (an empty name or domain, for example).
    static func cookie(_ cookie: ImportedCookie, now: Date) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
        ]
        // Foundation gives a cookie without a path the path "/".
        if !cookie.path.isEmpty {
            properties[.path] = cookie.path
        }
        if let expiresMs = cookie.expiresMs {
            let expires = Date(timeIntervalSince1970: Double(expiresMs) / 1000)
            guard expires > now else { return nil }
            properties[.expires] = expires
        }
        if cookie.secure {
            properties[.secure] = "TRUE"
        }
        if cookie.httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        // Without a policy WebKit sends the cookie on cross-site requests, which is what
        // Chromium's "no restriction" means; "unspecified" cookies keep WebKit's default too.
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .noRestriction, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }

    /// The login with its password, or nil for logins that don't belong to a website.
    static func login(_ login: ImportedLogin) -> (login: SavedLogin, password: String)? {
        guard !login.password.isEmpty, let origin = URL(string: login.origin),
              let saved = SavedLogin(origin: origin, username: login.username)
        else { return nil }
        return (saved, login.password)
    }

    /// The built-in engine matching the source browser's default search engine, if any.
    static func builtInEngine(matching engines: [ImportedSearchEngine]) -> SearchEngineID? {
        guard let source = engines.first(where: \.isDefault),
              let host = URL(string: source.urlTemplate.replacingOccurrences(of: "{searchTerms}", with: "bamboo"))?.host()
        else { return nil }
        return SearchEngine.all.first { Self.sameSite($0.searchURL(for: "bamboo").host(), host) }?.id
    }

    private static func sameSite(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        let strip = { (host: String) in host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
        return strip(a.lowercased()) == strip(b.lowercased())
    }
}
