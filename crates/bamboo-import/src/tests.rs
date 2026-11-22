//! Fixture profiles built in temporary directories. Nothing here touches the
//! real browsers or the Keychain.

use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

use rusqlite::{Connection, params};
use tempfile::TempDir;

use crate::*;

/// 2024-01-01T00:00:00Z.
pub(crate) const JAN_2024_MS: i64 = 1_704_067_200_000;
/// 2023-06-01T00:00:00Z.
const JUN_2023_MS: i64 = 1_685_577_600_000;
/// 2024-06-01T00:00:00Z.
const JUN_2024_MS: i64 = 1_717_200_000_000;

pub(crate) fn chromium_us(unix_ms: i64) -> i64 {
    (unix_ms + 11_644_473_600_000) * 1000
}

pub(crate) fn write(path: &Path, contents: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

pub(crate) fn database(path: &Path, schema: &str) -> Connection {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch(schema).unwrap();
    db
}

fn support(home: &TempDir) -> PathBuf {
    home.path().join("Library/Application Support")
}

fn discover(home: &TempDir) -> Vec<SourceProfile> {
    discover_profiles(home.path().display().to_string())
}

fn request(kinds: &[ImportKind], history_since_ms: Option<i64>) -> ImportRequest {
    ImportRequest {
        kinds: kinds.to_vec(),
        history_since_ms,
    }
}

fn import_kinds(
    profile: &SourceProfile,
    kinds: &[ImportKind],
    history_since_ms: Option<i64>,
) -> Result<ImportBundle, ImportError> {
    ImportSession::default().import_profile(profile.clone(), request(kinds, history_since_ms))
}

fn profile_named<'a>(profiles: &'a [SourceProfile], name: &str) -> &'a SourceProfile {
    profiles
        .iter()
        .find(|profile| profile.profile_name == name)
        .unwrap()
}

fn brave_home() -> TempDir {
    let home = TempDir::new().unwrap();
    let root = support(&home).join("BraveSoftware/Brave-Browser");
    write(
        &root.join("Local State"),
        r#"{"profile":{"info_cache":{
            "Default":{"name":"Personal"},
            "Profile 1":{"name":"Work"},
            "Profile 9":{"name":"Deleted"}}}}"#,
    );
    let default = root.join("Default");
    write(&default.join("Preferences"), "{}");
    write(&default.join("Bookmarks"), "{}");
    write(&default.join("History"), "");
    write(&default.join("Network/Cookies"), "");
    write(&default.join("Login Data"), "");
    write(&default.join("Web Data"), "");
    fs::create_dir_all(default.join("Extensions")).unwrap();
    write(&root.join("Profile 1/Preferences"), "{}");
    home
}

#[test]
fn discovers_chromium_profiles_from_local_state() {
    let home = brave_home();
    let profiles = discover(&home);
    assert_eq!(profiles.len(), 2, "{profiles:?}");

    let personal = profile_named(&profiles, "Personal");
    assert_eq!(personal.browser, BrowserKind::Brave);
    assert_eq!(personal.browser_name, "Brave");
    assert!(personal.profile_dir.ends_with("Brave-Browser/Default"));
    assert_eq!(
        personal.kinds,
        [
            ImportKind::Bookmarks,
            ImportKind::History,
            ImportKind::Cookies,
            ImportKind::Passwords,
            ImportKind::SearchEngines,
            ImportKind::Extensions,
        ]
    );
    assert_eq!(personal.access_error, None);

    let work = profile_named(&profiles, "Work");
    assert!(work.kinds.is_empty());
}

#[test]
fn discovers_profiles_by_scanning_when_local_state_is_missing() {
    let home = TempDir::new().unwrap();
    let root = support(&home).join("Google/Chrome");
    write(&root.join("Default/Preferences"), "{}");
    write(&root.join("Default/Cookies"), "");
    write(&root.join("Profile 2/Preferences"), "{}");
    write(&root.join("Profile 2/Network/Cookies"), "");
    write(&root.join("System Profile/Preferences"), "{}");
    write(&root.join("Crashpad/settings.dat"), "");

    let profiles = discover(&home);
    let names: Vec<_> = profiles.iter().map(|p| p.profile_name.as_str()).collect();
    assert_eq!(names, ["Default", "Profile 2"]);
    assert!(
        profiles
            .iter()
            .all(|p| p.browser_name == "Google Chrome" && p.kinds == [ImportKind::Cookies])
    );
}

