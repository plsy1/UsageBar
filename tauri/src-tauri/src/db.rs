// 用量数据库（和 macOS 版同一套表）：解析出来的每条请求存一行，日志读到哪里也存在这里
//   位置：应用数据目录下的 usage.sqlite（Windows 是 %APPDATA%\io.github.plsy1.usagebar）
//   records：每条请求一行，按时间建了索引；成本也存着（价格表更新时统一重算），汇总可以直接在 SQL 里加
//   files  ：每个日志文件的解析进度（读到第几个字节、解析到一半的状态）
//   meta   ：解析规则的版本、成本按哪一版价格算的
//   日志被 Claude Code 清理掉以后，库里的记录还留着

use crate::stats::{self, Entry, Pricing, Source, UsageRecord};
use chrono::DateTime;
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::time::UNIX_EPOCH;

/// 解析规则改了就加一：所有日志重新解析一遍（库里的记录按新结果更新；日志已经删掉的记录保留）
const PARSER_VERSION: &str = "1";
pub const REMOTE_PREFIX: &str = "ssh://";

const UPSERT: &str = "
INSERT INTO records(id, file, time, source, model, host, project, input, output, cache_read, cache_write, cache_write_1h,
                    duration, first_token, status, cost)
VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
ON CONFLICT(id) DO UPDATE SET file = excluded.file, time = excluded.time, source = excluded.source,
  model = excluded.model, host = excluded.host, project = excluded.project, input = excluded.input,
  output = excluded.output, cache_read = excluded.cache_read, cache_write = excluded.cache_write,
  cache_write_1h = excluded.cache_write_1h, duration = excluded.duration, first_token = excluded.first_token,
  status = excluded.status, cost = excluded.cost
WHERE excluded.output > records.output OR (excluded.output = records.output AND excluded.file = records.file)";

const COLUMNS: &str = "id, time, source, model, host, project, input, output, cache_read, cache_write, cache_write_1h, duration, first_token, status, cost";

pub struct Store {
    conn: Connection,
    /// 每个文件上次解析时的修改时间（纳秒）和大小：没变的文件不用去库里取进度
    known: Option<HashMap<String, (i64, u64)>>,
}

/// 每天的用量（热力图用），按本地日期、应用、机器分组；失败的请求不算
#[derive(Serialize, Clone, Debug)]
pub struct DayTotal {
    pub day: String, // 本地日期 yyyy-mm-dd
    pub source: Source,
    pub host: Option<String>,
    pub tokens: i64,
    pub requests: i64,
    pub cost: f64,
}

/// 库里一共多少条、最早一条的时间（毫秒）、出现过哪些远程机器
#[derive(Serialize, Clone, Debug, Default)]
pub struct Overview {
    pub count: i64,
    pub earliest: Option<i64>,
    pub hosts: Vec<String>,
}

fn source_name(s: Source) -> &'static str {
    match s {
        Source::Claude => "Claude",
        Source::Codex => "Codex",
    }
}

fn source_of(s: &str) -> Source {
    if s == "Codex" { Source::Codex } else { Source::Claude }
}

fn record(r: &Row) -> rusqlite::Result<UsageRecord> {
    let time: i64 = r.get(1)?;
    let source: String = r.get(2)?;
    Ok(UsageRecord {
        id: r.get(0)?,
        time: DateTime::from_timestamp_millis(time).unwrap_or_default(),
        source: source_of(&source),
        model: r.get(3)?,
        host: r.get(4)?,
        project: r.get(5)?,
        input: r.get(6)?,
        output: r.get(7)?,
        cache_read: r.get(8)?,
        cache_write: r.get(9)?,
        cache_write_1h: r.get(10)?,
        duration: r.get(11)?,
        first_token: r.get(12)?,
        status: r.get(13)?,
        cost: r.get(14)?,
    })
}

