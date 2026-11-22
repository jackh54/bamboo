//! Firefox: bookmarks, history and cookies. Saved passwords are encrypted
//! with NSS and not supported.

use std::{collections::HashMap, path::Path};

use crate::{
    BrowserKind, CookieSameSite, ImportBundle, ImportError, ImportKind, ImportRequest,
    ImportedBookmark, ImportedCookie, ImportedHistory, SourceProfile,
    common::{exists, push_bookmark, read_database, read_optional},
};

const BROWSER_NAME: &str = "Firefox";

/// Special bookmark folders by `moz_bookmarks.guid`. The tags folder is left out.
const ROOTS: [(&str, &str); 4] = [
    ("toolbar_____", "Bookmarks Toolbar"),
    ("menu________", "Bookmarks Menu"),
    ("unfiled_____", "Other Bookmarks"),
    ("mobile______", "Mobile Bookmarks"),
];

struct BookmarkRow {
    id: i64,
    kind: i64,
    guid: String,
    title: String,
    url: Option<String>,
    created_us: i64,
}

pub(crate) fn discover(home: &Path) -> Vec<SourceProfile> {
    let root = home.join("Library/Application Support/Firefox");
    profiles(&root).unwrap_or_else(|e| {
        vec![SourceProfile {
            browser: BrowserKind::Firefox,
            browser_name: BROWSER_NAME.to_string(),
            profile_name: BROWSER_NAME.to_string(),
            profile_dir: root.display().to_string(),
            kinds: vec![],
            access_error: Some(e.to_string()),
        }]
    })
}

/// Empty when Firefox is not installed.
fn profiles(root: &Path) -> Result<Vec<SourceProfile>, ImportError> {
    if !exists(root)? {
        return Ok(vec![]);
    }
    let Some(ini) = read_optional(&root.join("profiles.ini"))? else {
        return Ok(vec![]);
    };
    let ini = String::from_utf8_lossy(&ini);
    let mut profiles = Vec::new();
    for (name, dir) in parse_profiles_ini(&ini, root) {
        if !exists(&dir)? {
            continue;
        }
        let mut kinds = Vec::new();
        if exists(&dir.join("places.sqlite"))? {
            kinds.extend([ImportKind::Bookmarks, ImportKind::History]);
        }
        if exists(&dir.join("cookies.sqlite"))? {
            kinds.push(ImportKind::Cookies);
        }
        profiles.push(SourceProfile {
            browser: BrowserKind::Firefox,
            browser_name: BROWSER_NAME.to_string(),
            profile_name: name,
            profile_dir: dir.display().to_string(),
            kinds,
            access_error: None,
        });
    }
    Ok(profiles)
}

/// `(Name, directory)` of every `[ProfileN]` section.
fn parse_profiles_ini(ini: &str, root: &Path) -> Vec<(String, std::path::PathBuf)> {
    let mut profiles = Vec::new();
    let (mut name, mut path, mut relative) = (None, None, true);
    let mut in_profile = false;
    let mut finish = |name: &mut Option<String>, path: &mut Option<String>, relative: bool| {
        if let (Some(name), Some(path)) = (name.take(), path.take()) {
            let dir = if relative {
                root.join(path)
            } else {
                path.into()
            };
            profiles.push((name, dir));
        }
    };
    for line in ini.lines().map(str::trim) {
        if line.starts_with('[') {
            finish(&mut name, &mut path, relative);
            in_profile = line.starts_with("[Profile");
            relative = true;
        } else if in_profile && let Some((key, value)) = line.split_once('=') {
            match key {
                "Name" => name = Some(value.to_string()),
                "Path" => path = Some(value.to_string()),
                "IsRelative" => relative = value != "0",
                _ => {}
            }
        }
    }
    finish(&mut name, &mut path, relative);
    profiles
}

pub(crate) fn import(
    profile: &SourceProfile,
    request: &ImportRequest,
    bundle: &mut ImportBundle,
) -> Result<(), ImportError> {
    let dir = Path::new(&profile.profile_dir);
    let wants = |kind| request.kinds.contains(&kind);
    if wants(ImportKind::Bookmarks) {
        bundle.bookmarks = bookmarks(&dir.join("places.sqlite"))?;
    }
    if wants(ImportKind::History) {
        bundle.history = history(&dir.join("places.sqlite"), request.history_since_ms)?;
    }
    if wants(ImportKind::Cookies) {
        bundle.cookies = cookies(&dir.join("cookies.sqlite"))?;
    }
    Ok(())
}

