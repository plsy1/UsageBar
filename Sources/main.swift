// UsageBar — 菜单栏显示 Claude / Codex 剩余用量
// 数据来源：
//   Claude: macOS 钥匙串 "Claude Code-credentials" 里的 OAuth token → api.anthropic.com/api/oauth/usage
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 数据模型

struct LimitWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// 主要的周额度（Claude 的 seven_day、Codex 的 7 天窗口）；用量统计按它算「重置以来」
    var weekly = false
    var remaining: Double { max(0, 100 - usedPercent) }
    /// 按设置显示剩余还是已使用（进度条和百分比都跟着变）
    func shown(_ used: Bool = Pref.showUsed) -> Double { used ? min(100, usedPercent) : remaining }
    func shownText(_ used: Bool = Pref.showUsed) -> String {
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
    /// 各窗口里最紧的那个（剩余最少）
    var binding: LimitWindow? { windows.min { $0.remaining < $1.remaining } }
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
        "本机会话记录": ("ローカルのセッション記録", "Local Session Logs"),
        "%d 条请求，最早 %@": ("%d 件、最古 %@", "%d requests since %@"),
        "布局": ("レイアウト", "Layout"),
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
        "正在读取本机会话记录…": ("ローカルのセッション記録を読み込み中…", "Reading local session logs…"),
        "该时间段内没有记录": ("この期間の記録はありません", "No usage in this period"),
        "成本按 models.dev 的 API 价格估算，仅统计本机会话记录": ("コストは models.dev の API 価格による推定で、この Mac のセッション記録のみを集計しています", "Cost is estimated from models.dev API prices and covers only session logs on this Mac"),
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
        "开机启动、语言和主题色": ("ログイン時の起動、言語、テーマカラー", "Launch at login, language and theme color"),
        "额度显示": ("上限の表示", "Limits"),
        "数据来源": ("データソース", "Data Sources"),
        "菜单栏和桌面卡片显示哪些额度、怎么显示": ("メニューバーとカードに表示する上限と表示方法", "Which limits the menu bar and card show, and how"),
        "用量从哪里读取，以及价格表和本机记录": ("使用量の取得元、価格表、ローカルの記録", "Where usage comes from, plus prices and local logs"),
        "显示内容": ("表示内容", "Content"),
        "每家显示最紧的那个额度": ("各サービスで最も残りが少ない上限を表示します", "Each shows its tightest limit"),
        "来源": ("取得元", "Source"),
        "Claude Code 登录（钥匙串）": ("Claude Code のログイン（キーチェーン）", "Claude Code login (Keychain)"),
        "说明": ("説明", "Notes"),
        "额度：用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询。\n\n用量统计：只读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），成本按 models.dev 的 API 价格估算，价格每天更新一次。\n\n所有数据只在这台 Mac 和上述官方服务之间传输。": ("上限：この Mac の Claude Code と Codex のログイン情報を使って、Anthropic と OpenAI の使用量 API に問い合わせます。\n\n使用量の統計：この Mac のセッション記録（~/.claude/projects と ~/.codex/sessions）だけを読み取り、コストは models.dev の API 価格で推定します。価格は 1 日 1 回更新されます。\n\nデータはこの Mac と上記の公式サービスの間でのみやり取りされます。", "Limits: queried from Anthropic's and OpenAI's usage endpoints using the Claude Code and Codex logins on this Mac.\n\nUsage statistics: read only from local session logs (~/.claude/projects and ~/.codex/sessions); cost is estimated from models.dev API prices, refreshed once a day.\n\nData only travels between this Mac and those official services."),
        "主题色": ("テーマカラー", "Theme Color"),
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
                                             weekly: key == "seven_day"))
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
                        weekly: seconds == 7 * 86400))
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
                                             weekly: seconds == 7 * 86400))
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
    static let language = "language"           // auto / zh / ja / en
    static let displayMode = "displayMode"     // remaining / used
    static let cardLayout = "cardLayout"       // horizontal / vertical / compact
    static let resetStyle = "cardResetStyle"   // hidden / relative（多久后）/ absolute（几点）
    static var showUsed: Bool { UserDefaults.standard.string(forKey: displayMode) == "used" }

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCard: true, background: "none", textColor: "white", scale: 1.0, opacity: 1.0, bgOpacity: 1.0,
            showReset: true, showClaude: true, showCodex: true, refreshMinutes: 5, statsRefreshMinutes: 5, menuLabel: "short", language: "auto", displayMode: "remaining", cardLayout: "horizontal", resetStyle: "relative",
        ])
        // 旧版只有「显示重置时间」开关：关掉过的人沿用为「不显示」
        // 只看用户真正保存过的值（注册的默认值不算）
        let d = UserDefaults.standard
        let saved = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.usagebar") ?? [:]
        if saved[resetStyle] == nil, saved[showReset] as? Bool == false { d.set("hidden", forKey: resetStyle) }
    }
    static func visible(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: name == "Claude" ? showClaude : showCodex)
    }
}

