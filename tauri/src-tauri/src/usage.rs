// 取数：Claude、Codex 和 Gemini 的额度（移植自 macOS 版 Sources/main.swift）
//   Claude: ~/.claude/.credentials.json 里的 OAuth token → api.anthropic.com/api/oauth/usage
//           （Windows / Linux 上 Claude Code 把登录信息存在这个文件；macOS 上在钥匙串，这里不处理）
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits
//   Gemini: Antigravity 在跑时写的 ~/.gemini/antigravity/daemon/hub_<端口>.json → 本机 language server 的额度接口，
//           没在跑时显示上次查到的（缓存在 app 数据目录的 gemini.json）
//   额度来源选「仅本地」时不发请求：Claude 读桌面 app 留下的记录，Codex 读会话日志

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::task::Poll;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// 一家服务。设置里的键按 <前缀>_<小写名字> 来（show_gemini、card_show_gemini、gemini_limit_source），
/// 加一家就是在这里加一行、再写它的取数
pub struct Service {
    pub name: &'static str,
    /// 托盘文字的简写（Cc 56%  Cx 47%  Gm 80%）
    pub short: &'static str,
    /// 有本机日志、有用量统计（stats::Source 里的两家）；也只有这两家新装时必须先选额度来源
    pub stats: bool,
}

/// 显示顺序就是这个顺序
pub const PROVIDERS: [Service; 3] = [
    Service { name: "Claude", short: "Cc", stats: true },
    Service { name: "Codex", short: "Cx", stats: true },
    // Gemini 的对话是加密的，只有额度、没有用量统计
    Service { name: "Gemini", short: "Gm", stats: false },
];

pub fn service(name: &str) -> Option<&'static Service> {
    PROVIDERS.iter().find(|s| s.name == name)
}

/// 一个额度窗口。kind 由界面翻译：five_hour / weekly / weekly_opus / weekly_sonnet / weekly_model（「本周 Fable」，模型名在 model）/ hours / days / 其他原样显示
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct LimitWindow {
    pub kind: String,
    pub amount: Option<u64>, // kind 为 hours / days 时的数字
    pub used: f64,
    pub resets_at: Option<i64>, // Unix 秒
    /// 窗口总长（秒）：5 小时或 7 天；不知道时为 0，不算速度
    pub length: f64,
    /// 用得比时间快（界面和托盘在百分比后面加 ↑）
    #[serde(default)]
    pub fast: bool,
    /// 按现在的速度什么时候用完（Unix 秒）；重置前用不完就是空
    pub runs_out_at: Option<i64>,
    /// 同一家里另一组额度（Gemini 里 Claude、GPT 那组是 third_party，界面上翻成「第三方模型 · 5 小时」）。
    /// 有组的不是这一家的主额度：托盘文字只取没有组的 5 小时和本周
    pub group: Option<String>,
    /// 稳定的标识（Gemini 的 bucketId）：Gemini 的窗口数会变（缺 remainingFraction 的跳过、组跟着套餐和模型增减），
    /// 通知按位置当键会把两个不同的窗口对上。Claude、Codex 没有，照旧按位置
    #[serde(default)]
    pub id: Option<String>,
    /// kind 为 weekly_model 时的模型名（Claude 单独算的某个模型的每周额度，比如 Fable）
    #[serde(default)]
    pub model: Option<String>,
}

