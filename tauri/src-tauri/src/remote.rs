// 远程机器（SSH）上的 Codex 日志（移植自 macOS 版 Sources/Stats.swift 的 readRemote）
//   Codex 在哪台机器上跑，日志就只留在哪台（Claude 用 app 连远程时日志存在本机，不用管）。
//   用系统的 ssh 去读（Windows 10/11 自带 OpenSSH 客户端）：先列出远程的日志文件和大小，
//   再把有变化的文件从上次读到的位置往后、在远程过滤后传回来。
//   要能免密登录（密钥或 ssh-agent）；BatchMode 下不会弹密码

use crate::db::{Store, REMOTE_PREFIX};
use crate::stats::{self, Entry, Pricing};
use serde::Serialize;
use serde_json::Value;
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// 一台远程机器上次读取的结果（设置页显示）。连不上时 files 为空，requests 是库里上次读到的
#[derive(Serialize, Clone, Debug, Default)]
pub struct RemoteStatus {
    pub files: Option<usize>,
    pub requests: i64,
    /// 界面翻译的 key（timeout / unreachable），或者 ssh 自己报的错（原样显示）
    pub error: Option<String>,
}

/// 在远程跑一段 sh 脚本，拿回输出；出错时第二项是原因
fn ssh(host: &str, script: &str, timeout: Duration) -> (Vec<u8>, Option<String>) {
    let mut cmd = Command::new("ssh");
    cmd.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-C", host, "sh -s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // Windows：不要弹出黑色的控制台窗口
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return (vec![], Some("no_ssh".into())),
    };
    // 脚本在 Windows 上检出时可能带 \r，远程的 sh 不认
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(script.replace('\r', "").as_bytes());
    }
    // 边跑边读：输出可能很大，等进程结束再读的话管道写满会卡住
    let reader = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut buf = vec![];
            if let Some(mut p) = pipe {
                let _ = p.read_to_end(&mut buf);
            }
            buf
        })
    };
    let out = reader(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let err = reader(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break Some(s),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let out = out.join().unwrap_or_default();
    let err = err.join().unwrap_or_default();
    match status {
        None => (out, Some("timeout".into())),
        Some(s) if s.success() => (out, None),
        Some(_) => {
            let msg = String::from_utf8_lossy(&err);
            let last = msg.lines().map(str::trim).filter(|l| !l.is_empty()).last().unwrap_or("");
            (out, Some(error_key(last)))
        }
    }
}

/// 常见的 ssh 错误换成界面能翻译的 key（Windows 上 ssh 附带的系统原因是本地编码，显示出来是乱码）；其他的原样
fn error_key(msg: &str) -> String {
    let m = msg.to_ascii_lowercase();
    let key = if m.is_empty() {
        "unreachable"
    } else if m.contains("could not resolve hostname") {
        "no_host"
    } else if m.contains("permission denied") {
        "ssh_auth"
    } else if m.contains("host key verification failed") {
        "host_key"
    } else if m.contains("timed out") || m.contains("no route to host") || m.contains("connection refused") || m.contains("network is unreachable") {
        "unreachable"
    } else {
        return msg.to_string();
    };
    key.into()
}

/// 列出远程的 Codex 日志：「大小 修改时间 路径」一行一个（Linux 和 macOS 的 stat 参数不一样，两种都试）
const LIST_SCRIPT: &str = r#"
for d in "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions"; do
  [ -d "$d" ] || continue
  find "$d" -type f -name '*.jsonl' | while IFS= read -r f; do
    s=$(stat -c '%s %Y' "$f" 2>/dev/null || stat -f '%z %m' "$f" 2>/dev/null) && printf '%s %s\n' "$s" "$f"
  done
done
"#;

/// 远程这边先过滤再传：会话日志大部分是对话和工具输出，统计只用到 token_count、turn_context 这两种整行，
/// 其余行只要时间、类型和是不是用户消息（算耗时用）。这样传回来的只有原文件的百分之几。
/// fetch 文件 起点 长度 核对长度 分隔符 序号：只处理 [起点, 起点+长度) 里的完整行，
/// 最后打印实际读到的原始字节数，以及起点之前、新位置之前各一小段原始内容（十六进制，用来核对文件有没有被改写）
const FILTER_SCRIPT: &str = r#"
t=$(mktemp) || exit 1
trap 'rm -f "$t"' EXIT
hex() { od -An -v -tx1 | tr -d ' \n'; }
fetch() {
  printf '%s S %s\n' "$5" "$6"
  old=-
  [ "$4" -gt 0 ] && old=$(tail -c +$(($2 - $4 + 1)) "$1" | head -c "$4" | hex)
  tail -c +$(($2 + 1)) "$1" | head -c "$3" | LC_ALL=C awk -v n="$3" -v out="$t" '
    function emit(l,  ts, ty, r) {
      if (l ~ /"(token_count|turn_context|token_usage_record)"/) { print l; return }
      if (!match(l, /"timestamp":"[^"]*"/)) return
      ts = substr(l, RSTART, RLENGTH)
      ty = ""
      if (match(l, /"payload":\{"type":"[^"]*"/)) ty = substr(l, RSTART, RLENGTH)
      r = (l ~ /"role":"user"/) ? ",\"role\":\"user\"" : ""
      if (ty == "") print "{" ts "}"; else print "{" ts "," ty r "}}"
    }
    { if (has) emit(prev); prev = $0; has = 1; used += length($0) + 1 }
    END {
      c = 0
      if (has) { if (used <= n) { emit(prev); c = used } else c = used - length(prev) - 1 }
      print c > out
    }'
  c=$(cat "$t"); e=$(($2 + c)); k=$((e < 64 ? e : 64))
  new=-
  [ "$k" -gt 0 ] && new=$(tail -c +$((e - k + 1)) "$1" | head -c "$k" | hex)
  printf '%s E %s %s %s\n' "$5" "$c" "${old:--}" "${new:--}"
}
"#;

fn hex_bytes(s: &str) -> Vec<u8> {
    (0..s.len() / 2).filter_map(|i| u8::from_str_radix(s.get(i * 2..i * 2 + 2)?, 16).ok()).collect()
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    memchr::memmem::find(hay, needle)
}

/// 单引号包起来给 sh（路径里的单引号写成 '\''）
fn quote(p: &str) -> String {
    format!("'{}'", p.replace('\'', r"'\''"))
}

/// 一个要传回来的文件：库里的键、远程路径、从哪个字节开始、上次位置之前要核对多少字节、大小、修改时间、上次的进度
struct Need {
    key: String,
    path: String,
    from: u64,
    check: u64,
    size: u64,
    mtime: i64,
    entry: Entry,
}

/// 传回来的一段里最新的那份额度（rate_limits）和它的时间（秒）
fn newest_rate_limits(data: &[u8], best: &mut Option<(i64, Value)>) {
    for line in data.split(|&b| b == b'\n').filter(|l| find(l, b"\"rate_limits\"").is_some()) {
        let Ok(obj) = serde_json::from_slice::<Value>(line) else { continue };
        let Some(t) = obj["timestamp"].as_str().and_then(stats::parse_iso).map(|t| t.timestamp()) else { continue };
        let rl = &obj["payload"]["rate_limits"];
        if rl.is_object() && best.as_ref().map_or(true, |(bt, _)| t > *bt) {
            *best = Some((t, rl.clone()));
        }
    }
}

/// 把一台远程机器上 Codex 日志新写的部分读进库。传 ssh 的时候不占着数据库
pub fn read_remote(store: &Arc<Mutex<Store>>, host: &str, pricing: &Pricing) -> RemoteStatus {
    let count = |s: &Arc<Mutex<Store>>| s.lock().unwrap().host_count(host);
    let (list, error) = ssh(host, LIST_SCRIPT, Duration::from_secs(60));
    if let Some(error) = error {
        return RemoteStatus { files: None, requests: count(store), error: Some(error) };
    }
    let files: Vec<(u64, i64, String)> = String::from_utf8_lossy(&list)
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(3, ' ');
            let size = parts.next()?.parse().ok()?;
            let mtime: i64 = parts.next()?.parse().ok()?;
            Some((size, mtime, parts.next()?.to_string()))
        })
        .collect();
    let prefix = format!("{REMOTE_PREFIX}{host}/");
    let mut need: Vec<Need> = vec![];
    {
        let mut s = store.lock().unwrap();
        // 远程删掉的文件不用再记进度；记录留在库里
        let seen: std::collections::HashSet<String> = files.iter().map(|f| format!("{prefix}{}", f.2)).collect();
        let gone: Vec<String> = s.known_keys().into_iter().filter(|k| k.starts_with(&prefix) && !seen.contains(k)).collect();
        s.transaction(|s| gone.iter().for_each(|k| s.forget(k)));
        for (size, mtime, path) in &files {
            let key = format!("{prefix}{path}");
            // 和本机的一样按纳秒记
            let mtime = mtime * 1_000_000_000;
            if s.known(&key) == Some((mtime, *size)) {
                continue;
            }
            match s.entry(&key).filter(|e| e.offset > 0 && *size >= e.offset) {
                Some(e) => need.push(Need { key, path: path.clone(), from: e.offset, check: e.tail_length, size: *size, mtime, entry: e }),
                None => need.push(Need { key, path: path.clone(), from: 0, check: 0, size: *size, mtime, entry: Entry::default() }),
            }
        }
    }

    let mut error = None;
    if !need.is_empty() {
        // 一次 ssh 把要的都传回来，每个文件前后加分隔行（随机的，不会和日志内容撞上）
        let mark = format!("@@UB-{:x}{:x}", std::process::id(), stats::nanos(std::time::SystemTime::now()));
        let mut script = FILTER_SCRIPT.to_string();
        for (i, n) in need.iter().enumerate() {
            script += &format!("fetch {} {} {} {} '{mark}' {i}\n", quote(&n.path), n.from, n.size - n.from, n.check);
        }
        let (out, err) = ssh(host, &script, Duration::from_secs(900));
        error = err;
        let start_mark = format!("{mark} S ").into_bytes();
        let end_mark = format!("{mark} E ").into_bytes();
        let mut rest: &[u8] = &out;
        let mut limits: Option<(i64, Value)> = None;
        let mut s = store.lock().unwrap();
        s.transaction(|s| {
            // 传断了也把收到的完整文件先存下
            while let Some(start) = find(rest, &start_mark) {
                let after = &rest[start + start_mark.len()..];
                let Some(nl) = memchr::memchr(b'\n', after) else { break };
                let Some(i) = std::str::from_utf8(&after[..nl]).ok().and_then(|x| x.trim().parse::<usize>().ok()).filter(|&i| i < need.len()) else { break };
                let body = &after[nl + 1..];
                let Some(end) = find(body, &end_mark) else { break };
                let Some(end_line) = memchr::memchr(b'\n', &body[end + end_mark.len()..]) else { break };
                let data = &body[..end];
                // 结尾一行：这次读到的原始字节数、上次位置之前那段的十六进制、新位置之前那段的十六进制
                let fields: Vec<String> = String::from_utf8_lossy(&body[end + end_mark.len()..end + end_mark.len() + end_line])
                    .split(' ')
                    .map(str::to_string)
                    .collect();
                rest = &body[end + end_mark.len() + end_line + 1..];
                let n = &need[i];
                let Some(used) = fields.first().and_then(|x| x.parse::<u64>().ok()).filter(|_| fields.len() == 3) else { continue };
                let mut e = n.entry.clone();
                if n.check > 0 && stats::fnv(&hex_bytes(&fields[1])) != e.tail {
                    // 上次读到的位置之前的内容变了：文件被改写过，下次从头传
                    s.forget(&n.key);
                    continue;
                }
                if used > 0 {
                    let mut recs = stats::parse_codex_chunk(data, &mut e);
                    for r in &mut recs {
                        r.host = Some(host.to_string());
                    }
                    s.save(&recs, &n.key, pricing);
                    newest_rate_limits(data, &mut limits);
                    let tail = hex_bytes(&fields[2]);
                    e.offset = n.from + used;
                    e.tail_length = tail.len() as u64;
                    e.tail = stats::fnv(&tail);
                }
                s.store_entry(&n.key, n.mtime, n.size, &e);
            }
            if let Some((t, rl)) = limits {
                save_rate_limits(s, t, rl);
            }
        });
    }
    RemoteStatus { files: Some(files.len()), requests: count(store), error }
}

const RATE_LIMITS_KEY: &str = "codexRateLimits";

/// 记下远程日志里见到的最新一份额度（比库里的新才换）
fn save_rate_limits(s: &Store, t: i64, rl: Value) {
    if logged_rate_limits(s).is_some_and(|(_, old)| old >= t) {
        return;
    }
    s.set_meta_value(RATE_LIMITS_KEY, &serde_json::json!({ "time": t, "limits": rl }).to_string());
}

/// 远程机器的 Codex 日志里最新的一份额度，和它是什么时候记的（秒）
pub fn logged_rate_limits(s: &Store) -> Option<(Value, i64)> {
    let v: Value = serde_json::from_str(&s.meta_value(RATE_LIMITS_KEY)?).ok()?;
    Some((v["limits"].clone(), v["time"].as_i64()?))
}

/// ~/.ssh/config 里写了名字的主机（不含 * 这种通配），添加时给个选择
pub fn ssh_config_hosts() -> Vec<String> {
    let Some(text) = dirs::home_dir().and_then(|h| std::fs::read_to_string(h.join(".ssh").join("config")).ok()) else { return vec![] };
    let mut out = vec![];
    for line in text.lines() {
        let words: Vec<&str> = line.split(|c: char| c == ' ' || c == '\t' || c == '=').filter(|w| !w.is_empty()).collect();
        if words.first().is_some_and(|w| w.eq_ignore_ascii_case("host")) {
            for w in &words[1..] {
                if !w.contains('*') && !w.contains('?') && !w.starts_with('!') && !out.contains(&w.to_string()) {
                    out.push(w.to_string());
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_and_quote() {
        assert_eq!(hex_bytes("7b0a"), vec![0x7b, 0x0a]);
        assert_eq!(hex_bytes("-"), Vec::<u8>::new());
        assert_eq!(quote("/a/it's"), r"'/a/it'\''s'");
        assert_eq!(error_key("ssh: Could not resolve hostname jetson: ?????????"), "no_host");
        assert_eq!(error_key("y@nuc: Permission denied (publickey,password)."), "ssh_auth");
        assert_eq!(error_key("Connection closed by 203.0.113.9 port 22"), "Connection closed by 203.0.113.9 port 22");
    }
}
