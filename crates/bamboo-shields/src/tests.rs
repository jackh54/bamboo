use super::*;
use serde_json::Value;
use tempfile::TempDir;

const ADS_LIST: &str = "\
[Adblock Plus 2.0]
! Title: Test ads
||ads.example.com^
||tracker.example.net^$third-party
@@||ads.example.com/allowed^
example.org##.sponsored
##.banner-ad
";

const PRIVACY_LIST: &str = "\
! Title: Test privacy
||metrics.example.io^
";

const RESOURCES: &str = r#"[{"name":"noop.js","aliases":[],"kind":{"mime":"application/javascript"},"content":"Ly8gbm9vcA=="}]"#;

const NOW_MS: i64 = 1_700_000_000_000;
const DAY_MS: i64 = 86_400_000;

fn open_in(dir: &TempDir) -> Arc<Shields> {
    Shields::open(dir.path().to_str().expect("utf-8 path").into(), None).expect("open")
}

/// Fresh shields with only `easylist` (ADS_LIST) and `easyprivacy` (PRIVACY_LIST) enabled and loaded.
fn fixture() -> (TempDir, Arc<Shields>) {
    let dir = TempDir::new().expect("temp dir");
    let shields = open_in(&dir);
    for list in shields.lists() {
        let enabled = list.id == "easylist" || list.id == "easyprivacy";
        shields.set_list_enabled(list.id, enabled).expect("toggle");
    }
    shields
        .update_list("easylist".into(), ADS_LIST.into(), NOW_MS)
        .expect("update easylist");
    shields
        .update_list("easyprivacy".into(), PRIVACY_LIST.into(), NOW_MS)
        .expect("update easyprivacy");
    (dir, shields)
}

fn all_rules(build: &ShieldsBuild) -> Vec<Value> {
    build
        .rule_sets
        .iter()
        .flat_map(|set| {
            serde_json::from_str::<Vec<Value>>(&set.json).expect("rule set is a JSON array")
        })
        .collect()
}

fn blocked_hosts(shields: &Shields, page: &str, urls: &[&str]) -> Vec<String> {
    let requests = urls
        .iter()
        .map(|url| ObservedRequest {
            url: (*url).into(),
            request_type: RequestType::Script,
        })
        .collect();
    shields
        .check_requests(page.into(), requests)
        .into_iter()
        .map(|blocked| blocked.host)
        .collect()
}

#[test]
fn builtin_catalog_is_well_formed() {
    let dir = TempDir::new().expect("temp dir");
    let lists = open_in(&dir).lists();
    let ids: HashSet<&str> = lists.iter().map(|list| list.id.as_str()).collect();
    assert_eq!(ids.len(), lists.len(), "ids are unique");
    assert!(
        lists
            .iter()
            .all(|list| list.builtin && list.url.starts_with("https://"))
    );
    let enabled = |id: &str| lists.iter().find(|list| list.id == id).expect(id).enabled;
    assert!(enabled("easylist") && enabled("easylist-cookie"));
    assert!(!enabled("fanboy-annoyances") && !enabled("ublock-annoyances"));
}

#[test]
fn rebuild_converts_network_filters_to_webkit_rules() {
    let (_dir, shields) = fixture();
    let build = shields.rebuild().expect("rebuild");
    let rules = all_rules(&build);

    let block = rules
        .iter()
        .find(|rule| {
            rule["trigger"]["url-filter"]
                .as_str()
                .is_some_and(|filter| filter.contains(r"ads\.example\.com"))
        })
        .expect("a rule for ads.example.com");
    assert_eq!(block["action"]["type"], "block");

    let third_party = rules
        .iter()
        .find(|rule| {
            rule["trigger"]["url-filter"]
                .as_str()
                .is_some_and(|filter| filter.contains(r"tracker\.example\.net"))
        })
        .expect("a rule for tracker.example.net");
    assert_eq!(third_party["trigger"]["load-type"][0], "third-party");

    assert!(
        rules
            .iter()
            .any(|rule| rule["action"]["type"] == "ignore-previous-rules"),
        "the @@ exception becomes ignore-previous-rules"
    );
    assert!(
        rules
            .iter()
            .all(|rule| rule["action"]["type"] != "css-display-none"),
        "cosmetic filters stay out of WebKit"
    );
    assert_eq!(build.network_rules, 4);
    assert_eq!(build.cosmetic_rules, 2);
    assert_eq!(build.unconvertible_rules, 0);
}

