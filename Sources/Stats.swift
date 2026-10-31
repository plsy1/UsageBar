// 用量统计：从本机会话记录算 token 用量和按 API 价格估算的成本
//   Claude: ~/.claude/projects/**/*.jsonl 里 assistant 消息的 message.usage
//   Codex : ~/.codex/sessions/**/*.jsonl 里 token_count 事件的 last_token_usage
//   价格  : models.dev/api.json（每天更新一次，缓存在 ~/Library/Caches）

import AppKit
import SwiftUI
import Charts

// MARK: - 数据

enum Source: String { case claude = "Claude", codex = "Codex" }

struct UsageRecord: Identifiable {
    let id: String
    let time: Date
    let source: Source
    let model: String
    let input: Int        // 不含缓存的新输入
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    var cacheWrite1h = 0  // cacheWrite 里属于 1 小时缓存的部分（Claude 才有），单价是输入的 2 倍
    var cost: Double?
    var tokens: Int { input + output + cacheRead + cacheWrite }
}

// MARK: - 价格（models.dev）

struct Price {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?
    /// 上下文超过 size 后的单价（长上下文加价）
    var tiers: [(size: Int, price: Price)] = []
}

enum Pricing {
    static let providers = ["anthropic", "openai"]
    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.usagebar/models-dev.json")
    }
    private static var table: [String: [String: Price]] = [:]

    /// 读缓存；没有缓存或超过一天就重新下载
    static func load() async {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if mtime.map({ Date().timeIntervalSince($0) > 86400 }) ?? true, let fresh = await download() {
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fresh.write(to: cacheURL)
        }
        guard let d = try? Data(contentsOf: cacheURL),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        var t: [String: [String: Price]] = [:]
        for (provider, models) in json {
            guard let models = models as? [String: Any] else { continue }
            t[provider] = models.compactMapValues { ($0 as? [String: Any]).flatMap(price) }
        }
        table = t
    }

    /// 只留两家的 cost 字段，缓存从 6MB 缩到几十 KB
    static func download() async -> Data? {
        let req = URLRequest(url: URL(string: "https://models.dev/api.json")!, timeoutInterval: 30)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var subset: [String: Any] = [:]
        for p in providers {
            guard let models = (all[p] as? [String: Any])?["models"] as? [String: Any] else { continue }
            subset[p] = models.compactMapValues { ($0 as? [String: Any])?["cost"] }
        }
        return try? JSONSerialization.data(withJSONObject: subset)
    }

    static func price(_ c: [String: Any]) -> Price? {
        guard let i = c["input"] as? Double, let o = c["output"] as? Double else { return nil }
        var p = Price(input: i, output: o, cacheRead: c["cache_read"] as? Double, cacheWrite: c["cache_write"] as? Double)
        for t in c["tiers"] as? [[String: Any]] ?? [] {
            if let size = (t["tier"] as? [String: Any])?["size"] as? Int, let tp = price(t) { p.tiers.append((size, tp)) }
        }
        p.tiers.sort { $0.size < $1.size }
        return p
    }

    static func cost(_ r: UsageRecord) -> Double? {
        let models = table[r.source == .claude ? "anthropic" : "openai"]
        // 带日期后缀的型号（如 -20261001）去掉后缀再找一次
        let base = r.model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        guard var p = models?[r.model] ?? models?[base] else { return nil }
        let prompt = r.input + r.cacheRead + r.cacheWrite
        if let tier = p.tiers.last(where: { prompt > $0.size }) { p = tier.price }
        // models.dev 的 cache_write 是 5 分钟缓存的价格；1 小时缓存按 Anthropic 的规则算输入价的 2 倍
        let write5m = r.cacheWrite - r.cacheWrite1h
        let total = Double(r.input) * p.input + Double(r.output) * p.output
            + Double(r.cacheRead) * (p.cacheRead ?? p.input)
            + Double(write5m) * (p.cacheWrite ?? p.input) + Double(r.cacheWrite1h) * p.input * 2
        return total / 1_000_000
    }
}

// MARK: - 读会话记录

enum LogReader {
    /// 按文件缓存解析结果，刷新时只重读改动过的文件
    private static var cache: [String: (mtime: Date, size: Int, records: [UsageRecord])] = [:]
    private static let lock = NSLock()

