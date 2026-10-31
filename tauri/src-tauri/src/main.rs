// UsageBar（Windows / Linux 版）：托盘显示 Claude / Codex 剩余用量
//   托盘：Linux 顶栏直接显示「Cc 56%  Cx 47%」；Windows 上 Claude、Codex 各一个托盘图标，图标上画着百分比
//   Windows 左键点托盘弹出小面板（flyout），菜单里有各额度
//   窗口：「额度」和「设置」两页（ui/）

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod i18n;
mod trayicon;
mod usage;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Instant;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WindowEvent};

/// Windows 上每家一个画着数字的托盘图标；Linux 上一个图标、旁边显示文字
const PER_PROVIDER_TRAY: bool = cfg!(target_os = "windows");

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
struct Settings {
    language: String,     // auto / zh / ja / en
    display: String,      // remaining / used
    menu_label: String,   // short（Cc / Cx）/ full（Claude / Codex）
    refresh_minutes: u64, // 额度刷新间隔
    show_claude: bool,
    show_codex: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            language: "auto".into(),
            display: "remaining".into(),
            menu_label: "short".into(),
            refresh_minutes: 5,
            show_claude: true,
            show_codex: true,
        }
    }
}

#[derive(Default)]
struct AppState {
    settings: Mutex<Settings>,
    providers: Mutex<Vec<usage::Provider>>,
    updated: Mutex<Option<i64>>,
    loading: Mutex<bool>,
    trays: Mutex<Vec<TrayIcon>>,
    /// 小面板因失去焦点收起的时间：紧接着的那次托盘点击是「关掉」，不要再打开
    flyout_hidden_at: Mutex<Option<Instant>>,
}

/// 给界面的完整状态
#[derive(Serialize, Clone)]
struct Snapshot {
    settings: Settings,
    providers: Vec<usage::Provider>,
    updated: Option<i64>,
    loading: bool,
    lang: &'static str,
}

fn snapshot(app: &AppHandle) -> Snapshot {
    let st = app.state::<AppState>();
    let settings = st.settings.lock().unwrap().clone();
    let providers = st.providers.lock().unwrap().clone();
    let updated = *st.updated.lock().unwrap();
    let loading = *st.loading.lock().unwrap();
    let lang = i18n::resolve(&settings.language);
    Snapshot { settings, providers, updated, loading, lang }
}

fn settings_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("settings.json"))
}

