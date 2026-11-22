use rusqlite::Connection;
use tempfile::TempDir;

use super::*;
use crate::schema::MIGRATIONS;

const NOW: i64 = 1_700_000_000_000;
const DAY: i64 = MS_PER_DAY;

fn open_store() -> (TempDir, Arc<Store>) {
    let dir = TempDir::new().unwrap();
    let store = Store::open(db_path(&dir)).unwrap();
    (dir, store)
}

fn db_path(dir: &TempDir) -> String {
    dir.path().join("profile.db").to_str().unwrap().to_owned()
}

fn visit(store: &Store, url: &str, title: Option<&str>, kind: VisitKind, at_ms: i64) {
    store
        .record_visit(url.into(), title.map(Into::into), kind, at_ms)
        .unwrap();
}

fn link(store: &Store, url: &str, title: Option<&str>, at_ms: i64) {
    visit(store, url, title, VisitKind::Link, at_ms);
}

fn entry_urls(entries: &[HistoryEntry]) -> Vec<&str> {
    entries.iter().map(|entry| entry.url.as_str()).collect()
}

fn suggestion_urls(suggestions: &[Suggestion]) -> Vec<&str> {
    suggestions.iter().map(|s| s.url.as_str()).collect()
}

fn titles(bookmarks: &[Bookmark]) -> Vec<&str> {
    bookmarks.iter().map(|b| b.title.as_str()).collect()
}

fn add_bookmark(
    store: &Store,
    parent: Option<&Bookmark>,
    title: &str,
    url: Option<&str>,
) -> Bookmark {
    store
        .add_bookmark(
            parent.map(|p| p.id.clone()),
            title.into(),
            url.map(Into::into),
        )
        .unwrap()
}

fn user_version(path: &str) -> usize {
    Connection::open(path)
        .unwrap()
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap()
}

fn import_item(
    local_id: u32,
    parent_local_id: Option<u32>,
    title: &str,
    url: Option<&str>,
) -> BookmarkImport {
    BookmarkImport {
        local_id,
        parent_local_id,
        title: title.into(),
        url: url.map(Into::into),
        created_ms: None,
    }
}

// ---- Text helpers ----

#[test]
fn strip_url_removes_scheme_and_www() {
    assert_eq!(
        text::strip_url("https://www.github.com/a?b#c"),
        "github.com/a?b#c"
    );
    assert_eq!(
        text::strip_url("http://localhost:3000/x"),
        "localhost:3000/x"
    );
    assert_eq!(text::strip_url("github.com"), "github.com");
    assert_eq!(text::strip_url("about:blank"), "about:blank");
    assert_eq!(
        text::host("HTTPS://WWW.Example.com:8080/Path"),
        "example.com:8080"
    );
}

// ---- Migrations ----

#[test]
fn fresh_database_is_fully_migrated() {
    let dir = TempDir::new().unwrap();
    let path = db_path(&dir);
    Store::open(path.clone()).unwrap();
    assert_eq!(user_version(&path), MIGRATIONS.len());
    let conn = Connection::open(&path).unwrap();
    for table in ["urls", "visits", "bookmarks", "site_settings", "blocked"] {
        let exists: bool = conn
            .query_row(
                "SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE name = ?1)",
                [table],
                |row| row.get(0),
            )
            .unwrap();
        assert!(exists, "missing table {table}");
    }
}

#[test]
fn reopened_database_keeps_data_and_version() {
    let dir = TempDir::new().unwrap();
    let path = db_path(&dir);
    let store = Store::open(path.clone()).unwrap();
    link(&store, "https://example.com/", Some("Example"), NOW);
    add_bookmark(&store, None, "Example", Some("https://example.com/"));
    drop(store);

    let reopened = Store::open(path.clone()).unwrap();
    assert_eq!(user_version(&path), MIGRATIONS.len());
    assert_eq!(
        reopened.search_history("example".into(), 10).unwrap().len(),
        1
    );
    assert_eq!(reopened.bookmark_children(None).unwrap().len(), 1);
}

#[test]
fn old_database_is_upgraded_in_place() {
    let dir = TempDir::new().unwrap();
    let path = db_path(&dir);
    let old = Connection::open(&path).unwrap();
    old.execute_batch(MIGRATIONS[0]).unwrap();
    old.pragma_update(None, "user_version", 1).unwrap();
    old.execute(
        "INSERT INTO urls (url, title, host, match_text, visit_count, last_visit_ms)
         VALUES ('https://old.example/', 'Old page', 'old.example', 'old.example/', 1, 5)",
        [],
    )
    .unwrap();
    drop(old);

    let store = Store::open(path.clone()).unwrap();
    assert_eq!(user_version(&path), MIGRATIONS.len());
    let found = store.search_history("old".into(), 10).unwrap();
    assert_eq!(entry_urls(&found), ["https://old.example/"]);
    add_bookmark(&store, None, "New", Some("https://new.example/"));
    store
        .record_blocked("tracker.example".into(), 1, NOW)
        .unwrap();
}

