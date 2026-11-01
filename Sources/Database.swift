// 用量数据库：解析出来的每条请求存一行，日志读到哪里也存在这里（以前是整个放进内存再存成 plist）。
//   位置：~/Library/Application Support/UsageBar/usage.sqlite
//   records：每条请求一行，按时间建了索引；成本也存着（价格表更新时统一重算），汇总可以直接在 SQL 里加
//   files  ：每个日志文件的解析进度（读到第几个字节、解析到一半的状态）
//   meta   ：解析规则的版本、成本按哪一版价格算的
//   日志被 Claude Code 清理掉以后，库里的记录还留着

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 很薄的一层：执行语句、绑参数、逐行读结果。调用方自己负责加锁（LogReader 里统一用一把锁）
final class SQLiteDB {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]  // 预编译过的语句，反复用

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        for s in statements.values { sqlite3_finalize(s) }
        sqlite3_close(db)
    }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    final class Row {
        let s: OpaquePointer
        init(_ s: OpaquePointer) { self.s = s }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
        func optDouble(_ i: Int32) -> Double? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(s, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
        }
    }

    /// 执行一条语句；有结果的话每行调一次 row
    func run(_ sql: String, _ args: [Any?] = [], row: ((Row) -> Void)? = nil) {
        guard let s = statement(sql) else { return }
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(s, n)
            case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
            case let v as Double: sqlite3_bind_double(s, n, v)
            case let v as Date: sqlite3_bind_double(s, n, v.timeIntervalSince1970)
            case let v as String: sqlite3_bind_text(s, n, v, -1, SQLITE_TRANSIENT)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(s, n, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(s, n)
            }
        }
        let r = Row(s)
        while sqlite3_step(s) == SQLITE_ROW { row?(r) }
    }

    private func statement(_ sql: String) -> OpaquePointer? {
        if let s = statements[sql] { return s }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { return nil }
        statements[sql] = s
        return s
    }

    /// 一批写入放在一个事务里：两万行逐条提交要几秒，一个事务里几十毫秒
    func transaction(_ body: () -> Void) {
        exec("BEGIN")
        body()
        exec("COMMIT")
    }
}