    static func read(since: Date) -> [UsageRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs: [(String, Source)] = [(".claude/projects", .claude), (".codex/sessions", .codex),
                                        (".codex/archived_sessions", .codex)]
        var all: [UsageRecord] = []
        lock.lock(); defer { lock.unlock() }
        for (dir, src) in dirs {
            let root = home.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = v?.contentModificationDate ?? .distantPast, size = v?.fileSize ?? 0
                guard mtime >= since else { continue }
                if let c = cache[url.path], c.mtime == mtime, c.size == size { all += c.records; continue }
                let recs = src == .claude ? parseClaude(url) : parseCodex(url)
                cache[url.path] = (mtime, size, recs)
                all += recs
            }
        }
        // 同一请求可能出现在多个文件里（续接的会话会带上旧记录），按 id 去重，留输出最多的那条
        var byID: [String: UsageRecord] = [:]
        for r in all where r.time >= since {
            if let old = byID[r.id], old.output >= r.output { continue }
            byID[r.id] = r
        }
        return Array(byID.values)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 逐行读，先按字节粗筛再解析 JSON（日志里大部分行是对话内容，用不上）
    static func lines(_ url: URL, containing needles: [String], _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let keys = needles.map { Data($0.utf8) }
        for line in data.split(separator: UInt8(ascii: "\n")) where keys.contains(where: { line.range(of: $0) != nil }) {
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { body(obj) }
        }
    }

    static func parseClaude(_ url: URL) -> [UsageRecord] {
        var out: [UsageRecord] = []
        lines(url, containing: ["\"usage\""]) { o in
            guard o["type"] as? String == "assistant",
                  let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>",
                  let ts = (o["timestamp"] as? String).flatMap(iso.date) else { return }
            let id = "\(msg["id"] as? String ?? UUID().uuidString):\(o["requestId"] as? String ?? "")"
            var r = UsageRecord(id: id, time: ts, source: .claude, model: model,
                                input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
            r.cacheWrite1h = min(r.cacheWrite, (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
            out.append(r)
        }
        return out
    }

    static func parseCodex(_ url: URL) -> [UsageRecord] {
        var out: [UsageRecord] = []
        var model = "codex", lastTotal = -1
        lines(url, containing: ["\"token_count\"", "\"turn_context\""]) { o in
            guard let p = o["payload"] as? [String: Any] else { return }
            if o["type"] as? String == "turn_context" { model = p["model"] as? String ?? model; return }
            guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                  total != lastTotal,  // 只更新了额度信息的重复事件
                  let tsString = o["timestamp"] as? String, let ts = iso.date(from: tsString) else { return }
            lastTotal = total
            let cached = last["cached_input_tokens"] as? Int ?? 0
            out.append(UsageRecord(id: "\(tsString)|\(total)", time: ts, source: .codex, model: model,
                                   input: max(0, (last["input_tokens"] as? Int ?? 0) - cached),
                                   output: last["output_tokens"] as? Int ?? 0,
                                   cacheRead: cached, cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0))
        }
        return out
    }
}

// MARK: - 汇总

enum StatsRange: String { case today, week = "7d", month = "30d"
    var days: Int { self == .today ? 1 : self == .week ? 7 : 30 }
    var since: Date { Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: Date()))! }
}

struct Summary {
    var cost = 0.0, requests = 0, tokens = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    init(_ rs: [UsageRecord]) {
        for r in rs {
            cost += r.cost ?? 0; requests += 1; tokens += r.tokens
            input += r.input; output += r.output; cacheRead += r.cacheRead; cacheWrite += r.cacheWrite
        }
    }
    var hitRate: Double? {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }
}

struct ModelRow: Identifiable {
    let id: String
    let source: Source
    let model: String
    let s: Summary
    let priced: Bool
}

struct Bucket: Identifiable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

final class StatsStore: ObservableObject {
    @Published var all: [UsageRecord] = []
    @Published var loading = false
    @Published var updated: Date?

    func reload() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            await Pricing.load()
            var recs = LogReader.read(since: StatsRange.month.since)
            for i in recs.indices { recs[i].cost = Pricing.cost(recs[i]) }
            recs.sort { $0.time > $1.time }
            let result = recs
            await MainActor.run {
                self.all = result
                self.loading = false
                self.updated = Date()
            }
        }
    }
}

// MARK: - 格式