#[test]
fn database_from_a_newer_build_is_rejected() {
    let dir = TempDir::new().unwrap();
    let path = db_path(&dir);
    Store::open(path.clone()).unwrap();
    Connection::open(&path)
        .unwrap()
        .pragma_update(None, "user_version", MIGRATIONS.len() + 1)
        .unwrap();
    assert!(matches!(
        Store::open(path),
        Err(StoreError::Database { .. })
    ));
}

// ---- History ----

#[test]
fn record_visit_aggregates_per_url() {
    let (_dir, store) = open_store();
    link(&store, "https://example.com/", Some("Example"), NOW);
    link(&store, "https://example.com/", None, NOW + 1000);

    let found = store.search_history("example".into(), 10).unwrap();
    assert_eq!(
        found,
        [HistoryEntry {
            url: "https://example.com/".into(),
            title: Some("Example".into()),
            last_visit_ms: NOW + 1000,
            visit_count: 2,
        }]
    );
    assert_eq!(store.visits(None, None, 10).unwrap().len(), 2);
}

#[test]
fn record_visit_rejects_empty_url() {
    let (_dir, store) = open_store();
    let result = store.record_visit(String::new(), None, VisitKind::Link, NOW);
    assert!(matches!(result, Err(StoreError::InvalidInput { .. })));
}

#[test]
fn set_title_updates_search_and_reports_unknown_urls() {
    let (_dir, store) = open_store();
    link(&store, "https://example.com/", None, NOW);
    assert!(
        store
            .search_history("cooking".into(), 10)
            .unwrap()
            .is_empty()
    );

    store
        .set_title("https://example.com/".into(), "Cooking notes".into())
        .unwrap();
    assert_eq!(store.search_history("cooking".into(), 10).unwrap().len(), 1);

    let missing = store.set_title("https://nope.example/".into(), "x".into());
    assert!(matches!(missing, Err(StoreError::NotFound { .. })));
}

#[test]
fn visits_are_newest_first_and_page_with_before_ms() {
    let (_dir, store) = open_store();
    for (i, url) in [
        "https://a.com/",
        "https://b.com/",
        "https://c.com/",
        "https://a.com/",
    ]
    .iter()
    .enumerate()
    {
        link(&store, url, None, NOW + i as i64 * 1000);
    }

    let first_page = store.visits(None, None, 2).unwrap();
    assert_eq!(
        first_page
            .iter()
            .map(|v| v.visited_at_ms)
            .collect::<Vec<_>>(),
        [NOW + 3000, NOW + 2000]
    );
    let second_page = store
        .visits(None, Some(first_page[1].visited_at_ms), 2)
        .unwrap();
    assert_eq!(
        second_page
            .iter()
            .map(|v| v.url.as_str())
            .collect::<Vec<_>>(),
        ["https://b.com/", "https://a.com/"]
    );
}

#[test]
fn visits_filter_by_title_or_url() {
    let (_dir, store) = open_store();
    link(
        &store,
        "https://rust-lang.org/",
        Some("Rust Programming Language"),
        NOW,
    );
    link(&store, "https://news.example/", Some("Daily news"), NOW + 1);

    let by_title = store.visits(Some("progr".into()), None, 10).unwrap();
    assert_eq!(by_title.len(), 1);
    assert_eq!(by_title[0].url, "https://rust-lang.org/");
    let by_url = store.visits(Some("news.exa".into()), None, 10).unwrap();
    assert_eq!(by_url.len(), 1);
    assert_eq!(by_url[0].url, "https://news.example/");
    assert_eq!(store.visits(Some("  ".into()), None, 10).unwrap().len(), 2);
}

#[test]
fn search_history_ranks_by_frecency() {
    let (_dir, store) = open_store();
    link(
        &store,
        "https://old.example/",
        Some("Rust old"),
        NOW - 200 * DAY,
    );
    link(&store, "https://recent.example/", Some("Rust recent"), NOW);
    visit(
        &store,
        "https://typed.example/",
        Some("Rust typed"),
        VisitKind::Typed,
        NOW,
    );

    let found = store.search_history("rust".into(), 10).unwrap();
    assert_eq!(
        entry_urls(&found),
        [
            "https://typed.example/",
            "https://recent.example/",
            "https://old.example/"
        ]
    );
    assert_eq!(store.search_history("rust".into(), 1).unwrap().len(), 1);
    assert!(store.search_history("   ".into(), 10).unwrap().is_empty());
}

#[test]
fn frecency_counts_repeat_visits() {
    let (_dir, store) = open_store();
    link(&store, "https://once.example/", Some("page"), NOW);
    for i in 0..5 {
        link(&store, "https://often.example/", Some("page"), NOW + i);
    }
    let found = store.search_history("page".into(), 10).unwrap();
    assert_eq!(entry_urls(&found)[0], "https://often.example/");
}