#[test]
fn discovers_opera_profile_stored_in_the_root() {
    let home = TempDir::new().unwrap();
    let root = support(&home).join("com.operasoftware.Opera");
    write(&root.join("Preferences"), "{}");
    write(&root.join("Bookmarks"), "{}");

    let profiles = discover(&home);
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].browser, BrowserKind::Opera);
    assert_eq!(profiles[0].profile_dir, root.display().to_string());
    assert_eq!(profiles[0].kinds, [ImportKind::Bookmarks]);
}

#[test]
fn reports_an_unreadable_browser_root_instead_of_skipping_it() {
    let home = TempDir::new().unwrap();
    let root = support(&home).join("BraveSoftware/Brave-Browser");
    write(&root.join("Local State"), "{}");
    fs::set_permissions(&root, fs::Permissions::from_mode(0o000)).unwrap();
    assert!(
        fs::read_dir(&root).is_err(),
        "test must not run as a user that bypasses permissions"
    );

    let profiles = discover(&home);
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].browser, BrowserKind::Brave);
    assert!(profiles[0].kinds.is_empty());
    let message = profiles[0].access_error.as_ref().unwrap();
    assert!(message.contains("Full Disk Access"), "{message}");
}

#[test]
fn import_maps_denied_file_access_to_permission_denied() {
    let home = brave_home();
    let profiles = discover(&home);
    let personal = profile_named(&profiles, "Personal");
    let dir = PathBuf::from(&personal.profile_dir);
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o000)).unwrap();

    let result = import_kinds(personal, &[ImportKind::Bookmarks], None);
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();

    match result {
        Err(ImportError::PermissionDenied { path, message }) => {
            assert!(path.ends_with("Default/Bookmarks"), "{path}");
            assert!(message.contains("Full Disk Access"), "{message}");
        }
        other => panic!("expected PermissionDenied, got {other:?}"),
    }
}

#[test]
fn import_session_reads_each_browser_password_once() {
    let session = ImportSession::default();
    let mut reads = Vec::new();
    for browser in [BrowserKind::Brave, BrowserKind::Brave, BrowserKind::Chrome] {
        session
            .key(browser, || {
                reads.push(browser);
                Ok(format!("{browser:?} password").into_bytes())
            })
            .unwrap();
    }
    assert_eq!(reads, [BrowserKind::Brave, BrowserKind::Chrome]);
    assert_ne!(
        session.key(BrowserKind::Brave, || unreachable!()).unwrap(),
        session.key(BrowserKind::Chrome, || unreachable!()).unwrap()
    );
}

#[test]
fn import_session_asks_again_after_a_refused_keychain_read() {
    let session = ImportSession::default();
    let refused = session.key(BrowserKind::Brave, || {
        Err(ImportError::Keychain {
            message: "denied".into(),
        })
    });
    assert!(matches!(refused, Err(ImportError::Keychain { .. })));
    let mut asked_again = false;
    session
        .key(BrowserKind::Brave, || {
            asked_again = true;
            Ok(b"password".to_vec())
        })
        .unwrap();
    assert!(asked_again);
}

