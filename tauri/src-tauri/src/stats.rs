// 用量统计（移植自 macOS 版 Sources/Stats.swift）：从本机会话记录算 token 用量和按 API 价格估算的成本
//   Claude: ~/.claude/projects/**/*.jsonl 里 assistant 消息的 message.usage
//   Codex : ~/.codex/sessions/**/*.jsonl（和 archived_sessions）里 token_count 事件的 last_token_usage
//   耗时  : 两边日志都不记，按时间戳估算：请求发出（上一条用户消息 / 工具结果）到回复最后一段写入；
//           首字取第一段内容写入的时间（日志要等一整段生成完才写，所以偏大）
//   价格  : models.dev/api.json（每天更新一次，缓存在调用方给的缓存目录）
//   存储  : 解析结果存进 SQLite 数据库（db.rs），每个文件只接着解析新追加的部分

#![allow(dead_code)]

use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Utc};
use memchr::memmem;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

// MARK: - 数据

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Source {
    Claude,
    Codex,
}

/// 时间存成 Unix 毫秒（界面里直接 new Date(ms)）
mod ms {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(t: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(t.timestamp_millis())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let v = i64::deserialize(d)?;
        DateTime::from_timestamp_millis(v).ok_or_else(|| serde::de::Error::custom("bad time"))
    }
}

