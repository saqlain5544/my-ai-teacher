import SwiftUI

/// Settings → Hooks: the user's own hooks for every lesson (Claude Code's JSON), and the folders whose own hooks
/// (`.claude/settings.json`) they approved.
struct HooksSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        Form {
            Section("Your hooks") {
                Text("Shell commands run at steps of the agent's work, in Claude Code's format. PreToolUse runs before a tool call (exit 2 blocks it, stderr tells the agent why); PostToolUse after one (a formatter after an edit; its output reaches the agent); UserPromptSubmit when you send a message (its output becomes context; exit 2 holds the message back); Stop when the agent would finish (exit 2 sends it back to work). Each gets the event as JSON on stdin, in the folder, with a timeout (60 s unless set).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 170)
                let check = HookSet.parse(text: text)
                if check.set == nil {
                    Label("Not valid JSON.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                } else if let set = check.set, !set.isEmpty || !check.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(check.problems, id: \.self) { Text($0).foregroundStyle(.orange) }
                        ForEach(set.lines, id: \.self) { Text($0).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }.font(.caption.monospaced())
                }
                HStack {
                    Button("Insert example") { text = Self.example }.disabled(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Revert") { text = settings.value.hooks }.disabled(text == settings.value.hooks)
                    Button("Save") { settings.value.hooks = text }
                        .disabled(text == settings.value.hooks || check.set == nil)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            Section("Folders' own hooks") {
                Text("Hooks in a folder's .claude/settings.json (and settings.local.json) run only once you approve them, at the agent's first step in a lesson there. A changed configuration is asked about again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if settings.value.approvedHooks.isEmpty { Text("No folder's hooks are approved.").foregroundStyle(.secondary) }
                ForEach(settings.value.approvedHooks.keys.sorted(), id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).lastPathComponent).lineLimit(1)
                        Text(path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Revoke") { settings.value.approvedHooks.removeValue(forKey: path) }.controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if !loaded { text = settings.value.hooks; loaded = true } }
    }

    static let example = """
    {
      "PostToolUse": [
        {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write", "timeout": 30}]}
      ],
      "PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "if jq -r '.tool_input.command' | grep -q 'git push'; then echo 'Ask me before pushing.' >&2; exit 2; fi"}]}
      ]
    }
    """
}