#[test]
fn top_sites_returns_best_url_per_host() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/popular", None, NOW);
    link(&store, "https://a.com/popular", None, NOW + 1);
    link(&store, "http://www.a.com/rare", None, NOW + 2);
    link(&store, "https://b.com/", None, NOW + 3);

    let sites = store.top_sites(10).unwrap();
    assert_eq!(
        entry_urls(&sites),
        ["https://a.com/popular", "https://b.com/"]
    );
    assert_eq!(store.top_sites(1).unwrap().len(), 1);
}

#[test]
fn top_sites_boosts_bookmarked_urls() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/plain", None, NOW);
    link(&store, "https://a.com/saved", None, NOW);
    assert_eq!(
        entry_urls(&store.top_sites(10).unwrap()),
        ["https://a.com/plain"]
    );

    add_bookmark(&store, None, "Saved", Some("https://a.com/saved"));
    assert_eq!(
        entry_urls(&store.top_sites(10).unwrap()),
        ["https://a.com/saved"]
    );
}

#[test]
fn delete_url_removes_visits_and_search_entries() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/", Some("Alpha"), NOW);
    link(&store, "https://b.com/", Some("Beta"), NOW + 1);

    store.delete_url("https://a.com/".into()).unwrap();
    assert!(store.search_history("alpha".into(), 10).unwrap().is_empty());
    let remaining = store.visits(None, None, 10).unwrap();
    assert_eq!(remaining.len(), 1);
    assert_eq!(remaining[0].url, "https://b.com/");
}

#[test]
fn clear_history_everything_returns_visit_count() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/", Some("Alpha"), NOW);
    link(&store, "https://a.com/", None, NOW + 1);
    link(&store, "https://b.com/", Some("Beta"), NOW + 2);

    assert_eq!(store.clear_history(None).unwrap(), 3);
    assert!(store.visits(None, None, 10).unwrap().is_empty());
    assert!(store.search_history("alpha".into(), 10).unwrap().is_empty());
    assert!(store.top_sites(10).unwrap().is_empty());
    assert_eq!(store.clear_history(None).unwrap(), 0);
}

#[test]
fn clear_history_since_keeps_older_visits_and_fixes_aggregates() {
    let (_dir, store) = open_store();
    link(&store, "https://kept.example/", Some("Kept"), NOW);
    link(&store, "https://kept.example/", None, NOW + 10);
    link(&store, "https://gone.example/", Some("Gone"), NOW + 11);
    link(&store, "https://kept.example/", None, NOW + 12);

    assert_eq!(store.clear_history(Some(NOW + 10)).unwrap(), 3);
    let found = store.search_history("kept".into(), 10).unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].visit_count, 1);
    assert_eq!(found[0].last_visit_ms, NOW);
    assert!(store.search_history("gone".into(), 10).unwrap().is_empty());
}

#[test]
fn import_history_merges_with_existing_entries() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/", Some("Old title"), NOW);
    link(&store, "https://a.com/", None, NOW + 100);

    let written = store
        .import_history(vec![
            HistoryImport {
                url: "https://a.com/".into(),
                title: Some("New title".into()),
                last_visit_ms: NOW + 500,
                visit_count: 5,
            },
            HistoryImport {
                url: "https://b.com/".into(),
                title: Some("Fresh".into()),
                last_visit_ms: NOW + 50,
                visit_count: 3,
            },
        ])
        .unwrap();
    assert_eq!(written, 2);

    let a = store.search_history("title".into(), 10).unwrap();
    assert_eq!(a.len(), 1);
    assert_eq!(a[0].title.as_deref(), Some("New title"));
    assert_eq!(a[0].visit_count, 7);
    assert_eq!(a[0].last_visit_ms, NOW + 500);
    let b = store.search_history("fresh".into(), 10).unwrap();
    assert_eq!(b[0].visit_count, 3);
    assert_eq!(b[0].last_visit_ms, NOW + 50);
}

#[test]
fn import_history_keeps_later_last_visit_and_title_when_import_is_older() {
    let (_dir, store) = open_store();
    link(&store, "https://a.com/", Some("Current"), NOW + 1000);
    store
        .import_history(vec![HistoryImport {
            url: "https://a.com/".into(),
            title: Some("Imported".into()),
            last_visit_ms: NOW,
            visit_count: 4,
        }])
        .unwrap();

    let found = store.search_history("current".into(), 10).unwrap();
    assert_eq!(found[0].title.as_deref(), Some("Current"));
    assert_eq!(found[0].visit_count, 5);
    assert_eq!(found[0].last_visit_ms, NOW + 1000);
}

#[test]
fn import_history_is_all_or_nothing() {
    let (_dir, store) = open_store();
    let result = store.import_history(vec![
        HistoryImport {
            url: "https://a.com/".into(),
            title: None,
            last_visit_ms: NOW,
            visit_count: 1,
        },
        HistoryImport {
            url: "https://b.com/".into(),
            title: None,
            last_visit_ms: NOW,
            visit_count: 0,
        },
    ]);
    assert!(matches!(result, Err(StoreError::InvalidInput { .. })));
    assert!(store.visits(None, None, 10).unwrap().is_empty());
    assert_eq!(store.import_history(vec![]).unwrap(), 0);
}