impl LimitWindow {
    fn new(kind: &str, amount: Option<u64>, used: f64, resets_at: Option<i64>, length: f64) -> Self {
        let mut w = LimitWindow { kind: kind.into(), amount, used, resets_at, length, fast: false, runs_out_at: None, group: None, id: None, model: None };
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

/// 按 PROVIDERS 的顺序同时查各家。source(名字)：这一家的额度来源，Claude / Codex 是 api / local / off，
/// 空的是新装还没选（什么都不查）；Gemini 是 app / off，空的也算停用（新加的一家，旧设置里没有，默认不查）。
/// off 是停用了这一家（比如退订了）：不查，结果里也没有它，托盘、卡片、通知都不显示；
/// remote_limits：远程机器的日志里最新的一份 Codex 额度（和它的时间）；data_dir：放 Gemini 缓存的目录
pub async fn fetch_all(client: &reqwest::Client, source: impl Fn(&str) -> String, remote_limits: Option<(Value, i64)>, data_dir: Option<PathBuf>) -> Vec<Provider> {
    let futs: Vec<Pin<Box<dyn Future<Output = Option<Provider>> + Send + '_>>> = PROVIDERS
        .iter()
        .map(|s| Box::pin(fetch_one(client, s.name, source(s.name), remote_limits.clone(), data_dir.clone())) as _)
        .collect();
    join_all(futs).await.into_iter().flatten().collect()
}

async fn fetch_one(client: &reqwest::Client, name: &'static str, source: String, remote_limits: Option<(Value, i64)>, data_dir: Option<PathBuf>) -> Option<Provider> {
    match (name, source.as_str()) {
        (_, "off") => None,
        ("Claude", "api") => Some(claude(client).await),
        ("Claude", "local") => Some(claude_local_limits()),
        ("Codex", "api" | "local") => Some(codex(client, source == "local", remote_limits).await),
        ("Gemini", "app") => Some(gemini(data_dir.as_deref()).await),
        ("Gemini", _) => None,
        _ => Some(failed(name, "no_source", None)),
    }
}

/// 几个请求一起等（没有引入 futures 库，自己轮询一遍），结果按原来的顺序
async fn join_all<T>(mut futs: Vec<Pin<Box<dyn Future<Output = T> + Send + '_>>>) -> Vec<T> {
    let mut out: Vec<Option<T>> = futs.iter().map(|_| None).collect();
    std::future::poll_fn(|cx| {
        let mut pending = false;
        for (f, slot) in futs.iter_mut().zip(out.iter_mut()).filter(|(_, s)| s.is_none()) {
            match f.as_mut().poll(cx) {
                Poll::Ready(v) => *slot = Some(v),
                Poll::Pending => pending = true,
            }
        }
        if pending { Poll::Pending } else { Poll::Ready(()) }
    })
    .await;
    out.into_iter().flatten().collect()
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

/// Claude 桌面 app 记下的本周已用比例（秒、百分比）：统计页「按周期」补上 Claude 各周期用到多少
pub fn claude_desktop_weekly_samples() -> Vec<(i64, f64)> {
    claude_desktop_history()
        .into_iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .filter_map(|t| serde_json::from_str::<Value>(&t).ok())
        .flat_map(|j| j["samples"].as_array().cloned().unwrap_or_default())
        .filter_map(|s| Some(((s["t"].as_f64()? / 1000.0) as i64, s["u"]["sd"].as_f64()?)))
        .collect()
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
        return Provider { name: "Claude".into(), plan, windows: claude_windows(&j), ..Default::default() };
    }
    failed("Claude", "claude_expired", None)
}

/// Claude 额度接口的结果 → 额度窗口：先是 five_hour、seven_day 这些顶层的，
/// 再是 limits 里单独算某个模型的每周额度（kind 为 weekly_scoped，比如 Fable：「本周 Fable」）
pub fn claude_windows(j: &Value) -> Vec<LimitWindow> {
    let mut windows = Vec::new();
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
        // 认不出的 key（接口里常有 iguana_necktie 这种内部代号）：没用过就不显示，用过的叫「其他额度」
        let kind = match key.as_str() {
            "five_hour" => "five_hour",
            "seven_day" => "weekly",
            "seven_day_opus" => "weekly_opus",
            "seven_day_sonnet" => "weekly_sonnet",
            _ if util <= 0.0 => continue,
            _ => "other",
        };
        let length = if key == "five_hour" { 5.0 * 3600.0 } else if key.starts_with("seven_day") { 7.0 * 86400.0 } else { 0.0 };
        windows.push(LimitWindow::new(kind, None, util, resets_at, length));
    }
    // 单独算的模型额度：顶层已经有同一个模型的（seven_day_opus 这种）就不重复。
    // 键用模型名，不用位置：这一项有时有、有时没有，后面的不会挪到别人的键上
    for l in j["limits"].as_array().into_iter().flatten().filter(|l| l["kind"] == "weekly_scoped") {
        let Some(name) = l["scope"]["model"]["display_name"].as_str().filter(|s| !s.is_empty()) else { continue };
        let Some(used) = l["percent"].as_f64() else { continue };
        let dup = match name.to_lowercase().as_str() {
            "opus" => "weekly_opus",
            "sonnet" => "weekly_sonnet",
            _ => "",
        };
        if windows.iter().any(|w: &LimitWindow| w.kind == dup || w.model.as_deref() == Some(name)) {
            continue;
        }
        let resets_at = l["resets_at"].as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()).map(|d| d.timestamp());
        let mut w = LimitWindow::new("weekly_model", None, used, resets_at, 7.0 * 86400.0);
        w.model = Some(name.to_string());
        w.id = Some(format!("weekly_model:{name}"));
        windows.push(w);
    }
    windows
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

async fn codex(client: &reqwest::Client, local: bool, remote_limits: Option<(Value, i64)>) -> Provider {
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
    // 「仅本地」，或接口查不到：会话日志里最新的一份 rate_limits（本机和远程机器的都算）
    let logged = match (latest_local_rate_limits(), remote_limits) {
        (Some(a), Some(b)) => Some(if a.1 >= b.1 { a } else { b }),
        (a, b) => a.or(b),
    };
    if let Some((rl, mtime)) = logged {
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

// MARK: - Gemini

/// Antigravity 的 agent（Windows / Linux 上是 Antigravity 的 IDE / CLI）在跑时写的发现文件所在目录
fn gemini_daemon_dir() -> PathBuf {
    home().join(".gemini").join("antigravity").join("daemon")
}

/// 最新的 hub_<端口>.json 里的 HTTP 端口和 csrf token。旧的文件（进程已经没了）请求会失败，退回缓存
fn gemini_hub() -> Option<(u16, String)> {
    let newest = std::fs::read_dir(gemini_daemon_dir())
        .ok()?
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.starts_with("hub_") && n.ends_with(".json")
        })
        .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())?;
    let j: Value = serde_json::from_str(&std::fs::read_to_string(newest.path()).ok()?).ok()?;
    let port = u16::try_from(j["httpPort"].as_u64()?).ok().filter(|p| *p > 0)?;
    let token = j["csrfToken"].as_str().filter(|t| !t.is_empty())?.to_string();
    Some((port, token))
}

