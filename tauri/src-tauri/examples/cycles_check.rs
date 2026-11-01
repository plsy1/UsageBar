// 排查用：从本机日志建一个临时库，打印「按周期」的前几行（和 macOS 版对照）
//   cargo run --example cycles_check
// 库在系统临时目录下的 usagebar-stats-check（和 stats_check 共用）

#[path = "../src/stats.rs"]
mod stats;
#[path = "../src/db.rs"]
#[allow(dead_code)]
mod db;

fn main() {
    let dir = std::env::temp_dir().join("usagebar-stats-check");
    let pricing = stats::Pricing::load_cached(&dir);
    let mut store = db::Store::open(&dir).expect("open database");
    store.sync_local(&pricing);
    let fmt = |ms: i64| chrono::DateTime::from_timestamp_millis(ms).unwrap().with_timezone(&chrono::Local).format("%m/%d %H:%M").to_string();
    for c in store.cycles(&[], &[]).iter().take(10) {
        println!(
            "{} – {}{} {:6} ${:>8.2} {:>6} req  used {}",
            fmt(c.start), fmt(c.end), if c.current { " *" } else { "  " }, c.source, c.cost, c.requests,
            c.used.map_or("—".to_string(), |u| format!("{u}"))
        );
    }
}