mod opt_ms {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};
    pub fn serialize<S: Serializer>(t: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match t {
            Some(t) => s.serialize_some(&t.timestamp_millis()),
            None => s.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        Ok(Option::<i64>::deserialize(d)?.and_then(DateTime::from_timestamp_millis))
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct UsageRecord {
    pub id: String,
    #[serde(with = "ms")]
    pub time: DateTime<Utc>,
    pub source: Source,
    pub model: String,
    pub input: i64, // 不含缓存的新输入
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    #[serde(default)]
    pub cache_write_1h: i64, // cache_write 里属于 1 小时缓存的部分（Claude 才有），单价是输入的 2 倍
    #[serde(default)]
    pub cost: Option<f64>,
    #[serde(default)]
    pub duration: Option<f64>, // 估算的总耗时（秒）
    #[serde(default)]
    pub first_token: Option<f64>, // 估算的首字时间（秒）：第一段内容写入日志的时间
    #[serde(default = "ok_status")]
    pub status: i64, // 失败的请求（Claude Code 会记下来）：429、401 等
    #[serde(default)]
    pub project: Option<String>, // 会话的工作目录（日志里的 cwd）
    #[serde(default)]
    pub host: Option<String>, // 从哪台远程机器读来的（SSH）；本机的为空
}

fn ok_status() -> i64 {
    200
}

impl UsageRecord {
    fn new(id: String, time: DateTime<Utc>, source: Source, model: String) -> Self {
        UsageRecord {
            id,
            time,
            source,
            model,
            input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            cache_write_1h: 0,
            cost: None,
            duration: None,
            first_token: None,
            status: 200,
            project: None,
            host: None,
        }
    }

    pub fn tokens(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }

    pub fn failed(&self) -> bool {
        self.status != 200
    }

    pub fn hit_rate(&self) -> Option<f64> {
        let prompt = self.input + self.cache_read + self.cache_write;
        (prompt > 0).then(|| self.cache_read as f64 / prompt as f64)
    }

    /// 输出太少时耗时几乎全是等待，算出来的速度没意义
    pub const MIN_SPEED_OUTPUT: i64 = 200;

    /// 输出速度（token/秒），按总耗时算（思考也算在输出里，扣掉首字反而偏高）
    pub fn speed(&self) -> Option<f64> {
        self.duration
            .filter(|&d| d > 0.05 && self.output >= Self::MIN_SPEED_OUTPUT)
            .map(|d| self.output as f64 / d)
    }
}

// MARK: - 价格（models.dev）

#[derive(Clone, Debug, PartialEq)]
pub struct Price {
    pub input: f64,
    pub output: f64,
    pub cache_read: Option<f64>,
    pub cache_write: Option<f64>,
    /// 上下文超过 size 后的单价（长上下文加价），按 size 从小到大
    pub tiers: Vec<(i64, Price)>,
}

/// 各部分的成本（美元），请求详情里显示
#[derive(Serialize, Clone, Copy, Debug, Default, PartialEq)]
pub struct Breakdown {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
}

impl Breakdown {
    pub fn total(&self) -> f64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
}

#[derive(Clone, Debug, Default)]
pub struct Pricing {
    table: HashMap<String, HashMap<String, Price>>,
    /// 本地价格表缓存的更新时间（设置里显示）
    pub updated_at: Option<SystemTime>,
    /// 最近一次下载是否失败（失败时继续用旧缓存）
    pub download_failed: bool,
}

pub const PRICING_FILE: &str = "models-dev.json";
const PROVIDERS: [&str; 2] = ["anthropic", "openai"];

/// 读缓存；没有缓存、超过一天或 force 时重新下载。只想读本地缓存（启动时先出数）用 Pricing::load_cached
pub async fn load_pricing(client: &reqwest::Client, cache_dir: &Path, force: bool) -> Pricing {
    let path = cache_dir.join(PRICING_FILE);
    let stale = mtime(&path)
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .is_none_or(|age| age.as_secs() > 86400);
    let mut failed = false;
    if force || stale {
        match download(client).await {
            Some(fresh) => {
                let _ = write_atomic(&path, &fresh);
            }
            None => failed = true,
        }
    }
    let mut p = Pricing::load_cached(cache_dir);
    p.download_failed = failed;
    p
}

/// 只留两家的 cost 字段，缓存从 6MB 缩到几十 KB
async fn download(client: &reqwest::Client) -> Option<Vec<u8>> {
    let resp = client
        .get("https://models.dev/api.json")
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await
        .ok()?;
    if resp.status().as_u16() != 200 {
        return None;
    }
    let all: Value = serde_json::from_slice(&resp.bytes().await.ok()?).ok()?;
    let mut subset = serde_json::Map::new();
    for p in PROVIDERS {
        let Some(models) = all[p]["models"].as_object() else { continue };
        let costs: serde_json::Map<String, Value> = models
            .iter()
            .filter_map(|(k, m)| m.get("cost").map(|c| (k.clone(), c.clone())))
            .collect();
        subset.insert(p.to_string(), Value::Object(costs));
    }
    serde_json::to_vec(&Value::Object(subset)).ok()
}

impl Pricing {
    /// 只读本地缓存，不碰网络
    pub fn load_cached(cache_dir: &Path) -> Pricing {
        let path = cache_dir.join(PRICING_FILE);
        let mut p = Pricing::default();
        let Some(json) = fs::read(&path).ok().and_then(|d| serde_json::from_slice::<Value>(&d).ok()) else {
            return p;
        };
        let Some(obj) = json.as_object() else { return p };
        for (provider, models) in obj {
            let Some(models) = models.as_object() else { continue };
            let t = models.iter().filter_map(|(k, c)| Some((k.clone(), price(c)?))).collect();
            p.table.insert(provider.clone(), t);
        }
        p.updated_at = mtime(&path);
        p
    }

    pub fn is_empty(&self) -> bool {
        self.table.is_empty()
    }

    pub fn price(&self, source: Source, model: &str) -> Option<&Price> {
        let models = self.table.get(if source == Source::Claude { "anthropic" } else { "openai" })?;
        // 带日期后缀的型号（如 -20261001）去掉后缀再找一次
        models.get(model).or_else(|| models.get(strip_date_suffix(model)))
    }

    pub fn cost(&self, r: &UsageRecord) -> Option<f64> {
        self.breakdown(r).map(|b| b.total())
    }

    pub fn breakdown(&self, r: &UsageRecord) -> Option<Breakdown> {
        let mut p = self.price(r.source, &r.model)?;
        let prompt = r.input + r.cache_read + r.cache_write;
        if let Some((_, tp)) = p.tiers.iter().rev().find(|(size, _)| prompt > *size) {
            p = tp;
        }
        // models.dev 的 cache_write 是 5 分钟缓存的价格；1 小时缓存按 Anthropic 的规则算输入价的 2 倍
        let write5m = (r.cache_write - r.cache_write_1h) as f64;
        let m = 1_000_000.0;
        Some(Breakdown {
            input: r.input as f64 * p.input / m,
            output: r.output as f64 * p.output / m,
            cache_read: r.cache_read as f64 * p.cache_read.unwrap_or(p.input) / m,
            cache_write: (write5m * p.cache_write.unwrap_or(p.input) + r.cache_write_1h as f64 * p.input * 2.0) / m,
        })
    }

    /// 给每条记录填上 cost
    pub fn apply(&self, records: &mut [UsageRecord]) {
        for r in records {
            r.cost = self.cost(r);
        }
    }
}

fn price(c: &Value) -> Option<Price> {
    let mut p = Price {
        input: c.get("input")?.as_f64()?,
        output: c.get("output")?.as_f64()?,
        cache_read: c.get("cache_read").and_then(Value::as_f64),
        cache_write: c.get("cache_write").and_then(Value::as_f64),
        tiers: vec![],
    };
    for t in c.get("tiers").and_then(Value::as_array).into_iter().flatten() {
        if let (Some(size), Some(tp)) = (t.get("tier").and_then(|x| x.get("size")).and_then(int), price(t)) {
            p.tiers.push((size, tp));
        }
    }
    p.tiers.sort_by_key(|(s, _)| *s);
    Some(p)
}

/// 去掉结尾的 -yyyymmdd
fn strip_date_suffix(model: &str) -> &str {
    let b = model.as_bytes();
    let n = b.len();
    if n >= 9 && b[n - 9] == b'-' && b[n - 8..].iter().all(u8::is_ascii_digit) {
        &model[..n - 9]
    } else {
        model
    }
}

// MARK: - 读会话记录

/// 一个日志文件的解析进度（存在数据库的 files 表里）。文件变了只接着解析后面新写的部分（会话日志只会往后追加）
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Entry {
    pub offset: u64,      // 已经解析到的字节位置（总在一行末尾）
    pub tail: u64,        // offset 之前一小段内容的指纹：对不上说明文件被改写过，得从头读
    pub tail_length: u64,
    claude: ClaudeState,
    pub codex: CodexState,
    /// 最后几十条记录：Claude 的一个回复分几行写，接着读时后面几段要更新前面那条的耗时
    #[serde(default)]
    recent: Vec<UsageRecord>,
}

/// 解析读到 offset 时的状态，接着读时要用
#[derive(Serialize, Deserialize, Clone)]
struct ClaudeState {
    #[serde(with = "opt_ms")]
    sent_at: Option<DateTime<Utc>>,
    model: String,
}

impl Default for ClaudeState {
    fn default() -> Self {
        ClaudeState { sent_at: None, model: "—".into() }
    }
}

#[derive(Serialize, Deserialize, Clone)]
pub struct CodexState {
    /// 这次解析见到的周额度周期（重置时间整分钟的秒数、已用比例），调用方存进库后清掉；不随进度保存
    #[serde(skip)]
    pub cycles: Vec<(i64, f64)>,
    model: String,
    #[serde(default)]
    cwd: Option<String>,
    last_total: i64,
    #[serde(with = "opt_ms")]
    input_at: Option<DateTime<Utc>>,
    #[serde(with = "opt_ms")]
    start: Option<DateTime<Utc>>,
    #[serde(with = "opt_ms")]
    first: Option<DateTime<Utc>>,
    #[serde(with = "opt_ms")]
    end: Option<DateTime<Utc>>,
}

impl Default for CodexState {
    fn default() -> Self {
        CodexState { cycles: vec![], model: "codex".into(), cwd: None, last_total: -1, input_at: None, start: None, first: None, end: None }
    }
}

/// 日志目录（相对用户目录）和来源；Windows 上用户目录是 %USERPROFILE%
pub const LOG_DIRS: [(&str, Source); 3] = [
    (".claude/projects", Source::Claude),
    (".codex/sessions", Source::Codex),
    (".codex/archived_sessions", Source::Codex),
];

/// 递归找 .jsonl（不跟进目录的符号链接）
pub fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let Ok(ft) = e.file_type() else { continue };
        let p = e.path();
        if ft.is_dir() {
            walk(&p, out);
        } else if p.extension().is_some_and(|x| x == "jsonl") {
            out.push(p);
        }
    }
}

