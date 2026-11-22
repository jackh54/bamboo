//! Chromium-family browsers: Brave, Chrome, Edge, Arc, Vivaldi, Opera and
//! Chromium itself. They share one on-disk format.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use rusqlite::OptionalExtension;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::Url;

use crate::{
    BrowserKind, CookieSameSite, ImportBundle, ImportError, ImportKind, ImportRequest,
    ImportSession, ImportedBookmark, ImportedCookie, ImportedExtension, ImportedHistory,
    ImportedLogin, ImportedSearchEngine, SourceProfile,
    common::{
        chromium_time_ms, exists, io_error, push_bookmark, read, read_database, read_optional,
    },
    crypto::{self, Key},
};

/// Cookies databases from this `meta` version on prefix the plaintext with
/// SHA-256 of the host key.
const HOST_HASH_VERSION: i64 = 24;
const HOST_HASH_LEN: usize = 32;
/// `Manifest::Location` values of extensions the browser ships itself.
const LOCATION_COMPONENT: u32 = 5;
const LOCATION_EXTERNAL_COMPONENT: u32 = 10;

struct Browser {
    kind: BrowserKind,
    name: &'static str,
    /// Under `~/Library/Application Support`.
    root: &'static str,
    /// Keychain account; the service is "<account> Safe Storage".
    keychain_account: &'static str,
}

// Roots and Keychain names come from each browser's Chromium build
// configuration (`user_data_dir` and the os_crypt keychain name) and from
// tools that read these profiles (yt-dlp, browser_cookie3, pycookiecheat).
// The Brave, Chrome and Edge channels share one Keychain entry per vendor.
// They could not be checked against installed copies of every browser here.
const BROWSERS: [Browser; 11] = [
    Browser {
        kind: BrowserKind::Brave,
        name: "Brave",
        root: "BraveSoftware/Brave-Browser",
        keychain_account: "Brave",
    },
    Browser {
        kind: BrowserKind::BraveBeta,
        name: "Brave Beta",
        root: "BraveSoftware/Brave-Browser-Beta",
        keychain_account: "Brave",
    },
    Browser {
        kind: BrowserKind::BraveNightly,
        name: "Brave Nightly",
        root: "BraveSoftware/Brave-Browser-Nightly",
        keychain_account: "Brave",
    },
    Browser {
        kind: BrowserKind::Chrome,
        name: "Google Chrome",
        root: "Google/Chrome",
        keychain_account: "Chrome",
    },
    Browser {
        kind: BrowserKind::ChromeBeta,
        name: "Google Chrome Beta",
        root: "Google/Chrome Beta",
        keychain_account: "Chrome",
    },
    Browser {
        kind: BrowserKind::ChromeCanary,
        name: "Google Chrome Canary",
        root: "Google/Chrome Canary",
        keychain_account: "Chrome",
    },
    Browser {
        kind: BrowserKind::Chromium,
        name: "Chromium",
        root: "Chromium",
        keychain_account: "Chromium",
    },
    Browser {
        kind: BrowserKind::Edge,
        name: "Microsoft Edge",
        root: "Microsoft Edge",
        keychain_account: "Microsoft Edge",
    },
    Browser {
        kind: BrowserKind::Arc,
        name: "Arc",
        root: "Arc/User Data",
        keychain_account: "Arc",
    },
    Browser {
        kind: BrowserKind::Vivaldi,
        name: "Vivaldi",
        root: "Vivaldi",
        keychain_account: "Vivaldi",
    },
    // Opera keeps its single profile directly in the root.
    Browser {
        kind: BrowserKind::Opera,
        name: "Opera",
        root: "com.operasoftware.Opera",
        keychain_account: "Opera",
    },
];

#[derive(Deserialize, Default)]
struct LocalState {
    #[serde(default)]
    profile: LocalStateProfile,
}

#[derive(Deserialize, Default)]
struct LocalStateProfile {
    #[serde(default)]
    info_cache: BTreeMap<String, ProfileInfo>,
}

