//! Connection setup and numbered schema migrations.

use std::time::Duration;

use rusqlite::Connection;

use crate::StoreError;

/// Appended to, never edited: `PRAGMA user_version` is the number already applied.
pub const MIGRATIONS: [&str; 3] = [
    // 1: history
    "
    CREATE TABLE urls (
        id INTEGER PRIMARY KEY,
        url TEXT NOT NULL UNIQUE,
        title TEXT,
        host TEXT NOT NULL,
        match_text TEXT NOT NULL,
        visit_count INTEGER NOT NULL,
        last_visit_ms INTEGER NOT NULL,
        frecency REAL NOT NULL DEFAULT 0,
        scored_at_ms INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX urls_match_text ON urls (match_text, frecency);
    CREATE INDEX urls_scored_at ON urls (scored_at_ms);
    CREATE TABLE visits (
        id INTEGER PRIMARY KEY,
        url_id INTEGER NOT NULL REFERENCES urls (id) ON DELETE CASCADE,
        visited_at_ms INTEGER NOT NULL,
        weight INTEGER NOT NULL
    );
    CREATE INDEX visits_url ON visits (url_id, visited_at_ms);
    CREATE INDEX visits_time ON visits (visited_at_ms);
    CREATE VIRTUAL TABLE urls_fts USING fts5(
        title, match_text, content = 'urls', content_rowid = 'id', prefix = '2 3'
    );
    CREATE TRIGGER urls_ai AFTER INSERT ON urls BEGIN
        INSERT INTO urls_fts (rowid, title, match_text) VALUES (new.id, new.title, new.match_text);
    END;
    CREATE TRIGGER urls_ad AFTER DELETE ON urls BEGIN
        INSERT INTO urls_fts (urls_fts, rowid, title, match_text)
        VALUES ('delete', old.id, old.title, old.match_text);
    END;
    CREATE TRIGGER urls_au AFTER UPDATE OF title ON urls WHEN old.title IS NOT new.title BEGIN
        INSERT INTO urls_fts (urls_fts, rowid, title, match_text)
        VALUES ('delete', old.id, old.title, old.match_text);
        INSERT INTO urls_fts (rowid, title, match_text) VALUES (new.id, new.title, new.match_text);
    END;
    ",
    // 2: bookmarks
    "
    CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_id INTEGER REFERENCES bookmarks (id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        url TEXT,
        match_text TEXT,
        position INTEGER NOT NULL,
        created_ms INTEGER NOT NULL
    );
    CREATE INDEX bookmarks_parent ON bookmarks (parent_id, position);
    CREATE INDEX bookmarks_url ON bookmarks (url);
    CREATE INDEX bookmarks_match_text ON bookmarks (match_text);
    CREATE VIRTUAL TABLE bookmarks_fts USING fts5(
        title, match_text, content = 'bookmarks', content_rowid = 'id', prefix = '2 3'
    );
    CREATE TRIGGER bookmarks_ai AFTER INSERT ON bookmarks BEGIN
        INSERT INTO bookmarks_fts (rowid, title, match_text)
        VALUES (new.id, new.title, new.match_text);
    END;
    CREATE TRIGGER bookmarks_ad AFTER DELETE ON bookmarks BEGIN
        INSERT INTO bookmarks_fts (bookmarks_fts, rowid, title, match_text)
        VALUES ('delete', old.id, old.title, old.match_text);
    END;
    CREATE TRIGGER bookmarks_au AFTER UPDATE OF title, match_text ON bookmarks BEGIN
        INSERT INTO bookmarks_fts (bookmarks_fts, rowid, title, match_text)
        VALUES ('delete', old.id, old.title, old.match_text);
        INSERT INTO bookmarks_fts (rowid, title, match_text)
        VALUES (new.id, new.title, new.match_text);
    END;
    ",
    // 3: site settings and privacy stats
    "
    CREATE TABLE site_settings (
        host TEXT PRIMARY KEY,
        shields_enabled INTEGER NOT NULL,
        javascript_enabled INTEGER NOT NULL,
        popups INTEGER NOT NULL,
        camera INTEGER NOT NULL,
        microphone INTEGER NOT NULL,
        location INTEGER NOT NULL,
        zoom REAL NOT NULL,
        lockdown_mode INTEGER NOT NULL
    );
    CREATE TABLE blocked (
        day INTEGER NOT NULL,
        host TEXT NOT NULL,
        count INTEGER NOT NULL,
        PRIMARY KEY (day, host)
    );
    ",
];

pub fn init(conn: &mut Connection) -> Result<(), StoreError> {
    conn.busy_timeout(Duration::from_secs(5))?;
    let journal_mode: String =
        conn.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
    if !journal_mode.eq_ignore_ascii_case("wal") {
        return Err(StoreError::Database {
            message: format!("could not enable WAL, journal mode is {journal_mode}"),
        });
    }
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", true)?;
    migrate(conn)
}

fn migrate(conn: &mut Connection) -> Result<(), StoreError> {
    let applied: usize = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if applied > MIGRATIONS.len() {
        return Err(StoreError::Database {
            message: format!(
                "database schema version {applied} is newer than this build supports ({})",
                MIGRATIONS.len()
            ),
        });
    }
    for (index, migration) in MIGRATIONS.iter().enumerate().skip(applied) {
        let tx = conn.transaction()?;
        tx.execute_batch(migration)?;
        tx.pragma_update(None, "user_version", index + 1)?;
        tx.commit()?;
    }
    Ok(())
}
