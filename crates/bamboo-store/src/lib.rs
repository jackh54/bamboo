//! Bamboo's per-profile database: history, bookmarks, per-site settings and
//! privacy statistics, stored in one SQLite file.
//!
//! All timestamps are milliseconds since the Unix epoch. Callers pass "now"
//! explicitly so behaviour is deterministic in tests.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Row, ToSql, params};

mod frecency;
mod schema;
#[cfg(test)]
mod tests;
mod text;

uniffi::setup_scaffolding!();

const MS_PER_DAY: i64 = 86_400_000;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum StoreError {
    #[error("database error: {message}")]
    Database { message: String },
    #[error("not found: {id}")]
    NotFound { id: String },
    #[error("invalid input: {message}")]
    InvalidInput { message: String },
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database {
            message: error.to_string(),
        }
    }
}

fn invalid_input(message: &str) -> StoreError {
    StoreError::InvalidInput {
        message: message.into(),
    }
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
    conn: Mutex<Connection>,
}

impl Store {
    fn conn(&self) -> Result<MutexGuard<'_, Connection>, StoreError> {
        self.conn.lock().map_err(|_| StoreError::Database {
            message: "database connection lock poisoned".into(),
        })
    }
}

/// Match quality multipliers for `suggest`: prefix matches outrank title word matches.
const HOST_PREFIX_QUALITY: f64 = 8.0;
const URL_PREFIX_QUALITY: f64 = 4.0;
const TITLE_QUALITY: f64 = 1.0;

/// Title matches `suggest` looks at, newest first: ranking every match of a short word
/// would blow the latency budget, and sites the user types are found by URL prefix anyway.
const TITLE_MATCHES_SCANNED: i64 = 300;

const BOOKMARK_SELECT: &str =
    "SELECT id, parent_id, title, url, position, created_ms FROM bookmarks";

const SITE_SETTINGS_SELECT: &str =
    "SELECT host, shields_enabled, javascript_enabled, popups, camera,
    microphone, location, zoom, lockdown_mode FROM site_settings";

fn now_ms() -> Result<i64, StoreError> {
    let elapsed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| StoreError::Database {
            message: error.to_string(),
        })?;
    i64::try_from(elapsed.as_millis()).map_err(|error| StoreError::Database {
        message: error.to_string(),
    })
}

fn history_entry(row: &Row) -> rusqlite::Result<HistoryEntry> {
    Ok(HistoryEntry {
        url: row.get(0)?,
        title: row.get(1)?,
        last_visit_ms: row.get(2)?,
        visit_count: row.get(3)?,
    })
}

fn bookmark_from_row(row: &Row) -> rusqlite::Result<Bookmark> {
    Ok(Bookmark {
        id: row.get::<_, i64>(0)?.to_string(),
        parent_id: row.get::<_, Option<i64>>(1)?.map(|id| id.to_string()),
        title: row.get(2)?,
        url: row.get(3)?,
        position: row.get(4)?,
        created_ms: row.get(5)?,
    })
}

fn parse_id(id: &str) -> Result<i64, StoreError> {
    id.parse()
        .map_err(|_| StoreError::NotFound { id: id.into() })
}

fn parse_parent(parent_id: Option<&str>) -> Result<Option<i64>, StoreError> {
    parent_id.map(parse_id).transpose()
}

/// Fails with `NotFound` unless `id` exists and `InvalidInput` unless it is a folder.
fn check_folder(conn: &Connection, id: i64) -> Result<(), StoreError> {
    match conn
        .query_row(
            "SELECT url IS NULL FROM bookmarks WHERE id = ?1",
            [id],
            |row| row.get::<_, bool>(0),
        )
        .optional()?
    {
        None => Err(StoreError::NotFound { id: id.to_string() }),
        Some(false) => Err(invalid_input("parent is a bookmark, not a folder")),
        Some(true) => Ok(()),
    }
}

