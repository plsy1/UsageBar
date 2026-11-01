// 托盘菜单用的几句文字（窗口里的文字在 ui/app.js）

use crate::usage::LimitWindow;

/// 设置里的语言：auto / zh / ja / en；auto 按系统语言，非中日一律英文
pub fn resolve(setting: &str) -> &'static str {
    let lang = if setting == "auto" { sys_locale::get_locale().unwrap_or_default() } else { setting.to_string() };
    if lang.starts_with("zh") {
        "zh"
    } else if lang.starts_with("ja") {
        "ja"
    } else {
        "en"
    }
}

pub fn t(lang: &str, key: &str) -> &'static str {
    let (zh, ja, en) = match key {
        "refresh" => ("立即刷新", "今すぐ更新", "Refresh Now"),
        "open" => ("打开 UsageBar…", "UsageBar を開く…", "Open UsageBar…"),
        "quit" => ("退出", "終了", "Quit"),
        "show_card" => ("显示额度卡片", "上限カードを表示", "Show Limits Card"),
        "hide_card" => ("隐藏额度卡片", "上限カードを隠す", "Hide Limits Card"),
        "card_settings" => ("卡片设置…", "カード設定…", "Card Settings…"),
        "show_usage_card" => ("显示用量卡片", "使用量カードを表示", "Show Usage Card"),
        "hide_usage_card" => ("隐藏用量卡片", "使用量カードを隠す", "Hide Usage Card"),
        "keep_on_top" => ("保持在最前", "常に手前に表示", "Keep on Top"),
        "loading" => ("正在获取用量…", "使用量を取得中…", "Fetching usage…"),
        "used" => ("已用", "使用済み", "used"),
        "left" => ("剩", "残り", "left"),
        "error" => ("读取失败，打开窗口查看原因", "取得に失敗しました。ウィンドウで詳細を確認", "Couldn't read usage, open the window for details"),
        "five_hour" => ("5 小时", "5時間", "5 hours"),
        "weekly" => ("本周", "今週", "Weekly"),
        "weekly_opus" => ("本周 Opus", "今週 Opus", "Weekly Opus"),
        "weekly_sonnet" => ("本周 Sonnet", "今週 Sonnet", "Weekly Sonnet"),
        // 通知（%s 按顺序换成参数）
        "n_used" => ("%s 已用 %s%", "%s を %s% 使用", "%s is %s% used"),
        "n_fast" => ("%s 用得比时间快", "%s が速いペースです", "%s is ahead of pace"),
        "n_runs_out" => ("按现在的速度预计 %s 用完，%s", "このペースだと %s に使い切ります。%s", "At this pace it runs out %s; %s"),
        "n_reset_early" => ("%s 的额度被提前重置了", "%s の上限が予定より早くリセットされました", "%s limits were reset early"),
        "n_reset" => ("%s 的额度已重置", "%s の上限がリセットされました", "%s limits have reset"),
        "n_was_used" => ("%s（之前用了 %s%）", "%s（それまで %s% 使用）", "%s (was %s% used)"),
        "n_sep" => ("、", "、", ", "),
        "n_gain_one" => ("Codex 获得了 1 次额度重置", "Codex の上限リセットを 1 回もらいました", "Codex gave you a limit reset"),
        "n_gain" => ("Codex 获得了 %s 次额度重置", "Codex の上限リセットを %s 回もらいました", "Codex gave you %s limit resets"),
        "n_credits" => ("可用重置 %s 次", "リセット %s 回分", "%s resets available"),
        "n_credit_expiring" => ("Codex 的额度重置次数快到期了", "Codex のリセットがまもなく期限切れ", "A Codex reset is about to expire"),
        "n_credit_expires" => ("有 1 次重置将在 %s 到期，用不掉就作废", "リセット 1 回分が %s に期限切れになります。使わないと失効します", "One reset expires %s; it's lost if unused"),
        "update_available" => ("有新版本 %s…", "新しいバージョン %s…", "Version %s available…"),
        "runs_out" => ("预计 %s 用完", "%s に使い切る見込み", "runs out %s"),
        "expires" => ("%s 到期", "%s まで", "expires %s"),
        "earliest_expires" => ("最早 %s 到期", "最も早いもの %s まで", "earliest expires %s"),
        "resets_full" => ("%s后重置（%s）", "%s後にリセット（%s）", "resets in %s (%s)"),
        "resets_at" => ("%s 重置", "%s にリセット", "resets %s"),
        "resets_in" => ("%s后重置", "%s後にリセット", "resets in %s"),
        _ => ("", "", ""),
    };
    match lang {
        "zh" => zh,
        "ja" => ja,
        _ => en,
    }
}