// ---- Suggestions ----

#[test]
fn suggest_ranks_prefix_matches_above_title_matches() {
    let (_dir, store) = open_store();
    link(&store, "https://github.com/", Some("GitHub"), NOW);
    link(
        &store,
        "https://blog.example/post",
        Some("Getting started with git"),
        NOW,
    );

    let found = store.suggest("git".into(), 10).unwrap();
    assert_eq!(
        suggestion_urls(&found),
        ["https://github.com/", "https://blog.example/post"]
    );
    assert!(found[0].score > found[1].score);
}

#[test]
fn suggest_autocompletes_the_host_when_input_is_a_host_prefix() {
    let (_dir, store) = open_store();
    link(
        &store,
        "https://www.github.com/jackh54/bamboo",
        Some("bamboo"),
        NOW,
    );

    for input in ["git", "GIT", "github.com", "https://git", "www.git"] {
        let found = store.suggest(input.into(), 5).unwrap();
        assert_eq!(
            found[0].autocomplete.as_deref(),
            Some("github.com/"),
            "input {input:?}"
        );
    }
}

#[test]
fn suggest_autocompletes_the_path_once_input_leaves_the_host() {
    let (_dir, store) = open_store();
    link(&store, "https://example.com/ReadMe", None, NOW);

    let found = store.suggest("example.com/rea".into(), 5).unwrap();
    assert_eq!(found[0].autocomplete.as_deref(), Some("example.com/ReadMe"));
    let exact = store.suggest("example.com/readme".into(), 5).unwrap();
    assert_eq!(exact[0].autocomplete.as_deref(), Some("example.com/ReadMe"));
}

#[test]
fn suggest_has_no_autocomplete_for_title_only_matches() {
    let (_dir, store) = open_store();
    link(
        &store,
        "https://example.com/",
        Some("Learn Rust today"),
        NOW,
    );

    let found = store.suggest("rus".into(), 5).unwrap();
    assert_eq!(suggestion_urls(&found), ["https://example.com/"]);
    assert_eq!(found[0].autocomplete, None);
    assert_eq!(store.suggest("learn tod".into(), 5).unwrap().len(), 1);
}

#[test]
fn suggest_does_not_match_inside_words_or_other_text() {
    let (_dir, store) = open_store();
    link(&store, "https://github.com/", Some("GitHub"), NOW);

    assert!(store.suggest("hub".into(), 5).unwrap().is_empty());
    assert!(store.suggest("zzz".into(), 5).unwrap().is_empty());
    assert!(store.suggest("   ".into(), 5).unwrap().is_empty());
    assert!(store.suggest("git".into(), 0).unwrap().is_empty());
}

#[test]
fn suggest_prefers_frequently_and_recently_visited_urls() {
    let (_dir, store) = open_store();
    link(&store, "https://git-old.example/", None, NOW - 300 * DAY);
    link(&store, "https://git-new.example/", None, NOW);
    for i in 0..4 {
        link(&store, "https://git-busy.example/", None, NOW + i);
    }
    visit(
        &store,
        "https://git-typed.example/",
        None,
        VisitKind::Typed,
        NOW,
    );

    let found = store.suggest("git".into(), 10).unwrap();
    assert_eq!(found[0].url, "https://git-busy.example/");
    let order = suggestion_urls(&found);
    let position = |url: &str| order.iter().position(|u| *u == url).unwrap();
    assert!(position("https://git-typed.example/") < position("https://git-new.example/"));
    assert!(position("https://git-new.example/") < position("https://git-old.example/"));
}

#[test]
fn suggest_merges_history_and_bookmarks_without_duplicates() {
    let (_dir, store) = open_store();
    link(&store, "https://docs.example/", Some("Docs"), NOW);
    add_bookmark(&store, None, "Docs", Some("https://docs.example/"));
    add_bookmark(
        &store,
        None,
        "Docs mirror",
        Some("https://docs-mirror.example/"),
    );

    let found = store.suggest("docs".into(), 10).unwrap();
    assert_eq!(
        suggestion_urls(&found),
        ["https://docs.example/", "https://docs-mirror.example/"]
    );
    assert_eq!(found[0].source, SuggestionSource::Bookmark);
    assert_eq!(found[1].source, SuggestionSource::Bookmark);
}

#[test]
fn suggest_marks_plain_history_as_history_and_boosts_bookmarks() {
    let (_dir, store) = open_store();
    link(&store, "https://a-plain.example/", None, NOW);
    link(&store, "https://a-saved.example/", None, NOW);
    add_bookmark(&store, None, "saved", Some("https://a-saved.example/"));

    let found = store.suggest("a-".into(), 10).unwrap();
    assert_eq!(
        suggestion_urls(&found),
        ["https://a-saved.example/", "https://a-plain.example/"]
    );
    assert_eq!(found[1].source, SuggestionSource::History);
}

