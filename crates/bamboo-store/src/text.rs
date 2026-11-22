//! Normalisation of URLs and search text for matching.

/// `url` as the address bar shows it: no scheme and no leading `www.`.
pub fn strip_url(url: &str) -> &str {
    let rest = match url.split_once("://") {
        Some((scheme, rest))
            if !scheme.is_empty()
                && scheme
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.')) =>
        {
            rest
        }
        _ => url,
    };
    rest.strip_prefix("www.").unwrap_or(rest)
}

/// The authority part (host and port) of a stripped URL.
pub fn host_of(stripped: &str) -> &str {
    stripped
        .find(['/', '?', '#'])
        .map_or(stripped, |end| &stripped[..end])
}

/// Lowercased stripped URL, the text address-bar input is matched against.
pub fn match_text(url: &str) -> String {
    strip_url(&url.to_lowercase()).to_owned()
}

pub fn host(url: &str) -> String {
    host_of(&match_text(url)).to_owned()
}

/// FTS5 prefix terms for each word of `text`; words with nothing to index are dropped.
pub fn prefix_terms(text: &str) -> Vec<String> {
    text.split_whitespace()
        .filter(|word| word.chars().any(char::is_alphanumeric))
        .map(|word| format!("\"{}\"*", word.replace('"', "\"\"")))
        .collect()
}
