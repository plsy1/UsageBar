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
    /// 每次的到期时间写成一行：「11/7 06:50、12/1 05:15 到期」
    var expiryText: String? {
        expiries.isEmpty ? nil : L("%@ 到期", expiries.map(Self.date).joined(separator: L("、")))
    }

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
        "官方接口": ("公式 API", "Official API"),
        "仅本地": ("ローカルのみ", "Local Only"),
        "额度：「官方接口」用本机的登录信息向 Anthropic、OpenAI 查询，最准；「仅本地」只读本机文件、不发请求，Codex 读会话日志，Claude 读桌面 app 的记录，可能不是最新。用量统计都只读本地日志": ("上限：「公式 API」はこの Mac のログイン情報で Anthropic・OpenAI に問い合わせ、最も正確です。「ローカルのみ」はこの Mac のファイルだけを読みリクエストを送りません（Codex はセッションログ、Claude はデスクトップアプリの記録。最新でないことがあります）。使用量の統計はいずれもローカルのログだけを読みます", "Limits: Official API asks Anthropic and OpenAI using the logins on this Mac and is the most accurate; Local Only reads files on this Mac and sends no requests (Codex from its session logs, Claude from the desktop app's records, which may be out of date). Usage statistics always read local logs only"),
        "本机没有 Claude 的额度记录（Claude 桌面 app 查看过用量后才会有）": ("この Mac に Claude の上限の記録がありません（Claude デスクトップアプリで使用量を表示すると作られます）", "No Claude limit records on this Mac (the Claude desktop app writes one when it shows usage)"),
        "Claude 桌面 app 最近没有查过用量（最近一次 %@）": ("Claude デスクトップアプリが最近使用量を取得していません（最後は %@）", "The Claude desktop app hasn't checked usage recently (last at %@)"),
        "来自 Claude 桌面 app 的记录 · 数据时间 %@": ("Claude デスクトップアプリの記録 · %@ 時点", "From the Claude desktop app · as of %@"),
        "来自会话日志": ("セッションログより", "From session logs"),
        "会话日志里还没有额度记录（用一次 Codex 就有）": ("セッションログにまだ上限の記録がありません（Codex を一度使うと記録されます）", "No limits in the session logs yet (they appear after using Codex once)"),
        "共 %d 行": ("全 %d 行", "%d rows"),
        "前 %d 行 · 共 %d 行": ("上位 %d 行 · 全 %d 行", "Top %d of %d rows"),
        "显示全部": ("すべて表示", "Show All"),
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
        "读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），以及「通用」里添加的远程机器上的 Codex 日志（用 ssh 读取，在远程先过滤）。解析结果存在本机的数据库里（~/Library/Application Support/UsageBar），日志被清理后统计也还在；成本按 models.dev 的 API 价格估算，价格每天更新一次": ("この Mac のセッション記録（~/.claude/projects と ~/.codex/sessions）と、「一般」で追加したリモートマシンの Codex ログ（ssh で読み込み、リモート側で絞り込み）を読みます。解析結果はこの Mac のデータベース（~/Library/Application Support/UsageBar）に保存され、ログが削除されても統計は残ります。コストは models.dev の API 価格で推定し、価格は 1 日 1 回更新します", "Reads this Mac's session logs (~/.claude/projects and ~/.codex/sessions) plus Codex logs on remote machines added under General (read over ssh, filtered on the remote side). Parsed records are kept in a local database (~/Library/Application Support/UsageBar), so statistics survive log cleanup; cost is estimated from models.dev API prices, refreshed daily"),
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
        "可用重置": ("使えるリセット", "Resets Available"),
        "大数字": ("大きな数字", "Big Numbers"),
        "圆环": ("リング", "Rings"),
        "细条": ("細いバー", "Slim Bars"),
        "走势图": ("推移グラフ", "Trend Chart"),
        "占比条": ("割合バー", "Share Bar"),
        "已用": ("使用済み", "Used"),
        "按余量着色": ("残りで色分け", "Color by Level"),
        "剩不到 30% 变黄，不到 10% 变红": ("残り 30% 未満で黄、10% 未満で赤", "Amber under 30% left, red under 10%"),
        "数据": ("データ", "Data"),
        "用量记录存在本机的数据库里，可以备份，也可以从备份导入": ("使用記録はこの Mac のデータベースに保存されます。バックアップやバックアップからの読み込みができます", "Usage records live in a local database you can back up and import from a backup"),
        "数据库": ("データベース", "Database"),
        "解析好的用量记录和每周额度的周期都存在这里，Claude Code 清理旧日志后统计也还在": ("解析済みの使用記録と週間上限の期間はここに保存され、Claude Code が古いログを削除しても統計は残ります", "Parsed usage records and weekly limit cycles are kept here, so statistics survive Claude Code's log cleanup"),
        "位置": ("場所", "Location"),
        "在访达中显示": ("Finder で表示", "Show in Finder"),
        "备份": ("バックアップ", "Backup"),
        "备份是一个完整的数据库文件。导入会把备份里的记录合并进来，现有的不会丢；Windows / Linux 版的备份也能导入": ("バックアップはデータベース全体のファイルです。読み込むとバックアップの記録が統合され、今ある記録は消えません。Windows / Linux 版のバックアップも読み込めます", "A backup is a complete copy of the database. Importing merges its records in without losing the ones you have; backups from Windows / Linux work too"),
        "备份到文件": ("ファイルにバックアップ", "Back Up to a File"),
        "保存一份数据库的副本": ("データベースのコピーを保存します", "Saves a copy of the database"),
        "备份…": ("バックアップ…", "Back Up…"),
        "从备份导入": ("バックアップから読み込む", "Import a Backup"),
        "合并备份里的记录，比如换了电脑或重装之后": ("バックアップの記録を統合します（PC を替えたときや再インストール後など）", "Merges its records in, e.g. after moving to a new computer or reinstalling"),
        "导入…": ("読み込む…", "Import…"),
        "已备份到 %@": ("%@ にバックアップしました", "Backed up to %@"),
        "备份失败": ("バックアップに失敗しました", "Backup failed"),
        "已导入，新增 %d 条请求": ("読み込みました（%d 件追加）", "Imported: %d new requests"),
        "这不是 UsageBar 的数据库": ("UsageBar のデータベースではありません", "That isn't a UsageBar database"),
        "隐藏 UsageBar": ("UsageBar を隠す", "Hide UsageBar"),
        "隐藏其他": ("ほかを隠す", "Hide Others"),
        "编辑": ("編集", "Edit"),
        "撤销": ("取り消す", "Undo"),
        "重做": ("やり直す", "Redo"),
        "剪切": ("カット", "Cut"),
        "拷贝": ("コピー", "Copy"),
        "粘贴": ("ペースト", "Paste"),
        "全选": ("すべてを選択", "Select All"),
        "窗口": ("ウインドウ", "Window"),
        "最小化": ("しまう", "Minimize"),
        "1 次": ("1 回", "1"),
        "%d 次": ("%d 回", "%d"),
        "按周期": ("期間別", "By Cycle"),
        "周期": ("期間", "Cycle"),
        "已用额度": ("使用した上限", "Limit Used"),
        "满额价值": ("上限いっぱいの価値", "Full-Limit Value"),
        "环比": ("前期比", "vs. Previous"),
        "进行中": ("進行中", "in progress"),
        "提前重置": ("早期リセット", "reset early"),
        "每周额度从上次重置到下次重置算一个周期，不跟上面的时间范围。Codex 的周期取自会话日志；Claude 只记得查过额度的周期，更早的按 7 天往前推算。已用额度是这个周期里见到的最高比例；满额价值 = 估算成本 ÷ 已用额度（不到 10% 时不算），只是粗略参考：网页、桌面 app 聊天、其他电脑和云端任务也占额度但没有记录，周期中途提前重置过也会让它偏高或偏低": ("週間上限の前回リセットから次のリセットまでを 1 期間とし、上の期間の選択には従いません。Codex の期間はセッションログから、Claude は上限を問い合わせた期間だけを記録し、それより前は 7 日ずつさかのぼって推定します。使用した上限はその期間に見られた最大の割合です。上限いっぱいの価値 = 推定コスト ÷ 使用した上限（10% 未満は計算しません）は目安にすぎません：Web、デスクトップアプリのチャット、ほかの PC、クラウドタスクも上限を使いますが記録がなく、期間の途中で早期リセットがあってもずれます", "A cycle runs from one weekly reset to the next and ignores the period selected above. Codex cycles come from the session logs; Claude only remembers cycles whose limits were checked, and earlier ones are counted back in 7-day steps. Limit Used is the highest share seen in that cycle. Full-Limit Value = estimated cost ÷ limit used (left out below 10%) is only a rough guide: the web, desktop-app chats, other computers and cloud tasks also use the limit but leave no records here, and an early reset in the middle of a cycle skews it too"),
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
        "默认用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询；在「通用 → 数据来源」里可以改成「仅本地」，只读本机文件、不发请求": ("既定ではこの Mac の Claude Code と Codex のログイン情報で Anthropic・OpenAI の使用量 API に問い合わせます。「一般 → データソース」で「ローカルのみ」にすると、この Mac のファイルだけを読みリクエストを送りません", "By default, queried from Anthropic's and OpenAI's usage endpoints using the Claude Code and Codex logins on this Mac; switch to Local Only under General → Data Sources to read files on this Mac only and send no requests"),
        "卡片": ("カード", "Cards"),
        "额度卡片": ("上限カード", "Limits Card"),
        "用量卡片": ("使用量カード", "Usage Card"),
        "显示额度卡片": ("上限カードを表示", "Show Limits Card"),
        "隐藏额度卡片": ("上限カードを隠す", "Hide Limits Card"),
        "额度": ("上限", "Limits"),
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

    /// 「仅本地」：Claude 桌面 app 查过用量后会在这里留一条采样（5 小时、本周已用的百分比），不发请求。
    /// 只在 app 查看用量时才写，可能是很久以前的；没有重置时间
    static func fetchLocal() -> ProviderUsage {
        var u = ProviderUsage(name: "Claude")
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/plan-usage-history.json")
        guard let d = try? Data(contentsOf: url),
              let samples = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["samples"] as? [[String: Any]],
              let last = samples.max(by: { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }),
              let t = last["t"] as? Double, let usage = last["u"] as? [String: Any] else {
            u.error = L("本机没有 Claude 的额度记录（Claude 桌面 app 查看过用量后才会有）")
            return u
        }
        let at = Date(timeIntervalSince1970: t / 1000), age = Date().timeIntervalSince(at)
        // 过了一个窗口的长度，那时的数肯定已经重置过了，不再显示
        if age < 5 * 3600, let fh = usage["fh"] as? Double {
            u.windows.append(LimitWindow(label: L("5 小时"), usedPercent: fh, resetsAt: nil, length: 5 * 3600))
        }
        if age < 7 * 86400, let sd = usage["sd"] as? Double {
            u.windows.append(LimitWindow(label: L("本周"), usedPercent: sd, resetsAt: nil, weekly: true, length: 7 * 86400))
        }
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        u.note = L("来自 Claude 桌面 app 的记录 · 数据时间 %@", f.string(from: at))
        if u.windows.isEmpty { u.error = L("Claude 桌面 app 最近没有查过用量（最近一次 %@）", f.string(from: at)) }
        return u
    }

    /// Claude 桌面 app 记下的本周已用比例（时间、百分比）：统计页「按周期」补上 Claude 各周期用到多少
    static func desktopWeeklySamples() -> [(Date, Double)] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/plan-usage-history.json")
        guard let d = try? Data(contentsOf: url),
              let samples = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["samples"] as? [[String: Any]] else { return [] }
        return samples.compactMap { s in
            guard let t = s["t"] as? Double, let sd = (s["u"] as? [String: Any])?["sd"] as? Double else { return nil }
            return (Date(timeIntervalSince1970: t / 1000), sd)
        }
    }

    static func fetch() async -> ProviderUsage {
        if Pref.localLimits("Claude") { return fetchLocal() }
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
        let local = Pref.localLimits("Codex")
        if !local, let d = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
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
        // 「仅本地」，或接口查不到：用会话日志里最新的一份额度（本机和远程机器的都算）
        if let (rl, mtime) = newestLoggedRateLimits() {
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
            u.note = L("%@ · 数据时间 %@", u.note ?? (local ? L("来自会话日志") : L("本地缓存")), f.string(from: mtime))
        } else if u.windows.isEmpty {
            u.error = local ? L("会话日志里还没有额度记录（用一次 Codex 就有）") : L("读不到 Codex 登录信息或会话记录")
        }
        return u
    }

    /// 数据库里记下的（解析本机和远程日志时见到的最新一份），和直接翻本机最近几个日志找到的，取较新的
    static func newestLoggedRateLimits() -> ([String: Any], Date)? {
        let fromDB = LogReader.codexRateLimits().map { ($0.limits, $0.time) }
        let fromFiles = latestLocalRateLimits()
        switch (fromDB, fromFiles) {
        case let (a?, b?): return a.1 >= b.1 ? a : b
        case let (a?, nil): return a
        default: return fromFiles
        }
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

/// 接口给的重置时间常是 05:59:59.x：差几秒到整分钟就进位，和统计页的「重置以来」一致
func resetMinute(_ d: Date) -> Date { Date(timeIntervalSince1970: ((d.timeIntervalSince1970 + 5) / 60).rounded(.down) * 60) }

/// 「3天4小时」「4小时40分」「12分钟」
func countdown(_ d: Date) -> String {
    let s = max(0, d.timeIntervalSinceNow)
    let days = Int(s) / 86400, hours = Int(s) % 86400 / 3600, mins = Int(s) % 3600 / 60
    return days > 0 ? L("%d天%d小时", days, hours) : hours > 0 ? L("%d小时%d分", hours, mins) : L("%d分钟", mins)
}

/// 今天内只写几点，否则带上星期几
func resetClock(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: ["zh": "zh_CN", "ja": "ja_JP"][I18n.lang] ?? "en_US")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : (I18n.lang == "ja" ? "EEEE HH:mm" : "EEE HH:mm")
    return f.string(from: d)
}