#[test]
fn suggest_finds_bookmarks_by_title_and_ignores_folders() {
    let (_dir, store) = open_store();
    let folder = add_bookmark(&store, None, "Recipes", None);
    add_bookmark(
        &store,
        Some(&folder),
        "Pancake recipe",
        Some("https://food.example/pancakes"),
    );

    let found = store.suggest("recip".into(), 10).unwrap();
    assert_eq!(suggestion_urls(&found), ["https://food.example/pancakes"]);
    assert_eq!(found[0].autocomplete, None);
}

#[test]
fn suggest_respects_limit() {
    let (_dir, store) = open_store();
    for i in 0..10 {
        link(&store, &format!("https://site{i}.example/"), None, NOW + i);
    }
    assert_eq!(store.suggest("site".into(), 3).unwrap().len(), 3);
}

// ---- Bookmarks ----

#[test]
fn bookmarks_get_contiguous_positions_per_parent() {
    let (_dir, store) = open_store();
    let first = add_bookmark(&store, None, "first", Some("https://one.example/"));
    let folder = add_bookmark(&store, None, "folder", None);
    let nested = add_bookmark(
        &store,
        Some(&folder),
        "nested",
        Some("https://two.example/"),
    );

    assert_eq!(
        (first.position, folder.position, nested.position),
        (0, 1, 0)
    );
    assert_eq!(nested.parent_id.as_deref(), Some(folder.id.as_str()));
    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["first", "folder"]);
    assert_eq!(root[1].url, None);
    assert_eq!(
        titles(&store.bookmark_children(Some(folder.id)).unwrap()),
        ["nested"]
    );
}

#[test]
fn add_bookmark_validates_the_parent() {
    let (_dir, store) = open_store();
    let leaf = add_bookmark(&store, None, "leaf", Some("https://one.example/"));

    let missing = store.add_bookmark(Some("999".into()), "x".into(), None);
    assert!(matches!(missing, Err(StoreError::NotFound { .. })));
    let garbage = store.add_bookmark(Some("not-an-id".into()), "x".into(), None);
    assert!(matches!(garbage, Err(StoreError::NotFound { .. })));
    let under_bookmark = store.add_bookmark(Some(leaf.id), "x".into(), None);
    assert!(matches!(
        under_bookmark,
        Err(StoreError::InvalidInput { .. })
    ));
}

#[test]
fn bookmarks_for_url_lists_every_match() {
    let (_dir, store) = open_store();
    let folder = add_bookmark(&store, None, "folder", None);
    add_bookmark(&store, None, "one", Some("https://same.example/"));
    add_bookmark(&store, Some(&folder), "two", Some("https://same.example/"));
    add_bookmark(&store, None, "other", Some("https://other.example/"));

    let found = store
        .bookmarks_for_url("https://same.example/".into())
        .unwrap();
    assert_eq!(titles(&found), ["one", "two"]);
}

#[test]
fn update_bookmark_changes_title_and_url() {
    let (_dir, store) = open_store();
    let bookmark = add_bookmark(&store, None, "old", Some("https://old.example/"));
    store
        .update_bookmark(
            bookmark.id.clone(),
            "new".into(),
            Some("https://new.example/".into()),
        )
        .unwrap();

    let stored = &store.bookmark_children(None).unwrap()[0];
    assert_eq!(
        (stored.title.as_str(), stored.url.as_deref()),
        ("new", Some("https://new.example/"))
    );
    assert!(store.search_bookmarks("old".into(), 10).unwrap().is_empty());
    assert_eq!(
        titles(&store.search_bookmarks("new.exa".into(), 10).unwrap()),
        ["new"]
    );
}

#[test]
fn update_bookmark_rejects_unknown_ids_and_kind_changes() {
    let (_dir, store) = open_store();
    let bookmark = add_bookmark(&store, None, "page", Some("https://a.example/"));
    let folder = add_bookmark(&store, None, "folder", None);

    let unknown = store.update_bookmark("999".into(), "x".into(), None);
    assert!(matches!(unknown, Err(StoreError::NotFound { .. })));
    let to_folder = store.update_bookmark(bookmark.id, "x".into(), None);
    assert!(matches!(to_folder, Err(StoreError::InvalidInput { .. })));
    let to_bookmark =
        store.update_bookmark(folder.id, "x".into(), Some("https://b.example/".into()));
    assert!(matches!(to_bookmark, Err(StoreError::InvalidInput { .. })));
}

fn abc(store: &Store) -> (Bookmark, Bookmark, Bookmark) {
    (
        add_bookmark(store, None, "a", Some("https://a.example/")),
        add_bookmark(store, None, "b", Some("https://b.example/")),
        add_bookmark(store, None, "c", Some("https://c.example/")),
    )
}

fn assert_contiguous(bookmarks: &[Bookmark]) {
    let positions: Vec<u32> = bookmarks.iter().map(|b| b.position).collect();
    assert_eq!(positions, (0..bookmarks.len() as u32).collect::<Vec<_>>());
}

#[test]
fn move_bookmark_reorders_within_a_parent() {
    let (_dir, store) = open_store();
    let (a, _b, c) = abc(&store);

    store.move_bookmark(c.id.clone(), None, 0).unwrap();
    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["c", "a", "b"]);
    assert_contiguous(&root);

    store.move_bookmark(a.id, None, 2).unwrap();
    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["c", "b", "a"]);
    assert_contiguous(&root);
}

