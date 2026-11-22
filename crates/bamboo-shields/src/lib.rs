//! Shields: ad, tracker and annoyance blocking built on Brave's `adblock` crate.
//!
//! Network blocking runs inside WebKit: enabled filter lists are converted to
//! WebKit content-rule-list JSON, which the app compiles with
//! `WKContentRuleListStore`. The in-process engine holds only cosmetic filters
//! and handles what WebKit cannot: per-site cosmetic filtering and scriptlet
//! injection.
//!
//! The app downloads list text itself (URLSession) and hands it over with
//! [`Shields::update_list`]; this crate does no networking.

use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, RwLock};

use adblock::Engine;
use adblock::content_blocking::{CbRule, CbType};
use adblock::lists::{FilterSet, ParseOptions, RuleTypes, parse_filters};
use adblock::resources::Resource;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ShieldsError {
    #[error("io error: {message}")]
    Io { message: String },
    #[error("invalid filter list: {message}")]
    InvalidList { message: String },
    #[error("unknown filter list: {id}")]
    UnknownList { id: String },
    #[error("engine error: {message}")]
    Engine { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum ListCategory {
    Ads,
    Privacy,
    Annoyances,
    CookieNotices,
    Security,
    Regional,
    Custom,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct FilterListInfo {
    pub id: String,
    pub title: String,
    pub url: String,
    pub category: ListCategory,
    pub enabled: bool,
    /// Ships with Bamboo (cannot be removed, only disabled).
    pub builtin: bool,
    pub last_updated_ms: Option<i64>,
    pub rule_count: u32,
}

/// One WebKit content rule list. `identifier` is stable for identical content
/// (it embeds the build fingerprint), so the app can skip recompiling.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ContentRuleSet {
    pub identifier: String,
    pub json: String,
}

/// Output of [`Shields::rebuild`]. Rule sets are split so each stays under
/// WebKit's per-list rule limit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Record)]
pub struct ShieldsBuild {
    pub fingerprint: String,
    pub rule_sets: Vec<ContentRuleSet>,
    pub network_rules: u32,
    pub cosmetic_rules: u32,
    /// Filters that could not be expressed as WebKit rules.
    pub unconvertible_rules: u32,
}

/// Per-page cosmetic resources, fetched by the app before each main-frame
/// navigation and injected as a user script at document start.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CosmeticResources {
    /// CSS selectors to hide on this page.
    pub hide_selectors: Vec<String>,
    /// JavaScript (scriptlets) to run at document start; empty when none apply.
    pub injected_script: String,
    /// When true, generic hide rules must not be applied on this page.
    pub generichide: bool,
    /// Selectors excepted on this page; pass back to [`Shields::hidden_selectors`].
    pub exceptions: Vec<String>,
}

const CATALOG_JSON: &str = include_str!("../catalog.json");
const RESOURCES_URL: &str =
    "https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json";

/// Bump when what a build contains changes without the lists changing, so
/// installs holding an older engine.dat rebuild it. 2: engine is cosmetic-only.
const BUILD_FORMAT: &str = "2";

const CATALOG_FILE: &str = "catalog.json";
const CUSTOM_RULES_FILE: &str = "custom-rules.txt";
const RESOURCES_FILE: &str = "resources.json";
const BUILD_FILE: &str = "build.json";
const ENGINE_FILE: &str = "engine.dat";
const LISTS_DIR: &str = "lists";

/// WebKit rejects a content rule list with more than 150,000 rules (and
/// rejected more than 50,000 before Safari 15). Staying at the older limit keeps
/// every chunk valid on any macOS Bamboo supports, and chunks this size still
/// compile in a few seconds each.
const MAX_RULES_PER_SET: usize = 50_000;

impl From<std::io::Error> for ShieldsError {
    fn from(error: std::io::Error) -> Self {
        Self::Io {
            message: error.to_string(),
        }
    }
}

impl From<serde_json::Error> for ShieldsError {
    fn from(error: serde_json::Error) -> Self {
        Self::Engine {
            message: error.to_string(),
        }
    }
}

#[derive(Deserialize)]
struct BuiltinList {
    id: String,
    title: String,
    url: String,
    category: ListCategory,
    default_enabled: bool,
}

/// Persisted catalog state: every list's flags and counts, plus when the
/// resources were last downloaded.
#[derive(Serialize, Deserialize, Default)]
struct Catalog {
    lists: Vec<FilterListInfo>,
    resources_updated_ms: Option<i64>,
}

impl Catalog {
    /// Built-in lists come from the shipped catalog (so titles and URLs follow
    /// app updates) with their saved state laid over them; custom lists are
    /// kept as saved.
    fn load(dir: &Path) -> Result<Self, ShieldsError> {
        let saved: Catalog = match optional(fs::read(dir.join(CATALOG_FILE)))? {
            Some(bytes) => serde_json::from_slice(&bytes)?,
            None => Catalog::default(),
        };
        let builtin: Vec<BuiltinList> = serde_json::from_str(CATALOG_JSON)?;
        let mut lists: Vec<FilterListInfo> = builtin
            .into_iter()
            .map(|list| {
                let state = saved.lists.iter().find(|saved| saved.id == list.id);
                FilterListInfo {
                    enabled: state.map_or(list.default_enabled, |saved| saved.enabled),
                    last_updated_ms: state.and_then(|saved| saved.last_updated_ms),
                    rule_count: state.map_or(0, |saved| saved.rule_count),
                    id: list.id,
                    title: list.title,
                    url: list.url,
                    category: list.category,
                    builtin: true,
                }
            })
            .collect();
        lists.extend(saved.lists.into_iter().filter(|list| !list.builtin));
        Ok(Self {
            lists,
            resources_updated_ms: saved.resources_updated_ms,
        })
    }

    fn save(&self, dir: &Path) -> Result<(), ShieldsError> {
        write_atomic(&dir.join(CATALOG_FILE), serde_json::to_vec(self)?)
    }

    fn list_mut(&mut self, id: &str) -> Result<&mut FilterListInfo, ShieldsError> {
        self.lists
            .iter_mut()
            .find(|list| list.id == id)
            .ok_or_else(|| ShieldsError::UnknownList { id: id.into() })
    }
}

#[derive(uniffi::Object)]
pub struct Shields {
    dir: PathBuf,
    catalog: Mutex<Catalog>,
    custom_rules: Mutex<String>,
    /// Swapped whole by [`Shields::rebuild`]; readers clone the `Arc` and query
    /// outside the lock, so a rebuild never blocks them for longer than the swap.
    engine: RwLock<Arc<Engine>>,
    /// Serializes rebuilds so two never write the build files at once.
    rebuild_lock: Mutex<()>,
}

#[uniffi::export]
impl Shields {
    /// Opens the shields state in `state_dir` (list catalog, downloaded list
    /// text, last build). On first run, list text is seeded from
    /// `bundled_lists_dir` when given: the app bundle ships `<list id>.txt` for
    /// each built-in list plus `resources.json`, fetched at release time.
    #[uniffi::constructor]
    pub fn open(
        state_dir: String,
        bundled_lists_dir: Option<String>,
    ) -> Result<Arc<Self>, ShieldsError> {
        let dir = PathBuf::from(state_dir);
        fs::create_dir_all(dir.join(LISTS_DIR))?;
        let mut catalog = Catalog::load(&dir)?;
        if let Some(bundled) = bundled_lists_dir {
            seed_from_bundle(&dir, Path::new(&bundled), &mut catalog)?;
        }
        let custom_rules =
            optional(fs::read_to_string(dir.join(CUSTOM_RULES_FILE)))?.unwrap_or_default();
        let shields = Arc::new(Self {
            dir,
            catalog: Mutex::new(catalog),
            custom_rules: Mutex::new(custom_rules),
            engine: RwLock::new(Arc::new(Engine::default())),
            rebuild_lock: Mutex::new(()),
        });
        if shields.current_build()?.is_some() {
            match shields.load_cached_engine()? {
                Some(engine) => {
                    *shields.engine.write().expect("engine lock poisoned") = Arc::new(engine)
                }
                None => {
                    shields.rebuild_if(true)?;
                }
            }
        }
        Ok(shields)
    }

    /// The full catalog: built-in lists first, then custom lists.
    pub fn lists(&self) -> Vec<FilterListInfo> {
        self.catalog().lists.clone()
    }

    pub fn set_list_enabled(&self, id: String, enabled: bool) -> Result<(), ShieldsError> {
        let mut catalog = self.catalog();
        catalog.list_mut(&id)?.enabled = enabled;
        catalog.save(&self.dir)
    }

    /// Adds a subscription by URL. It has no rules until its text is downloaded.
    pub fn add_custom_list(
        &self,
        title: String,
        url: String,
    ) -> Result<FilterListInfo, ShieldsError> {
        let scheme_ok = ["http://", "https://"].iter().any(|scheme| {
            url.len() > scheme.len() && url[..scheme.len()].eq_ignore_ascii_case(scheme)
        });
        if !scheme_ok || url.contains(char::is_whitespace) {
            return Err(ShieldsError::InvalidList {
                message: format!("not an http(s) URL: {url}"),
            });
        }
        let id = format!("custom-{}", &hex(&Sha256::digest(&url))[..12]);
        let mut catalog = self.catalog();
        if catalog.lists.iter().any(|list| list.id == id) {
            return Err(ShieldsError::InvalidList {
                message: format!("already subscribed: {url}"),
            });
        }
        let list = FilterListInfo {
            id,
            title,
            url,
            category: ListCategory::Custom,
            enabled: true,
            builtin: false,
            last_updated_ms: None,
            rule_count: 0,
        };
        catalog.lists.push(list.clone());
        catalog.save(&self.dir)?;
        Ok(list)
    }

    pub fn remove_custom_list(&self, id: String) -> Result<(), ShieldsError> {
        let mut catalog = self.catalog();
        if catalog.list_mut(&id)?.builtin {
            return Err(ShieldsError::InvalidList {
                message: format!("built-in list cannot be removed: {id}"),
            });
        }
        catalog.lists.retain(|list| list.id != id);
        catalog.save(&self.dir)?;
        match fs::remove_file(list_path(&self.dir, &id)) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        }
    }

    /// User-written filter rules (Adblock Plus / uBlock Origin syntax).
    pub fn custom_rules(&self) -> String {
        self.custom_rules
            .lock()
            .expect("custom rules lock poisoned")
            .clone()
    }

    pub fn set_custom_rules(&self, rules: String) -> Result<(), ShieldsError> {
        let mut current = self
            .custom_rules
            .lock()
            .expect("custom rules lock poisoned");
        write_atomic(&self.dir.join(CUSTOM_RULES_FILE), &rules)?;
        *current = rules;
        Ok(())
    }

    /// Enabled lists never downloaded or last updated more than `max_age_ms` before `now_ms`.
    pub fn stale_lists(&self, max_age_ms: i64, now_ms: i64) -> Vec<FilterListInfo> {
        self.catalog()
            .lists
            .iter()
            .filter(|list| list.enabled && is_stale(list.last_updated_ms, max_age_ms, now_ms))
            .cloned()
            .collect()
    }

    /// Stores freshly downloaded list text. Rejects text with no parseable
    /// filters (an HTML error page, for example). Returns the rule count.
    /// Call [`Shields::rebuild`] afterwards to apply it.
    pub fn update_list(&self, id: String, text: String, now_ms: i64) -> Result<u32, ShieldsError> {
        // Parsing is slow; do it before taking the lock the UI reads under.
        let rule_count = count_filters(&id, &text)?;
        let mut catalog = self.catalog();
        let list = catalog.list_mut(&id)?;
        write_atomic(&list_path(&self.dir, &id), &text)?;
        list.last_updated_ms = Some(now_ms);
        list.rule_count = rule_count;
        catalog.save(&self.dir)?;
        Ok(rule_count)
    }

    /// Where to download scriptlet and redirect resources (Brave's adblock-resources JSON).
    pub fn resources_url(&self) -> String {
        RESOURCES_URL.into()
    }

    /// Resources were never downloaded or are older than `max_age_ms`.
    pub fn resources_stale(&self, max_age_ms: i64, now_ms: i64) -> bool {
        is_stale(self.catalog().resources_updated_ms, max_age_ms, now_ms)
    }

    /// Stores downloaded resources JSON (rejecting anything that doesn't parse).
    /// Takes effect at the next [`Shields::rebuild`]. Returns the resource count.
    pub fn update_resources(&self, json: String, now_ms: i64) -> Result<u32, ShieldsError> {
        let resources = parse_resources(&json)?;
        let mut catalog = self.catalog();
        write_atomic(&self.dir.join(RESOURCES_FILE), &json)?;
        catalog.resources_updated_ms = Some(now_ms);
        catalog.save(&self.dir)?;
        Ok(resources.len() as u32)
    }

    /// Rebuilds the engine and content rule sets from enabled lists and custom
    /// rules, persists them, and returns the new build. Slow (seconds); call it
    /// off the main thread.
    pub fn rebuild(&self) -> Result<ShieldsBuild, ShieldsError> {
        self.rebuild_if(false)
    }

    /// The last persisted build without recompiling, or `None` before the first build.
    pub fn current_build(&self) -> Result<Option<ShieldsBuild>, ShieldsError> {
        match optional(fs::read(self.dir.join(BUILD_FILE)))? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn cosmetic_resources(&self, page_url: String) -> CosmeticResources {
        let resources = self.engine().url_cosmetic_resources(&page_url);
        // `procedural_actions` (`:has-text()`, `:style()` and similar) need an
        // in-page JS interpreter that the app's cosmetic script doesn't have.
        CosmeticResources {
            hide_selectors: sorted(resources.hide_selectors),
            injected_script: resources.injected_script,
            generichide: resources.generichide,
            exceptions: sorted(resources.exceptions),
        }
    }

    /// Generic hide selectors matching the classes and ids found in the page DOM.
    pub fn hidden_selectors(
        &self,
        classes: Vec<String>,
        ids: Vec<String>,
        exceptions: Vec<String>,
    ) -> Vec<String> {
        let exceptions: HashSet<String> = exceptions.into_iter().collect();
        self.engine()
            .hidden_class_id_selectors(classes, ids, &exceptions)
    }
}

impl Shields {
    fn catalog(&self) -> MutexGuard<'_, Catalog> {
        self.catalog.lock().expect("catalog lock poisoned")
    }

    fn engine(&self) -> Arc<Engine> {
        Arc::clone(&self.engine.read().expect("engine lock poisoned"))
    }

    /// With `force` false, returns the persisted build when the inputs are
    /// unchanged instead of recompiling.
    fn rebuild_if(&self, force: bool) -> Result<ShieldsBuild, ShieldsError> {
        let _rebuilding = self.rebuild_lock.lock().expect("rebuild lock poisoned");

        let enabled_ids: Vec<String> = self
            .catalog()
            .lists
            .iter()
            .filter(|list| list.enabled)
            .map(|list| list.id.clone())
            .collect();
        let mut lists = Vec::new();
        for id in enabled_ids {
            // An enabled list that was never downloaded has no rules yet.
            if let Some(text) = optional(fs::read_to_string(list_path(&self.dir, &id)))? {
                lists.push((id, text));
            }
        }
        let custom_rules = self.custom_rules();
        let resources_json = optional(fs::read_to_string(self.dir.join(RESOURCES_FILE)))?;

        let fingerprint = fingerprint(&lists, &custom_rules, resources_json.as_deref());
        if !force
            && let Some(build) = self.current_build()?
            && build.fingerprint == fingerprint
        {
            return Ok(build);
        }

        let texts: Vec<&str> = lists
            .iter()
            .map(|(_, text)| text.as_str())
            .chain(Some(custom_rules.as_str()).filter(|rules| !rules.is_empty()))
            .collect();
        let conversion = convert_to_content_rules(&texts)?;
        let rule_sets = split_rule_sets(&conversion.rules, MAX_RULES_PER_SET)?
            .into_iter()
            .enumerate()
            .map(|(n, json)| ContentRuleSet {
                identifier: format!("bamboo-shields-{fingerprint}-{n}"),
                json,
            })
            .collect();
        let build = ShieldsBuild {
            fingerprint,
            rule_sets,
            network_rules: conversion.network_rules,
            cosmetic_rules: conversion.cosmetic_rules,
            unconvertible_rules: conversion.unconvertible_rules,
        };

        // WebKit does all network blocking, so network filters would only cost memory here.
        let cosmetic_only = ParseOptions {
            rule_types: RuleTypes::CosmeticOnly,
            ..ParseOptions::default()
        };
        let mut filter_set = FilterSet::new(false);
        for text in texts {
            filter_set.add_filter_list(text.into(), cosmetic_only);
            // `@@...$generichide` is a network filter, but it is what turns generic hiding off for a site.
            let generichide_exceptions: String = text
                .lines()
                .filter(|line| is_generichide_exception(line))
                .flat_map(|line| [line, "\n"])
                .collect();
            if !generichide_exceptions.is_empty() {
                filter_set.add_filter_list(generichide_exceptions, ParseOptions::default());
            }
        }
        let mut engine = Engine::new_with_filter_set(filter_set);
        if let Some(json) = &resources_json {
            engine.use_resources(parse_resources(json)?);
        }

        // build.json is written last: it is the marker that engine.dat is complete.
        write_atomic(&self.dir.join(ENGINE_FILE), engine.serialize())?;
        write_atomic(&self.dir.join(BUILD_FILE), serde_json::to_vec(&build)?)?;
        *self.engine.write().expect("engine lock poisoned") = Arc::new(engine);
        Ok(build)
    }

    /// Loads the engine saved by the last build, skipping list parsing. `None`
    /// when the file is missing or unreadable (a format change after an
    /// upgrade, for example); it is only a cache, so the caller rebuilds.
    fn load_cached_engine(&self) -> Result<Option<Engine>, ShieldsError> {
        let Some(bytes) = optional(fs::read(self.dir.join(ENGINE_FILE)))? else {
            return Ok(None);
        };
        let mut engine = Engine::default();
        if engine.deserialize(&bytes).is_err() {
            return Ok(None);
        }
        if let Some(json) = optional(fs::read_to_string(self.dir.join(RESOURCES_FILE)))? {
            engine.use_resources(parse_resources(&json)?);
        }
        Ok(Some(engine))
    }
}