pub fn nanos(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_nanos().min(i64::MAX as u128) as i64,
        Err(e) => -(e.duration().as_nanos().min(i64::MAX as u128) as i64),
    }
}

fn mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// 先写临时文件再改名，写到一半退出不会留下坏文件
fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

/// 能不能接着上次的位置读：文件没变小，offset 前面那一小段也没变
pub fn can_resume(e: &Entry, path: &Path, size: u64) -> bool {
    if e.offset == 0 || size < e.offset {
        return false;
    }
    let Ok(mut f) = fs::File::open(path) else { return false };
    let mut buf = vec![0u8; e.tail_length as usize];
    f.seek(SeekFrom::Start(e.offset - e.tail_length)).is_ok() && f.read_exact(&mut buf).is_ok() && fnv(&buf) == e.tail
}

/// 从 entry.offset 读到文件末尾最后一个完整行（写到一半的行留到下次），返回新的和更新过的记录
pub fn parse(path: &Path, src: Source, e: &mut Entry) -> Vec<UsageRecord> {
    let data = if e.offset == 0 {
        match fs::read(path) {
            Ok(d) => d,
            Err(_) => return vec![],
        }
    } else {
        let mut d = vec![];
        let Ok(mut f) = fs::File::open(path) else { return vec![] };
        if f.seek(SeekFrom::Start(e.offset)).is_err() || f.read_to_end(&mut d).is_err() {
            return vec![];
        }
        d
    };
    let Some(last_newline) = memchr::memrchr(b'\n', &data) else { return vec![] };
    let chunk = &data[..=last_newline];
    let mut out = match src {
        Source::Claude => std::mem::take(&mut e.recent),
        Source::Codex => vec![],
    };
    match src {
        Source::Claude => parse_claude(chunk, &mut e.claude, &mut out),
        Source::Codex => parse_codex(chunk, &mut e.codex, &mut out),
    }
    if src == Source::Claude {
        e.recent = out[out.len().saturating_sub(50)..].to_vec();
    }
    e.offset += chunk.len() as u64;
    e.tail_length = chunk.len().min(64) as u64;
    e.tail = fnv(&chunk[chunk.len() - e.tail_length as usize..]);
    out
}

/// 远程传回来的一段（已在远程过滤过）：只解析 Codex，进度由调用方按原文件的字节数记
pub fn parse_codex_chunk(chunk: &[u8], e: &mut Entry) -> Vec<UsageRecord> {
    let mut out = vec![];
    parse_codex(chunk, &mut e.codex, &mut out);
    out
}

