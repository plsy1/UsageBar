// 用量统计页（照 macOS 版 StatsView）：筛选、汇总、走势图、热力图、按应用 / 模型 / 项目 / 请求明细的表格、请求详情
// 数据由 Rust 按条件从库里算好（stats_query），这里只负责画。用到 app.js 里的 t、esc、state、invoke、money、abbrev、pct

Object.assign(T, {
  nav_stats: ['用量统计', '使用量の統計', 'Usage Statistics'],
  r_today: ['今天', '今日', 'Today'],
  r_cycle: ['重置以来', 'リセット以降', 'Since Reset'],
  r_24h: ['近 24 小时', '過去 24 時間', 'Last 24 Hours'],
  r_7d: ['近 7 天', '過去 7 日間', 'Last 7 Days'],
  r_14d: ['近 14 天', '過去 14 日間', 'Last 14 Days'],
  r_30d: ['近 30 天', '過去 30 日間', 'Last 30 Days'],
  r_all: ['全部时间', 'すべての期間', 'All Time'],
  r_custom: ['自定义', 'カスタム', 'Custom'],
  all_apps: ['全部', 'すべて', 'All'],
  since_from: ['%s 自 %s 起', '%s は %s から', '%s since %s'],
  now: ['现在', '現在', 'Now'],
  est_cost: ['估算成本', '推定コスト', 'Est. Cost'],
  new_input: ['新增输入', '新規入力', 'New Input'],
  output: ['输出', '出力', 'Output'],
  cache_read: ['缓存读取', 'キャッシュ読み取り', 'Cache Read'],
  cache_write: ['缓存写入', 'キャッシュ書き込み', 'Cache Write'],
  more_metrics: ['更多指标', 'その他の指標', 'More Metrics'],
  collapse: ['收起', '閉じる', 'Show Less'],
  tokens_hourly: ['Tokens · 按小时', 'Tokens · 時間別', 'Tokens · Hourly'],
  tokens_daily: ['Tokens · 按天', 'Tokens · 日別', 'Tokens · Daily'],
  line: ['曲线图', '折れ線', 'Line'],
  bars: ['柱状图', '棒グラフ', 'Bars'],
  daily_usage: ['每日用量', '日ごとの使用量', 'Daily Usage'],
  less: ['少', '少', 'Less'],
  more: ['多', '多', 'More'],
  n_requests: ['%s 次请求', '%s リクエスト', '%s requests'],
  by_app: ['按应用', 'アプリ別', 'By App'],
  by_model: ['按模型', 'モデル別', 'By Model'],
  by_project: ['按项目', 'プロジェクト別', 'By Project'],
  request_log: ['请求明细', 'リクエスト履歴', 'Request Log'],
  col_app: ['应用', 'アプリ', 'App'],
  col_model: ['模型', 'モデル', 'Model'],
  col_project: ['项目', 'プロジェクト', 'Project'],
  col_time: ['时间', '時刻', 'Time'],
  col_cost: ['成本', 'コスト', 'Cost'],
  col_hit: ['命中率', 'ヒット率', 'Hit Rate'],
  col_success: ['成功率', '成功率', 'Success'],
  col_speed: ['速度', '速度', 'Speed'],
  col_ttft: ['首字', '初回応答', 'TTFT'],
  col_duration: ['总耗时', '所要時間', 'Duration'],
  col_status: ['状态码', 'ステータス', 'Status'],
  all_status: ['全部状态码', 'すべてのステータス', 'All Status Codes'],
  page_of: ['第 %s / %s 页 · 共 %s 条', '%s / %s ページ · 全 %s 件', 'Page %s of %s · %s total'],
  top_rows: ['前 %s 行 · 共 %s 行', '上位 %s 行 · 全 %s 行', 'Top %s of %s rows'],
  rows_total: ['共 %s 行', '全 %s 行', '%s rows'],
  show_all: ['显示全部', 'すべて表示', 'Show All'],
  no_usage: ['这段时间没有用量', 'この期間の使用量はありません', 'No usage in this period'],
  this_machine: ['本机', 'この PC', 'This Computer'],
  all_machines: ['全部机器', 'すべてのマシン', 'All Machines'],
  n_machines: ['%s 台机器', '%s 台のマシン', '%s Machines'],
  unknown_dir: ['未知目录', '不明なディレクトリ', 'Unknown Directory'],
  details: ['请求详情', 'リクエストの詳細', 'Request Details'],
  basics: ['基本信息', '基本情報', 'Basics'],
  request_id: ['请求 ID', 'リクエスト ID', 'Request ID'],
  failed_req: ['请求失败', 'リクエスト失敗', 'Request failed'],
  token_usage: ['Tokens 用量', 'Tokens の使用量', 'Tokens'],
  cost_breakdown: ['成本明细（美元）', 'コストの内訳（USD）', 'Cost Breakdown (USD)'],
  total: ['合计', '合計', 'Total'],
  performance: ['性能', 'パフォーマンス', 'Performance'],
  ttft_est: ['首字（估算）', '初回応答（推定）', 'TTFT (est.)'],
  duration_est: ['总耗时（估算）', '所要時間（推定）', 'Duration (est.)'],
  speed_short: ['输出少于 200 tokens，不估算速度', '出力が 200 tokens 未満のため速度は推定しません', 'Under 200 output tokens, speed not estimated'],
  timing_note: ['耗时按会话记录的时间戳估算：从请求发出（上一条用户消息或工具结果）到回复最后一段写入；首字取第一段内容写入的时间，日志要等一整段生成完才写，所以偏大。',
    '所要時間はセッション記録のタイムスタンプから推定します（リクエスト送信から返答の最後の書き込みまで）。初回応答は最初の内容が書き込まれた時刻で、1 段落分の生成を待ってから記録されるため大きめに出ます。',
    'Times are estimated from session log timestamps, from when the request was sent to when the last part of the reply was written. TTFT is when the first part was written; logs are written after a whole part is generated, so it runs high.'],
  stats_foot: ['成本按 models.dev 的 API 价格估算，统计本机和已添加的远程机器上的会话记录', 'コストは models.dev の API 価格による推定で、この PC と追加したリモートマシンのセッション記録を集計しています',
    'Cost is estimated from models.dev API prices and covers session logs on this computer and the remote machines you added'],
  unpriced: ['没有价格', '価格なし', 'No price'],
});

