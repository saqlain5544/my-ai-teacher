import SwiftUI

/// Settings → Instructions: every agent's standing instructions, editable. The defaults are short on purpose; an edit
/// replaces the default for lessons started afterwards (a lesson keeps the instructions it began with), and Reset
/// restores it.
struct InstructionsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: Instructions.Key = .teacher

    var body: some View {
        HSplitView {
            List(Instructions.all, selection: Binding(get: { selection }, set: { if let k = $0 { selection = k } })) { key in
                HStack {
                    Text(key.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if Instructions.isEdited(key, settings.value) {
                        Text("edited").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .tag(key)
            }
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            editor(selection).frame(minWidth: 380)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 600)
    }

    private func editor(_ key: Instructions.Key) -> some View {
        let text = Binding<String>(
            get: { settings.value.instructions[key.raw] ?? Instructions.defaultText(key) },
            set: { new in
                if new == Instructions.defaultText(key) || new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settings.value.instructions[key.raw] = nil
                } else {
                    settings.value.instructions[key.raw] = new
                }
            })
        let current = Instructions.text(key, settings.value)
        return VStack(alignment: .leading, spacing: 8) {
            Text(key.title).font(.headline)
            Text(key.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            HStack {
                Text("≈ \(ContextPolicy.estimate(current)) tokens").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !key.placeholders.isEmpty {
                    Text("Filled in by the app: " + key.placeholders.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to default") { settings.value.instructions[key.raw] = nil }
                    .disabled(!Instructions.isEdited(key, settings.value))
            }
            Text("Changes apply to lessons you start from now on; a lesson keeps the instructions it began with.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
    }
}
