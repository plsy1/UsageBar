// 取数：Claude 和 Codex 的额度（移植自 macOS 版 Sources/main.swift）
//   Claude: ~/.claude/.credentials.json 里的 OAuth token → api.anthropic.com/api/oauth/usage
//           （Windows / Linux 上 Claude Code 把登录信息存在这个文件；macOS 上在钥匙串，这里不处理）
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits
//   额度来源选「仅本地」时不发请求：Claude 读桌面 app 留下的记录，Codex 读会话日志

use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 一个额度窗口。kind 由界面翻译：five_hour / weekly / weekly_opus / weekly_sonnet / hours / days / 其他原样显示
#[derive(Serialize, Clone, Debug)]
pub struct LimitWindow {
    pub kind: String,
    pub amount: Option<u64>, // kind 为 hours / days 时的数字
    pub used: f64,
    pub resets_at: Option<i64>, // Unix 秒
    /// 窗口总长（秒）：5 小时或 7 天；不知道时为 0，不算速度
    pub length: f64,
    /// 用得比时间快（界面和托盘在百分比后面加 ↑）
    pub fast: bool,
    /// 按现在的速度什么时候用完（Unix 秒）；重置前用不完就是空
    pub runs_out_at: Option<i64>,
}

impl LimitWindow {
    fn new(kind: &str, amount: Option<u64>, used: f64, resets_at: Option<i64>, length: f64) -> Self {
        let mut w = LimitWindow { kind: kind.into(), amount, used, resets_at, length, fast: false, runs_out_at: None };
        w.update_pace(now());
        w
    }

    pub fn remaining(&self) -> f64 {
        (100.0 - self.used).max(0.0)
    }

    /// 这个窗口已经过去的比例（0~1）
    fn elapsed(&self, now: f64) -> Option<f64> {
        let r = self.resets_at? as f64;
        (self.length > 0.0).then(|| (1.0 - (r - now) / self.length).clamp(0.0, 1.0))
    }

    /// 算 fast 和 runs_out_at（和 macOS 版一样）：窗口刚开始的一成时间不算，样本太少
    pub fn update_pace(&mut self, now: f64) {
        self.fast = false;
        self.runs_out_at = None;
        let Some(e) = self.elapsed(now).filter(|e| *e >= 0.1) else { return };
        if self.used >= 100.0 {
            return;
        }
        let u = self.used / 100.0;
        // 已用的比例明显超过已过去的比例
        self.fast = u - e >= 0.05 && u > e * 1.15;
        if self.used > 0.0 {
            let spent = self.length * e;
            let t = now + (100.0 - self.used) / (self.used / spent);
            if let Some(r) = self.resets_at {
                self.runs_out_at = ((t as i64) < r).then_some(t as i64);
            }
        }
    }
}

/// error / note 是给界面翻译的 key，detail 是附带的数字（HTTP 状态码、数据时间）
#[derive(Serialize, Clone, Debug, Default)]
pub struct Provider {
    pub name: String,
    pub plan: Option<String>,
    pub windows: Vec<LimitWindow>,
    pub error: Option<String>,
    pub note: Option<String>,
    pub detail: Option<i64>,
    /// Codex 的额度重置（OpenAI 送的「立即重置 5 小时和本周额度」）
    pub resets: Option<ResetCredits>,
}

/// 可用的重置次数，和每次的到期时间（Unix 秒，从早到晚；详情没拿到时为空）
#[derive(Serialize, Clone, Debug, Default)]
pub struct ResetCredits {
    pub count: u64,
    pub expiries: Vec<i64>,
}

