// UsageBar — 菜单栏显示 Claude / Codex 剩余用量
// 数据来源：
//   Claude: macOS 钥匙串 "Claude Code-credentials" 里的 OAuth token → api.anthropic.com/api/oauth/usage
//   Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage，失败时退回最近一次会话日志里的 rate_limits

import AppKit
import SwiftUI

// MARK: - 数据模型

struct LimitWindow {
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    var remaining: Double { max(0, 100 - usedPercent) }
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
        let loginHint = "在终端运行 claude auth login 登录一次"
        guard var creds = readCreds(), let oauth = creds["claudeAiOauth"] as? [String: Any] else {
            u.error = "读不到 Claude Code 登录信息 · \(loginHint)"; return u
        }
        u.plan = oauth["subscriptionType"] as? String

        let expiresAt = (oauth["expiresAt"] as? Double ?? 0) / 1000
        var refreshed = false
        if expiresAt < Date().timeIntervalSince1970 + 60 {
            refreshed = await refresh(&creds)
            if !refreshed { u.error = "Claude Code 登录已失效 · \(loginHint)"; return u }
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
                u.error = status == 401 ? "Claude Code 登录已失效 · \(loginHint)"
                                        : "请求失败（HTTP \(status)）"
                return u
            }
            let keys = order.filter { json[$0] != nil } + json.keys.filter { !order.contains($0) }.sorted()
            for key in keys {
                guard let w = json[key] as? [String: Any], let util = w["utilization"] as? Double else { continue }
                u.windows.append(LimitWindow(label: labels[key] ?? key, usedPercent: util,
                                             resetsAt: (w["resets_at"] as? String).flatMap(parseISODate)))
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
        case ..<(6 * 3600): return "\(Int(seconds / 3600)) 小时"
        case (6 * 86400)...(8 * 86400): return "本周"
        default: return "\(Int(seconds / 86400)) 天"
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
                    u.windows.append(LimitWindow(
                        label: windowLabel(seconds: w["limit_window_seconds"] as? Double ?? 0),
                        usedPercent: used,
                        resetsAt: (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }))
                }
                return u
            }
            u.note = status == 401 ? "登录过期，显示本地缓存（打开 Codex 会自动刷新）"
                                   : "接口请求失败（HTTP \(status)），显示本地缓存"
        }
        // 退回：最近一次会话日志里的 rate_limits
        if let (rl, mtime) = latestLocalRateLimits() {
            u.plan = u.plan ?? rl["plan_type"] as? String
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                // 已经过了重置时间的窗口，用量视为归零
                let expired = reset.map { $0 < Date() } ?? false
                u.windows.append(LimitWindow(label: windowLabel(seconds: (w["window_minutes"] as? Double ?? 0) * 60),
                                             usedPercent: expired ? 0 : used, resetsAt: expired ? nil : reset))
            }
            let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
            u.note = (u.note ?? "本地缓存") + " · 数据时间 \(f.string(from: mtime))"
        } else if u.windows.isEmpty {
            u.error = "读不到 Codex 登录信息或会话记录"
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

func bar(_ remaining: Double, width: Int = 12) -> String {
    let filled = Int((remaining / 100 * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, d.timeIntervalSinceNow)
    let days = Int(s) / 86400, hours = Int(s) % 86400 / 3600, mins = Int(s) % 3600 / 60
    let rel = days > 0 ? "\(days)天\(hours)小时" : hours > 0 ? "\(hours)小时\(mins)分" : "\(mins)分钟"
    let f = DateFormatter(); f.dateFormat = days > 0 ? "M/d HH:mm" : "HH:mm"
    return "\(rel)后重置（\(f.string(from: d))）"
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
    static let menuLabel = "menuLabel"         // short / full

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCard: true, background: "none", textColor: "white", scale: 1.0, opacity: 1.0, bgOpacity: 1.0,
            showReset: true, showClaude: true, showCodex: true, refreshMinutes: 5, menuLabel: "short",
        ])
    }
    static func visible(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: name == "Claude" ? showClaude : showCodex)
    }
}

struct SettingsView: View {
    @AppStorage(Pref.showCard) var showCard = true
    @AppStorage(Pref.background) var background = "none"
    @AppStorage(Pref.textColor) var textColor = "white"
    @AppStorage(Pref.scale) var scale = 1.0
    @AppStorage(Pref.opacity) var opacity = 1.0
    @AppStorage(Pref.bgOpacity) var bgOpacity = 1.0
    @AppStorage(Pref.showReset) var showReset = true
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true
    @AppStorage(Pref.refreshMinutes) var refreshMinutes = 5
    @AppStorage(Pref.menuLabel) var menuLabel = "short"