#[test]
fn move_bookmark_clamps_position_past_the_end() {
    let (_dir, store) = open_store();
    let (a, _b, _c) = abc(&store);
    store.move_bookmark(a.id, None, 99).unwrap();
    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["b", "c", "a"]);
    assert_contiguous(&root);
}

#[test]
fn move_bookmark_between_parents_renumbers_both() {
    let (_dir, store) = open_store();
    let (a, b, _c) = abc(&store);
    let folder = add_bookmark(&store, None, "folder", None);
    add_bookmark(&store, Some(&folder), "inside", Some("https://i.example/"));

    store
        .move_bookmark(a.id, Some(folder.id.clone()), 0)
        .unwrap();
    store
        .move_bookmark(b.id, Some(folder.id.clone()), 1)
        .unwrap();

    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["c", "folder"]);
    assert_contiguous(&root);
    let inside = store.bookmark_children(Some(folder.id)).unwrap();
    assert_eq!(titles(&inside), ["a", "b", "inside"]);
    assert_contiguous(&inside);
}

#[test]
fn move_bookmark_to_the_root() {
    let (_dir, store) = open_store();
    let folder = add_bookmark(&store, None, "folder", None);
    let inner = add_bookmark(&store, Some(&folder), "inner", Some("https://i.example/"));

    store.move_bookmark(inner.id, None, 0).unwrap();
    assert_eq!(
        titles(&store.bookmark_children(None).unwrap()),
        ["inner", "folder"]
    );
    assert!(store.bookmark_children(Some(folder.id)).unwrap().is_empty());
}

#[test]
fn move_bookmark_rejects_cycles() {
    let (_dir, store) = open_store();
    let outer = add_bookmark(&store, None, "outer", None);
    let middle = add_bookmark(&store, Some(&outer), "middle", None);
    let inner = add_bookmark(&store, Some(&middle), "inner", None);

    let into_self = store.move_bookmark(outer.id.clone(), Some(outer.id.clone()), 0);
    assert!(matches!(into_self, Err(StoreError::InvalidInput { .. })));
    let into_child = store.move_bookmark(outer.id.clone(), Some(middle.id.clone()), 0);
    assert!(matches!(into_child, Err(StoreError::InvalidInput { .. })));
    let into_grandchild = store.move_bookmark(outer.id.clone(), Some(inner.id.clone()), 0);
    assert!(matches!(
        into_grandchild,
        Err(StoreError::InvalidInput { .. })
    ));
    let middle_into_inner = store.move_bookmark(middle.id.clone(), Some(inner.id), 0);
    assert!(matches!(
        middle_into_inner,
        Err(StoreError::InvalidInput { .. })
    ));

    assert_eq!(titles(&store.bookmark_children(None).unwrap()), ["outer"]);
    assert_eq!(
        titles(&store.bookmark_children(Some(outer.id)).unwrap()),
        ["middle"]
    );
}

#[test]
fn move_bookmark_rejects_unknown_ids_and_non_folder_parents() {
    let (_dir, store) = open_store();
    let (a, b, _c) = abc(&store);

    let unknown_item = store.move_bookmark("999".into(), None, 0);
    assert!(matches!(unknown_item, Err(StoreError::NotFound { .. })));
    let unknown_parent = store.move_bookmark(a.id.clone(), Some("999".into()), 0);
    assert!(matches!(unknown_parent, Err(StoreError::NotFound { .. })));
    let bookmark_parent = store.move_bookmark(a.id, Some(b.id), 0);
    assert!(matches!(
        bookmark_parent,
        Err(StoreError::InvalidInput { .. })
    ));
}

#[test]
fn delete_bookmark_removes_a_folder_with_everything_inside() {
    let (_dir, store) = open_store();
    let keep_before = add_bookmark(&store, None, "before", Some("https://before.example/"));
    let folder = add_bookmark(&store, None, "folder", None);
    let nested = add_bookmark(&store, Some(&folder), "nested", None);
    add_bookmark(&store, Some(&nested), "deep", Some("https://deep.example/"));
    add_bookmark(
        &store,
        Some(&folder),
        "shallow",
        Some("https://shallow.example/"),
    );
    add_bookmark(&store, None, "after", Some("https://after.example/"));

    store.delete_bookmark(folder.id.clone()).unwrap();

    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["before", "after"]);
    assert_contiguous(&root);
    assert_eq!(root[0].id, keep_before.id);
    assert!(
        store
            .bookmarks_for_url("https://deep.example/".into())
            .unwrap()
            .is_empty()
    );
    assert!(
        store
            .search_bookmarks("deep".into(), 10)
            .unwrap()
            .is_empty()
    );
    assert!(matches!(
        store.bookmark_children(Some(nested.id)),
        Err(StoreError::NotFound { .. })
    ));
    assert!(matches!(
        store.delete_bookmark(folder.id),
        Err(StoreError::NotFound { .. })
    ));
}