impl Provider {
    /// 各窗口里最紧的那个
    pub fn binding(&self) -> Option<&LimitWindow> {
        self.windows.iter().min_by(|a, b| a.remaining().total_cmp(&b.remaining()))
    }
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

/// 接口给的套餐名是小写的（team、plus），显示成 Team、Plus
fn plan_name(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    Some(
        raw.split(|c| c == '_' || c == '-' || c == ' ')
            .filter(|w| !w.is_empty())
            .map(|w| {
                let mut c = w.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            })
            .collect::<Vec<_>>()
            .join(" "),
    )
}

fn failed(name: &str, key: &str, detail: Option<i64>) -> Provider {
    Provider { name: name.into(), error: Some(key.into()), detail, ..Default::default() }
}

/// claude_local / codex_local：额度来源选了「仅本地」
pub async fn fetch_all(client: &reqwest::Client, claude_local: bool, codex_local: bool) -> Vec<Provider> {
    let c = async { if claude_local { claude_local_limits() } else { claude(client).await } };
    let (c, x) = tokio::join!(c, codex(client, codex_local));
    vec![c, x]
}

// MARK: - Claude

const CLAUDE_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const CLAUDE_TOKEN_URLS: [&str; 2] =
    ["https://platform.claude.com/v1/oauth/token", "https://console.anthropic.com/v1/oauth/token"];

fn claude_creds_path() -> PathBuf {
    home().join(".claude").join(".credentials.json")
}

/// 用 refresh token 换新的 access token，并写回文件（和 Claude Code 自己的做法一致）
async fn claude_refresh(client: &reqwest::Client, creds: &mut Value, path: &Path) -> bool {
    let Some(rt) = creds["claudeAiOauth"]["refreshToken"].as_str().map(str::to_owned) else { return false };
    let body = json!({ "grant_type": "refresh_token", "refresh_token": rt, "client_id": CLAUDE_CLIENT_ID });
    for url in CLAUDE_TOKEN_URLS {
        let Ok(resp) = client.post(url).json(&body).timeout(Duration::from_secs(15)).send().await else { continue };
        if !resp.status().is_success() {
            continue;
        }
        let Ok(j) = resp.json::<Value>().await else { continue };
        let Some(at) = j["access_token"].as_str() else { continue };
        let oauth = &mut creds["claudeAiOauth"];
        oauth["accessToken"] = json!(at);
        if let Some(new_rt) = j["refresh_token"].as_str() {
            oauth["refreshToken"] = json!(new_rt);
        }
        if let Some(exp) = j["expires_in"].as_f64() {
            oauth["expiresAt"] = json!(((now() + exp) * 1000.0) as i64);
        }
        // 覆盖写入保留原文件权限（Claude Code 建的是 600）
        let _ = std::fs::write(path, creds.to_string());
        return true;
    }
    false
}

/// Claude 桌面 app 查过用量后留下的采样（5 小时、本周已用的百分比）可能在的位置。
/// Windows 上商店版的 app 数据在 Packages 里
fn claude_desktop_history() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(dir) = dirs::config_dir() {
        out.push(dir.join("Claude").join("plan-usage-history.json"));
    }
    #[cfg(windows)]
    if let Some(local) = dirs::data_local_dir() {
        if let Ok(entries) = std::fs::read_dir(local.join("Packages")) {
            for e in entries.flatten().filter(|e| e.file_name().to_string_lossy().starts_with("Claude")) {
                out.push(e.path().join("LocalCache").join("Roaming").join("Claude").join("plan-usage-history.json"));
            }
        }
    }
    out
}

/// 「仅本地」：读 Claude 桌面 app 的最近一条采样，不发请求。只在 app 查看用量时才写，可能是很久以前的；没有重置时间
fn claude_local_limits() -> Provider {
    let newest = claude_desktop_history()
        .into_iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .filter_map(|t| serde_json::from_str::<Value>(&t).ok())
        .filter_map(|j| j["samples"].as_array()?.iter().max_by(|a, b| a["t"].as_f64().unwrap_or(0.0).total_cmp(&b["t"].as_f64().unwrap_or(0.0))).cloned())
        .max_by(|a, b| a["t"].as_f64().unwrap_or(0.0).total_cmp(&b["t"].as_f64().unwrap_or(0.0)));
    let Some((at, usage)) = newest.and_then(|s| Some((s["t"].as_f64()? / 1000.0, s["u"].clone()))) else {
        return failed("Claude", "claude_local_none", None);
    };
    let age = now() - at;
    let mut p = Provider { name: "Claude".into(), note: Some("claude_local".into()), detail: Some(at as i64), ..Default::default() };
    // 过了一个窗口的长度，那时的数肯定已经重置过了，不再显示
    if let Some(fh) = usage["fh"].as_f64().filter(|_| age < 5.0 * 3600.0) {
        p.windows.push(LimitWindow::new("five_hour", None, fh, None, 5.0 * 3600.0));
    }
    if let Some(sd) = usage["sd"].as_f64().filter(|_| age < 7.0 * 86400.0) {
        p.windows.push(LimitWindow::new("weekly", None, sd, None, 7.0 * 86400.0));
    }
    if p.windows.is_empty() {
        p.note = None;
        p.error = Some("claude_local_stale".into());
    }
    p
}

