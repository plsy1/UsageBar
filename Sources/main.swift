// UsageBar — 菜单栏显示 Claude / Codex 剩余用量
// 数据来源：
//   Claude: macOS 钥匙串 "Claude Code-credentials" 里的 OAuth token → api.anthropic.com/api/oauth/usage
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits

import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

// MARK: - 数据模型

struct LimitWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// 主要的周额度（Claude 的 seven_day、Codex 的 7 天窗口）；用量统计按它算「重置以来」
    var weekly = false
    /// 窗口总长（秒）：5 小时或 7 天；不知道时为 0，不算速度
    var length: TimeInterval = 0
    var remaining: Double { max(0, 100 - usedPercent) }

    /// 这个窗口已经过去的比例（0~1）
    var elapsed: Double? {
        guard length > 0, let r = resetsAt else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSinceNow / length))
    }
    /// 用得比时间快：已用的比例明显超过已过去的比例。窗口刚开始的一成时间不算，样本太少
    var fast: Bool {
        guard let e = elapsed, e >= 0.1, usedPercent < 100 else { return false }
        let u = usedPercent / 100
        return u - e >= 0.05 && u > e * 1.15
    }
    /// 按这个窗口开始以来的平均速度，什么时候用完；重置前用不完就是 nil
    var runsOutAt: Date? {
        guard let e = elapsed, e >= 0.1, usedPercent > 0, usedPercent < 100, let r = resetsAt else { return nil }
        let spent = length * e
        let t = Date().addingTimeInterval((100 - usedPercent) / (usedPercent / spent))
        return t < r ? t : nil
    }
    /// 按设置显示剩余还是已使用（进度条和百分比都跟着变）
    func shown(_ used: Bool) -> Double { used ? min(100, usedPercent) : remaining }
    func shownText(_ used: Bool) -> String {
        let v = Int(shown(used).rounded())
        return used ? L("已用 %d%%", v) : L("剩 %d%%", v)
    }
}

struct ProviderUsage {
    let name: String
    var plan: String?
    var windows: [LimitWindow] = []
    var note: String?
    var error: String?
    /// Codex 的额度重置次数（OpenAI 送的「立即重置 5 小时和本周额度」）和最早一次的到期时间
    var resetCredits: ResetCredits?
    /// 各窗口里最紧的那个（剩余最少）
    var binding: LimitWindow? { windows.min { $0.remaining < $1.remaining } }
    var session: LimitWindow? { windows.first { !$0.weekly } }  // 5 小时（两家都排在第一个）
    var weekly: LimitWindow? { windows.first(where: \.weekly) }
    /// 菜单栏上的百分比：session 5 小时 / weekly 本周 / both「11%/86%」；没有就 nil
    func menuValue(_ which: String, used: Bool) -> String? {
        // 用得比时间快的额度后面加个 ↑
        let pct = { (w: LimitWindow) in "\(Int(w.shown(used).rounded()))%" + (w.fast ? "↑" : "") }
        switch which {
        case "session": return (session ?? weekly).map(pct)
        case "weekly": return (weekly ?? session).map(pct)
        default:
            switch (session, weekly) {
            case let (s?, w?): return pct(s) + "/" + pct(w)
            case let (s?, nil): return pct(s)
            case let (nil, w?): return pct(w)
            default: return nil
            }
        }
    }
}

struct ResetCredits {
    let count: Int
    /// 每一次的到期时间，从早到晚（详情接口没拿到时为空）
    let expiries: [Date]
    var earliest: Date? { expiries.first }

    /// 「可用重置 1 次」（英文单复数不同，1 次单独一条）
    var countText: String { count == 1 ? L("可用重置 1 次") : L("可用重置 %d 次", count) }
    /// 「可用重置 1 次 · 11/7 06:50 到期」；多次时只写最早那次：「可用重置 3 次 · 最早 11/7 06:50 到期」
    var text: String {
        guard let e = earliest else { return countText }
        return countText + " · " + (count > 1 ? L("最早 %@ 到期", Self.date(e)) : L("%@ 到期", Self.date(e)))
    }
    /// 菜单里逐条列出每次的到期时间（多于一次时）
    var lines: [String] { count > 1 ? expiries.map { L("%@ 到期", Self.date($0)) } : [] }

    static func date(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: d)
    }
}

// MARK: - 多语言（中文 / 日本語 / English）

