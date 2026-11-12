// 排查用：查一次 Gemini 的额度（本机 Gemini.app 的 agent 或 Antigravity 在跑时），打印窗口、套餐、提示、出错原因；不打印 token
//   cargo run --example gemini_check
// 缓存放在系统临时目录下的 usagebar-gemini-check（不碰正式版的 gemini.json）：查到一次以后关掉 agent 再跑，看退回缓存的样子

#[path = "../src/usage.rs"]
#[allow(dead_code)]
mod usage;

fn main() {
    let dir = std::env::temp_dir().join("usagebar-gemini-check");
    let p = tauri::async_runtime::block_on(usage::gemini(Some(&dir)));
    println!("{}  plan={:?}  note={:?}  detail={:?}  error={:?}", p.name, p.plan, p.note, p.detail, p.error);
    for w in &p.windows {
        let label = match &w.group {
            Some(g) => format!("{g} · {}", w.kind),
            None => w.kind.clone(),
        };
        println!("  {label:28} id={:26} used={:5.1}%  resets_at={:?}  length={}  fast={}  runs_out_at={:?}", w.id.as_deref().unwrap_or("-"), w.used, w.resets_at, w.length, w.fast, w.runs_out_at);
    }
    // 托盘取的：没有组的 5 小时和本周
    let main: Vec<&str> = p.windows.iter().filter(|w| w.group.is_none()).map(|w| w.kind.as_str()).collect();
    println!("tray windows: {main:?}");
}