#[test]
fn search_bookmarks_matches_title_and_url_but_not_folders() {
    let (_dir, store) = open_store();
    let folder = add_bookmark(&store, None, "Rust things", None);
    add_bookmark(
        &store,
        Some(&folder),
        "The Rust book",
        Some("https://doc.rust-lang.org/book/"),
    );
    add_bookmark(&store, None, "Cooking", Some("https://food.example/"));

    assert_eq!(
        titles(&store.search_bookmarks("rust".into(), 10).unwrap()),
        ["The Rust book"]
    );
    assert_eq!(
        titles(&store.search_bookmarks("food.exa".into(), 10).unwrap()),
        ["Cooking"]
    );
    assert!(store.search_bookmarks("".into(), 10).unwrap().is_empty());
}

#[test]
fn import_bookmarks_creates_a_folder_and_counts_only_bookmarks() {
    let (_dir, store) = open_store();
    add_bookmark(&store, None, "existing", Some("https://existing.example/"));

    let imported = store
        .import_bookmarks(
            "Imported from Chrome".into(),
            vec![
                import_item(1, None, "Bar", None),
                import_item(2, Some(1), "Nested", None),
                import_item(3, Some(2), "Deep", Some("https://deep.example/")),
                import_item(4, Some(1), "Shallow", Some("https://shallow.example/")),
                import_item(5, None, "Top level", Some("https://top.example/")),
            ],
        )
        .unwrap();
    assert_eq!(imported, 3);

    let root = store.bookmark_children(None).unwrap();
    assert_eq!(titles(&root), ["existing", "Imported from Chrome"]);
    let import_folder = root[1].id.clone();
    let top = store.bookmark_children(Some(import_folder)).unwrap();
    assert_eq!(titles(&top), ["Bar", "Top level"]);
    assert_contiguous(&top);
    let bar = store.bookmark_children(Some(top[0].id.clone())).unwrap();
    assert_eq!(titles(&bar), ["Nested", "Shallow"]);
    assert_contiguous(&bar);
    let deep = store.bookmark_children(Some(bar[0].id.clone())).unwrap();
    assert_eq!(titles(&deep), ["Deep"]);
}

#[test]
fn import_bookmarks_keeps_given_creation_times() {
    let (_dir, store) = open_store();
    let mut item = import_item(1, None, "Dated", Some("https://dated.example/"));
    item.created_ms = Some(1234);
    store.import_bookmarks("Import".into(), vec![item]).unwrap();

    let found = store
        .bookmarks_for_url("https://dated.example/".into())
        .unwrap();
    assert_eq!(found[0].created_ms, 1234);
}

#[test]
fn import_bookmarks_rolls_back_on_bad_input() {
    let (_dir, store) = open_store();
    let orphan = store.import_bookmarks(
        "Import".into(),
        vec![
            import_item(2, Some(1), "child first", Some("https://a.example/")),
            import_item(1, None, "parent", None),
        ],
    );
    assert!(matches!(orphan, Err(StoreError::InvalidInput { .. })));

    let under_bookmark = store.import_bookmarks(
        "Import".into(),
        vec![
            import_item(1, None, "leaf", Some("https://a.example/")),
            import_item(2, Some(1), "child", Some("https://b.example/")),
        ],
    );
    assert!(matches!(
        under_bookmark,
        Err(StoreError::InvalidInput { .. })
    ));

    let duplicate = store.import_bookmarks(
        "Import".into(),
        vec![
            import_item(1, None, "one", None),
            import_item(1, None, "again", None),
        ],
    );
    assert!(matches!(duplicate, Err(StoreError::InvalidInput { .. })));

    assert!(store.bookmark_children(None).unwrap().is_empty());
}

// ---- Site settings ----

#[test]
fn unknown_hosts_get_default_settings() {
    let (_dir, store) = open_store();
    let settings = store.site_settings("example.com".into()).unwrap();
    assert_eq!(settings, default_site_settings("example.com".into()));
    assert!(store.customized_sites().unwrap().is_empty());
}

#[test]
fn saved_settings_round_trip() {
    let (_dir, store) = open_store();
    let custom = SiteSettings {
        host: "example.com".into(),
        shields_enabled: false,
        javascript_enabled: false,
        popups: PermissionState::Allow,
        camera: PermissionState::Deny,
        microphone: PermissionState::Allow,
        location: PermissionState::Deny,
        zoom: 1.25,
        lockdown_mode: true,
    };
    store.save_site_settings(custom.clone()).unwrap();
    assert_eq!(store.site_settings("example.com".into()).unwrap(), custom);
    // www. is a different site.
    assert_eq!(
        store.site_settings("www.example.com".into()).unwrap(),
        default_site_settings("www.example.com".into())
    );

    let changed = SiteSettings {
        zoom: 0.8,
        ..custom
    };
    store.save_site_settings(changed.clone()).unwrap();
    assert_eq!(store.customized_sites().unwrap(), [changed]);
}