/// 中文原文就是 key；表里是对应的日文和英文
enum I18n {
    static let table: [String: (ja: String, en: String)] = [
        // 额度名称
        "5 小时": ("5時間", "5 hours"),
        "本周": ("今週", "Weekly"),
        "本周 Opus": ("今週 Opus", "Weekly Opus"),
        "本周 Sonnet": ("今週 Sonnet", "Weekly Sonnet"),
        "%d 小时": ("%d時間", "%d hours"),
        "%d 天": ("%d日", "%d days"),
        // 错误和提示
        "在终端运行 claude auth login 登录一次": ("ターミナルで claude auth login を実行してログインしてください", "run claude auth login in Terminal"),
        "读不到 Claude Code 登录信息 · %@": ("Claude Code のログイン情報が見つかりません · %@", "No Claude Code login found · %@"),
        "Claude Code 登录已失效 · %@": ("Claude Code のログインが期限切れです · %@", "Claude Code login expired · %@"),
        "请求失败（HTTP %d）": ("リクエスト失敗（HTTP %d）", "Request failed (HTTP %d)"),
        "登录过期，显示本地缓存（打开 Codex 会自动刷新）": ("ログイン期限切れのためローカルキャッシュを表示（Codex を開くと更新されます）", "Login expired, showing local cache (opening Codex refreshes it)"),
        "接口请求失败（HTTP %d），显示本地缓存": ("API リクエスト失敗（HTTP %d）、ローカルキャッシュを表示", "API request failed (HTTP %d), showing local cache"),
        "本地缓存": ("ローカルキャッシュ", "Local cache"),
        "%@ · 数据时间 %@": ("%@ · データ時刻 %@", "%@ · data from %@"),
        "读不到 Codex 登录信息或会话记录": ("Codex のログイン情報またはセッション記録が見つかりません", "No Codex login or session history found"),
        // 重置时间
        "%d天%d小时": ("%d日%d時間", "%dd %dh"),
        "%d小时%d分": ("%d時間%d分", "%dh %dm"),
        "%d分钟": ("%d分", "%dm"),
        "%@后重置（%@）": ("%@後にリセット（%@）", "resets in %@ (%@)"),
        "%@后重置": ("%@後にリセット", "resets in %@"),
        // 卡片和菜单
        "剩 %d%%": ("残り %d%%", "%d%% left"),
        "已用 %d%%": ("使用済み %d%%", "%d%% used"),
        "显示数值": ("表示する値", "Show"),
        "剩余": ("残り", "Remaining"),
        "已使用": ("使用済み", "Used"),
        "正在获取用量…": ("使用量を取得中…", "Fetching usage…"),
        "更新于 %@": ("更新 %@", "Updated %@"),
        "正在刷新…": ("更新中…", "Refreshing…"),
        "立即刷新": ("今すぐ更新", "Refresh Now"),
        "隐藏桌面卡片": ("デスクトップカードを隠す", "Hide Desktop Card"),
        "显示桌面卡片": ("デスクトップカードを表示", "Show Desktop Card"),
        "退出": ("終了", "Quit"),
        // 设置窗口
        "通用": ("一般", "General"),
        "设置": ("設定", "Settings"),
        "布局、外观和大小，改动会实时显示在右边的预览里": ("レイアウト、外観、サイズ。変更は右のプレビューにすぐ反映されます", "Layout, look and size. Changes show up in the preview on the right"),
        "拖动桌面上的卡片可以移动位置，右键有更多操作": ("デスクトップのカードはドラッグで移動、右クリックでその他の操作", "Drag the card on the desktop to move it; right-click for more"),
        "状态": ("状態", "Status"),
        "已连接": ("接続済み", "Connected"),
        "价格表": ("価格表", "Prices"),
        "未获取": ("未取得", "Not loaded"),
        "立即更新": ("今すぐ更新", "Update Now"),
        "曲线图": ("折れ線グラフ", "Line Chart"),
        "柱状图": ("棒グラフ", "Bar Chart"),
        "更新失败，继续使用旧价格": ("更新に失敗しました。以前の価格を使用中", "Update failed, using cached prices"),
        "%d 条请求，最早 %@": ("%d 件、最古 %@", "%d requests since %@"),
        "布局": ("レイアウト", "Layout"),
        "%@ 的额度被提前重置了": ("%@ の上限が予定より早くリセットされました", "%@ limits were reset early"),
        "%@ 的额度已重置": ("%@ の上限がリセットされました", "%@ limits have reset"),
        "%@（之前用了 %d%%）": ("%@（それまで %d%% 使用）", "%@ (was %d%% used)"),
        "、": ("、", ", "),
        "提前重置（官方统一重置或用了重置次数）时，或之前用了一半以上时": ("予定より早くリセットされたとき（公式の一斉リセットやリセットの使用）、またはそれまでに半分以上使っていたとき", "When reset early (an across-the-board reset or a reset you used), or after over half had been used"),
        "Codex 额度重置次数": ("Codex の上限リセット", "Codex Resets"),
        "新获得时，以及到期前 24 小时": ("新たにもらったとき、期限の 24 時間前", "When you get one, and 24 hours before one expires"),
        "Codex 获得了 1 次额度重置": ("Codex の上限リセットを 1 回もらいました", "Codex gave you a limit reset"),
        "Codex 获得了 %d 次额度重置": ("Codex の上限リセットを %d 回もらいました", "Codex gave you %d limit resets"),
        "每日用量": ("日ごとの使用量", "Daily Usage"),
        "少": ("少", "Less"),
        "多": ("多", "More"),
        "%d 次请求": ("%d リクエスト", "%d requests"),
        "按项目": ("プロジェクト別", "By Project"),
        "项目": ("プロジェクト", "Project"),
        "未知目录": ("不明なディレクトリ", "Unknown Directory"),
        "会话记录": ("セッション記録", "Session Logs"),
        "读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），以及「通用」里添加的远程机器上的 Codex 日志（用 ssh 读取，在远程先过滤）；成本按 models.dev 的 API 价格估算，价格每天更新一次": ("この Mac のセッション記録（~/.claude/projects と ~/.codex/sessions）と、「一般」で追加したリモートマシンの Codex ログ（ssh で読み込み、リモート側で絞り込み）を読みます。コストは models.dev の API 価格で推定し、価格は 1 日 1 回更新します", "Reads this Mac's session logs (~/.claude/projects and ~/.codex/sessions) plus Codex logs on remote machines added under General (read over ssh, filtered on the remote side); cost is estimated from models.dev API prices, refreshed daily"),
        "所有数据只在这台 Mac、你添加的远程机器和上述官方服务之间传输，不经过其他服务器": ("データはこの Mac、追加したリモートマシン、上記の公式サービスの間でのみやり取りされ、他のサーバーを経由しません", "Data only travels between this Mac, the remote machines you add and those official services, never through other servers"),
        "通知": ("通知", "Notifications"),
        "通知没有打开：请在 系统设置 → 通知 → UsageBar 中允许": ("通知がオフです：システム設定 → 通知 → UsageBar で許可してください", "Notifications are off: allow UsageBar in System Settings → Notifications"),
        "用量达到": ("使用量が達したら", "Usage Reaches"),
        "不提醒": ("通知しない", "Off"),
        "预计在重置前用完": ("リセット前に使い切りそうなとき", "On Pace to Run Out"),
        "用了三成以上、用得比时间快时": ("30% 以上使い、時間より速いペースのとき", "Over 30% used and ahead of pace"),
        "额度重置后": ("上限がリセットされたら", "After a Reset"),
        "%@ 已用 %d%%": ("%@ を %d%% 使用", "%@ is %d%% used"),
        "%@ 用得比时间快": ("%@ が速いペースです", "%@ is ahead of pace"),
        "按现在的速度预计 %@ 用完，%@": ("このペースだと %@ に使い切ります。%@", "At this pace it runs out %@; %@"),
        "Codex 的额度重置次数快到期了": ("Codex のリセットがまもなく期限切れ", "A Codex reset is about to expire"),
        "有 1 次重置将在 %@ 到期，用不掉就作废": ("リセット 1 回分が %@ に期限切れになります。使わないと失効します", "One reset expires %@; it's lost if unused"),
        "用得比时间快：已用的比例超过了这个周期已经过去的比例": ("時間の進みより速いペース：使用した割合がこの期間の経過割合を上回っています", "Ahead of pace: you've used more of this limit than the share of the period that has passed"),
        "预计 %@ 用完": ("%@ に使い切る見込み", "runs out %@"),
        "样式": ("スタイル", "Style"),
        "单行": ("1 行", "One Line"),
        "双行": ("2 行", "Two Lines"),
        "左右": ("横並び", "Side by Side"),
        "上下": ("縦並び", "Stacked"),
        "紧凑": ("コンパクト", "Compact"),
        // 用量统计
        "打开 UsageBar…": ("UsageBar を開く…", "Open UsageBar…"),
        "检查更新": ("アップデートを確認", "Check for Updates"),
        "正在检查…": ("確認中…", "Checking…"),
        "已是最新版本": ("最新バージョンです", "You're up to date"),
        "发现新版本 %@": ("新しいバージョン %@ があります", "Version %@ is available"),
        "更新并重启": ("アップデートして再起動", "Update and Restart"),
        "查看详情": ("詳細", "Details"),
        "正在下载并安装…": ("ダウンロードしてインストール中…", "Downloading and installing…"),
        "更新失败：%@": ("アップデートに失敗しました：%@", "Update failed: %@"),
        "重试": ("再試行", "Retry"),
        "前往下载页": ("ダウンロードページを開く", "Open Download Page"),
        "有新版本 %@…": ("新しいバージョン %@ があります…", "Update Available: %@…"),
        "网络错误": ("ネットワークエラー", "Network error"),
        "缺少校验值": ("チェックサムがありません", "Missing checksum"),
        "校验失败": ("チェックサムが一致しません", "Checksum mismatch"),
        "安装包不完整": ("インストーラーが不完全です", "Incomplete package"),
        "没有写入权限": ("書き込み権限がありません", "No permission to replace the app"),
        "卡片设置…": ("カードの設定…", "Card Settings…"),
        "用量统计": ("使用量の統計", "Usage Statistics"),
        "今天": ("今日", "Today"),
        "重置以来": ("リセット以降", "Since Reset"),
        "%@ 自 %@ 起": ("%@ %@ から", "%@ since %@"),
        "%@ 周期未知，按最近 7 天": ("%@ は周期が不明なため直近 7 日間", "%@ cycle unknown, using last 7 days"),
        "近 24 小时": ("過去 24 時間", "Last 24 Hours"),
        "近 7 天": ("過去 7 日間", "Last 7 Days"),
        "近 14 天": ("過去 14 日間", "Last 14 Days"),
        "近 30 天": ("過去 30 日間", "Last 30 Days"),
        "全部时间": ("全期間", "All Time"),
        "自定义": ("カスタム", "Custom"),
        "开始时间": ("開始", "Start"),
        "结束时间": ("終了", "End"),
        "结束时间跟随当前时刻": ("終了時刻を現在に合わせる", "End at the current time"),
        "取消": ("キャンセル", "Cancel"),
        "确定": ("適用", "Apply"),
        "现在": ("現在", "Now"),
        "全部": ("すべて", "All"),
        "估算成本": ("推定コスト", "Est. Cost"),
        "请求数": ("リクエスト数", "Requests"),
        "缓存命中率": ("キャッシュヒット率", "Cache Hit Rate"),
        "Tokens · 按小时": ("Tokens · 時間別", "Tokens · Hourly"),
        "Tokens · 按天": ("Tokens · 日別", "Tokens · Daily"),
        "按应用": ("アプリ別", "By App"),
        "按模型": ("モデル別", "By Model"),
        "请求明细": ("リクエスト履歴", "Request Log"),
        "模型": ("モデル", "Model"),
        "应用": ("アプリ", "App"),
        "时间": ("時刻", "Time"),
        "成本": ("コスト", "Cost"),
        "新增输入": ("新規入力", "New Input"),
        "输出": ("出力", "Output"),
        "缓存读取": ("キャッシュ読取", "Cache Read"),
        "缓存写入": ("キャッシュ書込", "Cache Write"),
        "命中率": ("ヒット率", "Hit Rate"),
        "累计 %@ tokens": ("累計 %@ tokens", "%@ tokens lifetime"),
        "服务端数据统计": ("サーバー側の統計", "Server Statistics"),
        "日均": ("1 日平均", "Daily Avg"),
        "最多的一天": ("最多の日", "Peak Day"),
        "数据截至": ("データの最終日", "Data Through"),
        "来自 OpenAI 账号统计：所有设备合计，只有总 tokens，按 UTC 日，通常晚 1–2 天出数。和上面按日志记录算的数据分开，不参与成本估算。": ("OpenAI アカウントの統計：全デバイスの合計で、総 tokens のみ、UTC 日単位、通常 1〜2 日遅れて反映されます。上のログ記録に基づく集計とは別で、コスト推定には使いません。", "From your OpenAI account statistics: all devices combined, total tokens only, by UTC day, usually 1–2 days behind. Kept separate from the log-based figures above and not used for cost estimates."),
        "本机": ("この Mac", "This Mac"),
        "全部机器": ("すべてのマシン", "All Machines"),
        "%d 台机器": ("%d 台のマシン", "%d Machines"),
        "Codex 记录来自哪几台机器": ("Codex の記録をどのマシンから表示するか", "Which machines' Codex logs to show"),
        "所选范围里最近几天服务端还没出数。": ("選択した期間の直近数日はまだサーバーに反映されていません。", "The most recent days in this range aren't on the server yet."),
        "可用重置 1 次": ("リセット 1 回分", "1 reset available"),
        "可用重置 %d 次": ("リセット %d 回分", "%d resets available"),
        "%@ 到期": ("%@ まで", "expires %@"),
        "最早 %@ 到期": ("最も早いもの %@ まで", "earliest expires %@"),
        "保持在最前": ("常に手前に表示", "Keep on Top"),
        "关掉时贴在桌面上，会被其他窗口盖住": ("オフのときはデスクトップに置かれ、他のウインドウに隠れます", "When off, the card sits on the desktop behind other windows"),
        "开机启动、外观、刷新频率和数据来源": ("ログイン時の起動、外観、更新頻度、データソース", "Launch at login, appearance, refresh and data sources"),
        "用量统计只读取新写入的日志，刷新很快": ("使用統計は新しく書き込まれた記録だけを読むので、更新はすぐ終わります", "Usage statistics only read newly written logs, so refreshing is quick"),
        "向 Anthropic 和 OpenAI 查询剩余额度": ("Anthropic と OpenAI に残りの上限を問い合わせます", "Asks Anthropic and OpenAI for remaining limits"),
        "读取本机和远程机器的会话记录": ("この Mac とリモートマシンのセッション記録を読み込みます", "Reads session logs on this Mac and remote machines"),
        "菜单栏文字": ("メニューバーの文字", "Menu Bar Text"),
        "显示的额度": ("表示する上限", "Limit Shown"),
        "都显示": ("両方", "Both"),
        "下拉菜单": ("メニュー", "Menu"),
        "完整": ("すべて", "Full"),
        "只影响菜单栏，两张卡片在「卡片」里各自设置": ("メニューバーだけに適用されます。2 枚のカードは「カード」で個別に設定します", "Applies to the menu bar only; each card has its own settings under Cards"),
        "全名": ("フルネーム", "Full Name"),
        "基本": ("基本", "Basics"),
        "后台增量更新": ("バックグラウンドで差分更新", "Updates in the background"),
        "隐私": ("プライバシー", "Privacy"),
        "所有版本": ("すべてのリリース", "All Releases"),
        "反馈问题": ("問題を報告", "Report an Issue"),
        "用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询": ("この Mac の Claude Code と Codex のログイン情報を使い、Anthropic と OpenAI の使用量 API に問い合わせます", "Uses this Mac's Claude Code and Codex logins to ask Anthropic's and OpenAI's usage endpoints"),
        "卡片": ("カード", "Cards"),
        "额度卡片": ("上限カード", "Limits Card"),
        "用量卡片": ("使用量カード", "Usage Card"),
        "显示额度卡片": ("上限カードを表示", "Show Limits Card"),
        "隐藏额度卡片": ("上限カードを隠す", "Hide Limits Card"),
        "额度": ("上限", "Limits"),
        "数据从哪里来，见「关于」": ("データの取得元は「情報」を参照", "See About for where the data comes from"),
        "版本、更新和数据说明": ("バージョン、アップデート、データについて", "Version, updates and where the data comes from"),
        "数据说明": ("データについて", "About the Data"),
        "开机启动、外观、额度显示和数据来源": ("ログイン時の起動、外観、上限の表示、データソース", "Launch at login, appearance, limits and data sources"),
        "菜单栏和两张卡片都按这里显示": ("メニューバーと 2 枚のカードはここの設定で表示します", "The menu bar and both cards follow these settings"),
        "菜单栏上显示的文字，右边是点开后的菜单": ("メニューバーに表示する文字。右はクリックしたときのメニューです", "What the menu bar shows; the menu it opens is on the right"),
        "额度卡片和用量卡片分开设置，改动会实时显示在右边的预览里": ("上限カードと使用量カードは別々に設定します。変更は右のプレビューにすぐ反映されます", "Set up the limits card and the usage card separately; changes show in the preview on the right"),
        "用量卡片显示各家的估算成本、请求数、Tokens 和缓存命中率": ("使用量カードには各サービスの推定コスト、リクエスト数、Tokens、キャッシュヒット率を表示します", "The usage card shows each service's estimated cost, requests, tokens and cache hit rate"),
        "额度卡片显示各家额度的剩余（或已用）和重置时间": ("上限カードには各上限の残り（または使用済み）とリセット時刻を表示します", "The limits card shows how much of each limit is left (or used) and when it resets"),
        "拖动表头换顺序，拖动分隔线调整宽度": ("見出しをドラッグで並べ替え、区切り線をドラッグで幅を調整", "Drag a header to reorder; drag a divider to resize"),
        "成功率": ("成功率", "Success"),
        "显示用量卡片": ("使用量カードを表示", "Show Usage Card"),
        "隐藏用量卡片": ("使用量カードを隠す", "Hide Usage Card"),
        "统计范围": ("集計期間", "Period"),
        "打开用量统计…": ("使用統計を開く…", "Open Usage Statistics…"),
        "用量卡片显示各家的估算成本、请求数和 Tokens，布局和外观跟额度卡片一样": ("使用量カードには各サービスの推定コスト、リクエスト数、Tokens を表示します。レイアウトと外観は上限カードと共通です", "The usage card shows each service's estimated cost, requests and tokens, with the same layout and look as the limits card"),
        "收起": ("閉じる", "Show Less"),
        "更多指标": ("その他の指標", "More Metrics"),
        "速度": ("速度", "Speed"),
        "首字": ("初回応答", "TTFT"),
        "总耗时": ("合計時間", "Duration"),
        "状态码": ("ステータス", "Status"),
        "全部状态码": ("すべてのステータス", "All Statuses"),
        "显示的列": ("表示する列", "Columns"),
        "恢复默认": ("デフォルトに戻す", "Reset to Default"),
        "请求详情": ("リクエストの詳細", "Request Details"),
        "关闭": ("閉じる", "Close"),
        "基本信息": ("基本情報", "Basics"),
        "请求 ID": ("リクエスト ID", "Request ID"),
        "请求失败": ("リクエスト失敗", "Request failed"),
        "Tokens 用量": ("Tokens 使用量", "Tokens"),
        "成本明细（USD）": ("コスト内訳（USD）", "Cost Breakdown (USD)"),
        "合计": ("合計", "Total"),
        "失败的请求不计费": ("失敗したリクエストは課金されません", "Failed requests aren't billed"),
        "models.dev 里没有这个模型的价格": ("models.dev にこのモデルの価格がありません", "No price for this model on models.dev"),
        "性能": ("パフォーマンス", "Performance"),
        "输出不到 %d token，不估速度": ("出力が %d token 未満のため速度は推定しません", "Under %d output tokens, speed not estimated"),
        "首字（估算）": ("初回応答（推定）", "TTFT (est.)"),
        "耗时（估算）": ("所要時間（推定）", "Duration (est.)"),
        "耗时按会话日志的时间戳估算：从请求发出到最后一段内容写进日志。日志要等一段内容生成完才写，所以首字偏大。": ("時間はセッション記録のタイムスタンプから推定しています（リクエスト送信から最後の内容が記録されるまで）。記録は内容のまとまりが生成し終わってから書かれるため、初回応答は長めに出ます。", "Times are estimated from session log timestamps, from when the request was sent until its last part was logged. The log is written only after each part finishes, so TTFT reads high."),
        "正在读取本机会话记录…": ("ローカルのセッション記録を読み込み中…", "Reading local session logs…"),
        "该时间段内没有记录": ("この期間の記録はありません", "No usage in this period"),
        "成本按 models.dev 的 API 价格估算，统计本机和已添加的远程机器上的会话记录": ("コストは models.dev の API 価格による推定で、この Mac と追加したリモートマシンのセッション記録を集計しています", "Cost is estimated from models.dev API prices and covers session logs on this Mac and the remote machines you added"),
        "SSH · %d 个日志文件": ("SSH · ログ %d 件", "SSH · %d log files"),
        "SSH · 读取中…": ("SSH · 読み込み中…", "SSH · Reading…"),
        "%@ 条请求": ("%@ リクエスト", "%@ requests"),
        "移除": ("削除", "Remove"),
        "远程机器": ("リモートマシン", "Remote Machines"),
        "Codex 跑在远程时日志只在那边，用 SSH 读回来": ("Codex をリモートで動かすとログはそちらにだけ残るので、SSH で読み込みます", "Codex keeps its logs on the machine it runs on; read them over SSH"),
        "主机名": ("ホスト名", "Host"),
        "~/.ssh/config 里的主机": ("~/.ssh/config のホスト", "Hosts in ~/.ssh/config"),
        "添加": ("追加", "Add"),
        "超时": ("タイムアウト", "Timed out"),
        "连不上": ("接続できません", "Can't connect"),
        "连不上：请在 系统设置 → 隐私与安全性 → 本地网络 中允许 UsageBar": ("接続できません：システム設定 → プライバシーとセキュリティ → ローカルネットワーク で UsageBar を許可してください", "Can't connect: allow UsageBar in System Settings → Privacy & Security → Local Network"),
        "第 %d / %d 页 · 共 %d 条": ("%d / %d ページ · 全 %d 件", "Page %d of %d · %d total"),
        "上一页": ("前のページ", "Previous Page"),
        "下一页": ("次のページ", "Next Page"),
        "开机启动": ("ログイン時に起動", "Launch at Login"),
        "需要在 系统设置 → 通用 → 登录项 中允许 UsageBar": ("システム設定 → 一般 → ログイン項目 で UsageBar を許可してください", "Allow UsageBar in System Settings → General → Login Items"),
        "关于": ("情報", "About"),
        "预览": ("プレビュー", "Preview"),
        "版本 %@": ("バージョン %@", "Version %@"),
        "在菜单栏和桌面显示 Claude 与 Codex 的剩余用量": ("Claude と Codex の残り使用量をメニューバーとデスクトップに表示", "Shows remaining Claude and Codex usage in the menu bar and on the desktop"),
        "语言": ("言語", "Language"),
        "跟随系统": ("システムに合わせる", "System"),
        "桌面卡片": ("デスクトップカード", "Desktop Card"),
        "背景": ("背景", "Background"),
        "无": ("なし", "None"),
        "深色毛玻璃": ("すりガラス（ダーク）", "Frosted (Dark)"),
        "浅色毛玻璃": ("すりガラス（ライト）", "Frosted (Light)"),
        "文字颜色": ("文字色", "Text Color"),
        "白色": ("白", "White"),
        "黑色": ("黒", "Black"),
        "毛玻璃浓度": ("すりガラスの濃さ", "Frosted Strength"),
        "大小": ("サイズ", "Size"),
        "整体不透明度": ("全体の不透明度", "Overall Opacity"),
        "重置时间": ("リセット時刻", "Reset Time"),
        "不显示": ("表示しない", "Hidden"),
        "剩余时间": ("残り時間", "Time Left"),
        "具体时间": ("時刻", "Clock Time"),
        "%@ 重置": ("%@ にリセット", "resets %@"),
        "菜单栏": ("メニューバー", "Menu Bar"),
        "名称": ("表示名", "Labels"),
        "简写（Cc / Cx）": ("略称（Cc / Cx）", "Short (Cc / Cx)"),
        "全名（Claude / Codex）": ("フルネーム（Claude / Codex）", "Full (Claude / Codex)"),
        "刷新间隔": ("更新間隔", "Refresh Interval"),
        "刷新间隔（后台增量更新）": ("更新間隔（バックグラウンドで差分更新）", "Refresh Interval (in the background)"),
        "额度显示": ("上限の表示", "Limits"),
        "数据来源": ("データソース", "Data Sources"),
        "菜单栏和桌面卡片显示哪些额度、怎么显示": ("メニューバーとカードに表示する上限と表示方法", "Which limits the menu bar and card show, and how"),
        "用量从哪里读取，以及价格表和本机记录": ("使用量の取得元、価格表、ローカルの記録", "Where usage comes from, plus prices and local logs"),
        "显示内容": ("表示内容", "Content"),
        "来源": ("取得元", "Source"),
        "Claude Code 登录（钥匙串）": ("Claude Code のログイン（キーチェーン）", "Claude Code login (Keychain)"),
        "说明": ("説明", "Notes"),
        "主题色": ("テーマカラー", "Theme Color"),
        "外观": ("外観", "Appearance"),
        "自动": ("自動", "Auto"),
        "浅色": ("ライト", "Light"),
        "深色": ("ダーク", "Dark"),
        "开机启动、外观、语言和主题色": ("ログイン時の起動、外観、言語、テーマカラー", "Launch at login, appearance, language and theme color"),
        "粉色": ("ピンク", "Pink"),
        "紫色": ("パープル", "Purple"),
        "蓝色": ("ブルー", "Blue"),
        "青色": ("ティール", "Teal"),
        "绿色": ("グリーン", "Green"),
        "橙色": ("オレンジ", "Orange"),
        "灰色": ("グレー", "Gray"),
        "刷新": ("更新", "Refresh"),
        "%d 分钟": ("%d 分", "%d min"),
    ]

