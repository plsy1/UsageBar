// 桌面卡片的位置和拖动（两张卡片通用）
//   位置按显示器分别记：每块屏记卡片左上角相对这块屏工作区左上角的偏移（逻辑像素），另记最后在哪块屏。
//   启动时、显示器变化时摆回去：那块屏还在就放回去；不在就放到主屏（不动那块屏的记录，接回来时自动回去）。
//   无论怎么摆都限制在工作区内（不含任务栏）。
//   拖动自己处理（不用系统拖动）：靠近屏幕边缘、离边一点的位置、屏幕中线、另一张卡片的边时吸过去，并画对齐线

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow};

/// 卡片窗口的 label
pub const CARDS: [&str; 2] = ["card", "stats_card"];

/// 离对齐位置多近就吸过去（逻辑像素，这段距离内拖不动）、离屏幕边缘留的空、两张卡片挨着时的间隔
const SNAP: f64 = 10.0;
const MARGIN: f64 = 16.0;
const GAP: f64 = 12.0;

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Placement {
    /// 显示器 → 左上角相对工作区左上角的偏移（逻辑像素）
    pub offsets: HashMap<String, (f64, f64)>,
    /// 最后放在哪块屏
    pub screen: Option<String>,
    /// 还没被拖过、是程序挨着另一张卡片自动摆的：另一张卡片变大变小时跟着重新摆
    pub auto: bool,
}

/// 显示器的名字当 ID（Windows 是 \\.\DISPLAY1 这种，Linux 是接口名）；没有名字就用位置和大小
pub fn monitor_id(m: &Monitor) -> String {
    m.name().cloned().unwrap_or_else(|| {
        format!("{}x{}@{},{}", m.size().width, m.size().height, m.position().x, m.position().y)
    })
}

/// 用来发现显示器变化（插拔、改分辨率、改排列）
pub fn monitors_signature(app: &AppHandle) -> String {
    app.available_monitors()
        .unwrap_or_default()
        .iter()
        .map(|m| format!("{}:{:?}:{:?}:{}", monitor_id(m), m.position(), m.size(), m.scale_factor()))
        .collect::<Vec<_>>()
        .join("|")
}

/// 矩形（物理像素）：x, y, 宽, 高
#[derive(Clone, Copy, Debug)]
struct Rect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

impl Rect {
    fn work(m: &Monitor) -> Rect {
        let a = m.work_area();
        Rect { x: a.position.x as f64, y: a.position.y as f64, w: a.size.width as f64, h: a.size.height as f64 }
    }
    fn overlap(&self, o: &Rect) -> f64 {
        let w = (self.x + self.w).min(o.x + o.w) - self.x.max(o.x);
        let h = (self.y + self.h).min(o.y + o.h) - self.y.max(o.y);
        if w > 0.0 && h > 0.0 { w * h } else { 0.0 }
    }
}

fn window_rect(w: &WebviewWindow) -> Option<Rect> {
    let p = w.outer_position().ok()?;
    let s = w.outer_size().ok()?;
    Some(Rect { x: p.x as f64, y: p.y as f64, w: s.width as f64, h: s.height as f64 })
}

/// 卡片在哪块屏：重叠面积最大的那块
fn best_monitor(app: &AppHandle, r: &Rect) -> Option<Monitor> {
    let ms = app.available_monitors().ok()?;
    ms.into_iter().max_by(|a, b| {
        let (x, y) = (Rect::work(a).overlap(r), Rect::work(b).overlap(r));
        x.partial_cmp(&y).unwrap_or(std::cmp::Ordering::Equal)
    })
}

fn monitor_by_id(app: &AppHandle, id: &str) -> Option<Monitor> {
    app.available_monitors().ok()?.into_iter().find(|m| monitor_id(m) == id)
}

/// 左上角挪进工作区内，整张卡片都看得见
fn clamp(pos: (f64, f64), size: PhysicalSize<u32>, m: &Monitor) -> PhysicalPosition<i32> {
    let a = Rect::work(m);
    let x = pos.0.min(a.x + a.w - size.width as f64).max(a.x);
    let y = pos.1.min(a.y + a.h - size.height as f64).max(a.y);
    PhysicalPosition::new(x.round() as i32, y.round() as i32)
}

/// 卡片该在的位置；还没记过就返回 None
pub fn target(app: &AppHandle, w: &WebviewWindow, p: &Placement) -> Option<PhysicalPosition<i32>> {
    if p.offsets.is_empty() {
        return None;
    }
    let last = p.screen.clone().unwrap_or_default();
    // 上次那块屏还在就用它；不在就用主屏（主屏自己有记录就用主屏的，否则沿用上次的相对位置）
    let m = monitor_by_id(app, &last).or_else(|| app.primary_monitor().ok().flatten())?;
    let off = p.offsets.get(&monitor_id(&m)).or_else(|| p.offsets.get(&last)).or_else(|| p.offsets.values().next())?;
    let a = Rect::work(&m);
    let sf = m.scale_factor();
    let size = w.outer_size().ok()?;
    Some(clamp((a.x + off.0 * sf, a.y + off.1 * sf), size, &m))
}

