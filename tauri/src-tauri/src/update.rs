// 应用内更新（和 macOS 版 Sources/Updater.swift 一个思路）：从 GitHub Releases 查最新的 Windows / Linux 版，
// 下载对应的安装包、按发布说明里的 SHA-256 校验，再装上并重启。
//   版本号：tag 去掉开头的 tauri-v（tauri-v0.4.0 → 0.4.0）；macOS 版的 v* 不算
//   校验值：发布说明 SHA-256 一节里的「<64 位十六进制>  <文件名>」
//   Windows：运行 NSIS 安装包（/P 只显示进度、/R 装完重新打开、/UPDATE 当作更新）
//   Linux AppImage：替换正在运行的那个文件再重新打开；deb 要 sudo，只给下载页

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;

pub const REPO: &str = "plsy1/UsageBar";

/// 给界面看的更新状态
#[derive(Serialize, Clone, Debug, Default)]
pub struct State {
    /// idle / checking / up_to_date / available / downloading / failed
    pub status: String,
    pub current: String,
    pub version: Option<String>,
    /// 发布说明的正文（「安装」之前的部分）
    pub notes: Option<String>,
    pub page: Option<String>,
    /// 失败原因：界面翻译的 key（network / checksum / no_checksum / write）或原样的错误
    pub error: Option<String>,
    /// 下载进度 0~1
    pub progress: Option<f64>,
    /// 能不能在应用里直接装（Linux 的 deb 不能，只给下载页）
    pub can_install: bool,
}

/// 查到的新版本：要下载的文件和它的校验值
#[derive(Clone, Debug)]
pub struct Release {
    pub version: String,
    pub notes: String,
    pub page: String,
    pub asset: Option<(String, String, Option<String>)>, // 文件名、下载地址、SHA-256
}

/// 1.10.0 > 1.9.3：按数字逐段比
pub fn is_newer(a: &str, b: &str) -> bool {
    let parse = |s: &str| s.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    let (x, y) = (parse(a), parse(b));
    for i in 0..x.len().max(y.len()) {
        let (p, q) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if p != q {
            return p > q;
        }
    }
    false
}

/// 正在运行的是不是 AppImage（是的话返回它的路径）
fn appimage() -> Option<PathBuf> {
    if cfg!(target_os = "linux") { std::env::var_os("APPIMAGE").map(PathBuf::from) } else { None }
}

/// 这台机器要的安装包文件名结尾
fn asset_suffix() -> Option<String> {
    let arch = if std::env::consts::ARCH == "aarch64" { "arm64" } else { "amd64" };
    if cfg!(windows) {
        Some("-windows-x64-setup.exe".into())
    } else if appimage().is_some() {
        Some(format!("-linux-{arch}.AppImage"))
    } else {
        None
    }
}

/// 发布说明里某个文件的 SHA-256
fn checksum(notes: &str, file: &str) -> Option<String> {
    notes.lines().find_map(|l| {
        let mut parts = l.split_whitespace();
        let hash = parts.next()?;
        (parts.next()? == file && hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit())).then(|| hash.to_lowercase())
    })
}