/// 重置时间常是 05:59:59.x：差几秒到整分钟就进位，同一个周期的键才一致（秒）
pub fn cycle_key(t: i64) -> i64 {
    (t + 5) / 60 * 60
}

/// FNV-1a：内容指纹（和 Swift 版同一算法）
pub fn fnv(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &b in bytes {
        h = (h ^ b as u64).wrapping_mul(0x100000001b3);
    }
    h
}

/// 同一请求可能出现在多个文件里（续接的会话会带上旧记录），按 id 去重，留输出最多的那条。结果按时间倒序
pub fn dedupe(all: impl IntoIterator<Item = UsageRecord>, since: DateTime<Utc>) -> Vec<UsageRecord> {
    let mut by_id: HashMap<String, UsageRecord> = HashMap::new();
    for r in all {
        if r.time < since {
            continue;
        }
        if by_id.get(&r.id).is_some_and(|old| old.output >= r.output) {
            continue;
        }
        by_id.insert(r.id.clone(), r);
    }
    let mut v: Vec<UsageRecord> = by_id.into_values().collect();
    v.sort_by_key(|r| std::cmp::Reverse(r.time));
    v
}

/// 按行切开，跳过空行
fn lines(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    data.split(|&b| b == b'\n').filter(|l| !l.is_empty())
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    memmem::find(hay, needle).is_some()
}

/// ISO 8601 时间，和 Swift 版一样要求带小数秒；精度截到毫秒
pub fn parse_iso(s: &str) -> Option<DateTime<Utc>> {
    if s.as_bytes().get(19) != Some(&b'.') {
        return None;
    }
    let t = DateTime::parse_from_rfc3339(s).ok()?;
    DateTime::from_timestamp_millis(t.timestamp_millis())
}

/// 引号里的值：line 里 key 后面到下一个引号为止
fn quoted_after<'a>(line: &'a [u8], key: &[u8]) -> Option<&'a str> {
    let start = memmem::find(line, key)? + key.len();
    let len = memchr::memchr(b'"', &line[start..])?;
    std::str::from_utf8(&line[start..start + len]).ok()
}

/// 一行里第一个 "timestamp"（顶层那个，在消息内容之前），不用解析整行 JSON
fn timestamp(line: &[u8]) -> Option<DateTime<Utc>> {
    quoted_after(line, b"\"timestamp\":\"").and_then(parse_iso)
}

/// Codex 日志一行是 {"timestamp":…,"type":…,"payload":{"type":"…"：取出 payload 的类型，不解析整行
fn payload_type(line: &[u8]) -> Option<&str> {
    quoted_after(line, b"\"payload\":{\"type\":\"")
}

/// 合理的耗时才要：负数（时间戳乱序）或超过半小时的多半是续接会话里拼起来的旧记录
fn span(from: Option<DateTime<Utc>>, to: DateTime<Utc>) -> Option<f64> {
    let d = (to - from?).num_milliseconds() as f64 / 1000.0;
    (d > 0.0 && d < 1800.0).then_some(d)
}

/// JSON 里的整数（和 Swift 的 `as? Int` 一样，整数值的浮点也算）
fn int(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_f64().filter(|f| f.fract() == 0.0).map(|f| f as i64))
}

fn int_or_zero(v: &Value, key: &str) -> i64 {
    v.get(key).and_then(int).unwrap_or(0)
}

/// 没有 id 的消息给个不会重复的 id（Swift 版用随机 UUID）
fn random_id() -> String {
    static N: AtomicU64 = AtomicU64::new(0);
    let t = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    format!("noid-{t:x}-{:x}-{:x}", std::process::id(), N.fetch_add(1, Ordering::Relaxed))
}

/// Claude Code 失败请求的状态码：有 apiErrorStatus 就用，没有按错误类型对应
fn claude_status(o: &Value) -> i64 {
    if let Some(s) = o.get("apiErrorStatus").and_then(int) {
        return s;
    }
    match o.get("error").and_then(Value::as_str) {
        Some("authentication_failed") => 401,
        Some("rate_limit") => 429,
        Some("invalid_request") => 400,
        Some("overloaded") => 529,
        _ => 500,
    }
}