/// 记下卡片的位置。用自己设的位置算，不回读窗口：Linux 上挪窗口是异步的，马上读到的还是旧位置
pub fn record_at(app: &AppHandle, pos: PhysicalPosition<i32>, size: PhysicalSize<u32>, p: &mut Placement) {
    let r = Rect { x: pos.x as f64, y: pos.y as f64, w: size.width as f64, h: size.height as f64 };
    let Some(m) = best_monitor(app, &r) else { return };
    let a = Rect::work(&m);
    let sf = m.scale_factor();
    let id = monitor_id(&m);
    p.offsets.insert(id.clone(), ((r.x - a.x) / sf, (r.y - a.y) / sf));
    p.screen = Some(id);
}

/// 把一个位置挪进它所在那块屏的工作区
pub fn clamped(app: &AppHandle, pos: PhysicalPosition<i32>, size: PhysicalSize<u32>) -> PhysicalPosition<i32> {
    let r = Rect { x: pos.x as f64, y: pos.y as f64, w: size.width as f64, h: size.height as f64 };
    match best_monitor(app, &r) {
        Some(m) => clamp((r.x, r.y), size, &m),
        None => pos,
    }
}

/// 挨着另一张卡片（位置、大小给定）放：下面放不下就放右边
pub fn next_to(app: &AppHandle, w: &WebviewWindow, pos: PhysicalPosition<i32>, near: PhysicalSize<u32>) -> Option<PhysicalPosition<i32>> {
    let size = w.outer_size().ok()?;
    let r = Rect { x: pos.x as f64, y: pos.y as f64, w: near.width as f64, h: near.height as f64 };
    let m = best_monitor(app, &r)?;
    let gap = GAP * m.scale_factor();
    let a = Rect::work(&m);
    let below = r.y + r.h + gap;
    let p = if below + (size.height as f64) <= a.y + a.h { (r.x, below) } else { (r.x + r.w + gap, r.y) };
    Some(clamp(p, size, &m))
}

/// 第一次：挨着另一张卡片放，都没有就放到主屏右上角
pub fn default_position(app: &AppHandle, w: &WebviewWindow, near: Option<&WebviewWindow>) -> Option<PhysicalPosition<i32>> {
    let size = w.outer_size().ok()?;
    if let Some(n) = near.filter(|n| n.is_visible().unwrap_or(false)) {
        if let (Ok(p), Ok(s)) = (n.outer_position(), n.outer_size()) {
            return next_to(app, w, p, s);
        }
    }
    let m = app.primary_monitor().ok()??;
    let a = Rect::work(&m);
    let sf = m.scale_factor();
    Some(clamp((a.x + a.w - (540.0 * sf), a.y + 32.0 * sf), size, &m))
}

/// 内容变大后可能超出屏幕：按记录里那块屏挪回来（不能现算重叠最多的那块：往下长出屏幕后可能变成旁边的屏）
pub fn keep_on_screen(app: &AppHandle, w: &WebviewWindow, p: &Placement) {
    let Some(r) = window_rect(w) else { return };
    let m = p.screen.as_deref().and_then(|id| monitor_by_id(app, id)).or_else(|| best_monitor(app, &r));
    let Some(m) = m else { return };
    let Ok(size) = w.outer_size() else { return };
    let pos = clamp((r.x, r.y), size, &m);
    if pos.x as f64 != r.x || pos.y as f64 != r.y {
        let _ = w.set_position(pos);
    }
}

// MARK: - 拖动

/// 正在拖的卡片：按下时的光标位置和窗口位置，当前吸在哪（用来判断要不要重画对齐线）
pub struct Drag {
    pub label: String,
    cursor: PhysicalPosition<f64>,
    origin: PhysicalPosition<i32>,
    /// 最后一次设的位置（拖完按它记，不回读窗口）
    pub last: PhysicalPosition<i32>,
}

pub fn drag_start(app: &AppHandle, w: &WebviewWindow) -> Option<Drag> {
    let origin = w.outer_position().ok()?;
    Some(Drag { label: w.label().to_string(), cursor: app.cursor_position().ok()?, origin, last: origin })
}

/// 一个可以吸附的位置：窗口左上角该放的坐标、对齐线画在哪（物理像素）
type Snap = (f64, f64);