struct Conversion {
    rules: Vec<CbRule>,
    network_rules: u32,
    cosmetic_rules: u32,
    unconvertible_rules: u32,
}

/// Network filters become WebKit rules; cosmetic filters do not. Like Brave,
/// the generic ones (`##.ad`) stay out of WebKit: each would be one
/// `css-display-none` rule matching every URL, which is tens of thousands of
/// rules WebKit must compile and evaluate on every load. Instead the engine
/// matches the page's actual classes and ids at runtime
/// ([`Shields::hidden_selectors`]) and returns only the selectors that apply.
/// Host-specific cosmetic and scriptlet filters need the engine anyway
/// ([`Shields::cosmetic_resources`]), so no cosmetic filter is converted.
fn convert_to_content_rules(texts: &[&str]) -> Result<Conversion, ShieldsError> {
    let network_only = ParseOptions {
        rule_types: RuleTypes::NetworkOnly,
        ..ParseOptions::default()
    };
    // Debug mode is required for the content-blocking conversion.
    let mut filter_set = FilterSet::new(true);
    let (mut network_filters, mut cosmetic_rules) = (0, 0);
    for text in texts {
        filter_set.add_filter_list((*text).into(), network_only);
        let (network, cosmetic) = parse_filters(text.lines(), false, ParseOptions::default());
        network_filters += network.len();
        cosmetic_rules += cosmetic.len();
    }
    let (rules, converted) =
        filter_set
            .into_content_blocking()
            .map_err(|()| ShieldsError::Engine {
                message: "content blocking conversion unavailable".into(),
            })?;
    Ok(Conversion {
        rules,
        network_rules: converted.len() as u32,
        cosmetic_rules: cosmetic_rules as u32,
        unconvertible_rules: (network_filters - converted.len()) as u32,
    })
}

