import Foundation

/// What the user typed into the address bar: a URL to open or text to search for.
enum AddressInput: Equatable {
    case url(URL)
    case search(String)

    private static let explicitSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "view-source"]

    /// Returns nil for empty input.
    static func parse(_ raw: String) -> AddressInput? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let scheme = text.split(separator: ":", maxSplits: 1).first.map({ $0.lowercased() }),
           explicitSchemes.contains(scheme), text.contains(":"),
           let url = URL(string: text) {
            return .url(url)
        }

        guard !text.contains(" "), let url = URL(string: "http://\(text)"), let host = url.host() else {
            return .search(text)
        }

        if host == "localhost" || isIPAddress(host) {
            return .url(url)
        }
        // A dotted host with a plausible top-level domain is treated as an address.
        let labels = host.split(separator: ".")
        if labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
           labels.allSatisfy({ !$0.isEmpty }),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secure = components.url { return .url(secure) }
        }
        return .search(text)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return host.hasPrefix("[") && host.hasSuffix("]")
    }
}