impl Store {
    pub fn open(dir: &Path) -> Option<Store> {
        fs::create_dir_all(dir).ok()?;
        let conn = Connection::open(dir.join("usage.sqlite")).ok()?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
             CREATE TABLE IF NOT EXISTS files(key TEXT PRIMARY KEY, mtime INTEGER, size INTEGER, state BLOB);
             CREATE TABLE IF NOT EXISTS records(
               id TEXT PRIMARY KEY, file TEXT, time INTEGER NOT NULL, source TEXT NOT NULL, model TEXT NOT NULL,
               host TEXT, project TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
               cache_write_1h INTEGER, duration REAL, first_token REAL, status INTEGER, cost REAL);
             CREATE INDEX IF NOT EXISTS records_time ON records(time);",
        )
        .ok()?;
        let store = Store { conn, known: None };
        if store.meta("parser").as_deref() != Some(PARSER_VERSION) {
            let _ = store.conn.execute("DELETE FROM files", []);
            store.set_meta("parser", PARSER_VERSION);
        }
        // 以前的缓存（整份记录存成 records.json）不用了
        Some(store)
    }

    fn meta(&self, key: &str) -> Option<String> {
        self.conn.query_row("SELECT value FROM meta WHERE key = ?1", [key], |r| r.get(0)).optional().ok().flatten()
    }

    fn set_meta(&self, key: &str, value: &str) {
        let _ = self.conn.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)", [key, value]);
    }

    fn load_known(&mut self) {
        if self.known.is_some() {
            return;
        }
        let mut k = HashMap::new();
        if let Ok(mut st) = self.conn.prepare("SELECT key, mtime, size FROM files") {
            if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))) {
                for (key, mtime, size) in rows.flatten() {
                    k.insert(key, (mtime, size as u64));
                }
            }
        }
        self.known = Some(k);
    }

    pub fn entry(&self, key: &str) -> Option<Entry> {
        let blob: Vec<u8> = self.conn.query_row("SELECT state FROM files WHERE key = ?1", [key], |r| r.get(0)).optional().ok()??;
        serde_json::from_slice(&blob).ok()
    }

    pub fn store_entry(&mut self, key: &str, mtime: i64, size: u64, e: &Entry) {
        let blob = serde_json::to_vec(e).unwrap_or_default();
        let _ = self.conn.execute(
            "INSERT OR REPLACE INTO files(key, mtime, size, state) VALUES(?1, ?2, ?3, ?4)",
            params![key, mtime, size as i64, blob],
        );
        if let Some(k) = self.known.as_mut() {
            k.insert(key.to_string(), (mtime, size));
        }
    }

    pub fn forget(&mut self, key: &str) {
        let _ = self.conn.execute("DELETE FROM files WHERE key = ?1", [key]);
        if let Some(k) = self.known.as_mut() {
            k.remove(key);
        }
    }

    /// 上次解析时这个文件的修改时间和大小
    pub fn known(&mut self, key: &str) -> Option<(i64, u64)> {
        self.load_known();
        self.known.as_ref()?.get(key).copied()
    }

    pub fn known_keys(&mut self) -> Vec<String> {
        self.load_known();
        self.known.as_ref().map(|k| k.keys().cloned().collect()).unwrap_or_default()
    }

    /// 写入记录。同一请求可能出现在多个文件里（续接的会话会带上旧记录，耗时、目录按新会话算，不准）：
    /// 按 id 合并，留输出最多的那份；一样多时留先写进来的，只有同一个文件里的后续几段才更新它（比如补上耗时）
    pub fn save(&self, rs: &[UsageRecord], file: &str, pricing: &Pricing) {
        let Ok(mut st) = self.conn.prepare_cached(UPSERT) else { return };
        for r in rs {
            let _ = st.execute(params![
                r.id, file, r.time.timestamp_millis(), source_name(r.source), r.model, r.host, r.project,
                r.input, r.output, r.cache_read, r.cache_write, r.cache_write_1h, r.duration, r.first_token,
                r.status, pricing.cost(r)
            ]);
        }
    }

    /// 一批写入放在一个事务里：两万行逐条提交要几秒，一个事务里几十毫秒
    pub fn transaction<T>(&mut self, f: impl FnOnce(&mut Store) -> T) -> T {
        let _ = self.conn.execute_batch("BEGIN");
        let out = f(self);
        let _ = self.conn.execute_batch("COMMIT");
        out
    }

    /// 把本机日志里新写的部分解析进库
    pub fn sync_local(&mut self, pricing: &Pricing) {
        let Some(home) = dirs::home_dir() else { return };
        self.load_known();
        self.transaction(|s| {
            let mut seen = HashSet::new();
            for (dir, src) in stats::LOG_DIRS {
                let mut files = vec![];
                stats::walk(&home.join(dir), &mut files);
                for path in files {
                    let meta = fs::metadata(&path).ok();
                    let mtime = meta.as_ref().and_then(|m| m.modified().ok()).map_or(i64::MIN, stats::nanos);
                    let size = meta.map_or(0, |m| m.len());
                    let key = path.to_string_lossy().into_owned();
                    seen.insert(key.clone());
                    if s.known(&key) == Some((mtime, size)) {
                        continue;
                    }
                    let mut e = s.entry(&key).filter(|e| stats::can_resume(e, &path, size)).unwrap_or_default();
                    let recs = stats::parse(&path, src, &mut e);
                    s.save(&recs, &key, pricing);
                    s.store_entry(&key, mtime, size, &e);
                }
            }
            // 删掉的日志不用再记进度；记录留在库里
            for key in s.known_keys() {
                if !seen.contains(&key) && !key.starts_with(REMOTE_PREFIX) {
                    s.forget(&key);
                }
            }
        });
    }

    /// since（毫秒）以来的记录，新的在前
    pub fn records_since(&self, since: i64) -> Vec<UsageRecord> {
        let sql = format!("SELECT {COLUMNS} FROM records WHERE time >= ?1 ORDER BY time DESC");
        let Ok(mut st) = self.conn.prepare_cached(&sql) else { return vec![] };
        st.query_map([since], record).map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    pub fn daily_totals(&self, since: i64) -> Vec<DayTotal> {
        let sql = "SELECT date(time / 1000, 'unixepoch', 'localtime') AS d, source, host,
                          SUM(input + output + cache_read + cache_write), COUNT(*), SUM(COALESCE(cost, 0))
                   FROM records WHERE time >= ?1 AND status = 200 GROUP BY d, source, host";
        let Ok(mut st) = self.conn.prepare_cached(sql) else { return vec![] };
        st.query_map([since], |r| {
            let source: String = r.get(1)?;
            Ok(DayTotal {
                day: r.get(0)?,
                source: source_of(&source),
                host: r.get(2)?,
                tokens: r.get(3)?,
                requests: r.get(4)?,
                cost: r.get(5)?,
            })
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    pub fn overview(&self) -> Overview {
        let mut o = Overview::default();
        if let Ok((count, earliest)) = self.conn.query_row("SELECT COUNT(*), MIN(time) FROM records", [], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i64>>(1)?))
        }) {
            o.count = count;
            o.earliest = earliest;
        }
        if let Ok(mut st) = self.conn.prepare("SELECT DISTINCT host FROM records WHERE host IS NOT NULL") {
            if let Ok(rows) = st.query_map([], |r| r.get::<_, String>(0)) {
                o.hosts = rows.flatten().collect();
            }
        }
        o
    }

    /// 价格表换了一版：库里每条记录的成本重算一遍（一天最多一次）
    pub fn reprice_if_needed(&mut self, pricing: &Pricing) {
        let Some(stamp) = pricing.updated_at.and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs().to_string()) else {
            return;
        };
        if self.meta("priced").as_deref() == Some(stamp.as_str()) {
            return;
        }
        let rows = self.records_since(i64::MIN);
        self.transaction(|s| {
            if let Ok(mut st) = s.conn.prepare_cached("UPDATE records SET cost = ?1 WHERE id = ?2") {
                for r in &rows {
                    let _ = st.execute(params![pricing.cost(r), r.id]);
                }
            }
            s.set_meta("priced", &stamp);
        });
    }

    /// 删掉的远程机器：它的记录和读取进度都清掉
    pub fn prune_remote(&mut self, keep: &[String]) {
        let o = self.overview();
        let gone: Vec<String> = o.hosts.into_iter().filter(|h| !keep.contains(h)).collect();
        let gone_keys: Vec<String> = self
            .known_keys()
            .into_iter()
            .filter(|k| k.starts_with(REMOTE_PREFIX) && !keep.iter().any(|h| k.starts_with(&format!("{REMOTE_PREFIX}{h}/"))))
            .collect();
        if gone.is_empty() && gone_keys.is_empty() {
            return;
        }
        self.transaction(|s| {
            for h in &gone {
                let _ = s.conn.execute("DELETE FROM records WHERE host = ?1", [h]);
            }
            for k in &gone_keys {
                s.forget(k);
            }
        });
    }

    pub fn host_count(&self, host: &str) -> i64 {
        self.conn
            .query_row("SELECT COUNT(*) FROM records WHERE host = ?1 AND status = 200", [host], |r| r.get(0))
            .unwrap_or(0)
    }

    pub fn meta_value(&self, key: &str) -> Option<String> {
        self.meta(key)
    }

    pub fn set_meta_value(&self, key: &str, value: &str) {
        self.set_meta(key, value)
    }
}