#[test]
fn rule_set_identifiers_embed_the_fingerprint() {
    let (_dir, shields) = fixture();
    let build = shields.rebuild().expect("rebuild");
    assert_eq!(build.rule_sets.len(), 1);
    assert_eq!(
        build.rule_sets[0].identifier,
        format!("bamboo-shields-{}-0", build.fingerprint)
    );
}

#[test]
fn rule_sets_are_split_at_the_limit_and_keep_exceptions() {
    let rule = |action: &str, filter: &str| -> CbRule {
        serde_json::from_value(serde_json::json!({
            "action": { "type": action },
            "trigger": { "url-filter": filter },
        }))
        .expect("rule")
    };
    let mut rules: Vec<CbRule> = (0..5).map(|n| rule("block", &format!("ad{n}"))).collect();
    rules.push(rule("ignore-previous-rules", "allowed"));

    let sets = split_rule_sets(&rules, 3).expect("split");
    assert_eq!(
        sets.len(),
        3,
        "2 blocking rules per set leave room for the exception"
    );
    for (n, set) in sets.iter().enumerate() {
        let chunk: Vec<Value> = serde_json::from_str(set).expect("json");
        assert!(chunk.len() <= 3);
        assert_eq!(
            chunk.last().expect("last")["action"]["type"],
            "ignore-previous-rules"
        );
        assert_eq!(chunk[0]["trigger"]["url-filter"], format!("ad{}", n * 2));
    }

    let only_exceptions = split_rule_sets(&rules, 1);
    assert!(matches!(only_exceptions, Err(ShieldsError::Engine { .. })));
}

#[test]
fn fingerprint_is_stable_and_follows_the_inputs() {
    let (_dir_a, a) = fixture();
    let (_dir_b, b) = fixture();
    let first = a.rebuild().expect("rebuild").fingerprint;
    assert_eq!(first, b.rebuild().expect("rebuild").fingerprint);
    assert_eq!(first.len(), 16);

    a.update_list(
        "easylist".into(),
        format!("{ADS_LIST}||more.example.com^\n"),
        NOW_MS,
    )
    .expect("update");
    let after_list = a.rebuild().expect("rebuild").fingerprint;
    assert_ne!(first, after_list);

    a.set_custom_rules("||mine.example.com^".into())
        .expect("custom rules");
    let after_custom = a.rebuild().expect("rebuild").fingerprint;
    assert_ne!(after_list, after_custom);

    a.update_resources(RESOURCES.into(), NOW_MS)
        .expect("resources");
    assert_ne!(after_custom, a.rebuild().expect("rebuild").fingerprint);
}

#[test]
fn rebuild_with_unchanged_inputs_returns_the_same_build() {
    let (_dir, shields) = fixture();
    let first = shields.rebuild().expect("rebuild");
    assert_eq!(first, shields.rebuild().expect("rebuild"));
}

#[test]
fn custom_rules_are_applied() {
    let (_dir, shields) = fixture();
    shields
        .set_custom_rules("||mine.example.com^".into())
        .expect("set");
    assert_eq!(shields.custom_rules(), "||mine.example.com^");
    shields.rebuild().expect("rebuild");
    assert_eq!(
        blocked_hosts(
            &shields,
            "https://news.test/",
            &["https://mine.example.com/x.js"]
        ),
        ["mine.example.com"]
    );
}