func abbrev(_ n: Int) -> String {
    let d = Double(n)
    switch abs(d) {
    case 1e9...: return String(format: "%.2fB", d / 1e9)
    case 1e6...: return String(format: "%.1fM", d / 1e6)
    case 1e3...: return String(format: "%.1fK", d / 1e3)
    default: return "\(n)"
    }
}

func money(_ v: Double?, digits: Int = 2) -> String {
    v.map { String(format: "$%.\(digits)f", $0) } ?? "—"
}

// MARK: - 窗口

struct StatsView: View {
    @ObservedObject var store: StatsStore
    @AppStorage("statsRange") var rangeRaw = StatsRange.today.rawValue
    @AppStorage("statsSource") var source = "all"
    @AppStorage(Pref.language) var language = "auto"
    @State var tab = "models"

    var range: StatsRange { StatsRange(rawValue: rangeRaw) ?? .today }
    var rows: [UsageRecord] {
        let since = range.since
        return store.all.filter { $0.time >= since && (source == "all" || $0.source.rawValue == source) }
    }

    var body: some View {
        let _ = language  // 切换语言时重绘
        let rows = rows
        let sum = Summary(rows)
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            HStack(spacing: 0) {
                tile(L("估算成本"), money(sum.cost))
                Divider().padding(.vertical, 4)
                tile(L("请求数"), sum.requests.formatted())
                Divider().padding(.vertical, 4)
                tile("Tokens", abbrev(sum.tokens))
                Divider().padding(.vertical, 4)
                tile(L("缓存命中率"), sum.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
            }
            .fixedSize(horizontal: false, vertical: true)  // 不让分隔线把这一行撑高
            .padding(.vertical, 14)
            .modifier(Panel())
            chart(rows)
            Picker("", selection: $tab) {
                Text(L("按模型")).tag("models")
                Text(L("请求明细")).tag("log")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if tab == "models" { modelTable(rows) } else { logTable(rows) }
            Text(L("成本按 models.dev 的 API 价格估算，仅统计本机会话记录"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 680)
        .environment(\.locale, locale)  // 图表坐标的日期跟着界面语言
    }

    var locale: Locale {
        Locale(identifier: ["zh": "zh_CN", "ja": "ja_JP"][I18n.lang] ?? "en_US")
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $rangeRaw) {
                Text(L("今天")).tag(StatsRange.today.rawValue)
                Text(L("7 天")).tag(StatsRange.week.rawValue)
                Text(L("30 天")).tag(StatsRange.month.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $source) {
                Text(L("全部")).tag("all")
                Text("Claude").tag("Claude")
                Text("Codex").tag("Codex")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            if store.loading {
                ProgressView().controlSize(.small)
            } else if let t = store.updated {
                Text(L("更新于 %@", t.formatted(.dateTime.hour().minute().locale(locale))))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button { store.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(L("刷新"))
                .disabled(store.loading)
        }
    }

    func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    func buckets(_ rows: [UsageRecord]) -> [Bucket] {
        let cal = Calendar.current
        let hourly = range == .today
        var sums: [Date: Int] = [:]
        for r in rows {
            let key = hourly ? cal.dateInterval(of: .hour, for: r.time)!.start : cal.startOfDay(for: r.time)
            sums[key, default: 0] += r.tokens
        }
        // 补齐没有用量的时段，曲线才连续
        var out: [Bucket] = []
        var t = range.since
        let end = Date()
        while t <= end {
            out.append(Bucket(date: t, tokens: sums[t] ?? 0))
            t = cal.date(byAdding: hourly ? .hour : .day, value: 1, to: t)!
        }
        return out
    }

    func chart(_ rows: [UsageRecord]) -> some View {
        let unit: Calendar.Component = range == .today ? .hour : .day
        return VStack(alignment: .leading, spacing: 10) {
            Text(range == .today ? L("Tokens · 按小时") : L("Tokens · 按天"))
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if store.loading && store.all.isEmpty {
                Text(L("正在读取本机会话记录…")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart(buckets(rows)) { b in
                    AreaMark(x: .value("t", b.date, unit: unit), y: .value("tokens", b.tokens))
                        .foregroundStyle(Color.primary.opacity(0.08))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", b.date, unit: unit), y: .value("tokens", b.tokens))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let n = v.as(Int.self) { Text(abbrev(n)) } }
                    }
                }
                .frame(height: 170)
            }
        }
        .padding(16)
        .modifier(Panel())
    }

    func modelTable(_ rows: [UsageRecord]) -> some View {
        let groups = Dictionary(grouping: rows) { "\($0.source.rawValue)|\($0.model)" }
        let models = groups.map { key, rs in
            ModelRow(id: key, source: rs[0].source, model: rs[0].model, s: Summary(rs), priced: rs[0].cost != nil)
        }
        .sorted { $0.s.cost != $1.s.cost ? $0.s.cost > $1.s.cost : $0.s.tokens > $1.s.tokens }
        return Table(models) {
            TableColumn(L("模型")) { Text($0.model).font(.system(.body, design: .monospaced)) }.width(min: 150, ideal: 190)
            TableColumn(L("应用")) { Text($0.source.rawValue) }.width(60)
            TableColumn(L("请求数")) { Text($0.s.requests.formatted()).monospacedDigit() }.width(70)
            TableColumn(L("输入")) { Text(abbrev($0.s.input)).monospacedDigit() }.width(70)
            TableColumn(L("输出")) { Text(abbrev($0.s.output)).monospacedDigit() }.width(70)
            TableColumn(L("缓存读取")) { Text(abbrev($0.s.cacheRead)).monospacedDigit() }.width(100)
            TableColumn(L("缓存写入")) { Text(abbrev($0.s.cacheWrite)).monospacedDigit() }.width(100)
            TableColumn(L("成本")) { Text($0.priced ? money($0.s.cost) : "—").monospacedDigit() }.width(100)
        }
        .overlay { if models.isEmpty && !store.loading { Text(L("该时间段内没有记录")).foregroundStyle(.secondary) } }
    }

    func logTable(_ rows: [UsageRecord]) -> some View {
        let limit = 1000
        let shown = Array(rows.prefix(limit))
        let f = DateFormatter()
        f.dateFormat = range == .today ? "HH:mm:ss" : "M/d HH:mm:ss"
        return VStack(alignment: .leading, spacing: 6) {
            Table(shown) {
                TableColumn(L("时间")) { Text(f.string(from: $0.time)).monospacedDigit() }.width(min: 70, ideal: 100)
                TableColumn(L("应用")) { Text($0.source.rawValue) }.width(60)
                TableColumn(L("模型")) { Text($0.model).font(.system(.body, design: .monospaced)) }.width(min: 140, ideal: 170)
                TableColumn(L("成本")) { Text(money($0.cost, digits: 4)).monospacedDigit() }.width(75)
                TableColumn(L("输入")) { Text($0.input.formatted()).monospacedDigit() }.width(70)
                TableColumn(L("输出")) { Text($0.output.formatted()).monospacedDigit() }.width(70)
                TableColumn(L("缓存读取")) { Text(abbrev($0.cacheRead)).monospacedDigit() }.width(100)
                TableColumn(L("缓存写入")) { Text(abbrev($0.cacheWrite)).monospacedDigit() }.width(100)
            }
            .overlay { if shown.isEmpty && !store.loading { Text(L("该时间段内没有记录")).foregroundStyle(.secondary) } }
            if rows.count > limit {
                Text(L("仅显示最近 %d 条", limit)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 统计窗口里的圆角面板
struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// 命令行：UsageBar --stats，打印今天和最近 7 天的汇总（排查用）
func printStats() async {
    await Pricing.load()
    var recs = LogReader.read(since: StatsRange.week.since)
    for i in recs.indices { recs[i].cost = Pricing.cost(recs[i]) }
    for range in [StatsRange.today, .week] {
        for src in [Source.claude, .codex] {
            let s = Summary(recs.filter { $0.time >= range.since && $0.source == src })
            print("\(range.rawValue) \(src.rawValue): cost \(money(s.cost)) · requests \(s.requests) · tokens \(abbrev(s.tokens))"
                  + " (in \(abbrev(s.input)) out \(abbrev(s.output)) cacheR \(abbrev(s.cacheRead)) cacheW \(abbrev(s.cacheWrite)))"
                  + " · hit \(s.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")")
        }
    }
    let unpriced = Set(recs.filter { $0.cost == nil }.map(\.model))
    if !unpriced.isEmpty { print("unpriced models:", unpriced.sorted().joined(separator: ", ")) }
}
