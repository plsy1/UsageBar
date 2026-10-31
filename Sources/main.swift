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
        // 卡片和菜单
        "剩 %d%%": ("残り %d%%", "%d%% left"),
        "已用 %d%%": ("使用済み %d%%", "%d%% used"),
        "显示数值": ("表示する値", "Show"),
        "剩余": ("残り", "Remaining"),
        "已使用": ("使用済み", "Used"),
        "正在获取用量…": ("使用量を取得中…", "Fetching usage…"),
        "更新于 %@": ("更新 %@", "Updated %@"),
        "正在刷新…": ("更新中…", "Refreshing…"),
        "更新于 %@ · 每 %d 分钟自动刷新": ("更新 %@ · %d 分ごとに自動更新", "Updated %@ · auto-refresh every %d min"),
        "立即刷新": ("今すぐ更新", "Refresh Now"),
        "设置…": ("設定…", "Settings…"),
        "隐藏桌面卡片": ("デスクトップカードを隠す", "Hide Desktop Card"),
        "显示桌面卡片": ("デスクトップカードを表示", "Show Desktop Card"),
        "退出": ("終了", "Quit"),
        // 设置窗口
        "通用": ("一般", "General"),
        "设置": ("設定", "Settings"),
        "语言、显示方式和刷新频率": ("言語、表示方法、更新頻度", "Language, display and refresh frequency"),
        "布局、外观和大小，改动会实时显示在右边的预览里": ("レイアウト、外観、サイズ。変更は右のプレビューにすぐ反映されます", "Layout, look and size. Changes show up in the preview on the right"),
        "菜单栏上显示的内容，以及点开后的菜单": ("メニューバーの表示と、クリックしたときのメニュー", "What the menu bar shows, and the menu that opens from it"),
        "每家显示最紧的那个额度；显示剩余还是已使用、显示哪几家在「通用」里设置": ("各サービスで最も残りが少ない上限を表示します。残り / 使用済みや表示するサービスは「一般」で設定します", "Each shows its tightest limit. Remaining vs. used and which services to show are set in General"),
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
        "用量统计…": ("使用量の統計…", "Usage Statistics…"),
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
        "显示重置时间": ("リセット時刻を表示", "Show Reset Time"),
        "菜单栏": ("メニューバー", "Menu Bar"),
        "名称": ("表示名", "Labels"),
        "简写（Cc / Cx）": ("略称（Cc / Cx）", "Short (Cc / Cx)"),
        "全名（Claude / Codex）": ("フルネーム（Claude / Codex）", "Full (Claude / Codex)"),
        "显示内容（卡片和菜单栏）": ("表示する項目（カードとメニューバー）", "Show (Card and Menu Bar)"),
        "刷新": ("更新", "Refresh"),
        "额度": ("上限", "Limits"),
        "用量统计（后台增量更新）": ("使用量の統計（バックグラウンドで差分更新）", "Usage statistics (updated in the background)"),
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
        u.plan = oauth["subscriptionType"] as? String

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
                u.plan = json["plan_type"] as? String
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
            u.plan = u.plan ?? rl["plan_type"] as? String
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

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, d.timeIntervalSinceNow)
    let days = Int(s) / 86400, hours = Int(s) % 86400 / 3600, mins = Int(s) % 3600 / 60
    let rel = days > 0 ? L("%d天%d小时", days, hours) : hours > 0 ? L("%d小时%d分", hours, mins) : L("%d分钟", mins)
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
    static var showUsed: Bool { UserDefaults.standard.string(forKey: displayMode) == "used" }

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCard: true, background: "none", textColor: "white", scale: 1.0, opacity: 1.0, bgOpacity: 1.0,
            showReset: true, showClaude: true, showCodex: true, refreshMinutes: 5, statsRefreshMinutes: 5, menuLabel: "short", language: "auto", displayMode: "remaining", cardLayout: "horizontal",
        ])
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
            .padding(.horizontal, 30).padding(.top, 26)
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
    @ObservedObject var model: UsageModel
    @ObservedObject var stats: StatsStore
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage(Pref.refreshMinutes) var refreshMinutes = 5
    @AppStorage(Pref.statsRefreshMinutes) var statsRefreshMinutes = 5
    @AppStorage(Pref.displayMode) var displayMode = "remaining"
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true
    @State var launchAtLogin = LoginItem.status == .enabled
    @State var needsApproval = LoginItem.status == .requiresApproval

    var body: some View {
        SettingsPage(.general, L("语言、显示方式和刷新频率")) {
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
                    Picker(L("显示数值"), selection: $displayMode) {
                        Text(L("剩余")).tag("remaining")
                        Text(L("已使用")).tag("used")
                    }
                    .pickerStyle(.segmented)
                }
                Section(L("刷新")) {
                    Picker(L("额度"), selection: $refreshMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                    }
                    Picker(L("用量统计（后台增量更新）"), selection: $statsRefreshMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text(L("%d 分钟", $0)).tag($0) }
                    }
                }
                Section(L("显示内容（卡片和菜单栏）")) {
                    Toggle("Claude", isOn: $showClaude)
                    Toggle("Codex", isOn: $showCodex)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } side: {
            Form {
                Section(L("状态")) {
                    if model.results.isEmpty {
                        Text(L("正在获取用量…")).foregroundStyle(.secondary)
                    }
                    ForEach(model.results, id: \.name) { u in
                        LabeledContent(u.name) { Text(status(u)).multilineTextAlignment(.trailing).foregroundStyle(.secondary) }
                    }
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
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    func status(_ u: ProviderUsage) -> String {
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
    @AppStorage(Pref.showReset) var showReset = true
    @AppStorage(Pref.cardLayout) var layout = "horizontal"

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
                    Toggle(L("显示重置时间"), isOn: $showReset)
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
                    let natural: CGFloat = (layout == "horizontal" ? 476 : layout == "vertical" ? 332 : 273) * scale
                    let fit = min(1, (g.size.width - 48) / natural)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: dark ? [Color(white: 0.32), Color(white: 0.14)] : [Color(white: 0.92), Color(white: 0.78)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        CardView(model: model)
                            .allowsHitTesting(false)
                            .scaleEffect(fit)
                    }
                    .opacity(showCard ? 1 : 0.4)
                }
                .frame(height: 380)
                Text(L("拖动桌面上的卡片可以移动位置，右键有更多操作"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuBarSettings: View {
    @ObservedObject var model: UsageModel
    @AppStorage(Pref.menuLabel) var menuLabel = "short"
    @AppStorage(Pref.displayMode) var displayMode = "remaining"
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true

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
        SettingsPage(.menuBar, L("菜单栏上显示的内容，以及点开后的菜单")) {
            Form {
                Section {
                    Picker(L("名称"), selection: $menuLabel) {
                        Text(L("简写（Cc / Cx）")).tag("short")
                        Text(L("全名（Claude / Codex）")).tag("full")
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(L("每家显示最紧的那个额度；显示剩余还是已使用、显示哪几家在「通用」里设置"))
                        .font(.callout).foregroundStyle(.secondary)
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
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(u.name).font(.system(size: 13, weight: .bold))
                                if let p = u.plan { Text(p).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                            ForEach(Array(u.windows.enumerated()), id: \.offset) { _, w in
                                Text("  " + w.label.padding(toLength: 10, withPad: " ", startingAt: 0) + bar(w.shown(used)) + " " + w.shownText(used))
                                    .font(.system(size: 12, design: .monospaced))
                                if w.resetsAt != nil {
                                    Text("    " + resetText(w.resetsAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Divider().padding(.vertical, 3)
                        }
                        ForEach([L("立即刷新"), L("显示桌面卡片"), L("用量统计…"), L("设置…"), L("退出")], id: \.self) {
                            Text($0).font(.system(size: 13)).padding(.vertical, 1)
                        }
                    }
                    .padding(12)
                    .frame(width: 330, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.trailing, 150)
                }
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("UsageBar").font(.title2.weight(.semibold))
            Text(L("版本 %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .font(.callout).foregroundStyle(.secondary)
            Text(L("在菜单栏和桌面显示 Claude 与 Codex 的剩余用量"))
                .font(.callout).multilineTextAlignment(.center)
            Link("github.com/plsy1/UsageBar", destination: URL(string: "https://github.com/plsy1/UsageBar")!)
                .font(.callout)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 主窗口：左侧边栏切换「用量统计」和各项设置

enum MainTab: String, CaseIterable, Identifiable {
    case stats, general, card, menuBar, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return L("用量统计")
        case .general: return L("通用")
        case .card: return L("桌面卡片")
        case .menuBar: return L("菜单栏")
        case .about: return L("关于")
        }
    }
    var symbol: String {
        switch self {
        case .stats: return "chart.bar.xaxis"
        case .general: return "gearshape"
        case .card: return "rectangle.on.rectangle"
        case .menuBar: return "menubar.rectangle"
        case .about: return "info.circle"
        }
    }
}

final class MainNav: ObservableObject {
    @Published var tab: MainTab = .stats
}

struct MainView: View {
    @ObservedObject var nav: MainNav
    @ObservedObject var stats: StatsStore
    let model: UsageModel
    @AppStorage(Pref.language) var language = "auto"

    var body: some View {
        let _ = language  // 切换语言时重绘
        NavigationSplitView {
            List(selection: Binding<MainTab?>(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) {
                row(.stats)
                Section(L("设置")) {
                    ForEach([MainTab.general, .card, .menuBar, .about]) { row($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch nav.tab {
                case .stats: StatsView(store: stats)
                case .general: GeneralSettings(model: model, stats: stats)
                case .card: CardSettings(model: model)
                case .menuBar: MenuBarSettings(model: model)
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(nav.tab.title)
        }
    }

    func row(_ t: MainTab) -> some View {
        Label(t.title, systemImage: t.symbol).tag(t)
    }
}

// MARK: - 桌面卡片

final class UsageModel: ObservableObject {
    @Published var results: [ProviderUsage] = []
    @Published var lastUpdate: Date?
    var onRefresh: () -> Void = {}
    var onHide: () -> Void = {}
    var onSettings: () -> Void = {}
    var onStats: () -> Void = {}
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
                Text(resetText(w.resetsAt)).font(.system(size: 10 * s)).foregroundStyle(.secondary)
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
    @AppStorage(Pref.showReset) var showReset = true
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
                VStack(alignment: .leading, spacing: 14 * s) { ForEach(shown, id: \.name, content: column) }
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
            Button(L("立即刷新")) { model.onRefresh() }
            Button(L("用量统计…")) { model.onStats() }
            Button(L("设置…")) { model.onSettings() }
            Button(L("隐藏桌面卡片")) { model.onHide() }
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
                UsageRow(w: w, s: s, showReset: showReset, used: used)
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

/// 贴在桌面层的卡片窗口：在所有桌面空间显示，可拖动，位置自动记住
final class CardWindow: NSWindow {
    init(model: UsageModel) {
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
    static let wideColumn: CGFloat = 300
    static let defaultWidth: CGFloat = column * 2 + 24 + 32
    override var canBecomeKey: Bool { false }

    /// 内容变高/变矮时保持左上角不动（AppKit 默认保持左下角）
    override func setFrame(_ r: NSRect, display: Bool) {
        var r = r
        if frame.height > 0, r.origin == frame.origin, r.height != frame.height {
            r.origin.y = frame.maxY - r.height
        }
        super.setFrame(r, display: display)
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
        model.onSettings = { [weak self] in self?.openSettings() }
        model.onStats = { [weak self] in self?.openStats() }
        if showCard { setCardVisible(true) }
        rebuildMenu()
        refresh()
        scheduleTimer()
        // 统计在后台先读好，打开窗口时不用等；之后按自己的间隔增量更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.stats.reload() }
        scheduleStatsTimer()
        // 设置窗口里改了什么，这里同步到卡片显隐、刷新间隔和菜单栏
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncPrefs()
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

    @objc func openSettings() { openMain(.general) }
    @objc func openStats() { openMain(.stats) }

    /// 主窗口：统计和设置都在这里，左侧边栏切换
    func openMain(_ tab: MainTab) {
        nav.tab = tab
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainView(nav: nav, stats: stats, model: model))
            host.sizingOptions = .minSize
            let w = NSWindow(contentViewController: host)
            w.title = "UsageBar"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
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
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

        for u in results where Pref.visible(u.name) {
            let head = NSMutableAttributedString(string: u.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            if let p = u.plan {
                head.append(NSAttributedString(string: "  \(p)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            info(head)
            if let e = u.error {
                info(NSAttributedString(string: "  \(e)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            for w in u.windows {
                let line = NSMutableAttributedString(string: "  " + w.label.padding(toLength: 10, withPad: " ", startingAt: 0),
                                                     attributes: [.font: mono])
                line.append(NSAttributedString(string: bar(w.shown()),
                                               attributes: [.font: mono]))
                line.append(NSAttributedString(string: " " + w.shownText(),
                                               attributes: [.font: mono]))
                info(line)
                if w.resetsAt != nil {
                    info(NSAttributedString(string: "    " + resetText(w.resetsAt),
                                            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
                }
            }
            if let n = u.note {
                info(NSAttributedString(string: "  \(n)", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            menu.addItem(.separator())
        }

        let status: String
        if loading { status = L("正在刷新…") }
        else if let t = lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status = L("更新于 %@ · 每 %d 分钟自动刷新", f.string(from: t), timerMinutes)
        } else { status = "" }
        if !status.isEmpty { info(NSAttributedString(string: status, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])) }

        let r = NSMenuItem(title: L("立即刷新"), action: #selector(refresh), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        let c = NSMenuItem(title: L("显示桌面卡片"), action: #selector(toggleCard), keyEquivalent: "")
        c.target = self
        c.state = showCard ? .on : .off
        menu.addItem(c)
        let sts = NSMenuItem(title: L("用量统计…"), action: #selector(openStats), keyEquivalent: "u"); sts.target = self
        menu.addItem(sts)
        let st = NSMenuItem(title: L("设置…"), action: #selector(openSettings), keyEquivalent: ","); st.target = self
        menu.addItem(st)
        let q = NSMenuItem(title: L("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
