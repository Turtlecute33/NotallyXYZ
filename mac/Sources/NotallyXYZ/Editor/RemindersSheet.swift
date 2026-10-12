import NotallyCore
import SwiftUI

/// List, add, edit and remove reminders of one note.
struct RemindersSheet: View {
    @Binding var note: [Reminder]
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Reminder?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reminders").font(.title3.weight(.medium))
            if note.isEmpty {
                Text("No reminders").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List {
                    ForEach(note) { reminder in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Format.full(reminder.nextNotification() ?? reminder.date))
                                    .foregroundStyle(reminder.nextNotification() == nil ? .secondary : .primary)
                                if let rep = reminder.repetition {
                                    Text(Format.repetition(rep)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Edit") { editing = reminder }
                            Button(role: .destructive) { note.removeAll { $0.id == reminder.id } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(minHeight: 140)
            }
            HStack {
                Button("Add Reminder") {
                    let next = Date().addingTimeInterval(3600)
                    editing = Reminder(id: (note.map(\.id).max() ?? -1) + 1,
                                       dateTime: Int64(next.timeIntervalSince1970 * 1000), repetition: nil)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .sheet(item: $editing) { reminder in
            ReminderForm(reminder: reminder) { saved in
                if let i = note.firstIndex(where: { $0.id == saved.id }) { note[i] = saved } else { note.append(saved) }
            }
        }
    }
}

private struct ReminderForm: View {
    @State var reminder: Reminder
    let onSave: (Reminder) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var repeatMode = 0
    @State private var value = 1
    @State private var unit = RepetitionUnit.days

    var body: some View {
        Form {
            DatePicker("Date", selection: $date)
            Picker("Repeat", selection: $repeatMode) {
                Text("Never").tag(0)
                Text("Daily").tag(1)
                Text("Weekly").tag(2)
                Text("Monthly").tag(3)
                Text("Yearly").tag(4)
                Text("Custom").tag(5)
            }
            if repeatMode == 5 {
                Stepper("Every \(value)", value: $value, in: 1...999)
                Picker("Unit", selection: $unit) {
                    ForEach(RepetitionUnit.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    reminder.dateTime = Int64(date.timeIntervalSince1970 * 1000)
                    reminder.repetition = repetition
                    onSave(reminder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private var repetition: Repetition? {
        switch repeatMode {
        case 1: return Repetition(value: 1, unit: .days)
        case 2: return Repetition(value: 1, unit: .weeks)
        case 3: return keepMonthlyRule(Repetition(value: 1, unit: .months))
        case 4: return Repetition(value: 1, unit: .years)
        case 5: return keepMonthlyRule(Repetition(value: value, unit: unit))
        default: return nil
        }
    }

    /// Keeps an "nth weekday of the month" rule made on Android if the user did not change it.
    private func keepMonthlyRule(_ rep: Repetition) -> Repetition {
        guard let old = reminder.repetition, old.unit == .months, rep.unit == .months, old.value == rep.value else { return rep }
        return old
    }

    private func load() {
        date = reminder.date
        guard let rep = reminder.repetition else { return }
        value = rep.value
        unit = rep.unit
        switch (rep.value, rep.unit, rep.occurrence) {
        case (1, .days, _): repeatMode = 1
        case (1, .weeks, _): repeatMode = 2
        case (1, .months, nil): repeatMode = 3
        case (1, .years, _): repeatMode = 4
        default: repeatMode = 5
        }
    }
}
