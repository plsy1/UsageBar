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
        "show_card" => ("显示桌面卡片", "デスクトップカードを表示", "Show Desktop Card"),
        "hide_card" => ("隐藏桌面卡片", "デスクトップカードを隠す", "Hide Desktop Card"),
        "card_settings" => ("卡片设置…", "カード設定…", "Card Settings…"),
        "loading" => ("正在获取用量…", "使用量を取得中…", "Fetching usage…"),
        "used" => ("已用", "使用済み", "used"),
        "left" => ("剩", "残り", "left"),
        "error" => ("读取失败，打开窗口查看原因", "取得に失敗しました。ウィンドウで詳細を確認", "Couldn't read usage, open the window for details"),
        "five_hour" => ("5 小时", "5時間", "5 hours"),
        "weekly" => ("本周", "今週", "Weekly"),
        "weekly_opus" => ("本周 Opus", "今週 Opus", "Weekly Opus"),
        "weekly_sonnet" => ("本周 Sonnet", "今週 Sonnet", "Weekly Sonnet"),
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