    /// 当前语言：zh / ja / en；"跟随系统" 时按系统首选语言，非中日一律英文
    static var lang: String {
        let p = UserDefaults.standard.string(forKey: Pref.language) ?? "auto"
        if p != "auto" { return p }
        let sys = Locale.preferredLanguages.first ?? "en"
        return sys.hasPrefix("zh") ? "zh" : sys.hasPrefix("ja") ? "ja" : "en"
    }
}

func L(_ zh: String, _ args: CVarArg...) -> String {
    let lang = I18n.lang
    let fmt = lang == "zh" ? zh : I18n.table[zh].map { lang == "ja" ? $0.ja : $0.en } ?? zh
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}

// MARK: - 工具函数

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 接口给的套餐名是小写的（team、plus、max），显示成 Team、Plus、Max
func planName(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

func httpJSON(_ req: URLRequest) async -> (status: Int, json: [String: Any]?) {
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (status, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
}

// MARK: - Claude

enum Claude {
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURLs = ["https://platform.claude.com/v1/oauth/token",
                            "https://console.anthropic.com/v1/oauth/token"]
    static let labels = ["five_hour": "5 小时", "seven_day": "本周",
                         "seven_day_opus": "本周 Opus", "seven_day_sonnet": "本周 Sonnet"]
    static let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]

    static func readCreds() -> [String: Any]? {
        let r = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        guard r.status == 0, let d = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func writeCreds(_ creds: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: creds) else { return }
        let hex = d.map { String(format: "%02x", $0) }.joined()
        run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(), "-s", service, "-X", hex])
    }

    /// 用 refresh token 换新的 access token，并写回钥匙串（和 Claude Code 自己的做法一致）
    static func refresh(_ creds: inout [String: Any]) async -> Bool {
        guard var oauth = creds["claudeAiOauth"] as? [String: Any],
              let rt = oauth["refreshToken"] as? String, !rt.isEmpty else { return false }
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]
        for url in tokenURLs {
            var req = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let (status, json) = await httpJSON(req)
            guard status == 200, let json, let at = json["access_token"] as? String else { continue }
            oauth["accessToken"] = at
            if let newRT = json["refresh_token"] as? String { oauth["refreshToken"] = newRT }
            if let exp = json["expires_in"] as? Double {
                oauth["expiresAt"] = Int64((Date().timeIntervalSince1970 + exp) * 1000)
            }
            creds["claudeAiOauth"] = oauth
            writeCreds(creds)
            return true
        }
        return false
    }

    static func fetch() async -> ProviderUsage {
        var u = ProviderUsage(name: "Claude")
        let loginHint = L("在终端运行 claude auth login 登录一次")
        guard var creds = readCreds(), let oauth = creds["claudeAiOauth"] as? [String: Any] else {
            u.error = L("读不到 Claude Code 登录信息 · %@", loginHint); return u
        }
        u.plan = planName(oauth["subscriptionType"] as? String)

        let expiresAt = (oauth["expiresAt"] as? Double ?? 0) / 1000
        var refreshed = false
        if expiresAt < Date().timeIntervalSince1970 + 60 {
            refreshed = await refresh(&creds)
            if !refreshed { u.error = L("Claude Code 登录已失效 · %@", loginHint); return u }
        }

        for attempt in 0..<2 {
            let token = (creds["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String ?? ""
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
            let (status, json) = await httpJSON(req)
            if status == 401, attempt == 0, !refreshed, await refresh(&creds) { refreshed = true; continue }
            guard status == 200, let json else {
                u.error = status == 401 ? L("Claude Code 登录已失效 · %@", loginHint)
                                        : L("请求失败（HTTP %d）", status)
                return u
            }
            let keys = order.filter { json[$0] != nil } + json.keys.filter { !order.contains($0) }.sorted()
            for key in keys {
                guard let w = json[key] as? [String: Any], let util = w["utilization"] as? Double else { continue }
                u.windows.append(LimitWindow(label: labels[key].map { L($0) } ?? key, usedPercent: util,
                                             resetsAt: (w["resets_at"] as? String).flatMap(parseISODate),
                                             weekly: key == "seven_day",
                                             length: key == "five_hour" ? 5 * 3600 : key.hasPrefix("seven_day") ? 7 * 86400 : 0))
            }
            return u
        }
        return u
    }
}

// MARK: - Codex

enum Codex {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    static func windowLabel(seconds: Double) -> String {
        switch seconds {
        case ..<(6 * 3600): return L("%d 小时", Int(seconds / 3600))
        case (6 * 86400)...(8 * 86400): return L("本周")
        default: return L("%d 天", Int(seconds / 86400))
        }
    }

    /// 账号统计（OpenAI 服务端按账号汇总，其他电脑和云端任务都算在内）：每天的 tokens 和累计总数。
    /// 只读；按天汇总，一般晚一天
    static func fetchAccount() async -> CodexAccount? {
        guard let d = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let at = tokens["access_token"] as? String else { return nil }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!, timeoutInterval: 15)
        req.setValue("Bearer \(at)", forHTTPHeaderField: "Authorization")
        if let aid = tokens["account_id"] as? String { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        let (status, json) = await httpJSON(req)
        guard status == 200, let stats = json?["stats"] as? [String: Any] else { return nil }
        var daily: [String: Int] = [:]
        for b in stats["daily_usage_buckets"] as? [[String: Any]] ?? [] {
            if let day = b["start_date"] as? String, let n = (b["tokens"] as? NSNumber)?.intValue { daily[day] = n }
        }
        return CodexAccount(daily: daily, lifetime: (stats["lifetime_tokens"] as? NSNumber)?.intValue ?? 0,
                            asOf: (json?["metadata"] as? [String: Any])?["stats_as_of"] as? String)
    }

    static func fetch() async -> ProviderUsage {
        var u = ProviderUsage(name: "Codex")
        if let d = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
           let auth = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let tokens = auth["tokens"] as? [String: Any],
           let at = tokens["access_token"] as? String {
            var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
            req.setValue("Bearer \(at)", forHTTPHeaderField: "Authorization")
            if let aid = tokens["account_id"] as? String { req.setValue(aid, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            let (status, json) = await httpJSON(req)
            if status == 200, let json, let rl = json["rate_limit"] as? [String: Any] {
                u.plan = planName(json["plan_type"] as? String)
                for key in ["primary_window", "secondary_window"] {
                    guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                    let seconds = w["limit_window_seconds"] as? Double ?? 0
                    u.windows.append(LimitWindow(
                        label: windowLabel(seconds: seconds),
                        usedPercent: used,
                        resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
                        weekly: seconds == 7 * 86400, length: seconds))
                }
                // 有可用的重置次数才去查详情（只读，拿最早到期的时间）
                if let rc = json["rate_limit_reset_credits"] as? [String: Any], let n = rc["available_count"] as? Int, n > 0 {
                    var detail = req
                    detail.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
                    let (st, dj) = await httpJSON(detail)
                    let expiries = st == 200 ? (dj?["credits"] as? [[String: Any]] ?? [])
                        .filter { $0["status"] as? String == "available" }
                        .compactMap { ($0["expires_at"] as? String).flatMap(parseISODate) }.sorted() : []
                    u.resetCredits = ResetCredits(count: n, expiries: expiries)
                }
                return u
            }
            u.note = status == 401 ? L("登录过期，显示本地缓存（打开 Codex 会自动刷新）")
                                   : L("接口请求失败（HTTP %d），显示本地缓存", status)
        }
        // 退回：最近一次会话日志里的 rate_limits
        if let (rl, mtime) = latestLocalRateLimits() {
            u.plan = u.plan ?? planName(rl["plan_type"] as? String)
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                // 已经过了重置时间的窗口，用量视为归零
                let expired = reset.map { $0 < Date() } ?? false
                let seconds = (w["window_minutes"] as? Double ?? 0) * 60
                u.windows.append(LimitWindow(label: windowLabel(seconds: seconds),
                                             usedPercent: expired ? 0 : used, resetsAt: expired ? nil : reset,
                                             weekly: seconds == 7 * 86400, length: seconds))
            }
            let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
            u.note = L("%@ · 数据时间 %@", u.note ?? L("本地缓存"), f.string(from: mtime))
        } else if u.windows.isEmpty {
            u.error = L("读不到 Codex 登录信息或会话记录")
        }
        return u
    }

    static func latestLocalRateLimits() -> ([String: Any], Date)? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: home.appendingPathComponent("sessions"),
                                    includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((url, m))
        }
        for (url, mtime) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      let rl = payload["rate_limits"] as? [String: Any] else { continue }
                return (rl, mtime)
            }
        }
        return nil
    }
}

// MARK: - 菜单栏 UI

