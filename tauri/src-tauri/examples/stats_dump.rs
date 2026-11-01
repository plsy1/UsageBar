// 排查用：按几种条件跑一遍统计页的查询，把结果存成 JSON（在浏览器里预览界面时喂给页面）
//   cargo run --example stats_dump <输出目录>
// 数据库用 stats_check 建的那个（系统临时目录下的 usagebar-stats-check）

#[path = "../src/stats.rs"]
mod stats;
#[path = "../src/db.rs"]
#[allow(dead_code)]
mod db;
#[path = "../src/statsview.rs"]
mod statsview;
#[path = "../src/usage.rs"]
#[allow(dead_code)]
mod usage;

fn main() {
    let out = std::path::PathBuf::from(std::env::args().nth(1).expect("output dir"));
    let dir = std::env::temp_dir().join("usagebar-stats-check");
    let pricing = stats::Pricing::load_cached(&dir);
    let mut store = db::Store::open(&dir).expect("open database");
    store.sync_local(&pricing);
    std::fs::create_dir_all(&out).unwrap();
    for range in ["today", "7d", "all"] {
        for tab in ["log", "apps", "models", "projects", "cycles"] {
            let q = statsview::Query { range: range.into(), tab: tab.into(), ..Default::default() };
            let v = statsview::compute(&store, &pricing, &q, &[], None);
            std::fs::write(out.join(format!("{range}-{tab}.json")), serde_json::to_vec(&v).unwrap()).unwrap();
        }
    }
    println!("ok");
}
