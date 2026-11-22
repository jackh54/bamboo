//! Import from other browsers on this Mac.
//!
//! Chromium-family browsers (Brave, Chrome, Edge, Arc, Vivaldi, Opera,
//! Chromium): bookmarks, history, cookies, saved passwords, search engines and
//! the list of installed extensions. Cookies and passwords are decrypted with
//! the browser's "Safe Storage" key from the macOS Keychain, which makes macOS
//! ask the user for permission. Firefox: bookmarks, history and cookies.
//! Safari: bookmarks and history (needs Full Disk Access).
//!
//! Databases are copied to a temporary directory before reading because the
//! source browser may hold locks on them while running.

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ImportError {
    #[error("not found: {path}")]
    NotFound { path: String },
    /// macOS privacy protection (TCC) refused access; the app should explain
    /// how to grant it.
    #[error("permission denied for {path}: {message}")]
    PermissionDenied { path: String, message: String },
    #[error("keychain error: {message}")]
    Keychain { message: String },
    #[error("database error: {message}")]
    Database { message: String },
    #[error("parse error: {message}")]
    Parse { message: String },
    #[error("decryption error: {message}")]
    Decryption { message: String },
    #[error("io error: {message}")]
    Io { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BrowserKind {
    Brave,
    BraveBeta,
    BraveNightly,
    Chrome,
    ChromeBeta,
    ChromeCanary,
    Chromium,
    Edge,
    Arc,
    Vivaldi,
    Opera,
    Firefox,
    Safari,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ImportKind {
    Bookmarks,
    History,
    Cookies,
    Passwords,
    SearchEngines,
    Extensions,
}

/// A browser profile found on disk.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SourceProfile {
    pub browser: BrowserKind,
    /// "Brave", "Google Chrome", ...
    pub browser_name: String,
    /// The profile's display name ("Personal", "Default", ...).
    pub profile_name: String,
    pub profile_dir: String,
    /// Data kinds present in this profile.
    pub kinds: Vec<ImportKind>,
    /// Set when the profile directory exists but macOS refused access.
    pub access_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportRequest {
    pub kinds: Vec<ImportKind>,
    /// Only import history visited at or after this time (`None` imports all).
    pub history_since_ms: Option<i64>,
}

/// Bookmark tree flattened in parent-before-child order. Top-level source
/// folders ("Bookmarks Bar", "Other Bookmarks") are kept as folders.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedBookmark {
    pub local_id: u32,
    pub parent_local_id: Option<u32>,
    pub title: String,
    pub url: Option<String>,
    pub created_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedHistory {
    pub url: String,
    pub title: Option<String>,
    pub last_visit_ms: i64,
    pub visit_count: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CookieSameSite {
    Unspecified,
    NoRestriction,
    Lax,
    Strict,
}

/// A decrypted cookie. `domain` keeps the source's leading dot for domain
/// cookies (".example.com"); `expires_ms` is `None` for session cookies.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub expires_ms: Option<i64>,
    pub secure: bool,
    pub http_only: bool,
    pub same_site: CookieSameSite,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedLogin {
    /// Origin the login belongs to, e.g. "https://accounts.example.com".
    pub origin: String,
    pub username: String,
    pub password: String,
    pub created_ms: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedSearchEngine {
    pub name: String,
    pub keyword: String,
    /// Search URL with `{searchTerms}` where the query goes.
    pub url_template: String,
    pub is_default: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportedExtension {
    pub id: String,
    pub name: String,
    pub version: String,
    /// Unpacked extension directory (contains manifest.json).
    pub directory: String,
    pub manifest_version: u32,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImportBundle {
    pub source: SourceProfile,
    pub bookmarks: Vec<ImportedBookmark>,
    pub history: Vec<ImportedHistory>,
    pub cookies: Vec<ImportedCookie>,
    pub logins: Vec<ImportedLogin>,
    pub search_engines: Vec<ImportedSearchEngine>,
    pub extensions: Vec<ImportedExtension>,
    /// Non-fatal problems, e.g. "12 cookies could not be decrypted".
    pub warnings: Vec<String>,
}

/// Every profile of every supported browser under `home_dir`.
#[uniffi::export]
pub fn discover_profiles(home_dir: String) -> Vec<SourceProfile> {
    let _ = home_dir; // STUB(phase1)
    vec![]
}

/// Reads the requested data kinds from `profile`. A kind that fails entirely
/// (for example the user denies Keychain access) returns an error; partial
/// failures are reported in `warnings`.
#[uniffi::export]
pub fn import_profile(
    profile: SourceProfile,
    request: ImportRequest,
) -> Result<ImportBundle, ImportError> {
    let _ = request; // STUB(phase1)
    Err(ImportError::NotFound {
        path: profile.profile_dir,
    })
}
