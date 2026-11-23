import Foundation
import AppKit
import UserNotifications
import CircleCore

/// Local notifications for todo reminders. Each reminder gets the main alert plus
/// follow-ups every `renotify_minutes` until it is done or snoozed, so a dismissed
/// or ignored notification comes back.
@MainActor
final class Reminders: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private weak var app: AppModel?
    /// What is currently scheduled: id -> (remindAt, title) it was scheduled for.
    /// Kept per vault: syncing one vault never cancels another vault's reminders.
    private var byVault: [String: [String: String]] = [:]
    private var vault: String { app?.store.vault ?? "" }
    private var scheduled: [String: String] {
        get { byVault[vault] ?? [:] }
        set { byVault[vault] = newValue }
    }
    private var authorized = false
    private var asked = false

    static let category = "circle.reminder"

    init(app: AppModel) {
        self.app = app
        super.init()
        center.delegate = self
        let done = UNNotificationAction(identifier: "done", title: "Done", options: [])
        let s30 = UNNotificationAction(identifier: "snooze30", title: "30 min", options: [])
        let s60 = UNNotificationAction(identifier: "snooze60", title: "1 hour", options: [])
        let tmrw = UNNotificationAction(identifier: "tomorrow", title: "Tomorrow", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [done, s30, s60, tmrw],
                                   intentIdentifiers: [], options: [.customDismissAction]),
        ])
        center.getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { self.authorized = ok }
        }
    }

    /// Reconciles pending notifications with the todos. Called after every change; cheap when nothing moved.
    func sync(_ todos: [Todo]) {
        let settings = Settings.shared
        let wanted = todos.filter { !$0.deleted && !$0.done && $0.remindAt > 0 && !$0.isSection }
            .sorted { $0.remindAt < $1.remindAt }
        var next: [String: String] = [:]
        for t in wanted { next[t.id] = "\(t.remindAt)|\(t.title)|\(settings.renotifyMinutes)|\(settings.renotifyCount)" }
        guard next != scheduled else { return }
        if !wanted.isEmpty { ensureAuthorized() }

        let gone = scheduled.keys.filter { next[$0] != scheduled[$0] }
        if !gone.isEmpty { center.removePendingNotificationRequests(withIdentifiers: gone.flatMap { ids(for: $0) }) }

        // macOS caps pending notifications, so only the nearest reminders get follow-ups.
        for (i, t) in wanted.enumerated() where scheduled[t.id] != next[t.id] {
            schedule(t, followUps: i < 10 ? settings.renotifyCount : 0, every: settings.renotifyMinutes)
        }
        scheduled = next
    }

    private func ids(for id: String) -> [String] { (0...12).map { "r-\(id)-\($0)" } }

    private func schedule(_ t: Todo, followUps: Int, every minutes: Int) {
        let due = Date(timeIntervalSince1970: Double(t.remindAt) / 1000)
        let now = Date()
        for n in 0...max(0, min(followUps, 12)) {
            if n > 0 && minutes <= 0 { break }
            let fire = due.addingTimeInterval(Double(n * minutes * 60))
            // Overdue reminders fire right away (once), then keep nagging on schedule.
            if fire < now && n > 0 && fire.addingTimeInterval(Double(minutes * 60)) < now { continue }
            let c = UNMutableNotificationContent()
            c.title = t.displayTitle.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            // Title only: the notes may be an agent's hand-back, which read as a fresh reply.
            c.body = n == 0 ? "" : "still open · \(n * minutes) min"
            c.sound = .default
            c.categoryIdentifier = Self.category
            c.threadIdentifier = t.id
            c.userInfo = ["id": t.id, "vault": vault]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: "r-\(t.id)-\(n)", content: c, trigger: trigger))
        }
    }

    private func ensureAuthorized() {
        guard !authorized, !asked else { return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            DispatchQueue.main.async {
                self.authorized = ok
                if !ok { self.app?.say("notifications are off for Circle (System Settings → Notifications)") }
            }
        }
    }

    /// Stop the nagging for one todo (done, snoozed, deleted).
    private func clear(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: ids(for: id))
        center.removeDeliveredNotifications(withIdentifiers: ids(for: id))
        scheduled[id] = nil
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["id"] as? String
        let vault = response.notification.request.content.userInfo["vault"] as? String ?? ""
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            defer { done() }
            // A reminder from another vault: open that vault first.
            if let app = self.app, vault != app.store.vault { app.openVault(vault) }
            guard let id, let app = self.app, let t = app.store.todo(id) else { return }
            let now = Date()
            switch action {
            case "done":
                self.clear(id)
                if !t.done { app.store.toggle(id) }
            case "snooze30", "snooze60":
                self.clear(id)
                let mins = action == "snooze30" ? 30 : 60
                app.store.setReminder(id, at: Int64(now.addingTimeInterval(Double(mins * 60)).timeIntervalSince1970 * 1000), rule: t.repeatRule)
            case "tomorrow":
                self.clear(id)
                let cal = Calendar.current
                let d = cal.date(bySettingHour: Settings.shared.reminderHour, minute: 0, second: 0,
                                 of: cal.date(byAdding: .day, value: 1, to: now)!)!
                app.store.setReminder(id, at: Int64(d.timeIntervalSince1970 * 1000), rule: t.repeatRule)
            case UNNotificationDismissActionIdentifier:
                break   // dismissed is not handled: follow-ups keep coming
            default:
                NSApp.activate(ignoringOtherApps: true)
                app.reveal(id)
            }
        }
    }
}
