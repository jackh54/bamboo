import Foundation

enum SearchEngineID: String, CaseIterable, Codable, Sendable, Identifiable {
    case duckDuckGo, brave, google, bing, kagi, startpage, ecosia, perplexity
    var id: String { rawValue }
}

/// A web search provider. Suggestion endpoints all return the OpenSearch
/// suggestions format: `["query", ["suggestion", ...], ...]`.
struct SearchEngine: Sendable, Identifiable {
    let id: SearchEngineID
    let name: String
    private let searchTemplate: String
    private let suggestionsTemplate: String?

    static let all: [SearchEngine] = [
        SearchEngine(id: .duckDuckGo, name: "DuckDuckGo",
                     searchTemplate: "https://duckduckgo.com/?q={q}",
                     suggestionsTemplate: "https://duckduckgo.com/ac/?q={q}&type=list"),
        SearchEngine(id: .brave, name: "Brave Search",
                     searchTemplate: "https://search.brave.com/search?q={q}",
                     suggestionsTemplate: "https://search.brave.com/api/suggest?q={q}"),
        SearchEngine(id: .google, name: "Google",
                     searchTemplate: "https://www.google.com/search?q={q}",
                     suggestionsTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q={q}"),
        SearchEngine(id: .bing, name: "Bing",
                     searchTemplate: "https://www.bing.com/search?q={q}",
                     suggestionsTemplate: "https://api.bing.com/osjson.aspx?query={q}"),
        SearchEngine(id: .kagi, name: "Kagi",
                     searchTemplate: "https://kagi.com/search?q={q}",
                     suggestionsTemplate: nil),
        SearchEngine(id: .startpage, name: "Startpage",
                     searchTemplate: "https://www.startpage.com/sp/search?query={q}",
                     suggestionsTemplate: nil),
        SearchEngine(id: .ecosia, name: "Ecosia",
                     searchTemplate: "https://www.ecosia.org/search?q={q}",
                     suggestionsTemplate: "https://ac.ecosia.org/autocomplete?q={q}&type=list"),
        SearchEngine(id: .perplexity, name: "Perplexity",
                     searchTemplate: "https://www.perplexity.ai/search?q={q}",
                     suggestionsTemplate: nil),
    ]

    static func engine(_ id: SearchEngineID) -> SearchEngine {
        guard let engine = all.first(where: { $0.id == id }) else {
            preconditionFailure("No search engine registered for \(id)")
        }
        return engine
    }

    func searchURL(for query: String) -> URL {
        Self.fill(searchTemplate, query)
    }

    var supportsSuggestions: Bool { suggestionsTemplate != nil }

    func suggestionsURL(for query: String) -> URL? {
        suggestionsTemplate.map { Self.fill($0, query) }
    }

    /// Parses an OpenSearch suggestions response.
    static func parseSuggestions(_ data: Data) throws -> [String] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2, let suggestions = array[1] as? [String] else {
            throw SuggestionsError.unexpectedFormat
        }
        return suggestions
    }

    enum SuggestionsError: Error {
        case unexpectedFormat
    }

    private static func fill(_ template: String, _ query: String) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        guard let url = URL(string: template.replacingOccurrences(of: "{q}", with: encoded)) else {
            preconditionFailure("Search template produced an invalid URL: \(template)")
        }
        return url
    }
}