#[test]
fn cosmetic_resources_for_a_host_specific_rule() {
    let (_dir, shields) = fixture();
    shields.rebuild().expect("rebuild");
    let on_site = shields.cosmetic_resources("https://example.org/page".into());
    assert_eq!(on_site.hide_selectors, [".sponsored"]);
    assert!(!on_site.generichide);
    let elsewhere = shields.cosmetic_resources("https://other.test/".into());
    assert!(elsewhere.hide_selectors.is_empty());
}

#[test]
fn hidden_selectors_for_a_generic_rule() {
    let (_dir, shields) = fixture();
    shields.rebuild().expect("rebuild");
    let page = shields.cosmetic_resources("https://other.test/".into());
    let found = shields.hidden_selectors(
        vec!["banner-ad".into(), "content".into()],
        vec![],
        page.exceptions.clone(),
    );
    assert_eq!(found, [".banner-ad"]);
    let excepted =
        shields.hidden_selectors(vec!["banner-ad".into()], vec![], vec![".banner-ad".into()]);
    assert!(excepted.is_empty());
}

#[test]
fn check_requests_blocks_ads_and_respects_exceptions() {
    let (_dir, shields) = fixture();
    shields.rebuild().expect("rebuild");
    let blocked = blocked_hosts(
        &shields,
        "https://news.test/",
        &[
            "https://ads.example.com/banner.js",
            "https://ads.example.com/allowed/banner.js",
            "https://cdn.news.test/app.js",
            "data:text/plain,hello",
        ],
    );
    assert_eq!(blocked, ["ads.example.com"]);
}

#[test]
fn check_requests_honours_the_third_party_option() {
    let (_dir, shields) = fixture();
    shields.rebuild().expect("rebuild");
    let url = "https://tracker.example.net/t.js";
    assert_eq!(
        blocked_hosts(&shields, "https://news.test/", &[url]),
        ["tracker.example.net"]
    );
    assert!(blocked_hosts(&shields, "https://tracker.example.net/", &[url]).is_empty());
}

#[test]
fn disabling_a_list_removes_its_rules() {
    let (_dir, shields) = fixture();
    let before = shields.rebuild().expect("rebuild");
    let metrics = "https://metrics.example.io/p.js";
    assert_eq!(
        blocked_hosts(&shields, "https://news.test/", &[metrics]),
        ["metrics.example.io"]
    );

    shields
        .set_list_enabled("easyprivacy".into(), false)
        .expect("disable");
    let after = shields.rebuild().expect("rebuild");
    assert_ne!(before.fingerprint, after.fingerprint);
    assert_eq!(after.network_rules, 3);
    assert!(blocked_hosts(&shields, "https://news.test/", &[metrics]).is_empty());
    assert!(!after.rule_sets[0].json.contains("metrics"));
}

#[test]
fn no_enabled_text_builds_no_rule_sets() {
    let dir = TempDir::new().expect("temp dir");
    let shields = open_in(&dir);
    let build = shields.rebuild().expect("rebuild");
    assert!(build.rule_sets.is_empty());
    assert_eq!(build.network_rules, 0);
}

#[test]
fn update_list_rejects_html_and_empty_text() {
    let (_dir, shields) = fixture();
    let html = "<!DOCTYPE html>\n<html>\n<head><title>Not found</title></head>\n<body>404</body>\n</html>\n";
    for text in [html, "", "! only a comment\n"] {
        let result = shields.update_list("easylist".into(), text.into(), NOW_MS + 1);
        assert!(
            matches!(result, Err(ShieldsError::InvalidList { .. })),
            "{text:?}"
        );
    }
    let easylist = shields
        .lists()
        .into_iter()
        .find(|list| list.id == "easylist")
        .expect("easylist");
    assert_eq!(easylist.rule_count, 5);
    assert_eq!(easylist.last_updated_ms, Some(NOW_MS));
}

#[test]
fn update_list_rejects_unknown_ids() {
    let (_dir, shields) = fixture();
    let result = shields.update_list("nope".into(), ADS_LIST.into(), NOW_MS);
    assert!(matches!(result, Err(ShieldsError::UnknownList { .. })));
}