/// 设置里每一行右侧的滑块 + 百分比
struct PercentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var body: some View {
        LabeledContent(title) {
            Slider(value: $value, in: range, step: step) { EmptyView() }
                .frame(width: 160)
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

/// 设置页的版式：顶部标题栏，下面左边是设置项，右边是预览或状态
struct SettingsPage<Main: View, Side: View>: View {
    let tab: MainTab
    let subtitle: String
    let main: Main
    let side: Side

    init(_ tab: MainTab, _ subtitle: String, @ViewBuilder main: () -> Main, @ViewBuilder side: () -> Side) {
        self.tab = tab; self.subtitle = subtitle; self.main = main(); self.side = side()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            HStack(alignment: .top, spacing: 0) {
                main.frame(width: 470)
                side.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 右栏的小标题 + 圆角面板
struct SidePanel<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            content
        }
        .padding(.top, 20).padding(.trailing, 30)
    }
}

struct GeneralSettings: View {
    let updater: Updater
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage("statsChartColor") var chartColor = "pink"
    @State var launchAtLogin = LoginItem.status == .enabled
    @State var needsApproval = LoginItem.status == .requiresApproval

    var body: some View {
        SettingsPage(.general, L("开机启动、语言和主题色")) {
            Form {
                Section {
                    Toggle(L("开机启动"), isOn: Binding(get: { launchAtLogin }, set: { on in
                        LoginItem.set(on)
                        launchAtLogin = LoginItem.status == .enabled
                        needsApproval = LoginItem.status == .requiresApproval
                    }))
                    if needsApproval {
                        Text(L("需要在 系统设置 → 通用 → 登录项 中允许 UsageBar"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Picker(L("语言"), selection: $language) {
                        Text(L("跟随系统")).tag("auto")
                        Divider()
                        Text("中文").tag("zh")
                        Text("日本語").tag("ja")
                        Text("English").tag("en")
                    }
                    // 主题色：统计图、开关、侧边栏和主窗口里的选中标记都用它
                    LabeledContent(L("主题色")) {
                        HStack(spacing: 9) {
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
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } side: {
            SidePanel(L("关于")) { AboutCard(updater: updater) }
        }
    }
}

/// 「额度显示」：菜单栏和桌面卡片显示哪些额度、怎么显示（卡片的外观在「桌面卡片」页）
struct LimitsSettings: View {
    @ObservedObject var model: UsageModel
    @AppStorage(Pref.menuLabel) var menuLabel = "short"
    @AppStorage(Pref.displayMode) var displayMode = "remaining"
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true
    @AppStorage(Pref.refreshMinutes) var refreshMinutes = 5

    var shown: [ProviderUsage] { model.results.filter { $0.name == "Claude" ? showClaude : showCodex } }
    var used: Bool { displayMode == "used" }

    /// 和菜单栏上一样的文字
    var title: String {
        let parts = shown.map { u -> String in
            let name = menuLabel == "full" ? u.name : u.name == "Claude" ? "Cc" : "Cx"
            return "\(name) " + (u.binding.map { "\(Int($0.shown(used).rounded()))%" } ?? "–")
        }
        return parts.isEmpty ? "UsageBar" : parts.joined(separator: "  ")
    }

    var body: some View {
        SettingsPage(.menuBar, L("菜单栏和桌面卡片显示哪些额度、怎么显示")) {
            Form {
                Section(L("显示内容")) {
                    Picker(L("显示数值"), selection: $displayMode) {
                        Text(L("剩余")).tag("remaining")
                        Text(L("已使用")).tag("used")
                    }
                    .pickerStyle(.segmented)
                    Toggle("Claude", isOn: $showClaude)
                    Toggle("Codex", isOn: $showCodex)
                }
                Section {
                    Picker(L("名称"), selection: $menuLabel) {
                        Text(L("简写（Cc / Cx）")).tag("short")
                        Text(L("全名（Claude / Codex）")).tag("full")
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text(L("菜单栏"))
                } footer: {
                    Text(L("每家显示最紧的那个额度")).font(.callout).foregroundStyle(.secondary)
                }
                Section(L("刷新")) {
                    Picker(L("刷新间隔"), selection: $refreshMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } side: {
            SidePanel(L("预览")) {
                VStack(alignment: .trailing, spacing: 6) {
                    // 模拟一段菜单栏
                    HStack(spacing: 14) {
                        Spacer()
                        Text(title).font(.system(size: 13, weight: .medium).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                        Text(Date().formatted(.dateTime.hour().minute())).monospacedDigit()
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Rectangle().fill(Color.primary.opacity(0.05)))
                    // 点开后的菜单
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(shown, id: \.name) { u in
                            MenuUsageBlock(u: u, used: used).padding(.horizontal, -2)
                            Divider().padding(.vertical, 3)
                        }
                        Text(L("更新于 %@", Date().formatted(.dateTime.hour().minute())))
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
                        ForEach([("arrow.clockwise", L("立即刷新")), ("eye.slash", L("隐藏桌面卡片")),
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
                    .padding(.trailing, 40)
                }
            }
        }
    }
}

/// 「数据来源」：各家连接状态、价格表、本机记录
struct DataSettings: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var stats: StatsStore
    @AppStorage(Pref.statsRefreshMinutes) var statsRefreshMinutes = 5

    var body: some View {
        SettingsPage(.data, L("用量从哪里读取，以及价格表和本机记录")) {
            Form {
                provider("Claude", source: L("Claude Code 登录（钥匙串）"))
                provider("Codex", source: "~/.codex/auth.json")
                Section(L("用量统计")) {
                    LabeledContent(L("价格表")) {
                        HStack(spacing: 10) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Pricing.updatedAt.map { "models.dev · " + L("更新于 %@", shortDate($0)) } ?? L("未获取"))
                                if Pricing.downloadFailed && !stats.loading {
                                    Text(L("更新失败，继续使用旧价格")).font(.caption)
                                }
                            }
                            .foregroundStyle(.secondary)
                            if stats.loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(L("立即更新")) { stats.reload(forcePrices: true) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    LabeledContent(L("本机会话记录")) {
                        Text(stats.all.last.map { L("%d 条请求，最早 %@", stats.all.count, shortDate($0.time)) } ?? L("正在读取本机会话记录…"))
                            .foregroundStyle(.secondary)
                    }
                    Picker(L("刷新间隔（后台增量更新）"), selection: $statsRefreshMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } side: {
            SidePanel(L("说明")) {
                Text(L("额度：用本机 Claude Code 和 Codex 的登录信息，向 Anthropic 和 OpenAI 的用量接口查询。\n\n用量统计：只读取本机的会话记录（~/.claude/projects 和 ~/.codex/sessions），成本按 models.dev 的 API 价格估算，价格每天更新一次。\n\n所有数据只在这台 Mac 和上述官方服务之间传输。"))
                    .font(.callout).foregroundStyle(.secondary)
                    // 宽度可以收缩但有下限，否则会按最窄宽度算出极高的最小高度
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 300, maxWidth: 420, alignment: .leading)
                    .padding(16)
                    .modifier(Panel())
            }
        }
    }

    func provider(_ name: String, source: String) -> some View {
        Section(name) {
            LabeledContent(L("状态")) {
                Text(status(model.results.first { $0.name == name }))
                    .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
            }
            LabeledContent(L("来源")) { Text(source).foregroundStyle(.secondary) }
        }
    }

    func status(_ u: ProviderUsage?) -> String {
        guard let u else { return L("正在获取用量…") }
        if let e = u.error { return e }
        var parts = [L("已连接")]
        if let p = u.plan { parts.append(p) }
        if u.note != nil { parts.append(L("本地缓存")) }
        return parts.joined(separator: " · ")
    }

    func shortDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f.string(from: d)
    }
}

struct CardSettings: View {
    @ObservedObject var model: UsageModel
    @AppStorage(Pref.showCard) var showCard = true
    @AppStorage(Pref.background) var background = "none"
    @AppStorage(Pref.textColor) var textColor = "white"
    @AppStorage(Pref.scale) var scale = 1.0
    @AppStorage(Pref.opacity) var opacity = 1.0
    @AppStorage(Pref.bgOpacity) var bgOpacity = 1.0
    @AppStorage(Pref.resetStyle) var resetStyle = "relative"
    @AppStorage(Pref.cardLayout) var layout = "horizontal"

    /// 卡片实际尺寸：卡片显示着就用桌面上那张的窗口尺寸，否则按布局估算
    var cardSize: CGSize {
        if showCard, model.cardSize.width > 0 { return model.cardSize }
        let base = layout == "horizontal" ? CGSize(width: 476, height: 167)
            : layout == "vertical" ? CGSize(width: 292, height: 295) : CGSize(width: 273, height: 93)
        return CGSize(width: base.width * scale, height: base.height * scale)
    }

    var body: some View {
        SettingsPage(.card, L("布局、外观和大小，改动会实时显示在右边的预览里")) {
            Form {
                Section {
                    Toggle(L("显示桌面卡片"), isOn: $showCard)
                }
                Section {
                    Picker(L("布局"), selection: $layout) {
                        Label(L("左右"), systemImage: "rectangle.split.2x1").tag("horizontal")
                        Label(L("上下"), systemImage: "rectangle.split.1x2").tag("vertical")
                        Label(L("紧凑"), systemImage: "list.bullet").tag("compact")
                    }
                    .pickerStyle(.segmented)
                    PercentSlider(title: L("大小"), value: $scale, range: 0.8...1.6, step: 0.1)
                }
                .disabled(!showCard)
                Section {
                    Picker(L("背景"), selection: $background) {
                        Text(L("无")).tag("none")
                        Text(L("深色毛玻璃")).tag("dark")
                        Text(L("浅色毛玻璃")).tag("light")
                    }
                    PercentSlider(title: L("毛玻璃浓度"), value: $bgOpacity, range: 0.1...1.0, step: 0.05)
                        .disabled(background == "none")
                    Picker(L("文字颜色"), selection: $textColor) {
                        Text(L("白色")).tag("white")
                        Text(L("黑色")).tag("black")
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(!showCard)
                Section {
                    PercentSlider(title: L("整体不透明度"), value: $opacity, range: 0.3...1.0, step: 0.05)
                    Picker(L("重置时间"), selection: $resetStyle) {
                        Text(L("不显示")).tag("hidden")
                        Text(L("剩余时间")).tag("relative")
                        Text(L("具体时间")).tag("absolute")
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(!showCard)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } side: {
            SidePanel(L("预览")) {
                GeometryReader { g in
                    // 预览底色模拟壁纸：白字配深色，黑字配浅色
                    let dark = textColor == "white"
                    let fit = min(1, (g.size.width - 48) / cardSize.width, (g.size.height - 48) / cardSize.height)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: dark ? [Color(white: 0.32), Color(white: 0.14)] : [Color(white: 0.92), Color(white: 0.78)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        CardView(model: model)
                            .allowsHitTesting(false)
                            .scaleEffect(fit)
                            // scaleEffect 只缩画面不缩占位，占位也按缩放后的尺寸来，免得撑出预览框
                            .frame(width: cardSize.width * fit, height: cardSize.height * fit)
                    }
                    .opacity(showCard ? 1 : 0.4)
                }
                .frame(height: 420)
                Text(L("拖动桌面上的卡片可以移动位置，右键有更多操作"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 通用页右栏的「关于」
struct AboutCard: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("UsageBar").font(.title2.weight(.semibold))
            Text(L("版本 %@", updater.currentVersion))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("在菜单栏和桌面显示 Claude 与 Codex 的剩余用量"))
                .font(.callout).multilineTextAlignment(.center)
            Link("github.com/plsy1/UsageBar", destination: URL(string: "https://github.com/plsy1/UsageBar")!)
                .font(.callout)
            Divider().padding(.vertical, 6)
            updateSection
        }
        .padding(28)
        .frame(maxWidth: 460)
        .modifier(Panel())
    }

    /// 检查更新 / 有新版 / 下载中 / 失败
    @ViewBuilder var updateSection: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在检查…")).foregroundStyle(.secondary) }
        case .downloading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("正在下载并安装…")).foregroundStyle(.secondary) }
        case .available(let v):
            VStack(spacing: 10) {
                Text(L("发现新版本 %@", v)).font(.callout.weight(.semibold))
                if let notes = updater.release?.notes {
                    Text(Self.summary(notes)).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(L("更新并重启")) { updater.install() }.buttonStyle(.borderedProminent)
                    if let page = updater.release?.page { Link(L("查看详情"), destination: page).font(.callout) }
                }
            }
        case .failed(let msg):
            VStack(spacing: 8) {
                Text(L("更新失败：%@", msg)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(L("重试")) { updater.check() }
                    Link(L("前往下载页"), destination: Updater.releasesPage).font(.callout)
                }
            }
        case .upToDate:
            VStack(spacing: 8) {
                Text(L("已是最新版本")).font(.callout).foregroundStyle(.secondary)
                Button(L("检查更新")) { updater.check() }
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
    case stats, general, menuBar, card, data
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return L("用量统计")
        case .general: return L("通用")
        case .menuBar: return L("额度显示")
        case .card: return L("桌面卡片")
        case .data: return L("数据来源")
        }
    }
    var symbol: String {
        switch self {
        case .stats: return "chart.bar.xaxis"
        case .general: return "gearshape"
        case .menuBar: return "gauge.with.dots.needle.50percent"
        case .card: return "rectangle.on.rectangle"
        case .data: return "cylinder.split.1x2"
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
                    ForEach([MainTab.general, .menuBar, .card, .data]) { row($0) }
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .modifier(HideSidebarToggle())
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch nav.tab {
                case .stats: StatsView(store: stats)
                case .general: GeneralSettings(updater: updater)
                case .menuBar: LimitsSettings(model: model)
                case .card: CardSettings(model: model)
                case .data: DataSettings(model: model, stats: stats)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .top)  // 内容顶到窗口最上面，不再空出标题栏那一条
        }
        // 主题色：主窗口里的开关、分段按钮、选中标记都用它（桌面卡片和菜单栏保持单色）
        // NavigationSplitView 会自带一条显示窗口标题的工具栏，整条隐藏，只留左上角三个按钮
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 1120, minHeight: 700)  // 16:10，所有页面在这个尺寸下都能完整显示
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
    var onOpen: () -> Void = {}
    var onCardSettings: () -> Void = {}
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack {
                Text(w.label).font(.system(size: 12 * s))
                Spacer()
                Text(w.shownText(used))
                    .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.25))
                    Capsule().fill(Color.primary.opacity(0.9)).frame(width: g.size.width * w.shown(used) / 100)
                }
            }
            .frame(height: 4 * s)
            if showReset, w.resetsAt != nil {
                Text(resetText(w.resetsAt, style: resetStyle)).font(.system(size: 10 * s)).foregroundStyle(.secondary)
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
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage(Pref.displayMode) var displayMode = "remaining"
    @AppStorage(Pref.cardLayout) var layout = "horizontal"

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
            switch layout {
            case "vertical":
                VStack(alignment: .leading, spacing: 20 * s) { ForEach(shown, id: \.name, content: column) }
            case "compact":
                VStack(alignment: .leading, spacing: 6 * s) { ForEach(shown, id: \.name, content: compactRow) }
            default:
                HStack(alignment: .top, spacing: 24 * s) { ForEach(shown, id: \.name, content: column) }
            }
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
            Button { model.onHide() } label: { Label(L("隐藏桌面卡片"), systemImage: "eye.slash") }
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
                UsageRow(w: w, s: s, showReset: resetStyle != "hidden", used: used, resetStyle: resetStyle)
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
        HStack(alignment: .firstTextBaseline, spacing: 14 * s) {
            Text(u.name).font(.system(size: 13 * s, weight: .semibold))
                .frame(width: 54 * s, alignment: .leading)
            if let e = u.error, u.windows.isEmpty {
                Text(e).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 260 * s, alignment: .leading)
            }
            ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
                    Text(w.label).font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    Text(w.shownText(used)).font(.system(size: 12 * s, weight: .medium).monospacedDigit())
                }
            }
        }
    }
}

/// 菜单里每家的用量区块：名称、套餐，各额度一行加圆角进度条
struct MenuUsageBlock: View {
    let u: ProviderUsage
    let used: Bool
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
                UsageRow(w: w, s: 1.08, showReset: true, used: used)
            }
            if let n = u.note {
                Text(n).font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(width: 290, alignment: .leading)
    }
}

/// 贴在桌面层的卡片窗口：在所有桌面空间显示，可拖动，位置自动记住
final class CardWindow: NSWindow {
    weak var model: UsageModel?

    init(model: UsageModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: CardView(model: model))
        host.sizingOptions = .preferredContentSize
        contentViewController = host
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false  // 透明区域也能拖动
        isMovableByWindowBackground = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        // 默认放到主屏右上角
        if !setFrameUsingName("UsageCard"), let s = NSScreen.screens.first?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: s.maxX - CardWindow.defaultWidth - 24, y: s.maxY - 16))
        }
        setFrameAutosaveName("UsageCard")
    }
    /// 每家一栏的宽度；两栏并排时卡片约 500 宽
    static let column: CGFloat = 210
    static let wideColumn: CGFloat = 260
    static let defaultWidth: CGFloat = column * 2 + 24 + 32
    override var canBecomeKey: Bool { false }

    /// 内容变高/变矮时保持左上角不动（AppKit 默认保持左下角）
    override func setFrame(_ r: NSRect, display: Bool) {
        var r = r
        if frame.height > 0, r.origin == frame.origin, r.height != frame.height {
            r.origin.y = frame.maxY - r.height
        }
        super.setFrame(r, display: display)
        // 尺寸变了就告诉设置页预览；放到下一轮，免得在布局途中改发布的值
        let size = frame.size
        DispatchQueue.main.async { [weak model] in
            if let model, model.cardSize != size { model.cardSize = size }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = UsageModel()
    var card: CardWindow?
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

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        // install.sh 从旧版（LaunchAgent 自启）升级时会带上这个参数
        if CommandLine.arguments.contains("--enable-login-item") { LoginItem.set(true) }
        lastLang = I18n.lang
        item.button?.title = "Cc …  Cx …"
        model.onRefresh = { [weak self] in self?.refresh() }
        model.onHide = { [weak self] in self?.toggleCard() }
        model.onOpen = { [weak self] in self?.openApp() }
        model.onCardSettings = { [weak self] in self?.openMain(.card) }
        if showCard { setCardVisible(true) }
        rebuildMenu()
        refresh()
        scheduleTimer()
        // 统计在后台先读好，打开窗口时不用等；之后按自己的间隔增量更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.stats.reload() }
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
            }
        }
    }

    func setCardVisible(_ on: Bool) {
        if on {
            if card == nil { card = CardWindow(model: model) }
            card?.orderFront(nil)
        } else {
            card?.orderOut(nil)
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
        if UserDefaults.standard.integer(forKey: Pref.refreshMinutes) != timerMinutes { scheduleTimer() }
        if UserDefaults.standard.integer(forKey: Pref.statsRefreshMinutes) != statsTimerMinutes { scheduleStatsTimer() }
        if (card?.isVisible ?? false) != showCard { setCardVisible(showCard) }
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
    @objc func openUpdate() { openMain(.general) }

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
            w.isMovableByWindowBackground = true  // 标题栏透明后，空白处也能拖动窗口
            w.isReleasedWhenClosed = false
            // 固定 16:10 的宽屏比例，拖动缩放时保持形状
            w.contentAspectRatio = NSSize(width: 16, height: 10)
            w.setContentSize(NSSize(width: 1280, height: 800))
            w.center()
            w.setFrameAutosaveName("MainWindow")
            mainWindow = w
        }
        stats.reload()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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
        for (i, u) in results.filter({ Pref.visible($0.name) }).enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let short = full ? "\(u.name) " : u.name == "Claude" ? "Cc " : "Cx "
            s.append(NSAttributedString(string: short, attributes: [.font: font]))
            if let b = u.binding {
                s.append(NSAttributedString(string: "\(Int(b.shown().rounded()))%", attributes: [.font: font]))
            } else {
                s.append(NSAttributedString(string: "–", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        item.button?.attributedTitle = s.length > 0 ? s : NSAttributedString(string: "UsageBar", attributes: [.font: font])
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
        for u in results where Pref.visible(u.name) {
            let host = NSHostingView(rootView: MenuUsageBlock(u: u, used: Pref.showUsed))
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
        add(showCard ? L("隐藏桌面卡片") : L("显示桌面卡片"), showCard ? "eye.slash" : "eye", #selector(toggleCard))
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
                print("  \(w.label.padding(toLength: 10, withPad: " ", startingAt: 0))\(bar(w.shown())) \(w.shownText())  \(resetText(w.resetsAt))")
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
