// 取数：Claude 和 Codex 的额度（移植自 macOS 版 Sources/main.swift）
//   Claude: ~/.claude/.credentials.json 里的 OAuth token → api.anthropic.com/api/oauth/usage
//           （Windows / Linux 上 Claude Code 把登录信息存在这个文件；macOS 上在钥匙串，这里不处理）
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits

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
}

impl LimitWindow {
    pub fn remaining(&self) -> f64 {
        (100.0 - self.used).max(0.0)
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

pub async fn fetch_all(client: &reqwest::Client) -> Vec<Provider> {
    let (c, x) = tokio::join!(claude(client), codex(client));
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
            p.windows.push(LimitWindow { kind: kind.into(), amount: None, used: util, resets_at });
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
    LimitWindow { kind: kind.into(), amount, used, resets_at }
}

async fn codex(client: &reqwest::Client) -> Provider {
    let mut p = Provider { name: "Codex".into(), ..Default::default() };
    let auth = std::fs::read_to_string(codex_home().join("auth.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok());
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
    // 退回：最近一次会话日志里的 rate_limits
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
            p.note = Some("codex_cache".into());
        }
        p.detail = Some(mtime);
    } else if p.windows.is_empty() {
        p.error = Some("codex_no_login".into());
    }
    p
}

/// 最近改动的几个会话文件里，从后往前找第一条带 rate_limits 的记录；返回记录和文件修改时间
fn latest_local_rate_limits() -> Option<(Value, i64)> {
    let mut files = Vec::new();
    collect_jsonl(&codex_home().join("sessions"), &mut files);
    files.sort_by(|a, b| b.1.cmp(&a.1));
    for (path, mtime) in files.into_iter().take(5) {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        for line in text.lines().rev().filter(|l| l.contains("\"rate_limits\"")) {
            let Ok(obj) = serde_json::from_str::<Value>(line) else { continue };
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
