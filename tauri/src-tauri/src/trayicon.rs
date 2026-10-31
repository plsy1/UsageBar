// Windows 托盘图标：直接画出百分比（不用悬停、不用点开就能看到）
//   32×32 深色圆角方块，上面是白色像素数字，下面一条进度条
//   100% 缩放下托盘图标显示成 16×16，这里的 5×7 像素字按 2 倍画，缩小后正好一像素对一像素

use tauri::image::Image;

const SIZE: usize = 32;

/// 5×7 像素数字，每行低 5 位有效，最高位在左
const FONT_5X7: [[u8; 7]; 10] = [
    [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E], // 0
    [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E], // 1
    [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F], // 2
    [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E], // 3
    [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02], // 4
    [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E], // 5
    [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E], // 6
    [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08], // 7
    [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E], // 8
    [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C], // 9
];

/// 3×5 像素数字（三位数「100」时用），每行低 3 位有效
const FONT_3X5: [[u8; 5]; 10] = [
    [7, 5, 5, 5, 7], // 0
    [2, 6, 2, 2, 7], // 1
    [7, 1, 7, 4, 7], // 2
    [7, 1, 7, 1, 7], // 3
    [5, 5, 7, 1, 1], // 4
    [7, 4, 7, 1, 7], // 5
    [7, 4, 7, 5, 7], // 6
    [7, 1, 1, 1, 1], // 7
    [7, 5, 7, 5, 7], // 8
    [7, 5, 7, 1, 7], // 9
];

struct Canvas(Vec<u8>);

impl Canvas {
    fn new() -> Self {
        Canvas(vec![0; SIZE * SIZE * 4])
    }

    fn put(&mut self, x: usize, y: usize, c: [u8; 4]) {
        if x < SIZE && y < SIZE {
            let i = (y * SIZE + x) * 4;
            self.0[i..i + 4].copy_from_slice(&c);
        }
    }

    fn rect(&mut self, x: usize, y: usize, w: usize, h: usize, c: [u8; 4]) {
        for yy in y..y + h {
            for xx in x..x + w {
                self.put(xx, yy, c);
            }
        }
    }

    /// 圆角背景：四个角按半径挖掉
    fn rounded_bg(&mut self, r: usize, c: [u8; 4]) {
        for y in 0..SIZE {
            for x in 0..SIZE {
                let dx = if x < r { r - x } else if x >= SIZE - r { x + 1 + r - SIZE } else { 0 };
                let dy = if y < r { r - y } else if y >= SIZE - r { y + 1 + r - SIZE } else { 0 };
                if dx * dx + dy * dy <= r * r {
                    self.put(x, y, c);
                }
            }
        }
    }

    /// 按位图画一个字形，每个像素放大 scale 倍
    fn glyph(&mut self, rows: &[u8], width: usize, x: usize, y: usize, scale: usize, c: [u8; 4]) {
        for (ry, bits) in rows.iter().enumerate() {
            for rx in 0..width {
                if bits >> (width - 1 - rx) & 1 == 1 {
                    self.rect(x + rx * scale, y + ry * scale, scale, scale, c);
                }
            }
        }
    }
}

const WHITE: [u8; 4] = [255, 255, 255, 255];

/// value：要显示的百分比（None 画一个短横线表示还没数据）；fill：进度条比例 0..=100
pub fn render(value: Option<i64>, fill: f64) -> Image<'static> {
    let mut c = Canvas::new();
    c.rounded_bg(7, [44, 44, 46, 255]);

    match value.map(|v| v.clamp(0, 100).to_string()) {
        Some(text) if text.len() == 3 => {
            // 「100」：3×5 字按 2 倍画，宽 3×6 + 2×2 = 22
            let (w, gap, scale) = (3, 2, 2);
            let total = text.len() * w * scale + (text.len() - 1) * gap;
            let mut x = (SIZE - total) / 2 & !1;  // 对齐到偶数像素，缩成 16×16 时才不糊
            for ch in text.bytes() {
                c.glyph(&FONT_3X5[(ch - b'0') as usize], w, x, 8, scale, WHITE);
                x += w * scale + gap;
            }
        }
        Some(text) => {
            // 一两位数：5×7 字按 2 倍画
            let (w, gap, scale) = (5, 2, 2);
            let total = text.len() * w * scale + (text.len() - 1) * gap;
            let mut x = (SIZE - total) / 2 & !1;
            for ch in text.bytes() {
                c.glyph(&FONT_5X7[(ch - b'0') as usize], w, x, 6, scale, WHITE);
                x += w * scale + gap;
            }
        }
        None => c.rect(10, 12, 12, 2, WHITE),
    }

    // 进度条：底部 4 像素（缩小后正好 2 像素），位置也都是偶数
    let track_w = SIZE - 8;
    // rect 是直接覆盖像素、不做混合，所以轨道要用不透明的灰（不然在浅色任务栏上会透出白色，看着像满格）
    c.rect(4, 24, track_w, 4, [102, 102, 104, 255]);
    let filled = ((fill.clamp(0.0, 100.0) / 100.0) * (track_w / 2) as f64).round() as usize * 2;
    c.rect(4, 24, filled, 4, WHITE);

    Image::new_owned(c.0, SIZE as u32, SIZE as u32)
}
