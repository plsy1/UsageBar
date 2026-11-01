// 窗口界面：「用量统计」「额度」「桌面卡片」「设置」四页（统计页在 stats.js）；同一个页面也用作托盘小面板（#flyout）和桌面卡片（#card）
// 数据和设置都在 Rust 那边（src-tauri/src/main.rs）
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// 中文原文就是 key
const T = {
  nav_usage: ['额度', '上限', 'Limits'],
  nav_settings: ['设置', '設定', 'Settings'],
  nav_card: ['卡片', 'カード', 'Cards'],
  nav_general: ['通用', '一般', 'General'],
  nav_tray: ['托盘', 'トレイ', 'Tray'],
  tray_sub: ['托盘上显示的文字，右边是点开后的面板', 'トレイに表示する文字。右側はクリックで開くパネル', 'What the tray shows; on the right, the panel it opens'],
  g_basic: ['基本', '基本', 'Basics'],
  g_show: ['显示内容', '表示内容', 'Contents'],
  g_tray_text: ['托盘文字', 'トレイの文字', 'Tray Text'],
  g_menu: ['菜单和面板', 'メニューとパネル', 'Menu and Panel'],
  reset_time_menu: ['重置时间', 'リセット時刻', 'Reset Time'],
  preview: ['预览', 'プレビュー', 'Preview'],
  tray_preview_note: ['Linux 在顶栏显示这段文字；Windows 托盘只有图标，鼠标放上去显示这段文字，点开是下面的面板', 'Linux ではトップバーにこの文字を表示します。Windows のトレイはアイコンだけで、マウスを重ねるとこの文字、クリックすると下のパネルが開きます', 'Linux shows this text in the top bar; on Windows the tray shows only the icon, with this text on hover and the panel below on click'],
  card_sub: ['额度卡片和用量卡片分开设置，改动会实时显示在右边的预览里', '上限カードと使用量カードは個別に設定します。変更は右のプレビューにすぐ反映されます', 'The limits card and the usage card are set up separately; changes show in the preview on the right'],
  g_card: ['卡片', 'カード', 'Card'],
  g_look: ['外观', '外観', 'Appearance'],
  show_card: ['显示额度卡片', '上限カードを表示', 'Show Limits Card'],
  on_top: ['保持在最前', '常に手前に表示', 'Keep on Top'],
  on_top_hint: ['关掉时卡片在桌面层，会被其他窗口盖住', 'オフのときはデスクトップ層に置かれ、他のウインドウに隠れます', 'When off, the card sits on the desktop behind other windows'],
  layout: ['布局', 'レイアウト', 'Layout'],
  l_horizontal: ['左右', '左右', 'Side by Side'],
  l_vertical: ['上下', '上下', 'Stacked'],
  l_compact: ['紧凑', 'コンパクト', 'Compact'],
  size: ['大小', 'サイズ', 'Size'],
  background: ['背景', '背景', 'Background'],
  bg_none: ['无', 'なし', 'None'],
  bg_dark: ['深色', 'ダーク', 'Dark'],
  bg_light: ['浅色', 'ライト', 'Light'],
  bg_opacity: ['背景浓度', '背景の濃さ', 'Background Strength'],
  text_color: ['文字颜色', '文字色', 'Text Color'],
  white: ['白色', '白', 'White'],
  black: ['黑色', '黒', 'Black'],
  opacity: ['整体不透明度', '全体の不透明度', 'Overall Opacity'],
  reset_time: ['重置时间', 'リセット時刻', 'Reset Time'],
  r_hidden: ['不显示', '表示しない', 'Hidden'],
  r_relative: ['剩余时间', '残り時間', 'Countdown'],
  r_absolute: ['具体时间', '日時', 'Date & Time'],
  card_hint: ['在卡片上按住拖动可以换位置，右键有更多选项', 'カードをドラッグして移動、右クリックでその他の操作', 'Drag the card to move it; right-click for more options'],
  resets_at: ['%s 重置', '%s にリセット', 'resets %s'],
  runs_out: ['预计 %s 用完', '%s に使い切る見込み', 'runs out %s'],
  fast_hint: ['用得比时间快：已用的比例超过了这个周期已经过去的比例', '時間の進みより速いペース：使用した割合がこの期間の経過割合を上回っています', "Ahead of pace: you've used more of this limit than the share of the period that has passed"],
  reset_one: ['可用重置 1 次', 'リセット 1 回分', '1 reset available'],
  limits_card: ['额度卡片', '上限カード', 'Limits Card'],
  usage_card: ['用量卡片', '使用量カード', 'Usage Card'],
  show_usage_card: ['显示用量卡片', '使用量カードを表示', 'Show Usage Card'],
  limits_card_desc: ['额度卡片显示各家额度的剩余（或已用）和重置时间', '上限カードには各上限の残り（または使用済み）とリセット時刻を表示します', 'The limits card shows how much of each limit is left (or used) and when it resets'],
  usage_card_desc: ['用量卡片显示各家的估算成本、请求数、Tokens 和缓存命中率（来自本机会话记录）', '使用量カードには各サービスの推定コスト、リクエスト数、Tokens、キャッシュヒット率を表示します（この PC のセッション記録から）', "The usage card shows each service's estimated cost, requests, tokens and cache hit rate (from this computer's session logs)"],
  stats_range: ['统计范围', '集計期間', 'Period'],
  today: ['今天', '今日', 'Today'],
  since_reset: ['重置以来', 'リセット以降', 'Since Reset'],
  last_7d: ['近 7 天', '過去 7 日間', 'Last 7 Days'],
  requests: ['请求数', 'リクエスト数', 'Requests'],
  hit_rate: ['缓存命中率', 'キャッシュヒット率', 'Cache Hit Rate'],
  reading_logs: ['正在读取本机会话记录…', 'ローカルのセッション記録を読み込み中…', 'Reading local session logs…'],
  stats_refresh: ['统计刷新间隔', '統計の更新間隔', 'Statistics Refresh'],
  reset_count: ['可用重置 %s 次', 'リセット %s 回分', '%s resets available'],
  expires: ['%s 到期', '%s まで', 'expires %s'],
  earliest: ['最早 %s 到期', '最も早いもの %s まで', 'earliest expires %s'],
  usage_sub: ['Claude 与 Codex 的剩余用量', 'Claude と Codex の残り使用量', 'Remaining Claude and Codex usage'],
  settings_sub: ['开机启动、外观、刷新频率和数据来源', 'ログイン時の起動、外観、更新頻度、データソース', 'Launch at login, appearance, refresh and data sources'],
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
  claude_local_none: ['本机没有 Claude 的额度记录（Claude 桌面 app 查看过用量后才会有）', 'この PC に Claude の上限の記録がありません（Claude デスクトップアプリで使用量を表示すると作られます）', 'No Claude limit records on this computer (the Claude desktop app writes one when it shows usage)'],
  claude_local_stale: ['Claude 桌面 app 最近没有查过用量（最近一次 %s）', 'Claude デスクトップアプリが最近使用量を取得していません（最後は %s）', "The Claude desktop app hasn't checked usage recently (last at %s)"],
  claude_local: ['来自 Claude 桌面 app 的记录 · 数据时间 %s', 'Claude デスクトップアプリの記録 · %s 時点', 'From the Claude desktop app · as of %s'],
  codex_logs: ['来自会话日志 · 数据时间 %s', 'セッションログより · データ時刻 %s', 'From session logs · data from %s'],
  codex_logs_none: ['会话日志里还没有额度记录（用一次 Codex 就有）', 'セッションログにまだ上限の記録がありません（Codex を一度使うと記録されます）', 'No limits in the session logs yet (they appear after using Codex once)'],
  g_notify: ['通知', '通知', 'Notifications'],
  n_threshold: ['用量达到', '使用量が達したら', 'Usage Reaches'],
  n_off: ['不提醒', '通知しない', 'Off'],
  n_run_out: ['预计在重置前用完', 'リセット前に使い切りそうなとき', 'On Pace to Run Out'],
  n_run_out_hint: ['用了三成以上、用得比时间快时', '30% 以上使い、時間より速いペースのとき', 'Over 30% used and ahead of pace'],
  n_reset: ['额度重置后', '上限がリセットされたら', 'After a Reset'],
  n_reset_hint: ['提前重置（官方统一重置或用了重置次数）时，或之前用了一半以上时', '予定より早くリセットされたとき（公式の一斉リセットやリセットの使用）、またはそれまでに半分以上使っていたとき', 'When reset early (an across-the-board reset or a reset you used), or after over half had been used'],
  n_credits: ['Codex 额度重置次数', 'Codex の上限リセット', 'Codex Resets'],
  n_credits_hint: ['新获得时，以及到期前 24 小时', '新たにもらったとき、期限の 24 時間前', 'When you get one, and 24 hours before one expires'],
  remote: ['远程机器', 'リモートマシン', 'Remote Machines'],
  remote_hint: ['Codex 跑在远程时日志只在那边，用 SSH 读回来', 'Codex をリモートで動かすとログはそちらにだけ残るので、SSH で読み込みます', 'Codex keeps its logs on the machine it runs on; read them over SSH'],
  add_machine: ['添加机器', 'マシンを追加', 'Add Machine'],
  host: ['主机名', 'ホスト名', 'Host'],
  add: ['添加', '追加', 'Add'],
  remove: ['移除', '削除', 'Remove'],
  ssh_config_hosts: ['~/.ssh/config 里的主机', '~/.ssh/config のホスト', 'Hosts in ~/.ssh/config'],
  ssh_files: ['SSH · %s 个日志文件', 'SSH · ログ %s 件', 'SSH · %s log files'],
  ssh_reading: ['SSH · 读取中…', 'SSH · 読み込み中…', 'SSH · Reading…'],
  n_req: ['%s 条请求', '%s リクエスト', '%s requests'],
  timeout: ['超时', 'タイムアウト', 'Timed out'],
  unreachable: ['连不上', '接続できません', "Can't connect"],
  no_host: ['找不到这台主机：检查主机名，或在 ~/.ssh/config 里配置', 'ホストが見つかりません：ホスト名を確認するか ~/.ssh/config に設定してください', "Host not found: check the name or set it up in ~/.ssh/config"],
  ssh_auth: ['登录被拒绝：需要免密登录（密钥或 ssh-agent）', 'ログインが拒否されました：パスワードなしのログイン（鍵または ssh-agent）が必要です', 'Login refused: passwordless login (a key or ssh-agent) is required'],
  host_key: ['主机密钥未确认：先在终端里 ssh 连一次这台机器', 'ホスト鍵が未確認です：まずターミナルで一度 ssh 接続してください', "Host key not confirmed: ssh to it once in a terminal first"],
  no_ssh: ['找不到 ssh 命令：请安装 OpenSSH 客户端', 'ssh コマンドが見つかりません：OpenSSH クライアントをインストールしてください', 'ssh not found: install the OpenSSH client'],
  remote_note: ['需要能免密登录（密钥或 ssh-agent）。只读远程的 Codex 会话日志，在远程先过滤再传回来', 'パスワードなしでログインできる必要があります（鍵または ssh-agent）。リモートの Codex セッションログを読むだけで、リモート側で絞り込んでから転送します', 'Needs passwordless login (a key or ssh-agent). Only reads the Codex session logs on that machine, filtered there before being sent back'],
  nav_about: ['关于', '情報', 'About'],
  about_sub: ['版本、更新和数据说明', 'バージョン、アップデート、データについて', 'Version, updates and where the data comes from'],
  version: ['版本 %s', 'バージョン %s', 'Version %s'],
  tagline: ['在托盘和桌面显示 Claude 与 Codex 的剩余用量', 'Claude と Codex の残り使用量をトレイとデスクトップに表示', 'Shows remaining Claude and Codex usage in the tray and on the desktop'],
  check_update: ['检查更新', 'アップデートを確認', 'Check for Updates'],
  checking: ['正在检查…', '確認中…', 'Checking…'],
  downloading: ['正在下载 %s%…', 'ダウンロード中 %s%…', 'Downloading %s%…'],
  installing: ['正在安装…', 'インストール中…', 'Installing…'],
  up_to_date: ['已是最新版本', '最新バージョンです', "You're up to date"],
  new_version: ['发现新版本 %s', '新しいバージョン %s があります', 'Version %s is available'],
  update_restart: ['更新并重启', 'アップデートして再起動', 'Update and Restart'],
  download_page: ['前往下载页', 'ダウンロードページを開く', 'Open Download Page'],
  deb_hint: ['deb 安装的版本请下载新的 deb 后用 apt 安装', 'deb 版は新しい deb をダウンロードして apt でインストールしてください', 'For the deb package, download the new .deb and install it with apt'],
  view_details: ['查看详情', '詳細', 'Details'],
  retry: ['重试', '再試行', 'Retry'],
  update_failed: ['更新失败：%s', 'アップデートに失敗しました：%s', 'Update failed: %s'],
  checksum: ['校验失败', 'チェックサムが一致しません', 'Checksum mismatch'],
  no_checksum: ['缺少校验值', 'チェックサムがありません', 'Missing checksum'],
  write: ['没有写入权限', '書き込み権限がありません', 'No permission to replace the app'],
  data_info: ['数据说明', 'データについて', 'About the Data'],
  info_limits: ['默认用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询；在「设置 → 数据来源」里可以改成「仅本地」，只读本机文件、不发请求', '既定ではこの PC の Claude Code と Codex のログイン情報で Anthropic・OpenAI の使用量 API に問い合わせます。「設定 → データソース」で「ローカルのみ」にすると、この PC のファイルだけを読みリクエストを送りません', "By default, queried from Anthropic's and OpenAI's usage endpoints using the Claude Code and Codex logins on this computer; switch to Local Only under Settings → Data Sources to read files on this computer only and send no requests"],
  info_stats: ['读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），以及「设置」里添加的远程机器上的 Codex 日志（用 ssh 读取，在远程先过滤）。解析结果存在本机的数据库里，日志被清理后统计也还在；成本按 models.dev 的 API 价格估算，价格每天更新一次', 'この PC のセッション記録（~/.claude/projects と ~/.codex/sessions）と、「設定」で追加したリモートマシンの Codex ログ（ssh で読み込み、リモート側で絞り込み）を読みます。解析結果はこの PC のデータベースに保存されるので、ログが削除されても統計は残ります。コストは models.dev の API 価格で推定し、価格は毎日更新されます', 'Reads the session logs on this computer (~/.claude/projects and ~/.codex/sessions) and the Codex logs on remote machines added in Settings (read over ssh, filtered there). Parsed results are kept in a local database, so statistics stay after logs are cleaned up; costs are estimated from models.dev API prices, updated daily'],
  privacy: ['隐私', 'プライバシー', 'Privacy'],
  info_privacy: ['所有数据只在这台电脑、你添加的远程机器和上述官方服务之间传输，不经过其他服务器', 'データはこの PC、追加したリモートマシン、上記の公式サービスの間でのみやり取りされ、他のサーバーを経由しません', 'Data only travels between this computer, the remote machines you add and those official services, never through other servers'],
  all_releases: ['所有版本', 'すべてのリリース', 'All Releases'],
  report_issue: ['反馈问题', '問題を報告', 'Report an Issue'],
  appearance_l: ['外观', '外観', 'Appearance'],
  ap_auto: ['自动', '自動', 'Auto'],
  ap_light: ['浅色', 'ライト', 'Light'],
  ap_dark: ['深色', 'ダーク', 'Dark'],
  accent_l: ['主题色', 'テーマカラー', 'Theme Color'],
  c_pink: ['粉色', 'ピンク', 'Pink'],
  c_purple: ['紫色', 'パープル', 'Purple'],
  c_blue: ['蓝色', 'ブルー', 'Blue'],
  c_teal: ['青色', 'ティール', 'Teal'],
  c_green: ['绿色', 'グリーン', 'Green'],
  c_orange: ['橙色', 'オレンジ', 'Orange'],
  c_gray: ['灰色', 'グレー', 'Gray'],
  g_refresh: ['刷新', '更新', 'Refresh'],
  limits_detail: ['向 Anthropic 和 OpenAI 查询剩余额度', 'Anthropic と OpenAI に残りの上限を問い合わせます', 'Asks Anthropic and OpenAI for remaining limits'],
  stats_detail: ['读取本机和远程机器的会话记录', 'この PC とリモートマシンのセッション記録を読み込みます', 'Reads session logs on this computer and remote machines'],
  refresh_note: ['用量统计只读取新写入的日志，刷新很快', '使用統計は新しく書き込まれた記録だけを読むので、更新はすぐ終わります', 'Usage statistics only read newly written logs, so refreshing is quick'],
  g_tray: ['托盘', 'トレイ', 'Tray'],
  tray_note: ['只影响托盘，两张卡片在「卡片」里各自设置', 'トレイだけに反映されます。2 枚のカードは「カード」で個別に設定します', 'Only affects the tray; each card has its own settings under Cards'],
  tray_limit: ['显示的额度', '表示する上限', 'Limit Shown'],
  both: ['都显示', '両方', 'Both'],
  tray_reset: ['菜单里的重置时间', 'メニューのリセット時刻', 'Reset Time in Menu'],
  r_full: ['完整', 'すべて', 'Full'],
  resets_full: ['%s后重置（%s）', '%s後にリセット（%s）', 'resets in %s (%s)'],
  g_stats: ['用量统计', '使用量の統計', 'Usage Statistics'],
  price_table: ['价格表', '価格表', 'Prices'],
  price_updated: ['models.dev · 更新于 %s', 'models.dev · 更新 %s', 'models.dev · updated %s'],
  not_loaded: ['未获取', '未取得', 'Not loaded'],
  update_now: ['立即更新', '今すぐ更新', 'Update Now'],
  session_logs: ['会话记录', 'セッション記録', 'Session Logs'],
  records_since: ['%s 条请求，最早 %s', '%s 件、最古 %s', '%s requests since %s'],
  g_sources: ['数据来源', 'データソース', 'Data Sources'],
  src_api: ['官方接口', '公式 API', 'Official API'],
  src_local: ['仅本地', 'ローカルのみ', 'Local Only'],
  sources_note: ['额度：「官方接口」用本机的登录信息向 Anthropic、OpenAI 查询，最准；「仅本地」只读本机文件、不发请求，Codex 读会话日志，Claude 读桌面 app 的记录，可能不是最新。用量统计都只读本地日志', '上限：「公式 API」はこの PC のログイン情報で Anthropic・OpenAI に問い合わせ、最も正確です。「ローカルのみ」はこの PC のファイルだけを読みリクエストを送りません（Codex はセッションログ、Claude はデスクトップアプリの記録。最新でないことがあります）。使用量の統計はいずれもローカルのログだけを読みます', 'Limits: Official API asks Anthropic and OpenAI using the logins on this computer and is the most accurate; Local Only reads files on this computer and sends no requests (Codex from its session logs, Claude from the desktop app\'s records, which may be out of date). Usage statistics always read local logs only'],
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
let page = 'stats';
// 卡片设置页正在看哪张：limits / stats
let cardTab = 'limits';
// 两张卡片形状一样时对齐到的内容区大小（Rust 发来的）
let synced = null;
// 托盘点开的小面板（Windows）和桌面卡片：同一个页面，地址带 #flyout / #card
const FLYOUT = location.hash === '#flyout';
const CARD = location.hash === '#card';
const STATS_CARD = location.hash === '#stats_card';  // 用量卡片
const ANY_CARD = CARD || STATS_CARD;
// 拖卡片时画对齐线的透明窗口
const GUIDES = location.hash === '#guides';
let autostart = false;
// ~/.ssh/config 里的主机（添加远程机器时给个选择），和输入框里还没添加的字（状态更新重绘时保留）
let sshHosts = [];
let newHostDraft = '';

// 主题色：浅色、深色两套（和 macOS 的系统色一样）
const ACCENTS = {
  pink: ['#ff2d55', '#ff375f'], purple: ['#af52de', '#bf5af2'], blue: ['#007aff', '#0a84ff'], teal: ['#30b0c7', '#40c8e0'],
  green: ['#34c759', '#30d158'], orange: ['#ff9500', '#ff9f0a'], gray: ['#8e8e93', '#98989d'],
};
const systemDark = window.matchMedia('(prefers-color-scheme: dark)');

// 外观：auto 跟随系统，light / dark 固定；主题色按当前深浅选一套
function applyTheme() {
  const s = state?.settings;
  if (!s) return;
  const root = document.documentElement;
  if (s.appearance === 'light' || s.appearance === 'dark') root.dataset.theme = s.appearance;
  else delete root.dataset.theme;
  const dark = s.appearance === 'dark' || (s.appearance !== 'light' && systemDark.matches);
  const pair = ACCENTS[s.accent] || ACCENTS.pink;
  root.style.setProperty('--accent', pair[dark ? 1 : 0]);
}
systemDark.addEventListener?.('change', () => { applyTheme(); if (typeof render === 'function') render(); });

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

// 今天内只写几点，否则带上星期几
function shortTime(sec) {
  const d = new Date(sec * 1000);
  const locale = { zh: 'zh-CN', ja: 'ja-JP' }[state.lang] ?? 'en-US';
  const time = d.toLocaleTimeString(locale, { hour: '2-digit', minute: '2-digit', hour12: false });
  if (d.toDateString() === new Date().toDateString()) return time;
  return `${d.toLocaleDateString(locale, { weekday: state.lang === 'ja' ? 'long' : 'short' })} ${time}`;
}

// 用得比时间快的额度：百分比后面加个 ↑
const fastMark = (w) => (w.fast ? `<span class="up" title="${esc(t('fast_hint'))}">↑</span>` : '');

// style：relative「3小时20分后重置」/ absolute「周三 14:20 重置」/ full「3小时20分后重置（14:20）」
function resetText(at, style = 'relative') {
  // 差几秒到整分钟就进位（接口常给 05:59:59.x）
  at = Math.floor((at + 5) / 60) * 60;
  if (style === 'absolute') return t('resets_at', shortTime(at));
  const s = Math.max(0, at - Date.now() / 1000);
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  const rel = d > 0 ? t('d_h').replace('%d', d).replace('%h', h)
    : h > 0 ? t('h_m').replace('%h', h).replace('%m', m)
    : t('m').replace('%m', m);
  if (style !== 'full') return t('resets_in', rel);
  const date = new Date(at * 1000), hm = date.toTimeString().slice(0, 5);
  return t('resets_full', rel, d > 0 ? `${date.getMonth() + 1}/${date.getDate()} ${hm}` : hm);
}

// Codex 的额度重置：「可用重置 1 次 · 11/7 06:50 到期」；多次时写最早那次，lines 是逐条的到期时间
const resetCountText = (r) => (r.count === 1 ? t('reset_one') : t('reset_count', r.count));
function resetCreditsText(r) {
  if (!r.expiries.length) return resetCountText(r);
  const first = dateTime(r.expiries[0]);
  return resetCountText(r) + ' · ' + (r.count > 1 ? t('earliest', first) : t('expires', first));
}
const resetCreditLines = (r) => (r.count > 1 ? r.expiries.map((e) => t('expires', dateTime(e))) : []);

// 出错原因：附带的数字是时间的按日期写，其他（HTTP 状态码）原样
const errorText = (p) => t(p.error, p.detail == null ? '' : p.error === 'claude_local_stale' ? dateTime(p.detail) : p.detail);

function providerHTML(p) {
  const used = state.settings.display === 'used';
  let html = `<div class="panel provider"><div class="name">${esc(p.name)}${p.plan ? `<span class="plan">${esc(p.plan)}</span>` : ''}</div>`;
  if (p.error) html += `<div class="error">${esc(errorText(p))}</div>`;
  for (const w of p.windows) {
    const v = used ? Math.min(100, w.used) : Math.max(0, 100 - w.used);
    html += `<div class="row">
      <div class="top"><span>${esc(windowLabel(w))}</span><span class="value">${t(used ? 'used' : 'left', Math.round(v))}${fastMark(w)}</span></div>
      <div class="bar"><div style="width:${v}%"></div></div>
      ${w.resets_at && state.settings.tray_reset !== 'hidden' ? `<div class="reset">${esc(resetText(w.resets_at, state.settings.tray_reset) + (w.runs_out_at ? ' · ' + t('runs_out', shortTime(w.runs_out_at)) : ''))}</div>` : ''}
    </div>`;
  }
  if (p.resets) {
    html += `<div class="note">↻ ${esc(resetCreditsText(p.resets))}</div>`;
    for (const l of resetCreditLines(p.resets)) html += `<div class="note indent">${esc(l)}</div>`;
  }
  if (p.note) html += `<div class="note">${esc(t(p.note, p.detail ? dateTime(p.detail) : ''))}</div>`;
  return html + '</div>';
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

// MARK: 桌面卡片（布局和尺寸照 macOS 版的 CardView）

// 额度卡片：自己的「显示哪几家」和「剩余 / 已用」（托盘的在设置页）
const shownProviders = () => state.providers.filter((p) => (p.name === 'Claude' ? state.settings.card_show_claude : state.settings.card_show_codex));

function cardRow(w) {
  const s = state.settings, used = s.card_display === 'used';
  const v = used ? Math.min(100, w.used) : Math.max(0, 100 - w.used);
  return `<div class="c-row">
    <div class="c-top"><span>${esc(windowLabel(w))}</span><span class="c-val">${t(used ? 'used' : 'left', Math.round(v))}${fastMark(w)}</span></div>
    <div class="c-bar"><div style="width:${v}%"></div></div>
    ${s.card_reset !== 'hidden' && w.resets_at
      ? `<div class="c-reset">${esc(resetText(w.resets_at, s.card_reset))}</div>`
      : '<div class="c-reset" style="visibility:hidden">·</div>'}
  </div>`;  // 不显示重置时间时留着这一行的位置：布局不动，只是字不见了
}

function cardColumn(p) {
  return `<div class="c-col">
    <div class="c-name">${esc(p.name)}${p.plan ? `<span class="c-plan">${esc(p.plan)}</span>` : ''}</div>
    ${p.error ? `<div class="c-err">${esc(errorText(p))}</div>` : ''}
    ${p.windows.map(cardRow).join('')}
    ${p.resets ? `<div class="c-reset">↻ ${esc(resetCreditsText(p.resets))}</div>` : ''}
    ${p.note ? `<div class="c-note">${esc(t(p.note, p.detail ? dateTime(p.detail) : ''))}</div>` : ''}
  </div>`;
}

// 紧凑：一家一行，放在网格里，各行的同一列上下对齐（cols：最多的那行有几格）
function cardCompactRow(p, cols) {
  const used = state.settings.card_display === 'used';
  // 出错时这一格占满后面所有列，不用再补空格
  if (p.error && p.windows.length === 0) {
    return `<span class="c-name">${esc(p.name)}</span><span class="c-err" style="grid-column: span ${cols - 1}">${esc(errorText(p))}</span>`;
  }
  const cells = p.windows.map((w) => {
    const v = used ? Math.min(100, w.used) : Math.max(0, 100 - w.used);
    return `<span class="c-pair"><span class="c-lab">${esc(windowLabel(w))}</span><span class="c-num">${t(used ? 'used' : 'left', Math.round(v))}${fastMark(w)}</span></span>`;
  });
  if (p.resets) cells.push(`<span class="c-lab">${esc(resetCountText(p.resets))}</span>`);
  while (cells.length < cols - 1) cells.push('<span></span>');
  return `<span class="c-name">${esc(p.name)}</span>${cells.join('')}`;
}
const compactCells = (p) => 1 + (p.error && p.windows.length === 0 ? 1 : p.windows.length) + (p.resets ? 1 : 0);

const money = (v) => '$' + (v || 0).toFixed(2);
function abbrev(n) {
  for (const [v, u] of [[1e9, 'B'], [1e6, 'M'], [1e3, 'K']]) if (n >= v) return (n / v).toFixed(n >= v * 100 ? 0 : 1).replace(/\.0$/, '') + u;
  return String(n);
}
const pct = (v) => (v == null ? '—' : (v * 100).toFixed(1) + '%');

// 卡片外框：中间内容区按对齐后的大小撑开（多出来的空在右边和下面），下面是更新时间
function cardFrame(prefix, body, footer) {
  const s = state.settings;
  const style = `--s:${s[prefix + 'scale']};--bgop:${s[prefix + 'bg_opacity']};opacity:${s[prefix + 'opacity']}`;
  const min = synced ? `min-width:${synced[0]}px;min-height:${synced[1]}px` : '';
  return `<div class="card-box bg-${esc(s[prefix + 'background'])} text-${esc(s[prefix + 'text'])}" style="${style}">
    <div class="c-area" style="${min}"><div class="c-content">${body}</div></div>
    ${footer}
  </div>`;
}

// 报给 Rust 内容区的自然大小和形状（布局|大小|几家），两张一样时它会让两边对齐
function reportCardContent(shape) {
  const el = document.querySelector('.c-content');
  if (!el) return;
  const r = el.getBoundingClientRect();
  invoke('card_content', { content: { width: Math.ceil(r.width), height: Math.ceil(r.height), shape } });
}

// MARK: 用量卡片

const usageShown = () => ['Claude', 'Codex'].filter((n) => state.settings[n === 'Claude' ? 'stats_card_show_claude' : 'stats_card_show_codex']);
const planOf = (name) => state.providers.find((p) => p.name === name)?.plan;
const usageOf = (name) => state.usage[name.toLowerCase()];
const rangeTitle = () => t({ today: 'today', cycle: 'since_reset', '7d': 'last_7d' }[state.settings.stats_card_range] || 'today');

function statsColumn(name) {
  const u = usageOf(name), plan = planOf(name);
  const kv = (k, v) => `<div class="c-kv"><span>${k}</span><span class="c-val">${v}</span></div>`;
  return `<div class="c-col">
    <div class="c-name">${esc(name)}${plan ? `<span class="c-plan">${esc(plan)}</span>` : ''}</div>
    <div class="c-cost">${money(u.cost)}</div>
    ${kv(t('requests'), u.requests.toLocaleString())}${kv('Tokens', abbrev(u.tokens))}${kv(t('hit_rate'), pct(u.hit_rate))}
  </div>`;
}

function statsCompactRow(name) {
  const u = usageOf(name);
  const pair = (k, v) => `<span class="c-pair"><span class="c-lab">${k}</span><span class="c-num">${v}</span></span>`;
  return `<span class="c-name">${esc(name)}</span><span class="c-num">${money(u.cost)}</span>${pair(t('requests'), u.requests.toLocaleString())}${pair('Tokens', abbrev(u.tokens))}`;
}

function statsCardPage() {
  const s = state.settings, shown = usageShown();
  const body = state.usage.updated == null && !state.usage.claude.requests && !state.usage.codex.requests
    ? `<div class="c-reset">${t('reading_logs')}</div>`
    : s.stats_card_layout === 'compact'
      ? `<div class="c-lines" style="grid-template-columns: repeat(4, max-content)">${shown.map(statsCompactRow).join('')}</div>`
      : `<div class="c-cols ${s.stats_card_layout === 'vertical' ? 'vertical' : ''}">${shown.map(statsColumn).join('')}</div>`;
  const footer = state.usage.updated ? `<div class="c-updated">${rangeTitle()} · ${t('updated', clock(state.usage.updated))}</div>` : '';
  return cardFrame('stats_card_', body, footer);
}

function cardPage() {
  const s = state.settings;
  const shown = shownProviders();
  const body = state.providers.length === 0 ? `<div class="c-reset">${t('loading')}</div>`
    : s.card_layout === 'compact' ? (() => {
      const cols = Math.max(2, ...shown.map(compactCells));
      return `<div class="c-lines" style="grid-template-columns: repeat(${cols}, max-content)">${shown.map((p) => cardCompactRow(p, cols)).join('')}</div>`;
    })()
    : `<div class="c-cols ${s.card_layout === 'vertical' ? 'vertical' : ''}">${shown.map(cardColumn).join('')}</div>`;
  return cardFrame('card_', body, state.updated ? `<div class="c-updated">${t('updated', clock(state.updated))}</div>` : '');
}

// 卡片窗口的大小跟着内容走
function fitCard() {
  const r = document.querySelector('.card-box').getBoundingClientRect();
  invoke('fit_card', { width: Math.ceil(r.width), height: Math.ceil(r.height) });
}

function seg(key, options) {
  const cur = state.settings[key];
  return `<div class="seg">${options.map(([v, label]) => `<button data-set="${key}" data-val="${v}" class="${cur === v ? 'on' : ''}">${esc(label)}</button>`).join('')}</div>`;
}
const toggle = (id, on) => `<label class="switch"><input type="checkbox" id="${id}" ${on ? 'checked' : ''}><span></span></label>`;
// 百分比滑块：拖动时只更新数字，松手再保存
const slider = (key, min, max, step) => `<span class="slider"><input type="range" data-num="${key}" min="${min}" max="${max}" step="${step}" value="${state.settings[key]}"><span class="pct">${Math.round(state.settings[key] * 100)}%</span></span>`;

// 卡片比预览框宽（大尺寸、左右布局）时缩小显示，免得被裁掉
function fitCardPreview() {
  const frame = document.querySelector('.card-preview'), box = frame?.querySelector('.card-box');
  if (!box) return;
  const room = frame.clientWidth - 32, w = box.offsetWidth;
  box.style.zoom = w > room ? room / w : '';
}
window.addEventListener('resize', () => { if (page === 'card' && !ANY_CARD) fitCardPreview(); });

function cardSettingsPage() {
  const s = state.settings, stats = cardTab === 'stats', k = stats ? 'stats_card_' : 'card_';
  const tabs = `<div class="seg card-tabs">${[['limits', t('limits_card')], ['stats', t('usage_card')]].map(([v, l]) =>
    `<button data-cardtab="${v}" class="${cardTab === v ? 'on' : ''}">${esc(l)}</button>`).join('')}</div>`;
  const own = stats
    ? `<div class="field"><span>${t('stats_range')}</span>${seg('stats_card_range', [['today', t('today')], ['cycle', t('since_reset')], ['7d', t('last_7d')]])}</div>
       <div class="field"><span>Claude</span>${toggle('stats_card_show_claude', s.stats_card_show_claude)}</div>
       <div class="field"><span>Codex</span>${toggle('stats_card_show_codex', s.stats_card_show_codex)}</div>`
    : `<div class="field"><span>${t('display')}</span>${seg('card_display', [['remaining', t('remaining')], ['used', t('used_opt')]])}</div>
       <div class="field"><span>${t('reset_time')}</span>${seg('card_reset', [['hidden', t('r_hidden')], ['relative', t('r_relative')], ['absolute', t('r_absolute')]])}</div>
       <div class="field"><span>Claude</span>${toggle('card_show_claude', s.card_show_claude)}</div>
       <div class="field"><span>Codex</span>${toggle('card_show_codex', s.card_show_codex)}</div>`;
  const form = group(t(stats ? 'usage_card' : 'limits_card'), `
      <div class="field"><span>${t(stats ? 'show_usage_card' : 'show_card')}</span>${toggle(k + 'show', s[k + 'show'])}</div>
      <div class="field"><span>${t('on_top')}<div class="hint">${t('on_top_hint')}</div></span>${toggle(k + 'on_top', s[k + 'on_top'])}</div>
      ${own}`, t(stats ? 'usage_card_desc' : 'limits_card_desc'))
    + group(t('layout'), `
      <div class="field"><span>${t('layout')}</span>${seg(k + 'layout', [['horizontal', t('l_horizontal')], ['vertical', t('l_vertical')], ['compact', t('l_compact')]])}</div>
      <div class="field"><span>${t('size')}</span>${slider(k + 'scale', 0.8, 2.5, 0.1)}</div>`)
    + group(t('g_look'), `
      <div class="field"><span>${t('background')}</span>${seg(k + 'background', [['none', t('bg_none')], ['dark', t('bg_dark')], ['light', t('bg_light')]])}</div>
      ${s[k + 'background'] !== 'none' ? `<div class="field"><span>${t('bg_opacity')}</span>${slider(k + 'bg_opacity', 0.1, 1, 0.05)}</div>` : ''}
      <div class="field"><span>${t('text_color')}</span>${seg(k + 'text', [['white', t('white')], ['black', t('black')]])}</div>
      <div class="field"><span>${t('opacity')}</span>${slider(k + 'opacity', 0.3, 1, 0.05)}</div>`);
  // 预览：和桌面上的卡片同一套画法，放在一块像桌面的底色上
  const preview = `<section class="sgroup"><div class="group-title">${t('preview')}</div>
    <div class="card-preview">${stats ? statsCardPage() : cardPage()}</div>
    <div class="footnote">${t('card_hint')}</div></section>`;
  return `${pageHeader('card', t('nav_card'), t('card_sub'))}${tabs}${columns(form, preview)}`;
}

const minutesSelect = (id, list) => `<select id="${id}">${list.map((m) => `<option value="${m}" ${state.settings[id] === m ? 'selected' : ''}>${t('minutes', m)}</option>`).join('')}</select>`;

function settingsPage() {
  const s = state.settings;
  const langs = [['auto', t('lang_auto')], ['zh', '中文'], ['ja', '日本語'], ['en', 'English']];
  const basic = group(t('g_basic'), `
      <div class="field"><span>${t('launch')}</span>${toggle('autostart', autostart)}</div>
      <div class="field"><span>${t('language')}</span>
        <select id="language">${langs.map(([v, l]) => `<option value="${v}" ${s.language === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>
      <div class="field"><span>${t('appearance_l')}</span>${seg('appearance', [['auto', t('ap_auto')], ['light', t('ap_light')], ['dark', t('ap_dark')]])}</div>
      <div class="field"><span>${t('accent_l')}</span><span class="swatches">${Object.keys(ACCENTS).map((k) =>
        `<button data-set="accent" data-val="${k}" class="${s.accent === k ? 'on' : ''}" title="${esc(t('c_' + k))}" style="background-color:var(--sw-${k})"></button>`).join('')}</span></div>`);
  const notify = group(t('g_notify'), `
      <div class="field"><span>${t('n_threshold')}</span>
        <select id="notify_threshold">${[[0, t('n_off')], [80, '80%'], [90, '90%'], [95, '95%']].map(([v, l]) => `<option value="${v}" ${s.notify_threshold === v ? 'selected' : ''}>${l}</option>`).join('')}</select></div>
      <div class="field"><span>${t('n_run_out')}<div class="hint">${t('n_run_out_hint')}</div></span>${toggle('notify_run_out', s.notify_run_out)}</div>
      <div class="field"><span>${t('n_reset')}<div class="hint">${t('n_reset_hint')}</div></span>${toggle('notify_reset', s.notify_reset)}</div>
      <div class="field"><span>${t('n_credits')}<div class="hint">${t('n_credits_hint')}</div></span>${toggle('notify_credits', s.notify_credits)}</div>`);
  const usage = group(t('g_stats'), `
      <div class="field"><span>${t('price_table')}<div class="hint">${state.pricing_updated ? t('price_updated', dateTime(state.pricing_updated)) : t('not_loaded')}</div></span>
        ${state.stats_loading ? `<span class="sub">${t('refreshing')}</span>` : `<button class="btn" id="update-prices">${t('update_now')}</button>`}</div>
      <div class="field"><span>${t('session_logs')}</span><span class="sub">${state.overview?.earliest
        ? t('records_since', state.overview.count.toLocaleString(), new Date(state.overview.earliest).toLocaleDateString()) : t('reading_logs')}</span></div>`);
  const refresh = group(t('g_refresh'), `
      <div class="field"><span>${t('nav_usage')}<div class="hint">${t('limits_detail')}</div></span>${minutesSelect('refresh_minutes', [1, 2, 5, 10, 15, 30])}</div>
      <div class="field"><span>${t('nav_stats')}<div class="hint">${t('stats_detail')}</div></span>${minutesSelect('stats_refresh_minutes', [1, 2, 5, 10, 15, 30, 60])}</div>`, t('refresh_note'));
  // 数据来源：两家的额度来源，下面是远程机器（和 macOS 版一样放在同一组）
  const others = sshHosts.filter((h) => !s.remote_hosts.includes(h));
  const sources = group(t('g_sources'), `
      ${['Claude', 'Codex'].map(sourceRow).join('')}
      ${s.remote_hosts.map(hostRow).join('')}
      <div class="field"><span>${t('remote')}<div class="hint">${t('remote_hint')}</div></span>
        <span class="host-add">
          <input id="new-host" type="text" placeholder="${t('host')}" spellcheck="false" autocomplete="off">
          ${others.length ? `<select id="ssh-pick" title="${esc(t('ssh_config_hosts'))}"><option value="">~/.ssh/config</option>${others.map((h) => `<option>${esc(h)}</option>`).join('')}</select>` : ''}
          <button class="btn" id="add-host">${t('add')}</button>
        </span></div>`, `${t('sources_note')}<br>${t('remote_note')}`);
  return `${pageHeader('settings', t('nav_general'), t('settings_sub'))}${columns(basic + notify + usage, refresh + sources)}`;
}

// 托盘页：左边设置，右边是托盘文字和点开后面板的预览
function trayText() {
  const s = state.settings, used = s.display === 'used';
  const pct = (w) => `${Math.round(used ? Math.min(100, w.used) : Math.max(0, 100 - w.used))}%${w.fast ? '↑' : ''}`;
  const parts = state.providers.filter((p) => (p.name === 'Claude' ? s.show_claude : s.show_codex)).map((p) => {
    const name = s.menu_label === 'full' ? p.name : p.name === 'Claude' ? 'Cc' : 'Cx';
    const session = p.windows.find((w) => !w.kind.startsWith('weekly') && w.kind !== 'days');
    const weekly = p.windows.find((w) => w.kind === 'weekly');
    const v = s.tray_limit === 'session' ? (session || weekly) : s.tray_limit === 'weekly' ? (weekly || session) : null;
    const text = v ? pct(v) : session && weekly ? `${pct(session)}/${pct(weekly)}` : (session || weekly) ? pct(session || weekly) : '–';
    return `${name} ${text}`;
  });
  return parts.length ? parts.join('  ') : 'UsageBar';
}

function trayPage() {
  const s = state.settings;
  const left = group(t('g_show'), `
      <div class="field"><span>${t('display')}</span>${seg('display', [['remaining', t('remaining')], ['used', t('used_opt')]])}</div>
      <div class="field"><span>Claude</span>${toggle('show_claude', s.show_claude)}</div>
      <div class="field"><span>Codex</span>${toggle('show_codex', s.show_codex)}</div>`, t('tray_note'))
    + group(t('g_tray_text'), `
      <div class="field"><span>${t('tray_label')}</span>${seg('menu_label', [['short', t('short')], ['full', t('full')]])}</div>
      <div class="field"><span>${t('tray_limit')}</span>${seg('tray_limit', [['session', t('five_hour')], ['weekly', t('weekly')], ['both', t('both')]])}</div>`)
    + group(t('g_menu'), `
      <div class="field"><span>${t('reset_time_menu')}</span>${seg('tray_reset', [['full', t('r_full')], ['relative', t('r_relative')], ['absolute', t('r_absolute')], ['hidden', t('r_hidden')]])}</div>`);
  const shown = state.providers.filter((p) => (p.name === 'Claude' ? s.show_claude : s.show_codex));
  const status = state.loading ? t('refreshing') : state.updated ? t('updated', clock(state.updated)) : t('loading');
  const right = `<section class="sgroup"><div class="group-title">${t('preview')}</div>
    <div class="tray-bar"><span class="tray-text">${esc(trayText())}</span><span class="sub">${clock(Date.now() / 1000)}</span></div>
    <div class="tray-panel">
      ${state.providers.length ? `<div class="providers">${shown.map(providerHTML).join('')}</div>` : `<div class="sub">${t('loading')}</div>`}
      <div class="fly-foot"><span class="sub">${status}</span><span class="spacer"></span>
        <button class="btn" id="refresh" ${state.loading ? 'disabled' : ''}>${t('refresh')}</button></div>
    </div>
    <div class="footnote">${t('tray_preview_note')}</div></section>`;
  return `${pageHeader('tray', t('nav_tray'), t('tray_sub'))}${columns(left, right)}`;
}

// 一台远程机器：左边是 SSH 和日志文件数（连不上时是红色的原因），右边是请求数和移除
function hostRow(host) {
  const st = state.remote_status?.[host];
  const detail = !st ? t('ssh_reading') : st.error ? (T[st.error] ? t(st.error) : st.error) : t('ssh_files', st.files ?? 0);
  return `<div class="field"><span>${esc(host)}<div class="hint ${st?.error ? 'error-text' : ''}">${esc(detail)}</div></span>
    <span class="host-right"><span class="sub">${st ? t('n_req', st.requests.toLocaleString()) : '—'}</span>
    <button class="btn plain" data-remove-host="${esc(host)}" title="${esc(t('remove'))}">✕</button></span></div>`;
}

function addHost(h) {
  h = (h ?? document.getElementById('new-host')?.value ?? '').trim();
  if (!h || h.includes(',') || /\s/.test(h) || state.settings.remote_hosts.includes(h)) return;
  newHostDraft = '';
  save({ remote_hosts: [...state.settings.remote_hosts, h] });
}

// 左边是这次从哪查到了什么（套餐、本地数据的时间），出错时是原因；右边选额度来源
function sourceRow(name) {
  const p = state.providers.find((x) => x.name === name);
  const key = name === 'Claude' ? 'claude_limit_source' : 'codex_limit_source';
  const status = !p ? '' : p.error ? `<div class="hint error-text">${esc(errorText(p))}</div>`
    : p.note ? `<div class="hint">${esc(t(p.note, p.detail ? dateTime(p.detail) : ''))}</div>`
    : p.plan ? `<div class="hint">${esc(p.plan)}</div>` : '';
  return `<div class="field"><span>${name}${status}</span>${seg(key, [['api', t('src_api')], ['local', t('src_local')]])}</div>`;
}

// MARK: 页面框架：侧边栏和页头的图标（线条图标，和 macOS 版的 SF Symbols 对应）、分组、两列

const ICONS = {
  stats: '<path d="M4 4v16h16"/><path d="M8 16v-5M12 16V7M16 16v-8"/>',
  settings: '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
  tray: '<rect x="3" y="5" width="18" height="14" rx="2.5"/><path d="M3 9h18"/>',
  card: '<rect x="8" y="9" width="13" height="10" rx="2"/><path d="M16 9V7a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h3"/>',
  about: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
};
const icon = (name) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${ICONS[name]}</svg>`;

// 页头：图标、标题、一句说明（extra 放在右边）
const pageHeader = (name, title, sub, extra = '') => `<div class="header"><div class="page-icon">${icon(name)}</div>
  <div><h1>${title}</h1><div class="sub">${sub}</div></div>${extra ? `<div class="spacer"></div>${extra}` : ''}</div>`;
// 一组设置：标题、圆角面板、底下的说明
const group = (title, rows, footer) => `<section class="sgroup">${title ? `<div class="group-title">${title}</div>` : ''}
  <div class="panel group">${rows}</div>${footer ? `<div class="footnote">${footer}</div>` : ''}</section>`;
// 两列各自往下排（窄了就上下排）
const columns = (left, right) => `<div class="cols"><div class="col">${left}</div><div class="col">${right}</div></div>`;

// MARK: 关于：图标、版本、检查更新；有新版或出错时下面展开说明；再下面是数据说明和链接

const GITHUB = 'https://github.com/plsy1/UsageBar';
const githubPath = (url) => (url || '').startsWith(GITHUB) ? url.slice(GITHUB.length) : '/releases';

function updateControl(u) {
  switch (u.status) {
    case 'checking': return `<span class="sub">${t('checking')}</span>`;
    case 'downloading': return `<span class="sub">${(u.progress ?? 0) >= 0.99 ? t('installing') : t('downloading', Math.round((u.progress ?? 0) * 100))}</span>`;
    case 'available': return `<div class="update-right"><b>${esc(t('new_version', u.version))}</b>
      ${u.can_install ? `<button class="btn primary" id="install-update">${t('update_restart')}</button>`
        : `<button class="btn" data-github="${esc(githubPath(u.page))}">${t('download_page')}</button>`}</div>`;
    case 'failed': return `<button class="btn" id="check-update">${t('retry')}</button>`;
    case 'up_to_date': return `<div class="update-right"><span class="sub">✓ ${t('up_to_date')}</span><button class="btn" id="check-update">${t('check_update')}</button></div>`;
    default: return `<button class="btn" id="check-update">${t('check_update')}</button>`;
  }
}

function aboutPage() {
  const u = state.update || { status: 'idle' };
  const err = u.error ? (T[u.error] ? t(u.error) : u.error) : '';
  const below = u.status === 'available' && u.notes
    ? `<div class="update-notes">${esc(u.notes.replace(/\*\*|`/g, '').replace(/^#+\s*/gm, ''))}</div>
       ${u.can_install ? '' : `<div class="sub">${t('deb_hint')}</div>`}
       <a class="link" data-github="${esc(githubPath(u.page))}">${t('view_details')}</a>`
    : u.status === 'failed'
      ? `<div class="update-fail"><span class="sub">${esc(t('update_failed', err))}</span><span class="spacer"></span><a class="link" data-github="/releases">${t('download_page')}</a></div>`
      : '';
  const info = (ico, title, text) => `<div class="info-row"><span class="info-ico">${ico}</span><div><div>${title}</div><div class="sub">${text}</div></div></div>`;
  return `${pageHeader('about', t('nav_about'), t('about_sub'))}
    <div class="panel about-card">
      <div class="about-top">
        <img src="icon.png" alt="" width="64" height="64">
        <div><div class="about-name">UsageBar</div><div class="sub">${t('version', esc(u.current || ''))}</div><div class="sub">${t('tagline')}</div></div>
        <span class="spacer"></span>
        ${updateControl(u)}
      </div>
      ${below ? `<div class="about-below">${below}</div>` : ''}
    </div>
    <div class="group-title">${t('data_info')}</div>
    <div class="panel group info">
      ${info(icon('tray'), t('nav_usage'), t('info_limits'))}
      ${info(icon('stats'), t('nav_stats'), t('info_stats'))}
      ${info('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z"/></svg>', t('privacy'), t('info_privacy'))}
    </div>
    <div class="about-links">
      <a class="link" data-github="">GitHub</a>
      <a class="link" data-github="/releases">${t('all_releases')}</a>
      <a class="link" data-github="/issues">${t('report_issue')}</a>
    </div>`;
}

function render() {
  if (!state) return;
  document.documentElement.lang = state.lang;
  applyTheme();
  document.querySelectorAll('[data-t]').forEach((el) => (el.textContent = t(el.dataset.t)));
  document.querySelectorAll('.nav').forEach((b) => {
    b.classList.toggle('active', b.dataset.page === page);
    const ico = b.querySelector('.ico');
    if (ico && !ico.firstChild) ico.innerHTML = icon(b.dataset.page);
  });
  if (FLYOUT) {
    document.getElementById('content').innerHTML = flyoutPage();
    fitFlyout();
    return;
  }
  if (ANY_CARD) {
    document.getElementById('content').innerHTML = STATS_CARD ? statsCardPage() : cardPage();
    fitCard();
    const s = state.settings, k = STATS_CARD ? 'stats_card_' : 'card_';
    const count = STATS_CARD ? usageShown().length : shownProviders().length;
    const ready = STATS_CARD ? state.usage.updated != null : state.providers.length > 0;
    reportCardContent(s[k + 'show'] && ready && count ? `${s[k + 'layout']}|${s[k + 'scale']}|${count}` : '');
    return;
  }
  const pages = { stats: statsPage, settings: settingsPage, tray: trayPage, card: cardSettingsPage, about: aboutPage };
  const main = document.getElementById('content');
  const focused = document.activeElement?.id === 'new-host';
  main.classList.toggle('wide', page === 'stats');
  main.innerHTML = pages[page]();
  if (page === 'card') fitCardPreview();
  // 远程机器读完一台就会重绘：输入框里打到一半的字和焦点留着
  const input = document.getElementById('new-host');
  if (input) {
    input.value = newHostDraft;
    if (focused) input.focus();
  }
  if (page === 'stats') afterStatsRender();
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
  if (e.target.id === 'add-host') { addHost(); return; }
  if (e.target.id === 'check-update') { invoke('check_update_now'); return; }
  if (e.target.id === 'update-prices') { invoke('refresh_prices'); return; }
  if (e.target.id === 'install-update') { invoke('install_update'); return; }
  const gh = e.target.closest('[data-github]');
  if (gh) { invoke('open_github', { path: gh.dataset.github }); return; }
  const rm = e.target.closest('[data-remove-host]');
  if (rm) { save({ remote_hosts: state.settings.remote_hosts.filter((h) => h !== rm.dataset.removeHost) }); return; }
  const tab = e.target.closest('[data-cardtab]');
  if (tab) { cardTab = tab.dataset.cardtab; render(); return; }
  const b = e.target.closest('[data-set]');
  if (b) save({ [b.dataset.set]: b.dataset.val });
});
document.addEventListener('keydown', (e) => { if (e.target.id === 'new-host' && e.key === 'Enter') addHost(); });
document.addEventListener('change', async (e) => {
  const el = e.target;
  if (el.id === 'language') save({ language: el.value });
  else if (el.id === 'refresh_minutes' || el.id === 'stats_refresh_minutes') save({ [el.id]: Number(el.value) });
  else if (el.id === 'notify_threshold') save({ notify_threshold: Number(el.value) });
  else if (el.id === 'ssh-pick') { if (el.value) addHost(el.value); }
  else if (['show_claude', 'show_codex', 'card_show', 'card_on_top', 'stats_card_show', 'stats_card_on_top',
            'stats_card_show_claude', 'stats_card_show_codex', 'notify_run_out', 'notify_reset', 'notify_credits', 'card_show_claude', 'card_show_codex'].includes(el.id)) save({ [el.id]: el.checked });
  else if (el.dataset.num) save({ [el.dataset.num]: Number(el.value) });
  else if (el.id === 'autostart') {
    await invoke(el.checked ? 'plugin:autostart|enable' : 'plugin:autostart|disable').catch(() => {});
    autostart = await invoke('plugin:autostart|is_enabled').catch(() => false);
    render();
  }
});

document.addEventListener('input', (e) => {
  const el = e.target;
  if (el.id === 'new-host') { newHostDraft = el.value; return; }
  if (el.dataset.num) el.nextElementSibling.textContent = `${Math.round(el.value * 100)}%`;
});

// 桌面卡片：按住拖动（位置由 Rust 按光标算，好做吸附对齐），右键弹出菜单
if (ANY_CARD) {
  let dragging = false, busy = false;
  const end = () => {
    if (!dragging) return;
    dragging = false;
    invoke('card_drag_end');
  };
  document.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    dragging = true;
    e.target.setPointerCapture?.(e.pointerId);  // 窗口跟着挪时光标不会「掉出去」
    invoke('card_drag_start');
  });
  document.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    if (!(e.buttons & 1)) { end(); return; }
    if (busy) return;  // 上一步还没挪完就不发，免得排队
    busy = true;
    invoke('card_drag_move').finally(() => { busy = false; });
  });
  document.addEventListener('pointerup', end);
  document.addEventListener('pointercancel', end);
  document.addEventListener('contextmenu', (e) => { e.preventDefault(); invoke('card_menu'); });
}

// 对齐线：收到「竖线 x、横线 y」（逻辑像素，可能为空）就画出来
function drawGuides([x, y]) {
  document.body.innerHTML =
    (x != null ? `<div class="guide v" style="left:${x - 0.5}px"></div>` : '') +
    (y != null ? `<div class="guide h" style="top:${y - 0.5}px"></div>` : '');
}

(async () => {
  if (GUIDES) {
    document.documentElement.classList.add('guides');
    document.body.className = 'guides';
    await listen('guides', (e) => drawGuides(e.payload));
    return;
  }
  // 等后面的脚本（stats.js）也加载完再画
  if (document.readyState === 'loading') await new Promise((r) => document.addEventListener('DOMContentLoaded', r));
  if (FLYOUT) document.body.classList.add('flyout');
  if (ANY_CARD) { document.documentElement.classList.add('card'); document.body.classList.add('card'); }
  document.getElementById('version').textContent = await window.__TAURI__.app.getVersion().catch(() => '');
  autostart = await invoke('plugin:autostart|is_enabled').catch(() => false);
  if (!FLYOUT && !ANY_CARD) sshHosts = await invoke('ssh_config_hosts').catch(() => []);
  state = await invoke('get_state');
  render();
  await listen('state', (e) => {
    // 额度刷新后「重置以来」的起点可能变了：统计页重新查
    const cycleChanged = JSON.stringify(e.payload.cycle) !== JSON.stringify(state?.cycle);
    state = e.payload;
    if (page === 'stats' && cycleChanged && statsQ.range === 'cycle') fetchStats();
    render();
  });
  // 日志读进库以后：统计页按自己的条件重新查
  await listen('stats_changed', () => { if (page === 'stats' && !FLYOUT && !ANY_CARD) fetchStats(); });
  // 卡片右键「卡片设置…」：主窗口切到卡片页
  // 卡片右键「卡片设置…」：主窗口切到卡片页，并切到那张卡片
  await listen('navigate', (e) => {
    const [p, which] = Array.isArray(e.payload) ? e.payload : [e.payload];
    page = p;
    if (which) cardTab = which;
    render();
  });
  if (ANY_CARD) await listen('card_sync', (e) => { synced = e.payload; render(); });
  // 重置倒计时每分钟走一次
  setInterval(() => { if (FLYOUT || ANY_CARD || page === 'tray' || page === 'card') render(); }, 60000);
})();
