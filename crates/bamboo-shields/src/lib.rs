//! Shields: ad, tracker and annoyance blocking built on Brave's `adblock` crate.
//!
//! Network blocking runs inside WebKit: enabled filter lists are converted to
//! WebKit content-rule-list JSON, which the app compiles with
//! `WKContentRuleListStore`. The in-process engine handles what WebKit cannot:
//! per-site cosmetic filtering, scriptlet injection, and classifying observed
//! requests for the per-page "trackers blocked" report.
//!
//! The app downloads list text itself (URLSession) and hands it over with
//! [`Shields::update_list`]; this crate does no networking.

use std::sync::Arc;

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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ListCategory {
    Ads,
    Privacy,
    Annoyances,
    CookieNotices,
    Security,
    Regional,
    Custom,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
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
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ContentRuleSet {
    pub identifier: String,
    pub json: String,
}

/// Output of [`Shields::rebuild`]. Rule sets are split so each stays under
/// WebKit's per-list rule limit.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RequestType {
    Document,
    Subdocument,
    Script,
    Stylesheet,
    Image,
    Font,
    Media,
    Xhr,
    Websocket,
    Ping,
    Other,
}

/// A subresource request the page script saw.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ObservedRequest {
    pub url: String,
    pub request_type: RequestType,
}

/// A request the engine would block, with the host it was sent to.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BlockedRequest {
    pub url: String,
    pub host: String,
}

#[derive(uniffi::Object)]
pub struct Shields {
    // STUB(phase1): replaced by the real engine state.
    _state_dir: String,
}

#[uniffi::export]
impl Shields {
    /// Opens the shields state in `state_dir` (list catalog, downloaded list
    /// text, last build). On first run, list text is seeded from
    /// `bundled_lists_dir` when given (lists shipped in the app bundle).
    #[uniffi::constructor]
    pub fn open(
        state_dir: String,
        bundled_lists_dir: Option<String>,
    ) -> Result<Arc<Self>, ShieldsError> {
        let _ = bundled_lists_dir; // STUB(phase1)
        Ok(Arc::new(Self {
            _state_dir: state_dir,
        }))
    }

    /// The full catalog: built-in lists first, then custom lists.
    pub fn lists(&self) -> Vec<FilterListInfo> {
        vec![] // STUB(phase1)
    }

    pub fn set_list_enabled(&self, id: String, enabled: bool) -> Result<(), ShieldsError> {
        let _ = (id, enabled); // STUB(phase1)
        Ok(())
    }

    /// Adds a subscription by URL. It has no rules until its text is downloaded.
    pub fn add_custom_list(
        &self,
        title: String,
        url: String,
    ) -> Result<FilterListInfo, ShieldsError> {
        let _ = (title, url); // STUB(phase1)
        Err(ShieldsError::Engine {
            message: "shields not implemented".into(),
        })
    }

    pub fn remove_custom_list(&self, id: String) -> Result<(), ShieldsError> {
        let _ = id; // STUB(phase1)
        Ok(())
    }

    /// User-written filter rules (Adblock Plus / uBlock Origin syntax).
    pub fn custom_rules(&self) -> String {
        String::new() // STUB(phase1)
    }

    pub fn set_custom_rules(&self, rules: String) -> Result<(), ShieldsError> {
        let _ = rules; // STUB(phase1)
        Ok(())
    }

    /// Enabled lists never downloaded or last updated more than `max_age_ms` before `now_ms`.
    pub fn stale_lists(&self, max_age_ms: i64, now_ms: i64) -> Vec<FilterListInfo> {
        let _ = (max_age_ms, now_ms); // STUB(phase1)
        vec![]
    }

    /// Stores freshly downloaded list text. Rejects text with no parseable
    /// filters (an HTML error page, for example). Returns the rule count.
    /// Call [`Shields::rebuild`] afterwards to apply it.
    pub fn update_list(&self, id: String, text: String, now_ms: i64) -> Result<u32, ShieldsError> {
        let _ = (id, text, now_ms); // STUB(phase1)
        Ok(0)
    }

    /// Rebuilds the engine and content rule sets from enabled lists and custom
    /// rules, persists them, and returns the new build. Slow (seconds); call it
    /// off the main thread.
    pub fn rebuild(&self) -> Result<ShieldsBuild, ShieldsError> {
        // STUB(phase1)
        Ok(ShieldsBuild {
            fingerprint: "stub".into(),
            rule_sets: vec![],
            network_rules: 0,
            cosmetic_rules: 0,
            unconvertible_rules: 0,
        })
    }

    /// The last persisted build without recompiling, or `None` before the first build.
    pub fn current_build(&self) -> Result<Option<ShieldsBuild>, ShieldsError> {
        Ok(None) // STUB(phase1)
    }

    pub fn cosmetic_resources(&self, page_url: String) -> CosmeticResources {
        let _ = page_url; // STUB(phase1)
        CosmeticResources {
            hide_selectors: vec![],
            injected_script: String::new(),
            generichide: false,
            exceptions: vec![],
        }
    }

    /// Generic hide selectors matching the classes and ids found in the page DOM.
    pub fn hidden_selectors(
        &self,
        classes: Vec<String>,
        ids: Vec<String>,
        exceptions: Vec<String>,
    ) -> Vec<String> {
        let _ = (classes, ids, exceptions); // STUB(phase1)
        vec![]
    }

    /// Which of the observed requests match a blocking rule on `page_url`.
    pub fn check_requests(
        &self,
        page_url: String,
        requests: Vec<ObservedRequest>,
    ) -> Vec<BlockedRequest> {
        let _ = (page_url, requests); // STUB(phase1)
        vec![]
    }
}