#[derive(Deserialize)]
struct ProfileInfo {
    name: Option<String>,
}

#[derive(Deserialize, Default)]
struct Preferences {
    #[serde(default)]
    extensions: ExtensionPreferences,
    #[serde(default)]
    default_search_provider_data: DefaultSearchPreferences,
}

#[derive(Deserialize, Default)]
struct ExtensionPreferences {
    #[serde(default)]
    settings: BTreeMap<String, ExtensionSettings>,
}

#[derive(Deserialize, Default)]
struct DefaultSearchPreferences {
    template_url_data: Option<TemplateUrlData>,
}

#[derive(Deserialize)]
struct TemplateUrlData {
    keyword: Option<String>,
}

#[derive(Deserialize)]
struct ExtensionSettings {
    #[serde(default)]
    location: u32,
    state: Option<u32>,
    /// A bit mask in current versions.
    disable_reasons: Option<serde_json::Value>,
    /// Relative to `<profile>/Extensions`, absolute for unpacked extensions.
    path: Option<String>,
    #[serde(default)]
    was_installed_by_default: bool,
    #[serde(default)]
    was_installed_by_oem: bool,
}

#[derive(Deserialize)]
struct Manifest {
    name: String,
    version: String,
    manifest_version: u32,
    default_locale: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    message: String,
}

#[derive(Deserialize)]
struct BookmarksFile {
    roots: BookmarkRoots,
}

#[derive(Deserialize)]
struct BookmarkRoots {
    bookmark_bar: Option<BookmarkNode>,
    other: Option<BookmarkNode>,
    synced: Option<BookmarkNode>,
}

#[derive(Deserialize)]
struct BookmarkNode {
    #[serde(default)]
    name: String,
    #[serde(rename = "type", default)]
    kind: String,
    url: Option<String>,
    /// Chromium time as a decimal string.
    date_added: Option<String>,
    #[serde(default)]
    children: Vec<BookmarkNode>,
}

pub(crate) fn discover(home: &Path) -> Vec<SourceProfile> {
    let support = home.join("Library/Application Support");
    BROWSERS
        .iter()
        .flat_map(|browser| {
            let root = support.join(browser.root);
            profiles(browser, &root).unwrap_or_else(|e| {
                vec![SourceProfile {
                    browser: browser.kind,
                    browser_name: browser.name.to_string(),
                    profile_name: browser.name.to_string(),
                    profile_dir: root.display().to_string(),
                    kinds: vec![],
                    access_error: Some(e.to_string()),
                }]
            })
        })
        .collect()
}

/// Empty when the browser is not installed.
fn profiles(browser: &Browser, root: &Path) -> Result<Vec<SourceProfile>, ImportError> {
    if !exists(root)? {
        return Ok(vec![]);
    }
    let mut found = Vec::new();
    if let Some(local_state) = read_optional(&root.join("Local State"))? {
        let local_state: LocalState = serde_json::from_slice(&local_state)?;
        for (dir_name, info) in local_state.profile.info_cache {
            let dir = root.join(&dir_name);
            if exists(&dir)? {
                found.push((dir, info.name.unwrap_or(dir_name)));
            }
        }
    }
    if found.is_empty() {
        let mut dir_names = Vec::new();
        for entry in std::fs::read_dir(root).map_err(|e| io_error(root, &e))? {
            let entry = entry.map_err(|e| io_error(root, &e))?;
            let dir_name = entry.file_name().to_string_lossy().into_owned();
            if (dir_name == "Default" || dir_name.starts_with("Profile "))
                && exists(&entry.path().join("Preferences"))?
            {
                dir_names.push(dir_name);
            }
        }
        dir_names.sort();
        found.extend(dir_names.into_iter().map(|name| (root.join(&name), name)));
    }
    if found.is_empty() && exists(&root.join("Preferences"))? {
        found.push((root.to_path_buf(), "Default".to_string()));
    }
    found
        .into_iter()
        .map(|(dir, profile_name)| {
            Ok(SourceProfile {
                browser: browser.kind,
                browser_name: browser.name.to_string(),
                profile_name,
                kinds: kinds(&dir)?,
                profile_dir: dir.display().to_string(),
                access_error: None,
            })
        })
        .collect()
}

