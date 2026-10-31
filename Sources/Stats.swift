// 用量统计：从本机会话记录算 token 用量和按 API 价格估算的成本
//   Claude: ~/.claude/projects/**/*.jsonl 里 assistant 消息的 message.usage
//   Codex : ~/.codex/sessions/**/*.jsonl 里 token_count 事件的 last_token_usage
//   耗时  : 两边日志都不记，按时间戳估算：请求发出（上一条用户消息 / 工具结果）到回复最后一段写入；
//           首字取第一段内容写入的时间（日志要等一整段生成完才写，所以偏大）
//   价格  : models.dev/api.json（每天更新一次，缓存在 ~/Library/Caches）

import AppKit
import SwiftUI
import Charts

// MARK: - 数据

enum Source: String, Codable { case claude = "Claude", codex = "Codex" }

struct UsageRecord: Identifiable, Codable {
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
    var duration: Double?  // 估算的总耗时（秒）
    var firstToken: Double?  // 估算的首字时间（秒）：第一段内容写入日志的时间
    var status = 200       // 失败的请求（Claude Code 会记下来）：429、401 等
    var tokens: Int { input + output + cacheRead + cacheWrite }
    var failed: Bool { status != 200 }
    var hitRate: Double? {
        let prompt = input + cacheRead + cacheWrite
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }
    /// 输出速度（token/秒），按总耗时算（思考也算在输出里，扣掉首字反而偏高）。
    /// 输出太少时耗时几乎全是等待，算出来没意义
    static let minSpeedOutput = 200
    var speed: Double? { duration.flatMap { $0 > 0.05 && output >= Self.minSpeedOutput ? Double(output) / $0 : nil } }
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
    /// 本地价格表缓存的更新时间（设置里显示）
    static var updatedAt: Date?
    /// 最近一次下载是否失败（失败时继续用旧缓存）
    static var downloadFailed = false

    /// 读缓存；没有缓存、超过一天或 force 时重新下载
    /// download：false 时只读本地缓存（启动时先出数，不等网络）
    static func load(force: Bool = false, download allowDownload: Bool = true) async {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if allowDownload, force || mtime.map({ Date().timeIntervalSince($0) > 86400 }) ?? true {
            if let fresh = await download() {
                try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fresh.write(to: cacheURL)
                downloadFailed = false
            } else {
                downloadFailed = true
            }
        }
        guard let d = try? Data(contentsOf: cacheURL),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        var t: [String: [String: Price]] = [:]
        for (provider, models) in json {
            guard let models = models as? [String: Any] else { continue }
            t[provider] = models.compactMapValues { ($0 as? [String: Any]).flatMap(price) }
        }
        table = t
        updatedAt = (try? fm.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
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
        breakdown(r).map { $0.input + $0.output + $0.cacheRead + $0.cacheWrite }
    }

    /// 各部分的成本（美元），请求详情里显示
    static func breakdown(_ r: UsageRecord) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)? {
        let models = table[r.source == .claude ? "anthropic" : "openai"]
        // 带日期后缀的型号（如 -20261001）去掉后缀再找一次
        let base = r.model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        guard var p = models?[r.model] ?? models?[base] else { return nil }
        let prompt = r.input + r.cacheRead + r.cacheWrite
        if let tier = p.tiers.last(where: { prompt > $0.size }) { p = tier.price }
        // models.dev 的 cache_write 是 5 分钟缓存的价格；1 小时缓存按 Anthropic 的规则算输入价的 2 倍
        let write5m = r.cacheWrite - r.cacheWrite1h
        let m = 1_000_000.0
        return (Double(r.input) * p.input / m, Double(r.output) * p.output / m,
                Double(r.cacheRead) * (p.cacheRead ?? p.input) / m,
                (Double(write5m) * (p.cacheWrite ?? p.input) + Double(r.cacheWrite1h) * p.input * 2) / m)
    }
}

// MARK: - 读会话记录

