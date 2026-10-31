// 排查用：打印今天和最近 7 天每家的汇总，格式和 macOS 版 `UsageBar --stats` 一样，后面附上精确数字
//   cargo run --example stats_check [缓存目录]
// 缓存目录默认是系统临时目录下的 usagebar-stats-check（不碰正式版的缓存）
// 再加 since=<带小数秒的 ISO 时间> 打印从那时起每家的汇总（对照「重置以来」用）

#[path = "../src/stats.rs"]
mod stats;

use stats::{LogReader, Source, StatsRange, Summary};
use std::time::Instant;

fn abbrev(n: i64) -> String {
    let d = n as f64;
    match d.abs() {
        x if x >= 1e9 => format!("{:.2}B", d / 1e9),
        x if x >= 1e6 => format!("{:.1}M", d / 1e6),
        x if x >= 1e3 => format!("{:.1}K", d / 1e3),
        _ => n.to_string(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let since_args: Vec<_> = args.iter().filter_map(|a| a.strip_prefix("since=")).collect();
    let dir = args
        .iter()
        .find(|a| !a.starts_with("since="))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("usagebar-stats-check"));
    let t0 = Instant::now();
    let pricing = tauri::async_runtime::block_on(async {
        let client = reqwest::Client::new();
        stats::load_pricing(&client, &dir, false).await
    });
    let t1 = Instant::now();
    let mut reader = LogReader::new(&dir);
    let mut recs = reader.read(StatsRange::Week.preset_start());
    pricing.apply(&mut recs);
    let t2 = Instant::now();
    for range in [StatsRange::Today, StatsRange::Week] {
        let name = if range == StatsRange::Today { "today" } else { "7d" };
        for src in [Source::Claude, Source::Codex] {
            let s: Summary = stats::summarize(&recs, Some(src), range.preset_start());
            println!(
                "{name} {src:?}: cost ${:.2} · requests {} · tokens {} (in {} out {} cacheR {} cacheW {}) · hit {}",
                s.cost,
                s.requests,
                abbrev(s.tokens),
                abbrev(s.input),
                abbrev(s.output),
                abbrev(s.cache_read),
                abbrev(s.cache_write),
                s.hit_rate.map_or("—".into(), |h| format!("{:.1}%", h * 100.0))
            );
            println!(
                "    exact: cost {:.6} requests {} tokens {} in {} out {} cacheR {} cacheW {}",
                s.cost, s.requests, s.tokens, s.input, s.output, s.cache_read, s.cache_write
            );
        }
    }
    for a in since_args {
        let Some(t) = stats::parse_iso(a) else {
            println!("bad since: {a}");
            continue;
        };
        for src in [Source::Claude, Source::Codex] {
            let s = stats::summarize(&recs, Some(src), t);
            println!("since {a} {src:?}: cost ${:.2} · requests {} · tokens {}", s.cost, s.requests, abbrev(s.tokens));
        }
    }
    let unpriced = stats::unpriced_models(&recs);
    if !unpriced.is_empty() {
        println!("unpriced models: {}", unpriced.join(", "));
    }
    println!(
        "cache {} · pricing {}{} · read {} records in {:.0} ms (pricing {:.0} ms)",
        dir.display(),
        if pricing.is_empty() { "missing" } else { "ok" },
        if pricing.download_failed { " (download failed)" } else { "" },
        recs.len(),
        (t2 - t1).as_secs_f64() * 1000.0,
        (t1 - t0).as_secs_f64() * 1000.0
    );
}
