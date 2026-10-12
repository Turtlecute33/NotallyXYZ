import NotallyCore
import SwiftUI

struct LabelPicker: View {
    @Binding var selected: [String]
    @Environment(AppModel.self) private var model
    @State private var newLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Labels").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.store?.sortedLabels ?? []) { label in
                        Toggle(label.value, isOn: Binding(
                            get: { selected.contains(label.value) },
                            set: { on in
                                if on { selected.append(label.value) } else { selected.removeAll { $0 == label.value } }
                            }))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                TextField("New label", text: $newLabel).onSubmit(add)
                Button("Add", action: add).disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func add() {
        let value = newLabel.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        model.store?.createLabel(value)
        if !selected.contains(value) { selected.append(value) }
        newLabel = ""
    }
}

struct ColorPickerView: View {
    @Binding var color: String
    @State private var custom = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 6), spacing: 10) {
                ForEach(NoteColor.presets, id: \.hex) { preset in
                    swatch(preset.hex).help(preset.name)
                }
            }
            ColorPicker("Custom color", selection: Binding(get: { custom }, set: { new in
                custom = new
                if let c = NSColor(new).usingColorSpace(.sRGB) {
                    color = NoteColor.hex(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
                }
            }), supportsOpacity: false)
        }
        .padding(14)
        .onAppear { if let c = Theme.color(color) { custom = c } }
    }

    private func swatch(_ hex: String) -> some View {
        let selected = color.caseInsensitiveCompare(hex) == .orderedSame
        return Circle()
            .fill(Theme.color(hex) ?? Color(nsColor: .textBackgroundColor))
            .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
            .overlay {
                if selected { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.darkText) }
                else if hex == NoteColor.defaultValue { Image(systemName: "drop").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .onTapGesture { color = hex }
    }
}
