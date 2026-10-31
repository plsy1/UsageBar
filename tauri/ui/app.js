// 窗口界面：「额度」和「设置」两页；数据和设置都在 Rust 那边（src-tauri/src/main.rs）
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// 中文原文就是 key
const T = {
  nav_usage: ['额度', '上限', 'Limits'],
  nav_settings: ['设置', '設定', 'Settings'],
  usage_sub: ['Claude 与 Codex 的剩余用量', 'Claude と Codex の残り使用量', 'Remaining Claude and Codex usage'],
  settings_sub: ['托盘、语言和刷新频率', 'トレイ、言語、更新頻度', 'Tray, language and refresh frequency'],
  refresh: ['立即刷新', '今すぐ更新', 'Refresh Now'],
  open_window: ['打开窗口', 'ウィンドウを開く', 'Open Window'],
  refreshing: ['正在刷新…', '更新中…', 'Refreshing…'],
  updated: ['更新于 %s', '更新 %s', 'Updated %s'],
  loading: ['正在获取用量…', '使用量を取得中…', 'Fetching usage…'],
  used: ['已用 %s%', '使用済み %s%', '%s% used'],
  left: ['剩 %s%', '残り %s%', '%s% left'],
  five_hour: ['5 小时', '5時間', '5 hours'],
  weekly: ['本周', '今週', 'Weekly'],
  weekly_opus: ['本周 Opus', '今週 Opus', 'Weekly Opus'],
  weekly_sonnet: ['本周 Sonnet', '今週 Sonnet', 'Weekly Sonnet'],
  hours: ['%s 小时', '%s時間', '%s hours'],
  days: ['%s 天', '%s日', '%s days'],
  resets_in: ['%s后重置', '%s後にリセット', 'resets in %s'],
  d_h: ['%d天%h小时', '%d日%h時間', '%dd %hh'],
  h_m: ['%h小时%m分', '%h時間%m分', '%hh %mm'],
  m: ['%m分钟', '%m分', '%mm'],
  claude_no_login: ['读不到 Claude Code 登录信息 · 在终端运行 claude auth login 登录一次', 'Claude Code のログイン情報が見つかりません · ターミナルで claude auth login を実行してください', 'No Claude Code login found · run claude auth login in a terminal'],
  claude_expired: ['Claude Code 登录已失效 · 在终端运行 claude auth login 重新登录', 'Claude Code のログインが期限切れです · claude auth login を実行してください', 'Claude Code login expired · run claude auth login in a terminal'],
  codex_no_login: ['读不到 Codex 登录信息或会话记录', 'Codex のログイン情報またはセッション記録が見つかりません', 'No Codex login or session history found'],
  network: ['网络错误', 'ネットワークエラー', 'Network error'],
  http: ['请求失败（HTTP %s）', 'リクエスト失敗（HTTP %s）', 'Request failed (HTTP %s)'],
  codex_cache: ['本地缓存 · 数据时间 %s', 'ローカルキャッシュ · データ時刻 %s', 'Local cache · data from %s'],
  codex_cache_expired: ['登录过期，显示本地缓存（打开 Codex 会自动刷新）· 数据时间 %s', 'ログイン期限切れのためローカルキャッシュを表示 · データ時刻 %s', 'Login expired, showing local cache · data from %s'],
  codex_cache_http: ['接口请求失败，显示本地缓存 · 数据时间 %s', 'API リクエスト失敗、ローカルキャッシュを表示 · データ時刻 %s', 'API request failed, showing local cache · data from %s'],
  footnote: ['托盘图标旁（Linux）或鼠标悬停提示里（Windows）显示每家最紧的那个额度', 'トレイ（Linux はアイコンの横、Windows はツールチップ）に各サービスで最も残りが少ない上限を表示', 'The tray shows each service\'s tightest limit (next to the icon on Linux, in the tooltip on Windows)'],
  g_general: ['通用', '一般', 'General'],
  g_display: ['额度显示', '上限の表示', 'Limits'],
  launch: ['开机启动', 'ログイン時に起動', 'Launch at Login'],
  language: ['语言', '言語', 'Language'],
  lang_auto: ['跟随系统', 'システムに合わせる', 'System'],
  refresh_interval: ['刷新间隔', '更新間隔', 'Refresh Interval'],
  minutes: ['%s 分钟', '%s 分', '%s min'],
  display: ['显示数值', '表示する値', 'Show'],
  remaining: ['剩余', '残り', 'Remaining'],
  used_opt: ['已使用', '使用済み', 'Used'],
  tray_label: ['托盘名称', 'トレイの表示名', 'Tray Labels'],
  short: ['简写（Cc / Cx）', '略称（Cc / Cx）', 'Short (Cc / Cx)'],
  full: ['全名', 'フルネーム', 'Full'],
};