func bar(_ percent: Double, width: Int = 12) -> String {
    let filled = Int((percent / 100 * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

/// style：full（菜单，「3小时21分后重置（03:30）」）/ relative（「3小时21分后重置」）/ absolute（「03:30 重置」「周一 06:00 重置」）
/// 今天内只写几点，否则带上星期几
func shortTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: ["zh": "zh_CN", "ja": "ja_JP"][I18n.lang] ?? "en_US")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (I18n.lang == "ja" ? "EEEE HH:mm" : "EEE HH:mm")
    return f.string(from: d)
}

func resetText(_ d: Date?, style: String = "full") -> String {
    guard var d else { return "" }
    // 接口给的重置时间常是 05:59:59.x：差几秒到整分钟就进位，和统计页的「重置以来」一致
    d = Date(timeIntervalSince1970: ((d.timeIntervalSince1970 + 5) / 60).rounded(.down) * 60)
    let s = max(0, d.timeIntervalSinceNow)
    let days = Int(s) / 86400, hours = Int(s) % 86400 / 3600, mins = Int(s) % 3600 / 60
    let rel = days > 0 ? L("%d天%d小时", days, hours) : hours > 0 ? L("%d小时%d分", hours, mins) : L("%d分钟", mins)
    if style == "relative" { return L("%@后重置", rel) }
    if style == "absolute" {
        // 今天内只写几点，否则带上星期几
        let f = DateFormatter()
        f.locale = Locale(identifier: ["zh": "zh_CN", "ja": "ja_JP"][I18n.lang] ?? "en_US")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (I18n.lang == "ja" ? "EEEE HH:mm" : "EEE HH:mm")
        return L("%@ 重置", f.string(from: d))
    }
    let f = DateFormatter(); f.dateFormat = days > 0 ? "M/d HH:mm" : "HH:mm"
    return L("%@后重置（%@）", rel, f.string(from: d))
}

// MARK: - 设置

enum Pref {
    static let showCard = "showCard"
    static let background = "cardBackground"   // none / dark / light
    static let textColor = "cardText"          // white / black
    static let scale = "cardScale"
    static let opacity = "cardOpacity"
    static let bgOpacity = "cardBgOpacity"     // 毛玻璃背景单独的不透明度
    static let showReset = "showReset"
    static let showClaude = "showClaude"
    static let showCodex = "showCodex"
    static let refreshMinutes = "refreshMinutes"
    static let statsRefreshMinutes = "statsRefreshMinutes"
    static let menuLabel = "menuLabel"         // short / full
    static let menuStyle = "menuStyle"         // inline 一行 / stacked 名称在上、数值在下两行
    static let language = "language"           // auto / zh / ja / en
    static let displayMode = "displayMode"     // remaining / used
    static let cardLayout = "cardLayout"       // horizontal / vertical / compact
    static let resetStyle = "cardResetStyle"   // hidden / relative（多久后）/ absolute（几点）
    static let appearance = "appearance"       // auto / light / dark
    // 菜单栏和两张卡片各自显示哪几家、剩余还是已用（旧版是共用的 showClaude / showCodex / displayMode，只用来给它们当初始值）
    static let menuShowClaude = "menuShowClaude"
    static let menuShowCodex = "menuShowCodex"
    static let menuDisplayMode = "menuDisplayMode"
    static let menuLimit = "menuLimit"             // session / weekly / both：菜单栏文字显示哪个额度
    static let menuResetStyle = "menuResetStyle"   // full / relative / absolute / hidden：下拉菜单里的重置时间
    static let cardShowClaude = "cardShowClaude"
    static let cardShowCodex = "cardShowCodex"
    static let cardDisplayMode = "cardDisplayMode"
    static let statsCardShowClaude = "statsCardShowClaude"
    static let statsCardShowCodex = "statsCardShowCodex"
    static let cardOnTop = "cardOnTop"             // 保持在最前；关掉时贴在桌面层
    static let statsCardOnTop = "statsCardOnTop"
    static let showStatsCard = "showStatsCard" // 用量卡片（成本、请求数、Tokens）
    static let statsCardRange = "statsCardRange"  // today / cycle / 7d
    // 用量卡片自己的布局和外观（和额度卡片分开设置）
    static let statsCardLayout = "statsCardLayout"
    static let statsCardScale = "statsCardScale"
    static let statsCardBackground = "statsCardBackground"
    static let statsCardText = "statsCardText"
    static let statsCardOpacity = "statsCardOpacity"
    static let statsCardBgOpacity = "statsCardBgOpacity"

    /// 主窗口和菜单的外观；桌面卡片有自己的文字颜色和背景，不受影响
    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil  // 跟随系统
        }
    }
    static var menuUsed: Bool { UserDefaults.standard.string(forKey: menuDisplayMode) == "used" }

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCard: true, background: "none", textColor: "white", scale: 1.0, opacity: 1.0, bgOpacity: 1.0,
            showReset: true, showClaude: true, showCodex: true, refreshMinutes: 5, statsRefreshMinutes: 5, menuLabel: "short", language: "auto", displayMode: "remaining", cardLayout: "horizontal", resetStyle: "relative", appearance: "auto",
            showStatsCard: false, statsCardRange: "today", cardOnTop: false, statsCardOnTop: false,
        ])
        // 用量卡片的外观一开始跟额度卡片现在的一样，之后各改各的
        let u = UserDefaults.standard
        // 各自的显示设置一开始沿用旧版共用的那份
        let claude = u.bool(forKey: showClaude), codex = u.bool(forKey: showCodex), mode = u.string(forKey: displayMode) ?? "remaining"
        u.register(defaults: [
            menuShowClaude: claude, menuShowCodex: codex, menuDisplayMode: mode, menuLimit: "both", menuResetStyle: "full",
            cardShowClaude: claude, cardShowCodex: codex, cardDisplayMode: mode,
            statsCardShowClaude: claude, statsCardShowCodex: codex,
        ])
        u.register(defaults: [
            statsCardLayout: u.string(forKey: cardLayout) ?? "horizontal", statsCardScale: u.double(forKey: scale),
            statsCardBackground: u.string(forKey: background) ?? "none", statsCardText: u.string(forKey: textColor) ?? "white",
            statsCardOpacity: u.double(forKey: opacity), statsCardBgOpacity: u.double(forKey: bgOpacity),
        ])
        // 旧版只有「显示重置时间」开关：关掉过的人沿用为「不显示」
        // 只看用户真正保存过的值（注册的默认值不算）
        let d = UserDefaults.standard
        let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.usagebar") ?? [:]
        if saved[resetStyle] == nil, saved[showReset] as? Bool == false { d.set("hidden", forKey: resetStyle) }
        // 去掉了「最紧的那个」，选过它的改成都显示
        if d.string(forKey: menuLimit) == "tightest" { d.set("both", forKey: menuLimit) }
    }
    /// 菜单栏显示这一家吗
    static func menuVisible(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: name == "Claude" ? menuShowClaude : menuShowCodex)
    }
}

/// 设置里每一行右侧的滑块 + 百分比
/// 百分比滑块（放在设置行右边）
struct PercentControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: range, step: step) { EmptyView() }
                .frame(width: 150)
            Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// 开机启动（系统设置 → 通用 → 登录项）
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static func set(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
    }
}

// MARK: - 设置页的版式：顶部标题，下面是自己画的分组卡片，宽度跟着窗口走，可以排成网格

/// 设置页：顶部标题，下面的内容铺满宽度，太高时上下滚动
struct SettingsScroll<Content: View>: View {
    let tab: MainTab
    let subtitle: String
    let content: Content
    init(_ tab: MainTab, _ subtitle: String, @ViewBuilder content: () -> Content) {
        self.tab = tab; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageHeader(tab: tab, subtitle: subtitle)
            ScrollView {
                content
                    .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 页面顶部：图标、标题、一句说明
struct PageHeader: View {
    let tab: MainTab
    let subtitle: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tab.symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 30).padding(.top, 28)
    }
}

/// 一组设置：小标题、圆角面板（里面一行一项，行之间自己放 Divider）、底下的说明
struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .modifier(Panel())
            if let footer {
                Text(footer).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 一行设置：左边名称（可带一行小字），右边控件
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    var warning = false  // detail 用红色（出错的说明）
    let control: Control
    init(_ title: String, detail: String? = nil, warning: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.detail = detail; self.warning = warning; self.control = control()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(warning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2).help(detail)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: 40)
        .padding(.vertical, 3)
    }
}

/// 设置行里的开关：和系统设置一样的小号开关
struct SwitchControl: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
}

/// 「通用」：四宫格——基本、刷新，用量统计、数据来源（显示哪几家、剩余还是已用在菜单栏和各张卡片里分别设）
struct GeneralSettings: View {
    let updater: Updater
    @ObservedObject var model: UsageModel
    @ObservedObject var stats: StatsStore
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage("statsChartColor") var chartColor = "pink"
    @AppStorage(Pref.appearance) var appearance = "auto"
    @AppStorage(Pref.refreshMinutes) var refreshMinutes = 5
    @AppStorage(Pref.statsRefreshMinutes) var statsRefreshMinutes = 5
    @AppStorage(LogReader.hostsKey) var remoteHosts = ""
    @State var newHost = ""
    @AppStorage(Notifier.thresholdKey) var notifyThreshold = 0
    @AppStorage(Notifier.runOutKey) var notifyRunOut = false
    @AppStorage(Notifier.resetKey) var notifyReset = false
    @AppStorage(Notifier.creditsKey) var notifyCredits = false
    @State var notifyAllowed = true
    @State var launchAtLogin = LoginItem.status == .enabled
    @State var needsApproval = LoginItem.status == .requiresApproval