/// 解析一段完整的行，接在 out 后面；state 带着上一段读完时的状态
fn parse_claude(data: &[u8], state: &mut ClaudeState, out: &mut Vec<UsageRecord>) {
    let usage_key = memmem::Finder::new(b"\"usage\"");
    let sent_keys = [memmem::Finder::new(b"\"type\":\"user\""), memmem::Finder::new(b"\"type\":\"api-request\"")];
    // 一个回复分成几行写（每段内容一行），记下它在 out 里的位置；接着读时后面几段可能落在新的一段里
    let mut index: HashMap<String, usize> = HashMap::new();
    for (i, r) in out.iter().enumerate() {
        index.entry(r.id.clone()).or_insert(i);
    }
    let mut sent_at = state.sent_at; // 最近一次发出请求：用户消息、工具结果，或新版的 api-request
    let mut model = std::mem::take(&mut state.model); // 失败的请求没有模型名，用前面最近的那个
    for line in lines(data) {
        // 大部分行是对话内容：先按字节粗筛，用户消息和工具结果只取时间戳，不解析整行
        if usage_key.find(line).is_none() {
            if sent_keys.iter().any(|k| k.find(line).is_some()) {
                if let Some(t) = timestamp(line) {
                    sent_at = Some(t);
                }
            }
            continue;
        }
        let Ok(o) = serde_json::from_slice::<Value>(line) else { continue };
        let Some(ts) = o.get("timestamp").and_then(Value::as_str).and_then(parse_iso) else { continue };
        let kind = o.get("type").and_then(Value::as_str);
        if kind != Some("assistant") {
            if matches!(kind, Some("user" | "api-request")) {
                sent_at = Some(ts);
            }
            continue;
        }
        let Some(msg) = o.get("message").filter(|m| m.is_object()) else { continue };
        let Some(u) = msg.get("usage").filter(|u| u.is_object()) else { continue };
        let id = format!(
            "{}:{}",
            msg.get("id").and_then(Value::as_str).map_or_else(random_id, String::from),
            o.get("requestId").and_then(Value::as_str).unwrap_or("")
        );
        if let Some(&i) = index.get(&id) {
            // 后面几段写入时更新结束时间
            if let Some(d) = span(sent_at, ts) {
                out[i].duration = Some(d);
            }
            continue;
        }
        let name = msg.get("model").and_then(Value::as_str).map_or_else(|| model.clone(), String::from);
        if name == "<synthetic>" {
            // Claude Code 自己插的消息；isApiErrorMessage 的是失败的请求，其他（比如中断提示）不算
            if o.get("isApiErrorMessage").and_then(Value::as_bool) != Some(true) {
                continue;
            }
            let mut r = UsageRecord::new(id.clone(), ts, Source::Claude, model.clone());
            r.status = claude_status(&o);
            r.duration = span(sent_at, ts);
            r.project = o.get("cwd").and_then(Value::as_str).map(String::from);
            index.insert(id, out.len());
            out.push(r);
            continue;
        }
        model = name.clone();
        let mut r = UsageRecord::new(id.clone(), ts, Source::Claude, name);
        r.input = int_or_zero(u, "input_tokens");
        r.output = int_or_zero(u, "output_tokens");
        r.cache_read = int_or_zero(u, "cache_read_input_tokens");
        r.cache_write = int_or_zero(u, "cache_creation_input_tokens");
        let w1h = u.get("cache_creation").map_or(0, |c| int_or_zero(c, "ephemeral_1h_input_tokens"));
        r.cache_write_1h = r.cache_write.min(w1h);
        r.duration = span(sent_at, ts);
        r.first_token = r.duration;
        r.project = o.get("cwd").and_then(Value::as_str).map(String::from);
        index.insert(id, out.len());
        out.push(r);
    }
    state.sent_at = sent_at;
    state.model = model;
}