fn sibling_ids(
    conn: &Connection,
    parent: Option<i64>,
    excluding: Option<i64>,
) -> rusqlite::Result<Vec<i64>> {
    conn.prepare_cached(
        "SELECT id FROM bookmarks WHERE parent_id IS ?1 AND id IS NOT ?2 ORDER BY position, id",
    )?
    .query_map(params![parent, excluding], |row| row.get(0))?
    .collect()
}

/// Puts `ids` under `parent` at positions 0, 1, 2, ... in the given order.
fn set_order(conn: &Connection, parent: Option<i64>, ids: &[i64]) -> rusqlite::Result<()> {
    let mut update =
        conn.prepare_cached("UPDATE bookmarks SET parent_id = ?2, position = ?3 WHERE id = ?1")?;
    for (position, id) in (0u32..).zip(ids) {
        update.execute(params![id, parent, position])?;
    }
    Ok(())
}

fn insert_bookmark(
    conn: &Connection,
    parent: Option<i64>,
    title: &str,
    url: Option<&str>,
    position: u32,
    created_ms: i64,
) -> rusqlite::Result<i64> {
    conn.prepare_cached(
        "INSERT INTO bookmarks (parent_id, title, url, match_text, position, created_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )?
    .execute(params![
        parent,
        title,
        url,
        url.map(text::match_text),
        position,
        created_ms
    ])?;
    Ok(conn.last_insert_rowid())
}

fn permission_code(state: PermissionState) -> i64 {
    match state {
        PermissionState::Ask => 0,
        PermissionState::Allow => 1,
        PermissionState::Deny => 2,
    }
}

fn permission_at(row: &Row, index: usize) -> rusqlite::Result<PermissionState> {
    match row.get::<_, i64>(index)? {
        0 => Ok(PermissionState::Ask),
        1 => Ok(PermissionState::Allow),
        2 => Ok(PermissionState::Deny),
        code => Err(rusqlite::Error::IntegralValueOutOfRange(index, code)),
    }
}

fn site_settings_from_row(row: &Row) -> rusqlite::Result<SiteSettings> {
    Ok(SiteSettings {
        host: row.get(0)?,
        shields_enabled: row.get(1)?,
        javascript_enabled: row.get(2)?,
        popups: permission_at(row, 3)?,
        camera: permission_at(row, 4)?,
        microphone: permission_at(row, 5)?,
        location: permission_at(row, 6)?,
        zoom: row.get(7)?,
        lockdown_mode: row.get(8)?,
    })
}

fn default_site_settings(host: String) -> SiteSettings {
    SiteSettings {
        host,
        shields_enabled: true,
        javascript_enabled: true,
        popups: PermissionState::Ask,
        camera: PermissionState::Ask,
        microphone: PermissionState::Ask,
        location: PermissionState::Ask,
        zoom: 1.0,
        lockdown_mode: false,
    }
}

/// A history or bookmark row that might answer address-bar input.
struct Candidate {
    url: String,
    title: Option<String>,
    match_text: String,
    frecency: f64,
    bookmarked: bool,
}

/// Runs one candidate query (columns: url, title, match_text, frecency, bookmarked)
/// and merges its rows into `found`, deduplicating by URL.
fn collect(
    conn: &Connection,
    sql: &str,
    params: &[&dyn ToSql],
    found: &mut HashMap<String, Candidate>,
) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare_cached(sql)?;
    let rows = stmt.query_map(params, |row| {
        Ok(Candidate {
            url: row.get(0)?,
            title: row.get(1)?,
            match_text: row.get(2)?,
            frecency: row.get(3)?,
            bookmarked: row.get(4)?,
        })
    })?;
    for row in rows {
        let candidate = row?;
        let bookmarked = candidate.bookmarked;
        found
            .entry(candidate.url.clone())
            .and_modify(|known| known.bookmarked |= bookmarked)
            .or_insert(candidate);
    }
    Ok(())
}