fn kinds(dir: &Path) -> Result<Vec<ImportKind>, ImportError> {
    let present = [
        (ImportKind::Bookmarks, exists(&dir.join("Bookmarks"))?),
        (ImportKind::History, exists(&dir.join("History"))?),
        (ImportKind::Cookies, cookies_file(dir)?.is_some()),
        (ImportKind::Passwords, exists(&dir.join("Login Data"))?),
        (ImportKind::SearchEngines, exists(&dir.join("Web Data"))?),
        (ImportKind::Extensions, exists(&dir.join("Extensions"))?),
    ];
    Ok(present
        .into_iter()
        .filter_map(|(kind, found)| found.then_some(kind))
        .collect())
}

/// Newer versions keep the cookie database in `Network/`.
fn cookies_file(dir: &Path) -> Result<Option<PathBuf>, ImportError> {
    for candidate in [dir.join("Network/Cookies"), dir.join("Cookies")] {
        if exists(&candidate)? {
            return Ok(Some(candidate));
        }
    }
    Ok(None)
}

pub(crate) fn import(
    profile: &SourceProfile,
    request: &ImportRequest,
    bundle: &mut ImportBundle,
    session: &ImportSession,
) -> Result<(), ImportError> {
    let browser = BROWSERS
        .iter()
        .find(|browser| browser.kind == profile.browser)
        .ok_or_else(|| ImportError::Parse {
            message: format!("{} is not a Chromium browser", profile.browser_name),
        })?;
    let dir = Path::new(&profile.profile_dir);
    let wants = |kind| request.kinds.contains(&kind);

    if wants(ImportKind::Bookmarks) {
        bundle.bookmarks = bookmarks(dir)?;
    }
    if wants(ImportKind::History) {
        bundle.history = history(dir, request.history_since_ms)?;
    }
    if wants(ImportKind::Cookies) || wants(ImportKind::Passwords) {
        let key = session.key(browser.kind, || {
            keychain_password(
                &format!("{} Safe Storage", browser.keychain_account),
                browser.keychain_account,
            )
        })?;
        if wants(ImportKind::Cookies) {
            bundle.cookies = cookies(dir, &key, &mut bundle.warnings)?;
        }
        if wants(ImportKind::Passwords) {
            bundle.logins = logins(dir, &key, &mut bundle.warnings)?;
        }
    }
    if wants(ImportKind::SearchEngines) {
        bundle.search_engines = search_engines(dir, &mut bundle.warnings)?;
    }
    if wants(ImportKind::Extensions) {
        bundle.extensions = extensions(dir, &mut bundle.warnings)?;
    }
    Ok(())
}

/// The Keychain password is the PBKDF2 input for the browser's value key.
/// Reading it makes macOS ask the user; a refusal or cancel is an error.
fn keychain_password(service: &str, account: &str) -> Result<Vec<u8>, ImportError> {
    security_framework::passwords::get_generic_password(service, account).map_err(|e| {
        ImportError::Keychain {
            message: format!("could not read \"{service}\" from the Keychain: {e}"),
        }
    })
}

fn bookmarks(dir: &Path) -> Result<Vec<ImportedBookmark>, ImportError> {
    let file: BookmarksFile = serde_json::from_slice(&read(&dir.join("Bookmarks"))?)?;
    let mut bookmarks = Vec::new();
    for (root, title) in [
        (file.roots.bookmark_bar, "Bookmarks Bar"),
        (file.roots.other, "Other Bookmarks"),
        (file.roots.synced, "Mobile Bookmarks"),
    ] {
        let Some(root) = root.filter(|root| !root.children.is_empty()) else {
            continue;
        };
        let local_id = push_bookmark(&mut bookmarks, None, title.to_string(), None, None);
        push_children(&mut bookmarks, local_id, root.children)?;
    }
    Ok(bookmarks)
}