#[test]
fn imports_chromium_bookmarks_parent_before_child() {
    let home = brave_home();
    let profile = profile_named(&discover(&home), "Personal").clone();
    write(
        &Path::new(&profile.profile_dir).join("Bookmarks"),
        r#"{"roots":{
            "bookmark_bar":{"name":"Bookmarks bar","type":"folder","children":[
                {"name":"Rust","type":"url","url":"https://rust-lang.org/","date_added":"13348540800000000"},
                {"name":"Dev","type":"folder","date_added":"13348540800000000","children":[
                    {"name":"MDN","type":"url","url":"https://developer.mozilla.org/","date_added":"0"}]}]},
            "other":{"name":"Other bookmarks","type":"folder","children":[]},
            "synced":{"name":"Mobile bookmarks","type":"folder","children":[
                {"name":"Phone","type":"url","url":"https://example.com/","date_added":"13348540800000000"}]}}}"#,
    );

    let bundle = import_kinds(&profile, &[ImportKind::Bookmarks], None).unwrap();
    let bookmark =
        |local_id, parent_local_id, title: &str, url: Option<&str>, created_ms| ImportedBookmark {
            local_id,
            parent_local_id,
            title: title.to_string(),
            url: url.map(str::to_string),
            created_ms,
        };
    assert_eq!(
        bundle.bookmarks,
        [
            bookmark(0, None, "Bookmarks Bar", None, None),
            bookmark(
                1,
                Some(0),
                "Rust",
                Some("https://rust-lang.org/"),
                Some(JAN_2024_MS)
            ),
            bookmark(2, Some(0), "Dev", None, Some(JAN_2024_MS)),
            bookmark(
                3,
                Some(2),
                "MDN",
                Some("https://developer.mozilla.org/"),
                None
            ),
            bookmark(4, None, "Mobile Bookmarks", None, None),
            bookmark(
                5,
                Some(4),
                "Phone",
                Some("https://example.com/"),
                Some(JAN_2024_MS)
            ),
        ]
    );
    assert!(bundle.history.is_empty() && bundle.cookies.is_empty());
}

#[test]
fn imports_chromium_history_including_unflushed_wal_pages() {
    let home = brave_home();
    let profile = profile_named(&discover(&home), "Personal").clone();
    let history = Path::new(&profile.profile_dir).join("History");
    fs::remove_file(&history).unwrap();
    // Keeping the connection open leaves the rows in the -wal file, like a
    // running browser does.
    let source = database(
        &history,
        "PRAGMA journal_mode = WAL;
         CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
            last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);",
    );
    let rows = [
        ("https://old.example/", "Old", 3, JUN_2023_MS, 0),
        ("https://new.example/page", "New", 5, JUN_2024_MS, 0),
        ("http://untitled.example/", "", 1, JUN_2024_MS - 1000, 0),
        ("https://hidden.example/", "Hidden", 1, JUN_2024_MS, 1),
        ("chrome://settings/", "Settings", 1, JUN_2024_MS, 0),
        ("https://never.example/", "Never", 0, 0, 0),
    ];
    for (url, title, visits, visited_ms, hidden) in rows {
        let visited = if visited_ms == 0 {
            0
        } else {
            chromium_us(visited_ms)
        };
        source
            .execute(
                "INSERT INTO urls(url, title, visit_count, last_visit_time, hidden)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![url, title, visits, visited, hidden],
            )
            .unwrap();
    }
    assert!(Path::new(&format!("{}-wal", history.display())).exists());

    let all = import_kinds(&profile, &[ImportKind::History], None).unwrap();
    assert_eq!(
        all.history,
        [
            ImportedHistory {
                url: "https://new.example/page".into(),
                title: Some("New".into()),
                last_visit_ms: JUN_2024_MS,
                visit_count: 5,
            },
            ImportedHistory {
                url: "http://untitled.example/".into(),
                title: None,
                last_visit_ms: JUN_2024_MS - 1000,
                visit_count: 1,
            },
            ImportedHistory {
                url: "https://old.example/".into(),
                title: Some("Old".into()),
                last_visit_ms: JUN_2023_MS,
                visit_count: 3,
            },
        ]
    );

    let recent = import_kinds(&profile, &[ImportKind::History], Some(JAN_2024_MS)).unwrap();
    let urls: Vec<_> = recent.history.iter().map(|h| h.url.as_str()).collect();
    assert_eq!(
        urls,
        ["https://new.example/page", "http://untitled.example/"]
    );
}

