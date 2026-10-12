import NotallyCore
import SwiftUI

/// Task list rows: checkbox, subtasks, reorder, checked items at the bottom (auto sort).
struct ListEditor: View {
    @Binding var items: [ListItem]
    let editable: Bool
    let autoSort: Bool
    let fontSize: CGFloat
    let onChange: () -> Void
    @FocusState private var focus: UUID?

    private var firstChecked: Int {
        guard autoSort else { return items.count }
        return ListOps.groups(items).prefix { !$0[0].checked }.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        let split = firstChecked
        Section {
            ForEach(Array(items.indices.prefix(split)), id: \.self) { row($0) }
                .onMove { move($0, $1, offset: 0) }
                .moveDisabled(!editable)
            if editable {
                Button { add(after: split - 1) } label: { Label("Add item", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        if split < items.count {
            Section("\(items.count - split) checked") {
                ForEach(Array(items.indices.suffix(from: split)), id: \.self) { row($0) }
                    .onMove { move($0, $1, offset: split) }
                    .moveDisabled(!editable)
            }
        }
    }

    @ViewBuilder
    private func row(_ index: Int) -> some View {
        if index < items.count {
            let item = items[index]
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle("", isOn: Binding(get: { item.checked }, set: { toggle(index, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!editable)
                TextField("", text: Binding(get: { items[safe: index]?.body ?? "" }, set: { setBody(index, $0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize))
                    .foregroundStyle(item.checked ? .secondary : .primary)
                    .disabled(!editable)
                    .focused($focus, equals: item.id)
                    .onSubmit { add(after: index) }
                    .onKeyPress(keys: [.tab, .delete, KeyEquivalent("\u{19}")]) { press in handleKey(press, index) }
                if editable && item.checked {
                    Button { remove(index) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete item")
                }
            }
            .padding(.leading, item.isChild ? 28 : 0)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .contextMenu {
                if editable {
                    Button(item.isChild ? "Outdent" : "Indent") { indent(index, !item.isChild) }
                        .disabled(index == 0 && !item.isChild)
                    Button("Delete Item", role: .destructive) { remove(index) }
                }
            }
        }
    }

    private func handleKey(_ press: KeyPress, _ index: Int) -> KeyPress.Result {
        guard editable, index < items.count else { return .ignored }
        switch press.key {
        case .tab:
            indent(index, !press.modifiers.contains(.shift))
            return .handled
        case KeyEquivalent("\u{19}"):
            indent(index, false)
            return .handled
        case .delete where items[index].body.isEmpty:
            let previous = index > 0 ? items[index - 1].id : nil
            remove(index)
            focus = previous
            return .handled
        default:
            return .ignored
        }
    }

    private func commit(normalize: Bool = true) {
        if normalize { items = ListOps.normalized(items, autoSort: autoSort) }
        onChange()
    }

    private func setBody(_ index: Int, _ text: String) {
        guard index < items.count else { return }
        // A pasted multi-line text becomes several items.
        let lines = text.components(separatedBy: "\n")
        items[index].body = lines[0]
        if lines.count > 1 {
            let extra = lines.dropFirst().map { ListItem(body: $0, isChild: items[index].isChild) }
            items.insert(contentsOf: extra, at: index + 1)
            commit()
            focus = items[safe: index + extra.count]?.id
        } else {
            commit(normalize: false)
        }
    }

    private func toggle(_ index: Int, _ checked: Bool) {
        ListOps.setChecked(&items, at: index, checked)
        commit()
    }

    private func indent(_ index: Int, _ child: Bool) {
        ListOps.setChild(&items, at: index, child)
        commit()
    }

    private func add(after index: Int) {
        let position = ListOps.insert(&items, after: index < 0 ? nil : index)
        let id = items[position].id
        commit()
        focus = id
    }

    private func remove(_ index: Int) {
        ListOps.remove(&items, at: index)
        commit()
    }

    private func move(_ source: IndexSet, _ destination: Int, offset: Int) {
        ListOps.move(&items, from: IndexSet(source.map { $0 + offset }), to: destination + offset)
        commit()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