    var body: some View {
        Form {
            Section("桌面卡片") {
                Toggle("显示桌面卡片", isOn: $showCard)
                Picker("背景", selection: $background) {
                    Text("无").tag("none")
                    Text("深色毛玻璃").tag("dark")
                    Text("浅色毛玻璃").tag("light")
                }
                Picker("文字颜色", selection: $textColor) {
                    Text("白色").tag("white")
                    Text("黑色").tag("black")
                }
                LabeledContent("毛玻璃浓度") {
                    Slider(value: $bgOpacity, in: 0.1...1.0, step: 0.05) { EmptyView() }
                    Text("\(Int((bgOpacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                .disabled(background == "none")
                LabeledContent("大小") {
                    Slider(value: $scale, in: 0.8...1.6, step: 0.1) { EmptyView() }
                    Text("\(Int((scale * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                LabeledContent("整体不透明度") {
                    Slider(value: $opacity, in: 0.3...1.0, step: 0.05) { EmptyView() }
                    Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Toggle("显示重置时间", isOn: $showReset)
            }
            Section("菜单栏") {
                Picker("名称", selection: $menuLabel) {
                    Text("简写（Cc / Cx）").tag("short")
                    Text("全名（Claude / Codex）").tag("full")
                }
            }
            Section("显示内容（卡片和菜单栏）") {
                Toggle("Claude", isOn: $showClaude)
                Toggle("Codex", isOn: $showCodex)
            }
            Section("刷新") {
                Picker("自动刷新间隔", selection: $refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}

// MARK: - 桌面卡片

final class UsageModel: ObservableObject {
    @Published var results: [ProviderUsage] = []
    @Published var lastUpdate: Date?
    var onRefresh: () -> Void = {}
    var onHide: () -> Void = {}
    var onSettings: () -> Void = {}
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3 * s) {
            HStack {
                Text(w.label).font(.system(size: 12 * s))
                Spacer()
                Text("剩 \(Int(w.remaining.rounded()))%")
                    .font(.system(size: 12 * s, weight: .medium).monospacedDigit())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.25))
                    Capsule().fill(Color.primary.opacity(0.9)).frame(width: g.size.width * w.remaining / 100)
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

    var body: some View {
        let s = CGFloat(scale)
        let white = textColor == "white"
        let shown = model.results.filter { $0.name == "Claude" ? showClaude : showCodex }
        VStack(alignment: .leading, spacing: 14 * s) {
            if model.results.isEmpty {
                Text("正在获取用量…").font(.system(size: 12 * s)).foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.name) { u in
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
                        UsageRow(w: w, s: s, showReset: showReset)
                    }
                    if let n = u.note {
                        Text(n).font(.system(size: 10 * s)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let t = model.lastUpdate {
                Text("更新于 \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10 * s)).foregroundStyle(.tertiary)
            }
        }
        .padding(16 * s)
        .frame(width: CardWindow.width * s, alignment: .leading)
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
            Button("立即刷新") { model.onRefresh() }
            Button("设置…") { model.onSettings() }
            Button("隐藏桌面卡片") { model.onHide() }
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
            setFrameTopLeftPoint(NSPoint(x: s.maxX - CardWindow.width - 24, y: s.maxY - 16))
        }
        setFrameAutosaveName("UsageCard")
    }
    static let width: CGFloat = 250
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
    var settingsWindow: NSWindow?
    var showCard: Bool {
        get { UserDefaults.standard.bool(forKey: Pref.showCard) }
        set { UserDefaults.standard.set(newValue, forKey: Pref.showCard) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        item.button?.title = "Cc …  Cx …"
        model.onRefresh = { [weak self] in self?.refresh() }
        model.onHide = { [weak self] in self?.toggleCard() }
        model.onSettings = { [weak self] in self?.openSettings() }
        if showCard { setCardVisible(true) }
        rebuildMenu()
        refresh()
        scheduleTimer()
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

    func syncPrefs() {
        if UserDefaults.standard.integer(forKey: Pref.refreshMinutes) != timerMinutes { scheduleTimer() }
        if (card?.isVisible ?? false) != showCard { setCardVisible(showCard) }
        updateTitle()
        rebuildMenu()
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "UsageBar 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
                s.append(NSAttributedString(string: "\(Int(b.remaining.rounded()))%", attributes: [.font: font]))
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

        func info(_ a: NSAttributedString) {
            let mi = NSMenuItem(); mi.attributedTitle = a; mi.isEnabled = false; menu.addItem(mi)
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
                line.append(NSAttributedString(string: bar(w.remaining),
                                               attributes: [.font: mono]))
                line.append(NSAttributedString(string: String(format: " 剩 %3d%%", Int(w.remaining.rounded())),
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
        if loading { status = "正在刷新…" }
        else if let t = lastUpdate {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status = "更新于 \(f.string(from: t)) · 每 \(timerMinutes) 分钟自动刷新"
        } else { status = "" }
        if !status.isEmpty { info(NSAttributedString(string: status, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])) }

        let r = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        let c = NSMenuItem(title: "显示桌面卡片", action: #selector(toggleCard), keyEquivalent: "")
        c.target = self
        c.state = showCard ? .on : .off
        menu.addItem(c)
        let st = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","); st.target = self
        menu.addItem(st)
        let q = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
        item.menu = menu
    }
}

// 命令行模式：UsageBar --print，直接在终端打印用量
if CommandLine.arguments.contains("--print") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        for u in [await Claude.fetch(), await Codex.fetch()] {
            print("\(u.name)\(u.plan.map { " (\($0))" } ?? "")")
            if let e = u.error { print("  ⚠︎ \(e)") }
            for w in u.windows {
                print("  \(w.label.padding(toLength: 10, withPad: " ", startingAt: 0))\(bar(w.remaining)) 剩 \(Int(w.remaining.rounded()))%  \(resetText(w.resetsAt))")
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
