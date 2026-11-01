import Foundation
import UserNotifications

// MARK: - 额度通知
//   每次查完额度看一遍：用量到了设定的比例、按现在的速度会在重置前用完、额度重置了、Codex 的重置次数快到期。
//   同一件事只提醒一次：发过的记下来（键里带着这个周期的重置时间），下个周期才会再提醒

enum Notifier {
    /// 用量达到多少时提醒：0 是不提醒
    static let thresholdKey = "notifyThreshold"
    static let runOutKey = "notifyRunOut"
    static let resetKey = "notifyReset"
    static let creditsKey = "notifyCredits"
    private static let sentKey = "notifySent"

    static var anyEnabled: Bool {
        let d = UserDefaults.standard
        return d.integer(forKey: thresholdKey) > 0 || d.bool(forKey: runOutKey) || d.bool(forKey: resetKey) || d.bool(forKey: creditsKey)
    }

    /// 打开任一项通知时请求权限（系统只问一次，之后在 系统设置 → 通知 里改）；返回是否允许
    @discardableResult
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }

    /// 上一次的结果：用来发现「额度重置了」
    @MainActor private static var last: [String: LimitWindow] = [:]

    static func check(_ results: [ProviderUsage]) {
        guard anyEnabled else { return }
        Task {
            let ok = await authorized()
            await MainActor.run { evaluate(results, canSend: ok) }
        }
    }

    /// canSend：没有通知权限时不发也不记，等允许了下次刷新再提醒
    @MainActor private static func evaluate(_ results: [ProviderUsage], canSend: Bool) {
        let d = UserDefaults.standard
        let threshold = d.integer(forKey: thresholdKey)
        var sent = d.stringArray(forKey: sentKey) ?? []
        var changed = false
        func once(_ key: String, _ title: String, _ body: String) {
            guard canSend, !sent.contains(key) else { return }
            sent.append(key); changed = true
            send(key, title, body)
        }
        for u in results where u.error == nil {
            // 用位置当键，不用显示名：显示名跟着界面语言变，换了语言会重复提醒
            for (i, w) in u.windows.enumerated() {
                let id = "\(u.name)|\(i)"
                // 接口给的重置时间常是 05:59:59.x，取到分钟，同一个周期的键才稳定
                let cycle = w.resetsAt.map { Int(($0.timeIntervalSince1970 + 5) / 60) } ?? 0
                let name = "\(u.name) · \(w.label)"
                if threshold > 0, w.usedPercent >= Double(threshold) {
                    once("usage|\(id)|\(cycle)|\(threshold)", L("%@ 已用 %d%%", name, Int(w.usedPercent.rounded())),
                         w.resetsAt == nil ? "" : resetText(w.resetsAt))
                }
                // 用了三成以上才提醒，周期刚开始时速度不准
                if d.bool(forKey: runOutKey), w.usedPercent >= 30, let t = w.runsOutAt {
                    once("runout|\(id)|\(cycle)", L("%@ 用得比时间快", name),
                         L("按现在的速度预计 %@ 用完，%@", shortTime(t), resetText(w.resetsAt)))
                }
                // 重置时间往后跳了、用量也降下来了，就是重置了；之前用了一半以上才值得说
                if d.bool(forKey: resetKey), let old = last[id], let o = old.resetsAt, let n = w.resetsAt,
                   n.timeIntervalSince(o) > 60, w.usedPercent < old.usedPercent, old.usedPercent >= 50 {
                    once("reset|\(id)|\(cycle)", L("%@ 已重置", name), L("重置前用了 %d%%", Int(old.usedPercent.rounded())))
                }
                last[id] = w
            }
            if d.bool(forKey: creditsKey), let rc = u.resetCredits {
                for e in rc.expiries where e > Date() && e.timeIntervalSinceNow < 86400 {
                    once("credit|\(Int(e.timeIntervalSince1970))", L("Codex 的额度重置次数快到期了"),
                         L("有 1 次重置将在 %@ 到期，用不掉就作废", shortTime(e)))
                }
            }
        }
        if changed { d.set(Array(sent.suffix(300)), forKey: sentKey) }
    }

    private static func send(_ id: String, _ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

/// app 在前台时也显示横幅（默认前台不显示）
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
