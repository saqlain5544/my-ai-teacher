import SwiftUI

/// Settings → MCP: the user's own servers (for every agent, in every folder), the open folder's `.mcp.json` servers
/// (approved or declined here, or when the agent first loads one), and each server's state for this folder: running or
/// not, its pid, restarts, tools, and the last of what it wrote to stderr.
struct MCPSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel
    @State private var editing: MCPServerConfig?
    @State private var importing = false
    @State private var logShown: String?
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var folder: URL { app.workspace.url }

    var body: some View {
        let _ = tick   // redrawn every second: servers start, crash and restart on their own
        let entries = MCPConfig.entries(folder, settings.value)
        let project = MCPConfig.project(folder)
        Form {
            Section {
                Text("MCP servers give the teacher more tools: `mcp__<server>__<tool>`, loaded when it needs them. Every call is asked unless you always allow that server in the folder. Servers start on first use and end with the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your servers (every folder)") {
                ForEach(settings.value.mcpServers) { c in
                    row(c, entry: entries.first { $0.config == c })
                        .contextMenu {
                            Button("Edit…") { editing = c }
                            Button("Delete", role: .destructive) { remove(c) }
                        }
                        .onTapGesture(count: 2) { editing = c }
                }
                HStack {
                    Button { editing = MCPServerConfig(name: "") } label: { Label("Add server", systemImage: "plus") }
                    Button { importing = true } label: { Label("Add from JSON…", systemImage: "curlybraces") }
                }
                .buttonStyle(.borderless)
            }
            Section("This folder's .mcp.json (\(folder.lastPathComponent))") {
                if let e = project.error { Text(e).foregroundStyle(.red).font(.caption) }
                if project.servers.isEmpty && project.error == nil {
                    Text("No .mcp.json here. A project's servers (Claude Code's format) run only after you approve each one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(project.servers) { c in row(c, entry: entries.first { $0.config == c }) }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in tick &+= 1 }
        .sheet(item: $editing) { c in
            MCPServerEditor(draft: c, taken: settings.value.mcpServers.map(\.name).filter { $0 != c.name }) { saved in
                if !c.name.isEmpty { stopEverywhere(c) }
                if let i = settings.value.mcpServers.firstIndex(where: { $0.name == c.name && !c.name.isEmpty }) { settings.value.mcpServers[i] = saved }
                else { settings.value.mcpServers.append(saved) }
            }
        }
        .sheet(isPresented: $importing) {
            MCPImportSheet(taken: settings.value.mcpServers.map(\.name)) { added in settings.value.mcpServers += added }
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ c: MCPServerConfig, entry: MCPConfig.Entry?) -> some View {
        let standing = entry?.standing ?? (c.scope == .project ? .needsApproval : .disabled)
        let live = MCPHub.shared.existing(c.name, folder: folder).flatMap { $0.config.fingerprint == c.fingerprint ? $0 : nil }
        let status = live?.status
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color(standing, status?.phase)).frame(width: 8, height: 8)
                Text(c.name).font(.body.monospaced())
                Text(c.isHTTP ? "HTTP" : c.type == "sse" ? "SSE" : "stdio").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                actions(c, standing: standing, live: live)
            }
            Text(c.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text(entry == nil && c.scope == .app && c.enabled ? "This folder's .mcp.json has a server of the same name, which it uses instead."
                 : statusLine(c, standing: standing, status: status)).font(.caption).foregroundStyle(status?.phase == .failed ? .red : .secondary)
            if standing == .usable {
                Toggle("Always allow its tools in this folder", isOn: Binding(
                    get: { (settings.value.mcpAlwaysAllow[folder.path] ?? []).contains(c.name) },
                    set: { on in
                        var names = settings.value.mcpAlwaysAllow[folder.path] ?? []
                        names.removeAll { $0 == c.name }
                        if on { names.append(c.name) }
                        settings.value.mcpAlwaysAllow[folder.path] = names.isEmpty ? nil : names
                    })).font(.caption).toggleStyle(.checkbox)
            }
            if logShown == c.id, let live {
                ScrollView {
                    Text(live.log.text.isEmpty ? "(nothing yet)" : live.log.text).font(.caption2.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140).padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func actions(_ c: MCPServerConfig, standing: MCPConfig.Standing, live: MCPInstance?) -> some View {
        let phase = live?.status.phase ?? .idle
        let running = [.starting, .ready, .restarting].contains(phase)
        HStack(spacing: 6) {
            switch standing {
            case .needsApproval:
                Button("Approve") { decide(c, true) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Decline") { decide(c, false) }.controlSize(.small)
            case .declined:
                Button("Allow") { decide(c, true) }.controlSize(.small)
            case .usable, .disabled, .unsupported:
                if standing == .usable {
                    if running {
                        Button("Restart") { Task { await live?.stop(); _ = try? await MCPHub.shared.instance(c, folder: folder).connection() } }.controlSize(.small)
                        Button("Stop") { Task { await live?.stop() } }.controlSize(.small)
                    } else {
                        Button("Start") { Task { _ = try? await MCPHub.shared.instance(c, folder: folder).connection() } }.controlSize(.small)
                    }
                }
                if c.scope == .project {
                    Button("Revoke") { revoke(c) }.controlSize(.small).help("Forget the approval: the agent asks again before it runs")
                }
            }
            if live != nil {
                Button { logShown = logShown == c.id ? nil : c.id } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.borderless).help("Its log (stderr)")
            }
            if c.scope == .app {
                Toggle("", isOn: Binding(get: { c.enabled }, set: { on in
                    guard let i = settings.value.mcpServers.firstIndex(where: { $0.name == c.name }) else { return }
                    settings.value.mcpServers[i].enabled = on
                    if !on { stopEverywhere(c) }
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    private func color(_ standing: MCPConfig.Standing, _ phase: MCPInstance.Phase?) -> Color {
        guard standing == .usable else { return standing == .needsApproval ? .orange : .gray.opacity(0.5) }
        switch phase ?? .idle {
        case .ready: return .green
        case .starting, .restarting: return .yellow
        case .failed: return .red
        case .idle, .stopped: return .gray
        }
    }

    private func statusLine(_ c: MCPServerConfig, standing: MCPConfig.Standing, status: MCPInstance.Status?) -> String {
        switch standing {
        case .needsApproval: return "Not approved: nothing runs until you approve it (here, or when the agent asks)."
        case .declined: return "Declined: the agent can't use it in this folder."
        case .disabled: return "Off."
        case .unsupported: return "Uses the old HTTP+SSE transport, which isn't supported: use its streamable HTTP endpoint."
        case .usable: break
        }
        guard let s = status else {
            let known = MCPHub.shared.knownTools(c, folder: folder)?.count
            return "Not started (starts when the agent uses it)" + (known.map { " · \($0) tool\($0 == 1 ? "" : "s") last time" } ?? "") + "."
        }
        var parts: [String] = [s.phase.rawValue]
        if let pid = s.pid { parts.append("pid \(pid)") }
        if let server = s.server, !server.name.isEmpty { parts.append("\(server.name) \(server.version)".trimmingCharacters(in: .whitespaces)) }
        if let tools = s.tools { parts.append("\(tools.count) tool\(tools.count == 1 ? "" : "s")") }
        if s.restarts > 0 { parts.append("\(s.restarts) restart\(s.restarts == 1 ? "" : "s")") }
        if let e = s.lastError, s.phase != .ready { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    // MARK: Changes

    private func decide(_ c: MCPServerConfig, _ allowed: Bool) {
        settings.value.mcpProjectDecisions[folder.path, default: [:]][c.name] = MCPDecision(fingerprint: c.fingerprint, allowed: allowed)
        if !allowed { Task { await MCPHub.shared.existing(c.name, folder: folder)?.stop() } }
    }
    private func revoke(_ c: MCPServerConfig) {
        settings.value.mcpProjectDecisions[folder.path]?[c.name] = nil
        Task { await MCPHub.shared.existing(c.name, folder: folder)?.stop() }
    }
    private func remove(_ c: MCPServerConfig) {
        settings.value.mcpServers.removeAll { $0.name == c.name }
        stopEverywhere(c)
    }
    /// An app-level server's instances in every folder.
    private func stopEverywhere(_ c: MCPServerConfig) {
        let doomed = MCPHub.shared.all.filter { $0.config.scope == .app && $0.config.name == c.name }
        Task { for i in doomed { await i.stop() } }
    }
}

/// Adds or edits one of the user's servers.
private struct MCPServerEditor: View {
    @State var draft: MCPServerConfig
    let taken: [String]
    let save: (MCPServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var args = ""
    @State private var env = ""
    @State private var headers = ""

    var body: some View {
        Form {
            TextField("Name (tools are mcp__name__tool)", text: $draft.name)
            Picker("Transport", selection: Binding(get: { draft.isHTTP ? "http" : "stdio" }, set: { draft.type = $0 })) {
                Text("stdio (a program)").tag("stdio")
                Text("Streamable HTTP (a URL)").tag("http")
            }
            if draft.isHTTP {
                TextField("URL", text: $draft.url)
                Section("Headers (Name: value, one per line; ${VAR} reads your environment)") {
                    TextEditor(text: $headers).font(.body.monospaced()).frame(minHeight: 60)
                }
            } else {
                TextField("Command (npx, uvx, /path/to/server…)", text: $draft.command)
                Section("Arguments (one per line)") { TextEditor(text: $args).font(.body.monospaced()).frame(minHeight: 60) }
                Section("Environment (KEY=value, one per line; ${VAR} reads your environment)") {
                    TextEditor(text: $env).font(.body.monospaced()).frame(minHeight: 60)
                }
            }
            HStack {
                Text("It runs in the folder of the lesson that uses it.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    var d = draft
                    d.name = d.name.trimmingCharacters(in: .whitespaces)
                    d.scope = .app
                    d.args = lines(args)
                    d.env = pairs(env, "=")
                    d.headers = pairs(headers, ":")
                    if d.isHTTP { d.command = ""; d.args = []; d.env = [:] } else { d.url = ""; d.headers = [:] }
                    save(d)
                    dismiss()
                }
                .disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 520, height: 520)
        .onAppear {
            args = draft.args.joined(separator: "\n")
            env = draft.env.keys.sorted().map { "\($0)=\(draft.env[$0]!)" }.joined(separator: "\n")
            headers = draft.headers.keys.sorted().map { "\($0): \(draft.headers[$0]!)" }.joined(separator: "\n")
        }
    }

    private var valid: Bool {
        let n = draft.name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !taken.contains(n) && (draft.isHTTP ? URL(string: draft.url)?.scheme?.hasPrefix("http") == true : !draft.command.isEmpty)
    }
    private func lines(_ s: String) -> [String] { s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private func pairs(_ s: String, _ sep: Character) -> [String: String] {
        var out: [String: String] = [:]
        for l in lines(s) {
            guard let i = l.firstIndex(of: sep) else { continue }
            out[l[..<i].trimmingCharacters(in: .whitespaces)] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

/// Pasted JSON, as servers' READMEs give it: `{"mcpServers": {…}}`, `{"name": {…}}`, or one server's object.
private struct MCPImportSheet: View {
    let taken: [String]
    let add: ([MCPServerConfig]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a server's JSON (Claude Code's or Claude Desktop's format).").font(.headline)
            TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 200)
            if parsed.isEmpty, Self.single(text) != nil { TextField("Name for this server", text: $name) }
            Text(parsed.isEmpty ? "Nothing to add yet." : "Adds: " + parsed.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add(servers); dismiss() }.disabled(servers.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding().frame(width: 520, height: 380)
    }

    private var parsed: [MCPServerConfig] {
        guard let j = JSON.parse(text), let o = (j["mcpServers"] ?? j["servers"] ?? j).object, Self.single(text) == nil else { return [] }
        return o.keys.sorted().compactMap { MCPServerConfig(name: $0, json: o[$0]!, scope: .app) }.filter { !taken.contains($0.name) }
    }
    private var servers: [MCPServerConfig] {
        if !parsed.isEmpty { return parsed }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !taken.contains(n), let one = Self.single(text) else { return [] }
        return MCPServerConfig(name: n, json: one, scope: .app).map { [$0] } ?? []
    }
    /// One server's own object (it has a command or a url at the top).
    static func single(_ text: String) -> JSON? {
        guard let j = JSON.parse(text), j["command"]?.string != nil || j["url"]?.string != nil else { return nil }
        return j
    }
}