#[test]
fn imports_search_engines_with_the_default_from_preferences() {
    let home = brave_home();
    let profile = profile_named(&discover(&home), "Personal").clone();
    let dir = Path::new(&profile.profile_dir);
    web_data(&dir.join("Web Data"), None);
    write(
        &dir.join("Preferences"),
        r#"{"default_search_provider_data":{"template_url_data":{"keyword":"brave"}}}"#,
    );

    let bundle = import_kinds(&profile, &[ImportKind::SearchEngines], None).unwrap();
    let defaults: Vec<_> = bundle
        .search_engines
        .iter()
        .filter(|engine| engine.is_default)
        .map(|engine| engine.name.as_str())
        .collect();
    assert_eq!(defaults, ["Brave"]);
    let names: Vec<_> = bundle
        .search_engines
        .iter()
        .map(|e| e.name.as_str())
        .collect();
    assert_eq!(names, ["DuckDuckGo", "Brave"]);
    assert_eq!(
        bundle.search_engines[0].url_template,
        "https://duckduckgo.com/?q={searchTerms}"
    );
    assert_eq!(
        bundle.warnings,
        ["1 search engines skipped because their address depends on Google settings"]
    );
}

#[test]
fn search_engine_default_falls_back_to_the_web_data_meta_id() {
    let home = brave_home();
    let profile = profile_named(&discover(&home), "Personal").clone();
    let dir = Path::new(&profile.profile_dir);
    web_data(&dir.join("Web Data"), Some(2));
    write(&dir.join("Preferences"), "{}");

    let bundle = import_kinds(&profile, &[ImportKind::SearchEngines], None).unwrap();
    let defaults: Vec<_> = bundle
        .search_engines
        .iter()
        .filter(|engine| engine.is_default)
        .map(|engine| engine.keyword.as_str())
        .collect();
    assert_eq!(defaults, ["duckduckgo.com"]);
}

fn web_data(path: &Path, default_id: Option<i64>) {
    let db = database(
        path,
        "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
         CREATE TABLE keywords(id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL,
            keyword VARCHAR NOT NULL, url VARCHAR NOT NULL);
         INSERT INTO keywords VALUES
            (1, 'Google', 'google.com', '{google:baseURL}search?q={searchTerms}'),
            (2, 'DuckDuckGo', 'duckduckgo.com', 'https://duckduckgo.com/?q={searchTerms}'),
            (3, 'Brave', 'brave', 'https://search.brave.com/search?q={searchTerms}'),
            (4, 'Extension', 'ext', 'chrome-extension://abc/');",
    );
    if let Some(id) = default_id {
        db.execute(
            "INSERT INTO meta VALUES ('Default Search Provider ID', ?1)",
            [id.to_string()],
        )
        .unwrap();
    }
}

#[test]
fn imports_extensions_and_skips_component_and_default_ones() {
    let home = brave_home();
    let profile = profile_named(&discover(&home), "Personal").clone();
    let dir = Path::new(&profile.profile_dir);
    write(
        &dir.join("Secure Preferences"),
        r#"{"extensions":{"settings":{
            "aaaa":{"location":1,"state":1,"path":"aaaa/1.2.3_0"},
            "bbbb":{"location":5,"path":"bbbb/1.0_0"},
            "cccc":{"location":1,"path":"cccc/1.0_0","was_installed_by_default":true},
            "eeee":{"location":1,"state":1,"path":"eeee/1.0_0"}}}}"#,
    );
    write(
        &dir.join("Preferences"),
        r#"{"extensions":{"settings":{
            "dddd":{"location":1,"state":1,"disable_reasons":1,"path":"dddd/2.0_0"}}}}"#,
    );
    let aaaa = dir.join("Extensions/aaaa/1.2.3_0");
    write(
        &aaaa.join("manifest.json"),
        r#"{"name":"__MSG_extName__","version":"1.2.3","manifest_version":3,"default_locale":"en"}"#,
    );
    write(
        &aaaa.join("_locales/en/messages.json"),
        r#"{"extname":{"message":"Dark Reader"}}"#,
    );
    write(
        &dir.join("Extensions/dddd/2.0_0/manifest.json"),
        r#"{"name":"Plain","version":"2.0","manifest_version":2}"#,
    );

    let bundle = import_kinds(&profile, &[ImportKind::Extensions], None).unwrap();
    assert_eq!(
        bundle.extensions,
        [
            ImportedExtension {
                id: "aaaa".into(),
                name: "Dark Reader".into(),
                version: "1.2.3".into(),
                directory: aaaa.display().to_string(),
                manifest_version: 3,
                enabled: true,
            },
            ImportedExtension {
                id: "dddd".into(),
                name: "Plain".into(),
                version: "2.0".into(),
                directory: dir.join("Extensions/dddd/2.0_0").display().to_string(),
                manifest_version: 2,
                enabled: false,
            },
        ]
    );
    assert_eq!(
        bundle.warnings,
        ["1 extensions skipped because their files are missing"]
    );
}