    var body: some View {
        SettingsScroll(.general, L("开机启动、外观、刷新频率和数据来源")) {
            // 两列各自往下排（不按行对齐，免得短的一组下面空一大块）
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 26) { basic; notifications; usage }
                    .frame(maxWidth: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 26) { refresh; sources }
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    var basic: some View {
        SettingsGroup(L("基本"), footer: needsApproval ? L("需要在 系统设置 → 通用 → 登录项 中允许 UsageBar") : nil) {
            SettingsRow(L("开机启动")) {
                SwitchControl(isOn: Binding(get: { launchAtLogin }, set: { on in
                    LoginItem.set(on)
                    launchAtLogin = LoginItem.status == .enabled
                    needsApproval = LoginItem.status == .requiresApproval
                }))
            }
            Divider()
            SettingsRow(L("语言")) {
                Picker("", selection: $language) {
                    Text(L("跟随系统")).tag("auto")
                    Divider()
                    Text("中文").tag("zh")
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            SettingsRow(L("外观")) {
                Picker("", selection: $appearance) {
                    Text(L("自动")).tag("auto")
                    Text(L("浅色")).tag("light")
                    Text(L("深色")).tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Divider()
            // 主题色：统计图、开关、侧边栏和主窗口里的选中标记都用它
            SettingsRow(L("主题色")) {
                HStack(spacing: 7) {
                    ForEach(ChartColor.all, id: \.key) { c in
                        Button { chartColor = c.key } label: {
                            ChartColor.swatch(c.key).frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(chartColor == c.key ? 0.7 : 0), lineWidth: 1.5).padding(-3))
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        .help(L(c.name))
                    }
                }
            }
        }
    }

    var refresh: some View {
        SettingsGroup(L("刷新"), footer: L("用量统计只读取新写入的日志，刷新很快")) {
            SettingsRow(L("额度"), detail: L("向 Anthropic 和 OpenAI 查询剩余额度")) {
                Picker("", selection: $refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            SettingsRow(L("用量统计"), detail: L("读取本机和远程机器的会话记录")) {
                Picker("", selection: $statsRefreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    var notifications: some View {
        SettingsGroup(L("通知"), footer: notifyAllowed ? nil : L("通知没有打开：请在 系统设置 → 通知 → UsageBar 中允许")) {
            SettingsRow(L("用量达到")) {
                Picker("", selection: asking($notifyThreshold)) {
                    Text(L("不提醒")).tag(0)
                    ForEach([80, 90, 95], id: \.self) { Text("\($0)%").tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            SettingsRow(L("预计在重置前用完"), detail: L("用了三成以上、用得比时间快时")) { SwitchControl(isOn: asking($notifyRunOut)) }
            Divider()
            SettingsRow(L("额度重置后"), detail: L("提前重置（官方统一重置或用了重置次数）时，或之前用了一半以上时")) { SwitchControl(isOn: asking($notifyReset)) }
            Divider()
            SettingsRow(L("Codex 额度重置次数"), detail: L("新获得时，以及到期前 24 小时")) { SwitchControl(isOn: asking($notifyCredits)) }
        }
        .task {
            let ok = await Notifier.authorized()
            notifyAllowed = ok || !Notifier.anyEnabled
        }
    }

    /// 打开某项通知时顺便请求通知权限，并更新「没打开」的提示
    func asking<T>(_ b: Binding<T>) -> Binding<T> {
        Binding(get: { b.wrappedValue }, set: { v in
            b.wrappedValue = v
            Task {
                let ok = await Notifier.requestPermission()
                await MainActor.run { notifyAllowed = ok || !Notifier.anyEnabled }
            }
        })
    }

    var usage: some View {
        SettingsGroup(L("用量统计")) {
            SettingsRow(L("价格表"), detail: Pricing.updatedAt.map { "models.dev · " + L("更新于 %@", shortDate($0)) } ?? L("未获取")) {
                if stats.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("立即更新")) { stats.reload(forcePrices: true) }.controlSize(.small)
                }
            }
            if Pricing.downloadFailed && !stats.loading {
                Text(L("更新失败，继续使用旧价格")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }
            Divider()
            SettingsRow(L("会话记录")) {
                Text(stats.all.last.map { L("%d 条请求，最早 %@", stats.all.count, shortDate($0.time)) } ?? L("正在读取本机会话记录…"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var sources: some View {
        SettingsGroup(L("数据来源"), footer: L("数据从哪里来，见「关于」")) {
            provider("Claude", source: L("Claude Code 登录（钥匙串）"))
            Divider()
            provider("Codex", source: "~/.codex/auth.json")
            ForEach(hosts, id: \.self) { host in
                Divider()
                // 左边小字：SSH 和日志文件数（连不上时是红色的原因）；右边和上面两行一样只放一项：请求数
                let s = stats.remoteStatus[host]
                SettingsRow(host, detail: s.map { $0.error ?? L("SSH · %d 个日志文件", $0.files ?? 0) } ?? L("SSH · 读取中…"),
                            warning: s?.error != nil) {
                    HStack(spacing: 8) {
                        Text(s.map { L("%@ 条请求", $0.requests.formatted()) } ?? "—")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button { setHosts(hosts.filter { $0 != host }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(L("移除"))
                            .frame(width: Self.removeWidth)
                    }
                }
            }
            Divider()
            SettingsRow(L("远程机器"), detail: L("Codex 跑在远程时日志只在那边，用 SSH 读回来")) {
                HStack(spacing: 6) {
                    TextField(L("主机名"), text: $newHost)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                        .onSubmit(addHost)
                    let suggestions = sshConfigHosts.filter { !hosts.contains($0) }
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { h in Button(h) { newHost = h; addHost() } }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help(L("~/.ssh/config 里的主机"))
                    }
                    Button(L("添加"), action: addHost).disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    var hosts: [String] { _ = remoteHosts; return LogReader.hosts }

    func setHosts(_ list: [String]) {
        remoteHosts = list.joined(separator: ",")
        stats.reload()
    }

    func addHost() {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !h.contains(","), !hosts.contains(h) else { return }
        newHost = ""
        setHosts(hosts + [h])
    }

    /// ~/.ssh/config 里写了名字的主机（不含 * 这种通配）
    var sshConfigHosts: [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").flatMap { line -> [String] in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard words.first?.lowercased() == "host" else { return [] }
            return words.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
    }

    /// 一家一行：名字和读取的地方，右边是连接状态
    /// 右边只放一项（套餐），和远程机器的行一样；出错的原因、本地缓存这些写在左边小字里
    func provider(_ name: String, source: String) -> some View {
        let u = model.results.first { $0.name == name }
        let detail = u?.error ?? (u?.note != nil ? source + " · " + L("本地缓存") : source)
        return SettingsRow(name, detail: detail, warning: u?.error != nil) {
            HStack(spacing: 8) {
                Text(u == nil ? L("正在获取用量…") : u?.error != nil ? "—" : u?.plan ?? L("已连接"))
                    .foregroundStyle(.secondary)
                // 有远程机器时，给它们的「移除」按钮留出同样的位置，状态文字才对得齐
                if !hosts.isEmpty { Color.clear.frame(width: Self.removeWidth, height: 1) }
            }
        }
    }

    static let removeWidth: CGFloat = 18

    func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: d)
    }
}

/// 「菜单栏」：上面是设置，下面是铺满宽度的预览（菜单栏和点开后的菜单）
struct MenuBarSettings: View {
    @ObservedObject var model: UsageModel
    @AppStorage(Pref.menuLabel) var menuLabel = "short"
    @AppStorage(Pref.menuStyle) var menuStyle = "inline"
    @AppStorage(Pref.menuDisplayMode) var displayMode = "remaining"
    @AppStorage(Pref.menuShowClaude) var showClaude = true
    @AppStorage(Pref.menuShowCodex) var showCodex = true
    @AppStorage(Pref.menuLimit) var limit = "both"
    @AppStorage(Pref.menuResetStyle) var resetStyle = "full"
    @AppStorage(Pref.showCard) var showCard = true
    @AppStorage(Pref.showStatsCard) var showStatsCard = false

    var shown: [ProviderUsage] { model.results.filter { $0.name == "Claude" ? showClaude : showCodex } }
    var used: Bool { displayMode == "used" }

    /// 和菜单栏上一样的文字
    var title: String {
        let parts = shown.map { u -> String in
            let name = menuLabel == "full" ? u.name : u.name == "Claude" ? "Cc" : "Cx"
            return "\(name) " + (u.menuValue(limit, used: used) ?? "–")
        }
        return parts.isEmpty ? "UsageBar" : parts.joined(separator: "  ")
    }

    var body: some View {
        SettingsScroll(.menuBar, L("菜单栏上显示的文字，右边是点开后的菜单")) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 26) {
                    SettingsGroup(L("显示内容"), footer: L("只影响菜单栏，两张卡片在「卡片」里各自设置")) {
                        SettingsRow(L("显示数值")) {
                            Picker("", selection: $displayMode) {
                                Text(L("剩余")).tag("remaining")
                                Text(L("已使用")).tag("used")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingsRow("Claude") { SwitchControl(isOn: $showClaude) }
                        Divider()
                        SettingsRow("Codex") { SwitchControl(isOn: $showCodex) }
                    }
                    SettingsGroup(L("菜单栏文字")) {
                        SettingsRow(L("样式")) {
                            Picker("", selection: $menuStyle) {
                                Text(L("单行")).tag("inline")
                                Text(L("双行")).tag("stacked")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingsRow(L("名称")) {
                            Picker("", selection: $menuLabel) {
                                Text(L("简写（Cc / Cx）")).tag("short")
                                Text(L("全名")).tag("full")
                            }
                            .pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().fixedSize()
                        }
                        Divider()
                        SettingsRow(L("显示的额度")) {
                            Picker("", selection: $limit) {
                                Text(L("5 小时")).tag("session")
                                Text(L("本周")).tag("weekly")
                                Text(L("都显示")).tag("both")
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    SettingsGroup(L("下拉菜单")) {
                        // 窗口窄时四个选项和标题放不进一行，选项换到标题下面
                        ViewThatFits(in: .horizontal) {
                            SettingsRow(L("重置时间")) { resetPicker.fixedSize() }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("重置时间"))
                                resetPicker
                            }
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("预览")).font(.headline)
                    preview
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    var resetPicker: some View {
        Picker("", selection: $resetStyle) {
            Text(L("完整")).tag("full")
            Text(L("剩余时间")).tag("relative")
            Text(L("具体时间")).tag("absolute")
            Text(L("不显示")).tag("hidden")
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    /// 和菜单栏上一样：单行文字，或每家一块、名称在上数值在下
    @ViewBuilder var titleView: some View {
        if menuStyle == "stacked", !shown.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(shown, id: \.name) { u in
                    VStack(alignment: .center, spacing: -1.5) {
                        Text(menuLabel == "full" ? u.name : u.name == "Claude" ? "Cc" : "Cx")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text(u.menuValue(limit, used: used) ?? "–")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                }
            }
        } else {
            Text(title).font(.system(size: 13, weight: .medium).monospacedDigit()).lineLimit(1)
        }
    }

    /// 一段模拟的菜单栏，下面挂着点开后的菜单
    var preview: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                titleView
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(Date().formatted(.dateTime.hour().minute())).monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Rectangle().fill(Color.primary.opacity(0.05)))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown, id: \.name) { u in
                    MenuUsageBlock(u: u, used: used, resetStyle: resetStyle).padding(.horizontal, -2)
                    Divider().padding(.vertical, 3)
                }
                Text(L("更新于 %@", Date().formatted(.dateTime.hour().minute())))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
                ForEach([("arrow.clockwise", L("立即刷新")),
                         (showCard ? "eye.slash" : "eye", showCard ? L("隐藏额度卡片") : L("显示额度卡片")),
                         ("chart.bar", showStatsCard ? L("隐藏用量卡片") : L("显示用量卡片")),
                         ("macwindow", L("打开 UsageBar…")), ("power", L("退出"))], id: \.1) { icon, title in
                    if icon == "power" { Divider().padding(.vertical, 3) }
                    HStack(spacing: 8) {
                        Image(systemName: icon).frame(width: 18)  // 固定图标宽度，文字才对齐
                        Text(title)
                    }
                    .font(.system(size: 13)).padding(.vertical, 1).padding(.leading, 12)
                }
            }
            .padding(.vertical, 10)
            .frame(width: 310, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.trailing, 24)
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .modifier(Panel())
    }
}

/// 「卡片」：额度卡片和用量卡片，上面切换；左边是这张卡片的设置，右边预览
struct CardSettings: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var stats: StatsStore
    @AppStorage("cardSettingsTab") var which = "limits"

    var body: some View {
        let keys = which == "stats" ? CardKeys.stats : CardKeys.limits
        SettingsScroll(.card, L("额度卡片和用量卡片分开设置，改动会实时显示在右边的预览里")) {
            VStack(alignment: .leading, spacing: 18) {
                Picker("", selection: $which) {
                    Text(L("额度卡片")).tag("limits")
                    Text(L("用量卡片")).tag("stats")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                HStack(alignment: .top, spacing: 24) {
                    // 换一张卡片时重建，@AppStorage 才会换成那张卡片的键
                    CardForm(keys: keys).id(which)
                        .frame(maxWidth: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("预览")).font(.headline)
                        CardPreview(keys: keys, model: model, stats: stats).id(which)
                            .frame(height: 440)
                        Text(L("拖动桌面上的卡片可以移动位置，右键有更多操作"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }
}

/// 一张卡片的各项设置存在哪些键下
struct CardKeys {
    let stats: Bool  // 用量卡片；否则是额度卡片
    let show, onTop, claude, codex, layout, scale, background, text, opacity, bgOpacity: String
    static let limits = CardKeys(stats: false, show: Pref.showCard, onTop: Pref.cardOnTop, claude: Pref.cardShowClaude, codex: Pref.cardShowCodex,
                                 layout: Pref.cardLayout, scale: Pref.scale, background: Pref.background, text: Pref.textColor,
                                 opacity: Pref.opacity, bgOpacity: Pref.bgOpacity)
    static let stats = CardKeys(stats: true, show: Pref.showStatsCard, onTop: Pref.statsCardOnTop, claude: Pref.statsCardShowClaude, codex: Pref.statsCardShowCodex,
                                layout: Pref.statsCardLayout, scale: Pref.statsCardScale, background: Pref.statsCardBackground,
                                text: Pref.statsCardText, opacity: Pref.statsCardOpacity, bgOpacity: Pref.statsCardBgOpacity)
}

struct CardForm: View {
    let keys: CardKeys
    @AppStorage var show: Bool
    @AppStorage var onTop: Bool
    @AppStorage var showClaude: Bool
    @AppStorage var showCodex: Bool
    @AppStorage var layout: String
    @AppStorage var scale: Double
    @AppStorage var background: String
    @AppStorage var textColor: String
    @AppStorage var opacity: Double
    @AppStorage var bgOpacity: Double
    @AppStorage(Pref.resetStyle) var resetStyle = "relative"
    @AppStorage(Pref.cardDisplayMode) var displayMode = "remaining"
    @AppStorage(Pref.statsCardRange) var statsRange = "today"

    init(keys: CardKeys) {
        self.keys = keys
        _show = AppStorage(wrappedValue: !keys.stats, keys.show)
        _onTop = AppStorage(wrappedValue: false, keys.onTop)
        _showClaude = AppStorage(wrappedValue: true, keys.claude)
        _showCodex = AppStorage(wrappedValue: true, keys.codex)
        _layout = AppStorage(wrappedValue: "horizontal", keys.layout)
        _scale = AppStorage(wrappedValue: 1.0, keys.scale)
        _background = AppStorage(wrappedValue: "none", keys.background)
        _textColor = AppStorage(wrappedValue: "white", keys.text)
        _opacity = AppStorage(wrappedValue: 1.0, keys.opacity)
        _bgOpacity = AppStorage(wrappedValue: 1.0, keys.bgOpacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(footer: keys.stats ? L("用量卡片显示各家的估算成本、请求数、Tokens 和缓存命中率")
                                             : L("额度卡片显示各家额度的剩余（或已用）和重置时间")) {
                SettingsRow(keys.stats ? L("显示用量卡片") : L("显示额度卡片")) { SwitchControl(isOn: $show) }
                Divider()
                SettingsRow(L("保持在最前"), detail: L("关掉时贴在桌面上，会被其他窗口盖住")) { SwitchControl(isOn: $onTop) }
                    .disabled(!show)
                Divider()
                if keys.stats {
                    SettingsRow(L("统计范围")) {
                        Picker("", selection: $statsRange) {
                            Text(L("今天")).tag("today")
                            Text(L("重置以来")).tag("cycle")
                            Text(L("近 7 天")).tag("7d")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .disabled(!show)
                } else {
                    SettingsRow(L("显示数值")) {
                        Picker("", selection: $displayMode) {
                            Text(L("剩余")).tag("remaining")
                            Text(L("已使用")).tag("used")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .disabled(!show)
                    Divider()
                    SettingsRow(L("重置时间")) {
                        Picker("", selection: $resetStyle) {
                            Text(L("不显示")).tag("hidden")
                            Text(L("剩余时间")).tag("relative")
                            Text(L("具体时间")).tag("absolute")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    .disabled(!show)
                }
                Divider()
                SettingsRow("Claude") { SwitchControl(isOn: $showClaude) }.disabled(!show)
                Divider()
                SettingsRow("Codex") { SwitchControl(isOn: $showCodex) }.disabled(!show)
            }
            SettingsGroup(L("布局")) {
                SettingsRow(L("布局")) {
                    Picker("", selection: $layout) {
                        Label(L("左右"), systemImage: "rectangle.split.2x1").tag("horizontal")
                        Label(L("上下"), systemImage: "rectangle.split.1x2").tag("vertical")
                        Label(L("紧凑"), systemImage: "list.bullet").tag("compact")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(L("大小")) { PercentControl(value: $scale, range: 0.8...2.5, step: 0.1) }
            }
            .disabled(!show)
            SettingsGroup(L("外观")) {
                SettingsRow(L("背景")) {
                    Picker("", selection: $background) {
                        Text(L("无")).tag("none")
                        Text(L("深色毛玻璃")).tag("dark")
                        Text(L("浅色毛玻璃")).tag("light")
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(L("毛玻璃浓度")) { PercentControl(value: $bgOpacity, range: 0.1...1.0, step: 0.05) }
                    .disabled(background == "none")
                Divider()
                SettingsRow(L("文字颜色")) {
                    Picker("", selection: $textColor) {
                        Text(L("白色")).tag("white")
                        Text(L("黑色")).tag("black")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                SettingsRow(L("整体不透明度")) { PercentControl(value: $opacity, range: 0.3...1.0, step: 0.05) }
            }
            .disabled(!show)
        }
    }
}

/// 卡片预览：底色模拟壁纸，卡片按预览框缩放
struct CardPreview: View {
    let keys: CardKeys
    @ObservedObject var model: UsageModel
    @ObservedObject var stats: StatsStore
    @AppStorage var show: Bool
    @AppStorage var layout: String
    @AppStorage var scale: Double
    @AppStorage var textColor: String

    init(keys: CardKeys, model: UsageModel, stats: StatsStore) {
        self.keys = keys
        self.model = model
        self.stats = stats
        _show = AppStorage(wrappedValue: !keys.stats, keys.show)
        _layout = AppStorage(wrappedValue: "horizontal", keys.layout)
        _scale = AppStorage(wrappedValue: 1.0, keys.scale)
        _textColor = AppStorage(wrappedValue: "white", keys.text)
    }

    /// 卡片实际尺寸：卡片显示着就用桌面上那张的窗口尺寸，否则按布局估算
    var cardSize: CGSize {
        let live = keys.stats ? model.statsCardSize : model.cardSize
        if show, live.width > 0 { return live }
        let base: CGSize
        switch (keys.stats, layout) {
        case (false, "vertical"): base = CGSize(width: 292, height: 295)
        case (false, "compact"): base = CGSize(width: 273, height: 93)
        case (false, _): base = CGSize(width: 476, height: 167)
        case (true, "vertical"): base = CGSize(width: 292, height: 330)
        case (true, "compact"): base = CGSize(width: 330, height: 93)
        default: base = CGSize(width: 476, height: 180)
        }
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    var body: some View {
        GeometryReader { g in
            // 白字配深色底，黑字配浅色底
            let dark = textColor == "white"
            // 按 100% 的样子缩进预览框：调「大小」时预览不跟着变，只有桌面上的卡片变
            let base = CGSize(width: cardSize.width / scale, height: cardSize.height / scale)
            let fitBase = min(1, (g.size.width - 48) / base.width, (g.size.height - 48) / base.height)
            let fit = fitBase / scale
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: dark ? [Color(white: 0.32), Color(white: 0.14)] : [Color(white: 0.92), Color(white: 0.78)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Group {
                    if keys.stats { StatsCardView(stats: stats, model: model, report: false) } else { CardView(model: model, report: false) }
                }
                .allowsHitTesting(false)
                .scaleEffect(fit)
                // scaleEffect 只缩画面不缩占位，占位也按缩放后的尺寸来，免得撑出预览框
                .frame(width: base.width * fitBase, height: base.height * fitBase)
            }
            .opacity(show ? 1 : 0.4)
        }
    }
}

/// 「关于」：一整列——版本和更新、数据说明、链接
struct AboutSettings: View {
    let updater: Updater

    var body: some View {
        SettingsScroll(.about, L("版本、更新和数据说明")) {
                VStack(alignment: .leading, spacing: 24) {
                    AboutCard(updater: updater)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("数据说明")).font(.headline)
                        VStack(spacing: 0) {
                            infoRow("gauge.with.dots.needle.50percent", L("额度"),
                                    L("用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询"))
                            Divider().padding(.leading, 54)
                            infoRow("chart.bar.xaxis", L("用量统计"),
                                    L("读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），以及「通用」里添加的远程机器上的 Codex 日志（用 ssh 读取，在远程先过滤）；成本按 models.dev 的 API 价格估算，价格每天更新一次"))
                            Divider().padding(.leading, 54)
                            infoRow("lock.shield", L("隐私"), L("所有数据只在这台 Mac、你添加的远程机器和上述官方服务之间传输，不经过其他服务器"))
                        }
                        .modifier(Panel())
                    }
                    HStack(spacing: 22) {
                        link("chevron.left.forwardslash.chevron.right", "GitHub", "")
                        link("shippingbox", L("所有版本"), "/releases")
                        link("exclamationmark.bubble", L("反馈问题"), "/issues")
                    }
                    .font(.callout)
                }
        }
    }

    /// 数据说明的一行：图标、标题、说明
    func infoRow(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    func link(_ symbol: String, _ title: String, _ path: String) -> some View {
        Link(destination: URL(string: "https://github.com/\(Updater.repo)\(path)")!) {
            Label(title, systemImage: symbol)
        }
    }
}

/// 「关于」页顶部：图标、名称、版本，右边是检查更新；有新版或出错时下面展开说明
struct AboutCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                // 直接读包里的图标：NSApp.applicationIconImage 在这里拿到的是系统占位图
                Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("UsageBar").font(.title2.weight(.semibold))
                    Text(L("版本 %@", updater.currentVersion)).foregroundStyle(.secondary)
                    Text(L("在菜单栏和桌面显示 Claude 与 Codex 的剩余用量")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                updateControl
            }
            switch updater.state {
            case .available:
                if let notes = updater.release?.notes {
                    Divider()
                    Text(Self.summary(notes)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                    if let page = updater.release?.page { Link(L("查看详情"), destination: page).font(.callout) }
                }
            case .failed(let msg):
                Divider()
                HStack {
                    Text(L("更新失败：%@", msg)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Link(L("前往下载页"), destination: Updater.releasesPage).font(.callout)
                }
            default:
                EmptyView()
            }
        }
        .padding(20)
        .modifier(Panel())
    }

    /// 右边：检查更新 / 正在检查 / 有新版 / 下载中
    @ViewBuilder var updateControl: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在检查…")).foregroundStyle(.secondary) }
        case .downloading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在下载并安装…")).foregroundStyle(.secondary) }
        case .available(let v):
            VStack(alignment: .trailing, spacing: 6) {
                Text(L("发现新版本 %@", v)).font(.callout.weight(.semibold))
                Button(L("更新并重启")) { updater.install() }.buttonStyle(.borderedProminent)
            }
        case .failed:
            Button(L("重试")) { updater.check() }
        case .upToDate:
            VStack(alignment: .trailing, spacing: 6) {
                Label(L("已是最新版本"), systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                Button(L("检查更新")) { updater.check() }.controlSize(.small)
            }
        case .idle:
            Button(L("检查更新")) { updater.check() }
        }
    }

    /// 更新说明只取正文几行：去掉链接行、校验值和 Markdown 符号
    static func summary(_ notes: String) -> String {
        // 只要「安装」之前的部分（新功能 / 修复）
        let body = notes.components(separatedBy: "### Install").first ?? notes
        return body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("SHA-256") && !$0.hasPrefix("macOS 13") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "### ", with: "") }
            .joined(separator: "\n")
    }
}

// MARK: - 主窗口：左侧边栏切换「用量统计」和各项设置

/// 去掉 NavigationSplitView 自带的侧边栏开关按钮（macOS 14 起才有这个 API）
struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case stats, general, menuBar, card, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return L("用量统计")
        case .general: return L("通用")
        case .menuBar: return L("菜单栏")
        case .card: return L("卡片")
        case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .stats: return "chart.bar.xaxis"
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .card: return "rectangle.on.rectangle"
        case .about: return "info.circle"
        }
    }
}

final class MainNav: ObservableObject {
    /// 记住上次看的页，下次「打开 UsageBar」回到这里
    @Published var tab: MainTab = MainTab(rawValue: UserDefaults.standard.string(forKey: "mainTab") ?? "") ?? .stats {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "mainTab") }
    }
}

struct MainView: View {
    @ObservedObject var nav: MainNav
    @ObservedObject var stats: StatsStore
    let model: UsageModel
    let updater: Updater
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage("statsChartColor") var themeColor = "pink"

    var body: some View {
        let _ = language  // 切换语言时重绘
        NavigationSplitView {
            // 侧边栏自己画：系统列表的选中高亮只认系统强调色，不跟主题色
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.stats)
                    Text(L("设置")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
                    ForEach([MainTab.general, .menuBar, .card, .about]) { row($0) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .modifier(HideSidebarToggle())
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch nav.tab {
                case .stats: StatsView(store: stats)
                case .general: GeneralSettings(updater: updater, model: model, stats: stats)
                case .menuBar: MenuBarSettings(model: model)
                case .card: CardSettings(model: model, stats: stats)
                case .about: AboutSettings(updater: updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .top)  // 内容顶到窗口最上面，不再空出标题栏那一条
        }
        // 主题色：主窗口里的开关、分段按钮、选中标记都用它（桌面卡片和菜单栏保持单色）
        // NavigationSplitView 会自带一条显示窗口标题的工具栏，整条隐藏，只留左上角三个按钮
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 1120, minHeight: 700)  // 最小尺寸：所有页面在这个尺寸下都能完整显示
        // 选「跟随系统」时不覆盖，控件用系统的主题颜色
        .tint(themeColor == "system" ? nil : ChartColor.color(themeColor))
        .accentColor(themeColor == "system" ? nil : ChartColor.color(themeColor))
    }

    var theme: Color { themeColor == "system" ? Color(nsColor: .controlAccentColor) : ChartColor.color(themeColor) }

    /// 侧边栏一行：图标用主题色，选中时整行填主题色、文字变白
    func row(_ t: MainTab) -> some View {
        let selected = nav.tab == t
        return Button { nav.tab = t } label: {
            HStack(spacing: 8) {
                Image(systemName: t.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : theme)
                Text(t.title).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? theme : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 桌面卡片

final class UsageModel: ObservableObject {
    @Published var results: [ProviderUsage] = []
    @Published var lastUpdate: Date?
    var onRefresh: () -> Void = {}
    var onHide: () -> Void = {}
    /// 桌面卡片窗口的当前尺寸（设置页预览按它缩放）
    @Published var cardSize = CGSize.zero
    @Published var statsCardSize = CGSize.zero
    /// 两张卡片中间内容的大小（按 100% 算）和「形状」（布局|大小|几家；不参与对齐时为空）
    @Published var cardContent: [String: CardContent] = [:]
    struct CardContent: Equatable { var size: CGSize; var shape: String }

    /// 两张卡片布局、大小、显示几家都一样时，内容区对齐到较宽、较高的那张，两张就一样大了
    func syncedSize(_ kind: String) -> CGSize? {
        guard let a = cardContent[kind], let b = cardContent[kind == "limits" ? "stats" : "limits"],
              !a.shape.isEmpty, a.shape == b.shape else { return nil }
        return CGSize(width: max(a.size.width, b.size.width), height: max(a.size.height, b.size.height))
    }

    func reportCard(_ kind: String, _ c: CardContent) {
        // 放到下一轮：在视图更新途中改发布的值会有警告
        DispatchQueue.main.async { if self.cardContent[kind] != c { self.cardContent[kind] = c } }
    }
    var onOpen: () -> Void = {}
    var onCardSettings: () -> Void = {}
    // 用量卡片的右键菜单
    var onRefreshStats: () -> Void = {}
    var onOpenStats: () -> Void = {}
    var onHideStats: () -> Void = {}
}

/// 卡片中间内容：量出自然大小报给 model，再按两张卡片对齐后的大小撑开（多出来的空在右边和下面）
struct CardHeightSync: ViewModifier {
    let kind: String     // limits / stats
    let shape: String    // 空：这张卡片不参与对齐（隐藏、还没数据）
    let scale: CGFloat
    @ObservedObject var model: UsageModel
    let report: Bool     // 设置页的预览只读不报

    /// 量到的自然大小。先存下来，在外层和 shape 一起盯着变化——
    /// 放在 GeometryReader 里的 onChange 拿到的 shape 可能还是旧的
    @State var measured = CGSize.zero

    func body(content: Content) -> some View {
        let synced = model.syncedSize(kind)
        return content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { measured = g.size }
                    .onChange(of: g.size) { measured = $0 }
            })
            .frame(minWidth: synced.map { $0.width * scale }, minHeight: synced.map { $0.height * scale }, alignment: .topLeading)
            .onAppear { send() }
            .onChange(of: "\(measured)|\(shape)") { _ in send() }
    }

    func send() {
        if report {
            model.reportCard(kind, .init(size: CGSize(width: measured.width / scale, height: measured.height / scale), shape: shape))
        }
    }
}

/// 毛玻璃背景（透出壁纸）
struct Blur: NSViewRepresentable {
    let dark: Bool
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

struct UsageRow: View {
    let w: LimitWindow
    let s: CGFloat
    let showReset: Bool
    let used: Bool  // 显式传进来：SwiftUI 只在输入变化时重绘这一行
    var resetStyle = "full"  // 菜单用完整的；桌面卡片按设置用 relative / absolute
    /// 不显示重置时间时仍占着那一行的位置（桌面卡片用：布局不动，只是字不见了）
    var keepResetSpace = false
    /// 重置时间后面加上「预计几点用完」（菜单里有地方写；卡片太窄不写）
    var showRunOut = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack(spacing: 3 * s) {
                Text(w.label).font(.system(size: 12 * s))
                Spacer()
                Text(w.shownText(used))
                    .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
                if w.fast {
                    Image(systemName: "arrow.up").font(.system(size: 9 * s, weight: .bold))
                        .help(L("用得比时间快：已用的比例超过了这个周期已经过去的比例"))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.25))
                    Capsule().fill(Color.primary.opacity(0.9)).frame(width: g.size.width * w.shown(used) / 100)
                }
            }
            .frame(height: 4 * s)
            if showReset, w.resetsAt != nil {
                Text(resetText(w.resetsAt, style: resetStyle) + (showRunOut ? w.runsOutAt.map { " · " + L("预计 %@ 用完", shortTime($0)) } ?? "" : ""))
                    .font(.system(size: 10 * s)).foregroundStyle(.secondary)
            } else if keepResetSpace {
                Text(" ").font(.system(size: 10 * s)).hidden()
            }
        }
    }
}

struct CardView: View {
    @ObservedObject var model: UsageModel
    @AppStorage(Pref.background) var background = "none"
    @AppStorage(Pref.textColor) var textColor = "white"
    @AppStorage(Pref.scale) var scale = 1.0
    @AppStorage(Pref.opacity) var opacity = 1.0
    @AppStorage(Pref.bgOpacity) var bgOpacity = 1.0
    @AppStorage(Pref.resetStyle) var resetStyle = "relative"
    @AppStorage(Pref.cardShowClaude) var showClaude = true
    @AppStorage(Pref.cardShowCodex) var showCodex = true
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage(Pref.cardDisplayMode) var displayMode = "remaining"
    @AppStorage(Pref.cardLayout) var layout = "horizontal"
    @AppStorage(Pref.showCard) var visible = true
    @AppStorage(Pref.cardOnTop) var onTop = false
    var report = true  // 设置页的预览传 false

    var s: CGFloat { CGFloat(scale) }
    var used: Bool { displayMode == "used" }

    var body: some View {
        let _ = (language, displayMode)  // 切换语言或显示方式时重绘
        let white = textColor == "white"
        let shown = model.results.filter { $0.name == "Claude" ? showClaude : showCodex }
        VStack(alignment: .leading, spacing: (layout == "compact" ? 10 : 14) * s) {
            if model.results.isEmpty {
                Text(L("正在获取用量…")).font(.system(size: 12 * s)).foregroundStyle(.secondary)
            }
            Group {
                switch layout {
                case "vertical":
                    VStack(alignment: .leading, spacing: 20 * s) { ForEach(shown, id: \.name, content: column) }
                case "compact":
                    // 网格：各行的同一列上下对齐
                    Grid(alignment: .leading, horizontalSpacing: 14 * s, verticalSpacing: 6 * s) {
                        ForEach(shown, id: \.name, content: compactRow)
                    }
                default:
                    HStack(alignment: .top, spacing: 24 * s) { ForEach(shown, id: \.name, content: column) }
                }
            }
            .modifier(CardHeightSync(kind: "limits",
                                     shape: visible && !shown.isEmpty ? "\(layout)|\(scale)|\(shown.count)" : "",
                                     scale: s, model: model, report: report))
            if let t = model.lastUpdate {
                Text(L("更新于 %@", t.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 10 * s)).foregroundStyle(.tertiary)
            }
        }
        .padding(16 * s)
        .fixedSize()
        .environment(\.colorScheme, white ? .dark : .light)
        // 没有背景时直接显示在壁纸上，加一层淡阴影保证看得清
        .shadow(color: background == "none" ? (white ? Color.black : Color.white).opacity(0.6) : Color.clear, radius: 2, y: 1)
        .background {
            if background != "none" {
                Blur(dark: background == "dark")
                    .clipShape(RoundedRectangle(cornerRadius: 20 * s, style: .continuous))
                    .opacity(bgOpacity)
            }
        }
        .opacity(opacity)
        .contextMenu {
            Button { model.onRefresh() } label: { Label(L("立即刷新"), systemImage: "arrow.clockwise") }
            Button { model.onOpen() } label: { Label(L("打开 UsageBar…"), systemImage: "macwindow") }
            Button { model.onCardSettings() } label: { Label(L("卡片设置…"), systemImage: "slider.horizontal.3") }
            Divider()
            Toggle(L("保持在最前"), isOn: $onTop)
            Button { model.onHide() } label: { Label(L("隐藏额度卡片"), systemImage: "eye.slash") }
        }
    }
}

extension CardView {
    /// 一家一栏：名称、各额度的进度条和重置时间
    func column(_ u: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(u.name).font(.system(size: 13 * s, weight: .semibold))
                if let p = u.plan { Text(p).font(.system(size: 10 * s)).foregroundStyle(.secondary) }
            }
            if let e = u.error {
                Text(e).font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                UsageRow(w: w, s: s, showReset: resetStyle != "hidden", used: used, resetStyle: resetStyle, keepResetSpace: true)
            }
            if let rc = u.resetCredits {
                Label(rc.text, systemImage: "arrow.counterclockwise.circle").font(.system(size: 10 * s)).foregroundStyle(.secondary)
            }
            if let n = u.note {
                Text(n).font(.system(size: 10 * s)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 上下布局时一栏占满整行，放宽一些更好看
        .frame(width: (layout == "vertical" ? CardWindow.wideColumn : CardWindow.column) * s, alignment: .topLeading)
    }

    /// 紧凑：一家一行，只有数字
    func compactRow(_ u: ProviderUsage) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(u.name).font(.system(size: 13 * s, weight: .semibold))
            if let e = u.error, u.windows.isEmpty {
                Text(e).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 260 * s, alignment: .leading)
                    .gridCellColumns(2)
            }
            ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
                    Text(w.label).font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    Text(w.shownText(used)).font(.system(size: 12 * s, weight: .medium).monospacedDigit())
                }
            }
            if let rc = u.resetCredits {
                Text(rc.countText).font(.system(size: 11 * s)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 菜单里每家的用量区块：名称、套餐，各额度一行加圆角进度条
struct MenuUsageBlock: View {
    let u: ProviderUsage
    let used: Bool
    var resetStyle = "full"
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(u.name).font(.system(size: 13, weight: .semibold))
                if let p = u.plan { Text(p).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if let e = u.error {
                Text(e).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                UsageRow(w: w, s: 1.08, showReset: resetStyle != "hidden", used: used, resetStyle: resetStyle, showRunOut: true)
            }
            if let rc = u.resetCredits {
                VStack(alignment: .leading, spacing: 2) {
                    Label(rc.text, systemImage: "arrow.counterclockwise.circle")
                    // 多次时逐条列出，图标宽度留空对齐
                    ForEach(rc.lines, id: \.self) { Text($0).padding(.leading, 20) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let n = u.note {
                Text(n).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: 290, alignment: .leading)
    }
}

extension NSScreen {
    /// 显示器的唯一 ID（重启、换接口都不变），按它分别记卡片位置
    var uuid: String? {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, id) as String
    }
}

/// 贴在桌面层的卡片窗口：在所有桌面空间显示，可拖动。额度卡片和用量卡片都用它
///
/// 位置按显示器分别记：每块屏记卡片左上角相对这块屏左上角的偏移，另记最后放在哪块屏。
/// 启动时、显示器插拔或改排列时重新摆：那块屏还在就放回去；不在就放到主屏（不动那块屏的记录，接回来时自动回去）。
/// 无论怎么摆都限制在屏幕可见范围内——无边框窗口系统不会帮忙挪，跑到屏幕外就再也找不回来
final class CardWindow: NSWindow {
    /// 尺寸变了（额度卡片拿来给设置页预览）
    var onResize: (CGSize) -> Void = { _ in }
    /// 偏好里记位置的键：「每块屏的偏移」和「最后在哪块屏」
    let placementKey: String
    var lastScreenKey: String { placementKey + ".screen" }
    /// 卡片摆在哪块屏（摆放或用户拖动时定下来）。卡片变大后按它挪回屏内——
    /// 不能现算重叠最多的那块：卡片往下长出屏幕后，重叠最多的可能变成旁边的屏
    weak var home: NSScreen?

    /// 「保持在最前」存在哪个键
    let onTopKey: String

    /// name：记住位置用的名字；onTopKey：「保持在最前」的偏好键；near：第一次显示时挨着这个窗口放（用量卡片挨着额度卡片）
    init<V: View>(_ view: V, name: String, onTopKey: String, near: NSWindow? = nil) {
        placementKey = "cardPlacement." + name
        self.onTopKey = onTopKey
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        contentViewController = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false  // 透明区域也能拖动（拖动自己处理，见 sendEvent）
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        applyLevel()
        // 先按内容定好大小再摆位置，不然窗口之后从 0 长高时会往上长
        setContentSize(host.view.fittingSize)
        if !place() {
            // 第一次：旧版存的位置（「x y 宽 高 屏幕…」，全局坐标）直接拿来用。
            // 不用 setFrameUsingName：屏幕可用区域差 1pt 它就当成别的屏，按比例把卡片挪到主屏上
            let old = UserDefaults.standard.string(forKey: "NSWindow Frame " + name)?
                .split(separator: " ").compactMap { Double($0) } ?? []
            if old.count >= 4 {
                setFrameTopLeftPoint(NSPoint(x: old[0], y: old[1] + old[3]))
                UserDefaults.standard.removeObject(forKey: "NSWindow Frame " + name)
            } else if let near, let s = near.screen?.visibleFrame {
                // 放在它下面；下面放不下就放右边
                let h = frame.height
                setFrameTopLeftPoint(near.frame.minY - 12 - h > s.minY
                    ? NSPoint(x: near.frame.minX, y: near.frame.minY - 12)
                    : NSPoint(x: near.frame.maxX + 12, y: near.frame.maxY))
            } else if let s = NSScreen.main?.visibleFrame {
                setFrameTopLeftPoint(NSPoint(x: s.maxX - CardWindow.defaultWidth - 24, y: s.maxY - 16))
            }
            clampToScreen()
            savePlacement()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: self)
        CardWindow.all.add(self)
    }
    /// 每家一栏的宽度；两栏并排时卡片约 500 宽
    static let column: CGFloat = 210
    static let wideColumn: CGFloat = 260
    static let defaultWidth: CGFloat = column * 2 + 24 + 32
    override var canBecomeKey: Bool { false }

    // MARK: 拖动：自己处理，靠近屏幕边缘、屏幕中线、另一张卡片的边时吸过去，并画出对齐线

    /// 所有卡片（拖一张时和另一张对齐）
    static let all = NSHashTable<CardWindow>.weakObjects()
    static let guides = GuideWindow()
    /// 离对齐位置多近就吸过去（这段距离内拖不动，像碰到了边）
    static let snapDistance: CGFloat = 10
    /// 离屏幕边缘留的空、两张卡片挨着时的间隔
    static let margin: CGFloat = 16
    static let gap: CGFloat = 12

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var snappedX: CGFloat?, snappedY: CGFloat?

    override func sendEvent(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            dragStart = (NSEvent.mouseLocation, frame.origin)
        case .leftMouseDragged:
            if let d = dragStart {
                let m = NSEvent.mouseLocation
                drag(to: NSPoint(x: d.origin.x + m.x - d.mouse.x, y: d.origin.y + m.y - d.mouse.y))
                return
            }
        case .leftMouseUp:
            if dragStart != nil {
                dragStart = nil
                snappedX = nil; snappedY = nil
                Self.guides.orderOut(nil)
            }
        default:
            break
        }
        super.sendEvent(e)
    }

    /// 一个可以吸附的位置：窗口左下角该放的坐标，和要画的对齐线在哪
    typealias Snap = (origin: CGFloat, line: CGFloat)

    func drag(to raw: NSPoint) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? self.screen ?? NSScreen.main
        var xs: [Snap] = [], ys: [Snap] = []
        if let v = screen?.visibleFrame {
            let m = Self.margin
            xs += [(v.minX, v.minX), (v.minX + m, v.minX + m), (v.maxX - size.width, v.maxX),
                   (v.maxX - m - size.width, v.maxX - m), (v.midX - size.width / 2, v.midX)]
            ys += [(v.minY, v.minY), (v.minY + m, v.minY + m), (v.maxY - size.height, v.maxY),
                   (v.maxY - m - size.height, v.maxY - m), (v.midY - size.height / 2, v.midY)]
        }
        for other in Self.all.allObjects where other !== self && other.isVisible {
            let f = other.frame, g = Self.gap
            // 左边、右边、中线对齐；或者隔一点并排（线画在两张中间）
            xs += [(f.minX, f.minX), (f.maxX - size.width, f.maxX), (f.midX - size.width / 2, f.midX),
                   (f.maxX + g, f.maxX + g / 2), (f.minX - g - size.width, f.minX - g / 2)]
            // 顶边、底边对齐；或者隔一点上下叠放
            ys += [(f.minY, f.minY), (f.maxY - size.height, f.maxY),
                   (f.maxY + g, f.maxY + g / 2), (f.minY - g - size.height, f.minY - g / 2)]
        }
        func nearest(_ c: [Snap], _ v: CGFloat) -> Snap? {
            c.filter { abs($0.origin - v) <= Self.snapDistance }.min { abs($0.origin - v) < abs($1.origin - v) }
        }
        let sx = nearest(xs, raw.x), sy = nearest(ys, raw.y)
        // 刚吸上的那一下给个触感（力度触控板才有）
        if (sx != nil && sx?.line != snappedX) || (sy != nil && sy?.line != snappedY) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        snappedX = sx?.line; snappedY = sy?.line
        setFrameOrigin(NSPoint(x: sx?.origin ?? raw.x, y: sy?.origin ?? raw.y))
        Self.guides.show(x: snappedX, y: snappedY, on: screen, above: level)
    }

    /// 保持在最前：浮在所有窗口上面；否则贴在桌面层（桌面图标上面一层，其他窗口会盖住它）
    func applyLevel() {
        let onTop = UserDefaults.standard.bool(forKey: onTopKey)
        let want: NSWindow.Level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if level != want { level = want }
    }

    /// 只记用户拖动（按着鼠标）的结果；系统因为显示器变化挪窗口、程序自己摆放都不算
    @objc func moved() {
        if NSEvent.pressedMouseButtons & 1 != 0 { savePlacement() }
    }

    /// 卡片在哪块屏：重叠面积最大的那块（还没显示时 NSWindow.screen 不可靠）
    var bestScreen: NSScreen? {
        NSScreen.screens.max { a, b in
            let x = a.frame.intersection(frame), y = b.frame.intersection(frame)
            return x.width * x.height < y.width * y.height
        }
    }

    func savePlacement() {
        guard let screen = bestScreen ?? NSScreen.main, let id = screen.uuid else { return }
        home = screen
        let d = UserDefaults.standard
        var map = d.dictionary(forKey: placementKey) as? [String: [Double]] ?? [:]
        map[id] = [frame.minX - screen.frame.minX, screen.frame.maxY - frame.maxY]
        d.set(map, forKey: placementKey)
        d.set(id, forKey: lastScreenKey)
    }

    /// 摆到该在的地方；还没记过位置就返回 false
    @discardableResult
    func place() -> Bool {
        let d = UserDefaults.standard
        guard let map = d.dictionary(forKey: placementKey) as? [String: [Double]], !map.isEmpty else { return false }
        let last = d.string(forKey: lastScreenKey) ?? ""
        let screens = NSScreen.screens
        // 上次那块屏还在就用它；不在就用主屏（主屏自己有记录就用主屏的，否则沿用上次的相对位置）
        guard let target = screens.first(where: { $0.uuid == last }) ?? NSScreen.main ?? screens.first,
              let offset = map[target.uuid ?? ""] ?? map[last] ?? map.values.first, offset.count == 2 else { return false }
        let f = target.frame
        home = target
        setFrameOrigin(NSPoint(x: f.minX + offset[0], y: f.maxY - offset[1] - frame.height))
        clampToScreen()
        return true
    }

    /// 整张卡片挪进屏幕可见范围（不算菜单栏和程序坞）
    func clampToScreen(_ target: NSScreen? = nil) {
        guard let s = (target ?? home ?? bestScreen ?? NSScreen.main)?.visibleFrame else { return }
        var o = frame.origin
        o.x = min(max(o.x, s.minX), max(s.minX, s.maxX - frame.width))
        o.y = min(max(o.y, s.minY), max(s.minY, s.maxY - frame.height))
        if o != frame.origin { setFrameOrigin(o) }
    }

    /// 内容变高/变矮时保持左上角不动（AppKit 默认保持左下角）
    override func setFrame(_ r: NSRect, display: Bool) {
        var r = r
        let resized = frame.height > 0 && r.size != frame.size
        if frame.height > 0, r.origin == frame.origin, r.height != frame.height {
            r.origin.y = frame.maxY - r.height
        }
        super.setFrame(r, display: display)
        // 尺寸变了就告诉设置页预览；变大后可能超出屏幕，挪回来。放到下一轮，免得在布局途中改
        let size = frame.size
        DispatchQueue.main.async { [weak self] in
            self?.onResize(size)
            if resized { self?.clampToScreen() }
        }
    }
}

/// 拖卡片时的对齐线：一层铺满屏幕、透明、不接鼠标的窗口，盖在卡片上面一层
final class GuideWindow: NSWindow {
    let lines = GuideView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = lines
    }

    /// x、y 是屏幕坐标里的竖线和横线；都没有就收起来
    func show(x: CGFloat?, y: CGFloat?, on screen: NSScreen?, above cardLevel: NSWindow.Level) {
        guard let screen, x != nil || y != nil else { orderOut(nil); return }
        if frame != screen.frame { setFrame(screen.frame, display: false) }
        level = NSWindow.Level(rawValue: cardLevel.rawValue + 1)
        lines.x = x.map { $0 - screen.frame.minX }
        lines.y = y.map { $0 - screen.frame.minY }
        lines.needsDisplay = true
        orderFrontRegardless()
    }
}

final class GuideView: NSView {
    var x: CGFloat?, y: CGFloat?
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        if let x { NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill() }
        if let y { NSRect(x: 0, y: y - 0.5, width: bounds.width, height: 1).fill() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = UsageModel()
    var card: CardWindow?
    var statsCard: CardWindow?
    var results: [ProviderUsage] = []
    var lastUpdate: Date?
    var loading = false
    var timer: Timer?
    var timerMinutes = 0
    var statsTimer: Timer?
    var statsTimerMinutes = 0
    var mainWindow: NSWindow?
    let nav = MainNav()
    let updater = Updater()
    var updateTimer: Timer?
    var updaterWatch: Any?
    let stats = StatsStore()
    var lastLang = ""
    var showCard: Bool {
        get { UserDefaults.standard.bool(forKey: Pref.showCard) }
        set { UserDefaults.standard.set(newValue, forKey: Pref.showCard) }
    }
    var showStatsCard: Bool {
        get { UserDefaults.standard.bool(forKey: Pref.showStatsCard) }
        set { UserDefaults.standard.set(newValue, forKey: Pref.showStatsCard) }
    }

    /// 显示器插拔、改分辨率或排列：两张卡片重新摆
    @objc func screensChanged() {
        card?.place()
        statsCard?.place()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Pref.register()
        Pref.applyAppearance()
        // install.sh 从旧版（LaunchAgent 自启）升级时会带上这个参数
        if CommandLine.arguments.contains("--enable-login-item") { LoginItem.set(true) }
        lastLang = I18n.lang
        item.button?.title = "Cc …  Cx …"
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        if Notifier.anyEnabled { Task { await Notifier.requestPermission() } }
        model.onRefresh = { [weak self] in self?.refresh() }
        model.onHide = { [weak self] in self?.toggleCard() }
        model.onOpen = { [weak self] in self?.openApp() }
        model.onCardSettings = { [weak self] in self?.openMain(.card) }
        model.onRefreshStats = { [weak self] in self?.stats.reload() }
        model.onOpenStats = { [weak self] in self?.openMain(.stats) }
        model.onHideStats = { [weak self] in self?.toggleStatsCard() }
        if showCard { setCardVisible(true) }
        if showStatsCard { setStatsCardVisible(true) }
        rebuildMenu()
        refresh()
        scheduleTimer()
        // 统计在后台先读好，打开窗口时不用等；之后按自己的间隔增量更新
        stats.reload()  // 先用磁盘缓存马上出数，改动过的日志在后台再读
        scheduleStatsTimer()
        // 自动检查更新：启动 10 秒后查一次，之后每天一次；有新版时菜单里会出现提示
        updaterWatch = updater.$state.receive(on: RunLoop.main).sink { [weak self] _ in self?.scheduleSync() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.updater.check(silent: true) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.updater.lastCheck.map({ Date().timeIntervalSince($0) > 86400 }) ?? true { self.updater.check(silent: true) }
        }
        // 设置窗口里改了什么，这里同步到卡片显隐、刷新间隔和菜单栏
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleSync()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        rebuildMenu()
        Task {
            async let c = Claude.fetch()
            async let x = Codex.fetch()
            let r = await [c, x]
            await MainActor.run {
                self.results = r
                self.lastUpdate = Date()
                self.loading = false
                self.model.results = r
                self.model.lastUpdate = self.lastUpdate
                // 周额度的重置时间往前推 7 天，就是当前周期的起点
                for u in r {
                    guard let src = Source(rawValue: u.name),
                          let reset = u.windows.first(where: \.weekly)?.resetsAt else { continue }
                    // 接口给的重置时间常是 05:59:59.x 这种：差几秒到整分钟就进位，否则舍去秒数
                    let resetMinute = Date(timeIntervalSince1970: ((reset.timeIntervalSince1970 + 5) / 60).rounded(.down) * 60)
                    self.stats.cycleStarts[src] = resetMinute.addingTimeInterval(-7 * 86400)
                }
                self.updateTitle()
                self.rebuildMenu()
                Notifier.check(r)
            }
        }
    }

    func setCardVisible(_ on: Bool) {
        if on {
            if card == nil {
                let w = CardWindow(CardView(model: model), name: "UsageCard", onTopKey: Pref.cardOnTop)
                w.onResize = { [weak model] size in if let model, model.cardSize != size { model.cardSize = size } }
                card = w
            }
            card?.orderFront(nil)
        } else {
            card?.orderOut(nil)
        }
    }

    func setStatsCardVisible(_ on: Bool) {
        if on {
            if statsCard == nil {
                let w = CardWindow(StatsCardView(stats: stats, model: model), name: "UsageStatsCard", onTopKey: Pref.statsCardOnTop,
                                   near: card?.isVisible == true ? card : nil)
                w.onResize = { [weak model] size in if let model, model.statsCardSize != size { model.statsCardSize = size } }
                statsCard = w
            }
            statsCard?.orderFront(nil)
        } else {
            statsCard?.orderOut(nil)
        }
    }

    func scheduleTimer() {
        timerMinutes = UserDefaults.standard.integer(forKey: Pref.refreshMinutes)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, timerMinutes) * 60), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func scheduleStatsTimer() {
        statsTimerMinutes = UserDefaults.standard.integer(forKey: Pref.statsRefreshMinutes)
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, statsTimerMinutes) * 60), repeats: true) { [weak self] _ in
            self?.stats.reload()
        }
    }

    /// 偏好变化可能发生在 SwiftUI 布局途中（比如窗口位置自动保存），
    /// 这时同步重建菜单会嵌套触发文字排版而崩溃，所以推到下一轮主循环，并把连续的变化合并成一次
    var syncScheduled = false
    func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async {
            self.syncScheduled = false
            self.syncPrefs()
        }
    }

    func syncPrefs() {
        Pref.applyAppearance()
        if UserDefaults.standard.integer(forKey: Pref.refreshMinutes) != timerMinutes { scheduleTimer() }
        if UserDefaults.standard.integer(forKey: Pref.statsRefreshMinutes) != statsTimerMinutes { scheduleStatsTimer() }
        if (card?.isVisible ?? false) != showCard { setCardVisible(showCard) }
        if (statsCard?.isVisible ?? false) != showStatsCard { setStatsCardVisible(showStatsCard) }
        card?.applyLevel()
        statsCard?.applyLevel()
        if I18n.lang != lastLang {
            // 错误提示、额度名称是取数时生成的，换语言后重新取一次
            lastLang = I18n.lang
            refresh()
        }
        updateTitle()
        rebuildMenu()
    }

    /// 统计和设置都在主窗口里，菜单只留一个入口，打开时回到上次看的页
    @objc func openApp() { openMain(nil) }

    /// 已经在运行时再打开一次（Finder、启动台、Spotlight）：弹出主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openApp()
        return false
    }
    @objc func openUpdate() { openMain(.about) }

    /// 主窗口：统计和设置都在这里，左侧边栏切换
    func openMain(_ tab: MainTab?) {
        if let tab { nav.tab = tab }
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(nav: nav, stats: stats, model: model, updater: updater))
            host.sizingOptions = .minSize  // 最小尺寸来自 MainView 根部的 frame(minWidth:minHeight:)
            let w = NSWindow(contentViewController: host)
            // 标题留空：SwiftUI 会把 titleVisibility 改回可见，留空才能保证标题栏上不出现文字
            w.title = ""
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // 现代样式：标题栏透明、不显示标题和分隔线，只留左上角三个按钮
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.titlebarSeparatorStyle = .none
            // 不开「拖背景移动窗口」：开了的话表头上拖列宽、拖顺序都会变成拖整个窗口；窗口靠顶上的标题栏区域拖
            w.isReleasedWhenClosed = false
            // 宽高随便拖，只有最小尺寸（MainView 的 frame(minWidth:minHeight:)）
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            mainWindow = w
        }
        stats.reload()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleStatsCard() {
        showStatsCard.toggle()
        setStatsCardVisible(showStatsCard)
        rebuildMenu()
    }

    @objc func toggleCard() {
        showCard.toggle()
        setCardVisible(showCard)
        rebuildMenu()
    }

    func updateTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let s = NSMutableAttributedString()
        let full = UserDefaults.standard.string(forKey: Pref.menuLabel) == "full"
        let which = UserDefaults.standard.string(forKey: Pref.menuLimit) ?? "both"
        let shown = results.filter { Pref.menuVisible($0.name) }
        if UserDefaults.standard.string(forKey: Pref.menuStyle) == "stacked", !shown.isEmpty {
            item.button?.attributedTitle = NSAttributedString()
            item.button?.image = stackedTitle(shown.map { u in
                (full ? u.name : u.name == "Claude" ? "Cc" : "Cx", u.menuValue(which, used: Pref.menuUsed))
            })
            return
        }
        item.button?.image = nil
        for (i, u) in results.filter({ Pref.menuVisible($0.name) }).enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let short = full ? "\(u.name) " : u.name == "Claude" ? "Cc " : "Cx "
            s.append(NSAttributedString(string: short, attributes: [.font: font]))
            if let v = u.menuValue(which, used: Pref.menuUsed) {
                s.append(NSAttributedString(string: v, attributes: [.font: font]))
            } else {
                s.append(NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        item.button?.attributedTitle = s.length > 0 ? s : NSAttributedString(string: "UsageBar", attributes: [.font: font])
    }

    /// 双行样式：每家一块，上面小字是名称，下面是百分比。画成模板图，菜单栏深色浅色都跟着变
    func stackedTitle(_ blocks: [(name: String, value: String?)]) -> NSImage {
        let h = max(22, item.button?.bounds.height ?? 22)
        let tall = h >= 30  // 刘海屏的菜单栏更高，字也放大一点
        let nameFont = NSFont.systemFont(ofSize: tall ? 10.5 : 8.5, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: tall ? 14 : 11, weight: .semibold)
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: nameFont, .foregroundColor: NSColor.black]
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let texts = blocks.map { (NSString(string: $0.name), NSString(string: $0.value ?? "–")) }
        let widths = texts.map { max($0.0.size(withAttributes: nameAttrs).width, $0.1.size(withAttributes: valueAttrs).width) }
        let gap: CGFloat = tall ? 14 : 10
        let width = ceil(widths.reduce(0, +) + gap * CGFloat(max(0, blocks.count - 1)))
        let nameH = ceil(nameFont.ascender - nameFont.descender), valueH = ceil(valueFont.ascender - valueFont.descender)
        let overlap: CGFloat = tall ? 0 : 1.5  // 两行字的行距收紧一点，22pt 高的菜单栏才放得下
        let top = floor((h - nameH - valueH + overlap) / 2)
        let image = NSImage(size: NSSize(width: max(1, width), height: h), flipped: true) { _ in
            var x: CGFloat = 0
            // 名称和数值在各自那一块里居中
            for ((name, value), w) in zip(texts, widths) {
                let nw = name.size(withAttributes: nameAttrs).width, vw = value.size(withAttributes: valueAttrs).width
                name.draw(at: NSPoint(x: x + (w - nw) / 2, y: top), withAttributes: nameAttrs)
                value.draw(at: NSPoint(x: x + (w - vw) / 2, y: top + nameH - overlap), withAttributes: valueAttrs)
                x += w + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let small = NSFont.systemFont(ofSize: 11)

        // 纯展示的行：用自定义视图，否则 macOS 会把不可点的菜单项画成灰色
        func info(_ a: NSAttributedString) {
            let text = NSMutableAttributedString(attributedString: a)
            text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { v, r, _ in
                if v == nil { text.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r) }
            }
            let label = NSTextField(labelWithAttributedString: text)
            let size = label.fittingSize
            let pad = NSSize(width: 14, height: 2)
            label.frame = NSRect(x: pad.width, y: pad.height, width: size.width, height: size.height)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: size.width + pad.width * 2, height: size.height + pad.height * 2))
            box.addSubview(label)
            let mi = NSMenuItem()
            mi.view = box
            menu.addItem(mi)
        }

        // 每家一块，和桌面卡片同样的样式（圆角进度条，不再用字符画）
        let resetStyle = UserDefaults.standard.string(forKey: Pref.menuResetStyle) ?? "full"
        for u in results where Pref.menuVisible(u.name) {
            let host = NSHostingView(rootView: MenuUsageBlock(u: u, used: Pref.menuUsed, resetStyle: resetStyle))
            host.frame.size = host.fittingSize
            let mi = NSMenuItem()
            mi.view = host
            menu.addItem(mi)
            menu.addItem(.separator())
        }

        let status: String
        if loading { status = L("正在刷新…") }
        else if let t = lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            status = L("更新于 %@", f.string(from: t))
        } else { status = "" }
        if !status.isEmpty { info(NSAttributedString(string: status, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])) }

        /// 每一项都配 SF Symbol 图标，和系统自动给「退出」加的图标对齐
        func add(_ title: String, _ symbol: String, _ action: Selector, key: String = "") {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(mi)
        }
        add(L("立即刷新"), "arrow.clockwise", #selector(refresh), key: "r")
        // 不用勾号：卡片显示时叫「隐藏」，隐藏时叫「显示」，和卡片右键菜单一致
        add(showCard ? L("隐藏额度卡片") : L("显示额度卡片"), showCard ? "eye.slash" : "eye", #selector(toggleCard))
        add(showStatsCard ? L("隐藏用量卡片") : L("显示用量卡片"), "chart.bar", #selector(toggleStatsCard))
        if case .available(let v) = updater.state {
            add(L("有新版本 %@…", v), "arrow.down.circle", #selector(openUpdate))
        }
        add(L("打开 UsageBar…"), "macwindow", #selector(openApp), key: "o")
        menu.addItem(.separator())
        let q = NSMenuItem(title: L("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        q.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(q)
        item.menu = menu
    }
}

// 命令行模式：UsageBar --stats，打印本机会话记录的用量统计
if CommandLine.arguments.contains("--stats") {
    let sem = DispatchSemaphore(value: 0)
    Task { await printStats(); sem.signal() }
    sem.wait()
    exit(0)
}

// 命令行模式：UsageBar --print，直接在终端打印用量
if CommandLine.arguments.contains("--print") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        for u in [await Claude.fetch(), await Codex.fetch()] {
            print("\(u.name)\(u.plan.map { " (\($0))" } ?? "")")
            if let e = u.error { print("  ⚠︎ \(e)") }
            for w in u.windows {
                print("  \(w.label.padding(toLength: 10, withPad: " ", startingAt: 0))\(bar(w.shown(false))) \(w.shownText(false))  \(resetText(w.resetsAt))")
            }
            if let n = u.note { print("  ⓘ \(n)") }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