const STORE = (k, v) => { try { if (v === undefined) return JSON.parse(localStorage.getItem('stats.' + k)); localStorage.setItem('stats.' + k, JSON.stringify(v)); } catch { return null; } };
let statsQ = Object.assign({ range: 'today', source: 'all', hidden: [], status: 0, page: 0, tab: 'log', show_all: false, custom_start: null, custom_end: null }, STORE('q') || {});
statsQ.page = 0;
let statsView = null, statsBusy = false, statsAgain = false;
let chartStyle = STORE('chart') || 'line';
let moreTiles = STORE('more') || false;
let selected = null;      // 打开详情的那条请求
let machineOpen = false;  // 机器筛选的弹出面板

async function fetchStats() {
  if (statsBusy) { statsAgain = true; return; }
  statsBusy = true;
  STORE('q', statsQ);
  const v = await invoke('stats_query', { query: { ...statsQ, cycle: state?.cycle || {} } }).catch(() => null);
  statsBusy = false;
  if (v) statsView = v;
  if (statsAgain) { statsAgain = false; return fetchStats(); }
  if (page === 'stats') render();
}

function setQ(patch) {
  Object.assign(statsQ, patch);
  if (!('page' in patch)) statsQ.page = 0;
  fetchStats();
}

const intl = () => ({ zh: 'zh-CN', ja: 'ja-JP' })[state.lang] ?? 'en-US';
const md = (ms) => { const d = new Date(ms); return `${d.getMonth() + 1}/${d.getDate()}`; };
const mdhm = (ms) => { const d = new Date(ms); return `${md(ms)} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; };
const ymd = (ms) => { const d = new Date(ms); return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`; };
const secs = (v) => (v == null ? '—' : v < 10 ? v.toFixed(1) + 's' : v < 60 ? Math.round(v) + 's' : `${Math.floor(v / 60)}m${Math.round(v % 60)}s`);
const num = (n) => (n ?? 0).toLocaleString();
const machineName = (m) => (m === '' ? t('this_machine') : m);
const groupTitle = (s) => s.replace('@local', t('this_machine')).replace('@unknown', t('unknown_dir'));

// MARK: 顶部

