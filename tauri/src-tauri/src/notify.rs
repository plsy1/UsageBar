// 额度通知（移植自 macOS 版 Sources/Notify.swift）
//   每次查完额度看一遍：用量到了设定的比例、按现在的速度会在重置前用完、额度重置了、Codex 的重置次数（新拿到、快到期）。
//   同一件事只提醒一次：发过的记在 notify.json（键里带着这个周期的重置时间），下个周期才会再提醒

use crate::i18n;
use crate::usage::{LimitWindow, Provider};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};
use tauri_plugin_notification::NotificationExt;

/// 哪些通知打开了（来自设置）
pub struct Options {
    pub threshold: u32, // 用量达到多少时提醒：0 是不提醒
    pub run_out: bool,
    pub reset: bool,
    pub credits: bool,
}

impl Options {
    fn any(&self) -> bool {
        self.threshold > 0 || self.run_out || self.reset || self.credits
    }
}

/// 存在文件里的：发过的通知，和上次看到的 Codex 重置次数（变多了就是新拿到了）
#[derive(Serialize, Deserialize, Default)]
struct Saved {
    sent: Vec<String>,
    credit_count: Option<u64>,
}

#[derive(Default)]
pub struct Notifier {
    /// 上一次的结果：用来发现「额度重置了」
    last: HashMap<String, LimitWindow>,
}

fn saved_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|d| d.join("notify.json"))
}

/// 接口给的重置时间常是 05:59:59.x，取到分钟，同一个周期的键才稳定
fn cycle(w: &LimitWindow) -> i64 {
    w.resets_at.map(|r| (r + 5) / 60).unwrap_or(0)
}

impl Notifier {
    pub fn check(&mut self, app: &AppHandle, lang: &str, opts: &Options, providers: &[Provider]) {
        if !opts.any() {
            return;
        }
        let path = saved_path(app);
        let mut saved: Saved =
            path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let mut out: Vec<(String, String)> = Vec::new();
        // 同一件事只发一次
        fn once(sent: &mut Vec<String>, out: &mut Vec<(String, String)>, key: String, title: String, body: String) {
            if !sent.contains(&key) {
                sent.push(key);
                out.push((title, body));
            }
        }
        let now = chrono::Utc::now().timestamp();
        for p in providers.iter().filter(|p| p.error.is_none()) {
            // 退回本地缓存、或者选了「仅本地」时的数据不可靠，不拿来判断重置
            let live = p.note.is_none();
            let mut resets: Vec<(String, f64, bool)> = Vec::new();
            // 用位置当键，不用显示名：显示名跟着界面语言变，换了语言会重复提醒
            for (i, w) in p.windows.iter().enumerate() {
                let id = format!("{}|{i}", p.name);
                let name = format!("{} · {}", p.name, i18n::window_label(lang, w));
                let reset = w.resets_at.map(|r| i18n::reset_text(lang, r)).unwrap_or_default();
                if opts.threshold > 0 && w.used >= opts.threshold as f64 {
                    let pct = (w.used.round() as i64).to_string();
                    once(&mut saved.sent, &mut out, format!("usage|{id}|{}|{}", cycle(w), opts.threshold),
                         i18n::fmt(lang, "n_used", &[&name, &pct]), reset.clone());
                }
                // 用了三成以上才提醒，周期刚开始时速度不准
                if let Some(t) = w.runs_out_at.filter(|_| opts.run_out && w.used >= 30.0) {
                    once(&mut saved.sent, &mut out, format!("runout|{id}|{}", cycle(w)),
                         i18n::fmt(lang, "n_fast", &[&name]),
                         i18n::fmt(lang, "n_runs_out", &[&i18n::short_time(lang, t), &reset]));
                }
                // 重置了就是开始了新周期：下次重置时间往后推（推了 5 分钟以上才算，Claude 的重置时间会有几秒的抖动）。
                // 原定时间还没到就推了的是提前重置（OpenAI 时不时给所有人重置一次，或者用了重置次数），总要提醒；
                // 按时重置的，之前用了一半以上才值得说
                if live {
                    if let Some(old) = self.last.get(&id) {
                        if let (Some(o), Some(n)) = (old.resets_at, w.resets_at) {
                            if n - o > 300 {
                                let early = o - now > 60;
                                if early || old.used >= 50.0 {
                                    resets.push((i18n::window_label(lang, w), old.used, early));
                                }
                            }
                        }
                    }
                    self.last.insert(id, w.clone());
                }
            }
            // 5 小时和本周常常一起重置：合成一条
            if opts.reset && !resets.is_empty() {
                let early = resets.iter().any(|r| r.2);
                // 键里是新的重置时间：每次重置都不一样，同一次不会重复提醒
                let cycles: Vec<String> = p.windows.iter().map(|w| w.resets_at.map(|_| cycle(w).to_string()).unwrap_or("-".into())).collect();
                let body: Vec<String> =
                    resets.iter().map(|(l, u, _)| i18n::fmt(lang, "n_was_used", &[l, &(u.round() as i64).to_string()])).collect();
                once(&mut saved.sent, &mut out, format!("reset|{}|{}", p.name, cycles.join(",")),
                     i18n::fmt(lang, if early { "n_reset_early" } else { "n_reset" }, &[&p.name]),
                     body.join(i18n::t(lang, "n_sep")));
            }
            // 新拿到重置次数。只看接口直接查到的（退回本地缓存时不知道次数）；第一次只记下不提醒
            if p.name == "Codex" && live {
                let count = p.resets.as_ref().map(|r| r.count).unwrap_or(0);
                if let (true, Some(old), Some(rc)) = (opts.credits, saved.credit_count, p.resets.as_ref()) {
                    if count > old {
                        let gained = count - old;
                        let title = if gained == 1 { i18n::t(lang, "n_gain_one").to_string() } else { i18n::fmt(lang, "n_gain", &[&gained.to_string()]) };
                        out.push((title, i18n::fmt(lang, "n_credits", &[&rc.count.to_string()])));
                    }
                }
                saved.credit_count = Some(count);
            }
            if let Some(rc) = p.resets.as_ref().filter(|_| opts.credits) {
                for &e in rc.expiries.iter().filter(|&&e| e > now && e - now < 86400) {
                    once(&mut saved.sent, &mut out, format!("credit|{e}"), i18n::t(lang, "n_credit_expiring").to_string(),
                         i18n::fmt(lang, "n_credit_expires", &[&i18n::date_time(e)]));
                }
            }
        }
        for (title, body) in out {
            let _ = app.notification().builder().title(title).body(body).show();
        }
        let keep = saved.sent.len().saturating_sub(300);
        saved.sent.drain(..keep);
        if let Some(p) = path {
            let _ = std::fs::write(p, serde_json::to_string(&saved).unwrap_or_default());
        }
    }
}
