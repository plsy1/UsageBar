// UsageBar（Windows / Linux 版）：托盘显示 Claude / Codex 剩余用量
//   托盘：Linux 顶栏直接显示「Cc 56%  Cx 47%」；Windows 托盘只有图标，悬停看用量，左键点开小面板（flyout）
//   桌面卡片：跟 macOS 版一样的悬浮卡片，右键菜单；位置和拖动吸附见 cards.rs
//   窗口：「用量统计」「额度」「桌面卡片」「设置」四页（ui/）

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod cards;
mod db;
mod i18n;
mod stats;
mod statsview;
mod usage;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
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
    // 用量卡片（成本、请求数、Tokens），布局和外观自己一套（第一次沿用额度卡片的）
    stats_card_show: bool,
    stats_card_on_top: bool,
    stats_card_range: String,  // today / cycle / 7d
    stats_card_show_claude: bool,
    stats_card_show_codex: bool,
    stats_card_layout: String,
    stats_card_background: String,
    stats_card_text: String,
    stats_card_scale: f64,
    stats_card_opacity: f64,
    stats_card_bg_opacity: f64,
    stats_refresh_minutes: u64, // 用量统计的刷新间隔（只读新写入的日志）
    /// 各张卡片按显示器记的位置（界面不改，只由拖动来改）
    card_places: HashMap<String, cards::Placement>,
    card_x: Option<i32>,     // 旧版存的位置（物理像素），启动时迁移到 card_places
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
            stats_card_show: false,
            stats_card_on_top: false,
            stats_card_range: "today".into(),
            stats_card_show_claude: true,
            stats_card_show_codex: true,
            stats_card_layout: "horizontal".into(),
            stats_card_background: "none".into(),
            stats_card_text: "white".into(),
            stats_card_scale: 1.0,
            stats_card_opacity: 1.0,
            stats_card_bg_opacity: 1.0,
            stats_refresh_minutes: 5,
            card_places: HashMap::new(),
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
    /// 正在拖的卡片
    drag: Mutex<Option<cards::Drag>>,
    /// 用量统计：数据库（解析好的记录都在里面）、最近几天的记录（用量卡片用，新的在前）、价格表、上次读完的时间
    store: Mutex<Option<Arc<Mutex<db::Store>>>>,
    records: Mutex<Vec<stats::UsageRecord>>,
    pricing: Mutex<Arc<stats::Pricing>>,
    stats_updated: Mutex<Option<i64>>,
    stats_loading: Mutex<bool>,
    /// 两张卡片内容区的自然大小和「形状」，布局、大小、家数一样时对齐到较大的
    card_content: Mutex<HashMap<String, CardContent>>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
struct CardContent {
    width: f64,
    height: f64,
    shape: String,
}

/// 用量卡片要的：每家在所选范围内的汇总
#[derive(Serialize, Clone)]
struct UsageCard {
    claude: stats::Summary,
    codex: stats::Summary,
    updated: Option<i64>,
}

/// 给界面的完整状态
#[derive(Serialize, Clone)]
struct Snapshot {
    settings: Settings,
    providers: Vec<usage::Provider>,
    updated: Option<i64>,
    loading: bool,
    lang: &'static str,
    usage: UsageCard,
    stats_loading: bool,
    /// 各家周额度当前周期的起点（毫秒）：统计页「重置以来」用
    cycle: HashMap<String, i64>,
}

fn snapshot(app: &AppHandle) -> Snapshot {
    let st = app.state::<AppState>();
    let settings = st.settings.lock().unwrap().clone();
    let providers = st.providers.lock().unwrap().clone();
    let updated = *st.updated.lock().unwrap();
    let loading = *st.loading.lock().unwrap();
    let lang = i18n::resolve(&settings.language);
    let usage = usage_card(&st, &settings, &providers);
    let stats_loading = *st.stats_loading.lock().unwrap();
    let cycle = providers
        .iter()
        .filter_map(|p| {
            let reset = p.windows.iter().find(|w| w.kind == "weekly")?.resets_at?;
            Some((p.name.clone(), stats::cycle_start(chrono::DateTime::from_timestamp(reset, 0)?).timestamp_millis()))
        })
        .collect();
    Snapshot { settings, providers, updated, loading, lang, usage, stats_loading, cycle }
}

