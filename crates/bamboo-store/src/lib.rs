//! Bamboo's per-profile database: history, bookmarks, per-site settings and
//! privacy statistics, stored in one SQLite file.
//!
//! All timestamps are milliseconds since the Unix epoch. Callers pass "now"
//! explicitly so behaviour is deterministic in tests.

use std::sync::Arc;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum StoreError {
    #[error("database error: {message}")]
    Database { message: String },
    #[error("not found: {id}")]
    NotFound { id: String },
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
}

/// How a page was reached; affects suggestion ranking (typed visits rank higher).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VisitKind {
    Link,
    Typed,
    Bookmark,
    Reload,
    Redirect,
    FormSubmit,
    Other,
}

/// One URL in history, aggregated over all its visits.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryEntry {
    pub url: String,
    pub title: Option<String>,
    pub last_visit_ms: i64,
    pub visit_count: u32,
}

/// One visit, for the chronological history view.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryVisit {
    pub url: String,
    pub title: Option<String>,
    pub visited_at_ms: i64,
}

/// A bookmark (`url` is `Some`) or a folder (`url` is `None`).
/// `parent_id` is `None` for items at the root level.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Bookmark {
    pub id: String,
    pub parent_id: Option<String>,
    pub title: String,
    pub url: Option<String>,
    pub position: u32,
    pub created_ms: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SuggestionSource {
    History,
    Bookmark,
}

/// An address-bar suggestion. `autocomplete` is set when the typed input is a
/// prefix of the URL with its scheme and `www.` removed; it holds the full text
/// to show inline (for example input `git` gives `github.com/`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Suggestion {
    pub source: SuggestionSource,
    pub url: String,
    pub title: Option<String>,
    pub score: f64,
    pub autocomplete: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PermissionState {
    Ask,
    Allow,
    Deny,
}

/// Per-site settings keyed by host (`www.` is not stripped; `example.com` and
/// `www.example.com` are different sites). Unknown hosts get the defaults:
/// shields on, JavaScript on, every permission `Ask`, zoom 1.0, lockdown off.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SiteSettings {
    pub host: String,
    pub shields_enabled: bool,
    pub javascript_enabled: bool,
    pub popups: PermissionState,
    pub camera: PermissionState,
    pub microphone: PermissionState,
    pub location: PermissionState,
    pub zoom: f64,
    pub lockdown_mode: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TrackerCount {
    pub host: String,
    pub count: u64,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PrivacyStats {
    pub blocked_total: u64,
    pub since_ms: i64,
    pub top_trackers: Vec<TrackerCount>,
}

/// History item handed over by the importer.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HistoryImport {
    pub url: String,
    pub title: Option<String>,
    pub last_visit_ms: i64,
    pub visit_count: u32,
}

/// Bookmark tree flattened for import. Parents always come before their
/// children; `parent_local_id` refers to another item's `local_id` in the same
/// batch, or is `None` for top-level items.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BookmarkImport {
    pub local_id: u32,
    pub parent_local_id: Option<u32>,
    pub title: String,
    pub url: Option<String>,
    pub created_ms: Option<i64>,
}

#[derive(uniffi::Object)]
pub struct Store {
    // STUB(phase1): replaced by the real connection.
    _path: String,
}