fn push_children(
    bookmarks: &mut Vec<ImportedBookmark>,
    parent: u32,
    children: Vec<BookmarkNode>,
) -> Result<(), ImportError> {
    for node in children {
        let created_ms = match &node.date_added {
            Some(date) => chromium_time_ms(date.parse().map_err(|_| ImportError::Parse {
                message: format!("bookmark date_added \"{date}\" is not a number"),
            })?),
            None => None,
        };
        if node.kind == "url" {
            push_bookmark(bookmarks, Some(parent), node.name, node.url, created_ms);
        } else {
            let local_id = push_bookmark(bookmarks, Some(parent), node.name, None, created_ms);
            push_children(bookmarks, local_id, node.children)?;
        }
    }
    Ok(())
}

fn history(dir: &Path, since_ms: Option<i64>) -> Result<Vec<ImportedHistory>, ImportError> {
    read_database(&dir.join("History"), |db| {
        let mut statement = db.prepare(
            "SELECT url, title, visit_count, last_visit_time FROM urls \
             WHERE hidden = 0 ORDER BY last_visit_time DESC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u32>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        let mut history = Vec::new();
        for row in rows {
            let (url, title, visit_count, last_visit_time) = row?;
            let Some(last_visit_ms) = chromium_time_ms(last_visit_time) else {
                continue;
            };
            let is_web = url.starts_with("http://") || url.starts_with("https://");
            if !is_web || since_ms.is_some_and(|since| last_visit_ms < since) {
                continue;
            }
            history.push(ImportedHistory {
                url,
                title: (!title.is_empty()).then_some(title),
                last_visit_ms,
                visit_count,
            });
        }
        Ok(history)
    })
}

fn cookies(
    dir: &Path,
    key: &Key,
    warnings: &mut Vec<String>,
) -> Result<Vec<ImportedCookie>, ImportError> {
    let path = cookies_file(dir)?.ok_or_else(|| ImportError::NotFound {
        path: dir.join("Network/Cookies").display().to_string(),
    })?;
    let (cookies, undecryptable) = read_database(&path, |db| {
        let version: i64 = db.query_row(
            "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'version'",
            [],
            |row| row.get(0),
        )?;
        let mut statement = db.prepare(
            "SELECT host_key, name, value, encrypted_value, path, expires_utc, \
             is_secure, is_httponly, samesite, has_expires FROM cookies",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, bool>(6)?,
                row.get::<_, bool>(7)?,
                row.get::<_, i64>(8)?,
                row.get::<_, bool>(9)?,
            ))
        })?;
        let mut cookies = Vec::new();
        let mut undecryptable = 0;
        for row in rows {
            let (
                domain,
                name,
                plain_value,
                encrypted_value,
                path,
                expires_utc,
                secure,
                http_only,
                same_site,
                has_expires,
            ) = row?;
            let value = if encrypted_value.is_empty() {
                plain_value
            } else {
                match decrypt_cookie(key, version, &domain, &encrypted_value) {
                    Ok(value) => value,
                    Err(_) => {
                        undecryptable += 1;
                        continue;
                    }
                }
            };
            cookies.push(ImportedCookie {
                name,
                value,
                domain,
                path,
                expires_ms: if has_expires {
                    chromium_time_ms(expires_utc)
                } else {
                    None
                },
                secure,
                http_only,
                same_site: match same_site {
                    0 => CookieSameSite::NoRestriction,
                    1 => CookieSameSite::Lax,
                    2 => CookieSameSite::Strict,
                    _ => CookieSameSite::Unspecified,
                },
            });
        }
        Ok((cookies, undecryptable))
    })?;
    if undecryptable > 0 {
        warnings.push(format!("{undecryptable} cookies could not be decrypted"));
    }
    Ok(cookies)
}