/// 第一次打开数据库时删掉旧版的 records.json 缓存
pub fn remove_old_cache(cache_dir: &Path) {
    let _ = fs::remove_file(cache_dir.join("records.json"));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: &str, ms: i64, output: i64) -> UsageRecord {
        let mut r = UsageRecord {
            id: id.into(),
            time: DateTime::from_timestamp_millis(ms).unwrap(),
            source: Source::Claude,
            model: "m".into(),
            input: 1,
            output,
            cache_read: 0,
            cache_write: 0,
            cache_write_1h: 0,
            cost: None,
            duration: None,
            first_token: None,
            status: 200,
            project: Some("/p".into()),
            host: None,
        };
        r.duration = Some(1.0);
        r
    }

    #[test]
    fn upsert_rules() {
        let dir = std::env::temp_dir().join(format!("ub-db-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut s = Store::open(&dir).unwrap();
        let p = Pricing::default();
        s.transaction(|s| s.save(&[rec("a", 1000, 5)], "f1", &p));
        // 别的文件里一样多的副本：不覆盖
        let mut copy = rec("a", 1000, 5);
        copy.duration = Some(99.0);
        s.save(&[copy], "f2", &p);
        assert_eq!(s.records_since(0)[0].duration, Some(1.0));
        // 同一个文件的后续：覆盖（补上耗时）
        let mut more = rec("a", 1000, 5);
        more.duration = Some(3.0);
        s.save(&[more], "f1", &p);
        assert_eq!(s.records_since(0)[0].duration, Some(3.0));
        // 别的文件里输出更多的：覆盖
        s.save(&[rec("a", 1000, 9)], "f2", &p);
        assert_eq!(s.records_since(0)[0].output, 9);
        assert_eq!(s.overview().count, 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
