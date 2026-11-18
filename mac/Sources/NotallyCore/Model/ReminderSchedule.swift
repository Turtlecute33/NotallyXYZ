import Foundation

/// Same rules as NotallyX `Reminder.nextNotification` (ModelExtensions.kt).
extension Reminder {
    public func nextNotification(after from: Date = Date(), calendar: Calendar = .current) -> Date? {
        let start = date
        if from < start { return start }
        guard let rep = repetition else { return nil }

        if rep.unit == .months, let occurrence = rep.occurrence, let weekday = rep.dayOfWeek {
            var month = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
            for _ in 0..<2400 {
                if let target = Self.occurrence(in: month, occurrence, weekday, timeOf: start, calendar), target > from {
                    return target
                }
                guard let next = calendar.date(byAdding: .month, value: rep.value, to: month) else { return nil }
                month = next
            }
            return nil
        }

        if rep.unit == .months || rep.unit == .years {
            // Each occurrence counts from the start, so a day that a short month cut comes back
            // (Jan 31 → Feb 28 → Mar 31). Start at the occurrence in the month of `from` (or the last
            // one before that month). If it is not after `from`, the next one is: it is in a later
            // month. `passed` is one short when a time change skips the midnight that starts the
            // first month, so try one more.
            let (months, overflow) = rep.value.multipliedReportingOverflow(by: rep.unit == .years ? 12 : 1)
            guard !overflow, months > 0,
                  let startMonth = calendar.dateInterval(of: .month, for: start)?.start,
                  let fromMonth = calendar.dateInterval(of: .month, for: from)?.start,
                  let passed = calendar.dateComponents([.month], from: startMonth, to: fromMonth).month else { return nil }
            var k = max(1, passed / months)
            for _ in 0..<3 {
                let (total, overflow) = k.multipliedReportingOverflow(by: months)
                guard !overflow, let next = calendar.date(byAdding: .month, value: total, to: start) else { return nil }
                if next > from { return next }
                k += 1
            }
            return nil
        }

        let component: Calendar.Component
        switch rep.unit {
        case .minutes: component = .minute
        case .hours: component = .hour
        case .days: component = .day
        case .weeks: component = .weekOfYear
        case .months, .years: return nil  // handled above
        }
        var next = start
        // Jump close to `from` first. Minutes and hours have a fixed length; days and weeks are
        // counted in calendar units.
        if rep.unit == .minutes || rep.unit == .hours {
            let step = Double(rep.value) * (rep.unit == .minutes ? 60 : 3600)
            let skip = Int(from.timeIntervalSince(start) / step) - 1
            if skip > 0 { next = start.addingTimeInterval(Double(skip) * step) }
        } else if rep.unit == .days || rep.unit == .weeks,
                  let passed = calendar.dateComponents([component], from: start, to: from).value(for: component) {
            let skip = passed / rep.value - 1
            if skip > 0, let jumped = calendar.date(byAdding: component, value: skip * rep.value, to: start) { next = jumped }
        }
        for _ in 0..<100_000 {
            guard let candidate = calendar.date(byAdding: component, value: rep.value, to: next) else { return nil }
            next = candidate
            if next > from { return next }
        }
        return nil
    }

    static func occurrence(in month: Date, _ occurrence: Int, _ weekday: Int, timeOf time: Date, _ calendar: Calendar) -> Date? {
        let t = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: time)
        let m = calendar.dateComponents([.year, .month], from: month)
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
        let candidates = days.compactMap { day -> Date? in
            var c = DateComponents(year: m.year, month: m.month, day: day, hour: t.hour, minute: t.minute, second: t.second)
            c.nanosecond = t.nanosecond
            guard let d = calendar.date(from: c), calendar.component(.weekday, from: d) == weekday else { return nil }
            return d
        }
        if occurrence == -1 { return candidates.last }
        // A missing 5th occurrence falls back to the last one, like Android.
        return candidates.indices.contains(occurrence - 1) ? candidates[occurrence - 1] : candidates.last
    }
}

extension Note {
    /// The next reminder notification of this note, if any.
    public var nextReminder: Date? {
        reminders.compactMap { $0.nextNotification() }.min()
    }
}
