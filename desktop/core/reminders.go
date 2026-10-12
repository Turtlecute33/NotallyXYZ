package core

import "time"

// NextNotification follows NotallyX Reminder.nextNotification (ModelExtensions.kt), in local time.
// Months and years clamp to the last day of the month, like java.util.Calendar.
func NextNotification(r Reminder, from time.Time) (time.Time, bool) {
	start := time.UnixMilli(r.DateTime).In(time.Local)
	if from.Before(start) {
		return start, true
	}
	rep := r.Repetition
	if rep == nil {
		return time.Time{}, false
	}
	value := max(1, rep.Value)

	if rep.Unit == "MONTHS" && rep.Occurrence != nil && rep.DayOfWeek != nil {
		month := time.Date(start.Year(), start.Month(), 1, 0, 0, 0, 0, time.Local)
		for range 2400 {
			if t, ok := occurrence(month, *rep.Occurrence, *rep.DayOfWeek, start); ok && t.After(from) {
				return t, true
			}
			month = time.Date(month.Year(), month.Month()+time.Month(value), 1, 0, 0, 0, 0, time.Local)
		}
		return time.Time{}, false
	}

	var step func(time.Time) time.Time
	switch rep.Unit {
	case "MINUTES", "HOURS":
		d := time.Duration(value) * time.Minute
		if rep.Unit == "HOURS" {
			d = time.Duration(value) * time.Hour
		}
		// Fixed length: jump close to `from` first.
		if skip := int64(from.Sub(start)/d) - 1; skip > 0 {
			start = start.Add(time.Duration(skip) * d)
		}
		step = func(t time.Time) time.Time { return t.Add(d) }
	case "DAYS":
		step = func(t time.Time) time.Time { return t.AddDate(0, 0, value) }
	case "WEEKS":
		step = func(t time.Time) time.Time { return t.AddDate(0, 0, 7*value) }
	case "MONTHS":
		step = func(t time.Time) time.Time { return addMonths(t, value) }
	case "YEARS":
		step = func(t time.Time) time.Time { return addMonths(t, 12*value) }
	default:
		return time.Time{}, false
	}
	next := start
	for range 100_000 {
		next = step(next)
		if next.After(from) {
			return next, true
		}
	}
	return time.Time{}, false
}

func addMonths(t time.Time, n int) time.Time {
	first := time.Date(t.Year(), t.Month()+time.Month(n), 1, t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), t.Location())
	last := time.Date(first.Year(), first.Month()+1, 0, 0, 0, 0, 0, t.Location()).Day()
	return first.AddDate(0, 0, min(t.Day(), last)-1)
}

// occurrence: the n-th (or -1 = last) weekday (1 = Sunday … 7 = Saturday) of a month, at the time of day of `at`.
func occurrence(month time.Time, n, weekday int, at time.Time) (time.Time, bool) {
	var candidates []time.Time
	for d := time.Date(month.Year(), month.Month(), 1, at.Hour(), at.Minute(), at.Second(), at.Nanosecond(), time.Local); d.Month() == month.Month(); d = d.AddDate(0, 0, 1) {
		if int(d.Weekday())+1 == weekday {
			candidates = append(candidates, d)
		}
	}
	if len(candidates) == 0 {
		return time.Time{}, false
	}
	// A missing 5th occurrence falls back to the last one, like Android.
	if n < 1 || n > len(candidates) {
		return candidates[len(candidates)-1], true
	}
	return candidates[n-1], true
}

// NextReminder is the next reminder notification of a note after `from`.
func NextReminder(n Note, from time.Time) (time.Time, bool) {
	var best time.Time
	found := false
	for _, r := range n.Reminders {
		if t, ok := NextNotification(r, from); ok && (!found || t.Before(best)) {
			best, found = t, true
		}
	}
	return best, found
}

// DueReminders are notes with a reminder notification in (after, until].
func DueReminders(notes []Note, after, until time.Time) []Note {
	var out []Note
	for _, n := range notes {
		if n.Folder == FolderDeleted {
			continue
		}
		if t, ok := NextReminder(n, after); ok && !t.After(until) {
			out = append(out, n)
		}
	}
	return out
}