pub fn window_label(lang: &str, w: &LimitWindow) -> String {
    match (w.kind.as_str(), w.amount) {
        ("hours", Some(n)) => match lang {
            "zh" => format!("{n} 小时"),
            "ja" => format!("{n}時間"),
            _ => format!("{n} hours"),
        },
        ("days", Some(n)) => match lang {
            "zh" => format!("{n} 天"),
            "ja" => format!("{n}日"),
            _ => format!("{n} days"),
        },
        (kind, _) => {
            let s = t(lang, kind);
            if s.is_empty() { kind.to_string() } else { s.to_string() }
        }
    }
}

/// 「已用 24%」/「剩 76%」/「24% used」
pub fn value_text(lang: &str, w: &LimitWindow, used: bool) -> String {
    let v = if used { w.used.min(100.0) } else { w.remaining() }.round() as i64;
    let word = t(lang, if used { "used" } else { "left" });
    if lang == "en" { format!("{v}% {word}") } else { format!("{word} {v}%") }
}

/// 把 key 对应的文字里的 %s 按顺序换成参数
pub fn fmt(lang: &str, key: &str, args: &[&str]) -> String {
    let mut s = t(lang, key).to_string();
    for a in args {
        s = s.replacen("%s", a, 1);
    }
    s
}

/// 「3小时20分后重置」（和界面的倒计时一样，差几秒到整分钟就进位）
pub fn reset_text(lang: &str, at: i64) -> String {
    reset_styled(lang, at, "relative")
}

/// 托盘菜单里的重置时间：full「3小时20分后重置（14:20）」/ relative「3小时20分后重置」/ absolute「周三 14:20 重置」
pub fn reset_styled(lang: &str, at: i64, style: &str) -> String {
    use chrono::{Local, TimeZone};
    let at = (at + 5) / 60 * 60;
    if style == "absolute" {
        return fmt(lang, "resets_at", &[&short_time(lang, at)]);
    }
    let s = (at - chrono::Utc::now().timestamp()).max(0);
    let (d, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60);
    let rel = match lang {
        "zh" if d > 0 => format!("{d}天{h}小时"),
        "zh" if h > 0 => format!("{h}小时{m}分"),
        "zh" => format!("{m}分钟"),
        "ja" if d > 0 => format!("{d}日{h}時間"),
        "ja" if h > 0 => format!("{h}時間{m}分"),
        "ja" => format!("{m}分"),
        _ if d > 0 => format!("{d}d {h}h"),
        _ if h > 0 => format!("{h}h {m}m"),
        _ => format!("{m}m"),
    };
    if style == "full" {
        let when = Local.timestamp_opt(at, 0).single().map(|d| d.format(if s >= 86400 { "%-m/%-d %H:%M" } else { "%H:%M" }).to_string()).unwrap_or_default();
        return fmt(lang, "resets_full", &[&rel, &when]);
    }
    fmt(lang, "resets_in", &[&rel])
}

/// 今天内只写几点，否则带上星期几：「14:20」「周三 14:20」
pub fn short_time(lang: &str, at: i64) -> String {
    use chrono::{Datelike, Local, TimeZone};
    let Some(d) = Local.timestamp_opt(at, 0).single() else { return String::new() };
    let time = d.format("%H:%M").to_string();
    if d.date_naive() == Local::now().date_naive() {
        return time;
    }
    let i = d.weekday().num_days_from_monday() as usize;
    let day = match lang {
        "zh" => ["周一", "周二", "周三", "周四", "周五", "周六", "周日"][i],
        "ja" => ["月曜日", "火曜日", "水曜日", "木曜日", "金曜日", "土曜日", "日曜日"][i],
        _ => ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][i],
    };
    format!("{day} {time}")
}

/// 「11/7 06:50」
pub fn date_time(at: i64) -> String {
    use chrono::{Local, TimeZone};
    Local.timestamp_opt(at, 0).single().map(|d| d.format("%-m/%-d %H:%M").to_string()).unwrap_or_default()
}
