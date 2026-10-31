// UsageBar（Windows / Linux 版）：托盘显示 Claude / Codex 剩余用量
//   托盘：Linux 顶栏直接显示「Cc 56%  Cx 47%」，Windows 显示在鼠标悬停提示里；菜单里有各额度
//   窗口：「额度」和「设置」两页（ui/）

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod i18n;
mod usage;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, WindowEvent};

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
    tray: Mutex<Option<TrayIcon>>,
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
    let text = tray_text(&snap.settings, &snap.providers);
    let st = app.state::<AppState>();
    let guard = st.tray.lock().unwrap();
    let Some(tray) = guard.as_ref() else { return };
    let _ = tray.set_tooltip(Some(&text));
    // 只有 Linux（AppIndicator）和 macOS 会在图标旁边显示文字；Windows 上忽略
    let _ = tray.set_title(Some(&text));
    if let Ok(menu) = build_menu(app) {
        let _ = tray.set_menu(Some(menu));
    }
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![get_state, set_settings, refresh_now])
        .setup(|app| {
            let handle = app.handle().clone();
            *app.state::<AppState>().settings.lock().unwrap() = load_settings(&handle);

            let tray = TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().cloned().expect("app icon"))
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
                // Windows：左键点托盘图标直接打开窗口（Linux 的 AppIndicator 只支持菜单）
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                        show_main(tray.app_handle());
                    }
                })
                .build(app)?;
            *app.state::<AppState>().tray.lock().unwrap() = Some(tray);

            // 带 --show 启动时直接打开窗口（从应用列表启动、或调试时用）
            if std::env::args().any(|a| a == "--show") {
                show_main(&handle);
            }
            tauri::async_runtime::spawn(refresh_loop(handle));
            Ok(())
        })
        // 关窗口只是隐藏，程序继续在托盘里运行
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running UsageBar");
}