/// 发布说明只要「安装」之前的正文，去掉开头的链接行和预览说明
fn summary(body: &str) -> String {
    let end = ["### Install", "### Not yet", "### SHA-256"].iter().filter_map(|h| body.find(h)).min().unwrap_or(body.len());
    body[..end]
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('[') && !l.contains("releases/latest"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn client() -> reqwest::Client {
    // GitHub 的接口要求带 User-Agent
    reqwest::Client::builder().user_agent("UsageBar").build().unwrap_or_default()
}

/// 查 tauri-v* 里版本号最大的那个（预览版也算）
pub async fn latest() -> Result<Release, String> {
    let resp = client()
        .get(format!("https://api.github.com/repos/{REPO}/releases?per_page=30"))
        .header("Accept", "application/vnd.github+json")
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|_| "network")?;
    if !resp.status().is_success() {
        return Err("network".into());
    }
    let list: Vec<Value> = resp.json().await.map_err(|_| "network")?;
    let r = list
        .iter()
        .filter(|r| !r["draft"].as_bool().unwrap_or(false))
        .filter_map(|r| Some((r["tag_name"].as_str()?.strip_prefix("tauri-v")?.to_string(), r)))
        .max_by(|a, b| if is_newer(&a.0, &b.0) { std::cmp::Ordering::Greater } else { std::cmp::Ordering::Less })
        .ok_or("network")?;
    let (version, r) = r;
    let body = r["body"].as_str().unwrap_or_default();
    let asset = asset_suffix().and_then(|suffix| {
        let a = r["assets"].as_array()?.iter().find(|a| a["name"].as_str().is_some_and(|n| n.ends_with(&suffix)))?;
        let name = a["name"].as_str()?.to_string();
        let url = a["browser_download_url"].as_str()?.to_string();
        let sha = checksum(body, &name);
        Some((name, url, sha))
    });
    Ok(Release {
        version,
        notes: summary(body),
        page: r["html_url"].as_str().map(str::to_string).unwrap_or(format!("https://github.com/{REPO}/releases")),
        asset,
    })
}

/// 下载并校验，返回下好的文件。progress 收到 0~1
pub async fn download(r: &Release, dir: &std::path::Path, progress: impl Fn(f64)) -> Result<PathBuf, String> {
    let Some((name, url, sha)) = &r.asset else { return Err("network".into()) };
    let Some(expected) = sha else { return Err("no_checksum".into()) };
    let mut resp = client().get(url).timeout(Duration::from_secs(600)).send().await.map_err(|_| "network")?;
    if !resp.status().is_success() {
        return Err("network".into());
    }
    let total = resp.content_length().unwrap_or(0) as f64;
    std::fs::create_dir_all(dir).map_err(|_| "write")?;
    let path = dir.join(name);
    let mut file = std::fs::File::create(&path).map_err(|_| "write")?;
    let mut hasher = Sha256::new();
    let mut got = 0.0;
    while let Some(chunk) = resp.chunk().await.map_err(|_| "network")? {
        hasher.update(&chunk);
        file.write_all(&chunk).map_err(|_| "write")?;
        got += chunk.len() as f64;
        if total > 0.0 {
            progress(got / total);
        }
    }
    drop(file);
    let digest: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if &digest != expected {
        let _ = std::fs::remove_file(&path);
        return Err("checksum".into());
    }
    Ok(path)
}

/// 装上下好的安装包。成功后调用方退出，新版会自己打开
pub fn install(file: &std::path::Path) -> Result<(), String> {
    #[cfg(windows)]
    {
        std::process::Command::new(file).args(["/P", "/R", "/UPDATE"]).spawn().map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(not(windows))]
    {
        // AppImage：换掉正在运行的文件（同一目录里改名是原子的），再启动新的
        use std::os::unix::fs::PermissionsExt;
        let target = appimage().ok_or("write")?;
        let tmp = target.with_extension("new");
        std::fs::copy(file, &tmp).map_err(|_| "write")?;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).map_err(|_| "write")?;
        std::fs::rename(&tmp, &target).map_err(|_| "write")?;
        std::process::Command::new(&target).spawn().map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// 用系统浏览器打开网页
pub fn open_url(url: &str) {
    #[cfg(windows)]
    let _ = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn();
    #[cfg(not(windows))]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_and_checksums() {
        assert!(is_newer("0.10.0", "0.9.3"));
        assert!(!is_newer("0.3.0", "0.3"));
        let notes = "### SHA-256\n```\n89224d797fcc693c20fa058a5cfaaf38639a576bbf8ada661f7b6ddd5788c2f6  UsageBar-0.3.0-linux-amd64.AppImage\n93b823cf7bc5097c56d46b92734a217c77e30ce293995d417bdc6fc0ab0c6a67  UsageBar-0.3.0-windows-x64-setup.exe\n```";
        assert_eq!(checksum(notes, "UsageBar-0.3.0-windows-x64-setup.exe").as_deref(), Some("93b823cf7bc5097c56d46b92734a217c77e30ce293995d417bdc6fc0ab0c6a67"));
        assert_eq!(checksum(notes, "UsageBar-0.3.0-linux-arm64.deb"), None);
        let body = "**Preview.** See [Latest](https://github.com/x/releases/latest).\n\n### New in 0.3.0\n- **Usage card**: x\n\n### Not yet\nmore\n### Install\n- y";
        assert_eq!(summary(body), "### New in 0.3.0\n- **Usage card**: x");
    }
}
