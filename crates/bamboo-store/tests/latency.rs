//! Latency check on a 100k-URL profile. Slow in debug builds, so it is ignored by default:
//!
//! `cargo test --release -p bamboo-store --test latency -- --ignored --nocapture`

use std::time::{Duration, Instant};

use bamboo_store::{HistoryImport, Store, VisitKind};
use tempfile::TempDir;

const URLS: u64 = 100_000;
const BOOKMARKS: u64 = 2_000;
const VOCABULARY: u64 = 3_000;
const NOW: i64 = 1_700_000_000_000;
const DAY_MS: i64 = 86_400_000;
const SYLLABLES: [&str; 20] = [
    "ka", "lo", "mi", "ra", "te", "su", "no", "vi", "ba", "chi", "dor", "fen", "gu", "hol", "jar",
    "ky", "lem", "nor", "pa", "qui",
];

/// Small deterministic generator so every run measures the same database.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self, bound: u64) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (self.0 >> 33) % bound
    }

    /// A pronounceable word; a skew towards low ids makes some words far more common than others.
    fn word(&mut self) -> String {
        let id = self.next(VOCABULARY).min(self.next(VOCABULARY));
        let mut word_rng = Lcg(id + 1);
        let syllables = 2 + word_rng.next(2);
        (0..syllables)
            .map(|_| SYLLABLES[word_rng.next(SYLLABLES.len() as u64) as usize])
            .collect()
    }
}

fn report(name: &str, mut samples: Vec<Duration>) -> Duration {
    samples.sort();
    let mean = samples.iter().sum::<Duration>() / samples.len() as u32;
    let p99 = samples[samples.len() * 99 / 100];
    println!(
        "{name:<30} mean {:>8.1} us   p99 {:>8.1} us   max {:>8.1} us   (n={})",
        mean.as_secs_f64() * 1e6,
        p99.as_secs_f64() * 1e6,
        samples.last().unwrap().as_secs_f64() * 1e6,
        samples.len()
    );
    mean
}

#[test]
#[ignore = "builds a 100k-URL database; run in release mode"]
fn suggest_and_record_visit_stay_fast_with_100k_urls() {
    let dir = TempDir::new().unwrap();
    let store = Store::open(dir.path().join("profile.db").to_str().unwrap().into()).unwrap();
    let mut rng = Lcg(42);

    // Real inputs taken from the data, so every query has something to find.
    let mut hosts = Vec::new();
    let mut paths = Vec::new();
    let mut title_starts = Vec::new();
    let items: Vec<HistoryImport> = (0..URLS)
        .map(|i| {
            let host = format!("{}{}.com", rng.word(), rng.next(20));
            let path = rng.word();
            let title = format!("{} {} {}", rng.word(), rng.word(), rng.word());
            if i % 10_000 == 0 {
                hosts.push(host.clone());
                paths.push(path.clone());
                title_starts.push(title.clone());
            }
            HistoryImport {
                url: format!("https://www.{host}/{path}/{i}"),
                title: Some(title),
                last_visit_ms: NOW - rng.next(400 * DAY_MS as u64) as i64,
                visit_count: 1 + rng.next(30) as u32,
            }
        })
        .collect();
    let started = Instant::now();
    store.import_history(items).unwrap();
    println!("import of {URLS} urls: {:?}", started.elapsed());
    for i in 0..BOOKMARKS {
        let url = format!("https://{}.org/saved/{i}", rng.word());
        store
            .add_bookmark(None, format!("{} {}", rng.word(), rng.word()), Some(url))
            .unwrap();
    }

    let measure = |inputs: &[String]| -> Vec<Duration> {
        let mut samples = Vec::new();
        for _ in 0..10 {
            for input in inputs {
                let started = Instant::now();
                let found = store.suggest(input.clone(), 8).unwrap();
                samples.push(started.elapsed());
                assert!(!found.is_empty(), "no suggestions for {input:?}");
            }
        }
        samples
    };
    let prefix = |len: usize| -> Vec<String> { hosts.iter().map(|h| h[..len].into()).collect() };
    let host_and_path: Vec<String> = hosts
        .iter()
        .zip(&paths)
        .map(|(host, path)| format!("{host}/{}", &path[..2]))
        .collect();
    let title_words = |letters: usize| -> Vec<String> {
        title_starts
            .iter()
            .map(|title| {
                title
                    .split(' ')
                    .map(|word| &word[..letters.min(word.len())])
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .collect()
    };

    let means = [
        ("1 letter", report("suggest, 1 letter", measure(&prefix(1)))),
        (
            "2 letters",
            report("suggest, 2 letters", measure(&prefix(2))),
        ),
        (
            "3 letters",
            report("suggest, 3 letters", measure(&prefix(3))),
        ),
        (
            "5 letters",
            report("suggest, 5 letters", measure(&prefix(5))),
        ),
        (
            "host and path",
            report("suggest, host and path", measure(&host_and_path)),
        ),
        (
            "3 title words",
            report("suggest, 3 title words", measure(&title_words(3))),
        ),
    ];

    let mut known = Vec::new();
    let mut fresh = Vec::new();
    for i in 0..2_000_i64 {
        let at_ms = NOW + i * 1_000;
        let started = Instant::now();
        store
            .record_visit(
                format!("https://www.{}/new/{i}", hosts[i as usize % hosts.len()]),
                Some("A page".into()),
                VisitKind::Link,
                at_ms,
            )
            .unwrap();
        fresh.push(started.elapsed());
        let started = Instant::now();
        store
            .record_visit(
                format!("https://www.{}/new/0", hosts[0]),
                None,
                VisitKind::Typed,
                at_ms,
            )
            .unwrap();
        known.push(started.elapsed());
    }
    let new_url = report("record_visit, new url", fresh);
    let known_url = report("record_visit, known url", known);

    for (name, mean) in means {
        assert!(
            mean < Duration::from_millis(2),
            "suggest ({name}) mean {mean:?} is over 2 ms"
        );
    }
    assert!(new_url < Duration::from_millis(2) && known_url < Duration::from_millis(2));
}