/// 调本机 language server 的一个方法（Connect 协议的 JSON）；不是 200 就算没查到。token 只放在请求头里，不记日志
async fn gemini_call(client: &reqwest::Client, port: u16, token: &str, method: &str) -> Option<Value> {
    let resp = client
        .post(format!("http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/{method}"))
        .header("Connect-Protocol-Version", "1")
        .header("X-Codeium-Csrf-Token", token)
        .json(&json!({ "metadata": { "ideName": "antigravity", "extensionName": "antigravity" } }))
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    resp.json().await.ok()
}

/// 重置时间：ISO-8601，偶尔是秒数
fn gemini_time(v: &Value) -> Option<i64> {
    match v {
        Value::String(s) => chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp()).or_else(|| s.parse::<f64>().ok().map(|n| n as i64)),
        Value::Number(n) => n.as_f64().map(|n| n as i64),
        _ => None,
    }
}

/// Gemini 里 Claude、GPT 那组的组名：存的是这个键，界面按语言翻成「第三方模型」
pub const THIRD_PARTY: &str = "third_party";

/// RetrieveUserQuotaSummary 的结果 → 额度窗口（id 是 bucketId，通知拿它当键）。排序固定：
/// 「Gemini Models」组（主额度，不加前缀）的 5 小时、本周，「Claude and GPT models」组（组名存成 third_party，界面上翻成「第三方模型」）的 5 小时、本周，
/// 再是其他组（比如 Gemini 4 Argon 的本周，按组名排）。没有 remainingFraction 的是不知道用了多少：跳过，不当成用完了
pub fn gemini_windows(j: &Value) -> Vec<LimitWindow> {
    let mut found: Vec<((u8, String, u8, u8, String), LimitWindow)> = Vec::new();
    for g in j["response"]["groups"].as_array().into_iter().flatten() {
        let gname = g["displayName"].as_str().unwrap_or_default().to_string();
        let buckets = g["buckets"].as_array().cloned().unwrap_or_default();
        let id = |b: &Value| b["bucketId"].as_str().unwrap_or_default().to_string();
        // 用稳定的 bucketId 认组，组名只是备用（显示名可能改）
        let rank = if buckets.iter().any(|b| matches!(id(b).as_str(), "gemini-5h" | "gemini-weekly")) || gname == "Gemini Models" {
            0
        } else if buckets.iter().any(|b| id(b).starts_with("3p-")) || gname == "Claude and GPT models" {
            1
        } else {
            2
        };
        let group = match rank {
            0 => None,
            1 => Some(THIRD_PARTY.to_string()),
            _ => Some(if gname.is_empty() { "Gemini".into() } else { gname.clone() }),
        };
        for b in &buckets {
            let Some(left) = b["remainingFraction"].as_f64().or_else(|| b["remaining"]["remainingFraction"].as_f64()) else { continue };
            let bid = id(b);
            // 没写 window 时按 bucketId 猜
            let cadence = b["window"].as_str().map(str::to_string).unwrap_or_else(|| {
                if bid.ends_with("5h") { "5h".into() } else if bid.contains("weekly") { "weekly".into() } else { String::new() }
            });
            let (kind, length, order) = match cadence.as_str() {
                "5h" => ("five_hour", 5.0 * 3600.0, 0),
                "weekly" => ("weekly", 7.0 * 86400.0, 1),
                _ => ("other", 0.0, 2),
            };
            let used = ((1.0 - left) * 100.0).clamp(0.0, 100.0);
            let resets_at = gemini_time(&b["resetTime"]).or_else(|| gemini_time(&b["remaining"]["resetTime"]));
            // 同一组同一种窗口有好几个时，常规的那个（gemini-5h、3p-weekly 这种）排前面，托盘取的是它
            let canonical = if matches!(bid.as_str(), "gemini-5h" | "gemini-weekly" | "3p-5h" | "3p-weekly") { 0 } else { 1 };
            let w = LimitWindow { group: group.clone(), id: Some(bid.clone()), ..LimitWindow::new(kind, None, used, resets_at, length) };
            found.push(((rank, if rank == 2 { gname.clone() } else { String::new() }, order, canonical, bid), w));
        }
    }
    found.sort_by(|a, b| a.0.cmp(&b.0));
    found.into_iter().map(|(_, w)| w).collect()
}