#[uniffi::export]
impl Store {
    /// Opens (creating and migrating if needed) the database at `path`.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, StoreError> {
        let mut conn = Connection::open(path)?;
        schema::init(&mut conn)?;
        Ok(Arc::new(Self {
            conn: Mutex::new(conn),
        }))
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
        if url.is_empty() {
            return Err(invalid_input("url is empty"));
        }
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let url_id: i64 = tx
            .prepare_cached(
                "INSERT INTO urls (url, title, host, match_text, visit_count, last_visit_ms)
                 VALUES (?1, ?2, ?3, ?4, 1, ?5)
                 ON CONFLICT (url) DO UPDATE SET
                     title = COALESCE(excluded.title, urls.title),
                     visit_count = urls.visit_count + 1
                 RETURNING id",
            )?
            .query_row(
                params![url, title, text::host(&url), text::match_text(&url), at_ms],
                |row| row.get(0),
            )?;
        tx.prepare_cached(
            "INSERT INTO visits (url_id, visited_at_ms, weight) VALUES (?1, ?2, ?3)",
        )?
        .execute(params![url_id, at_ms, frecency::weight(kind)])?;
        frecency::refresh(&tx, url_id, at_ms)?;
        frecency::age_stale(&tx, at_ms)?;
        tx.commit()?;
        Ok(())
    }

    pub fn set_title(&self, url: String, title: String) -> Result<(), StoreError> {
        let updated = self.conn()?.execute(
            "UPDATE urls SET title = ?2 WHERE url = ?1",
            params![url, title],
        )?;
        if updated == 0 {
            return Err(StoreError::NotFound { id: url });
        }
        Ok(())
    }

    /// Visits newest first. `query` matches title or URL; `before_ms` pages backwards.
    pub fn visits(
        &self,
        query: Option<String>,
        before_ms: Option<i64>,
        limit: u32,
    ) -> Result<Vec<HistoryVisit>, StoreError> {
        let terms = text::prefix_terms(query.as_deref().unwrap_or_default());
        let fts_query = (!terms.is_empty()).then(|| terms.join(" "));
        let conn = self.conn()?;
        let visits = conn
            .prepare_cached(
                "SELECT u.url, u.title, v.visited_at_ms
                 FROM visits v JOIN urls u ON u.id = v.url_id
                 WHERE (?1 IS NULL OR v.visited_at_ms < ?1)
                   AND (?2 IS NULL OR u.id IN (SELECT rowid FROM urls_fts WHERE urls_fts MATCH ?2))
                 ORDER BY v.visited_at_ms DESC, v.id DESC
                 LIMIT ?3",
            )?
            .query_map(params![before_ms, fts_query, limit], |row| {
                Ok(HistoryVisit {
                    url: row.get(0)?,
                    title: row.get(1)?,
                    visited_at_ms: row.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(visits)
    }

    /// URLs matching `query`, best match first.
    pub fn search_history(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<HistoryEntry>, StoreError> {
        let terms = text::prefix_terms(&query);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        let conn = self.conn()?;
        let entries = conn
            .prepare_cached(
                "SELECT u.url, u.title, u.last_visit_ms, u.visit_count
                 FROM urls_fts f JOIN urls u ON u.id = f.rowid
                 WHERE urls_fts MATCH ?1
                 ORDER BY u.frecency DESC, u.id
                 LIMIT ?2",
            )?
            .query_map(params![terms.join(" "), limit], history_entry)?
            .collect::<Result<_, _>>()?;
        Ok(entries)
    }

    /// Most visited sites by frecency, one entry per host, for the new tab page.
    pub fn top_sites(&self, limit: u32) -> Result<Vec<HistoryEntry>, StoreError> {
        let conn = self.conn()?;
        let sites = conn
            .prepare_cached(
                "SELECT url, title, last_visit_ms, visit_count FROM (
                     SELECT url, title, last_visit_ms, visit_count, score,
                            ROW_NUMBER() OVER (PARTITION BY host ORDER BY score DESC, id) AS rank
                     FROM (
                         SELECT u.*, u.frecency + CASE
                             WHEN EXISTS (SELECT 1 FROM bookmarks b WHERE b.url = u.url)
                             THEN ?1 ELSE 0 END AS score
                         FROM urls u
                     )
                 )
                 WHERE rank = 1
                 ORDER BY score DESC, url
                 LIMIT ?2",
            )?
            .query_map(params![frecency::BOOKMARK_BONUS, limit], history_entry)?
            .collect::<Result<_, _>>()?;
        Ok(sites)
    }

    /// Removes a URL and all its visits.
    pub fn delete_url(&self, url: String) -> Result<(), StoreError> {
        self.conn()?
            .execute("DELETE FROM urls WHERE url = ?1", [url])?;
        Ok(())
    }

    /// Deletes visits at or after `since_ms` (all history when `None`) and any
    /// URL left with no visits. Returns the number of visits deleted.
    pub fn clear_history(&self, since_ms: Option<i64>) -> Result<u64, StoreError> {
        let since = since_ms.unwrap_or(i64::MIN);
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        // URLs that keep some visits need their count, last visit and frecency fixed up.
        let survivors = tx
            .prepare(
                "SELECT DISTINCT a.url_id FROM visits a
                 WHERE a.visited_at_ms >= ?1
                   AND EXISTS (SELECT 1 FROM visits b
                               WHERE b.url_id = a.url_id AND b.visited_at_ms < ?1)",
            )?
            .query_map([since], |row| row.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        tx.execute(
            "UPDATE urls SET visit_count = MAX(1, visit_count - (
                 SELECT COUNT(*) FROM visits v
                 WHERE v.url_id = urls.id AND v.visited_at_ms >= ?1))
             WHERE EXISTS (SELECT 1 FROM visits v
                           WHERE v.url_id = urls.id AND v.visited_at_ms < ?1)",
            [since],
        )?;
        let deleted = tx.execute("DELETE FROM visits WHERE visited_at_ms >= ?1", [since])?;
        tx.execute(
            "DELETE FROM urls WHERE NOT EXISTS (SELECT 1 FROM visits WHERE url_id = urls.id)",
            [],
        )?;
        let newest_visit_ms: Option<i64> =
            tx.query_row("SELECT MAX(visited_at_ms) FROM visits", [], |row| {
                row.get(0)
            })?;
        if let Some(now_ms) = newest_visit_ms {
            for url_id in survivors {
                frecency::refresh(&tx, url_id, now_ms)?;
            }
        }
        tx.commit()?;
        Ok(deleted as u64)
    }

    /// Merges imported history: keeps the later `last_visit_ms`, adds visit counts.
    /// Returns the number of items written.
    pub fn import_history(&self, items: Vec<HistoryImport>) -> Result<u64, StoreError> {
        // Imported visits age relative to the newest item in the batch.
        let Some(now_ms) = items.iter().map(|item| item.last_visit_ms).max() else {
            return Ok(0);
        };
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        for item in &items {
            if item.url.is_empty() || item.visit_count == 0 {
                return Err(invalid_input(
                    "imported history needs a url and a visit count",
                ));
            }
            let url_id: i64 = tx
                .prepare_cached(
                    "INSERT INTO urls (url, title, host, match_text, visit_count, last_visit_ms)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                     ON CONFLICT (url) DO UPDATE SET
                         title = CASE WHEN excluded.last_visit_ms > urls.last_visit_ms
                                      THEN COALESCE(excluded.title, urls.title)
                                      ELSE COALESCE(urls.title, excluded.title) END,
                         visit_count = urls.visit_count + excluded.visit_count
                     RETURNING id",
                )?
                .query_row(
                    params![
                        item.url,
                        item.title,
                        text::host(&item.url),
                        text::match_text(&item.url),
                        item.visit_count,
                        item.last_visit_ms
                    ],
                    |row| row.get(0),
                )?;
            tx.prepare_cached(
                "INSERT INTO visits (url_id, visited_at_ms, weight) VALUES (?1, ?2, ?3)",
            )?
            .execute(params![
                url_id,
                item.last_visit_ms,
                frecency::weight(VisitKind::Other)
            ])?;
            frecency::refresh(&tx, url_id, now_ms)?;
        }
        tx.commit()?;
        Ok(items.len() as u64)
    }

    // ---- Bookmarks ----

    /// Children of a folder in position order (`None` lists the root level).
    pub fn bookmark_children(
        &self,
        parent_id: Option<String>,
    ) -> Result<Vec<Bookmark>, StoreError> {
        let parent = parse_parent(parent_id.as_deref())?;
        let conn = self.conn()?;
        if let Some(parent) = parent {
            check_folder(&conn, parent)?;
        }
        let children = conn
            .prepare_cached(&format!(
                "{BOOKMARK_SELECT} WHERE parent_id IS ?1 ORDER BY position"
            ))?
            .query_map([parent], bookmark_from_row)?
            .collect::<Result<_, _>>()?;
        Ok(children)
    }

    pub fn bookmarks_for_url(&self, url: String) -> Result<Vec<Bookmark>, StoreError> {
        let conn = self.conn()?;
        let bookmarks = conn
            .prepare_cached(&format!("{BOOKMARK_SELECT} WHERE url = ?1 ORDER BY id"))?
            .query_map([url], bookmark_from_row)?
            .collect::<Result<_, _>>()?;
        Ok(bookmarks)
    }

    /// Appends a bookmark (or a folder when `url` is `None`) to the end of `parent_id`.
    pub fn add_bookmark(
        &self,
        parent_id: Option<String>,
        title: String,
        url: Option<String>,
    ) -> Result<Bookmark, StoreError> {
        let parent = parse_parent(parent_id.as_deref())?;
        let created_ms = now_ms()?;
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        if let Some(parent) = parent {
            check_folder(&tx, parent)?;
        }
        let position: u32 = tx.query_row(
            "SELECT COUNT(*) FROM bookmarks WHERE parent_id IS ?1",
            [parent],
            |row| row.get(0),
        )?;
        let id = insert_bookmark(&tx, parent, &title, url.as_deref(), position, created_ms)?;
        tx.commit()?;
        Ok(Bookmark {
            id: id.to_string(),
            parent_id,
            title,
            url,
            position,
            created_ms,
        })
    }

    pub fn update_bookmark(
        &self,
        id: String,
        title: String,
        url: Option<String>,
    ) -> Result<(), StoreError> {
        let bookmark_id = parse_id(&id)?;
        let conn = self.conn()?;
        let current_url: Option<String> = conn
            .query_row(
                "SELECT url FROM bookmarks WHERE id = ?1",
                [bookmark_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound { id })?;
        if current_url.is_some() != url.is_some() {
            return Err(invalid_input(
                "a bookmark cannot become a folder or the reverse",
            ));
        }
        conn.execute(
            "UPDATE bookmarks SET title = ?2, url = ?3, match_text = ?4 WHERE id = ?1",
            params![
                bookmark_id,
                title,
                url,
                url.as_deref().map(text::match_text)
            ],
        )?;
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
        let bookmark_id = parse_id(&id)?;
        let parent = parse_parent(parent_id.as_deref())?;
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let old_parent: Option<i64> = tx
            .query_row(
                "SELECT parent_id FROM bookmarks WHERE id = ?1",
                [bookmark_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound { id })?;
        if let Some(parent) = parent {
            check_folder(&tx, parent)?;
            let into_own_subtree: bool = tx.query_row(
                "WITH RECURSIVE ancestors (id) AS (
                     SELECT ?1
                     UNION ALL
                     SELECT b.parent_id FROM bookmarks b JOIN ancestors a ON b.id = a.id
                     WHERE b.parent_id IS NOT NULL
                 )
                 SELECT EXISTS (SELECT 1 FROM ancestors WHERE id = ?2)",
                [parent, bookmark_id],
                |row| row.get(0),
            )?;
            if into_own_subtree {
                return Err(invalid_input(
                    "a folder cannot be moved into itself or its descendants",
                ));
            }
        }
        let mut order = sibling_ids(&tx, parent, Some(bookmark_id))?;
        order.insert((position as usize).min(order.len()), bookmark_id);
        set_order(&tx, parent, &order)?;
        if old_parent != parent {
            let remaining = sibling_ids(&tx, old_parent, None)?;
            set_order(&tx, old_parent, &remaining)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Deletes a bookmark, or a folder with everything inside it.
    pub fn delete_bookmark(&self, id: String) -> Result<(), StoreError> {
        let bookmark_id = parse_id(&id)?;
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let parent: Option<i64> = tx
            .query_row(
                "SELECT parent_id FROM bookmarks WHERE id = ?1",
                [bookmark_id],
                |row| row.get(0),
            )
            .optional()?
            .ok_or(StoreError::NotFound { id })?;
        tx.execute("DELETE FROM bookmarks WHERE id = ?1", [bookmark_id])?;
        let remaining = sibling_ids(&tx, parent, None)?;
        set_order(&tx, parent, &remaining)?;
        tx.commit()?;
        Ok(())
    }

    pub fn search_bookmarks(&self, query: String, limit: u32) -> Result<Vec<Bookmark>, StoreError> {
        let terms = text::prefix_terms(&query);
        if terms.is_empty() {
            return Ok(vec![]);
        }
        let conn = self.conn()?;
        let bookmarks = conn
            .prepare_cached(&format!(
                "{BOOKMARK_SELECT}
                 WHERE url IS NOT NULL
                   AND id IN (SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH ?1)
                 ORDER BY title COLLATE NOCASE, id
                 LIMIT ?2"
            ))?
            .query_map(params![terms.join(" "), limit], bookmark_from_row)?
            .collect::<Result<_, _>>()?;
        Ok(bookmarks)
    }

    /// Creates a root-level folder named `folder_title` and inserts the tree
    /// under it. Returns the number of bookmarks (not folders) inserted.
    pub fn import_bookmarks(
        &self,
        folder_title: String,
        items: Vec<BookmarkImport>,
    ) -> Result<u64, StoreError> {
        let now = now_ms()?;
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let root_position: u32 = tx.query_row(
            "SELECT COUNT(*) FROM bookmarks WHERE parent_id IS NULL",
            [],
            |row| row.get(0),
        )?;
        let folder_id = insert_bookmark(&tx, None, &folder_title, None, root_position, now)?;
        // local_id -> (row id, is a folder)
        let mut placed: HashMap<u32, (i64, bool)> = HashMap::new();
        let mut next_position: HashMap<i64, u32> = HashMap::new();
        let mut bookmarks = 0;
        for item in &items {
            let parent = match item.parent_local_id {
                None => folder_id,
                Some(local_id) => match placed.get(&local_id) {
                    Some(&(id, true)) => id,
                    Some(_) => {
                        return Err(invalid_input("import parent is a bookmark, not a folder"));
                    }
                    None => {
                        return Err(invalid_input(
                            "import parent is missing or listed after its child",
                        ));
                    }
                },
            };
            let position = next_position.entry(parent).or_insert(0);
            let id = insert_bookmark(
                &tx,
                Some(parent),
                &item.title,
                item.url.as_deref(),
                *position,
                item.created_ms.unwrap_or(now),
            )?;
            *position += 1;
            if placed
                .insert(item.local_id, (id, item.url.is_none()))
                .is_some()
            {
                return Err(invalid_input("duplicate import local_id"));
            }
            if item.url.is_some() {
                bookmarks += 1;
            }
        }
        tx.commit()?;
        Ok(bookmarks)
    }

    // ---- Address bar ----

    /// History and bookmark suggestions for address-bar input, best first.
    pub fn suggest(&self, input: String, limit: u32) -> Result<Vec<Suggestion>, StoreError> {
        let typed = text::match_text(input.trim());
        if typed.is_empty() || limit == 0 {
            return Ok(vec![]);
        }
        let upper = format!("{typed}\u{10FFFF}");
        let fetch = i64::from(limit) * 3;
        let terms = text::prefix_terms(input.trim());
        let title_match = (!terms.is_empty()).then(|| format!("title : ({})", terms.join(" ")));

        let conn = self.conn()?;
        let mut found = HashMap::new();
        collect(
            &conn,
            "SELECT u.url, u.title, u.match_text, u.frecency,
                    EXISTS (SELECT 1 FROM bookmarks b WHERE b.url = u.url)
             FROM urls u
             WHERE u.id IN (SELECT id FROM urls WHERE match_text >= ?1 AND match_text < ?2
                            ORDER BY frecency DESC LIMIT ?3)",
            &[&typed, &upper, &fetch],
            &mut found,
        )?;
        collect(
            &conn,
            "SELECT b.url, b.title, b.match_text, COALESCE(u.frecency, 0.0), 1
             FROM bookmarks b LEFT JOIN urls u ON u.url = b.url
             WHERE b.match_text >= ?1 AND b.match_text < ?2
             ORDER BY u.frecency DESC LIMIT ?3",
            &[&typed, &upper, &fetch],
            &mut found,
        )?;
        if let Some(title_match) = &title_match {
            collect(
                &conn,
                "SELECT u.url, u.title, u.match_text, u.frecency,
                        EXISTS (SELECT 1 FROM bookmarks b WHERE b.url = u.url)
                 FROM urls u
                 WHERE u.id IN (SELECT rowid FROM urls_fts WHERE urls_fts MATCH ?1
                                ORDER BY rowid DESC LIMIT ?3)
                 ORDER BY u.frecency DESC LIMIT ?2",
                &[title_match, &fetch, &TITLE_MATCHES_SCANNED],
                &mut found,
            )?;
            collect(
                &conn,
                "SELECT b.url, b.title, b.match_text, COALESCE(u.frecency, 0.0), 1
                 FROM bookmarks_fts f
                 JOIN bookmarks b ON b.id = f.rowid
                 LEFT JOIN urls u ON u.url = b.url
                 WHERE bookmarks_fts MATCH ?1 AND b.url IS NOT NULL
                 ORDER BY u.frecency DESC LIMIT ?2",
                &[title_match, &fetch],
                &mut found,
            )?;
        }

        let mut suggestions: Vec<Suggestion> = found
            .into_values()
            .map(|candidate| {
                let is_prefix = candidate.match_text.starts_with(&typed);
                let host = text::host_of(&candidate.match_text);
                let completes_host = is_prefix && !typed.contains('/') && host.starts_with(&typed);
                let quality = if completes_host {
                    HOST_PREFIX_QUALITY
                } else if is_prefix {
                    URL_PREFIX_QUALITY
                } else {
                    TITLE_QUALITY
                };
                let autocomplete = if completes_host {
                    Some(format!("{host}/"))
                } else if is_prefix {
                    Some(text::strip_url(&candidate.url).to_owned())
                } else {
                    None
                };
                let bonus = if candidate.bookmarked {
                    frecency::BOOKMARK_BONUS
                } else {
                    0.0
                };
                Suggestion {
                    source: if candidate.bookmarked {
                        SuggestionSource::Bookmark
                    } else {
                        SuggestionSource::History
                    },
                    score: quality * (candidate.frecency + bonus + 1.0),
                    url: candidate.url,
                    title: candidate.title,
                    autocomplete,
                }
            })
            .collect();
        suggestions.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.url.cmp(&b.url)));
        suggestions.truncate(limit as usize);
        Ok(suggestions)
    }

    // ---- Site settings ----

    pub fn site_settings(&self, host: String) -> Result<SiteSettings, StoreError> {
        let stored = self
            .conn()?
            .query_row(
                &format!("{SITE_SETTINGS_SELECT} WHERE host = ?1"),
                [&host],
                site_settings_from_row,
            )
            .optional()?;
        Ok(stored.unwrap_or_else(|| default_site_settings(host)))
    }

    /// Saves settings; saving the defaults removes the host's row.
    pub fn save_site_settings(&self, settings: SiteSettings) -> Result<(), StoreError> {
        if settings.host.is_empty() {
            return Err(invalid_input("site settings need a host"));
        }
        if !(settings.zoom.is_finite() && settings.zoom > 0.0) {
            return Err(invalid_input("zoom must be a positive number"));
        }
        let conn = self.conn()?;
        if settings == default_site_settings(settings.host.clone()) {
            conn.execute(
                "DELETE FROM site_settings WHERE host = ?1",
                [&settings.host],
            )?;
        } else {
            conn.execute(
                "INSERT OR REPLACE INTO site_settings (host, shields_enabled, javascript_enabled,
                     popups, camera, microphone, location, zoom, lockdown_mode)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    settings.host,
                    settings.shields_enabled,
                    settings.javascript_enabled,
                    permission_code(settings.popups),
                    permission_code(settings.camera),
                    permission_code(settings.microphone),
                    permission_code(settings.location),
                    settings.zoom,
                    settings.lockdown_mode
                ],
            )?;
        }
        Ok(())
    }

    /// Every host whose settings differ from the defaults, sorted by host.
    pub fn customized_sites(&self) -> Result<Vec<SiteSettings>, StoreError> {
        let conn = self.conn()?;
        let sites = conn
            .prepare_cached(&format!("{SITE_SETTINGS_SELECT} ORDER BY host"))?
            .query_map([], site_settings_from_row)?
            .collect::<Result<_, _>>()?;
        Ok(sites)
    }

    pub fn reset_site_settings(&self, host: String) -> Result<(), StoreError> {
        self.conn()?
            .execute("DELETE FROM site_settings WHERE host = ?1", [host])?;
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
        self.conn()?.execute(
            "INSERT INTO blocked (day, host, count) VALUES (?1, ?2, ?3)
             ON CONFLICT (day, host) DO UPDATE SET count = blocked.count + excluded.count",
            params![at_ms.div_euclid(MS_PER_DAY), tracker_host, count],
        )?;
        Ok(())
    }

    /// Totals since the start of the UTC day containing `since_ms`.
    pub fn privacy_stats(&self, since_ms: i64, top: u32) -> Result<PrivacyStats, StoreError> {
        let since_day = since_ms.div_euclid(MS_PER_DAY);
        let conn = self.conn()?;
        let blocked_total = conn.query_row(
            "SELECT COALESCE(SUM(count), 0) FROM blocked WHERE day >= ?1",
            [since_day],
            |row| row.get(0),
        )?;
        let top_trackers = conn
            .prepare_cached(
                "SELECT host, SUM(count) AS total FROM blocked WHERE day >= ?1
                 GROUP BY host ORDER BY total DESC, host LIMIT ?2",
            )?
            .query_map(params![since_day, top], |row| {
                Ok(TrackerCount {
                    host: row.get(0)?,
                    count: row.get(1)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(PrivacyStats {
            blocked_total,
            since_ms,
            top_trackers,
        })
    }

    pub fn clear_privacy_stats(&self) -> Result<(), StoreError> {
        self.conn()?.execute("DELETE FROM blocked", [])?;
        Ok(())
    }
}
