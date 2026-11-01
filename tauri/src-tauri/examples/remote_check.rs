// 排查用：用 SSH 读远程机器上的 Codex 日志进一个临时库，打印每台的文件数、请求数、耗时，第二次读（增量）的耗时
//   cargo run --example remote_check <主机> [主机…]
// 库在系统临时目录下的 usagebar-remote-check（不碰正式版的数据库）

#[path = "../src/stats.rs"]
mod stats;
#[path = "../src/db.rs"]
#[allow(dead_code)]
mod db;
#[path = "../src/remote.rs"]
#[allow(dead_code)]
mod remote;

use std::sync::{Arc, Mutex};

fn main() {
    let hosts: Vec<String> = std::env::args().skip(1).collect();
    let dir = std::env::temp_dir().join("usagebar-remote-check");
    let pricing = stats::Pricing::load_cached(&std::env::temp_dir().join("usagebar-stats-check"));
    let store = Arc::new(Mutex::new(db::Store::open(&dir).expect("open database")));
    for round in ["first", "again"] {
        for h in &hosts {
            let t = std::time::Instant::now();
            let st = remote::read_remote(&store, h, &pricing);
            println!("{round:5} {h}: files={:?} requests={} error={:?} {:?}", st.files, st.requests, st.error, t.elapsed());
        }
    }
    let s = store.lock().unwrap();
    println!("rate limits: {:?}", remote::logged_rate_limits(&s).map(|(_, t)| t));
}
