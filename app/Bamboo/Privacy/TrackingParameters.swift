import Foundation

/// Query parameters that only exist to track clicks across sites. Built from DuckDuckGo's
/// tracking-parameter list (privacy-configuration) and Brave's query filter
/// (brave-core components/query_filter), minus parameters those lists strip only on
/// particular sites because elsewhere they carry meaning.
enum TrackingParameters {
    static let names: Set<String> = [
        // Ad click ids: Google, Microsoft, Meta, TikTok, X, LinkedIn, Yandex, Reddit
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "srsltid", "_gl",
        "msclkid", "fbclid", "fb_action_ids", "fb_action_types", "fb_comment_id", "fb_ref", "fb_source",
        "ttclid", "twclid", "li_fat_id", "yclid", "ymclid", "ysclid", "rdt_cid",
        "igshid", "irclickid", "rb_clickid", "unicorn_click_id", "wickedid",
        // Email and marketing automation: HubSpot, Mailchimp, Marketo, Oracle, Vero, Iterable, ...
        "_hsenc", "_hsmi", "__hsfp", "__hssc", "__hstc", "hsCtaTracking",
        "mc_cid", "mc_eid", "mkt_tok", "ml_subscriber", "ml_subscriber_hash",
        "oly_anon_id", "oly_enc_id", "vero_conv", "vero_id", "_bta_c", "_bta_tid",
        "bbeml", "bsft_clkid", "bsft_uid", "et_rid", "ss_email_id", "sc_customer", "sc_eh", "sc_uid",
        "at_recipient_id", "at_recipient_list", "vgo_ee", "_kx", "s_cid", "_openstat",
        "oft_c", "oft_ck", "oft_d", "oft_id", "oft_ids", "oft_k", "oft_lk", "oft_sk",
        // Analytics and attribution
        "_branch_match_id", "_branch_referrer", "mtm_cid", "pk_cid", "ebisu_session_id",
        "guce_referrer", "guce_referrer_sig",
    ]

    /// UTM campaign tags (utm_source, utm_medium, utm_campaign, ...).
    static let prefixes = ["utm_"]

    static func isTracking(_ name: String) -> Bool {
        names.contains(name) || prefixes.contains { name.hasPrefix($0) }
    }

    /// The URL without tracking parameters, or nil when it has none.
    static func strip(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems
        else { return nil }
        let kept = items.filter { !isTracking($0.name.removingPercentEncoding ?? $0.name) }
        guard kept.count < items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}