func resetText(_ d: Date?, style: String = "full") -> String {
    guard let d = d.map(resetMinute) else { return "" }
    if style == "relative" { return L("%@后重置", countdown(d)) }
    if style == "absolute" { return L("%@ 重置", resetClock(d)) }
    let f = DateFormatter(); f.dateFormat = d.timeIntervalSinceNow >= 86400 ? "M/d HH:mm" : "HH:mm"
    return L("%@后重置（%@）", countdown(d), f.string(from: d))
}

/// 卡片上的短写法（前面配一个 ↻ 图标）：relative「4小时40分」/ absolute「周三 14:20」；hidden 或没有重置时间时为空
func resetShort(_ d: Date?, style: String) -> String? {
    guard let d = d.map(resetMinute), style != "hidden" else { return nil }
    return style == "absolute" ? resetClock(d) : countdown(d)
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
    /// 额度从哪来：api 用本机的登录信息请求官方接口 / local 只读本机文件、不发请求
    static let claudeLimitSource = "claudeLimitSource"
    static let codexLimitSource = "codexLimitSource"
    static func localLimits(_ provider: String) -> Bool {
        UserDefaults.standard.string(forKey: provider == "Claude" ? claudeLimitSource : codexLimitSource) == "local"
    }
    static let menuStyle = "menuStyle"         // inline 一行 / stacked 名称在上、数值在下两行
    static let language = "language"           // auto / zh / ja / en
    static let displayMode = "displayMode"     // remaining / used
    static let cardLayout = "cardLayout"       // horizontal / vertical / compact / big（大数字）/ rings（圆环）/ slim（细条）
    static let cardLevelColors = "cardLevelColors"  // 额度卡片按余量着色
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
    /// 只在真的变了时才设：每次赋一个新的外观对象，哪怕还是同一种，所有窗口都会整个重新画一遍
    static func applyAppearance() {
        let want: NSAppearance.Name? = switch UserDefaults.standard.string(forKey: appearance) {
        case "light": .aqua
        case "dark": .darkAqua
        default: nil  // 跟随系统
        }
        guard NSApp.appearance?.name != want else { return }
        NSApp.appearance = want.map { NSAppearance(named: $0) } ?? nil
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
    /// 要跨进程去问系统（每次几十毫秒），存一份：改开关时、app 回到前台时（可能在系统设置里改过）才重新问
    private(set) static var status: SMAppService.Status = SMAppService.mainApp.status
    static func refresh() { status = SMAppService.mainApp.status }
    static func set(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        refresh()
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
    @AppStorage(Pref.claudeLimitSource) var claudeSource = "api"
    @AppStorage(Pref.codexLimitSource) var codexSource = "api"
    @AppStorage(Notifier.thresholdKey) var notifyThreshold = 0
    @AppStorage(Notifier.runOutKey) var notifyRunOut = false
    @AppStorage(Notifier.resetKey) var notifyReset = false
    @AppStorage(Notifier.creditsKey) var notifyCredits = false
    @State var notifyAllowed = true
    // 开机启动的状态要跨进程去问系统，页面出现时问一次就好（写在初始值里的话，每次重建页面都会问）
    @State var launchAtLogin = false
    @State var needsApproval = false

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
        .onAppear {
            launchAtLogin = LoginItem.status == .enabled
            needsApproval = LoginItem.status == .requiresApproval
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
                Text(stats.overview.earliest.map { L("%d 条请求，最早 %@", stats.overview.count, shortDate($0)) } ?? L("正在读取本机会话记录…"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var sources: some View {
        SettingsGroup(L("数据来源"), footer: L("额度：「官方接口」用本机的登录信息向 Anthropic、OpenAI 查询，最准；「仅本地」只读本机文件、不发请求，Codex 读会话日志，Claude 读桌面 app 的记录，可能不是最新。用量统计都只读本地日志")) {
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
        let removed = hosts.filter { !list.contains($0) }
        remoteHosts = list.joined(separator: ",")
        // 移除的机器把它的记录也清掉，再重新读
        DispatchQueue.global(qos: .userInitiated).async {
            LogReader.removeHosts(removed)
            DispatchQueue.main.async { stats.reload() }
        }
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
    /// 右边选额度来源；左边小字是这次从哪查到了什么（套餐、本地数据的时间），出错时是红色的原因
    func provider(_ name: String, source: String) -> some View {
        let u = model.results.first { $0.name == name }
        let selection = name == "Claude" ? $claudeSource : $codexSource
        let local = selection.wrappedValue == "local"
        let detail = u?.error ?? (u == nil ? L("正在获取用量…")
            : local ? u?.note ?? L("仅本地")
            : [source, u?.plan, u?.note].compactMap { $0 }.joined(separator: " · "))
        return SettingsRow(name, detail: detail, warning: u?.error != nil) {
            HStack(spacing: 8) {
                Picker("", selection: selection) {
                    Text(L("官方接口")).tag("api")
                    Text(L("仅本地")).tag("local")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
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

/// 「数据」：用量记录的数据库在哪、多大，备份和从备份导入
struct DataSettings: View {
    @ObservedObject var stats: StatsStore
    @State var size = LogReader.databaseSize()
    @State var message: String?
    @State var busy = false

    var body: some View {
        SettingsScroll(.data, L("用量记录存在本机的数据库里，可以备份，也可以从备份导入")) {
            HStack(alignment: .top, spacing: 24) {
                database.frame(maxWidth: .infinity, alignment: .top)
                backup.frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    var database: some View {
        SettingsGroup(L("数据库"), footer: L("解析好的用量记录和每周额度的周期都存在这里，Claude Code 清理旧日志后统计也还在")) {
            SettingsRow(L("位置"), detail: (LogReader.dbURL.path as NSString).abbreviatingWithTildeInPath) {
                Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([LogReader.dbURL]) }.controlSize(.small)
            }
            Divider()
            SettingsRow(L("大小")) {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).monospacedDigit().foregroundStyle(.secondary)
            }
            Divider()
            SettingsRow(L("会话记录")) {
                Text(stats.overview.earliest.map { L("%d 条请求，最早 %@", stats.overview.count, Self.day($0)) } ?? L("正在读取本机会话记录…"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var backup: some View {
        SettingsGroup(L("备份"), footer: message ?? L("备份是一个完整的数据库文件。导入会把备份里的记录合并进来，现有的不会丢；Windows / Linux 版的备份也能导入")) {
            SettingsRow(L("备份到文件"), detail: L("保存一份数据库的副本")) {
                Button(L("备份…"), action: doBackup).controlSize(.small).disabled(busy)
            }
            Divider()
            SettingsRow(L("从备份导入"), detail: L("合并备份里的记录，比如换了电脑或重装之后")) {
                Button(L("导入…"), action: doImport).controlSize(.small).disabled(busy)
            }
        }
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f.string(from: d)
    }

    func doBackup() {
        let panel = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "UsageBar-backup-\(f.string(from: Date())).sqlite"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = LogReader.backup(to: url)
            DispatchQueue.main.async {
                busy = false
                message = ok ? L("已备份到 %@", (url.path as NSString).abbreviatingWithTildeInPath) : L("备份失败")
            }
        }
    }

    func doImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let added = LogReader.importBackup(from: url)
            DispatchQueue.main.async {
                busy = false
                size = LogReader.databaseSize()
                message = added.map { L("已导入，新增 %d 条请求", $0) } ?? L("这不是 UsageBar 的数据库")
                if added != nil { stats.reload() }
            }
        }
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
    @AppStorage(Pref.cardLevelColors) var levelColors = false
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
                    if keys.stats {
                        Picker("", selection: $layout) {
                            Label(L("左右"), systemImage: "rectangle.split.2x1").tag("horizontal")
                            Label(L("上下"), systemImage: "rectangle.split.1x2").tag("vertical")
                            Label(L("紧凑"), systemImage: "list.bullet").tag("compact")
                            Divider()
                            Label(L("大数字"), systemImage: "textformat.size").tag("big")
                            Label(L("走势图"), systemImage: "chart.bar.xaxis").tag("trend")
                            Label(L("占比条"), systemImage: "chart.bar.doc.horizontal").tag("share")
                        }
                        .labelsHidden().fixedSize()
                    } else {
                        // 额度卡片的样式多，用菜单
                        Picker("", selection: $layout) {
                            Label(L("左右"), systemImage: "rectangle.split.2x1").tag("horizontal")
                            Label(L("上下"), systemImage: "rectangle.split.1x2").tag("vertical")
                            Label(L("紧凑"), systemImage: "list.bullet").tag("compact")
                            Divider()
                            Label(L("大数字"), systemImage: "textformat.size").tag("big")
                            Label(L("圆环"), systemImage: "circle.circle").tag("rings")
                            Label(L("细条"), systemImage: "chart.bar.doc.horizontal").tag("slim")
                        }
                        .labelsHidden().fixedSize()
                    }
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
                if !keys.stats {
                    Divider()
                    SettingsRow(L("按余量着色"), detail: L("剩不到 30% 变黄，不到 10% 变红")) { SwitchControl(isOn: $levelColors) }
                }
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
        case (false, "big"): base = CGSize(width: 472, height: 190)
        case (false, "rings"): base = CGSize(width: 330, height: 175)
        case (false, "slim"): base = CGSize(width: 300, height: 120)
        case (false, _): base = CGSize(width: 476, height: 167)
        case (true, "vertical"): base = CGSize(width: 292, height: 330)
        case (true, "compact"): base = CGSize(width: 330, height: 93)
        case (true, "big"): base = CGSize(width: 472, height: 170)
        case (true, "trend"): base = CGSize(width: 252, height: 250)
        case (true, "share"): base = CGSize(width: 252, height: 160)
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
                                    L("默认用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询；在「通用 → 数据来源」里可以改成「仅本地」，只读本机文件、不发请求"))
                            Divider().padding(.leading, 54)
                            infoRow("chart.bar.xaxis", L("用量统计"),
                                    L("读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），以及「通用」里添加的远程机器上的 Codex 日志（用 ssh 读取，在远程先过滤）。解析结果存在本机的数据库里（~/Library/Application Support/UsageBar），日志被清理后统计也还在；成本按 models.dev 的 API 价格估算，价格每天更新一次"))
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
    case stats, general, menuBar, card, data, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return L("用量统计")
        case .general: return L("通用")
        case .menuBar: return L("菜单栏")
        case .card: return L("卡片")
        case .data: return L("数据")
        case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .stats: return "chart.bar.xaxis"
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .card: return "rectangle.on.rectangle"
        case .data: return "cylinder.split.1x2"
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

/// 主窗口的最小尺寸（所有页面在这个尺寸下都能完整显示）
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let minContent = NSSize(width: 1120, height: 700)
    var onClose: () -> Void = {}
    func windowWillClose(_ notification: Notification) { onClose() }
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let min = sender.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minContent)).size
        return NSSize(width: max(frameSize.width, min.width), height: max(frameSize.height, min.height))
    }
}

/// 主窗口的一页。输入都是不变的对象，判等只看是哪一页：页面自己的数据（设置、统计）变了照样会更新
struct PageHost: View, Equatable {
    let tab: MainTab
    let stats: StatsStore
    let model: UsageModel
    let updater: Updater
    let language: String  // 换语言时要重画
    static func == (a: PageHost, b: PageHost) -> Bool { a.tab == b.tab && a.language == b.language }

    var body: some View {
        switch tab {
        case .stats: StatsView(store: stats)
        case .general: GeneralSettings(updater: updater, model: model, stats: stats)
        case .menuBar: MenuBarSettings(model: model)
        case .card: CardSettings(model: model, stats: stats)
        case .data: DataSettings(stats: stats)
        case .about: AboutSettings(updater: updater)
        }
    }
}

/// 主窗口右边的页面。打开过的留着，切走只是藏起来：每次切换都重建整页的话，开关、下拉菜单这些原生控件多的页面
/// 要等两三百毫秒才出来。PageHost 判等时只看是哪一页，切换时 SwiftUI 就不会把藏着的页面重算一遍
struct MainPages: View {
    @ObservedObject var nav: MainNav
    let stats: StatsStore
    let model: UsageModel
    let updater: Updater
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage("statsChartColor") var themeColor = "pink"
    @State var visited: Set<MainTab> = []
    /// 藏起来的页面停在切走时的大小：拖窗口大小时只有正在看的那页跟着重新排版
    @State var frozen: [MainTab: CGSize] = [:]
    @State var size = CGSize.zero

    var body: some View {
        let _ = language  // 切换语言时重绘
        PagesLayout(current: nav.tab, frozen: frozen) {
            ForEach([MainTab.stats, .general, .menuBar, .card, .data, .about]) { t in
                if visited.contains(t) || nav.tab == t {
                    PageHost(tab: t, stats: stats, model: model, updater: updater, language: language).equatable()
                        .opacity(nav.tab == t ? 1 : 0)
                        .allowsHitTesting(nav.tab == t)
                        .accessibilityHidden(nav.tab != t)
                        .layoutValue(key: PageTab.self, value: t)
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 }
        })
        .onAppear { visited.insert(nav.tab) }
        // 拖窗口大小时，藏着的页面里的开关、下拉菜单这些原生控件也要跟着更新，很卡：开始拖时只留正在看的那页，
        // 其他的等切过去时再建
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in
            visited = [nav.tab]
            frozen = [:]
        }
        .onChange(of: nav.tab) { [old = nav.tab] new in
            visited.insert(new)
            frozen[old] = size
            frozen[new] = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        // 单独的托管视图不继承外面的主题色，这里再设一次
        .tint(themeColor == "system" ? nil : ChartColor.color(themeColor))
        .accentColor(themeColor == "system" ? nil : ChartColor.color(themeColor))
    }
}

struct PageTab: LayoutValueKey { static let defaultValue: MainTab? = nil }

/// 页面叠在一起：正在看的那页按给的空间排，其他页按切走时的大小排（大小不变，SwiftUI 就不用重新排它们）
struct PagesLayout: Layout {
    let current: MainTab
    let frozen: [MainTab: CGSize]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            let t = s[PageTab.self]
            let size = t == current ? bounds.size : t.flatMap { frozen[$0] } ?? bounds.size
            s.place(at: bounds.origin, proposal: ProposedViewSize(size))
        }
    }
}

/// 把内容放进一个不量尺寸的 NSHostingController，外面量它时直接按给的空间算
struct IsolatedHost<Content: View>: NSViewControllerRepresentable {
    let content: Content
    func makeNSViewController(context: Context) -> NSHostingController<Content> {
        let c = NSHostingController(rootView: content)
        c.sizingOptions = []
        return c
    }
    func updateNSViewController(_ c: NSHostingController<Content>, context: Context) { c.rootView = content }
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSHostingController<Content>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 900, height: proposal.height ?? 700)
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
                    ForEach([MainTab.general, .menuBar, .card, .data, .about]) { row($0) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .modifier(HideSidebarToggle())
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            // 页面放在单独的托管视图里：NavigationSplitView 每次布局都要量一遍详情区的最小尺寸，
            // 直接放 SwiftUI 内容的话要把页面完整排一遍；隔一层后它只量这个空壳
            IsolatedHost(content: MainPages(nav: nav, stats: stats, model: model, updater: updater))
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
        return Button { if nav.tab != t { nav.tab = t } } label: {
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
    /// 按余量着色时的颜色（够用时为空，用原来的颜色）
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack(spacing: 3 * s) {
                Text(w.label).font(.system(size: 12 * s))
                Spacer()
                Text(w.shownText(used))
                    .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                if w.fast {
                    Image(systemName: "arrow.up").font(.system(size: 9 * s, weight: .bold))
                        .help(L("用得比时间快：已用的比例超过了这个周期已经过去的比例"))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.25))
                    Capsule().fill(tint ?? Color.primary.opacity(0.9)).frame(width: g.size.width * w.shown(used) / 100)
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

extension LimitWindow {
    /// 按余量着色：剩不到 30% 黄、不到 10% 红；够用时为空（用原来的颜色）。显示「已使用」时也按剩余算
    func levelColor(_ on: Bool) -> Color? {
        guard on else { return nil }
        return remaining < 10 ? .red : remaining < 30 ? .orange : nil
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
    @AppStorage(Pref.cardLevelColors) var levelColors = false
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
                case "big":
                    HStack(alignment: .top, spacing: 26 * s) { ForEach(shown, id: \.name, content: bigBlock) }
                case "rings":
                    HStack(alignment: .top, spacing: 26 * s) { ForEach(shown, id: \.name, content: ringBlock) }
                case "slim":
                    Grid(alignment: .leading, horizontalSpacing: 8 * s, verticalSpacing: 7 * s) {
                        ForEach(shown, id: \.name, content: slimRows)
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
                UsageRow(w: w, s: s, showReset: resetStyle != "hidden", used: used, resetStyle: resetStyle, keepResetSpace: true,
                         tint: w.levelColor(levelColors))
            }
            if let rc = u.resetCredits { CreditsRow(rc: rc, s: s) }
            if let n = u.note {
                Text(n).font(.system(size: 10 * s)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 上下布局时一栏占满整行，放宽一些更好看
        .frame(width: (layout == "vertical" ? CardWindow.wideColumn : CardWindow.column) * s, alignment: .topLeading)
    }

    // MARK: 大数字、圆环、细条

    /// 名称、套餐，右边一个小字「剩余 / 已用」说明下面的数字是哪种
    func header(_ u: ProviderUsage, caption: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
            Text(u.name).font(.system(size: 13 * s, weight: .semibold))
            if let p = u.plan { Text(p).font(.system(size: 10 * s)).foregroundStyle(.secondary) }
            if caption {
                Spacer(minLength: 10 * s)
                Text(used ? L("已用") : L("剩余")).font(.system(size: 10 * s)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder func errorText(_ u: ProviderUsage) -> some View {
        if let e = u.error, u.windows.isEmpty {
            Text(e).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: 200 * s, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 细进度条（圆头）
    func thinBar(_ v: Double, tint: Color?, width: CGFloat? = nil, height: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.22))
                Capsule().fill(tint ?? Color.primary.opacity(0.9)).frame(width: g.size.width * min(100, max(0, v)) / 100)
            }
        }
        .frame(width: width, height: height)
    }

    /// ↻ 4小时40分（不显示重置时间时空着）
    @ViewBuilder func resetLabel(_ w: LimitWindow, size: CGFloat) -> some View {
        if let r = resetShort(w.resetsAt, style: resetStyle) {
            HStack(spacing: 3 * s) {
                Image(systemName: "arrow.clockwise").font(.system(size: (size - 1.5) * s, weight: .semibold))
                Text(r).font(.system(size: size * s)).monospacedDigit()
            }
            .foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// 大数字：每个额度一格，两格一行；名称、大号百分比、细进度条、多久后重置
    func bigBlock(_ u: ProviderUsage) -> some View {
        let cell: CGFloat = 92
        return VStack(alignment: .leading, spacing: 10 * s) {
            header(u, caption: !u.windows.isEmpty)
            errorText(u)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell * s), spacing: 16 * s, alignment: .leading), count: 2),
                      alignment: .leading, spacing: 12 * s) {
                ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in bigCell(w) }
            }
            if let rc = u.resetCredits { CreditsRow(rc: rc, s: s) }
        }
        .frame(width: (cell * 2 + 16) * s, alignment: .topLeading)
    }

    func bigCell(_ w: LimitWindow) -> some View {
        let tint = w.levelColor(levelColors)
        return VStack(alignment: .leading, spacing: 4 * s) {
            Text(w.label).font(.system(size: 10 * s)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1 * s) {
                Text("\(Int(w.shown(used).rounded()))")
                    .font(.system(size: 26 * s, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                Text("%").font(.system(size: 12 * s, weight: .medium)).foregroundStyle(.secondary)
                if w.fast { Image(systemName: "arrow.up").font(.system(size: 10 * s, weight: .bold)).padding(.leading, 2 * s) }
            }
            thinBar(w.shown(used), tint: tint, height: 3 * s)
            resetLabel(w, size: 9.5)
        }
    }

    /// 圆环：每个额度一个环，中间是百分比，下面是名称和多久后重置
    func ringBlock(_ u: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            header(u, caption: !u.windows.isEmpty)
            errorText(u)
            HStack(alignment: .top, spacing: 12 * s) {
                ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in ring(w) }
            }
            // 环下面地方窄，重置次数只写次数（和紧凑一样）
            if let rc = u.resetCredits { Text(rc.countText).font(.system(size: 10 * s)).foregroundStyle(.secondary) }
        }
    }

    func ring(_ w: LimitWindow) -> some View {
        let v = w.shown(used), tint = w.levelColor(levelColors), line = 5 * s
        return VStack(spacing: 5 * s) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.22), lineWidth: line)
                Circle().trim(from: 0, to: min(100, max(0, v)) / 100)
                    .stroke(tint ?? Color.primary.opacity(0.9), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(v.rounded()))").font(.system(size: 15 * s, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    Text("%").font(.system(size: 9 * s, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52 * s, height: 52 * s)
            Text(w.label + (w.fast ? " ↑" : "")).font(.system(size: 10 * s)).foregroundStyle(.secondary).lineLimit(1)
            resetLabel(w, size: 9)
        }
        .frame(minWidth: 58 * s)
    }

    /// 细条：每个额度一行：名称（每家第一行写）、额度名、细进度条、数值；不写重置时间
    @ViewBuilder func slimRows(_ u: ProviderUsage) -> some View {
        if let e = u.error, u.windows.isEmpty {
            GridRow(alignment: .firstTextBaseline) {
                Text(u.name).font(.system(size: 12 * s, weight: .semibold))
                Text(e).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 220 * s, alignment: .leading).gridCellColumns(3)
            }
        }
        ForEach(Array(u.windows.enumerated()), id: \.offset) { i, w in
            let tint = w.levelColor(levelColors)
            GridRow(alignment: .center) {
                Text(i == 0 ? u.name : " ").font(.system(size: 12 * s, weight: .semibold))
                Text(w.label).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                thinBar(w.shown(used), tint: tint, width: 110 * s, height: 4 * s)
                Text(w.shownText(used) + (w.fast ? "↑" : ""))
                    .font(.system(size: 11.5 * s, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                    .gridColumnAlignment(.trailing)
            }
        }
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
                        .foregroundStyle(w.levelColor(levelColors).map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                }
            }
            if let rc = u.resetCredits {
                Text(rc.countText).font(.system(size: 11 * s)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Codex 的额度重置次数：和额度一样左边名称、右边数值，下面一行小字是每次的到期时间
struct CreditsRow: View {
    let rc: ResetCredits
    let s: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack(spacing: 3 * s) {
                Text(L("可用重置")).font(.system(size: 12 * s))
                Spacer()
                Text(rc.count == 1 ? L("1 次") : L("%d 次", rc.count))
                    .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
            }
            if let e = rc.expiryText {
                Text(e).font(.system(size: 10 * s)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            if let rc = u.resetCredits { CreditsRow(rc: rc, s: 1.08) }
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
        // 主窗口里按 ⌘H 隐藏 UsageBar 时，桌面卡片留着
        canHide = false
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
        canHide = false
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
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            LoginItem.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    @objc func refresh() {
        // 正在查的话，等这次查完再查一次（比如刚换了额度来源，这次查的还是旧来源）
        guard !loading else { refreshAgain = true; return }
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
                    // 官方接口直接查到的才记进「按周期」（退回本地缓存的不算）
                    if u.error == nil, u.note == nil, let w = u.windows.first(where: \.weekly) {
                        DispatchQueue.global(qos: .utility).async { LogReader.recordCycle(src, resetsAt: reset, used: w.usedPercent) }
                    }
                }
                self.updateTitle()
                self.rebuildMenu()
                Notifier.check(r)
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
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
        // 菜单栏文字和下拉菜单只在跟它们有关的设置变了时才重画：任何设置一变（包括切换主窗口的页面）都会走到这里
        let d = UserDefaults.standard
        let menuKey = [Pref.menuLabel, Pref.menuStyle, Pref.menuDisplayMode, Pref.menuShowClaude, Pref.menuShowCodex,
                       Pref.menuLimit, Pref.menuResetStyle, Pref.showCard, Pref.showStatsCard, Pref.language]
            .map { "\(d.object(forKey: $0) ?? "")" }.joined(separator: "|")
        // 换了额度来源：马上按新的来源查一次
        let sourceKey = "\(Pref.localLimits("Claude"))|\(Pref.localLimits("Codex"))"
        if sourceKey != lastSourceKey {
            if !lastSourceKey.isEmpty { refresh(); stats.reload() }
            lastSourceKey = sourceKey
        }
        if menuKey != lastMenuKey {
            lastMenuKey = menuKey
            updateTitle()
            rebuildMenu()
        }
    }
    var lastMenuKey = ""
    var lastSourceKey = ""
    var refreshAgain = false

    /// 统计和设置都在主窗口里，菜单只留一个入口，打开时回到上次看的页
    @objc func openApp() { openMain(nil) }

    /// 已经在运行时再打开一次（Finder、启动台、Spotlight）：弹出主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openApp()
        return false
    }
    @objc func openUpdate() { openMain(.about) }

    /// 主窗口：统计和设置都在这里，左侧边栏切换
    let mainWindowDelegate = MainWindowDelegate()

    func openMain(_ tab: MainTab?) {
        // 关窗口时整个释放：留着的话打开过的页面一直占着内存（统计页几十 MB），看不见时也还跟着数据刷新重算
        mainWindowDelegate.onClose = { [weak self] in
            DispatchQueue.main.async {
                self?.mainWindow?.contentViewController = nil
                self?.mainWindow = nil
                self?.stats.release()  // 统计页取进内存的更早的记录也放掉
                // 主窗口关了：回到只在菜单栏的样子（不占程序坞）
                NSApp.setActivationPolicy(.accessory)
            }
        }
        if let tab { nav.tab = tab }
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(nav: nav, stats: stats, model: model, updater: updater))
            // 不让窗口从 SwiftUI 内容量最小尺寸：量一次要把整页完整排一遍，每切一个 tab 都要量，切换就慢。
            // 最小尺寸是固定的，直接设在窗口上
            host.sizingOptions = []
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
            // 最小尺寸：只设 contentMinSize 会被 NavigationSplitView 的约束盖掉，拖动时由代理卡住
            w.contentMinSize = MainWindowDelegate.minContent
            w.delegate = mainWindowDelegate
            // 宽高随便拖，只有最小尺寸（MainView 的 frame(minWidth:minHeight:)）
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            mainWindow = w
        }
        stats.reload()
        // 主窗口开着时像普通 app 一样出现在程序坞和 ⌘Tab 里，菜单栏有应用菜单，⌘H 才能隐藏（菜单栏 app 按 ⌘H 系统不理）
        NSApp.setActivationPolicy(.regular)
        // ⌘H 隐藏过的话先取消隐藏
        NSApp.unhide(nil)
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

/// 应用菜单：菜单栏 app 不显示它，但 ⌘H、⌘W、⌘M、⌘Q 和输入框里的 ⌘C / ⌘V / ⌘A / ⌘Z 这些快捷键都要靠它
func installMainMenu() {
    let bar = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let item = NSMenuItem()
        item.submenu = NSMenu(title: title)
        items.forEach { item.submenu?.addItem($0) }
        bar.addItem(item)
    }
    func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }
    submenu("UsageBar", [
        item(L("隐藏 UsageBar"), #selector(NSApplication.hide(_:)), "h"),
        item(L("隐藏其他"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        .separator(),
        item(L("退出"), #selector(NSApplication.terminate(_:)), "q"),
    ])
    submenu(L("编辑"), [
        item(L("撤销"), Selector(("undo:")), "z"),
        item(L("重做"), Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item(L("剪切"), #selector(NSText.cut(_:)), "x"),
        item(L("拷贝"), #selector(NSText.copy(_:)), "c"),
        item(L("粘贴"), #selector(NSText.paste(_:)), "v"),
        item(L("全选"), #selector(NSText.selectAll(_:)), "a"),
    ])
    submenu(L("窗口"), [
        item(L("最小化"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(L("关闭"), #selector(NSWindow.performClose(_:)), "w"),
    ])
    NSApp.mainMenu = bar
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
installMainMenu()
app.run()