fn parse_codex(data: &[u8], state: &mut CodexState, out: &mut Vec<UsageRecord>) {
    let parse_keys = [memmem::Finder::new(b"\"token_count\""), memmem::Finder::new(b"\"turn_context\"")];
    let role_user = memmem::Finder::new(b"\"role\":\"user\"");
    let usage_record = memmem::Finder::new(b"\"type\":\"token_usage_record\"");
    const OUTPUTS: [&str; 6] =
        ["reasoning", "message", "function_call", "custom_tool_call", "web_search_call", "local_shell_call"];
    // 耗时：一次回复从「最近一次输入」（用户消息、工具结果）开始，到它最后一项内容写入为止。
    // token_count 要等工具执行完才写，不能当结束时间
    let s = state;
    for line in lines(data) {
        // turn_context 的 payload 第一个字段不是 type，取不到类型，单独认
        let kind = payload_type(line).unwrap_or("");
        if !parse_keys.iter().any(|k| k.find(line).is_some()) || kind == "message" {
            // 只看类型和时间，不解析整行（工具输出往往很长）
            let Some(ts) = timestamp(line) else { continue };
            if kind.ends_with("_call_output")
                || kind == "task_started"
                || kind == "user_message"
                || (kind == "message" && role_user.find(line).is_some())
            {
                s.input_at = Some(ts);
            } else if OUTPUTS.contains(&kind) {
                if s.start.is_none() {
                    s.start = s.input_at;
                    s.first = Some(ts);
                }
                s.end = Some(ts);
            } else if kind == "token_usage_record" || usage_record.find(line).is_some() {
                s.end = Some(ts);
            }
            continue;
        }
        let Ok(o) = serde_json::from_slice::<Value>(line) else { continue };
        let Some(p) = o.get("payload").filter(|p| p.is_object()) else { continue };
        if o.get("type").and_then(Value::as_str) == Some("turn_context") {
            if let Some(m) = p.get("model").and_then(Value::as_str) {
                s.model = m.to_string();
            }
            if let Some(c) = p.get("cwd").and_then(Value::as_str) {
                s.cwd = Some(c.to_string());
            }
            continue;
        }
        if p.get("type").and_then(Value::as_str) != Some("token_count") {
            continue;
        }
        // 每次回复后都记着当时的额度：周额度的重置时间和已用比例记成周期（统计页「按周期」用）
        if let Some(rl) = p.get("rate_limits").and_then(Value::as_object) {
            for w in rl.values() {
                let minutes = w.get("window_minutes").and_then(Value::as_f64).unwrap_or(0.0);
                if let (true, Some(reset), Some(used)) =
                    ((8640.0..=11520.0).contains(&minutes), w.get("resets_at").and_then(Value::as_f64), w.get("used_percent").and_then(Value::as_f64))
                {
                    s.cycles.push((cycle_key(reset as i64), used));
                }
            }
        }
        let Some(info) = p.get("info").filter(|i| i.is_object()) else { continue };
        let Some(last) = info.get("last_token_usage").filter(|l| l.is_object()) else { continue };
        let Some(total) = info.get("total_token_usage").and_then(|t| t.get("total_tokens")).and_then(int) else {
            continue;
        };
        if total == s.last_total {
            continue; // 只更新了额度信息的重复事件
        }
        let Some(ts_string) = o.get("timestamp").and_then(Value::as_str) else { continue };
        let Some(ts) = parse_iso(ts_string) else { continue };
        s.last_total = total;
        let cached = int_or_zero(last, "cached_input_tokens");
        let mut r = UsageRecord::new(format!("{ts_string}|{total}"), ts, Source::Codex, s.model.clone());
        r.input = (int_or_zero(last, "input_tokens") - cached).max(0);
        r.output = int_or_zero(last, "output_tokens");
        r.cache_read = cached;
        r.cache_write = int_or_zero(last, "cache_write_input_tokens");
        if let Some(end) = s.end {
            r.duration = span(s.start, end);
        }
        if let Some(first) = s.first {
            r.first_token = span(s.start, first);
        }
        r.project = s.cwd.clone();
        s.start = None;
        s.first = None;
        s.end = None;
        out.push(r);
    }
}

// MARK: - 汇总

/// 统计的时间范围。Cycle：周额度上次重置以来（每家按自己的重置时间算）；Custom：自选起止
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatsRange {
    #[serde(rename = "today")]
    Today,
    #[serde(rename = "cycle")]
    Cycle,
    #[serde(rename = "24h")]
    Day,
    #[serde(rename = "7d")]
    Week,
    #[serde(rename = "14d")]
    Fortnight,
    #[serde(rename = "30d")]
    Month,
    #[serde(rename = "all")]
    All,
    #[serde(rename = "custom")]
    Custom,
}

impl StatsRange {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "today" => Self::Today,
            "cycle" => Self::Cycle,
            "24h" => Self::Day,
            "7d" => Self::Week,
            "14d" => Self::Fortnight,
            "30d" => Self::Month,
            "all" => Self::All,
            "custom" => Self::Custom,
            _ => return None,
        })
    }

    /// 固定的起点（本地时区的零点）；Cycle / All / Custom 的起点另算，这里按今天
    pub fn preset_start(self) -> DateTime<Utc> {
        let today = Local::now().date_naive();
        match self {
            Self::Day => Utc::now() - Duration::days(1),
            Self::Week => start_of_day(today - Duration::days(6)),
            Self::Fortnight => start_of_day(today - Duration::days(13)),
            Self::Month => start_of_day(today - Duration::days(29)),
            _ => start_of_day(today),
        }
    }
}

/// 本地时区某天的零点（夏令时跳过零点时取当天最早的时刻）
fn start_of_day(d: NaiveDate) -> DateTime<Utc> {
    let midnight = d.and_hms_opt(0, 0, 0).unwrap();
    match Local.from_local_datetime(&midnight).earliest() {
        Some(t) => t.with_timezone(&Utc),
        // 零点不存在：往后找第一个存在的整点
        None => (1..24)
            .find_map(|h| Local.from_local_datetime(&d.and_hms_opt(h, 0, 0).unwrap()).earliest())
            .map_or_else(|| Utc.from_utc_datetime(&midnight), |t| t.with_timezone(&Utc)),
    }
}

/// 周额度的重置时间往前推 7 天就是当前周期的起点。
/// 接口给的重置时间常是 05:59:59.x 这种：差几秒到整分钟就进位，否则舍去秒数
pub fn cycle_start(reset: DateTime<Utc>) -> DateTime<Utc> {
    let ms = reset.timestamp_millis() + 5000;
    let minute = ms.div_euclid(60_000) * 60_000;
    DateTime::from_timestamp_millis(minute).unwrap_or(reset) - Duration::days(7)
}