let state = null;
let page = 'usage';
// 托盘点开的小面板（Windows）：同一个页面，地址带 #flyout
const FLYOUT = location.hash === '#flyout';
let autostart = false;

const L = () => ({ zh: 0, ja: 1, en: 2 })[state?.lang] ?? 2;
const t = (key, ...args) => {
  let s = (T[key] || [key, key, key])[L()];
  for (const a of args) s = s.replace('%s', a);
  return s;
};
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const clock = (sec) => new Date(sec * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
const dateTime = (sec) => new Date(sec * 1000).toLocaleString([], { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });

function windowLabel(w) {
  if (w.kind === 'hours' || w.kind === 'days') return t(w.kind, w.amount);
  return T[w.kind] ? t(w.kind) : w.kind;
}

function resetText(at) {
  // 差几秒到整分钟就进位（接口常给 05:59:59.x）
  const s = Math.max(0, Math.floor((at + 5) / 60) * 60 - Date.now() / 1000);
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  const rel = d > 0 ? t('d_h').replace('%d', d).replace('%h', h)
    : h > 0 ? t('h_m').replace('%h', h).replace('%m', m)
    : t('m').replace('%m', m);
  return t('resets_in', rel);
}

function providerHTML(p) {
  const used = state.settings.display === 'used';
  let html = `<div class="panel provider"><div class="name">${esc(p.name)}${p.plan ? `<span class="plan">${esc(p.plan)}</span>` : ''}</div>`;
  if (p.error) html += `<div class="error">${esc(t(p.error, p.detail ?? ''))}</div>`;
  for (const w of p.windows) {
    const v = used ? Math.min(100, w.used) : Math.max(0, 100 - w.used);
    html += `<div class="row">
      <div class="top"><span>${esc(windowLabel(w))}</span><span class="value">${t(used ? 'used' : 'left', Math.round(v))}</span></div>
      <div class="bar"><div style="width:${v}%"></div></div>
      ${w.resets_at ? `<div class="reset">${esc(resetText(w.resets_at))}</div>` : ''}
    </div>`;
  }
  if (p.note) html += `<div class="note">${esc(t(p.note, p.detail ? dateTime(p.detail) : ''))}</div>`;
  return html + '</div>';
}

function usagePage() {
  const s = state.settings;
  const shown = state.providers.filter((p) => (p.name === 'Claude' ? s.show_claude : s.show_codex));
  const status = state.loading ? t('refreshing') : state.updated ? t('updated', clock(state.updated)) : '';
  return `<div class="header">
      <div><h1>${t('nav_usage')}</h1><div class="sub">${t('usage_sub')}</div></div>
      <div class="spacer"></div>
      <span class="sub">${status}</span>
      <button class="btn" id="refresh" ${state.loading ? 'disabled' : ''}>${t('refresh')}</button>
    </div>
    ${state.providers.length === 0 ? `<div class="sub">${t('loading')}</div>` : `<div class="providers">${shown.map(providerHTML).join('')}</div>`}
    <div class="footnote">${t('footnote')}</div>`;
}

function flyoutPage() {
  const s = state.settings;
  const shown = state.providers.filter((p) => (p.name === 'Claude' ? s.show_claude : s.show_codex));
  const status = state.loading ? t('refreshing') : state.updated ? t('updated', clock(state.updated)) : t('loading');
  return `<div class="providers">${shown.map(providerHTML).join('')}</div>
    <div class="fly-foot">
      <span class="sub">${status}</span><span class="spacer"></span>
      <button class="btn" id="refresh" ${state.loading ? 'disabled' : ''}>${t('refresh')}</button>
      <button class="btn" id="open-main">${t('open_window')}</button>
    </div>`;
}

// 小面板的高度跟着内容走
function fitFlyout() {
  const h = Math.ceil(document.getElementById('content').scrollHeight);
  window.__TAURI__.window.getCurrentWindow().setSize(new window.__TAURI__.dpi.LogicalSize(340, h)).catch(() => {});
}

function seg(key, options) {
  const cur = state.settings[key];
  return `<div class="seg">${options.map(([v, label]) => `<button data-set="${key}" data-val="${v}" class="${cur === v ? 'on' : ''}">${esc(label)}</button>`).join('')}</div>`;
}
const toggle = (id, on) => `<label class="switch"><input type="checkbox" id="${id}" ${on ? 'checked' : ''}><span></span></label>`;

function settingsPage() {
  const s = state.settings;
  const langs = [['auto', t('lang_auto')], ['zh', '中文'], ['ja', '日本語'], ['en', 'English']];
  return `<div class="header"><div><h1>${t('nav_settings')}</h1><div class="sub">${t('settings_sub')}</div></div></div>
    <div class="group-title">${t('g_general')}</div>
    <div class="panel group">
      <div class="field"><span>${t('launch')}</span>${toggle('autostart', autostart)}</div>
      <div class="field"><span>${t('language')}</span>
        <select id="language">${langs.map(([v, l]) => `<option value="${v}" ${s.language === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>
      <div class="field"><span>${t('refresh_interval')}</span>
        <select id="refresh_minutes">${[1, 2, 5, 10, 15, 30].map((m) => `<option value="${m}" ${s.refresh_minutes === m ? 'selected' : ''}>${t('minutes', m)}</option>`).join('')}</select></div>
    </div>
    <div class="group-title">${t('g_display')}</div>
    <div class="panel group">
      <div class="field"><span>${t('display')}</span>${seg('display', [['remaining', t('remaining')], ['used', t('used_opt')]])}</div>
      <div class="field"><span>${t('tray_label')}</span>${seg('menu_label', [['short', t('short')], ['full', t('full')]])}</div>
      <div class="field"><span>Claude</span>${toggle('show_claude', s.show_claude)}</div>
      <div class="field"><span>Codex</span>${toggle('show_codex', s.show_codex)}</div>
    </div>`;
}

function render() {
  if (!state) return;
  document.documentElement.lang = state.lang;
  document.querySelectorAll('[data-t]').forEach((el) => (el.textContent = t(el.dataset.t)));
  document.querySelectorAll('.nav').forEach((b) => b.classList.toggle('active', b.dataset.page === page));
  if (FLYOUT) {
    document.getElementById('content').innerHTML = flyoutPage();
    fitFlyout();
    return;
  }
  document.getElementById('content').innerHTML = page === 'usage' ? usagePage() : settingsPage();
}

async function save(patch) {
  state = await invoke('set_settings', { settings: { ...state.settings, ...patch } });
  render();
}

// 事件委托：重绘后也能点
document.addEventListener('click', (e) => {
  const nav = e.target.closest('.nav');
  if (nav) { page = nav.dataset.page; render(); return; }
  if (e.target.id === 'refresh') { invoke('refresh_now'); return; }
  if (e.target.id === 'open-main') { invoke('open_main'); return; }
  const b = e.target.closest('[data-set]');
  if (b) save({ [b.dataset.set]: b.dataset.val });
});
document.addEventListener('change', async (e) => {
  const el = e.target;
  if (el.id === 'language') save({ language: el.value });
  else if (el.id === 'refresh_minutes') save({ refresh_minutes: Number(el.value) });
  else if (el.id === 'show_claude' || el.id === 'show_codex') save({ [el.id]: el.checked });
  else if (el.id === 'autostart') {
    await invoke(el.checked ? 'plugin:autostart|enable' : 'plugin:autostart|disable').catch(() => {});
    autostart = await invoke('plugin:autostart|is_enabled').catch(() => false);
    render();
  }
});

(async () => {
  if (FLYOUT) document.body.classList.add('flyout');
  document.getElementById('version').textContent = await window.__TAURI__.app.getVersion().catch(() => '');
  autostart = await invoke('plugin:autostart|is_enabled').catch(() => false);
  state = await invoke('get_state');
  render();
  await listen('state', (e) => { state = e.payload; render(); });
  // 重置倒计时每分钟走一次
  setInterval(() => { if (FLYOUT || page === 'usage') render(); }, 60000);
})();