fn decrypt_cookie(
    key: &Key,
    version: i64,
    host_key: &str,
    encrypted_value: &[u8],
) -> Result<String, ImportError> {
    let plaintext = crypto::decrypt(key, encrypted_value)?;
    let value = if version >= HOST_HASH_VERSION {
        let (hash, value) =
            plaintext
                .split_at_checked(HOST_HASH_LEN)
                .ok_or_else(|| ImportError::Decryption {
                    message: "cookie is shorter than its host hash".to_string(),
                })?;
        if hash != Sha256::digest(host_key.as_bytes()).as_slice() {
            return Err(ImportError::Decryption {
                message: "cookie host hash does not match its host".to_string(),
            });
        }
        value.to_vec()
    } else {
        plaintext
    };
    String::from_utf8(value).map_err(|e| ImportError::Decryption {
        message: e.to_string(),
    })
}

fn logins(
    dir: &Path,
    key: &Key,
    warnings: &mut Vec<String>,
) -> Result<Vec<ImportedLogin>, ImportError> {
    let (logins, undecryptable, not_web) = read_database(&dir.join("Login Data"), |db| {
        let mut statement = db.prepare(
            "SELECT origin_url, username_value, password_value, date_created FROM logins \
             WHERE blacklisted_by_user = 0 AND length(password_value) > 0",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })?;
        let mut logins = Vec::new();
        let (mut undecryptable, mut not_web) = (0, 0);
        for row in rows {
            let (origin_url, username, encrypted_password, date_created) = row?;
            let origin = match Url::parse(&origin_url) {
                Ok(url) if matches!(url.scheme(), "http" | "https") => {
                    url.origin().ascii_serialization()
                }
                _ => {
                    not_web += 1;
                    continue;
                }
            };
            let password = match crypto::decrypt(key, &encrypted_password).and_then(|bytes| {
                String::from_utf8(bytes).map_err(|e| ImportError::Decryption {
                    message: e.to_string(),
                })
            }) {
                Ok(password) => password,
                Err(_) => {
                    undecryptable += 1;
                    continue;
                }
            };
            if password.is_empty() {
                continue;
            }
            logins.push(ImportedLogin {
                origin,
                username,
                password,
                created_ms: chromium_time_ms(date_created),
            });
        }
        Ok((logins, undecryptable, not_web))
    })?;
    if undecryptable > 0 {
        warnings.push(format!("{undecryptable} passwords could not be decrypted"));
    }
    if not_web > 0 {
        warnings.push(format!(
            "{not_web} passwords skipped because they are not for web sites"
        ));
    }
    Ok(logins)
}