/// Splits rules into JSON arrays of at most `limit` rules. `ignore-previous-rules`
/// (the `@@` exceptions) only affect earlier rules in the same list, so every
/// chunk carries all of them after its blocking rules.
fn split_rule_sets(rules: &[CbRule], limit: usize) -> Result<Vec<String>, ShieldsError> {
    let (exceptions, blocking): (Vec<&CbRule>, Vec<&CbRule>) = rules
        .iter()
        .partition(|rule| matches!(rule.action.typ, CbType::IgnorePreviousRules));
    let Some(blocking_per_set) = limit.checked_sub(exceptions.len()).filter(|room| *room > 0)
    else {
        return Err(ShieldsError::Engine {
            message: format!(
                "{} exception rules leave no room under the {limit}-rule limit",
                exceptions.len()
            ),
        });
    };
    blocking
        .chunks(blocking_per_set)
        .map(|chunk| {
            let set: Vec<&CbRule> = chunk.iter().chain(&exceptions).copied().collect();
            Ok(serde_json::to_string(&set)?)
        })
        .collect()
}

fn fingerprint(lists: &[(String, String)], custom_rules: &str, resources: Option<&str>) -> String {
    let mut hasher = Sha256::new();
    // Length prefixes keep ("ab", "c") and ("a", "bc") from hashing alike.
    let mut add = |part: &str| {
        hasher.update(part.len().to_le_bytes());
        hasher.update(part);
    };
    add(env!("CARGO_PKG_VERSION"));
    add(BUILD_FORMAT);
    for (id, text) in lists {
        add(id);
        add(text);
    }
    add(custom_rules);
    add(resources.unwrap_or_default());
    hex(&hasher.finalize())[..16].to_string()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn sorted(set: HashSet<String>) -> Vec<String> {
    let mut values: Vec<String> = set.into_iter().collect();
    values.sort();
    values
}

/// Matches on the option list after the last `$`, not on the whole line, so a
/// URL pattern that merely contains "ghide" doesn't qualify.
fn is_generichide_exception(line: &str) -> bool {
    line.starts_with("@@")
        && line.rsplit_once('$').is_some_and(|(_, options)| {
            options.split(',').any(|option| {
                option.eq_ignore_ascii_case("generichide") || option.eq_ignore_ascii_case("ghide")
            })
        })
}

fn is_stale(last_updated_ms: Option<i64>, max_age_ms: i64, now_ms: i64) -> bool {
    last_updated_ms.is_none_or(|updated| now_ms - updated > max_age_ms)
}

/// Counts the filters in `text`, rejecting text with none.
fn count_filters(id: &str, text: &str) -> Result<u32, ShieldsError> {
    // The parser accepts HTML tags as literal URL patterns, so an error page
    // would otherwise count as a list of filters.
    if text.trim_start().starts_with('<') {
        return Err(ShieldsError::InvalidList {
            message: format!("{id} is HTML, not a filter list"),
        });
    }
    let (network, cosmetic) = parse_filters(text.lines(), false, ParseOptions::default());
    match network.len() + cosmetic.len() {
        0 => Err(ShieldsError::InvalidList {
            message: format!("no filters found in {id}"),
        }),
        count => Ok(count as u32),
    }
}

fn parse_resources(json: &str) -> Result<Vec<Resource>, ShieldsError> {
    serde_json::from_str(json).map_err(|error| ShieldsError::InvalidList {
        message: format!("invalid resources: {error}"),
    })
}

fn list_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(LISTS_DIR).join(format!("{id}.txt"))
}