fn nearest(c: &[Snap], v: f64, limit: f64) -> Option<Snap> {
    c.iter()
        .filter(|s| (s.0 - v).abs() <= limit)
        .min_by(|a, b| (a.0 - v).abs().partial_cmp(&(b.0 - v).abs()).unwrap_or(std::cmp::Ordering::Equal))
        .copied()
}

/// 拖动中：算新位置，吸附，画对齐线
pub fn drag_move(app: &AppHandle, w: &WebviewWindow, d: &mut Drag) {
    let Ok(c) = app.cursor_position() else { return };
    let Ok(size) = w.outer_size() else { return };
    let raw = (d.origin.x as f64 + c.x - d.cursor.x, d.origin.y as f64 + c.y - d.cursor.y);
    // 光标在哪块屏就跟哪块屏对齐
    let cursor = Rect { x: c.x, y: c.y, w: 1.0, h: 1.0 };
    let Some(m) = best_monitor(app, &cursor).or_else(|| app.primary_monitor().ok().flatten()) else { return };
    let sf = m.scale_factor();
    let (cw, ch) = (size.width as f64, size.height as f64);
    let (mg, gap) = (MARGIN * sf, GAP * sf);
    let a = Rect::work(&m);
    let mut xs: Vec<Snap> = vec![
        (a.x, a.x),
        (a.x + mg, a.x + mg),
        (a.x + a.w - cw, a.x + a.w),
        (a.x + a.w - mg - cw, a.x + a.w - mg),
        (a.x + (a.w - cw) / 2.0, a.x + a.w / 2.0),
    ];
    let mut ys: Vec<Snap> = vec![
        (a.y, a.y),
        (a.y + mg, a.y + mg),
        (a.y + a.h - ch, a.y + a.h),
        (a.y + a.h - mg - ch, a.y + a.h - mg),
        (a.y + (a.h - ch) / 2.0, a.y + a.h / 2.0),
    ];
    for other in CARDS.iter().filter(|l| **l != d.label).filter_map(|l| app.get_webview_window(l)) {
        if !other.is_visible().unwrap_or(false) {
            continue;
        }
        let Some(f) = window_rect(&other) else { continue };
        // 左边、右边、中线对齐；或者隔一点并排（线画在两张中间）
        xs.extend([
            (f.x, f.x),
            (f.x + f.w - cw, f.x + f.w),
            (f.x + (f.w - cw) / 2.0, f.x + f.w / 2.0),
            (f.x + f.w + gap, f.x + f.w + gap / 2.0),
            (f.x - gap - cw, f.x - gap / 2.0),
        ]);
        // 顶边、底边对齐；或者隔一点上下叠放
        ys.extend([
            (f.y, f.y),
            (f.y + f.h - ch, f.y + f.h),
            (f.y + f.h + gap, f.y + f.h + gap / 2.0),
            (f.y - gap - ch, f.y - gap / 2.0),
        ]);
    }
    let sx = nearest(&xs, raw.0, SNAP * sf);
    let sy = nearest(&ys, raw.1, SNAP * sf);
    let pos = PhysicalPosition::new(sx.map_or(raw.0, |s| s.0).round() as i32, sy.map_or(raw.1, |s| s.0).round() as i32);
    let _ = w.set_position(pos);
    d.last = pos;
    show_guides(app, &m, sx.map(|s| s.1), sy.map(|s| s.1));
}

pub fn drag_end(app: &AppHandle) {
    if let Some(g) = app.get_webview_window("guides") {
        let _ = g.hide();
    }
}

/// 对齐线窗口：铺满这块屏、透明、不接鼠标；线的位置换算成窗口里的逻辑像素发给它
fn show_guides(app: &AppHandle, m: &Monitor, x: Option<f64>, y: Option<f64>) {
    let Some(g) = app.get_webview_window("guides") else { return };
    if x.is_none() && y.is_none() {
        let _ = g.hide();
        return;
    }
    let sf = m.scale_factor();
    let (mp, ms) = (m.position(), m.size());
    if g.outer_position().ok() != Some(*mp) {
        let _ = g.set_position(*mp);
    }
    if g.outer_size().ok() != Some(*ms) {
        let _ = g.set_size(*ms);
    }
    // 按窗口实际在哪算线的位置：GNOME 会自己摆这个窗口（比如挪到 Dock 右边），不一定在屏幕左上角
    let origin = g.outer_position().unwrap_or(*mp);
    let _ = g.emit("guides", (x.map(|v| (v - origin.x as f64) / sf), y.map(|v| (v - origin.y as f64) / sf)));
    if !g.is_visible().unwrap_or(false) {
        // 先显示再设鼠标穿透：Linux 上窗口没显示过时还没真正建出来，先设穿透会让 tao 崩溃
        let _ = g.show();
        let _ = g.set_ignore_cursor_events(true);
    }
}