enum LogReader {
    /// 每个文件的解析结果。存到磁盘上，下次启动直接用（全部重读要好几秒）；
    /// 文件变了只接着解析后面新写的部分（会话日志只会往后追加）
    struct Entry: Codable {
        var mtime = Date.distantPast
        var size = 0
        var records: [UsageRecord] = []
        var offset = 0         // 已经解析到的字节位置（总在一行末尾）
        var tail: UInt64 = 0   // offset 之前一小段内容的指纹：对不上说明文件被改写过，得从头读
        var tailLength = 0
        var claude = ClaudeState()
        var codex = CodexState()
    }
    /// 解析读到 offset 时的状态，接着读时要用
    struct ClaudeState: Codable {
        var sentAt: Date?
        var model = "—"
    }
    struct CodexState: Codable {
        var model = "codex"
        var lastTotal = -1
        var inputAt: Date?, start: Date?, first: Date?, end: Date?
    }
    struct DiskCache: Codable {
        var version: Int
        var files: [String: Entry]
    }
    /// 解析规则改了就加一，旧缓存作废
    static let cacheVersion = 3
    static var diskURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.usagebar/records.plist")
    }
    private static var cache: [String: Entry] = [:]
    private static var diskLoaded = false
    private static let lock = NSLock()

    private static func loadDisk() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let data = try? Data(contentsOf: diskURL),
              let disk = try? PropertyListDecoder().decode(DiskCache.self, from: data),
              disk.version == cacheVersion else { return }
        cache = disk.files
    }

    private static func saveDisk() {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(DiskCache(version: cacheVersion, files: cache)) else { return }
        try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: diskURL, options: .atomic)
    }

    /// 上次存下的结果，不碰日志文件（启动时先拿它出数）
    static func cached() -> [UsageRecord] {
        lock.lock(); defer { lock.unlock() }
        loadDisk()
        return dedupe(cache.values.flatMap(\.records), since: .distantPast)
    }

    static func read(since: Date) -> [UsageRecord] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dirs: [(String, Source)] = [(".claude/projects", .claude), (".codex/sessions", .codex),
                                        (".codex/archived_sessions", .codex)]
        var all: [UsageRecord] = []
        lock.lock(); defer { lock.unlock() }
        loadDisk()
        var seen = Set<String>(), changed = false
        for (dir, src) in dirs {
            let root = home.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = v?.contentModificationDate ?? .distantPast, size = v?.fileSize ?? 0
                seen.insert(url.path)
                guard mtime >= since else { continue }
                if let c = cache[url.path], c.mtime == mtime, c.size == size { all += c.records; continue }
                var entry = cache[url.path].flatMap { canResume($0, url: url, size: size) ? $0 : nil } ?? Entry()
                parse(url, src, into: &entry)
                entry.mtime = mtime
                entry.size = size
                cache[url.path] = entry
                changed = true
                all += entry.records
            }
        }
        // 删掉的日志也从缓存里去掉
        for path in cache.keys where !seen.contains(path) { cache[path] = nil; changed = true }
        if changed { saveDisk() }
        return dedupe(all, since: since)
    }

    /// 能不能接着上次的位置读：文件没变小，offset 前面那一小段也没变
    static func canResume(_ e: Entry, url: URL, size: Int) -> Bool {
        guard e.offset > 0, size >= e.offset, let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(e.offset - e.tailLength))) != nil,
              let bytes = try? fh.read(upToCount: e.tailLength) else { return false }
        return fnv(bytes) == e.tail
    }

    /// 从 entry.offset 读到文件末尾最后一个完整行；写到一半的行留到下次
    static func parse(_ url: URL, _ src: Source, into e: inout Entry) {
        let data: Data
        if e.offset == 0 {
            guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            data = d
        } else {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? fh.close() }
            guard (try? fh.seek(toOffset: UInt64(e.offset))) != nil, let d = try? fh.readToEnd() else { return }
            data = d
        }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let chunk = data[data.startIndex...lastNewline]
        if src == .claude { parseClaude(chunk, &e.claude, &e.records) } else { parseCodex(chunk, &e.codex, &e.records) }
        e.offset += chunk.count
        e.tailLength = min(64, chunk.count)
        e.tail = fnv(chunk.suffix(e.tailLength))
    }

    /// FNV-1a：内容指纹（Swift 自带的 hashValue 每次启动都不一样，不能存盘）
    static func fnv<D: DataProtocol>(_ bytes: D) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// 同一请求可能出现在多个文件里（续接的会话会带上旧记录），按 id 去重，留输出最多的那条
    static func dedupe(_ all: [UsageRecord], since: Date) -> [UsageRecord] {
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

    /// 一行里第一个 "timestamp"（顶层那个，在消息内容之前），不用解析整行 JSON
    static func timestamp(in line: Data.SubSequence) -> Date? {
        guard let r = line.range(of: Data("\"timestamp\":\"".utf8)) else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: Data(rest[..<end]), encoding: .utf8).flatMap(iso.date)
    }

    /// 合理的耗时才要：负数（时间戳乱序）或超过半小时的多半是续接会话里拼起来的旧记录
    static func span(_ from: Date?, _ to: Date) -> Double? {
        guard let from else { return nil }
        let d = to.timeIntervalSince(from)
        return d > 0 && d < 1800 ? d : nil
    }

    /// Claude Code 失败请求的状态码：有 apiErrorStatus 就用，没有按错误类型对应
    static func claudeStatus(_ o: [String: Any]) -> Int {
        if let s = o["apiErrorStatus"] as? Int { return s }
        switch o["error"] as? String {
        case "authentication_failed": return 401
        case "rate_limit": return 429
        case "invalid_request": return 400
        case "overloaded": return 529
        default: return 500
        }
    }

    /// 解析一段完整的行，接在 out 后面；state 带着上一段读完时的状态
    static func parseClaude(_ data: Data.SubSequence, _ state: inout ClaudeState, _ out: inout [UsageRecord]) {
        let usageKey = Data("\"usage\"".utf8)
        let sentKeys = [Data("\"type\":\"user\"".utf8), Data("\"type\":\"api-request\"".utf8)]
        // 一个回复分成几行写（每段内容一行），记下它在 out 里的位置；接着读时后面几段可能落在新的一段里
        var index = Dictionary(out.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sentAt = state.sentAt    // 最近一次发出请求：用户消息、工具结果，或新版的 api-request
        var model = state.model      // 失败的请求没有模型名，用前面最近的那个
        defer { state.sentAt = sentAt; state.model = model }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // 大部分行是对话内容：先按字节粗筛，用户消息和工具结果只取时间戳，不解析整行
            guard line.range(of: usageKey) != nil else {
                if sentKeys.contains(where: { line.range(of: $0) != nil }), let t = timestamp(in: line) { sentAt = t }
                continue
            }
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let ts = (o["timestamp"] as? String).flatMap(iso.date) else { continue }
            guard o["type"] as? String == "assistant" else {
                if ["user", "api-request"].contains(o["type"] as? String) { sentAt = ts }
                continue
            }
            guard let msg = o["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { continue }
            let id = "\(msg["id"] as? String ?? UUID().uuidString):\(o["requestId"] as? String ?? "")"
            if let i = index[id] {
                out[i].duration = span(sentAt, ts) ?? out[i].duration  // 后面几段写入时更新结束时间
                continue
            }
            let name = msg["model"] as? String ?? model
            if name == "<synthetic>" {
                // Claude Code 自己插的消息；isApiErrorMessage 的是失败的请求，其他（比如中断提示）不算
                guard o["isApiErrorMessage"] as? Bool == true else { continue }
                var r = UsageRecord(id: id, time: ts, source: .claude, model: model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
                r.status = claudeStatus(o)
                r.duration = span(sentAt, ts)
                index[id] = out.count
                out.append(r)
                continue
            }
            model = name
            var r = UsageRecord(id: id, time: ts, source: .claude, model: name,
                                input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
            r.cacheWrite1h = min(r.cacheWrite, (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
            r.duration = span(sentAt, ts)
            r.firstToken = r.duration
            index[id] = out.count
            out.append(r)
        }
    }

    /// Codex 日志一行是 {"timestamp":…,"type":…,"payload":{"type":"…"：取出 payload 的类型，不解析整行
    static func payloadType(in line: Data.SubSequence) -> String? {
        guard let r = line.range(of: Data("\"payload\":{\"type\":\"".utf8)) else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(data: Data(rest[..<end]), encoding: .utf8)
    }

    static func parseCodex(_ data: Data.SubSequence, _ state: inout CodexState, _ out: inout [UsageRecord]) {
        let parseKeys = [Data("\"token_count\"".utf8), Data("\"turn_context\"".utf8)]
        let outputs: Set<String> = ["reasoning", "message", "function_call", "custom_tool_call", "web_search_call", "local_shell_call"]
        var model = state.model, lastTotal = state.lastTotal
        // 耗时：一次回复从「最近一次输入」（用户消息、工具结果）开始，到它最后一项内容写入为止。
        // token_count 要等工具执行完才写，不能当结束时间
        var inputAt = state.inputAt, start = state.start, first = state.first, end = state.end
        defer { state = CodexState(model: model, lastTotal: lastTotal, inputAt: inputAt, start: start, first: first, end: end) }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // turn_context 的 payload 第一个字段不是 type，取不到类型，单独认
            let kind = payloadType(in: line) ?? ""
            if !parseKeys.contains(where: { line.range(of: $0) != nil }) || kind == "message" {
                // 只看类型和时间，不解析整行（工具输出往往很长）
                guard let ts = timestamp(in: line) else { continue }
                if kind.hasSuffix("_call_output") || kind == "task_started" || kind == "user_message" {
                    inputAt = ts
                } else if kind == "message", line.range(of: Data("\"role\":\"user\"".utf8)) != nil {
                    inputAt = ts
                } else if outputs.contains(kind) {
                    if start == nil { start = inputAt; first = ts }
                    end = ts
                } else if kind == "token_usage_record" || line.range(of: Data("\"type\":\"token_usage_record\"".utf8)) != nil {
                    end = ts
                }
                continue
            }
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let p = o["payload"] as? [String: Any] else { continue }
            if o["type"] as? String == "turn_context" { model = p["model"] as? String ?? model; continue }
            guard p["type"] as? String == "token_count", let info = p["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
                  total != lastTotal,  // 只更新了额度信息的重复事件
                  let tsString = o["timestamp"] as? String, let ts = iso.date(from: tsString) else { continue }
            lastTotal = total
            let cached = last["cached_input_tokens"] as? Int ?? 0
            var r = UsageRecord(id: "\(tsString)|\(total)", time: ts, source: .codex, model: model,
                                input: max(0, (last["input_tokens"] as? Int ?? 0) - cached),
                                output: last["output_tokens"] as? Int ?? 0,
                                cacheRead: cached, cacheWrite: last["cache_write_input_tokens"] as? Int ?? 0)
            if let end { r.duration = span(start, end) }
            if let first { r.firstToken = span(start, first) }
            start = nil; first = nil; end = nil
            out.append(r)
        }
    }
}

// MARK: - 汇总

/// 统计的时间范围。cycle：周额度上次重置以来（每家按自己的重置时间算）；custom：自选起止
enum StatsRange: String, CaseIterable {
    case today, cycle, day = "24h", week = "7d", fortnight = "14d", month = "30d", all, custom

    var title: String {
        switch self {
        case .today: return L("今天")
        case .cycle: return L("重置以来")
        case .day: return L("近 24 小时")
        case .week: return L("近 7 天")
        case .fortnight: return L("近 14 天")
        case .month: return L("近 30 天")
        case .all: return L("全部时间")
        case .custom: return L("自定义")
        }
    }

    /// 固定的起点；cycle / all / custom 的起点由统计窗口另算
    var presetStart: Date {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        switch self {
        case .day: return Date().addingTimeInterval(-86400)
        case .week: return cal.date(byAdding: .day, value: -6, to: today)!
        case .fortnight: return cal.date(byAdding: .day, value: -13, to: today)!
        case .month: return cal.date(byAdding: .day, value: -29, to: today)!
        default: return today
        }
    }
}

struct Summary {
    var cost = 0.0, requests = 0, tokens = 0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    init(_ rs: [UsageRecord]) {
        for r in rs where !r.failed {  // 失败的请求只在请求明细里列出来
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
    var failed = 0
    var speed: Double?       // 平均速度（只算估得出速度的请求）
    var firstToken: Double?  // 首字的中位数
    var successRate: Double { Double(s.requests) / Double(max(1, s.requests + failed)) }
}

/// 中位数：首字偶尔会因为等确认、长时间思考到几分钟，平均数会被这几次拉高
func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let v = xs.sorted(), m = v.count / 2
    return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
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
    /// 各家周额度当前周期的起点，由额度刷新时填入
    @Published var cycleStarts: [Source: Date] = [:]

    /// forcePrices：顺便从 models.dev 重新下载价格（设置里的「立即更新」）
    func reload(forcePrices: Bool = false) {
        guard !loading else { return }
        loading = true
        let first = all.isEmpty
        Task.detached(priority: .userInitiated) {
            func priced(_ rs: [UsageRecord]) -> [UsageRecord] {
                var rs = rs
                for i in rs.indices { rs[i].cost = Pricing.cost(rs[i]) }
                return rs.sorted { $0.time > $1.time }
            }
            // 刚启动：先用上次存下的结果马上出数，再去读改动过的日志
            if first {
                await Pricing.load(download: false)
                let cached = priced(LogReader.cached())
                if !cached.isEmpty {
                    await MainActor.run { self.all = cached; self.updated = Date() }
                }
            }
            await Pricing.load(force: forcePrices)
            let result = priced(LogReader.read(since: .distantPast))  // 全部历史，「全部时间」和自定义范围都要用
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
    @AppStorage("statsCustomStart") var customStart = 0.0
    @AppStorage("statsCustomEnd") var customEnd = 0.0
    @AppStorage("statsCustomEndNow") var customEndNow = true
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage("statsTab") var tab = "models"
    /// 请求明细的当前页（从 0 开始）；换时间范围或来源时回到第一页
    @State var page = 0
    static let pageSize = 50
    /// 请求明细每格左边留的空：表头的分隔线在两列交界处，文字不能贴着它
    static let cellInset: CGFloat = 8
    @State var showRange = false
    @AppStorage("statsChartStyle") var chartStyle = "line"  // line / bar
    @AppStorage("statsChartColor") var chartColor = "pink"  // 主题色，在 通用 → 基本 里选
    /// 请求明细里隐藏的列（LogColumn 的 rawValue，逗号分隔）
    @AppStorage("statsHiddenColumns") var hiddenColumns = ""
    /// 汇总下面展开的第二行（新增输入、输出、缓存读取、缓存写入）
    @AppStorage("statsMoreTiles") var moreTiles = false
    /// 请求明细只看某个状态码；0 是全部
    @AppStorage("statsStatus") var statusFilter = 0
    /// 点开详情的那条请求
    @State var selected: UsageRecord?
    /// 表格可用的宽度：列多了放不下时改成左右滚动
    @State var tableWidth: CGFloat = 0
    /// 三张表各自的列顺序和列宽（拖表头调整），逗号分隔：time,app,… / app:64,model:220
    @AppStorage("statsColumnOrder") var columnOrder = ""
    @AppStorage("statsColumnWidths") var columnWidths = ""
    @AppStorage("statsModelColumnOrder") var modelColumnOrder = ""
    @AppStorage("statsModelColumnWidths") var modelColumnWidths = ""
    @AppStorage("statsAppColumnOrder") var appColumnOrder = ""
    @AppStorage("statsAppColumnWidths") var appColumnWidths = ""
    /// 正在拖的分隔线：拖动中的宽度先放这里，松手再存（键是「表.列」）
    @State var liveWidths: [String: CGFloat] = [:]
    @State var resizeBase: CGFloat?
    /// 正在拖着换位置的表头（「表.列」）和拖了多远
    @State var reorder: (key: String, dx: CGFloat)?

    var range: StatsRange { StatsRange(rawValue: rangeRaw) ?? .today }
    var sources: [Source] { source == "all" ? [.claude, .codex] : [Source(rawValue: source) ?? .claude] }
    /// 「重置以来」时每家起点不同，其他范围两家一样
    func since(_ src: Source) -> Date {
        switch range {
        case .cycle: return store.cycleStarts[src] ?? StatsRange.week.presetStart
        case .all: return store.all.last?.time ?? StatsRange.month.presetStart  // all 按时间倒序，最后一条最早
        case .custom: return customStart > 0 ? Date(timeIntervalSince1970: customStart) : StatsRange.today.presetStart
        default: return range.presetStart
        }
    }
    var end: Date { range == .custom && !customEndNow && customEnd > 0 ? Date(timeIntervalSince1970: customEnd) : Date() }
    /// 两天以内按小时画，更长按天画
    var hourly: Bool { end.timeIntervalSince(sources.map(since).min() ?? end) <= 2 * 86400 }
    var rows: [UsageRecord] {
        let starts = Dictionary(uniqueKeysWithValues: sources.map { ($0, since($0)) })
        let end = end
        return store.all.filter { r in r.time <= end && (starts[r.source].map { r.time >= $0 } ?? false) }
    }
    var rangeLabel: String {
        guard range == .custom else { return range.title }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        let start = f.string(from: since(.claude))
        return "\(start) – " + (customEndNow ? L("现在") : f.string(from: end))
    }
    /// 「重置以来」时说明每家从什么时候算起
    var cycleCaption: String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return sources.map { src in
            store.cycleStarts[src].map { L("%@ 自 %@ 起", src.rawValue, f.string(from: $0)) }
                ?? L("%@ 周期未知，按最近 7 天", src.rawValue)
        }.joined(separator: " · ")
    }

    var body: some View {
        let _ = language  // 切换语言时重绘
        let rows = rows
        let sum = Summary(rows)
        VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if range == .cycle {
                Text(cycleCaption).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 12)
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
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
                // 更多指标：Tokens 拆成四部分
                if moreTiles {
                    Divider()
                    HStack(spacing: 0) {
                        tile(L("新增输入"), abbrev(sum.input), small: true)
                        Divider().padding(.vertical, 4)
                        tile(L("输出"), abbrev(sum.output), small: true)
                        Divider().padding(.vertical, 4)
                        tile(L("缓存读取"), abbrev(sum.cacheRead), small: true)
                        Divider().padding(.vertical, 4)
                        tile(L("缓存写入"), abbrev(sum.cacheWrite), small: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                }
            }
            .padding(.bottom, 8)
            .modifier(Panel())
            .overlay(alignment: .bottom) {
                Button { withAnimation(.easeOut(duration: 0.15)) { moreTiles.toggle() } } label: {
                    Image(systemName: moreTiles ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                }
                .buttonStyle(.plain)
                .help(moreTiles ? L("收起") : L("更多指标"))
                .offset(y: 11)
            }
            chart(rows)
            tables(rows)
            Text(L("成本按 models.dev 的 API 价格估算，仅统计本机会话记录"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding([.horizontal, .bottom], 20)
        }
        }
        .frame(minWidth: 820, minHeight: 600)
        // 点请求明细的一行：从右边滑出详情
        .overlay(alignment: .trailing) {
            if let r = selected {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { selected = nil }
                    RequestDetail(r: r, timeFormat: "yyyy/M/d HH:mm:ss") { selected = nil }
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: selected?.id)
        .environment(\.locale, locale)  // 图表坐标的日期跟着界面语言
    }

    var locale: Locale {
        Locale(identifier: ["zh": "zh_CN", "ja": "ja_JP"][I18n.lang] ?? "en_US")
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            Button { showRange.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(rangeLabel).monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $showRange, arrowEdge: .bottom) {
                RangePopover(rangeRaw: Binding(get: { rangeRaw }, set: { rangeRaw = $0; page = 0 }),
                             customStart: $customStart, customEnd: $customEnd,
                             customEndNow: $customEndNow, isPresented: $showRange)
                    .environment(\.locale, locale)
            }
            Picker("", selection: Binding(get: { source }, set: { source = $0; page = 0 })) {
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

    func tile(_ title: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: small ? 18 : 26, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    func buckets(_ rows: [UsageRecord]) -> [Bucket] {
        let cal = Calendar.current
        let hourly = hourly
        var sums: [Date: Int] = [:]
        for r in rows {
            let key = hourly ? cal.dateInterval(of: .hour, for: r.time)!.start : cal.startOfDay(for: r.time)
            sums[key, default: 0] += r.tokens
        }
        // 补齐没有用量的时段，曲线才连续
        var out: [Bucket] = []
        let end = end
        // 起点最多往前两年，防止没有数据时从很久以前开始补齐
        let first = max(sources.map(since).min() ?? end, end.addingTimeInterval(-730 * 86400))
        var t = hourly ? cal.dateInterval(of: .hour, for: first)!.start : cal.startOfDay(for: first)
        while t <= end {
            out.append(Bucket(date: t, tokens: sums[t] ?? 0))
            t = cal.date(byAdding: hourly ? .hour : .day, value: 1, to: t)!
        }
        return out
    }

    func chart(_ rows: [UsageRecord]) -> some View {
        let unit: Calendar.Component = hourly ? .hour : .day
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(hourly ? L("Tokens · 按小时") : L("Tokens · 按天"))
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $chartStyle) {
                    Image(systemName: "chart.xyaxis.line").help(L("曲线图")).tag("line")
                    Image(systemName: "chart.bar").help(L("柱状图")).tag("bar")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if store.loading && store.all.isEmpty {
                Text(L("正在读取本机会话记录…")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart(buckets(rows)) { b in
                    let c = ChartColor.color(chartColor)
                    if chartStyle == "bar" {
                        BarMark(x: .value("t", b.date, unit: unit), y: .value("tokens", b.tokens))
                            .foregroundStyle(c.opacity(0.8))
                            .cornerRadius(2)
                    } else {
                        AreaMark(x: .value("t", b.date, unit: unit), y: .value("tokens", b.tokens))
                            .foregroundStyle(LinearGradient(colors: [c.opacity(0.28), c.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", b.date, unit: unit), y: .value("tokens", b.tokens))
                            .foregroundStyle(c)
                            .interpolationMethod(.monotone)
                    }
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

    func modelRows(_ rows: [UsageRecord]) -> [ModelRow] { grouped(rows) { "\($0.source.rawValue)|\($0.model)" } }
    /// 按应用（CC Switch 叫「供应商」）：Claude Code、Codex 各一行
    func appRows(_ rows: [UsageRecord]) -> [ModelRow] { grouped(rows) { $0.source.rawValue } }

    /// 按 key 分组汇总。失败的请求也分进去，只用来算成功率
    func grouped(_ rows: [UsageRecord], by key: (UsageRecord) -> String) -> [ModelRow] {
        Dictionary(grouping: rows, by: key)
            .compactMap { key, rs in
                let ok = rs.filter { !$0.failed }
                guard let first = ok.first else { return nil }
                // 速度按总输出 ÷ 总耗时算，不是各请求速度的平均（那样会被几个输出少却很快的请求拉高）
                let timed = ok.filter { $0.speed != nil }
                let time = timed.reduce(0) { $0 + ($1.duration ?? 0) }
                return ModelRow(id: key, source: first.source, model: first.model, s: Summary(ok),
                                priced: ok.contains { $0.cost != nil }, failed: rs.count - ok.count,
                                speed: time > 0 ? Double(timed.reduce(0) { $0 + $1.output }) / time : nil,
                                firstToken: median(ok.compactMap(\.firstToken)))
            }
            .sorted { $0.s.cost != $1.s.cost ? $0.s.cost > $1.s.cost : $0.s.tokens > $1.s.tokens }
    }

    /// 下方的明细面板：顶部是带数量的下划线标签，下面是表格
    func tables(_ rows: [UsageRecord]) -> some View {
        let models = modelRows(rows), apps = appRows(rows)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 26) {
                tabButton(L("按应用"), count: apps.count, tag: "apps")
                tabButton(L("按模型"), count: models.count, tag: "models")
                tabButton(L("请求明细"), count: rows.count, tag: "log")
                Spacer()
                if tab == "log" {
                    statusMenu(rows)
                    Divider().frame(height: 16)
                    columnMenu
                } else {
                    layoutMenu(tab == "apps" ? appLayout : modelLayout)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)
            Divider()
            switch tab {
            case "apps": appTable(apps)
            case "models": modelTable(models)
            default: logTable(rows)
            }
        }
        .modifier(Panel())
    }

    func tabButton(_ title: String, count: Int, tag: String) -> some View {
        let selected = tab == tag
        return Button { tab = tag } label: {
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? .primary : .secondary)
                    Text(count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                }
                Rectangle().fill(selected ? ChartColor.color(chartColor) : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func emptyRow() -> some View {
        Text(store.loading ? L("正在读取本机会话记录…") : L("该时间段内没有记录"))
            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    var logLayout: ColumnLayout { ColumnLayout(table: "log", order: $columnOrder, widths: $columnWidths) }
    var modelLayout: ColumnLayout { ColumnLayout(table: "models", order: $modelColumnOrder, widths: $modelColumnWidths) }
    var appLayout: ColumnLayout { ColumnLayout(table: "apps", order: $appColumnOrder, widths: $appColumnWidths) }

    /// 按模型、按应用：各项 token 在上面汇总的「更多指标」里，这里和 CC Switch 一样只列总数
    func groupTable(_ rows: [ModelRow], _ l: ColumnLayout) -> some View {
        let apps = l.table == "apps"
        let cols: [GroupColumn] = ordered(l).filter { !(apps && $0 == .app) }
        let saved: [GroupColumn: CGFloat] = savedWidths(l)
        let m = metrics(cols, l, saved)
        let table = VStack(spacing: 0) {
            columnHeader(cols, l, saved: saved, flex: m.flex) { c in c == .name ? L(apps ? "应用" : "模型") : c.title }
            if rows.isEmpty { emptyRow() }
            ForEach(rows) { row in
                Divider()
                columnRow(cols, l, saved: saved) { c in c.cell(row, appName: apps) }
                    .frame(height: 42)
            }
        }
        return fitted(table, needed: m.needed)
    }

    func modelTable(_ models: [ModelRow]) -> some View { groupTable(models, modelLayout) }
    func appTable(_ apps: [ModelRow]) -> some View { groupTable(apps, appLayout) }

    var hidden: Set<LogColumn> {
        Set(hiddenColumns.split(separator: ",").compactMap { LogColumn(rawValue: String($0)) }).subtracting([.time])
    }

    // MARK: 列的顺序和宽度（三张表共用）

    /// 存下的顺序，之后新加的列补在后面
    func ordered<C: StatsColumn>(_ l: ColumnLayout) -> [C] {
        var list = l.order.wrappedValue.split(separator: ",").compactMap { C(rawValue: String($0)) }
        for c in C.allCases where !list.contains(c) { list.append(c) }
        return list
    }

    func savedWidths<C: StatsColumn>(_ l: ColumnLayout) -> [C: CGFloat] {
        let pairs = l.widths.wrappedValue.split(separator: ",").compactMap { kv -> (C, CGFloat)? in
            let p = kv.split(separator: ":")
            guard p.count == 2, let c = C(rawValue: String(p[0])), let w = Double(p[1]) else { return nil }
            return (c, CGFloat(w))
        }
        return Dictionary(pairs, uniquingKeysWith: { $1 })
    }

    /// nil：占满剩余宽度（名称那一列，除非拖过）
    func width<C: StatsColumn>(_ c: C, _ l: ColumnLayout, _ saved: [C: CGFloat]) -> CGFloat? {
        liveWidths[l.key(c)] ?? saved[c] ?? c.defaultWidth(today: range == .today)
    }

    /// 固定列的总宽、整张表至少要多宽、占满剩余那一列现在的实际宽度
    func metrics<C: StatsColumn>(_ cols: [C], _ l: ColumnLayout, _ saved: [C: CGFloat]) -> (needed: CGFloat, flex: CGFloat) {
        let fixed = cols.reduce(2 * (20 - Self.cellInset)) { $0 + (width($1, l, saved) ?? 0) }
        let needed = fixed + (cols.contains { width($0, l, saved) == nil } ? 170 : 0)
        return (needed, max(170, tableWidth - fixed))
    }

    func moveColumn<C: StatsColumn>(_ from: C, to target: C, _ l: ColumnLayout) {
        var list: [C] = ordered(l)
        guard let i = list.firstIndex(of: from), let j = list.firstIndex(of: target) else { return }
        list.move(fromOffsets: [i], toOffset: j > i ? j + 1 : j)
        l.order.wrappedValue = list.map(\.rawValue).joined(separator: ",")
    }

    /// 列多了放不下就左右滚动；放得下时名称那一列占满剩余宽度
    func fitted<T: View>(_ table: T, needed: CGFloat) -> some View {
        Group {
            if tableWidth >= needed { table } else { ScrollView(.horizontal) { table.frame(width: needed) } }
        }
        .frame(maxWidth: .infinity)
        .background(GeometryReader { g in
            Color.clear.onAppear { tableWidth = g.size.width }.onChange(of: g.size.width) { tableWidth = $0 }
        })
    }

    /// 表头：按住拖到别的列上换位置；拖右边的分隔线调宽度
    func columnHeader<C: StatsColumn>(_ cols: [C], _ l: ColumnLayout, saved: [C: CGFloat], flex: CGFloat,
                                      title: @escaping (C) -> String = { $0.title }) -> some View {
        HStack(spacing: 0) {
            ForEach(cols, id: \.self) { c in
                let w = width(c, l, saved), key = l.key(c)
                Text(title(c)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, Self.cellInset).padding(.trailing, 4)  // 文字和左边的分隔线隔开
                    .frame(width: w, alignment: .leading)
                    .frame(minWidth: w == nil ? 170 : nil, maxWidth: w == nil ? .infinity : nil, alignment: .leading)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                    .overlay(alignment: .trailing) { resizeHandle(c, l, current: w ?? flex, saved: saved) }
                    // 拖着的表头跟着鼠标走，松手时按落点换位置
                    .background(reorder?.key == key ? Color.primary.opacity(0.08) : .clear)
                    .offset(x: reorder?.key == key ? reorder?.dx ?? 0 : 0)
                    .zIndex(reorder?.key == key ? 1 : 0)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { v in reorder = (key, v.translation.width) }
                        .onEnded { v in
                            reorder = nil
                            let ws = cols.map { width($0, l, saved) ?? flex }
                            guard let i = cols.firstIndex(of: c) else { return }
                            let center = ws[..<i].reduce(0, +) + ws[i] / 2 + v.translation.width
                            var x: CGFloat = 0, j = cols.count - 1
                            for (k, wk) in ws.enumerated() {
                                if center < x + wk { j = k; break }
                                x += wk
                            }
                            if j != i { moveColumn(c, to: cols[j], l) }
                        })
            }
        }
        .padding(.horizontal, 20 - Self.cellInset)
        // 列都拖成固定宽度后不够宽：靠左放，底色铺满
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .help(L("拖动表头换顺序，拖动分隔线调整宽度"))
    }

    func resizeHandle<C: StatsColumn>(_ c: C, _ l: ColumnLayout, current: CGFloat, saved: [C: CGFloat]) -> some View {
        // 线在这一列的右边缘，可抓的范围往里多留几像素（不伸进右边那列，免得和拖表头换位置抢）
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
        }
        .frame(width: 8, height: 38)
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let base = resizeBase ?? current
                resizeBase = base
                liveWidths[l.key(c)] = max(c.minWidth, (base + v.translation.width).rounded())
            }
            .onEnded { _ in
                if let w = liveWidths[l.key(c)] {
                    var d = saved
                    d[c] = w
                    l.widths.wrappedValue = C.allCases.compactMap { k in d[k].map { "\(k.rawValue):\(Int($0))" } }
                        .joined(separator: ",")
                }
                liveWidths[l.key(c)] = nil
                resizeBase = nil
            })
    }

    /// 一行数据，列宽和表头对齐
    func columnRow<C: StatsColumn, Cell: View>(_ cols: [C], _ l: ColumnLayout, saved: [C: CGFloat],
                                               @ViewBuilder cell: @escaping (C) -> Cell) -> some View {
        HStack(spacing: 0) {
            ForEach(cols, id: \.self) { c in
                let w = width(c, l, saved)
                cell(c)
                    .lineLimit(1)
                    .padding(.leading, Self.cellInset).padding(.trailing, 4)
                    .frame(width: w, alignment: .leading)
                    .frame(minWidth: w == nil ? 170 : nil, maxWidth: w == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .font(.body.monospacedDigit())
        .padding(.horizontal, 20 - Self.cellInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 按应用、按模型右上角：恢复这张表的列宽和顺序
    func layoutMenu(_ l: ColumnLayout) -> some View {
        Menu {
            Button(L("恢复默认")) { l.order.wrappedValue = ""; l.widths.wrappedValue = "" }
        } label: {
            Image(systemName: "rectangle.split.3x1")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("拖动表头换顺序，拖动分隔线调整宽度"))
    }

    /// 按状态码筛选（ccswitch 那样）：只列出这段时间里出现过的状态码
    func statusMenu(_ rows: [UsageRecord]) -> some View {
        let codes = Set(rows.map(\.status)).union([200]).sorted()
        return Menu {
            Button { statusFilter = 0 } label: { check(statusFilter == 0, L("全部状态码")) }
            Divider()
            ForEach(codes, id: \.self) { c in
                Button { statusFilter = c } label: { check(statusFilter == c, "\(c)") }
            }
        } label: {
            Label(statusFilter == 0 ? L("状态码") : "\(statusFilter)", systemImage: "line.3.horizontal.decrease")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    /// 显示哪些列
    var columnMenu: some View {
        Menu {
            ForEach(LogColumn.allCases.filter { $0 != .time }, id: \.self) { c in
                Button {
                    var h = hidden
                    if h.contains(c) { h.remove(c) } else { h.insert(c) }
                    hiddenColumns = LogColumn.allCases.filter(h.contains).map(\.rawValue).joined(separator: ",")
                } label: { check(!hidden.contains(c), c.title) }
            }
            Divider()
            Button(L("恢复默认")) { hiddenColumns = ""; columnOrder = ""; columnWidths = "" }
        } label: {
            Image(systemName: "rectangle.split.3x1")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("显示的列"))
    }

    @ViewBuilder func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    func logTable(_ all: [UsageRecord]) -> some View {
        let rows = statusFilter == 0 ? all : all.filter { $0.status == statusFilter }
        let size = Self.pageSize
        let pages = max(1, (rows.count + size - 1) / size)
        let current = min(page, pages - 1)  // 数据变少时别停在不存在的页
        let f = DateFormatter()
        f.dateFormat = range == .today ? "HH:mm:ss" : "M/d HH:mm:ss"  // 跨天的范围带上日期
        let l = logLayout
        let cols: [LogColumn] = ordered(l).filter { !hidden.contains($0) }
        let saved: [LogColumn: CGFloat] = savedWidths(l)
        let m = metrics(cols, l, saved)
        let table = LazyVStack(spacing: 0) {
            columnHeader(cols, l, saved: saved, flex: m.flex)
            if rows.isEmpty { emptyRow() }
            ForEach(rows[min(rows.count, current * size)..<min(rows.count, (current + 1) * size)]) { r in
                Divider()
                let time = f.string(from: r.time)
                columnRow(cols, l, saved: saved) { c in c.cell(r, time: time) }
                    .frame(height: 42)
                    .background(selected?.id == r.id ? ChartColor.color(chartColor).opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = r }
            }
        }
        return VStack(spacing: 0) {
            fitted(table, needed: m.needed)
            if !rows.isEmpty {
                Divider()
                HStack(spacing: 12) {
                    Text(L("第 %d / %d 页 · 共 %d 条", current + 1, pages, rows.count))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { page = current - 1 } label: { Image(systemName: "chevron.left") }
                        .help(L("上一页")).disabled(current == 0)
                    Button { page = current + 1 } label: { Image(systemName: "chevron.right") }
                        .help(L("下一页")).disabled(current >= pages - 1)
                }
                .padding(.horizontal, 20).frame(height: 44)
            }
        }
    }

}

// MARK: - 表格的列

/// 能拖宽度、拖顺序的表格列
protocol StatsColumn: RawRepresentable, CaseIterable, Hashable where RawValue == String, AllCases == [Self] {
    var title: String { get }
    /// 默认宽度；nil：占满剩余宽度
    func defaultWidth(today: Bool) -> CGFloat?
    /// 拖窄的下限
    var minWidth: CGFloat { get }
}

/// 一张表的列顺序和列宽存在哪
struct ColumnLayout {
    let table: String
    let order: Binding<String>
    let widths: Binding<String>
    func key<C: StatsColumn>(_ c: C) -> String { "\(table).\(c.rawValue)" }
}

/// 按模型、按应用两张表的列（按应用没有「应用」那一列，名称列就是应用）
enum GroupColumn: String, CaseIterable, StatsColumn {
    case name, app, requests, cost, tokens, hitRate, success, speed, firstToken

    var title: String {
        switch self {
        case .name: return L("模型")
        case .app: return L("应用")
        case .requests: return L("请求数")
        case .cost: return L("成本")
        case .tokens: return "Tokens"
        case .hitRate: return L("命中率")
        case .success: return L("成功率")
        case .speed: return L("速度")
        case .firstToken: return L("首字")
        }
    }

    func defaultWidth(today: Bool) -> CGFloat? {
        switch self {
        case .name: return nil
        case .app, .requests, .hitRate, .success: return 76
        case .cost: return 96
        case .tokens, .speed: return 84
        case .firstToken: return 64
        }
    }

    var minWidth: CGFloat { self == .name ? 100 : 44 }

    @ViewBuilder func cell(_ m: ModelRow, appName: Bool) -> some View {
        switch self {
        case .name:
            if appName { Text(m.source == .claude ? "Claude Code" : "Codex") }
            else { Text(m.model).font(.system(.body, design: .monospaced)) }
        case .app: Text(m.source.rawValue)
        case .requests: Text(m.s.requests.formatted())
        case .cost: Text(m.priced ? money(m.s.cost) : "—")
        case .tokens: Text(abbrev(m.s.tokens))
        case .hitRate: Text(m.s.hitRate.map(percent) ?? "—")
        case .success: Text(percent(m.successRate))
        case .speed: Text(m.speed.map { String(format: "≈%.0f t/s", $0) } ?? "—")
        case .firstToken: Text(m.firstToken.map { "≈" + seconds($0) } ?? "—")
        }
    }
}

/// 请求明细的列
enum LogColumn: String, CaseIterable, StatsColumn {
    case time, app, model, cost, input, output, cacheRead, cacheWrite, hitRate, speed, firstToken, duration, status

    var title: String {
        switch self {
        case .time: return L("时间")
        case .app: return L("应用")
        case .model: return L("模型")
        case .cost: return L("成本")
        case .input: return L("新增输入")
        case .output: return L("输出")
        case .cacheRead: return L("缓存读取")
        case .cacheWrite: return L("缓存写入")
        case .hitRate: return L("命中率")
        case .speed: return L("速度")
        case .firstToken: return L("首字")
        case .duration: return L("总耗时")
        case .status: return L("状态码")
        }
    }

    /// 今天的时间只有时分秒，跨天的范围要带日期
    func defaultWidth(today: Bool) -> CGFloat? {
        switch self {
        case .time: return today ? 80 : 118
        case .app: return 64
        case .model: return nil
        case .cost: return 84
        case .input, .cacheRead, .cacheWrite: return 92
        case .output: return 72
        case .hitRate: return 70
        case .speed: return 84
        case .firstToken: return 60
        case .duration: return 70
        case .status: return 60
        }
    }

    var minWidth: CGFloat { self == .model ? 100 : 44 }

    @ViewBuilder func cell(_ r: UsageRecord, time: String) -> some View {
        switch self {
        case .time: Text(time)
        case .app: Text(r.source.rawValue)
        case .model: Text(r.model).font(.system(.body, design: .monospaced))
        case .cost: Text(r.failed ? "—" : money(r.cost, digits: 4))
        case .input: Text(r.input.formatted())
        case .output: Text(r.output.formatted())
        case .cacheRead: Text(abbrev(r.cacheRead))
        case .cacheWrite: Text(abbrev(r.cacheWrite))
        case .hitRate: Text(r.hitRate.map(percent) ?? "—")
        case .speed: Text(r.speed.map { String(format: "%.0f t/s", $0) } ?? "—")
        case .firstToken: Text(seconds(r.firstToken))
        case .duration: Text(seconds(r.duration))
        case .status: Text("\(r.status)").foregroundStyle(r.failed ? Color.red : Color.secondary)
        }
    }
}

func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

/// 7.3s、1m18s
func seconds(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v < 60 ? String(format: "%.1fs", v) : "\(Int(v) / 60)m\(Int(v) % 60)s"
}

// MARK: - 请求详情

/// 从右边滑出的详情面板：基本信息、Tokens、成本明细、性能
struct RequestDetail: View {
    let r: UsageRecord
    let timeFormat: String
    let close: () -> Void

    var body: some View {
        let f = DateFormatter()
        f.dateFormat = timeFormat
        let price = Pricing.breakdown(r)
        return VStack(spacing: 0) {
            HStack {
                Text(L("请求详情")).font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction).help(L("关闭"))
            }
            // 往下让开透明标题栏（那一条点不到按钮），和左边的工具栏对齐
            .padding(.horizontal, 20).padding(.top, 14).frame(height: 66)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(L("基本信息")) {
                        line(L("时间"), f.string(from: r.time))
                        line(L("应用"), r.source.rawValue)
                        line(L("模型"), r.model, mono: true)
                        line(L("状态码"), r.failed ? "\(r.status) · " + L("请求失败") : "\(r.status)")
                        line(L("请求 ID"), r.id, mono: true)
                    }
                    section(L("Tokens 用量")) {
                        line(L("新增输入"), r.input.formatted())
                        line(L("输出"), r.output.formatted())
                        line(L("缓存读取"), r.cacheRead.formatted())
                        line(L("缓存写入"), r.cacheWrite.formatted())
                        line(L("命中率"), r.hitRate.map(percent) ?? "—")
                    }
                    section(L("成本明细（USD）")) {
                        if let p = price {
                            line(L("新增输入"), money(p.input, digits: 4))
                            line(L("输出"), money(p.output, digits: 4))
                            line(L("缓存读取"), money(p.cacheRead, digits: 4))
                            line(L("缓存写入"), money(p.cacheWrite, digits: 4))
                            Divider()
                            line(L("合计"), money(p.input + p.output + p.cacheRead + p.cacheWrite, digits: 4), bold: true)
                        } else {
                            Text(r.failed ? L("失败的请求不计费") : L("models.dev 里没有这个模型的价格"))
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section(L("性能")) {
                        line(L("速度"), r.speed.map { String(format: "%.1f token/s", $0) }
                             ?? (r.output < UsageRecord.minSpeedOutput ? L("输出不到 %d token，不估速度", UsageRecord.minSpeedOutput) : "—"))
                        line(L("首字（估算）"), seconds(r.firstToken))
                        line(L("耗时（估算）"), seconds(r.duration))
                    }
                    Text(L("耗时按会话日志的时间戳估算：从请求发出到最后一段内容写进日志。日志要等一段内容生成完才写，所以首字偏大。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
        .shadow(color: .black.opacity(0.15), radius: 12, x: -2)
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(spacing: 10) { content() }
                .padding(14)
                .modifier(Panel())
        }
    }

    func line(_ title: String, _ value: String, mono: Bool = false, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body.monospacedDigit())
                .fontWeight(bold ? .semibold : .regular)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

// MARK: - 用量卡片

/// 桌面上的用量卡片：各家在所选范围内的估算成本、请求数、Tokens、缓存命中率。
/// 布局和外观有自己的一套设置（一开始沿用额度卡片的）
struct StatsCardView: View {
    @ObservedObject var stats: StatsStore
    let model: UsageModel
    @AppStorage(Pref.statsCardBackground) var background = "none"
    @AppStorage(Pref.statsCardText) var textColor = "white"
    @AppStorage(Pref.statsCardScale) var scale = 1.0
    @AppStorage(Pref.statsCardOpacity) var opacity = 1.0
    @AppStorage(Pref.statsCardBgOpacity) var bgOpacity = 1.0
    @AppStorage(Pref.showClaude) var showClaude = true
    @AppStorage(Pref.showCodex) var showCodex = true
    @AppStorage(Pref.language) var language = "auto"
    @AppStorage(Pref.statsCardLayout) var layout = "horizontal"
    @AppStorage(Pref.statsCardRange) var range = "today"

    var s: CGFloat { CGFloat(scale) }
    var rangeTitle: String { (StatsRange(rawValue: range) ?? .today).title }

    /// 「重置以来」每家按自己的周额度重置时间算
    func summary(_ src: Source) -> Summary {
        let from: Date
        switch range {
        case "cycle": from = stats.cycleStarts[src] ?? StatsRange.week.presetStart
        case "7d": from = StatsRange.week.presetStart
        default: from = StatsRange.today.presetStart
        }
        // all 按时间倒序，取到起点为止
        return Summary(stats.all.prefix { $0.time >= from }.filter { $0.source == src })
    }

    var body: some View {
        let _ = language  // 切换语言时重绘
        let white = textColor == "white"
        let shown = [Source.claude, .codex].filter { $0 == .claude ? showClaude : showCodex }
        VStack(alignment: .leading, spacing: (layout == "compact" ? 10 : 14) * s) {
            if stats.updated == nil {
                Text(L("正在读取本机会话记录…")).font(.system(size: 12 * s)).foregroundStyle(.secondary)
            } else {
                switch layout {
                case "vertical":
                    VStack(alignment: .leading, spacing: 20 * s) { ForEach(shown, id: \.self, content: column) }
                case "compact":
                    VStack(alignment: .leading, spacing: 6 * s) { ForEach(shown, id: \.self, content: compactRow) }
                default:
                    HStack(alignment: .top, spacing: 24 * s) { ForEach(shown, id: \.self, content: column) }
                }
            }
            if let t = stats.updated {
                Text(rangeTitle + " · " + L("更新于 %@", t.formatted(date: .omitted, time: .shortened)))
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
            Button { model.onRefreshStats() } label: { Label(L("立即刷新"), systemImage: "arrow.clockwise") }
            Picker(L("统计范围"), selection: $range) {
                Text(L("今天")).tag("today")
                Text(L("重置以来")).tag("cycle")
                Text(L("近 7 天")).tag("7d")
            }
            Divider()
            Button { model.onOpenStats() } label: { Label(L("打开用量统计…"), systemImage: "chart.bar") }
            Button { model.onCardSettings() } label: { Label(L("卡片设置…"), systemImage: "slider.horizontal.3") }
            Divider()
            Button { model.onHideStats() } label: { Label(L("隐藏用量卡片"), systemImage: "eye.slash") }
        }
    }

    /// 一家一栏：名称、成本（大字），下面是请求数、Tokens、命中率
    func column(_ src: Source) -> some View {
        let sum = summary(src)
        return VStack(alignment: .leading, spacing: 8 * s) {
            Text(src.rawValue).font(.system(size: 13 * s, weight: .semibold))
            Text(money(sum.cost)).font(.system(size: 22 * s, weight: .semibold, design: .rounded).monospacedDigit())
            VStack(spacing: 4 * s) {
                row(L("请求数"), sum.requests.formatted())
                row("Tokens", abbrev(sum.tokens))
                row(L("缓存命中率"), sum.hitRate.map(percent) ?? "—")
            }
        }
        .frame(width: (layout == "vertical" ? CardWindow.wideColumn : CardWindow.column) * s, alignment: .topLeading)
    }

    func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12 * s)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12 * s, weight: .medium).monospacedDigit())
        }
    }

    /// 紧凑：一家一行
    func compactRow(_ src: Source) -> some View {
        let sum = summary(src)
        return HStack(alignment: .firstTextBaseline, spacing: 14 * s) {
            Text(src.rawValue).font(.system(size: 13 * s, weight: .semibold))
                .frame(width: 54 * s, alignment: .leading)
            Text(money(sum.cost)).font(.system(size: 12 * s, weight: .medium).monospacedDigit())
            pair(L("请求数"), sum.requests.formatted())
            pair("Tokens", abbrev(sum.tokens))
        }
    }

    func pair(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
            Text(title).font(.system(size: 11 * s)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12 * s, weight: .medium).monospacedDigit())
        }
    }
}

/// 时间范围面板：上面一排预设，下面自选起止时间
struct RangePopover: View {
    @Binding var rangeRaw: String
    @Binding var customStart: Double
    @Binding var customEnd: Double
    @Binding var customEndNow: Bool
    @Binding var isPresented: Bool
    @State var start: Date
    @State var end: Date
    @State var endNow: Bool
    @State var editingEnd = false

    init(rangeRaw: Binding<String>, customStart: Binding<Double>, customEnd: Binding<Double>,
         customEndNow: Binding<Bool>, isPresented: Binding<Bool>) {
        _rangeRaw = rangeRaw; _customStart = customStart; _customEnd = customEnd
        _customEndNow = customEndNow; _isPresented = isPresented
        let today = Calendar.current.startOfDay(for: Date())
        _start = State(initialValue: customStart.wrappedValue > 0 ? Date(timeIntervalSince1970: customStart.wrappedValue) : today)
        _end = State(initialValue: customEnd.wrappedValue > 0 && !customEndNow.wrappedValue
                     ? Date(timeIntervalSince1970: customEnd.wrappedValue) : Date())
        _endNow = State(initialValue: customEndNow.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(StatsRange.allCases.filter { $0 != .custom }, id: \.self) { r in
                    let selected = rangeRaw == r.rawValue
                    Button { rangeRaw = r.rawValue; isPresented = false } label: {
                        Text(r.title)
                            .fontWeight(selected ? .semibold : .regular)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selected ? 0.12 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("自定义")).font(.callout).foregroundStyle(.secondary)
                    field(L("开始时间"), $start, active: !editingEnd) { editingEnd = false }
                    field(L("结束时间"), $end, active: editingEnd && !endNow) { if !endNow { editingEnd = true } }
                        .disabled(endNow).opacity(endNow ? 0.5 : 1)
                    Toggle(L("结束时间跟随当前时刻"), isOn: Binding(get: { endNow }, set: { on in
                        endNow = on
                        if on { editingEnd = false; end = Date() }
                    }))
                    Spacer(minLength: 0)
                    HStack {
                        Button(L("取消")) { isPresented = false }
                        Spacer()
                        Button(L("确定")) { apply() }.keyboardShortcut(.defaultAction)
                    }
                }
                .frame(width: 230)
                // 日历改的是当前选中的那一个（开始或结束）
                DatePicker("", selection: editingEnd ? $end : $start, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
            }
        }
        .padding(16)
    }

    func field(_ title: String, _ date: Binding<Date>, active: Bool, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field).labelsHidden()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(active ? Color.primary.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: active ? 1.5 : 1))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onTap))
    }

    func apply() {
        var s = start, e = endNow ? Date() : end
        if e < s { swap(&s, &e) }
        customStart = s.timeIntervalSince1970
        customEnd = e.timeIntervalSince1970
        customEndNow = endNow
        rangeRaw = StatsRange.custom.rawValue
        isPresented = false
    }
}

/// 主题色可选的颜色（系统色，深浅色模式下自动调整）：统计图、开关、选中标记
enum ChartColor {
    /// system：跟随 系统设置 → 外观 → 主题颜色（选「多色」时一般是蓝色）
    static let all: [(key: String, name: String, color: Color)] = [
        ("system", "跟随系统", Color(nsColor: .controlAccentColor)),
        ("pink", "粉色", .pink), ("purple", "紫色", .purple), ("blue", "蓝色", .blue), ("teal", "青色", .teal),
        ("green", "绿色", .green), ("orange", "橙色", .orange), ("gray", "灰色", .gray),
    ]
    static func color(_ key: String) -> Color { all.first { $0.key == key }?.color ?? .pink }

    /// 色块：「跟随系统」画成和系统设置里「多色」一样的彩虹圆
    @ViewBuilder static func swatch(_ key: String) -> some View {
        if key == "system" {
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
        } else {
            Circle().fill(color(key))
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
    var recs = LogReader.read(since: StatsRange.week.presetStart)
    for i in recs.indices { recs[i].cost = Pricing.cost(recs[i]) }
    for range in [StatsRange.today, .week] {
        for src in [Source.claude, .codex] {
            let s = Summary(recs.filter { $0.time >= range.presetStart && $0.source == src })
            print("\(range.rawValue) \(src.rawValue): cost \(money(s.cost)) · requests \(s.requests) · tokens \(abbrev(s.tokens))"
                  + " (in \(abbrev(s.input)) out \(abbrev(s.output)) cacheR \(abbrev(s.cacheRead)) cacheW \(abbrev(s.cacheWrite)))"
                  + " · hit \(s.hitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")")
        }
    }
    // 重置以来：先查额度拿到周额度的重置时间
    let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
    for u in [await Claude.fetch(), await Codex.fetch()] {
        guard let src = Source(rawValue: u.name), let reset = u.windows.first(where: \.weekly)?.resetsAt else { continue }
        let start = Date(timeIntervalSince1970: ((reset.timeIntervalSince1970 + 5) / 60).rounded(.down) * 60 - 7 * 86400)
        let s = Summary(recs.filter { $0.time >= start && $0.source == src })
        print("cycle \(src.rawValue) since \(f.string(from: start)) (resets \(f.string(from: reset))): cost \(money(s.cost)) · requests \(s.requests) · tokens \(abbrev(s.tokens))")
    }
    let unpriced = Set(recs.filter { $0.cost == nil }.map(\.model))
    if !unpriced.isEmpty { print("unpriced models:", unpriced.sorted().joined(separator: ", ")) }
}