/// 上次查到的结果（存在 app 数据目录的 gemini.json）：Antigravity 没在跑时显示这个
#[derive(Serialize, Deserialize)]
pub struct GeminiCache {
    pub at: i64,
    pub plan: Option<String>,
    pub windows: Vec<LimitWindow>,
}

/// 缓存 → 显示的结果：重置时间已经过了的窗口已经重置过，按 0% 显示、不写重置时间。
/// 带着 note，通知就不拿它判断「已重置」（和 Claude 的本地数据一样）
pub fn gemini_cached(c: GeminiCache, now: f64) -> Provider {
    let windows = c
        .windows
        .into_iter()
        .map(|w| {
            let expired = w.resets_at.map(|r| (r as f64) < now).unwrap_or(false);
            let (used, resets_at) = if expired { (0.0, None) } else { (w.used, w.resets_at) };
            // 旧版缓存里这组存的是「Claude/GPT」
            let group = if w.group.as_deref() == Some("Claude/GPT") { Some(THIRD_PARTY.to_string()) } else { w.group.clone() };
            LimitWindow { group, id: w.id.clone(), ..LimitWindow::new(&w.kind, w.amount, used, resets_at, w.length) }
        })
        .collect();
    Provider { name: "Gemini".into(), plan: c.plan, windows, note: Some("gemini_cache".into()), detail: Some(c.at), ..Default::default() }
}