async fn claude(client: &reqwest::Client) -> Provider {
    let path = claude_creds_path();
    let Some(mut creds) = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
    else {
        return failed("Claude", "claude_no_login", None);
    };
    let plan = plan_name(creds["claudeAiOauth"]["subscriptionType"].as_str());
    let expires = creds["claudeAiOauth"]["expiresAt"].as_f64().unwrap_or(0.0) / 1000.0;
    let mut refreshed = false;
    if expires < now() + 60.0 {
        refreshed = claude_refresh(client, &mut creds, &path).await;
        if !refreshed {
            return Provider { plan, ..failed("Claude", "claude_expired", None) };
        }
    }

    for attempt in 0..2 {
        let token = creds["claudeAiOauth"]["accessToken"].as_str().unwrap_or_default().to_owned();
        let resp = client
            .get("https://api.anthropic.com/api/oauth/usage")
            .bearer_auth(token)
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("User-Agent", "claude-code/2.1")
            .timeout(Duration::from_secs(15))
            .send()
            .await;
        let Ok(resp) = resp else { return Provider { plan, ..failed("Claude", "network", None) } };
        let status = resp.status().as_u16();
        if status == 401 && attempt == 0 && !refreshed && claude_refresh(client, &mut creds, &path).await {
            refreshed = true;
            continue;
        }
        if status != 200 {
            let key = if status == 401 { "claude_expired" } else { "http" };
            return Provider { plan, ..failed("Claude", key, Some(status as i64)) };
        }
        let Ok(j) = resp.json::<Value>().await else { return Provider { plan, ..failed("Claude", "network", None) } };
        let mut p = Provider { name: "Claude".into(), plan, ..Default::default() };
        let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"];
        let mut keys: Vec<String> = order.iter().filter(|k| !j[**k].is_null()).map(|k| k.to_string()).collect();
        if let Some(obj) = j.as_object() {
            let mut rest: Vec<String> = obj.keys().filter(|k| !order.contains(&k.as_str())).cloned().collect();
            rest.sort();
            keys.extend(rest);
        }
        for key in keys {
            let w = &j[&key];
            let Some(util) = w["utilization"].as_f64() else { continue };
            let resets_at = w["resets_at"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                .map(|d| d.timestamp());
            let kind = match key.as_str() {
                "five_hour" => "five_hour",
                "seven_day" => "weekly",
                "seven_day_opus" => "weekly_opus",
                "seven_day_sonnet" => "weekly_sonnet",
                other => other,
            };
            let length = if key == "five_hour" { 5.0 * 3600.0 } else if key.starts_with("seven_day") { 7.0 * 86400.0 } else { 0.0 };
            p.windows.push(LimitWindow::new(kind, None, util, resets_at, length));
        }
        return p;
    }
    failed("Claude", "claude_expired", None)
}

// MARK: - Codex

fn codex_home() -> PathBuf {
    home().join(".codex")
}

fn codex_window(seconds: f64, used: f64, resets_at: Option<i64>) -> LimitWindow {
    let (kind, amount) = if seconds < 6.0 * 3600.0 {
        ("hours", Some((seconds / 3600.0).round() as u64))
    } else if (6.0 * 86400.0..=8.0 * 86400.0).contains(&seconds) {
        ("weekly", None)
    } else {
        ("days", Some((seconds / 86400.0).round() as u64))
    };
    LimitWindow::new(kind, amount, used, resets_at, seconds)
}

async fn codex(client: &reqwest::Client, local: bool) -> Provider {
    let mut p = Provider { name: "Codex".into(), ..Default::default() };
    let auth = if local {
        None
    } else {
        std::fs::read_to_string(codex_home().join("auth.json")).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
    };
    if let Some(at) = auth.as_ref().and_then(|a| a["tokens"]["access_token"].as_str()) {
        let mut req = client
            .get("https://chatgpt.com/backend-api/wham/usage")
            .bearer_auth(at)
            .header("User-Agent", "codex-cli")
            .timeout(Duration::from_secs(15));
        if let Some(aid) = auth.as_ref().and_then(|a| a["tokens"]["account_id"].as_str()) {
            req = req.header("ChatGPT-Account-Id", aid);
        }
        match req.send().await {
            Ok(resp) if resp.status().as_u16() == 200 => {
                if let Ok(j) = resp.json::<Value>().await {
                    p.plan = plan_name(j["plan_type"].as_str());
                    for key in ["primary_window", "secondary_window"] {
                        let w = &j["rate_limit"][key];
                        let Some(used) = w["used_percent"].as_f64() else { continue };
                        let secs = w["limit_window_seconds"].as_f64().unwrap_or(0.0);
                        p.windows.push(codex_window(secs, used, w["reset_at"].as_f64().map(|v| v as i64)));
                    }
                    // 有可用的重置次数才去查详情（只读，拿每次的到期时间）
                    let count = j["rate_limit_reset_credits"]["available_count"].as_u64().unwrap_or(0);
                    if count > 0 {
                        let mut detail = client
                            .get("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
                            .bearer_auth(at)
                            .header("User-Agent", "codex-cli")
                            .timeout(Duration::from_secs(15));
                        if let Some(aid) = auth.as_ref().and_then(|a| a["tokens"]["account_id"].as_str()) {
                            detail = detail.header("ChatGPT-Account-Id", aid);
                        }
                        let mut expiries: Vec<i64> = match detail.send().await {
                            Ok(r) if r.status().as_u16() == 200 => r.json::<Value>().await.ok()
                                .and_then(|d| d["credits"].as_array().cloned())
                                .unwrap_or_default()
                                .iter()
                                .filter(|c| c["status"].as_str() == Some("available"))
                                .filter_map(|c| c["expires_at"].as_str())
                                .filter_map(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                                .map(|t| t.timestamp())
                                .collect(),
                            _ => vec![],
                        };
                        expiries.sort();
                        p.resets = Some(ResetCredits { count, expiries });
                    }
                    if !p.windows.is_empty() {
                        return p;
                    }
                }
            }
            Ok(resp) => {
                let status = resp.status().as_u16();
                p.note = Some(if status == 401 { "codex_cache_expired" } else { "codex_cache_http" }.into());
                p.detail = Some(status as i64);
            }
            Err(_) => p.note = Some("codex_cache_http".into()),
        }
    }
    // 「仅本地」，或接口查不到：最近一次会话日志里的 rate_limits
    if let Some((rl, mtime)) = latest_local_rate_limits() {
        if p.plan.is_none() {
            p.plan = plan_name(rl["plan_type"].as_str());
        }
        for key in ["primary", "secondary"] {
            let w = &rl[key];
            let Some(used) = w["used_percent"].as_f64() else { continue };
            let reset = w["resets_at"].as_f64().map(|v| v as i64);
            // 已经过了重置时间的窗口，用量视为归零
            let expired = reset.map(|r| (r as f64) < now()).unwrap_or(false);
            let secs = w["window_minutes"].as_f64().unwrap_or(0.0) * 60.0;
            p.windows.push(codex_window(secs, if expired { 0.0 } else { used }, if expired { None } else { reset }));
        }
        if p.note.is_none() {
            p.note = Some(if local { "codex_logs" } else { "codex_cache" }.into());
        }
        p.detail = Some(mtime);
    } else if p.windows.is_empty() {
        p.error = Some(if local { "codex_logs_none" } else { "codex_no_login" }.into());
    }
    p
}

/// Codex 账号统计（OpenAI 服务端按账号汇总，包含其他电脑和云端任务）：每天的 tokens 和累计总数。
/// 按 UTC 日期分天，一般晚一两天
#[derive(Serialize, Clone, Debug, Default)]
pub struct CodexAccount {
    pub daily: std::collections::BTreeMap<String, i64>, // UTC 日期 "yyyy-MM-dd" → 那天的 tokens（含缓存）
    pub lifetime: i64,
}

/// 查账号统计（只读）
pub async fn codex_account(client: &reqwest::Client) -> Option<CodexAccount> {
    let auth: Value = serde_json::from_str(&std::fs::read_to_string(codex_home().join("auth.json")).ok()?).ok()?;
    let at = auth["tokens"]["access_token"].as_str()?;
    let mut req = client
        .get("https://chatgpt.com/backend-api/wham/profiles/me")
        .bearer_auth(at)
        .header("User-Agent", "codex-cli")
        .timeout(Duration::from_secs(15));
    if let Some(aid) = auth["tokens"]["account_id"].as_str() {
        req = req.header("ChatGPT-Account-Id", aid);
    }
    let resp = req.send().await.ok().filter(|r| r.status().as_u16() == 200)?;
    let j: Value = resp.json().await.ok()?;
    let stats = j["stats"].as_object()?;
    let daily = stats
        .get("daily_usage_buckets")
        .and_then(Value::as_array)
        .map(|bs| bs.iter().filter_map(|b| Some((b["start_date"].as_str()?.to_string(), b["tokens"].as_i64()?))).collect())
        .unwrap_or_default();
    Some(CodexAccount { daily, lifetime: stats.get("lifetime_tokens").and_then(Value::as_i64).unwrap_or(0) })
}

/// 最近改动的几个会话文件里，从后往前找第一条带 rate_limits 的记录；返回记录和文件修改时间
fn latest_local_rate_limits() -> Option<(Value, i64)> {
    let mut files = Vec::new();
    collect_jsonl(&codex_home().join("sessions"), &mut files);
    files.sort_by(|a, b| b.1.cmp(&a.1));
    for (path, mtime) in files.into_iter().take(5) {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        for line in text.lines().rev().filter(|l| l.contains("\"rate_limits\"")) {
            // 有的编辑器 / PowerShell 写文件会带 BOM，去掉再解析
            let Ok(obj) = serde_json::from_str::<Value>(line.trim_start_matches('\u{feff}')) else { continue };
            let rl = obj["payload"]["rate_limits"].clone();
            if rl.is_object() {
                return Some((rl, mtime));
            }
        }
    }
    None
}

fn collect_jsonl(dir: &Path, out: &mut Vec<(PathBuf, i64)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let path = e.path();
        if path.is_dir() {
            collect_jsonl(&path, out);
        } else if path.extension().map(|x| x == "jsonl").unwrap_or(false) {
            let mtime = e
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            out.push((path, mtime));
        }
    }
}