function rangeLabel() {
  if (statsQ.range !== 'custom') return t('r_' + statsQ.range);
  const s = statsQ.custom_start ? mdhm(statsQ.custom_start) : '';
  return `${s} – ${statsQ.custom_end ? mdhm(statsQ.custom_end) : t('now')}`;
}

function toolbar(v) {
  const ranges = ['today', 'cycle', '24h', '7d', '14d', '30d', 'all', 'custom'];
  const seg2 = [['all', t('all_apps')], ['Claude', 'Claude'], ['Codex', 'Codex']].map(([val, l]) =>
    `<button data-stat-source="${val}" class="${statsQ.source === val ? 'on' : ''}">${esc(l)}</button>`).join('');
  const machines = v?.machines || [''];
  const shown = machines.filter((m) => !statsQ.hidden.includes(m));
  const machineBtn = statsQ.source !== 'Claude' && machines.length > 1 ? `
    <div class="pop-wrap">
      <button class="btn pill" id="machine-btn">▭ ${esc(shown.length === machines.length ? t('all_machines') : shown.length === 1 ? machineName(shown[0]) : t('n_machines', shown.length))} ▾</button>
      ${machineOpen ? `<div class="pop">
        <label><input type="checkbox" data-machine-all ${statsQ.hidden.length ? '' : 'checked'}> ${t('all_machines')}</label><hr>
        ${machines.map((m) => `<label><input type="checkbox" data-machine="${esc(m)}" ${statsQ.hidden.includes(m) ? '' : 'checked'}
          ${!statsQ.hidden.includes(m) && shown.length === 1 ? 'disabled' : ''}> ${esc(machineName(m))}</label>`).join('')}
      </div>` : ''}
    </div>` : '';
  const custom = statsQ.range === 'custom' ? `
    <input type="datetime-local" id="custom-start" value="${statsQ.custom_start ? toLocalInput(statsQ.custom_start) : ''}">
    <span class="sub">–</span>
    <input type="datetime-local" id="custom-end" value="${statsQ.custom_end ? toLocalInput(statsQ.custom_end) : ''}" placeholder="${t('now')}">` : '';
  const status = state.stats_loading ? t('refreshing') : state.usage.updated ? t('updated', clock(state.usage.updated)) : '';
  return `<div class="stats-bar">
    <select id="stat-range">${ranges.map((r) => `<option value="${r}" ${statsQ.range === r ? 'selected' : ''}>${esc(t('r_' + r))}</option>`).join('')}</select>
    ${custom}
    <div class="seg">${seg2}</div>
    ${machineBtn}
    <div class="spacer"></div>
    <span class="sub">${status}</span>
    <button class="btn" id="stats-refresh" ${state.stats_loading ? 'disabled' : ''}>↻</button>
  </div>`;
}

function toLocalInput(ms) {
  const d = new Date(ms - new Date(ms).getTimezoneOffset() * 60000);
  return d.toISOString().slice(0, 16);
}

function caption(v) {
  if (statsQ.range !== 'cycle' || !v) return '';
  return `<div class="sub caption">${Object.entries(v.starts).map(([s, ms]) => esc(t('since_from', s, mdhm(ms)))).join(' · ')}</div>`;
}

function tiles(v) {
  const s = v.summary;
  const tile = (k, val, small) => `<div class="tile"><div class="sub">${k}</div><div class="${small ? 'tv small' : 'tv'}">${val}</div></div>`;
  return `<div class="panel tiles-wrap">
    <div class="tiles">${tile(t('est_cost'), money(s.cost))}${tile(t('requests'), num(s.requests))}${tile('Tokens', abbrev(s.tokens))}${tile(t('hit_rate'), pct(s.hit_rate))}</div>
    ${moreTiles ? `<div class="tiles more">${tile(t('new_input'), abbrev(s.input), 1)}${tile(t('output'), abbrev(s.output), 1)}${tile(t('cache_read'), abbrev(s.cache_read), 1)}${tile(t('cache_write'), abbrev(s.cache_write), 1)}</div>` : ''}
    <button class="more-btn" id="more-tiles" title="${t(moreTiles ? 'collapse' : 'more_metrics')}">${moreTiles ? '︿' : '﹀'}</button>
  </div>`;
}

// MARK: 走势图（SVG，悬停时显示虚线、圆点和小卡片）

