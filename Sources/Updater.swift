// 应用内更新：从 GitHub Releases 查最新版本，下载 zip、校验 SHA-256、替换自身后重启
//   版本号：tag 去掉开头的 v（v1.2.0 → 1.2.0）
//   校验值：Release 说明里的 SHA-256: `<64 位十六进制>`（release.sh 发版时写进去）

import AppKit
import CryptoKit

final class Updater: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, downloading
        case available(String)  // 新版本号
        case failed(String)
    }

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
        let sha256: String?
        let page: URL
    }

    static let repo = "plsy1/UsageBar"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    @Published var state = State.idle
    @Published var release: Release?
    var lastCheck: Date?

    /// 当前版本；测试时可以改成旧版本号
    var currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// 新版装到哪；默认替换正在运行的这个 .app
    var destination = Bundle.main.bundleURL
    /// 装好之后怎么重启；测试时可以换掉
    var relaunch: (URL) -> Void = { app in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 1.10.0 > 1.9.3：按数字逐段比
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// silent：自动检查时用，失败也不显示错误
    func check(silent: Bool = false) {
        if state == .checking || state == .downloading { return }
        if !silent { state = .checking }
        Task {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (status, json) = await httpJSON(req)
            let result = Self.parse(json)
            await MainActor.run {
                self.lastCheck = Date()
                guard status == 200, let r = result else {
                    if !silent { self.state = .failed(L("网络错误")) }
                    return
                }
                if Self.isNewer(r.version, than: self.currentVersion) {
                    self.release = r
                    self.state = .available(r.version)
                } else {
                    self.release = nil
                    if !silent || self.state != .idle { self.state = .upToDate }
                }
            }
        }
    }

    static func parse(_ json: [String: Any]?) -> Release? {
        guard let json, let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let zipURL = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let notes = json["body"] as? String ?? ""
        let sha = notes.range(of: #"SHA-256:\s*`?([0-9a-f]{64})"#, options: .regularExpression)
            .map { String(notes[$0].suffix(64)) }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: notes, zipURL: zipURL, sha256: sha, page: page)
    }

    /// 下载 → 校验 → 解压 → 替换 → 重启
    func install() {
        guard let r = release, state != .downloading else { return }
        state = .downloading
        Task {
            do {
                let app = try await Self.download(r)
                let dest = self.destination
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: app)
                await MainActor.run { self.relaunch(dest) }
            } catch {
                let msg = (error as? UpdateError)?.message
                    ?? ((error as? CocoaError)?.code == .fileWriteNoPermission ? L("没有写入权限") : error.localizedDescription)
                await MainActor.run { self.state = .failed(msg) }
            }
        }
    }

    struct UpdateError: Error { let message: String }

    /// 下载并解压出新的 .app，返回它的位置（还没装）
    static func download(_ r: Release) async throws -> URL {
        guard let expected = r.sha256 else { throw UpdateError(message: L("缺少校验值")) }
        let (tmp, resp) = try await URLSession.shared.download(from: r.zipURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(message: L("网络错误")) }
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw UpdateError(message: L("校验失败")) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("UsageBar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tmp.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = dir.appendingPathComponent("UsageBar.app")
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard unzip.terminationStatus == 0, version == r.version else { throw UpdateError(message: L("安装包不完整")) }
        return app
    }
}
