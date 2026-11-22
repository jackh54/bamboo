//! Safari: bookmarks (`Bookmarks.plist`) and history (`History.db`). Both live
//! in `~/Library/Safari`, which macOS protects behind Full Disk Access.

use std::path::Path;

use serde::Deserialize;

use crate::{
    BrowserKind, ImportBundle, ImportError, ImportKind, ImportRequest, ImportedBookmark,
    ImportedHistory, SourceProfile,
    common::{core_data_time_ms, exists, push_bookmark, read, read_database},
};

const BROWSER_NAME: &str = "Safari";
/// Title Safari gives the Reading List folder, which is not a bookmark folder.
const READING_LIST: &str = "com.apple.ReadingList";

#[derive(Deserialize)]
struct Node {
    #[serde(rename = "WebBookmarkType")]
    kind: String,
    #[serde(rename = "Title")]
    title: Option<String>,
    #[serde(rename = "Children", default)]
    children: Vec<Node>,
    #[serde(rename = "URLString")]
    url: Option<String>,
    #[serde(rename = "URIDictionary")]
    uri_dictionary: Option<UriDictionary>,
}

#[derive(Deserialize)]
struct UriDictionary {
    title: Option<String>,
}

pub(crate) fn discover(home: &Path) -> Vec<SourceProfile> {
    let dir = home.join("Library/Safari");
    let found = (|| {
        let mut kinds = Vec::new();
        if exists(&dir.join("Bookmarks.plist"))? {
            kinds.push(ImportKind::Bookmarks);
        }
        if exists(&dir.join("History.db"))? {
            kinds.push(ImportKind::History);
        }
        Ok::<_, ImportError>(kinds)
    })();
    let (kinds, access_error) = match found {
        Ok(kinds) if kinds.is_empty() => return vec![],
        Ok(kinds) => (kinds, None),
        Err(e) => (vec![], Some(e.to_string())),
    };
    vec![SourceProfile {
        browser: BrowserKind::Safari,
        browser_name: BROWSER_NAME.to_string(),
        profile_name: BROWSER_NAME.to_string(),
        profile_dir: dir.display().to_string(),
        kinds,
        access_error,
    }]
}

pub(crate) fn import(
    profile: &SourceProfile,
    request: &ImportRequest,
    bundle: &mut ImportBundle,
) -> Result<(), ImportError> {
    let dir = Path::new(&profile.profile_dir);
    let wants = |kind| request.kinds.contains(&kind);
    if wants(ImportKind::Bookmarks) {
        bundle.bookmarks = bookmarks(&dir.join("Bookmarks.plist"))?;
    }
    if wants(ImportKind::History) {
        bundle.history = history(&dir.join("History.db"), request.history_since_ms)?;
    }
    Ok(())
}

/// Safari's own folders are renamed; the Reading List and the History proxy
/// are not bookmarks and are skipped. Safari stores no bookmark dates.
fn bookmarks(path: &Path) -> Result<Vec<ImportedBookmark>, ImportError> {
    let root: Node = plist::from_bytes(&read(path)?)?;
    let mut bookmarks = Vec::new();
    for node in root.children {
        let title = match node.title.as_deref() {
            Some("BookmarksBar") => Some("Favorites".to_string()),
            Some("BookmarksMenu") => Some("Bookmarks Menu".to_string()),
            Some(READING_LIST) => continue,
            _ => None,
        };
        push_node(&mut bookmarks, None, node, title)?;
    }
    Ok(bookmarks)
}

fn push_node(
    bookmarks: &mut Vec<ImportedBookmark>,
    parent: Option<u32>,
    node: Node,
    title_override: Option<String>,
) -> Result<(), ImportError> {
    match node.kind.as_str() {
        "WebBookmarkTypeLeaf" => {
            let title = node
                .uri_dictionary
                .and_then(|dictionary| dictionary.title)
                .unwrap_or_default();
            push_bookmark(bookmarks, parent, title, node.url, None);
        }
        "WebBookmarkTypeList" => {
            if node.children.is_empty() {
                return Ok(());
            }
            let title = title_override.or(node.title).unwrap_or_default();
            let local_id = push_bookmark(bookmarks, parent, title, None, None);
            for child in node.children {
                push_node(bookmarks, Some(local_id), child, None)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn history(path: &Path, since_ms: Option<i64>) -> Result<Vec<ImportedHistory>, ImportError> {
    read_database(path, |db| {
        // SQLite takes bare columns (the title) from the row holding MAX().
        let mut statement = db.prepare(
            "SELECT i.url, v.title, COUNT(v.id), MAX(v.visit_time) FROM history_items i \
             JOIN history_visits v ON v.history_item = i.id \
             WHERE i.url LIKE 'http://%' OR i.url LIKE 'https://%' \
             GROUP BY i.id ORDER BY MAX(v.visit_time) DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, f64>(3)?,
            ))
        })?;
        let mut history = Vec::new();
        for row in rows {
            let (url, title, visit_count, last_visit_time) = row?;
            let last_visit_ms = core_data_time_ms(last_visit_time);
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
