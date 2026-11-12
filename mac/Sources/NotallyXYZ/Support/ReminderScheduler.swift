import Foundation
import NotallyCore
import UserNotifications

/// Local notifications for reminders. The soonest occurrences (all of the next day, at least one per
/// reminder) are scheduled, at most 60 (macOS keeps 64 pending). The list is rebuilt after every
/// change and, by AppModel, before the scheduled ones run out.
enum ReminderScheduler {
    static let maxPending = 60
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    /// Returns the date of the last scheduled notification.
    @discardableResult
    static func reschedule(_ notes: [Note]) -> Date? {
        guard let center else { return nil }
        let now = Date(), horizon = now.addingTimeInterval(24 * 3600)
        var pending: [(Date, Note, Reminder)] = []
        for note in notes where note.folder == .notes {
            for reminder in note.reminders {
                var from = now
                for _ in 0..<maxPending {
                    guard let next = reminder.nextNotification(after: from) else { break }
                    pending.append((next, note, reminder))
                    if next > horizon { break }
                    from = next
                }
            }
        }
        pending.sort { $0.0 < $1.0 }
        let due = Array(pending.prefix(maxPending))
        center.removeAllPendingNotificationRequests()
        guard !due.isEmpty else { return nil }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for (index, (date, note, reminder)) in due.enumerated() {
                // Title only: the system stores notifications on disk in plain text.
                let content = UNMutableNotificationContent()
                content.title = note.title.isEmpty ? "Reminder" : note.title
                content.sound = .default
                content.userInfo = ["noteId": note.id]
                content.threadIdentifier = note.id
                // With the time zone, it fires at the same moment as on Android, also after a time zone change.
                let parts = Calendar.current.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                let request = UNNotificationRequest(
                    identifier: "\(note.id).\(reminder.id).\(index)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                center.add(request)
            }
        }
        return due.last?.0
    }

    static func removeAll() {
        center?.removeAllPendingNotificationRequests()
        center?.removeAllDeliveredNotifications()
    }
}