fn bookmarks(places: &Path) -> Result<Vec<ImportedBookmark>, ImportError> {
    let by_parent = read_database(places, |db| {
        let mut statement = db.prepare(
            "SELECT b.id, b.type, b.parent, b.guid, b.title, p.url, b.dateAdded \
             FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id \
             ORDER BY b.parent, b.position",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(2)?,
                BookmarkRow {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    guid: row.get(3)?,
                    title: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                    url: row.get(5)?,
                    created_us: row.get::<_, Option<i64>>(6)?.unwrap_or(0),
                },
            ))
        })?;
        let mut by_parent: HashMap<i64, Vec<BookmarkRow>> = HashMap::new();
        for row in rows {
            let (parent, bookmark) = row?;
            by_parent.entry(parent).or_default().push(bookmark);
        }
        Ok(by_parent)
    })?;
    let mut bookmarks = Vec::new();
    for (guid, title) in ROOTS {
        let Some(root) = by_parent.values().flatten().find(|row| row.guid == guid) else {
            continue;
        };
        let local_id = push_bookmark(&mut bookmarks, None, title.to_string(), None, None);
        push_children(&mut bookmarks, &by_parent, root.id, local_id);
        if bookmarks.len() == local_id as usize + 1 {
            bookmarks.pop();
        }
    }
    Ok(bookmarks)
}

fn push_children(
    bookmarks: &mut Vec<ImportedBookmark>,
    by_parent: &HashMap<i64, Vec<BookmarkRow>>,
    parent_id: i64,
    parent: u32,
) {
    for row in by_parent.get(&parent_id).into_iter().flatten() {
        let created_ms = (row.created_us != 0).then_some(row.created_us / 1000);
        match (row.kind, &row.url) {
            // `place:` URLs are Firefox's built-in smart folders.
            (1, Some(url)) if !url.starts_with("place:") => {
                push_bookmark(
                    bookmarks,
                    Some(parent),
                    row.title.clone(),
                    Some(url.clone()),
                    created_ms,
                );
            }
            (2, _) => {
                let local_id =
                    push_bookmark(bookmarks, Some(parent), row.title.clone(), None, created_ms);
                push_children(bookmarks, by_parent, row.id, local_id);
            }
            _ => {}
        }
    }
}

fn history(places: &Path, since_ms: Option<i64>) -> Result<Vec<ImportedHistory>, ImportError> {
    read_database(places, |db| {
        let mut statement = db.prepare(
            "SELECT p.url, p.title, COUNT(v.id), MAX(v.visit_date) FROM moz_places p \
             JOIN moz_historyvisits v ON v.place_id = p.id \
             WHERE p.hidden = 0 AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%') \
             GROUP BY p.id ORDER BY MAX(v.visit_date) DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        let mut history = Vec::new();
        for row in rows {
            let (url, title, visit_count, last_visit_us) = row?;
            let last_visit_ms = last_visit_us / 1000;
            if since_ms.is_some_and(|since| last_visit_ms < since) {
                continue;
            }
            history.push(ImportedHistory {
                url,
                title: title.filter(|title| !title.is_empty()),
                last_visit_ms,
                visit_count,
            });
        }
        Ok(history)
    })
}

fn cookies(path: &Path) -> Result<Vec<ImportedCookie>, ImportError> {
    read_database(path, |db| {
        let mut statement = db.prepare(
            "SELECT name, value, host, path, expiry, isSecure, isHttpOnly, sameSite \
             FROM moz_cookies",
        )?;
        let rows = statement.query_map([], |row| {
            let expiry_s: i64 = row.get(4)?;
            Ok(ImportedCookie {
                name: row.get(0)?,
                value: row.get(1)?,
                domain: row.get(2)?,
                path: row.get(3)?,
                expires_ms: (expiry_s != 0).then(|| expiry_s.saturating_mul(1000)),
                secure: row.get(5)?,
                http_only: row.get(6)?,
                same_site: match row.get::<_, i64>(7)? {
                    0 => CookieSameSite::NoRestriction,
                    1 => CookieSameSite::Lax,
                    2 => CookieSameSite::Strict,
                    _ => CookieSameSite::Unspecified,
                },
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })
}
