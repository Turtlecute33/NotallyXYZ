import Foundation
import NotallyCore
import UserNotifications

/// Local notifications for reminders. The next 3 occurrences of each reminder are scheduled
/// (macOS keeps at most 64 pending), and the list is rebuilt after every change.
enum ReminderScheduler {
    static let maxPending = 60
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    static func reschedule(_ notes: [Note]) {
        guard let center else { return }
        let now = Date()
        var pending: [(Date, Note, Reminder)] = []
        for note in notes where note.folder == .notes {
            for reminder in note.reminders {
                var from = now
                for _ in 0..<3 {
                    guard let next = reminder.nextNotification(after: from) else { break }
                    pending.append((next, note, reminder))
                    from = next
                }
            }
        }
        pending.sort { $0.0 < $1.0 }
        center.removeAllPendingNotificationRequests()
        guard !pending.isEmpty else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for (index, (date, note, reminder)) in pending.prefix(maxPending).enumerated() {
                let content = UNMutableNotificationContent()
                content.title = note.title.isEmpty ? "Reminder" : note.title
                content.body = preview(note)
                content.sound = .default
                content.userInfo = ["noteId": note.id]
                content.threadIdentifier = note.id
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let request = UNNotificationRequest(
                    identifier: "\(note.id).\(reminder.id).\(index)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                center.add(request)
            }
        }
    }

    static func removeAll() {
        center?.removeAllPendingNotificationRequests()
        center?.removeAllDeliveredNotifications()
    }

    private static func preview(_ note: Note) -> String {
        let text = note.type == .list
            ? note.items.filter { !$0.checked }.map(\.body).joined(separator: ", ")
            : note.body
        return String(text.prefix(120))
    }
}