#[test]
fn warns_about_kinds_a_browser_cannot_provide() {
    let home = TempDir::new().unwrap();
    let firefox = firefox_home(&home);
    let bundle = import_kinds(&firefox, &[ImportKind::Passwords], None).unwrap();
    assert!(bundle.logins.is_empty());
    assert_eq!(
        bundle.warnings,
        ["Passwords cannot be imported from Firefox"]
    );
}

fn firefox_home(home: &TempDir) -> SourceProfile {
    let root = support(home).join("Firefox");
    write(
        &root.join("profiles.ini"),
        "[Install4F96D1932A9F858E]\nDefault=Profiles/abcd.default-release\nLocked=1\n\n\
         [Profile1]\nName=default\nIsRelative=1\nPath=Profiles/efgh.default\n\n\
         [Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abcd.default-release\nDefault=1\n\n\
         [General]\nStartWithLastProfile=1\nVersion=2\n",
    );
    fs::create_dir_all(root.join("Profiles/efgh.default")).unwrap();
    let dir = root.join("Profiles/abcd.default-release");
    let places = database(
        &dir.join("places.sqlite"),
        "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
            hidden INTEGER DEFAULT 0 NOT NULL);
         CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
         CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL,
            parent INTEGER, position INTEGER, title LONGVARCHAR, dateAdded INTEGER, guid TEXT);",
    );
    let (jun_2023, jun_2024) = (JUN_2023_MS * 1000, JUN_2024_MS * 1000);
    places
        .execute_batch(&format!(
            "INSERT INTO moz_places VALUES
                (1, 'https://rust-lang.org/', 'Rust', 0),
                (2, 'https://developer.mozilla.org/', 'MDN', 0),
                (3, 'place:sort=8', 'Recent', 0),
                (4, 'https://hidden.example/', 'Hidden', 1),
                (5, 'ftp://files.example/', 'Files', 0),
                (6, 'https://unvisited.example/', 'Unvisited', 0);
             INSERT INTO moz_historyvisits VALUES
                (1, 1, {jun_2023}), (2, 1, {jun_2024}), (3, 2, {jun_2023}),
                (4, 4, {jun_2024}), (5, 5, {jun_2024});
             INSERT INTO moz_bookmarks VALUES
                (1, 2, NULL, 0, 0, '', 0, 'root________'),
                (2, 2, NULL, 1, 0, 'menu', 0, 'menu________'),
                (3, 2, NULL, 1, 1, 'toolbar', 0, 'toolbar_____'),
                (4, 2, NULL, 1, 2, '', 0, 'tags________'),
                (5, 2, NULL, 1, 3, 'unfiled', 0, 'unfiled_____'),
                (6, 2, NULL, 1, 4, 'mobile', 0, 'mobile______'),
                (7, 1, 1, 3, 0, 'Rust', {jan}, 'aaaaaaaaaaaa'),
                (8, 2, NULL, 3, 1, 'Dev', {jan}, 'bbbbbbbbbbbb'),
                (9, 1, 2, 8, 0, 'MDN', {jan}, 'cccccccccccc'),
                (10, 3, NULL, 3, 2, NULL, {jan}, 'dddddddddddd'),
                (11, 1, 3, 2, 0, 'Recent', {jan}, 'eeeeeeeeeeee'),
                (12, 2, NULL, 4, 0, 'tag', {jan}, 'ffffffffffff');",
            jan = JAN_2024_MS * 1000
        ))
        .unwrap();
    database(
        &dir.join("cookies.sqlite"),
        "CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, name TEXT, value TEXT, host TEXT,
            path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER);
         INSERT INTO moz_cookies VALUES
            (1, 'sid', 'abc', '.example.com', '/', 1735689600, 1, 1, 1),
            (2, 'session', 'def', 'app.example.com', '/app', 0, 0, 0, 0),
            (3, 'strict', 'ghi', 'example.org', '/', 1735689600, 0, 1, 2);",
    );
    discover(home)
        .into_iter()
        .find(|profile| profile.profile_name == "default-release")
        .unwrap()
}