/// The default engine is the keyword in `Preferences`
/// (`default_search_provider_data`). Profiles without it fall back to the
/// `Default Search Provider ID` row in `Web Data`'s `meta` table.
fn search_engines(
    dir: &Path,
    warnings: &mut Vec<String>,
) -> Result<Vec<ImportedSearchEngine>, ImportError> {
    let default_keyword = read_preferences(dir, "Preferences")?
        .default_search_provider_data
        .template_url_data
        .and_then(|data| data.keyword);
    let (engines, skipped) = read_database(&dir.join("Web Data"), |db| {
        let default_id: Option<i64> = if default_keyword.is_none() {
            db.query_row(
                "SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'Default Search Provider ID'",
                [],
                |row| row.get(0),
            )
            .optional()?
        } else {
            None
        };
        let mut statement = db.prepare(
            "SELECT id, short_name, keyword, url FROM keywords \
             WHERE url LIKE '%{searchTerms}%' ORDER BY id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })?;
        let mut engines = Vec::new();
        let mut skipped = 0;
        for row in rows {
            let (id, name, keyword, url_template) = row?;
            // "{google:baseURL}" and friends only mean something inside Chromium.
            if url_template.contains("{google:") {
                skipped += 1;
                continue;
            }
            engines.push(ImportedSearchEngine {
                is_default: default_keyword.as_deref() == Some(keyword.as_str())
                    || default_id == Some(id),
                name,
                keyword,
                url_template,
            });
        }
        Ok((engines, skipped))
    })?;
    if skipped > 0 {
        warnings.push(format!(
            "{skipped} search engines skipped because their address depends on Google settings"
        ));
    }
    Ok(engines)
}

fn read_preferences(dir: &Path, file: &str) -> Result<Preferences, ImportError> {
    match read_optional(&dir.join(file))? {
        Some(bytes) => Ok(serde_json::from_slice(&bytes)?),
        None => Ok(Preferences::default()),
    }
}

/// Extensions come from `extensions.settings` in `Secure Preferences` and
/// `Preferences`. Component extensions (location 5 and 10) and ones the
/// browser or an OEM installed by default are skipped. The directory is
/// the settings' `path` (`<id>/<version>_<n>` under `Extensions`) rather than
/// `<id>/<version>`, because Chromium appends a counter to the folder name.
/// Name, version and manifest version come from `manifest.json` in it.
fn extensions(
    dir: &Path,
    warnings: &mut Vec<String>,
) -> Result<Vec<ImportedExtension>, ImportError> {
    let mut settings = read_preferences(dir, "Secure Preferences")?
        .extensions
        .settings;
    for (id, setting) in read_preferences(dir, "Preferences")?.extensions.settings {
        settings.entry(id).or_insert(setting);
    }
    let mut extensions = Vec::new();
    let mut missing = 0;
    for (id, setting) in settings {
        if matches!(
            setting.location,
            LOCATION_COMPONENT | LOCATION_EXTERNAL_COMPONENT
        ) || setting.was_installed_by_default
            || setting.was_installed_by_oem
        {
            continue;
        }
        let Some(path) = setting.path else {
            missing += 1;
            continue;
        };
        let extension_dir = dir.join("Extensions").join(path);
        let Some(manifest) = read_optional(&extension_dir.join("manifest.json"))? else {
            missing += 1;
            continue;
        };
        let manifest: Manifest = serde_json::from_slice(&manifest)?;
        let name = match manifest
            .name
            .strip_prefix("__MSG_")
            .and_then(|key| key.strip_suffix("__"))
        {
            Some(key) => match localized_message(&extension_dir, &manifest, key)? {
                Some(name) => name,
                None => {
                    warnings.push(format!("extension {id} has an untranslatable name"));
                    id.clone()
                }
            },
            None => manifest.name,
        };
        extensions.push(ImportedExtension {
            id,
            name,
            version: manifest.version,
            directory: extension_dir.display().to_string(),
            manifest_version: manifest.manifest_version,
            enabled: setting.state != Some(0)
                && match setting.disable_reasons {
                    None => true,
                    Some(serde_json::Value::Number(reasons)) => reasons.as_i64() == Some(0),
                    Some(serde_json::Value::Array(reasons)) => reasons.is_empty(),
                    Some(_) => false,
                },
        });
    }
    if missing > 0 {
        warnings.push(format!(
            "{missing} extensions skipped because their files are missing"
        ));
    }
    Ok(extensions)
}

/// Looks `key` up in `_locales/<default_locale>/messages.json`; message names
/// are case-insensitive.
fn localized_message(
    extension_dir: &Path,
    manifest: &Manifest,
    key: &str,
) -> Result<Option<String>, ImportError> {
    let Some(locale) = &manifest.default_locale else {
        return Ok(None);
    };
    let path = extension_dir
        .join("_locales")
        .join(locale)
        .join("messages.json");
    let Some(messages) = read_optional(&path)? else {
        return Ok(None);
    };
    let messages: BTreeMap<String, Message> = serde_json::from_slice(&messages)?;
    Ok(messages
        .into_iter()
        .find(|(name, _)| name.eq_ignore_ascii_case(key))
        .map(|(_, message)| message.message))
}

#[cfg(test)]
mod tests {
    use rusqlite::{Connection, params};
    use tempfile::TempDir;

    use super::*;
    use crate::tests::{JAN_2024_MS, chromium_us, database};

    const PASSWORD: &[u8] = b"known keychain password";

    fn host_hash(host_key: &str) -> Vec<u8> {
        Sha256::digest(host_key.as_bytes()).to_vec()
    }

    fn encrypted_cookie(key: &Key, host_key: &str, value: &str) -> Vec<u8> {
        let mut plaintext = host_hash(host_key);
        plaintext.extend(value.as_bytes());
        crypto::encrypt(key, &plaintext)
    }

    fn cookies_database(dir: &TempDir, meta_version: u32) -> Connection {
        database(
            &dir.path().join("Network/Cookies"),
            &format!(
                "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
                 INSERT INTO meta VALUES ('version', '{meta_version}');
                 CREATE TABLE cookies(host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
                    encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
                    is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
                    samesite INTEGER NOT NULL, has_expires INTEGER NOT NULL);"
            ),
        )
    }

    fn insert_cookie(
        db: &Connection,
        host_key: &str,
        name: &str,
        plain: &str,
        encrypted: &[u8],
        expires_utc: i64,
        samesite: i64,
    ) {
        db.execute(
            "INSERT INTO cookies VALUES (?1, ?2, ?3, ?4, '/', ?5, 1, 1, ?6, ?7)",
            params![
                host_key,
                name,
                plain,
                encrypted,
                expires_utc,
                samesite,
                expires_utc != 0
            ],
        )
        .unwrap();
    }

    #[test]
    fn decrypts_cookies_and_strips_the_host_hash() {
        let key = crypto::derive_key(PASSWORD);
        let dir = TempDir::new().unwrap();
        let db = cookies_database(&dir, 24);
        let expires = chromium_us(JAN_2024_MS);
        let enc = |host: &str, value: &str| encrypted_cookie(&key, host, value);
        insert_cookie(
            &db,
            ".example.com",
            "sid",
            "",
            &enc(".example.com", "secret"),
            0,
            1,
        );
        insert_cookie(
            &db,
            "app.example.com",
            "theme",
            "",
            &enc("app.example.com", "dark"),
            expires,
            -1,
        );
        insert_cookie(
            &db,
            "a.example.com",
            "open",
            "",
            &enc("a.example.com", "x"),
            expires,
            0,
        );
        insert_cookie(
            &db,
            "b.example.com",
            "strict",
            "",
            &enc("b.example.com", "y"),
            expires,
            2,
        );
        insert_cookie(&db, "c.example.com", "plain", "visible", &[], expires, -1);
        let mut warnings = Vec::new();

        let cookies = cookies(dir.path(), &key, &mut warnings).unwrap();

        assert!(warnings.is_empty(), "{warnings:?}");
        let cookie = |name: &str| cookies.iter().find(|c| c.name == name).unwrap();
        assert_eq!(cookie("sid").value, "secret");
        assert_eq!(cookie("sid").domain, ".example.com");
        assert_eq!(cookie("sid").path, "/");
        assert_eq!(cookie("sid").expires_ms, None);
        assert_eq!(cookie("sid").same_site, CookieSameSite::Lax);
        assert!(cookie("sid").secure && cookie("sid").http_only);
        assert_eq!(cookie("theme").value, "dark");
        assert_eq!(cookie("theme").expires_ms, Some(JAN_2024_MS));
        assert_eq!(cookie("theme").same_site, CookieSameSite::Unspecified);
        assert_eq!(cookie("open").same_site, CookieSameSite::NoRestriction);
        assert_eq!(cookie("strict").same_site, CookieSameSite::Strict);
        assert_eq!(cookie("plain").value, "visible");
        assert_eq!(cookies.len(), 5);
    }

    #[test]
    fn counts_cookies_that_fail_to_decrypt() {
        let key = crypto::derive_key(PASSWORD);
        let dir = TempDir::new().unwrap();
        let db = cookies_database(&dir, 24);
        insert_cookie(
            &db,
            "ok.example.com",
            "ok",
            "",
            &encrypted_cookie(&key, "ok.example.com", "fine"),
            0,
            -1,
        );
        let wrong_key = crypto::derive_key(b"another password");
        insert_cookie(
            &db,
            "wk.example.com",
            "wrong_key",
            "",
            &encrypted_cookie(&wrong_key, "wk.example.com", "v"),
            0,
            -1,
        );
        insert_cookie(
            &db,
            "h.example.com",
            "wrong_host",
            "",
            &encrypted_cookie(&key, "other.example.com", "v"),
            0,
            -1,
        );
        insert_cookie(&db, "p.example.com", "not_v10", "", b"plain bytes", 0, -1);
        insert_cookie(
            &db,
            "s.example.com",
            "short",
            "",
            &crypto::encrypt(&key, b"tiny"),
            0,
            -1,
        );
        let mut warnings = Vec::new();

        let cookies = cookies(dir.path(), &key, &mut warnings).unwrap();

        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].name, "ok");
        assert_eq!(warnings, ["4 cookies could not be decrypted"]);
    }

    #[test]
    fn cookies_before_version_24_have_no_host_hash() {
        let key = crypto::derive_key(PASSWORD);
        let dir = TempDir::new().unwrap();
        let db = cookies_database(&dir, 23);
        insert_cookie(
            &db,
            ".example.com",
            "old",
            "",
            &crypto::encrypt(&key, b"legacy"),
            0,
            -1,
        );
        let mut warnings = Vec::new();

        let cookies = cookies(dir.path(), &key, &mut warnings).unwrap();

        assert_eq!(cookies[0].value, "legacy");
        assert!(warnings.is_empty());
    }

    #[test]
    fn decrypts_logins_and_skips_unusable_rows() {
        let key = crypto::derive_key(PASSWORD);
        let dir = TempDir::new().unwrap();
        let db = database(
            &dir.path().join("Login Data"),
            "CREATE TABLE logins(origin_url VARCHAR NOT NULL, username_value VARCHAR,
                password_value BLOB, date_created INTEGER NOT NULL,
                blacklisted_by_user INTEGER NOT NULL);",
        );
        let created = chromium_us(JAN_2024_MS);
        let enc = |password: &str| crypto::encrypt(&key, password.as_bytes());
        let wrong_key_password = crypto::encrypt(&crypto::derive_key(b"another"), b"nope");
        let rows: [(&str, &str, Vec<u8>, i64, i64); 7] = [
            (
                "https://accounts.example.com/login?next=1",
                "alice",
                enc("hunter2"),
                created,
                0,
            ),
            ("http://localhost:8080/app", "bob", enc("pw2"), 0, 0),
            ("https://never.example/", "", enc("x"), created, 1),
            ("https://empty.example/", "dave", vec![], created, 0),
            (
                "android://hash@com.example/",
                "carol",
                enc("pw3"),
                created,
                0,
            ),
            (
                "https://broken.example/",
                "erin",
                wrong_key_password,
                created,
                0,
            ),
            ("https://blank.example/", "frank", enc(""), created, 0),
        ];
        for (origin, username, password, date_created, blacklisted) in rows {
            db.execute(
                "INSERT INTO logins VALUES (?1, ?2, ?3, ?4, ?5)",
                params![origin, username, password, date_created, blacklisted],
            )
            .unwrap();
        }
        let mut warnings = Vec::new();

        let logins = logins(dir.path(), &key, &mut warnings).unwrap();

        assert_eq!(
            logins,
            [
                ImportedLogin {
                    origin: "https://accounts.example.com".into(),
                    username: "alice".into(),
                    password: "hunter2".into(),
                    created_ms: Some(JAN_2024_MS),
                },
                ImportedLogin {
                    origin: "http://localhost:8080".into(),
                    username: "bob".into(),
                    password: "pw2".into(),
                    created_ms: None,
                },
            ]
        );
        assert_eq!(
            warnings,
            [
                "1 passwords could not be decrypted",
                "1 passwords skipped because they are not for web sites"
            ]
        );
    }

    #[test]
    fn keychain_lookup_of_a_missing_item_is_a_keychain_error() {
        let result = keychain_password("Bamboo Import Test Safe Storage", "Bamboo Import Test");
        assert!(matches!(result, Err(ImportError::Keychain { .. })));
    }
}