#[uniffi::export]
impl Store {
    /// Opens (creating and migrating if needed) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, StoreError> {
        // STUB(phase1)
        Ok(Arc::new(Self { _path: path }))
    }

    // ---- History ----

    /// Records a visit and updates the URL's title when one is given.
    pub fn record_visit(
        &self,
        url: String,
        title: Option<String>,
        kind: VisitKind,
        at_ms: i64,
    ) -> Result<(), StoreError> {
        let _ = (url, title, kind, at_ms); // STUB(phase1)
        Ok(())
    }

    pub fn set_title(&self, url: String, title: String) -> Result<(), StoreError> {
        let _ = (url, title); // STUB(phase1)
        Ok(())
    }

    /// Visits newest first. `query` matches title or URL; `before_ms` pages backwards.
    pub fn visits(
        &self,
        query: Option<String>,
        before_ms: Option<i64>,
        limit: u32,
    ) -> Result<Vec<HistoryVisit>, StoreError> {
        let _ = (query, before_ms, limit); // STUB(phase1)
        Ok(vec![])
    }

    /// URLs matching `query`, best match first.
    pub fn search_history(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<HistoryEntry>, StoreError> {
        let _ = (query, limit); // STUB(phase1)
        Ok(vec![])
    }

    /// Most visited sites by frecency, one entry per host, for the new tab page.
    pub fn top_sites(&self, limit: u32) -> Result<Vec<HistoryEntry>, StoreError> {
        let _ = limit; // STUB(phase1)
        Ok(vec![])
    }

    /// Removes a URL and all its visits.
    pub fn delete_url(&self, url: String) -> Result<(), StoreError> {
        let _ = url; // STUB(phase1)
        Ok(())
    }

    /// Deletes visits at or after `since_ms` (all history when `None`) and any
    /// URL left with no visits. Returns the number of visits deleted.
    pub fn clear_history(&self, since_ms: Option<i64>) -> Result<u64, StoreError> {
        let _ = since_ms; // STUB(phase1)
        Ok(0)
    }

    /// Merges imported history: keeps the later `last_visit_ms`, adds visit counts.
    /// Returns the number of items written.
    pub fn import_history(&self, items: Vec<HistoryImport>) -> Result<u64, StoreError> {
        let _ = items; // STUB(phase1)
        Ok(0)
    }

    // ---- Bookmarks ----

    /// Children of a folder in position order (`None` lists the root level).
    pub fn bookmark_children(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<Bookmark>, StoreError> {
        let _ = parent_id; // STUB(phase1)
        Ok(vec![])
    }

    pub fn bookmarks_for_url(&self, url: String) -> Result<Vec<Bookmark>, StoreError> {
        let _ = url; // STUB(phase1)
        Ok(vec![])
    }

    /// Appends a bookmark (or a folder when `url` is `None`) to the end of `parent_id`.
    pub fn add_bookmark(
        &self,
        parent_id: Option<String>,
        title: String,
        url: Option<String>,
    ) -> Result<Bookmark, StoreError> {
        let _ = (parent_id, title, url); // STUB(phase1)
        Err(StoreError::Database {
            message: "store not implemented".into(),
        })
    }

    pub fn update_bookmark(
        &self,
        id: String,
        title: String,
        url: Option<String>,
    ) -> Result<(), StoreError> {
        let _ = (id, title, url); // STUB(phase1)
        Ok(())
    }

    /// Moves an item to `position` inside `parent_id`, renumbering siblings.
    /// Moving a folder into itself or a descendant is `InvalidInput`.
    pub fn move_bookmark(
        &self,
        id: String,
        parent_id: Option<String>,
        position: u32,
    ) -> Result<(), StoreError> {
        let _ = (id, parent_id, position); // STUB(phase1)
        Ok(())
    }

    /// Deletes a bookmark, or a folder with everything inside it.
    pub fn delete_bookmark(&self, id: String) -> Result<(), StoreError> {
        let _ = id; // STUB(phase1)
        Ok(())
    }

    pub fn search_bookmarks(&self, query: String, limit: u32) -> Result<Vec<Bookmark>, StoreError> {
        let _ = (query, limit); // STUB(phase1)
        Ok(vec![])
    }

    /// Creates a root-level folder named `folder_title` and inserts the tree
    /// under it. Returns the number of bookmarks (not folders) inserted.
    pub fn import_bookmarks(
        &self,
        folder_title: String,
        items: Vec<BookmarkImport>,
    ) -> Result<u64, StoreError> {
        let _ = (folder_title, items); // STUB(phase1)
        Ok(0)
    }

    // ---- Address bar ----

    /// History and bookmark suggestions for address-bar input, best first.
    pub fn suggest(&self, input: String, limit: u32) -> Result<Vec<Suggestion>, StoreError> {
        let _ = (input, limit); // STUB(phase1)
        Ok(vec![])
    }

    // ---- Site settings ----

    pub fn site_settings(&self, host: String) -> Result<SiteSettings, StoreError> {
        // STUB(phase1)
        Ok(SiteSettings {
            host,
            shields_enabled: true,
            javascript_enabled: true,
            popups: PermissionState::Ask,
            camera: PermissionState::Ask,
            microphone: PermissionState::Ask,
            location: PermissionState::Ask,
            zoom: 1.0,
            lockdown_mode: false,
        })
    }

    /// Saves settings; saving the defaults removes the host's row.
    pub fn save_site_settings(&self, settings: SiteSettings) -> Result<(), StoreError> {
        let _ = settings; // STUB(phase1)
        Ok(())
    }

    /// Every host whose settings differ from the defaults, sorted by host.
    pub fn customized_sites(&self) -> Result<Vec<SiteSettings>, StoreError> {
        Ok(vec![]) // STUB(phase1)
    }

    pub fn reset_site_settings(&self, host: String) -> Result<(), StoreError> {
        let _ = host; // STUB(phase1)
        Ok(())
    }

    // ---- Privacy stats ----

    /// Adds `count` blocked requests to `tracker_host`'s total for the day of `at_ms`.
    pub fn record_blocked(
        &self,
        tracker_host: String,
        count: u32,
        at_ms: i64,
    ) -> Result<(), StoreError> {
        let _ = (tracker_host, count, at_ms); // STUB(phase1)
        Ok(())
    }

    pub fn privacy_stats(&self, since_ms: i64, top: u32) -> Result<PrivacyStats, StoreError> {
        let _ = top; // STUB(phase1)
        Ok(PrivacyStats {
            blocked_total: 0,
            since_ms,
            top_trackers: vec![],
        })
    }

    pub fn clear_privacy_stats(&self) -> Result<(), StoreError> {
        Ok(()) // STUB(phase1)
    }
}