#[test]
fn discovers_firefox_profiles_without_passwords() {
    let home = TempDir::new().unwrap();
    firefox_home(&home);
    let profiles = discover(&home);
    let names: Vec<_> = profiles.iter().map(|p| p.profile_name.as_str()).collect();
    assert_eq!(names, ["default", "default-release"]);
    assert!(profiles.iter().all(|p| p.browser == BrowserKind::Firefox));
    assert!(profiles[0].kinds.is_empty());
    assert_eq!(
        profiles[1].kinds,
        [
            ImportKind::Bookmarks,
            ImportKind::History,
            ImportKind::Cookies
        ]
    );
    assert!(
        profiles
            .iter()
            .all(|p| !p.kinds.contains(&ImportKind::Passwords))
    );
}

#[test]
fn imports_firefox_bookmarks_history_and_cookies() {
    let home = TempDir::new().unwrap();
    let profile = firefox_home(&home);

    let bundle = import_kinds(
        &profile,
        &[ImportKind::Bookmarks, ImportKind::Cookies],
        None,
    )
    .unwrap();
    let outline: Vec<_> = bundle
        .bookmarks
        .iter()
        .map(|b| {
            (
                b.local_id,
                b.parent_local_id,
                b.title.as_str(),
                b.url.as_deref(),
            )
        })
        .collect();
    assert_eq!(
        outline,
        [
            (0, None, "Bookmarks Toolbar", None),
            (1, Some(0), "Rust", Some("https://rust-lang.org/")),
            (2, Some(0), "Dev", None),
            (3, Some(2), "MDN", Some("https://developer.mozilla.org/")),
        ]
    );
    assert_eq!(bundle.bookmarks[1].created_ms, Some(JAN_2024_MS));

    let cookie = |name: &str| bundle.cookies.iter().find(|c| c.name == name).unwrap();
    assert_eq!(cookie("sid").domain, ".example.com");
    assert_eq!(cookie("sid").expires_ms, Some(1_735_689_600_000));
    assert_eq!(cookie("sid").same_site, CookieSameSite::Lax);
    assert!(cookie("sid").secure && cookie("sid").http_only);
    assert_eq!(cookie("session").expires_ms, None);
    assert_eq!(cookie("session").same_site, CookieSameSite::NoRestriction);
    assert_eq!(cookie("strict").same_site, CookieSameSite::Strict);

    let all = import_kinds(&profile, &[ImportKind::History], None).unwrap();
    let urls: Vec<_> = all
        .history
        .iter()
        .map(|h| (h.url.as_str(), h.visit_count))
        .collect();
    assert_eq!(
        urls,
        [
            ("https://rust-lang.org/", 2),
            ("https://developer.mozilla.org/", 1)
        ]
    );
    assert_eq!(all.history[0].last_visit_ms, JUN_2024_MS);

    let recent = import_kinds(&profile, &[ImportKind::History], Some(JAN_2024_MS)).unwrap();
    assert_eq!(recent.history.len(), 1);
    assert_eq!(recent.history[0].url, "https://rust-lang.org/");
}