function niceMax(v) {
  if (v <= 4) return 4; // 刻度是四等分取整，至少 4 才不会出现重复的刻度
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

// 曲线：单调的三次插值（不会冲过数据点，和 macOS 版的 .monotone 一样）
function monotonePath(pts) {
  if (pts.length < 2) return pts.length ? `M${pts[0][0]},${pts[0][1]}` : '';
  const n = pts.length, dx = [], dy = [], m = [];
  for (let i = 0; i < n - 1; i++) { dx[i] = pts[i + 1][0] - pts[i][0]; dy[i] = (pts[i + 1][1] - pts[i][1]) / dx[i]; }
  m[0] = dy[0]; m[n - 1] = dy[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = dy[i - 1] * dy[i] <= 0 ? 0 : (dy[i - 1] + dy[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (dy[i] === 0) { m[i] = m[i + 1] = 0; continue; }
    const a = m[i] / dy[i], b = m[i + 1] / dy[i], h = a * a + b * b;
    if (h > 9) { const s = 3 / Math.sqrt(h); m[i] = s * a * dy[i]; m[i + 1] = s * b * dy[i]; }
  }
  let d = `M${pts[0][0]},${pts[0][1]}`;
  for (let i = 0; i < n - 1; i++) {
    const [x0, y0] = pts[i], [x1, y1] = pts[i + 1], h = dx[i] / 3;
    d += ` C${x0 + h},${y0 + m[i] * h} ${x1 - h},${y1 - m[i + 1] * h} ${x1},${y1}`;
  }
  return d;
}

function chartPanel(v) {
  return `<div class="panel chart-panel">
    <div class="panel-head"><span class="sub strong">${t(v.hourly ? 'tokens_hourly' : 'tokens_daily')}</span><span class="spacer"></span>
      <div class="seg">${[['line', '⌇'], ['bar', '▮▮']].map(([s, l]) => `<button data-chart="${s}" title="${t(s === 'line' ? 'line' : 'bars')}" class="${chartStyle === s ? 'on' : ''}">${l}</button>`).join('')}</div>
    </div>
    <div class="chart" id="chart"></div>
  </div>`;
}

function drawChart() {
  const el = document.getElementById('chart');
  if (!el || !statsView) return;
  const v = statsView, data = v.buckets, W = el.clientWidth, H = 200;
  const L = 6, R = 56, T0 = 10, B = 24, pw = W - L - R, ph = H - T0 - B;
  const n = Math.max(1, data.length), bw = pw / n;
  const max = niceMax(Math.max(0, ...data.map((b) => b.tokens)));
  const x = (i) => L + (i + 0.5) * bw, y = (val) => T0 + ph - (val / max) * ph;
  let svg = '';
  for (let k = 0; k <= 4; k++) {
    const yy = T0 + (ph * k) / 4;
    svg += `<line class="grid" x1="${L}" x2="${L + pw}" y1="${yy}" y2="${yy}"/><text class="axis" x="${L + pw + 6}" y="${yy + 4}">${abbrev(Math.round(max * (1 - k / 4)))}</text>`;
  }
  // 横轴：刻度放在时段中间，间隔从常用的几档里挑，最多七八个；第一个从半个间隔处开始，免得贴边被截
  const steps = v.hourly ? [1, 2, 3, 4, 6, 12, 24] : [1, 2, 3, 7, 14, 30, 61, 91, 182];
  const step = steps.find((s) => n <= s * 8) ?? steps[steps.length - 1];
  for (let i = step > 1 ? Math.floor(step / 2) : 0; i < n; i += step) {
    const d = new Date(data[i].t);
    const label = v.hourly ? `${String(d.getHours()).padStart(2, '0')}:00` : md(data[i].t);
    svg += `<line class="grid dash" x1="${x(i)}" x2="${x(i)}" y1="${T0}" y2="${T0 + ph}"/><text class="axis" text-anchor="middle" x="${x(i)}" y="${H - 6}">${label}</text>`;
  }
  if (chartStyle === 'bar') {
    data.forEach((b, i) => { const h = (b.tokens / max) * ph; svg += `<rect class="bar" data-i="${i}" x="${x(i) - bw * 0.32}" y="${T0 + ph - h}" width="${Math.max(1, bw * 0.64)}" height="${h}" rx="2"/>`; });
  } else {
    const pts = data.map((b, i) => [x(i), y(b.tokens)]);
    const line = monotonePath(pts);
    if (pts.length) svg += `<path class="area" d="${line} L${pts[pts.length - 1][0]},${T0 + ph} L${pts[0][0]},${T0 + ph} Z"/><path class="line" d="${line}"/>`;
  }
  svg += `<g id="hover"></g>`;
  el.innerHTML = `<svg width="${W}" height="${H}">${svg}</svg><div class="tip" id="tip" hidden></div>`;
  const svgEl = el.querySelector('svg'), hover = el.querySelector('#hover'), tip = el.querySelector('#tip');
  svgEl.addEventListener('mousemove', (e) => {
    const r = svgEl.getBoundingClientRect(), i = Math.floor((e.clientX - r.left - L) / bw);
    if (i < 0 || i >= n) { hover.innerHTML = ''; tip.hidden = true; return; }
    const b = data[i];
    hover.innerHTML = `<line class="rule" x1="${x(i)}" x2="${x(i)}" y1="${T0}" y2="${T0 + ph}"/>` + (chartStyle === 'line' ? `<circle class="dot" cx="${x(i)}" cy="${y(b.tokens)}" r="4"/>` : '');
    svgEl.querySelectorAll('.bar').forEach((el2) => el2.classList.toggle('dim', Number(el2.dataset.i) !== i));
    const d = new Date(b.t);
    tip.innerHTML = `<b>${ymd(b.t)}${v.hourly ? ` ${String(d.getHours()).padStart(2, '0')}:00` : ''}</b>
      <div class="tip-row"><span class="sw"></span><span>Tokens</span><span>${num(b.tokens)}</span></div>
      <div class="tip-row"><span></span><span>${t('requests')}</span><span>${num(b.requests)}</span></div>
      <div class="tip-row"><span></span><span>${t('est_cost')}</span><span>${money(b.cost)}</span></div>`;
    tip.hidden = false;
    // 卡片放在虚线右边，靠近右边缘时放左边
    const right = x(i) < W * 0.62;
    tip.style.left = right ? `${x(i) + 12}px` : '';
    tip.style.right = right ? '' : `${W - x(i) + 12}px`;
  });
  svgEl.addEventListener('mouseleave', () => { hover.innerHTML = ''; tip.hidden = true; svgEl.querySelectorAll('.bar').forEach((b) => b.classList.remove('dim')); });
}

// MARK: 热力图（GitHub 那样：一列一周，最近一年，窗口窄时少几周）

function heatPanel() {
  return `<div class="panel heat-panel">
    <div class="panel-head"><span class="sub strong">${t('daily_usage')}</span><span class="spacer"></span><span class="sub" id="heat-info"></span></div>
    <div id="heat"></div>
  </div>`;
}

function drawHeat() {
  const el = document.getElementById('heat'), info = document.getElementById('heat-info');
  if (!el || !statsView) return;
  const days = new Map(statsView.heat.map((d) => [d.day, d]));
  // 有用量的日子按四分位分档，少数几天特别多也不会把其他天都压成最浅
  const sorted = statsView.heat.map((d) => d.tokens).filter((n) => n > 0).sort((a, b) => a - b);
  const cut = [0.25, 0.5, 0.75].map((q) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * q))] : 0);
  const level = (n) => (n <= 0 ? 0 : 1 + cut.filter((c) => n > c).length);
  const W = el.clientWidth, labelW = 30, gap = 3;
  const weeks = Math.max(8, Math.min(53, Math.floor((W - labelW) / (10 + gap))));
  const cell = Math.min(16, (W - labelW) / weeks - gap);
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const start = new Date(today); start.setDate(today.getDate() - ((today.getDay() + 6) % 7) - (weeks - 1) * 7);  // 每周从周一开始
  const date = (w, d) => { const x = new Date(start); x.setDate(start.getDate() + w * 7 + d); return x; };
  const key = (x) => `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
  const top = 18, H = top + 7 * (cell + gap);
  let svg = '';
  const monthName = (x) => x.toLocaleDateString(intl(), { month: 'short' });
  for (let w = 0; w < weeks; w++) {
    const m = (k) => date(k, 0).getMonth();
    // 月份写在这个月第一次出现的那一列上面；第一列只在这个月还要再占两列以上时才写
    if (w === 0 ? m(0) === m(2) : m(w) !== m(w - 1)) svg += `<text class="axis" x="${labelW + w * (cell + gap)}" y="12">${esc(monthName(date(w, 0)))}</text>`;
    for (let d = 0; d < 7; d++) {
      const x = date(w, d);
      if (x > today) continue;
      svg += `<rect class="hc l${level(days.get(key(x))?.tokens ?? 0)}" data-day="${key(x)}" data-ms="${x.getTime()}" x="${labelW + w * (cell + gap)}" y="${top + d * (cell + gap)}" width="${cell}" height="${cell}" rx="2.5"/>`;
    }
  }
  const wd = (d) => { const x = new Date(2024, 0, 1 + d); return x.toLocaleDateString(intl(), { weekday: 'short' }); };  // 2024-01-01 是周一
  for (const d of [1, 3, 5]) svg += `<text class="axis small" x="0" y="${top + d * (cell + gap) + cell * 0.75}">${esc(wd(d))}</text>`;
  el.innerHTML = `<svg width="${W}" height="${H}">${svg}</svg>`;
  const legend = () => `${t('less')} ${[0, 1, 2, 3, 4].map((l) => `<span class="hc-key l${l}"></span>`).join('')} ${t('more')}`;
  info.innerHTML = legend();
  const svgEl = el.querySelector('svg');
  let last = null;
  // 整张只挂一个监听，按坐标找格子（每格各挂一个的话滚动页面会卡）
  svgEl.addEventListener('mousemove', (e) => {
    const r = e.target.closest('rect.hc');
    if (r === last) return;
    last?.classList.remove('hover'); last = r;
    if (!r) { info.innerHTML = legend(); return; }
    r.classList.add('hover');
    const d = days.get(r.dataset.day);
    info.textContent = `${ymd(Number(r.dataset.ms))} · ${abbrev(d?.tokens ?? 0)} tokens · ${t('n_requests', num(d?.requests ?? 0))} · ${money(d?.cost ?? 0)}`;
  });
  svgEl.addEventListener('mouseleave', () => { last?.classList.remove('hover'); last = null; info.innerHTML = legend(); });
}

// MARK: 表格

function tabsBar(v) {
  const tabs = [['apps', 'by_app'], ['models', 'by_model'], ['projects', 'by_project'], ['log', 'request_log']];
  const right = statsQ.tab === 'log' ? `<select id="stat-status"><option value="0">${t('all_status')}</option>${v.statuses.map((c) =>
    `<option value="${c}" ${statsQ.status === c ? 'selected' : ''}>${c}</option>`).join('')}</select>` : '';
  return `<div class="tabs">${tabs.map(([k, l]) => `<button data-tab="${k}" class="${statsQ.tab === k ? 'on' : ''}">${t(l)}<span class="count">${num(v.counts[k] ?? 0)}</span></button>`).join('')}
    <span class="spacer"></span>${right}</div>`;
}

function groupTable(v) {
  const kind = statsQ.tab;
  const name = { apps: 'col_app', models: 'col_model', projects: 'col_project' }[kind];
  const showApp = kind !== 'apps';
  const head = `<tr><th class="name">${t(name)}</th>${showApp ? `<th>${t('col_app')}</th>` : ''}<th>${t('requests')}</th><th>${t('col_cost')}</th><th>Tokens</th><th>${t('col_hit')}</th><th>${t('col_success')}</th><th>${t('col_speed')}</th><th>${t('col_ttft')}</th></tr>`;
  const rows = v.groups.map((g) => `<tr>
    <td class="name ${kind === 'models' ? 'mono' : kind === 'projects' ? 'path' : ''}" title="${esc(g.detail ?? '')}">${kind === 'projects' ? `<bdi>${esc(groupTitle(g.title))}</bdi>` : esc(groupTitle(g.title))}</td>
    ${showApp ? `<td>${esc(g.apps)}</td>` : ''}
    <td>${num(g.summary.requests)}</td><td>${g.priced ? money(g.summary.cost) : '—'}</td><td>${abbrev(g.summary.tokens)}</td>
    <td>${pct(g.summary.hit_rate)}</td><td>${(g.success_rate * 100).toFixed(1)}%</td>
    <td>${g.speed == null ? '—' : `≈${Math.round(g.speed)} t/s`}</td><td>${g.first_token == null ? '—' : '≈' + secs(g.first_token)}</td></tr>`).join('');
  const foot = v.group_total > 50 ? `<div class="table-foot"><span class="sub">${statsQ.show_all ? t('rows_total', num(v.group_total)) : t('top_rows', 50, num(v.group_total))}</span><span class="spacer"></span>
    <button class="btn" id="show-all">${t(statsQ.show_all ? 'collapse' : 'show_all')}</button></div>` : '';
  return `<div class="table-wrap"><table>${head}${rows || `<tr><td colspan="9" class="empty">${t('no_usage')}</td></tr>`}</table></div>${foot}`;
}

function logTable(v) {
  const head = `<tr><th>${t('col_time')}</th><th>${t('col_app')}</th><th class="name">${t('col_model')}</th><th>${t('col_cost')}</th><th>${t('new_input')}</th><th>${t('output')}</th><th>${t('cache_read')}</th><th>${t('cache_write')}</th><th>${t('col_hit')}</th><th>${t('col_speed')}</th><th>${t('col_ttft')}</th><th>${t('col_duration')}</th><th>${t('col_status')}</th></tr>`;
  const today = statsQ.range === 'today';
  const rows = v.log.map((r, i) => {
    const d = new Date(r.time), hms = d.toLocaleTimeString(intl(), { hour12: false });
    return `<tr class="clickable ${selected?.id === r.id ? 'sel' : ''}" data-row="${i}">
      <td>${today ? hms : `${md(r.time)} ${hms}`}</td><td>${esc(r.source + (r.host ? ' · ' + r.host : ''))}</td><td class="name mono">${esc(r.model)}</td>
      <td>${r.status !== 200 ? '—' : r.cost == null ? '—' : '$' + r.cost.toFixed(4)}</td><td>${num(r.input)}</td><td>${num(r.output)}</td>
      <td>${abbrev(r.cache_read)}</td><td>${abbrev(r.cache_write)}</td><td>${pct(r.hit_rate)}</td>
      <td>${r.speed == null ? '—' : Math.round(r.speed) + ' t/s'}</td><td>${secs(r.first_token)}</td><td>${secs(r.duration)}</td>
      <td class="${r.status !== 200 ? 'bad' : 'sub'}">${r.status}</td></tr>`;
  }).join('');
  const pager = v.log_total ? `<div class="table-foot"><span class="sub">${t('page_of', v.page + 1, v.pages, num(v.log_total))}</span><span class="spacer"></span>
    <button class="btn" id="prev-page" ${v.page === 0 ? 'disabled' : ''}>‹</button><button class="btn" id="next-page" ${v.page >= v.pages - 1 ? 'disabled' : ''}>›</button></div>` : '';
  return `<div class="table-wrap"><table class="log">${head}${rows || `<tr><td colspan="13" class="empty">${t('no_usage')}</td></tr>`}</table></div>${pager}`;
}

function detailPanel() {
  const r = selected;
  if (!r) return '';
  const line = (k, val, mono) => `<div class="kv"><span class="sub">${k}</span><span class="${mono ? 'mono' : ''}">${esc(val)}</span></div>`;
  const b = r.breakdown;
  return `<div class="detail"><div class="detail-head"><b>${t('details')}</b><span class="spacer"></span><button class="btn plain" id="close-detail">✕</button></div>
    <div class="detail-body">
      <div class="group-title">${t('basics')}</div><div class="panel dgroup">
        ${line(t('col_time'), new Date(r.time).toLocaleString(intl(), { hour12: false }))}
        ${line(t('col_app'), r.source + (r.host ? ' · ' + r.host : ''))}${line(t('col_model'), r.model, 1)}
        ${r.project ? line(t('col_project'), r.project, 1) : ''}
        ${line(t('col_status'), r.status !== 200 ? `${r.status} · ${t('failed_req')}` : String(r.status))}${line(t('request_id'), r.id, 1)}</div>
      <div class="group-title">${t('token_usage')}</div><div class="panel dgroup">
        ${line(t('new_input'), num(r.input))}${line(t('output'), num(r.output))}${line(t('cache_read'), num(r.cache_read))}${line(t('cache_write'), num(r.cache_write))}${line(t('col_hit'), pct(r.hit_rate))}</div>
      <div class="group-title">${t('cost_breakdown')}</div><div class="panel dgroup">
        ${b ? `${line(t('new_input'), '$' + b.input.toFixed(4))}${line(t('output'), '$' + b.output.toFixed(4))}${line(t('cache_read'), '$' + b.cache_read.toFixed(4))}${line(t('cache_write'), '$' + b.cache_write.toFixed(4))}
          <div class="kv total"><span>${t('total')}</span><b>$${(b.input + b.output + b.cache_read + b.cache_write).toFixed(4)}</b></div>` : line(t('col_cost'), t('unpriced'))}</div>
      <div class="group-title">${t('performance')}</div><div class="panel dgroup">
        ${line(t('col_speed'), r.speed != null ? `${Math.round(r.speed)} t/s` : r.output < 200 ? t('speed_short') : '—')}${line(t('ttft_est'), secs(r.first_token))}${line(t('duration_est'), secs(r.duration))}</div>
      <div class="footnote">${t('timing_note')}</div>
    </div></div>`;
}

function statsPage() {
  const v = statsView;
  if (!v) { fetchStats(); return `${toolbar(null)}<div class="sub">${t('reading_logs')}</div>`; }
  return `${toolbar(v)}${caption(v)}${tiles(v)}${chartPanel(v)}${heatPanel()}
    <div class="panel tables">${tabsBar(v)}${statsQ.tab === 'log' ? logTable(v) : groupTable(v)}</div>
    <div class="footnote">${t('stats_foot')}</div>${detailPanel()}`;
}

// 页面插进去以后才知道宽度：图表和热力图这时再画
function afterStatsRender() {
  drawChart();
  drawHeat();
}

window.addEventListener('resize', () => { if (page === 'stats') { drawChart(); drawHeat(); } });

document.addEventListener('click', (e) => {
  if (page !== 'stats') return;
  const el = e.target;
  const src = el.closest('[data-stat-source]');
  if (src) return setQ({ source: src.dataset.statSource });
  const tab = el.closest('[data-tab]');
  if (tab) { statsQ.tab = tab.dataset.tab; return setQ({ tab: tab.dataset.tab, show_all: false }); }
  const ch = el.closest('[data-chart]');
  if (ch) { chartStyle = ch.dataset.chart; STORE('chart', chartStyle); return render(); }
  if (el.closest('#more-tiles')) { moreTiles = !moreTiles; STORE('more', moreTiles); return render(); }
  if (el.closest('#stats-refresh')) return invoke('refresh_stats_now');
  if (el.closest('#machine-btn')) { machineOpen = !machineOpen; return render(); }
  if (el.closest('#show-all')) return setQ({ show_all: !statsQ.show_all, page: statsQ.page });
  if (el.closest('#prev-page')) return setQ({ page: Math.max(0, statsQ.page - 1) });
  if (el.closest('#next-page')) return setQ({ page: statsQ.page + 1 });
  if (el.closest('#close-detail')) { selected = null; return render(); }
  const row = el.closest('[data-row]');
  if (row && statsView) { selected = statsView.log[Number(row.dataset.row)]; return render(); }
  // 点机器面板外面：收起
  if (machineOpen && !el.closest('.pop')) { machineOpen = false; render(); }
});

document.addEventListener('change', (e) => {
  if (page !== 'stats') return;
  const el = e.target;
  if (el.id === 'stat-range') {
    const patch = { range: el.value };
    if (el.value === 'custom' && !statsQ.custom_start) patch.custom_start = new Date().setHours(0, 0, 0, 0);
    return setQ(patch);
  }
  if (el.id === 'custom-start') return setQ({ custom_start: el.value ? new Date(el.value).getTime() : null });
  if (el.id === 'custom-end') return setQ({ custom_end: el.value ? new Date(el.value).getTime() : null });
  if (el.id === 'stat-status') return setQ({ status: Number(el.value) });
  if (el.dataset.machineAll !== undefined) return setQ({ hidden: [] });
  if (el.dataset.machine !== undefined) {
    const m = el.dataset.machine;
    const hidden = el.checked ? statsQ.hidden.filter((h) => h !== m) : [...statsQ.hidden, m];
    return setQ({ hidden });
  }
});