fn load_settings(app: &AppHandle) -> Settings {
    settings_path(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_settings(app: &AppHandle, s: &Settings) {
    if let Some(p) = settings_path(app) {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(p, serde_json::to_string_pretty(s).unwrap_or_default());
    }
}

// MARK: - 给界面调用的命令

#[tauri::command]
fn get_state(app: AppHandle) -> Snapshot {
    snapshot(&app)
}

#[tauri::command]
fn set_settings(app: AppHandle, settings: Settings) -> Snapshot {
    *app.state::<AppState>().settings.lock().unwrap() = settings.clone();
    save_settings(&app, &settings);
    update_tray(&app);
    let snap = snapshot(&app);
    let _ = app.emit("state", snap.clone());
    snap
}

#[tauri::command]
fn refresh_now(app: AppHandle) {
    tauri::async_runtime::spawn(refresh(app));
}

/// 小面板里的「打开窗口」
#[tauri::command]
fn open_main(app: AppHandle) {
    if let Some(f) = app.get_webview_window("flyout") {
        let _ = f.hide();
    }
    show_main(&app);
}

// MARK: - 刷新

async fn refresh(app: AppHandle) {
    {
        let st = app.state::<AppState>();
        let mut loading = st.loading.lock().unwrap();
        if *loading {
            return;
        }
        *loading = true;
    }
    let _ = app.emit("state", snapshot(&app));
    let client = reqwest::Client::new();
    let providers = usage::fetch_all(&client).await;
    {
        let st = app.state::<AppState>();
        *st.providers.lock().unwrap() = providers;
        *st.updated.lock().unwrap() = Some(chrono::Utc::now().timestamp());
        *st.loading.lock().unwrap() = false;
    }
    update_tray(&app);
    let _ = app.emit("state", snapshot(&app));
}

/// 按设置的间隔一直刷新
async fn refresh_loop(app: AppHandle) {
    loop {
        refresh(app.clone()).await;
        let minutes = app.state::<AppState>().settings.lock().unwrap().refresh_minutes.max(1);
        tokio::time::sleep(std::time::Duration::from_secs(minutes * 60)).await;
    }
}

// MARK: - 托盘

/// 「Cc 56%  Cx 47%」：每家显示最紧的那个额度
fn tray_text(s: &Settings, providers: &[usage::Provider]) -> String {
    let used = s.display == "used";
    let parts: Vec<String> = providers
        .iter()
        .filter(|p| if p.name == "Claude" { s.show_claude } else { s.show_codex })
        .map(|p| {
            let name = if s.menu_label == "full" { p.name.clone() } else if p.name == "Claude" { "Cc".into() } else { "Cx".into() };
            let v = p.binding().map(|w| format!("{}%", (if used { w.used.min(100.0) } else { w.remaining() }).round() as i64));
            format!("{name} {}", v.unwrap_or_else(|| "–".into()))
        })
        .collect();
    if parts.is_empty() { "UsageBar".into() } else { parts.join("  ") }
}

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let snap = snapshot(app);
    let lang = snap.lang;
    let used = snap.settings.display == "used";
    let menu = Menu::new(app)?;
    if snap.providers.is_empty() {
        menu.append(&MenuItem::with_id(app, "info", i18n::t(lang, "loading"), false, None::<&str>)?)?;
    }
    for p in snap.providers.iter().filter(|p| if p.name == "Claude" { snap.settings.show_claude } else { snap.settings.show_codex }) {
        let head = match &p.plan { Some(plan) => format!("{}  {plan}", p.name), None => p.name.clone() };
        menu.append(&MenuItem::with_id(app, format!("h-{}", p.name), head, false, None::<&str>)?)?;
        if p.error.is_some() {
            menu.append(&MenuItem::with_id(app, format!("e-{}", p.name), format!("    {}", i18n::t(lang, "error")), false, None::<&str>)?)?;
        }
        for (i, w) in p.windows.iter().enumerate() {
            let line = format!("    {}   {}", i18n::window_label(lang, w), i18n::value_text(lang, w, used));
            menu.append(&MenuItem::with_id(app, format!("w-{}-{i}", p.name), line, false, None::<&str>)?)?;
        }
        menu.append(&PredefinedMenuItem::separator(app)?)?;
    }
    menu.append(&MenuItem::with_id(app, "refresh", i18n::t(lang, "refresh"), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "open", i18n::t(lang, "open"), true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", i18n::t(lang, "quit"), true, None::<&str>)?)?;
    Ok(menu)
}

fn update_tray(app: &AppHandle) {
    let snap = snapshot(app);
    let used = snap.settings.display == "used";
    let lang = snap.lang;
    let menu = build_menu(app).ok();
    let st = app.state::<AppState>();
    for tray in st.trays.lock().unwrap().iter() {
        if let Some(m) = &menu {
            let _ = tray.set_menu(Some(m.clone()));
        }
        let id = tray.id().as_ref().to_string();
        if id == "main" {
            let text = tray_text(&snap.settings, &snap.providers);
            let _ = tray.set_tooltip(Some(&text));
            // Linux（AppIndicator）会在图标旁边显示这段文字
            let _ = tray.set_title(Some(&text));
            continue;
        }
        // 每家一个图标：画最紧那个额度的数字，悬停提示里列出全部额度
        let visible = if id == "Claude" { snap.settings.show_claude } else { snap.settings.show_codex };
        let _ = tray.set_visible(visible);
        let p = snap.providers.iter().find(|p| p.name == id);
        let w = p.and_then(|p| p.binding());
        let v = w.map(|w| if used { w.used.min(100.0) } else { w.remaining() });
        let _ = tray.set_icon(Some(trayicon::render(v.map(|v| v.round() as i64), v.unwrap_or(0.0))));
        let mut tip = match p.and_then(|p| p.plan.clone()) { Some(plan) => format!("{id} {plan}"), None => id.clone() };
        if let Some(p) = p {
            if p.error.is_some() {
                tip.push_str(&format!("\n{}", i18n::t(lang, "error")));
            }
            for w in &p.windows {
                tip.push_str(&format!("\n{}  {}", i18n::window_label(lang, w), i18n::value_text(lang, w, used)));
            }
        }
        let _ = tray.set_tooltip(Some(&tip));
    }
}

/// Windows：在托盘图标旁边弹出小面板（再点一次收起）
fn toggle_flyout(app: &AppHandle, click: PhysicalPosition<f64>) {
    let Some(f) = app.get_webview_window("flyout") else { return };
    if f.is_visible().unwrap_or(false) {
        let _ = f.hide();
        return;
    }
    // 刚因为点托盘而失去焦点收起的，这次点击就是要关掉它
    let st = app.state::<AppState>();
    if st.flyout_hidden_at.lock().unwrap().map(|t| t.elapsed().as_millis() < 400).unwrap_or(false) {
        return;
    }
    let size = f.outer_size().unwrap_or_default();
    let (w, h) = (size.width as f64, size.height as f64);
    let mut x = click.x - w / 2.0;
    // 任务栏在下面时往上弹，在上面时往下弹
    let mut y = click.y - h - 12.0;
    if let Ok(Some(m)) = app.monitor_from_point(click.x, click.y) {
        let (mx, my) = (m.position().x as f64, m.position().y as f64);
        let (mw, mh) = (m.size().width as f64, m.size().height as f64);
        if click.y < my + mh / 2.0 {
            y = click.y + 12.0;
        }
        x = x.clamp(mx + 8.0, mx + mw - w - 8.0);
        y = y.clamp(my + 8.0, my + mh - h - 8.0);
    }
    let _ = f.set_position(PhysicalPosition::new(x, y));
    let _ = f.show();
    let _ = f.set_focus();
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    // 调试用：UsageBar --dump-icon <文件> <数字> 把托盘数字图标导出成 32×32 RGBA 原始数据
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--dump-icon") {
        let value = args.get(i + 2).and_then(|v| v.parse::<i64>().ok());
        let img = trayicon::render(value, value.unwrap_or(0) as f64);
        let _ = std::fs::write(&args[i + 1], img.rgba());
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![get_state, set_settings, refresh_now, open_main])
        .setup(|app| {
            let handle = app.handle().clone();
            *app.state::<AppState>().settings.lock().unwrap() = load_settings(&handle);

            // Codex 先建：Windows 会把后建的图标放在左边，这样从左到右是 Claude、Codex
            let ids: &[&str] = if PER_PROVIDER_TRAY { &["Codex", "Claude"] } else { &["main"] };
            let mut trays = Vec::new();
            for id in ids {
                let icon = if *id == "main" { app.default_window_icon().cloned().expect("app icon") } else { trayicon::render(None, 0.0) };
                let tray = TrayIconBuilder::with_id(*id)
                    .icon(icon)
                    .tooltip("UsageBar")
                    .menu(&build_menu(&handle)?)
                    .show_menu_on_left_click(false)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "refresh" => {
                            tauri::async_runtime::spawn(refresh(app.clone()));
                        }
                        "open" => show_main(app),
                        "quit" => app.exit(0),
                        _ => {}
                    })
                    // Windows：左键点托盘图标弹出小面板（Linux 的 AppIndicator 只有菜单）
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, position, .. } = event {
                            toggle_flyout(tray.app_handle(), position);
                        }
                    })
                    .build(app)?;
                trays.push(tray);
            }
            *app.state::<AppState>().trays.lock().unwrap() = trays;

            // 带 --show 启动时直接打开窗口（从应用列表启动、或调试时用）
            if std::env::args().any(|a| a == "--show") {
                show_main(&handle);
            }
            tauri::async_runtime::spawn(refresh_loop(handle));
            Ok(())
        })
        // 关窗口只是隐藏，程序继续在托盘里运行
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            // 小面板点别处就收起
            WindowEvent::Focused(false) if window.label() == "flyout" => {
                let _ = window.hide();
                *window.app_handle().state::<AppState>().flyout_hidden_at.lock().unwrap() = Some(Instant::now());
            }
            _ => {}
        })
        .run(tauri::generate_context!())
        .expect("error while running UsageBar");
}