const SAFARI_BOOKMARKS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
<key>Children</key><array>
 <dict><key>WebBookmarkType</key><string>WebBookmarkTypeProxy</string><key>Title</key><string>History</string></dict>
 <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>BookmarksBar</string>
  <key>Children</key><array>
   <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
    <key>URLString</key><string>https://www.apple.com/</string>
    <key>URIDictionary</key><dict><key>title</key><string>Apple</string></dict></dict>
   <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>Dev</string>
    <key>Children</key><array>
     <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
      <key>URLString</key><string>https://swift.org/</string>
      <key>URIDictionary</key><dict><key>title</key><string>Swift</string></dict></dict>
    </array></dict>
  </array></dict>
 <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>BookmarksMenu</string></dict>
 <dict><key>WebBookmarkType</key><string>WebBookmarkTypeList</string><key>Title</key><string>com.apple.ReadingList</string>
  <key>Children</key><array>
   <dict><key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
    <key>URLString</key><string>https://later.example/</string>
    <key>URIDictionary</key><dict><key>title</key><string>Later</string></dict></dict>
  </array></dict>
</array></dict></plist>"#;

fn safari_home() -> TempDir {
    let home = TempDir::new().unwrap();
    let dir = home.path().join("Library/Safari");
    fs::create_dir_all(&dir).unwrap();
    // Safari writes binary plists.
    write(&dir.join("Bookmarks.xml"), SAFARI_BOOKMARKS);
    plist::Value::from_file(dir.join("Bookmarks.xml"))
        .unwrap()
        .to_file_binary(dir.join("Bookmarks.plist"))
        .unwrap();
    fs::remove_file(dir.join("Bookmarks.xml")).unwrap();
    // Core Data seconds: 2023-06-01 and 2024-06-01.
    database(
        &dir.join("History.db"),
        "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT NOT NULL, visit_count INTEGER);
         CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER NOT NULL,
            visit_time REAL NOT NULL, title TEXT);
         INSERT INTO history_items VALUES
            (1, 'https://www.apple.com/', 2), (2, 'ftp://files.example/', 1),
            (3, 'https://old.example/', 1);
         INSERT INTO history_visits VALUES
            (1, 1, 707270400.0, 'Old Apple'), (2, 1, 738892800.0, 'Apple'),
            (3, 2, 738892800.0, 'Files'), (4, 3, 707270400.0, NULL);",
    );
    home
}

#[test]
fn discovers_safari() {
    let home = safari_home();
    let profiles = discover(&home);
    assert_eq!(profiles.len(), 1);
    assert_eq!(profiles[0].browser, BrowserKind::Safari);
    assert_eq!(
        profiles[0].kinds,
        [ImportKind::Bookmarks, ImportKind::History]
    );
}

#[test]
fn imports_safari_bookmarks_and_history() {
    let home = safari_home();
    let profile = discover(&home).remove(0);

    let bundle = import_kinds(&profile, &[ImportKind::Bookmarks], None).unwrap();
    let outline: Vec<_> = bundle
        .bookmarks
        .iter()
        .map(|b| {
            (
                b.local_id,
                b.parent_local_id,
                b.title.as_str(),
                b.url.as_deref(),
            )
        })
        .collect();
    assert_eq!(
        outline,
        [
            (0, None, "Favorites", None),
            (1, Some(0), "Apple", Some("https://www.apple.com/")),
            (2, Some(0), "Dev", None),
            (3, Some(2), "Swift", Some("https://swift.org/")),
        ]
    );

    let all = import_kinds(&profile, &[ImportKind::History], None).unwrap();
    assert_eq!(
        all.history,
        [
            ImportedHistory {
                url: "https://www.apple.com/".into(),
                title: Some("Apple".into()),
                last_visit_ms: JUN_2024_MS,
                visit_count: 2,
            },
            ImportedHistory {
                url: "https://old.example/".into(),
                title: None,
                last_visit_ms: JUN_2023_MS,
                visit_count: 1,
            },
        ]
    );
    let recent = import_kinds(&profile, &[ImportKind::History], Some(JAN_2024_MS)).unwrap();
    assert_eq!(recent.history.len(), 1);
}