/// 用量卡片的起点：range 是 "today" / "7d" / "cycle"；cycle 不知道重置时间时按最近 7 天
pub fn card_start(range: &str, cycle: Option<DateTime<Utc>>) -> DateTime<Utc> {
    match range {
        "cycle" => cycle.unwrap_or_else(|| StatsRange::Week.preset_start()),
        "7d" => StatsRange::Week.preset_start(),
        _ => StatsRange::Today.preset_start(),
    }
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct Summary {
    pub cost: f64,
    pub requests: i64,
    pub tokens: i64,
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub hit_rate: Option<f64>,
}

impl Summary {
    /// 失败的请求不算（只在请求明细里列出来）
    pub fn new<'a>(rs: impl IntoIterator<Item = &'a UsageRecord>) -> Self {
        let mut s = Summary::default();
        for r in rs.into_iter().filter(|r| !r.failed()) {
            s.cost += r.cost.unwrap_or(0.0);
            s.requests += 1;
            s.tokens += r.tokens();
            s.input += r.input;
            s.output += r.output;
            s.cache_read += r.cache_read;
            s.cache_write += r.cache_write;
        }
        let prompt = s.input + s.cache_read + s.cache_write;
        s.hit_rate = (prompt > 0).then(|| s.cache_read as f64 / prompt as f64);
        s
    }
}

/// since 以后（含）某一家（None 是两家合计）的汇总；records 要先用 Pricing::apply 填好 cost
pub fn summarize(records: &[UsageRecord], source: Option<Source>, since: DateTime<Utc>) -> Summary {
    Summary::new(records.iter().filter(|r| r.time >= since && source.is_none_or(|s| r.source == s)))
}

/// 用量卡片的走势图：每个时段的成本。hourly：今天按小时（到现在这一小时）；否则从 since 那天起按天
pub fn cost_trend(records: &[UsageRecord], source: Source, since: DateTime<Utc>, hourly: bool) -> Vec<f64> {
    use chrono::{Local, Timelike};
    let now = Local::now();
    let today = now.date_naive();
    let first = if hourly { today } else { since.with_timezone(&Local).date_naive() };
    let n = if hourly { now.hour() as usize + 1 } else { (today - first).num_days().max(0) as usize + 1 };
    let mut out = vec![0.0; n];
    for r in records.iter().filter(|r| r.source == source && r.time >= since && !r.failed()) {
        let t = r.time.with_timezone(&Local);
        let i = if hourly {
            if t.date_naive() != today {
                continue;
            }
            t.hour() as usize
        } else {
            (t.date_naive() - first).num_days() as usize
        };
        if let Some(v) = out.get_mut(i) {
            *v += r.cost.unwrap_or(0.0);
        }
    }
    out
}

/// 没有价格的型号（成本没算进去），排查用
pub fn unpriced_models(records: &[UsageRecord]) -> Vec<String> {
    let set: HashSet<&str> = records.iter().filter(|r| r.cost.is_none()).map(|r| r.model.as_str()).collect();
    let mut v: Vec<String> = set.into_iter().map(String::from).collect();
    v.sort();
    v
}