#[test]
fn custom_lists_accept_only_http_urls() {
    let (_dir, shields) = fixture();
    for url in [
        "ftp://example.com/list.txt",
        "file:///etc/hosts",
        "example.com/list.txt",
        "https://",
        "https://a b/c",
    ] {
        let result = shields.add_custom_list("Bad".into(), url.into());
        assert!(
            matches!(result, Err(ShieldsError::InvalidList { .. })),
            "{url}"
        );
    }
    let added = shields
        .add_custom_list("Mine".into(), "HTTPS://example.com/list.txt".into())
        .expect("add");
    assert!(!added.builtin && added.enabled);
    assert_eq!(added.category, ListCategory::Custom);
    assert_eq!(shields.lists().last(), Some(&added));
    assert!(matches!(
        shields.add_custom_list("Again".into(), "HTTPS://example.com/list.txt".into()),
        Err(ShieldsError::InvalidList { .. })
    ));

    shields
        .update_list(added.id.clone(), PRIVACY_LIST.into(), NOW_MS)
        .expect("update");
    shields
        .remove_custom_list(added.id.clone())
        .expect("remove");
    assert!(shields.lists().iter().all(|list| list.id != added.id));
    assert!(matches!(
        shields.remove_custom_list("easylist".into()),
        Err(ShieldsError::InvalidList { .. })
    ));
}

#[test]
fn stale_lists_cover_enabled_lists_only() {
    let (_dir, shields) = fixture();
    // The fixture disabled every list except easylist and easyprivacy, both fresh.
    assert!(shields.stale_lists(DAY_MS, NOW_MS + DAY_MS).is_empty());
    let stale = shields.stale_lists(DAY_MS, NOW_MS + DAY_MS + 1);
    assert_eq!(stale.len(), 2);

    shields
        .set_list_enabled("easyprivacy".into(), false)
        .expect("disable");
    shields
        .set_list_enabled("ublock-filters".into(), true)
        .expect("enable");
    let ids: Vec<String> = shields
        .stale_lists(DAY_MS, NOW_MS + DAY_MS + 1)
        .into_iter()
        .map(|list| list.id)
        .collect();
    assert_eq!(
        ids,
        ["easylist", "ublock-filters"],
        "never-downloaded enabled lists are stale"
    );
}