/// 用量卡片的汇总。「重置以来」每家按自己的每周额度重置时间算
fn usage_card(st: &AppState, s: &Settings, providers: &[usage::Provider]) -> UsageCard {
    let records = st.records.lock().unwrap();
    let start = |name: &str| {
        let reset = providers.iter().find(|p| p.name == name)
            .and_then(|p| p.windows.iter().find(|w| w.kind == "weekly"))
            .and_then(|w| w.resets_at)
            .and_then(|t| chrono::DateTime::from_timestamp(t, 0));
        stats::card_start(&s.stats_card_range, reset.map(stats::cycle_start))
    };
    UsageCard {
        claude: stats::summarize(&records, Some(stats::Source::Claude), start("Claude")),
        codex: stats::summarize(&records, Some(stats::Source::Codex), start("Codex")),
        updated: *st.stats_updated.lock().unwrap(),
    }
}

fn settings_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("settings.json"))
}

fn load_settings(app: &AppHandle) -> Settings {
    let text = settings_path(app).and_then(|p| std::fs::read_to_string(p).ok()).unwrap_or_default();
    let mut s: Settings = serde_json::from_str(&text).unwrap_or_default();
    // 旧版没有用量卡片：它的外观先沿用额度卡片的
    let raw: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if raw.get("stats_card_layout").is_none() {
        s.stats_card_layout = s.card_layout.clone();
        s.stats_card_background = s.card_background.clone();
        s.stats_card_text = s.card_text.clone();
        s.stats_card_scale = s.card_scale;
        s.stats_card_opacity = s.card_opacity;
        s.stats_card_bg_opacity = s.card_bg_opacity;
    }
    s
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
        settings.card_places = cur.card_places.clone();
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

/// 卡片窗口跟着内容改大小（逻辑像素）
#[tauri::command]
fn fit_card(window: tauri::WebviewWindow, width: f64, height: f64) {
    // GTK 会忽略「不可调整大小」窗口的改大小请求；tao 在窗口第一次显示时又会按配置把它设回不可调整，
    // 所以每次改大小前再设一次。卡片没有边框，用户拖不了边
    #[cfg(target_os = "linux")]
    let _ = window.set_resizable(true);
    let _ = window.set_size(tauri::LogicalSize::new(width, height));
    // 变大后可能超出屏幕，挪回来
    let app = window.app_handle();
    let st = app.state::<AppState>();
    let mut s = st.settings.lock().unwrap();
    let place = s.card_places.get(window.label()).cloned().unwrap_or_default();
    cards::keep_on_screen(app, &window, &place);
    // 另一张卡片还是自动摆的（没被拖过）：按这张的新大小重新挨着放，免得被盖住
    let other = if window.label() == "card" { "stats_card" } else { "card" };
    let sf = window.scale_factor().unwrap_or(1.0);
    let size = tauri::PhysicalSize::new((width * sf).round() as u32, (height * sf).round() as u32);
    if let (Some(o), Some(true), Ok(pos)) = (app.get_webview_window(other), s.card_places.get(other).map(|p| p.auto), window.outer_position()) {
        if let (Some(p), Ok(osize)) = (cards::next_to(app, &o, pos, size), o.outer_size()) {
            let _ = o.set_position(p);
            let place = s.card_places.entry(other.to_string()).or_default();
            cards::record_at(app, p, osize, place);
            save_settings(app, &s);
        }
    }
}

/// 卡片报来内容区的自然大小；两张形状一样时都撑到较大的那个（发 card_sync 给两张卡片）
#[tauri::command]
fn card_content(app: AppHandle, window: tauri::WebviewWindow, content: CardContent) {
    let st = app.state::<AppState>();
    let mut all = st.card_content.lock().unwrap();
    if all.get(window.label()) == Some(&content) {
        return;
    }
    all.insert(window.label().to_string(), content);
    let (a, b) = (all.get("card"), all.get("stats_card"));
    let synced = match (a, b) {
        (Some(a), Some(b)) if !a.shape.is_empty() && a.shape == b.shape => Some((a.width.max(b.width), a.height.max(b.height))),
        _ => None,
    };
    let _ = app.emit("card_sync", synced);
}

/// 卡片的拖动：按下、拖动中、松开（每一步由这边按光标位置算，好做吸附）
#[tauri::command]
fn card_drag_start(app: AppHandle, window: tauri::WebviewWindow) {
    *app.state::<AppState>().drag.lock().unwrap() = cards::drag_start(&app, &window);
}

#[tauri::command]
fn card_drag_move(app: AppHandle, window: tauri::WebviewWindow) {
    let st = app.state::<AppState>();
    let mut drag = st.drag.lock().unwrap();
    if let Some(d) = drag.as_mut().filter(|d| d.label == window.label()) {
        cards::drag_move(&app, &window, d);
    }
}

/// 拖完才记位置：系统或程序自己挪窗口都不算
#[tauri::command]
fn card_drag_end(app: AppHandle, window: tauri::WebviewWindow) {
    let st = app.state::<AppState>();
    let Some(d) = st.drag.lock().unwrap().take() else { return };
    cards::drag_end(&app);
    let Ok(size) = window.outer_size() else { return };
    let mut s = st.settings.lock().unwrap();
    let place = s.card_places.entry(window.label().to_string()).or_default();
    cards::record_at(&app, d.last, size, place);
    place.auto = false;
    save_settings(&app, &s);
}

/// 卡片上右键：弹出原生菜单（两张卡片各自的）
#[tauri::command]
fn card_menu(app: AppHandle, window: tauri::Window) {
    let snap = snapshot(&app);
    let lang = snap.lang;
    let usage = window.label() == "stats_card";
    let on_top = if usage { snap.settings.stats_card_on_top } else { snap.settings.card_on_top };
    let build = || -> tauri::Result<Menu<tauri::Wry>> {
        let menu = Menu::new(&app)?;
        let (refresh, hide) = if usage { ("s-refresh", "s-hide") } else { ("c-refresh", "c-hide") };
        menu.append(&MenuItem::with_id(&app, refresh, i18n::t(lang, "refresh"), true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(&app, "c-open", i18n::t(lang, "open"), true, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(&app, if usage { "s-settings" } else { "c-settings" }, i18n::t(lang, "card_settings"), true, None::<&str>)?)?;
        menu.append(&PredefinedMenuItem::separator(&app)?)?;
        menu.append(&CheckMenuItem::with_id(&app, if usage { "s-top" } else { "c-top" }, i18n::t(lang, "keep_on_top"), true, on_top, None::<&str>)?)?;
        menu.append(&MenuItem::with_id(&app, hide, i18n::t(lang, if usage { "hide_usage_card" } else { "hide_card" }), true, None::<&str>)?)?;
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

/// 内存里只放用量卡片要的最近几天（「重置以来」最多 7 天）；统计页按需从库里查
fn recent_start() -> i64 {
    (chrono::Utc::now() - chrono::Duration::days(8)).timestamp_millis()
}

fn open_store(app: &AppHandle) -> Option<Arc<Mutex<db::Store>>> {
    let st = app.state::<AppState>();
    let mut slot = st.store.lock().unwrap();
    if slot.is_none() {
        let dir = app.path().app_data_dir().ok()?;
        if let Ok(cache) = app.path().app_cache_dir() {
            db::remove_old_cache(&cache);
        }
        *slot = db::Store::open(&dir).map(|s| Arc::new(Mutex::new(s)));
    }
    slot.clone()
}

/// 读用量统计：日志里新写的部分解析进库，再取最近几天给用量卡片；读日志放到后台线程。
/// 第一次先从库里取上次的结果马上出数
async fn refresh_stats(app: AppHandle, force_prices: bool) {
    let Ok(cache) = app.path().app_cache_dir() else { return };
    let Some(store) = open_store(&app) else { return };
    let st = app.state::<AppState>();
    {
        let mut loading = st.stats_loading.lock().unwrap();
        if *loading {
            return;
        }
        *loading = true;
    }
    if st.records.lock().unwrap().is_empty() {
        *st.pricing.lock().unwrap() = Arc::new(stats::Pricing::load_cached(&cache));
        let s = store.clone();
        if let Ok(recs) = tauri::async_runtime::spawn_blocking(move || s.lock().unwrap().records_since(recent_start())).await {
            *st.records.lock().unwrap() = recs;
            let _ = app.emit("state", snapshot(&app));
        }
    }
    let pricing = Arc::new(stats::load_pricing(&reqwest::Client::new(), &cache, force_prices).await);
    *st.pricing.lock().unwrap() = pricing.clone();
    let s = store.clone();
    let p = pricing.clone();
    let done = tauri::async_runtime::spawn_blocking(move || {
        let mut s = s.lock().unwrap();
        s.sync_local(&p);
        s.reprice_if_needed(&p);
        s.records_since(recent_start())
    })
    .await;
    if let Ok(recs) = done {
        *st.records.lock().unwrap() = recs;
        *st.stats_updated.lock().unwrap() = Some(chrono::Utc::now().timestamp());
    }
    *st.stats_loading.lock().unwrap() = false;
    let _ = app.emit("state", snapshot(&app));
    // 统计页收到后按自己的条件重新查
    let _ = app.emit("stats_changed", ());
}

/// 统计页：按条件从库里查好汇总、走势图、热力图、表格（在后台线程里算）
#[tauri::command]
async fn stats_query(app: AppHandle, query: statsview::Query) -> Option<statsview::View> {
    let store = open_store(&app)?;
    let pricing = app.state::<AppState>().pricing.lock().unwrap().clone();
    tauri::async_runtime::spawn_blocking(move || statsview::compute(&store.lock().unwrap(), &pricing, &query, &[]))
        .await
        .ok()
}

#[tauri::command]
fn refresh_stats_now(app: AppHandle) {
    tauri::async_runtime::spawn(refresh_stats(app, false));
}

async fn stats_loop(app: AppHandle) {
    loop {
        refresh_stats(app.clone(), false).await;
        let minutes = app.state::<AppState>().settings.lock().unwrap().stats_refresh_minutes.max(1);
        tokio::time::sleep(std::time::Duration::from_secs(minutes * 60)).await;
    }
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
    menu.append(&CheckMenuItem::with_id(app, "stats_card", i18n::t(lang, "show_usage_card"), true, snap.settings.stats_card_show, None::<&str>)?)?;
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

/// 按设置显示 / 隐藏两张卡片，切换「保持在最前」和「贴在桌面层」
fn apply_card(app: &AppHandle) {
    let s = app.state::<AppState>().settings.lock().unwrap().clone();
    for (label, show, on_top) in [("card", s.card_show, s.card_on_top), ("stats_card", s.stats_card_show, s.stats_card_on_top)] {
        let Some(w) = app.get_webview_window(label) else { continue };
        if !show {
            let _ = w.hide();
            continue;
        }
        // 先撤掉旧的、再设新的：Windows 上反过来的话，撤「贴底」那一下会把刚设的「最前」也冲掉
        if on_top {
            let _ = w.set_always_on_bottom(false);
            let _ = w.set_always_on_top(true);
        } else {
            let _ = w.set_always_on_top(false);
            // Linux 不贴底：GNOME 的桌面图标是一层铺满全屏的透明窗口，贴底的卡片会被它盖住，点不到也拖不动
            #[cfg(not(target_os = "linux"))]
            let _ = w.set_always_on_bottom(true);
        }
        if !w.is_visible().unwrap_or(false) {
            // 第一次显示：还没位置记录就先摆好（挨着另一张卡片）
            if !s.card_places.contains_key(label) {
                place_card(app, label);
            }
            // GNOME 会给刚显示的普通窗口自动安排位置（覆盖掉我们设的），等它摆完再挪回去
            #[cfg(target_os = "linux")]
            let target = app.state::<AppState>().settings.lock().unwrap().card_places.get(label).and_then(|p| cards::target(app, &w, p));
            let _ = w.show();
            #[cfg(target_os = "linux")]
            if let Some(p) = target {
                let w = w.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                    let _ = w.set_position(p);
                });
            }
        }
    }
}

/// 摆到该在的地方：有记录按记录（那块屏不在了就去主屏）；没有记录先迁移旧版的坐标，再没有就放默认位置
fn place_card(app: &AppHandle, label: &str) {
    let Some(w) = app.get_webview_window(label) else { return };
    let st = app.state::<AppState>();
    let mut s = st.settings.lock().unwrap();
    let place = s.card_places.get(label).cloned().unwrap_or_default();
    if let Some(p) = cards::target(app, &w, &place) {
        let _ = w.set_position(p);
        return;
    }
    let old = if label == "card" { s.card_x.zip(s.card_y) } else { None };
    let pos = match old {
        Some((x, y)) => Some(PhysicalPosition::new(x, y)),
        None => cards::default_position(app, &w, CARD_LABELS.iter().filter(|l| **l != label).find_map(|l| app.get_webview_window(l)).as_ref()),
    };
    if let (Some(p), Ok(size)) = (pos, w.outer_size()) {
        let p = cards::clamped(app, p, size);
        let _ = w.set_position(p);
        let place = s.card_places.entry(label.to_string()).or_default();
        cards::record_at(app, p, size, place);
        // 挨着另一张卡片自动摆的，在被拖之前跟着它走；旧版迁移过来的位置是用户拖过的
        place.auto = old.is_none() && label == "stats_card";
        s.card_x = None;
        s.card_y = None;
        save_settings(app, &s);
    }
}

const CARD_LABELS: [&str; 2] = cards::CARDS;

/// 显示器插拔、改分辨率或排列时把卡片摆回去（Tauri 没有这个事件，隔几秒比一下）
async fn watch_monitors(app: AppHandle) {
    let mut last = cards::monitors_signature(&app);
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        let now = cards::monitors_signature(&app);
        if now != last {
            last = now;
            for l in CARD_LABELS {
                place_card(&app, l);
            }
        }
    }
}

/// 改一项设置（托盘和卡片右键菜单用）
fn update_settings(app: &AppHandle, f: impl FnOnce(&mut Settings)) {
    let mut s = app.state::<AppState>().settings.lock().unwrap().clone();
    f(&mut s);
    set_settings(app.clone(), s);
}

/// 打开主窗口并切到「桌面卡片」页（which：limits / stats，切到那张卡片的设置）
fn open_card_settings(app: &AppHandle, which: &str) {
    show_main(app);
    let _ = app.emit_to("main", "navigate", ("card", which));
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
        // 只跑一份：再启动一次（比如从开始菜单再点）就把已经在跑的那个窗口调出来
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![get_state, set_settings, refresh_now, open_main, card_menu, fit_card,
                                                 card_drag_start, card_drag_move, card_drag_end, card_content,
                                                 stats_query, refresh_stats_now])
        // 卡片右键菜单（托盘菜单有自己的处理）
        .on_menu_event(|app, event| match event.id.as_ref() {
            "c-refresh" => {
                tauri::async_runtime::spawn(refresh(app.clone()));
            }
            "s-refresh" => {
                tauri::async_runtime::spawn(refresh_stats(app.clone(), false));
            }
            "c-open" => show_main(app),
            "c-settings" => open_card_settings(app, "limits"),
            "s-settings" => open_card_settings(app, "stats"),
            "c-hide" => update_settings(app, |s| s.card_show = false),
            "s-hide" => update_settings(app, |s| s.stats_card_show = false),
            "c-top" => update_settings(app, |s| s.card_on_top = !s.card_on_top),
            "s-top" => update_settings(app, |s| s.stats_card_on_top = !s.stats_card_on_top),
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
                        "card" => update_settings(app, |s| s.card_show = !s.card_show),
                        "stats_card" => update_settings(app, |s| s.stats_card_show = !s.stats_card_show),
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
            // 两张卡片都按记录摆好（额度卡片先，用量卡片第一次要挨着它放）
            for l in CARD_LABELS {
                place_card(&handle, l);
            }
            apply_card(&handle);
            tauri::async_runtime::spawn(watch_monitors(handle.clone()));
            tauri::async_runtime::spawn(stats_loop(handle.clone()));

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
