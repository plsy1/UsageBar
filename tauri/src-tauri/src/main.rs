// UsageBar（Windows / Linux 版）：托盘显示 Claude / Codex 剩余用量
//   托盘：Linux 顶栏直接显示「Cc 56%  Cx 47%」；Windows 托盘只有图标，悬停看用量，左键点开小面板（flyout）
//   桌面卡片：跟 macOS 版一样的悬浮卡片，可拖动、位置记住，右键菜单
//   窗口：「额度」「桌面卡片」「设置」三页（ui/）

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod i18n;
mod usage;

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::Instant;
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WindowEvent};

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
struct Settings {
    language: String,     // auto / zh / ja / en
    display: String,      // remaining / used
    menu_label: String,   // short（Cc / Cx）/ full（Claude / Codex）
    refresh_minutes: u64, // 额度刷新间隔
    show_claude: bool,
    show_codex: bool,
    // 桌面卡片（跟 macOS 版的选项一一对应）
    card_show: bool,
    card_on_top: bool,       // 保持在最前；关掉时贴在桌面层（被其他窗口盖住）
    card_layout: String,     // horizontal / vertical / compact
    card_background: String, // none / dark / light
    card_text: String,       // white / black
    card_scale: f64,
    card_opacity: f64,
    card_bg_opacity: f64,
    card_reset: String,      // hidden / relative（多久后）/ absolute（几点）
    card_x: Option<i32>,     // 拖动后的位置（物理像素），界面不改这两个
    card_y: Option<i32>,
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
            card_show: true,
            card_on_top: false,
            card_layout: "horizontal".into(),
            card_background: "none".into(),
            card_text: "white".into(),
            card_scale: 1.0,
            card_opacity: 1.0,
            card_bg_opacity: 1.0,
            card_reset: "relative".into(),
            card_x: None,
            card_y: None,
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
fn set_settings(app: AppHandle, mut settings: Settings) -> Snapshot {
    {
        // 卡片位置只由拖动来改，界面传来的旧值不算
        let st = app.state::<AppState>();
        let mut cur = st.settings.lock().unwrap();
        settings.card_x = cur.card_x;
        settings.card_y = cur.card_y;
        *cur = settings.clone();
    }
    save_settings(&app, &settings);
    update_tray(&app);
    apply_card(&app);
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

/// 卡片上右键：弹出原生菜单
#[tauri::command]
fn card_menu(app: AppHandle, window: tauri::Window) {
    let lang = snapshot(&app).lang;
    let build = || -> tauri::Result<Menu<tauri::Wry>> {
        let menu = Menu::new(&app)?;
        menu.append(&MenuItem::with_id(&app, "c-refresh", i18n::t(lang, "refresh"), true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(&app, "c-open", i18n::t(lang, "open"), true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(&app, "c-settings", i18n::t(lang, "card_settings"), true, None::<&str>)?)?;
        menu.append(&PredefinedMenuItem::separator(&app)?)?;
        menu.append(&MenuItem::with_id(&app, "c-hide", i18n::t(lang, "hide_card"), true, None::<&str>)?)?;
        Ok(menu)
    };
    if let Ok(menu) = build() {
        let _ = window.popup_menu(&menu);
    }
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
    menu.append(&CheckMenuItem::with_id(app, "card", i18n::t(lang, "show_card"), true, snap.settings.card_show, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", i18n::t(lang, "quit"), true, None::<&str>)?)?;
    Ok(menu)
}

fn update_tray(app: &AppHandle) {
    let snap = snapshot(app);
    let menu = build_menu(app).ok();
    let st = app.state::<AppState>();
    for tray in st.trays.lock().unwrap().iter() {
        if let Some(m) = &menu {
            let _ = tray.set_menu(Some(m.clone()));
        }
        let text = tray_text(&snap.settings, &snap.providers);
        let _ = tray.set_tooltip(Some(&text));
        // Linux（AppIndicator）会在图标旁边显示这段文字；Windows 托盘只有图标，用量看悬停提示或点开小面板
        let _ = tray.set_title(Some(&text));
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

// MARK: - 桌面卡片

/// 按设置显示 / 隐藏卡片，切换「保持在最前」和「贴在桌面层」
fn apply_card(app: &AppHandle) {
    let Some(w) = app.get_webview_window("card") else { return };
    let s = app.state::<AppState>().settings.lock().unwrap().clone();
    if !s.card_show {
        let _ = w.hide();
        return;
    }
    let _ = w.set_always_on_top(s.card_on_top);
    let _ = w.set_always_on_bottom(!s.card_on_top);
    if !w.is_visible().unwrap_or(false) {
        let _ = w.show();
    }
}

/// 启动时放到上次的位置；没有记录（或那块屏幕已经不在了）就放到主屏右上角
fn place_card(app: &AppHandle) {
    let Some(w) = app.get_webview_window("card") else { return };
    let s = app.state::<AppState>().settings.lock().unwrap().clone();
    let monitors = w.available_monitors().unwrap_or_default();
    if let (Some(x), Some(y)) = (s.card_x, s.card_y) {
        let on_screen = monitors.iter().any(|m| {
            let (p, z) = (m.position(), m.size());
            x >= p.x && y >= p.y && x < p.x + z.width as i32 - 40 && y < p.y + z.height as i32 - 40
        });
        if on_screen {
            let _ = w.set_position(PhysicalPosition::new(x, y));
            return;
        }
    }
    if let Ok(Some(m)) = w.primary_monitor() {
        let sf = m.scale_factor();
        let x = m.position().x + m.size().width as i32 - (540.0 * sf) as i32;
        let y = m.position().y + (48.0 * sf) as i32;
        let _ = w.set_position(PhysicalPosition::new(x, y));
    }
}

fn set_card_show(app: &AppHandle, show: bool) {
    let mut s = app.state::<AppState>().settings.lock().unwrap().clone();
    s.card_show = show;
    set_settings(app.clone(), s);
}

/// 打开主窗口并切到「桌面卡片」页
fn open_card_settings(app: &AppHandle) {
    show_main(app);
    let _ = app.emit_to("main", "navigate", "card");
}

fn show_main(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn main() {
    // Linux 的 Wayland 不让程序自己摆窗口位置，卡片就没法记住位置：优先走 XWayland，没有再用 Wayland
    #[cfg(target_os = "linux")]
    if std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("GDK_BACKEND").is_none() {
        std::env::set_var("GDK_BACKEND", "x11,wayland");
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![get_state, set_settings, refresh_now, open_main, card_menu])
        // 卡片右键菜单（托盘菜单有自己的处理）
        .on_menu_event(|app, event| match event.id.as_ref() {
            "c-refresh" => {
                tauri::async_runtime::spawn(refresh(app.clone()));
            }
            "c-open" => show_main(app),
            "c-settings" => open_card_settings(app),
            "c-hide" => set_card_show(app, false),
            _ => {}
        })
        .setup(|app| {
            let handle = app.handle().clone();
            *app.state::<AppState>().settings.lock().unwrap() = load_settings(&handle);

            let mut trays = Vec::new();
            {
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
                        "card" => {
                            let show = !app.state::<AppState>().settings.lock().unwrap().card_show;
                            set_card_show(app, show);
                        }
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
            place_card(&handle);
            apply_card(&handle);

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
            // 拖动卡片后记住位置
            WindowEvent::Moved(pos) if window.label() == "card" => {
                let app = window.app_handle();
                let st = app.state::<AppState>();
                let mut s = st.settings.lock().unwrap();
                if s.card_x != Some(pos.x) || s.card_y != Some(pos.y) {
                    s.card_x = Some(pos.x);
                    s.card_y = Some(pos.y);
                    save_settings(app, &s);
                }
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