#[test]
fn resources_are_validated_and_tracked() {
    let (_dir, shields) = fixture();
    assert!(shields.resources_stale(DAY_MS, NOW_MS));
    assert!(matches!(
        shields.update_resources("<html>nope</html>".into(), NOW_MS),
        Err(ShieldsError::InvalidList { .. })
    ));
    assert!(matches!(
        shields.update_resources(r#"{"name":"not-an-array"}"#.into(), NOW_MS),
        Err(ShieldsError::InvalidList { .. })
    ));
    assert!(
        shields.resources_stale(DAY_MS, NOW_MS),
        "rejected JSON is not stored"
    );

    assert_eq!(
        shields
            .update_resources(RESOURCES.into(), NOW_MS)
            .expect("update"),
        1
    );
    assert!(!shields.resources_stale(DAY_MS, NOW_MS + DAY_MS));
    assert!(shields.resources_stale(DAY_MS, NOW_MS + DAY_MS + 1));
    assert!(shields.resources_url().ends_with("/dist/resources.json"));
}

#[test]
fn state_survives_a_restart() {
    let (dir, shields) = fixture();
    shields
        .update_resources(RESOURCES.into(), NOW_MS)
        .expect("resources");
    shields
        .set_custom_rules("||mine.example.com^".into())
        .expect("custom rules");
    let added = shields
        .add_custom_list("Mine".into(), "https://example.com/list.txt".into())
        .expect("add");
    let build = shields.rebuild().expect("rebuild");
    let lists = shields.lists();
    drop(shields);

    let reopened = open_in(&dir);
    assert_eq!(
        reopened.current_build().expect("build"),
        Some(build.clone())
    );
    assert_eq!(reopened.lists(), lists);
    assert_eq!(reopened.custom_rules(), "||mine.example.com^");
    assert!(reopened.lists().contains(&added));
    assert!(!reopened.resources_stale(DAY_MS, NOW_MS));

    // The engine comes back from its saved form, not from re-parsing lists.
    assert_eq!(
        blocked_hosts(
            &reopened,
            "https://news.test/",
            &[
                "https://ads.example.com/a.js",
                "https://mine.example.com/a.js"
            ]
        ),
        ["ads.example.com", "mine.example.com"]
    );
    assert_eq!(
        reopened
            .cosmetic_resources("https://example.org/".into())
            .hide_selectors,
        [".sponsored"]
    );
    assert_eq!(
        reopened.rebuild().expect("rebuild"),
        build,
        "same inputs, same build"
    );
}

#[test]
fn open_recovers_when_the_saved_engine_is_unreadable() {
    let (dir, shields) = fixture();
    let build = shields.rebuild().expect("rebuild");
    drop(shields);
    fs::write(dir.path().join(ENGINE_FILE), b"not an engine").expect("corrupt engine");

    let reopened = open_in(&dir);
    assert_eq!(reopened.current_build().expect("build"), Some(build));
    assert_eq!(
        blocked_hosts(
            &reopened,
            "https://news.test/",
            &["https://ads.example.com/a.js"]
        ),
        ["ads.example.com"]
    );
}

#[test]
fn bundled_lists_seed_missing_text_once() {
    let bundle = TempDir::new().expect("bundle dir");
    fs::write(bundle.path().join("easylist.txt"), ADS_LIST).expect("bundled list");
    fs::write(bundle.path().join("resources.json"), RESOURCES).expect("bundled resources");
    let dir = TempDir::new().expect("temp dir");
    let open = || {
        Shields::open(
            dir.path().to_str().expect("utf-8 path").into(),
            Some(bundle.path().to_str().expect("utf-8 path").into()),
        )
        .expect("open")
    };

    let shields = open();
    let easylist = shields
        .lists()
        .into_iter()
        .find(|list| list.id == "easylist")
        .expect("easylist");
    assert_eq!(easylist.rule_count, 5);
    assert_eq!(easylist.last_updated_ms, None);
    assert!(
        shields
            .stale_lists(DAY_MS, NOW_MS)
            .iter()
            .any(|list| list.id == "easylist")
    );
    assert!(shields.resources_stale(DAY_MS, NOW_MS));
    assert_eq!(shields.rebuild().expect("rebuild").network_rules, 3);

    // A downloaded update wins over the bundle on later opens.
    shields
        .update_list("easylist".into(), PRIVACY_LIST.into(), NOW_MS)
        .expect("update");
    drop(shields);
    let reopened = open();
    let easylist = reopened
        .lists()
        .into_iter()
        .find(|list| list.id == "easylist")
        .expect("easylist");
    assert_eq!(
        (easylist.rule_count, easylist.last_updated_ms),
        (1, Some(NOW_MS))
    );
}

#[test]
fn readers_are_not_blocked_while_rebuilding() {
    let (_dir, shields) = fixture();
    shields.rebuild().expect("rebuild");
    let rebuilder = Arc::clone(&shields);
    shields
        .set_custom_rules("||late.example.com^".into())
        .expect("custom rules");
    let handle = std::thread::spawn(move || rebuilder.rebuild().expect("rebuild"));
    for _ in 0..50 {
        // Always answered from a complete engine: the old one or the new one.
        assert_eq!(
            blocked_hosts(
                &shields,
                "https://news.test/",
                &["https://ads.example.com/a.js"]
            ),
            ["ads.example.com"]
        );
    }
    handle.join().expect("rebuild thread");
    assert_eq!(
        blocked_hosts(
            &shields,
            "https://news.test/",
            &["https://late.example.com/a.js"]
        ),
        ["late.example.com"]
    );
}