#[test]
fn saving_default_settings_removes_the_row() {
    let (_dir, store) = open_store();
    let host = "example.com".to_string();
    store
        .save_site_settings(SiteSettings {
            zoom: 2.0,
            ..default_site_settings(host.clone())
        })
        .unwrap();
    assert_eq!(store.customized_sites().unwrap().len(), 1);

    store
        .save_site_settings(default_site_settings(host))
        .unwrap();
    assert!(store.customized_sites().unwrap().is_empty());
}

#[test]
fn customized_sites_are_sorted_by_host_and_reset_removes_one() {
    let (_dir, store) = open_store();
    for host in ["zed.com", "alpha.com", "mid.com"] {
        store
            .save_site_settings(SiteSettings {
                lockdown_mode: true,
                ..default_site_settings(host.into())
            })
            .unwrap();
    }
    let hosts = |store: &Store| -> Vec<String> {
        store
            .customized_sites()
            .unwrap()
            .into_iter()
            .map(|s| s.host)
            .collect()
    };
    assert_eq!(hosts(&store), ["alpha.com", "mid.com", "zed.com"]);

    store.reset_site_settings("mid.com".into()).unwrap();
    assert_eq!(hosts(&store), ["alpha.com", "zed.com"]);
}

#[test]
fn save_site_settings_rejects_bad_values() {
    let (_dir, store) = open_store();
    for zoom in [0.0, -1.0, f64::NAN, f64::INFINITY] {
        let result = store.save_site_settings(SiteSettings {
            zoom,
            ..default_site_settings("example.com".into())
        });
        assert!(
            matches!(result, Err(StoreError::InvalidInput { .. })),
            "zoom {zoom}"
        );
    }
    let no_host = store.save_site_settings(default_site_settings(String::new()));
    assert!(matches!(no_host, Err(StoreError::InvalidInput { .. })));
}

// ---- Privacy stats ----

#[test]
fn blocked_counts_add_up_within_a_day() {
    let (_dir, store) = open_store();
    let day_start = 19_000 * DAY;
    store
        .record_blocked("ads.example".into(), 3, day_start + 10)
        .unwrap();
    store
        .record_blocked("ads.example".into(), 2, day_start + DAY - 1)
        .unwrap();
    store
        .record_blocked("track.example".into(), 1, day_start)
        .unwrap();

    let stats = store.privacy_stats(day_start, 10).unwrap();
    assert_eq!(stats.blocked_total, 6);
    assert_eq!(stats.since_ms, day_start);
    assert_eq!(
        stats.top_trackers,
        [
            TrackerCount {
                host: "ads.example".into(),
                count: 5
            },
            TrackerCount {
                host: "track.example".into(),
                count: 1
            },
        ]
    );
}

#[test]
fn privacy_stats_since_uses_whole_utc_days() {
    let (_dir, store) = open_store();
    let day = 19_000 * DAY;
    store
        .record_blocked("a.example".into(), 1, day - 1)
        .unwrap();
    store.record_blocked("a.example".into(), 10, day).unwrap();
    store
        .record_blocked("a.example".into(), 100, day + DAY)
        .unwrap();

    assert_eq!(
        store
            .privacy_stats(day + DAY / 2, 10)
            .unwrap()
            .blocked_total,
        110
    );
    assert_eq!(
        store.privacy_stats(day + DAY, 10).unwrap().blocked_total,
        100
    );
    assert_eq!(
        store.privacy_stats(day - DAY, 10).unwrap().blocked_total,
        111
    );
    assert_eq!(
        store
            .privacy_stats(day + 2 * DAY, 10)
            .unwrap()
            .blocked_total,
        0
    );
}

#[test]
fn privacy_stats_limit_top_trackers_and_break_ties_by_host() {
    let (_dir, store) = open_store();
    store.record_blocked("b.example".into(), 2, NOW).unwrap();
    store.record_blocked("a.example".into(), 2, NOW).unwrap();
    store.record_blocked("c.example".into(), 9, NOW).unwrap();

    let stats = store.privacy_stats(0, 2).unwrap();
    assert_eq!(stats.blocked_total, 13);
    let hosts: Vec<&str> = stats.top_trackers.iter().map(|t| t.host.as_str()).collect();
    assert_eq!(hosts, ["c.example", "a.example"]);
}

#[test]
fn negative_timestamps_fall_into_the_previous_day() {
    let (_dir, store) = open_store();
    store.record_blocked("a.example".into(), 4, -1).unwrap();
    assert_eq!(store.privacy_stats(-DAY, 10).unwrap().blocked_total, 4);
    assert_eq!(store.privacy_stats(0, 10).unwrap().blocked_total, 0);
}

#[test]
fn clear_privacy_stats_empties_the_buckets() {
    let (_dir, store) = open_store();
    store.record_blocked("a.example".into(), 4, NOW).unwrap();
    store.clear_privacy_stats().unwrap();

    let stats = store.privacy_stats(0, 10).unwrap();
    assert_eq!(stats.blocked_total, 0);
    assert!(stats.top_trackers.is_empty());
}
