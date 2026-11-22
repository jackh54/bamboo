//! Frecency in the spirit of Firefox's: recent visits score higher, typed visits
//! count extra and bookmarked URLs get a bonus.
//!
//! The score is stored per URL so `suggest` stays a plain index scan. It is
//! refreshed when the URL's visits change, and `age_stale` re-ages a few old
//! scores on every new visit so they keep decaying.

use rusqlite::Transaction;

use crate::{MS_PER_DAY, VisitKind};

/// Added to the frecency of bookmarked URLs when ranking.
pub const BOOKMARK_BONUS: f64 = 150.0;

/// Newest visits that feed a URL's score, as Firefox samples.
const SAMPLE_SIZE: i64 = 10;

/// Recency buckets are a day wide, so a score younger than this cannot have changed bucket.
const STALE_AFTER_MS: i64 = MS_PER_DAY;

/// Scores re-aged per new visit: keeps `record_visit` cheap while covering the table over time.
const AGED_PER_VISIT: i64 = 5;

/// Percent weight a visit of this kind contributes.
pub fn weight(kind: VisitKind) -> i32 {
    match kind {
        VisitKind::Typed => 200,
        VisitKind::Bookmark => 140,
        VisitKind::Link | VisitKind::FormSubmit | VisitKind::Other => 100,
        VisitKind::Reload => 50,
        VisitKind::Redirect => 25,
    }
}

fn recency_points(age_ms: i64) -> f64 {
    match age_ms / MS_PER_DAY {
        ..=4 => 100.0,
        5..=14 => 70.0,
        15..=31 => 50.0,
        32..=90 => 30.0,
        _ => 10.0,
    }
}

/// Recomputes a URL's frecency and last visit from its visits, aging them to `now_ms`.
pub fn refresh(tx: &Transaction, url_id: i64, now_ms: i64) -> rusqlite::Result<()> {
    let visit_count: u32 = tx
        .prepare_cached("SELECT visit_count FROM urls WHERE id = ?1")?
        .query_row([url_id], |row| row.get(0))?;
    let samples = tx
        .prepare_cached(
            "SELECT visited_at_ms, weight FROM visits WHERE url_id = ?1
             ORDER BY visited_at_ms DESC LIMIT ?2",
        )?
        .query_map((url_id, SAMPLE_SIZE), |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, i32>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let Some(&(last_visit_ms, _)) = samples.first() else {
        return Err(rusqlite::Error::QueryReturnedNoRows);
    };
    let points: f64 = samples
        .iter()
        .map(|&(at_ms, weight)| recency_points(now_ms - at_ms) * f64::from(weight) / 100.0)
        .sum();
    let frecency = f64::from(visit_count) * points / samples.len() as f64;
    tx.prepare_cached(
        "UPDATE urls SET frecency = ?2, last_visit_ms = ?3, scored_at_ms = ?4 WHERE id = ?1",
    )?
    .execute((url_id, frecency, last_visit_ms, now_ms))?;
    Ok(())
}

/// Re-ages the stalest scores to `now_ms`.
pub fn age_stale(tx: &Transaction, now_ms: i64) -> rusqlite::Result<()> {
    let stale = tx
        .prepare_cached(
            "SELECT id FROM urls WHERE scored_at_ms < ?1 ORDER BY scored_at_ms LIMIT ?2",
        )?
        .query_map((now_ms - STALE_AFTER_MS, AGED_PER_VISIT), |row| {
            row.get::<_, i64>(0)
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for url_id in stale {
        refresh(tx, url_id, now_ms)?;
    }
    Ok(())
}