/// 查 Gemini：Antigravity 没在跑（没有发现文件、连不上、不是 200）时退回缓存，没有缓存就报「没在运行」
pub async fn gemini(data_dir: Option<&Path>) -> Provider {
    let cache_path = data_dir.map(|d| d.join("gemini.json"));
    let live = async {
        let (port, token) = gemini_hub()?;
        // 只连本机：不走系统 / 环境变量里的代理，token 也不会发到别处
        let client = reqwest::Client::builder().no_proxy().build().ok()?;
        let (quota, status) = tokio::join!(
            gemini_call(&client, port, &token, "RetrieveUserQuotaSummary"),
            gemini_call(&client, port, &token, "GetUserStatus"),
        );
        let windows = gemini_windows(&quota?);
        let plan = status.and_then(|s| plan_name(s["userStatus"]["planStatus"]["planInfo"]["planName"].as_str()));
        Some((windows, plan))
    }
    .await;
    // 连上了、也是 200，但一个能用的额度都没有：是返回的格式变了，不是没在运行，别拿缓存冒充
    if let Some((_, plan)) = live.as_ref().filter(|(w, _)| w.is_empty()) {
        return Provider { plan: plan.clone(), ..failed("Gemini", "gemini_empty", None) };
    }
    if let Some((windows, plan)) = live {
        if let Some(path) = &cache_path {
            let c = GeminiCache { at: now() as i64, plan: plan.clone(), windows: windows.clone() };
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(path, serde_json::to_string(&c).unwrap_or_default());
        }
        return Provider { name: "Gemini".into(), plan, windows, ..Default::default() };
    }
    match cache_path.and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str::<GeminiCache>(&t).ok()) {
        Some(c) => gemini_cached(c, now()),
        None => failed("Gemini", "gemini_not_running", None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 本机 Gemini.app 的 agent 实际返回的 RetrieveUserQuotaSummary（去掉了说明文字）
    const SAMPLE: &str = r#"{"response":{"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-11-19T07:02:48Z"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-11-12T12:02:48Z"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-11-19T07:02:48Z"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-11-12T12:02:48Z"}]},
      {"displayName":"Gemini 4 Argon","buckets":[
        {"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":1,"resetTime":"2026-11-19T07:02:48Z"}]}]}}"#;

    fn shape(ws: &[LimitWindow]) -> Vec<(Option<&str>, &str)> {
        ws.iter().map(|w| (w.group.as_deref(), w.kind.as_str())).collect()
    }

    #[test]
    fn claude_model_limits() {
        // 实际返回的样子（去掉了别的字段）：Fable 只在 limits 里，顶层没有
        let j: Value = serde_json::from_str(r#"{
          "five_hour":{"utilization":4.0,"resets_at":"2026-11-12T14:19:59.547813+00:00"},
          "seven_day":{"utilization":43.0,"resets_at":"2026-11-15T21:00:00.547833+00:00"},
          "seven_day_opus":null,"iguana_necktie":null,
          "limits":[
            {"kind":"session","group":"session","percent":4,"resets_at":"2026-11-12T14:19:59.547813+00:00","scope":null},
            {"kind":"weekly_all","group":"weekly","percent":43,"resets_at":"2026-11-15T21:00:00.547833+00:00","scope":null},
            {"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"2026-11-15T21:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}"#).unwrap();
        let ws = claude_windows(&j);
        let kinds: Vec<&str> = ws.iter().map(|w| w.kind.as_str()).collect();
        assert_eq!(kinds, vec!["five_hour", "weekly", "weekly_model"]);
        assert_eq!(ws[2].model.as_deref(), Some("Fable"));
        assert_eq!(ws[2].used, 12.0);
        assert_eq!(ws[2].id.as_deref(), Some("weekly_model:Fable"));
        assert_eq!(ws[2].resets_at, Some(1_794_776_400));
        assert_eq!(crate::i18n::window_label("zh", &ws[2]), "本周 Fable");
        assert_eq!(crate::i18n::window_label("en", &ws[2]), "Weekly Fable");
        // 顶层已经有 Opus 的，limits 里的 Opus 不重复
        let j2: Value = serde_json::from_str(r#"{"seven_day_opus":{"utilization":5.0,"resets_at":null},
          "limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]}"#).unwrap();
        assert_eq!(claude_windows(&j2).iter().map(|w| w.kind.as_str()).collect::<Vec<_>>(), vec!["weekly_opus"]);
    }

    #[test]
    fn gemini_order_and_groups() {
        let ws = gemini_windows(&serde_json::from_str(SAMPLE).unwrap());
        assert_eq!(
            shape(&ws),
            vec![(None, "five_hour"), (None, "weekly"), (Some(THIRD_PARTY), "five_hour"), (Some(THIRD_PARTY), "weekly"), (Some("Gemini 4 Argon"), "weekly")]
        );
        assert_eq!(ws[0].length, 18000.0);
        assert_eq!(ws[1].length, 604800.0);
        assert_eq!(ws[1].resets_at, Some(chrono::DateTime::parse_from_rfc3339("2026-11-19T07:02:48Z").unwrap().timestamp()));
        assert!(ws.iter().all(|w| w.used == 0.0));
        // 组的顺序换了，结果一样（显示顺序固定）
        let mut j: Value = serde_json::from_str(SAMPLE).unwrap();
        j["response"]["groups"].as_array_mut().unwrap().reverse();
        assert_eq!(shape(&gemini_windows(&j)), shape(&ws));
    }

    #[test]
    fn gemini_missing_fraction_is_skipped() {
        let mut j: Value = serde_json::from_str(SAMPLE).unwrap();
        // 第三方模型的 5 小时没有 remainingFraction：不知道用了多少，跳过（不是用完了）
        j["response"]["groups"][1]["buckets"][1].as_object_mut().unwrap().remove("remainingFraction");
        // Gemini 的 5 小时换成另一种写法 remaining.remainingFraction
        let b = j["response"]["groups"][0]["buckets"][1].as_object_mut().unwrap();
        b.remove("remainingFraction");
        b.insert("remaining".into(), json!({ "remainingFraction": 0.25 }));
        let ws = gemini_windows(&j);
        assert_eq!(shape(&ws), vec![(None, "five_hour"), (None, "weekly"), (Some(THIRD_PARTY), "weekly"), (Some("Gemini 4 Argon"), "weekly")]);
        assert_eq!(ws[0].used, 75.0);
        // 通知按 bucketId 当键：少了一个窗口，后面的标识不跟着挪
        let ids: Vec<&str> = ws.iter().map(|w| w.id.as_deref().unwrap_or_default()).collect();
        assert_eq!(ids, vec!["gemini-5h", "gemini-weekly", "3p-weekly", "gemini-argon-wtu-weekly"]);
    }

    #[test]
    fn gemini_stale_cache() {
        let now = 1_800_000_000.0;
        let w = |used: f64, resets_at: i64, group: Option<&str>| LimitWindow {
            group: group.map(str::to_string),
            id: group.map(|_| "3p-weekly".to_string()),
            ..LimitWindow::new("weekly", None, used, Some(resets_at), 7.0 * 86400.0)
        };
        let c = GeminiCache { at: 1_799_990_000, plan: Some("Pro".into()), windows: vec![w(40.0, 1_799_999_000, None), w(30.0, 1_800_100_000, Some("Claude/GPT"))] };
        let text = serde_json::to_string(&c).unwrap();
        let p = gemini_cached(serde_json::from_str(&text).unwrap(), now);
        // 重置时间已过：已经重置了，0%、不写重置时间
        assert_eq!((p.windows[0].used, p.windows[0].resets_at), (0.0, None));
        assert_eq!((p.windows[1].used, p.windows[1].resets_at), (30.0, Some(1_800_100_000)));
        assert_eq!(p.windows[1].group.as_deref(), Some(THIRD_PARTY));  // 旧缓存的「Claude/GPT」换成键
        assert_eq!(p.windows[1].id.as_deref(), Some("3p-weekly"));
        assert_eq!((p.note.as_deref(), p.detail, p.plan.as_deref(), p.error.as_deref()), (Some("gemini_cache"), Some(1_799_990_000), Some("Pro"), None));
    }
}
