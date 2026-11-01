// 用量统计页要的数据：按界面选的时间范围、应用、机器从库里取记录，算好汇总、走势图、热力图、分组表格和
// 请求明细的一页再交给界面（界面不用收几万条原始记录）。和 macOS 版 StatsView 的算法一致

use crate::db::{Overview, Store};
use crate::stats::{Breakdown, Pricing, Source, StatsRange, Summary, UsageRecord};
use crate::usage::CodexAccount;
use chrono::{DateTime, Duration, Local, NaiveDate, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub const PAGE_SIZE: usize = 50;

#[derive(Deserialize, Debug, Clone)]
#[serde(default)]
pub struct Query {
    pub range: String,             // today / cycle / 24h / 7d / 14d / 30d / all / custom
    pub custom_start: Option<i64>, // 毫秒
    pub custom_end: Option<i64>,   // 毫秒；没有就是到现在
    pub source: String,            // all / Claude / Codex
    pub hidden: Vec<String>,       // 不看的 Codex 机器（"" 是本机）
    pub status: i64,               // 请求明细只看某个状态码；0 是全部
    pub page: usize,
    pub tab: String,               // apps / models / projects / log：只算当前标签页的表
    pub show_all: bool,            // 分组表格：行多时是否全部列出
    /// 各家周额度当前周期的起点（毫秒，「重置以来」用）
    pub cycle: HashMap<String, i64>,
}

impl Default for Query {
    fn default() -> Self {
        Query {
            range: "today".into(),
            custom_start: None,
            custom_end: None,
            source: "all".into(),
            hidden: vec![],
            status: 0,
            page: 0,
            tab: "log".into(),
            show_all: false,
            cycle: HashMap::new(),
        }
    }
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct Bucket {
    pub t: i64, // 时段开始（毫秒）
    pub tokens: i64,
    pub requests: i64,
    pub cost: f64,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct Group {
    pub id: String,
    pub title: String,
    pub detail: Option<String>, // 按项目：完整路径（悬停显示）
    pub apps: String,           // 用到的应用
    pub summary: Summary,
    pub priced: bool,
    pub failed: i64,
    pub success_rate: f64,
    pub speed: Option<f64>,
    pub first_token: Option<f64>, // 中位数
}

#[derive(Serialize, Clone, Debug)]
pub struct LogRow {
    #[serde(flatten)]
    pub r: UsageRecord,
    pub hit_rate: Option<f64>,
    pub speed: Option<f64>,
    pub breakdown: Option<Breakdown>,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct HeatDay {
    pub day: String,
    pub tokens: i64,
    pub requests: i64,
    pub cost: f64,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct View {
    pub summary: Summary,
    pub starts: BTreeMap<String, i64>, // 每家的起点（界面写「Claude 自 10/26 06:00 起」）
    pub end: i64,
    pub hourly: bool,
    pub buckets: Vec<Bucket>,
    pub heat: Vec<HeatDay>,
    pub counts: BTreeMap<String, usize>, // 各标签页的行数
    pub groups: Vec<Group>,              // 当前标签页（apps / models / projects）的行
    pub group_total: usize,
    pub log: Vec<LogRow>,
    pub log_total: usize,
    pub statuses: Vec<i64>,
    pub page: usize,
    pub pages: usize,
    pub machines: Vec<String>, // "" 是本机
    pub overview: Overview,
    /// Codex · 服务端数据统计（所选范围里），单独显示，不和日志记录混在一起算；没查到或没选 Codex 时为空
    pub codex_account: Option<AccountRange>,
}

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
pub struct AccountRange {
    pub tokens: i64,
    pub days: i64,      // 范围里服务端已出数的天数
    pub peak: i64,      // 最多的一天
    pub pending: bool,  // 范围里还有服务端没出数的日子
    pub lifetime: i64,
    pub last_day: Option<String>, // 服务端最新有数据的那天
}

/// 服务端统计在 from..=to 里的数（按 UTC 日，和本机记录无关）
pub fn account_range(acc: &CodexAccount, from: DateTime<Utc>, to: DateTime<Utc>) -> AccountRange {
    let last = acc.daily.keys().max().cloned();
    let mut r = AccountRange { lifetime: acc.lifetime, last_day: last.clone(), ..Default::default() };
    let last = last.unwrap_or_default();
    let mut day = from.date_naive();
    while day <= to.date_naive() {
        let key = day.format("%Y-%m-%d").to_string();
        if key > last {
            r.pending = true;
        } else {
            let n = acc.daily.get(&key).copied().unwrap_or(0);
            r.tokens += n;
            r.days += 1;
            r.peak = r.peak.max(n);
        }
        day = day.succ_opt().unwrap_or(day + Duration::days(1));
    }
    r
}

fn local_day_start(t: DateTime<Utc>) -> DateTime<Utc> {
    let d = t.with_timezone(&Local).date_naive();
    day_start(d)
}

fn day_start(d: NaiveDate) -> DateTime<Utc> {
    Local
        .from_local_datetime(&d.and_hms_opt(0, 0, 0).unwrap())
        .earliest()
        .map(|t| t.with_timezone(&Utc))
        .unwrap_or_else(|| Utc.from_utc_datetime(&d.and_hms_opt(0, 0, 0).unwrap()))
}

fn hour_start(t: DateTime<Utc>) -> DateTime<Utc> {
    let l = t.with_timezone(&Local);
    l.with_minute(0).and_then(|x| x.with_second(0)).and_then(|x| x.with_nanosecond(0)).map(|x| x.with_timezone(&Utc)).unwrap_or(t)
}

fn median(mut xs: Vec<f64>) -> Option<f64> {
    if xs.is_empty() {
        return None;
    }
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let m = xs.len() / 2;
    Some(if xs.len() % 2 == 1 { xs[m] } else { (xs[m - 1] + xs[m]) / 2.0 })
}

/// 按 key 分组汇总。失败的请求也分进去，只用来算成功率
fn grouped<'a>(rows: &[&'a UsageRecord], key: impl Fn(&UsageRecord) -> String) -> Vec<(String, Vec<&'a UsageRecord>)> {
    let mut map: HashMap<String, Vec<&'a UsageRecord>> = HashMap::new();
    for r in rows {
        map.entry(key(r)).or_default().push(r);
    }
    map.into_iter().collect()
}

fn group(id: String, title: String, rs: &[&UsageRecord]) -> Option<Group> {
    let ok: Vec<&UsageRecord> = rs.iter().copied().filter(|r| !r.failed()).collect();
    if ok.is_empty() {
        return None;
    }
    // 速度按总输出 ÷ 总耗时算，不是各请求速度的平均（那样会被几个输出少却很快的请求拉高）
    let timed: Vec<&&UsageRecord> = ok.iter().filter(|r| r.speed().is_some()).collect();
    let time: f64 = timed.iter().map(|r| r.duration.unwrap_or(0.0)).sum();
    let out: i64 = timed.iter().map(|r| r.output).sum();
    let s = Summary::new(ok.iter().copied());
    let failed = (rs.len() - ok.len()) as i64;
    Some(Group {
        id,
        title,
        detail: None,
        apps: String::new(),
        success_rate: s.requests as f64 / (s.requests + failed).max(1) as f64,
        summary: s,
        priced: ok.iter().any(|r| r.cost.is_some()),
        failed,
        speed: (time > 0.0).then(|| out as f64 / time),
        first_token: median(ok.iter().filter_map(|r| r.first_token).collect()),
    })
}

fn sort_groups(v: &mut [Group]) {
    v.sort_by(|a, b| {
        b.summary.cost.partial_cmp(&a.summary.cost).unwrap().then(b.summary.tokens.cmp(&a.summary.tokens))
    });
}

fn src_name(s: Source) -> &'static str {
    if s == Source::Claude { "Claude" } else { "Codex" }
}

/// 按应用：有远程机器的记录时，Codex 按机器分行
fn app_groups(rows: &[&UsageRecord]) -> Vec<Group> {
    let remote = rows.iter().any(|r| r.host.is_some());
    let mut v: Vec<Group> = grouped(rows, |r| {
        if r.source == Source::Codex && remote { format!("Codex|{}", r.host.clone().unwrap_or_default()) } else { src_name(r.source).into() }
    })
    .into_iter()
    .filter_map(|(k, rs)| {
        let title = match k.split_once('|') {
            Some((_, "")) => "Codex · @local".to_string(), // 界面换成「本机」
            Some((_, h)) => format!("Codex · {h}"),
            None => if k == "Claude" { "Claude Code".into() } else { "Codex".into() },
        };
        let mut g = group(k, title, &rs)?;
        g.apps = src_name(rs[0].source).into();
        Some(g)
    })
    .collect();
    sort_groups(&mut v);
    v
}

fn model_groups(rows: &[&UsageRecord]) -> Vec<Group> {
    let mut v: Vec<Group> = grouped(rows, |r| format!("{}|{}", src_name(r.source), r.model))
        .into_iter()
        .filter_map(|(k, rs)| {
            let mut g = group(k, rs[0].model.clone(), &rs)?;
            g.apps = src_name(rs[0].source).into();
            Some(g)
        })
        .collect();
    sort_groups(&mut v);
    v
}

/// 按项目：按会话的工作目录分组；远程机器上的同名目录分开算。显示完整路径（只写最后一级的话 worktree 会有一堆同名的）
fn project_groups(rows: &[&UsageRecord]) -> Vec<Group> {
    let home = dirs::home_dir().map(|h| h.to_string_lossy().into_owned()).unwrap_or_default();
    let mut v: Vec<Group> = grouped(rows, |r| format!("{}|{}", r.host.clone().unwrap_or_default(), r.project.clone().unwrap_or_default()))
        .into_iter()
        .filter_map(|(k, rs)| {
            let (host, path) = k.split_once('|').unwrap_or(("", ""));
            let shown = if host.is_empty() && !home.is_empty() && path.starts_with(&home) { format!("~{}", &path[home.len()..]) } else { path.to_string() };
            let title = if path.is_empty() { "@unknown".to_string() } else { shown } + &if host.is_empty() { String::new() } else { format!(" · {host}") };
            let mut g = group(k.clone(), title, &rs)?;
            g.detail = (!path.is_empty()).then(|| path.to_string());
            let apps: BTreeSet<&str> = rs.iter().filter(|r| !r.failed()).map(|r| src_name(r.source)).collect();
            g.apps = apps.into_iter().collect::<Vec<_>>().join(", ");
            Some(g)
        })
        .collect();
    sort_groups(&mut v);
    v
}

/// 走势图：两天以内按小时，更长按天；没有用量的时段补 0，曲线才连续
fn buckets(rows: &[&UsageRecord], start: DateTime<Utc>, end: DateTime<Utc>, hourly: bool) -> Vec<Bucket> {
    let key = |t: DateTime<Utc>| if hourly { hour_start(t) } else { local_day_start(t) };
    let mut sums: HashMap<i64, Bucket> = HashMap::new();
    for r in rows.iter().filter(|r| !r.failed()) {
        let k = key(r.time).timestamp_millis();
        let b = sums.entry(k).or_insert(Bucket { t: k, ..Default::default() });
        b.tokens += r.tokens();
        b.requests += 1;
        b.cost += r.cost.unwrap_or(0.0);
    }
    // 起点最多往前两年，防止没有数据时从很久以前开始补齐
    let first = start.max(end - Duration::days(730));
    let mut out = vec![];
    let mut t = key(first);
    while t <= end {
        let k = t.timestamp_millis();
        out.push(sums.remove(&k).unwrap_or(Bucket { t: k, ..Default::default() }));
        t = if hourly {
            t + Duration::hours(1)
        } else {
            let d = t.with_timezone(&Local).date_naive() + Duration::days(1);
            day_start(d)
        };
    }
    out
}

pub fn compute(store: &Store, pricing: &Pricing, q: &Query, remote_hosts: &[String], account: Option<&CodexAccount>) -> View {
    let overview = store.overview();
    let now = Utc::now();
    let sources: Vec<Source> = match q.source.as_str() {
        "Claude" => vec![Source::Claude],
        "Codex" => vec![Source::Codex],
        _ => vec![Source::Claude, Source::Codex],
    };
    let range = StatsRange::parse(&q.range).unwrap_or(StatsRange::Today);
    let since = |s: Source| -> DateTime<Utc> {
        match range {
            StatsRange::Cycle => q.cycle.get(src_name(s)).and_then(|&ms| DateTime::from_timestamp_millis(ms)).unwrap_or_else(|| StatsRange::Week.preset_start()),
            StatsRange::All => overview.earliest.and_then(DateTime::from_timestamp_millis).unwrap_or_else(|| StatsRange::Month.preset_start()),
            StatsRange::Custom => q.custom_start.and_then(DateTime::from_timestamp_millis).unwrap_or_else(|| StatsRange::Today.preset_start()),
            r => r.preset_start(),
        }
    };
    let end = match (range, q.custom_end) {
        (StatsRange::Custom, Some(e)) => DateTime::from_timestamp_millis(e).unwrap_or(now),
        _ => now,
    };
    let starts: BTreeMap<String, i64> = sources.iter().map(|&s| (src_name(s).to_string(), since(s).timestamp_millis())).collect();
    let earliest = sources.iter().map(|&s| since(s)).min().unwrap_or(now);
    let hourly = (end - earliest).num_seconds() <= 2 * 86400;

    // 库里按时间索引只取范围内的
    let all = store.records_since(earliest.timestamp_millis());
    let hidden: BTreeSet<&str> = q.hidden.iter().map(String::as_str).collect();
    let rows: Vec<&UsageRecord> = all
        .iter()
        .filter(|r| {
            sources.contains(&r.source)
                && r.time <= end
                && r.time >= since(r.source)
                && (r.source != Source::Codex || !hidden.contains(r.host.as_deref().unwrap_or("")))
        })
        .collect();

    // 机器列表：本机加上库里出现过的、设置里添加的远程机器
    let mut machines: BTreeSet<String> = overview.hosts.iter().cloned().collect();
    machines.extend(remote_hosts.iter().cloned());
    let machines: Vec<String> = std::iter::once(String::new()).chain(machines).collect();

    // 热力图：最近一年每天，跟着应用和机器筛选，不跟时间范围
    let year_ago = (now - Duration::days(380)).timestamp_millis();
    let mut heat: BTreeMap<String, HeatDay> = BTreeMap::new();
    for d in store.daily_totals(year_ago) {
        if !sources.contains(&d.source) || (d.source == Source::Codex && hidden.contains(d.host.as_deref().unwrap_or(""))) {
            continue;
        }
        let h = heat.entry(d.day.clone()).or_insert(HeatDay { day: d.day.clone(), ..Default::default() });
        h.tokens += d.tokens;
        h.requests += d.requests;
        h.cost += d.cost;
    }

    let apps = app_groups(&rows);
    let models = model_groups(&rows);
    let projects = project_groups(&rows);
    let log_rows: Vec<&UsageRecord> = rows.iter().copied().filter(|r| q.status == 0 || r.status == q.status).collect();
    let statuses: Vec<i64> = rows.iter().map(|r| r.status).chain([200]).collect::<BTreeSet<_>>().into_iter().collect();
    let pages = log_rows.len().div_ceil(PAGE_SIZE).max(1);
    let page = q.page.min(pages - 1);
    let mut counts = BTreeMap::new();
    counts.insert("apps".to_string(), apps.len());
    counts.insert("models".to_string(), models.len());
    counts.insert("projects".to_string(), projects.len());
    counts.insert("log".to_string(), rows.len());
    let current = match q.tab.as_str() {
        "apps" => apps,
        "models" => models,
        "projects" => projects,
        _ => vec![],
    };
    let group_total = current.len();
    // 行太多（按项目常有几百个）时先只列前 50 行：一次画几百行，界面会卡
    let groups = if q.show_all { current } else { current.into_iter().take(PAGE_SIZE).collect() };
    let log = if q.tab == "log" {
        log_rows
            .iter()
            .skip(page * PAGE_SIZE)
            .take(PAGE_SIZE)
            .map(|r| LogRow { r: (*r).clone(), hit_rate: r.hit_rate(), speed: r.speed(), breakdown: pricing.breakdown(r) })
            .collect()
    } else {
        vec![]
    };

    let codex_account = account.filter(|_| sources.contains(&Source::Codex)).map(|a| account_range(a, since(Source::Codex), end));

    View {
        summary: Summary::new(rows.iter().copied()),
        starts,
        end: end.timestamp_millis(),
        hourly,
        buckets: buckets(&rows, earliest, end, hourly),
        heat: heat.into_values().collect(),
        counts,
        groups,
        group_total,
        log,
        log_total: log_rows.len(),
        statuses,
        page,
        pages,
        machines,
        overview,
        codex_account,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_range_by_utc_day() {
        let mut acc = CodexAccount { lifetime: 900, ..Default::default() };
        acc.daily.insert("2026-10-29".into(), 100);
        acc.daily.insert("2026-10-30".into(), 300);
        let t = |s: &str| DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc);
        let r = account_range(&acc, t("2026-10-29T10:00:00Z"), t("2026-11-01T01:00:00Z"));
        assert_eq!(r, AccountRange { tokens: 400, days: 2, peak: 300, pending: true, lifetime: 900, last_day: Some("2026-10-30".into()) });
    }

    #[test]
    fn median_works() {
        assert_eq!(median(vec![3.0, 1.0, 2.0]), Some(2.0));
        assert_eq!(median(vec![4.0, 1.0, 2.0, 3.0]), Some(2.5));
        assert_eq!(median(vec![]), None);
    }

    #[test]
    fn daily_buckets_fill_gaps() {
        let end = Utc::now();
        let start = end - Duration::days(3);
        let b = buckets(&[], start, end, false);
        assert!(b.len() >= 3 && b.len() <= 5);
        assert!(b.windows(2).all(|w| w[1].t > w[0].t));
    }
}