// MARK: - 测试

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(s: &str) -> DateTime<Utc> {
        parse_iso(s).unwrap()
    }

    #[test]
    fn iso_requires_fraction() {
        assert!(parse_iso("2026-10-31T12:00:00Z").is_none());
        assert_eq!(ts("2026-10-31T12:00:00.250Z").timestamp_millis() % 1000, 250);
        assert_eq!(ts("2026-10-31T21:00:00.000+09:00"), ts("2026-10-31T12:00:00.000Z"));
    }

    #[test]
    fn fnv_known_value() {
        assert_eq!(fnv(b""), 0xcbf29ce484222325);
        assert_eq!(fnv(b"a"), 0xaf63dc4c8601ec8c);
    }

    #[test]
    fn date_suffix() {
        assert_eq!(strip_date_suffix("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
        assert_eq!(strip_date_suffix("gpt-5"), "gpt-5");
        assert_eq!(strip_date_suffix("x-2025100a"), "x-2025100a");
    }

    #[test]
    fn cycle_rounding() {
        let r = ts("2026-11-07T05:59:59.500Z");
        assert_eq!(cycle_start(r), ts("2026-10-31T06:00:00.000Z"));
        let r = ts("2026-11-07T05:59:30.000Z");
        assert_eq!(cycle_start(r), ts("2026-10-31T05:59:00.000Z"));
    }

    fn pricing() -> Pricing {
        let json = r#"{"anthropic":{"claude-x":{"input":3,"output":15,"cache_read":0.3,"cache_write":3.75,
            "tiers":[{"tier":{"type":"context","size":200000},"input":6,"output":22.5}]}},
            "openai":{"gpt-5":{"input":1.25,"output":10,"cache_read":0.125}}}"#;
        let mut p = Pricing::default();
        let v: Value = serde_json::from_str(json).unwrap();
        for (prov, models) in v.as_object().unwrap() {
            let t = models.as_object().unwrap().iter().filter_map(|(k, c)| Some((k.clone(), price(c)?))).collect();
            p.table.insert(prov.clone(), t);
        }
        p
    }

    #[test]
    fn cost_rules() {
        let p = pricing();
        let mut r = UsageRecord::new("a".into(), Utc::now(), Source::Claude, "claude-x-20260101".into());
        r.input = 1_000_000;
        r.output = 1_000_000;
        r.cache_write = 1_000_000;
        r.cache_write_1h = 400_000;
        // 3 + 15 + 0.6*3.75 + 0.4*3*2，prompt 2M 超过 200K → 长上下文价：6 + 22.5 + 0.6*6 + 0.4*6*2
        let b = p.breakdown(&r).unwrap();
        assert!((b.total() - (6.0 + 22.5 + 3.6 + 4.8)).abs() < 1e-9);
        r.input = 1000;
        r.cache_write = 0;
        r.cache_write_1h = 0;
        r.cache_read = 1000;
        let b = p.breakdown(&r).unwrap();
        assert!((b.total() - (0.003 + 15.0 + 0.0003)).abs() < 1e-9);
        let mut c = UsageRecord::new("b".into(), Utc::now(), Source::Codex, "gpt-5".into());
        c.cache_write = 1_000_000; // 没有 cache_write 价：按输入价
        assert!((p.cost(&c).unwrap() - 1.25).abs() < 1e-9);
        c.model = "unknown".into();
        assert!(p.cost(&c).is_none());
    }

    #[test]
    fn claude_parse_and_dedupe() {
        let log = br#"{"type":"user","timestamp":"2026-10-31T12:00:00.000Z","message":{"role":"user"}}
{"type":"assistant","timestamp":"2026-10-31T12:00:02.000Z","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":20}}}}
{"type":"assistant","timestamp":"2026-10-31T12:00:04.000Z","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"assistant","timestamp":"2026-10-31T12:00:05.000Z","isApiErrorMessage":true,"error":"rate_limit","message":{"id":"m2","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
{"type":"assistant","timestamp":"2026-10-31T12:00:06.000Z","message":{"id":"m3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
"#;
        let mut st = ClaudeState::default();
        let mut out = vec![];
        parse_claude(log, &mut st, &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].id, "m1:r1");
        assert_eq!(out[0].cache_write_1h, 20);
        assert_eq!(out[0].duration, Some(4.0));
        assert_eq!(out[0].first_token, Some(2.0));
        assert_eq!(out[1].status, 429);
        assert_eq!(out[1].model, "claude-x");
        assert_eq!(st.model, "claude-x");

        let mut dup = out[0].clone();
        dup.output = 9;
        let all = dedupe(out.iter().cloned().chain([dup]), DateTime::<Utc>::MIN_UTC);
        assert_eq!(all.len(), 2);
        assert_eq!(all.iter().find(|r| r.id == "m1:r1").unwrap().output, 9);
        let s = Summary::new(&all);
        assert_eq!((s.requests, s.tokens), (1, 10 + 9 + 100 + 50));
    }

    #[test]
    fn codex_parse() {
        let log = br#"{"timestamp":"2026-10-31T12:00:00.000Z","type":"turn_context","payload":{"cwd":"/","model":"gpt-5"}}
{"timestamp":"2026-10-31T12:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}
{"timestamp":"2026-10-31T12:00:03.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}
{"timestamp":"2026-10-31T12:00:06.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}
{"timestamp":"2026-10-31T12:00:07.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300},"last_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":100}}}}
{"timestamp":"2026-10-31T12:00:08.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300},"last_token_usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":100}}}}
"#;
        let mut st = CodexState::default();
        let mut out = vec![];
        parse_codex(log, &mut st, &mut out);
        assert_eq!(out.len(), 1);
        let r = &out[0];
        assert_eq!(r.id, "2026-10-31T12:00:07.000Z|300");
        assert_eq!((r.model.as_str(), r.input, r.cache_read, r.output), ("gpt-5", 50, 150, 100));
        assert_eq!(r.duration, Some(5.0));
        assert_eq!(r.first_token, Some(2.0));
        assert_eq!(st.last_total, 300);
    }

    #[test]
    fn incremental_matches_full() {
        // 分两段解析和一次解析结果一样（一个回复跨两段时更新耗时）
        let log: &[u8] = br#"{"type":"user","timestamp":"2026-10-31T12:00:00.000Z"}
{"type":"assistant","timestamp":"2026-10-31T12:00:02.000Z","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":1,"output_tokens":2}}}
{"type":"assistant","timestamp":"2026-10-31T12:00:09.000Z","requestId":"r1","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":1,"output_tokens":2}}}
"#;
        let (mut a, mut b) = (ClaudeState::default(), ClaudeState::default());
        let (mut full, mut part) = (vec![], vec![]);
        parse_claude(log, &mut a, &mut full);
        let cut = log.iter().enumerate().filter(|(_, &c)| c == b'\n').nth(1).unwrap().0 + 1;
        parse_claude(&log[..cut], &mut b, &mut part);
        parse_claude(&log[cut..], &mut b, &mut part);
        assert_eq!(full, part);
        assert_eq!(full[0].duration, Some(9.0));
    }
}
