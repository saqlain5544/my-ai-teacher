import SwiftUI

/// Settings → Agents: the limits and defaults the teacher chooses sub-agents within, and app-level agent types.
struct AgentsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var editing: AgentDefinition?

    var body: some View {
        Form {
            Section("Default budget (when the teacher doesn't give one)") {
                Stepper("Model calls: \(a.steps)", value: $settings.value.agents.steps, in: 1...max(1, a.maxSteps))
                Stepper("Time: \(a.seconds) s", value: $settings.value.agents.seconds, in: 10...max(10, a.maxSeconds), step: 10)
                Stepper("Tokens: \(a.tokens == 0 ? "no limit" : AgentBudget.short(a.tokens))", value: $settings.value.agents.tokens, in: 0...a.maxTokens, step: 10_000)
                Picker("Reasoning effort", selection: $settings.value.agents.effort) {
                    ForEach(ThinkingLevel.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section("Limits") {
                Stepper("At most \(a.maxSteps) model calls per run", value: $settings.value.agents.maxSteps, in: 1...500, step: 5)
                Stepper("At most \(a.maxSeconds / 60) min per run", value: $settings.value.agents.maxSeconds, in: 60...14_400, step: 60)
                Stepper("At most \(AgentBudget.short(a.maxTokens)) tokens per run", value: $settings.value.agents.maxTokens, in: 10_000...50_000_000, step: 100_000)
                Toggle("Allow unbounded runs (background only, always stoppable)", isOn: $settings.value.agents.allowUnbounded)
                Stepper("\(a.maxConcurrent) running at once per lesson", value: $settings.value.agents.maxConcurrent, in: 1...12)
                Stepper("Nesting: sub-agents \(a.maxDepth == 1 ? "can't start their own" : "may nest \(a.maxDepth) deep")", value: $settings.value.agents.maxDepth, in: 1...4)
                Toggle("Other providers with a key, not only the lesson's", isOn: $settings.value.agents.otherProviders)
                Toggle("Paid models on other providers", isOn: $settings.value.agents.paidModels).disabled(!a.otherProviders)
                Text("A lesson on a free model only ever delegates to free models. Sub-agents never get more access than the lesson: they can't ask for approval, and read-only types never write.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent types") {
                ForEach(AgentCatalog.builtIns) { d in row(d) }
                ForEach(a.definitions) { d in
                    row(d).contextMenu {
                        Button("Edit…") { editing = d }
                        Button("Delete", role: .destructive) { settings.value.agents.definitions.removeAll { $0.name == d.name } }
                    }
                    .onTapGesture(count: 2) { editing = d }
                }
                Button { editing = AgentDefinition(name: "", description: "", prompt: "", tools: AgentCatalog.research) } label: { Label("Add agent type", systemImage: "plus") }
                Text("Projects can define their own in .teacher/agents/*.md (frontmatter: name, description, tools, deny, read_only, provider, model, effort, max_steps, max_seconds, max_tokens; the body is the system prompt). Built-in names can't be redefined.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Skills") {
                Picker("Agent", selection: $skillsFor) {
                    Text("Teacher (every teaching mode)").tag("tutor")
                    Text("Language mentor").tag("language")
                    Text("Code mentor").tag("code-mentor")
                    Text("Code agent").tag("engineer")
                }
                let skills = Skills.available(node: skillsFor, folder: AppModel.shared.workspace.url)
                ForEach(skills, id: \.name) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.name).font(.body.monospaced())
                        Text(s.description).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(s.description)
                        Spacer()
                        Text(s.source.label).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text("Each agent names its skills in one line and loads one (`skill`) when a task needs it. Every agent has the base skills; each adds its own. Yours, for every agent: ~/.teacher/skills, ~/.claude/skills, ~/.config/opencode/skills, ~/.agents/skills. A folder's own: .teacher/skills, .claude/skills, .opencode/skills, .agents/skills (it wins on a name clash). A skill is a folder with a SKILL.md: front matter `name`, `description` and optionally `agents: [code-agent, code-mentor, language-mentor, teacher]`, then its instructions.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { NSWorkspace.shared.open(Self.userSkills()) } label: { Label("Open your skills folder", systemImage: "folder") }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { d in
            AgentTypeEditor(draft: d) { saved in
                settings.value.agents.definitions.removeAll { $0.name == d.name || $0.name == saved.name }
                settings.value.agents.definitions.append(saved)
            }
        }
    }

    private var a: SubAgentSettings { settings.value.agents }
    @State private var skillsFor = "engineer"

    /// ~/.teacher/skills, made on first use so the button always opens something.
    private static func userSkills() -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".teacher/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func row(_ d: AgentDefinition) -> some View {
        HStack {
            Text(d.name).font(.body.monospaced())
            if d.readOnly { Image(systemName: "eye").foregroundStyle(.secondary).help("Read-only") }
            Text(d.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(d.source == .builtIn ? "built in" : "app").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

private struct AgentTypeEditor: View {
    @State var draft: AgentDefinition
    let save: (AgentDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tools = ""
    @State private var deny = ""

    var body: some View {
        Form {
            TextField("Name (what the teacher passes as type)", text: $draft.name)
            TextField("Description", text: $draft.description)
            Toggle("Read-only (never changes files)", isOn: $draft.readOnly)
            TextField("Tools (comma-separated; empty = the general set)", text: $tools)
            TextField("Never these tools", text: $deny)
            TextField("Provider (optional)", text: Binding(get: { draft.provider ?? "" }, set: { draft.provider = $0.isEmpty ? nil : $0 }))
            TextField("Model (optional)", text: Binding(get: { draft.model ?? "" }, set: { draft.model = $0.isEmpty ? nil : $0 }))
            Picker("Effort", selection: Binding(get: { draft.effort?.rawValue ?? "" }, set: { draft.effort = ThinkingLevel(rawValue: $0) })) {
                Text("Default").tag("")
                ForEach(ThinkingLevel.allCases) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            TextField("Max steps (optional)", value: $draft.budget.steps, format: .number)
            TextField("Max seconds (optional)", value: $draft.budget.seconds, format: .number)
            Section("System prompt") { TextEditor(text: $draft.prompt).font(.body.monospaced()).frame(minHeight: 120) }
            HStack {
                Text("Tools: " + ToolRegistry.subagentPool.map(\.name).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var d = draft
                    d.name = AgentDefinition.normalized(d.name)
                    let list = { (s: String) in s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    d.tools = list(tools).isEmpty ? nil : list(tools)
                    d.deny = list(deny)
                    d.source = .app
                    save(d)
                    dismiss()
                }
                .disabled(AgentDefinition.normalized(draft.name).isEmpty || AgentCatalog.builtIns.contains { $0.name == AgentDefinition.normalized(draft.name) })
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 600)
        .onAppear { tools = draft.tools?.joined(separator: ", ") ?? ""; deny = draft.deny.joined(separator: ", ") }
    }
}