/// Copies bundled list text and resources into the state directory where none
/// is stored yet. `last_updated_ms` stays `None` so the app refreshes them soon.
fn seed_from_bundle(dir: &Path, bundled: &Path, catalog: &mut Catalog) -> Result<(), ShieldsError> {
    for list in catalog.lists.iter_mut().filter(|list| list.builtin) {
        let stored = list_path(dir, &list.id);
        if stored.exists() {
            continue;
        }
        let bundled_text = bundled.join(format!("{}.txt", list.id));
        if let Some(text) = optional(fs::read_to_string(&bundled_text))? {
            list.rule_count = count_filters(&list.id, &text)?;
            write_atomic(&stored, &text)?;
        }
    }
    let stored = dir.join(RESOURCES_FILE);
    if !stored.exists()
        && let Some(json) = optional(fs::read_to_string(bundled.join(RESOURCES_FILE)))?
    {
        parse_resources(&json)?;
        write_atomic(&stored, &json)?;
    }
    catalog.save(dir)
}

/// A missing file is `None`; any other failure is an error.
fn optional<T>(read: std::io::Result<T>) -> Result<Option<T>, ShieldsError> {
    match read {
        Ok(contents) => Ok(Some(contents)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

/// Writes to a temp file and renames it over `path`, so a reader or a crash
/// never sees a half-written file.
fn write_atomic(path: &Path, contents: impl AsRef<[u8]>) -> Result<(), ShieldsError> {
    let temp = path.with_extension("tmp");
    let mut file = fs::File::create(&temp)?;
    file.write_all(contents.as_ref())?;
    file.sync_all()?;
    fs::rename(&temp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests;
