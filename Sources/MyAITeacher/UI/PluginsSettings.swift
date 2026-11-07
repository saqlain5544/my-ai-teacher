import SwiftUI

/// Settings → Plugins: install a plugin from a folder or a git URL, review what it contains and approve its exact files,
/// switch it on or off, update or remove it. Nothing of a plugin is used until it is approved.
struct PluginsSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var url = ""
    @State private var busy = false
    @State private var message: String?
    @State private var reviewing: Plugin?
    @State private var expanded: Set<String> = []

    var body: some View {
        let plugins = Plugins.installed(settings.value)
        Form {
            Section {
                Text("A plugin is a folder in Claude Code's layout: .claude-plugin/plugin.json, and any of skills/, agents/, commands/, hooks/hooks.json and .mcp.json. Installing one does nothing by itself: you review what it contains (hook and MCP commands in full) and approve its exact files. An update that changes a file asks again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Installed") {
                if plugins.isEmpty { Text("No plugins installed.").foregroundStyle(.secondary) }
                ForEach(plugins) { p in row(p) }
            }
            Section("Install") {
                HStack {
                    TextField("Git URL (https:// or ssh://) or a folder path", text: $url).textFieldStyle(.roundedBorder).disabled(busy)
                    Button("Install") { install(url) }.disabled(busy || url.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose folder…") { choose() }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.caption).foregroundStyle(message.hasPrefix("Installed") || message.hasPrefix("Updated") ? Color.secondary : Color.red).textSelection(.enabled) }
                Button { NSWorkspace.shared.open(Plugins.root.deletingLastPathComponent()) } label: { Label("Show the plugins folder", systemImage: "folder") }
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $reviewing) { p in
            PluginReview(plugin: p) { reviewing = nil; approve(p) } cancel: { reviewing = nil }
        }
    }

    @ViewBuilder private func row(_ p: Plugin) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color(p.standing)).frame(width: 8, height: 8)
                Text(p.name).font(.body.monospaced())
                if !p.version.isEmpty { Text(p.version).font(.caption).foregroundStyle(.secondary) }
                Text(label(p.standing)).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if p.standing == .needsApproval {
                    Button("Review & approve…") { reviewing = p }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if case .broken = p.standing {} else {
                    Button("Contents") { if expanded.contains(p.name) { expanded.remove(p.name) } else { expanded.insert(p.name) } }.controlSize(.small)
                    Button("Update") { install(p.record.source, replacing: p) }.controlSize(.small).disabled(busy || p.record.source.isEmpty)
                }
                Button("Remove", role: .destructive) { remove(p) }.controlSize(.small)
                Toggle("", isOn: Binding(get: { p.record.enabled }, set: { setEnabled(p, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            if !p.description.isEmpty { Text(p.description).font(.caption).foregroundStyle(.secondary) }
            if case .broken(let why) = p.standing { Text("Can't be used: \(why).").font(.caption).foregroundStyle(.red) }
            if expanded.contains(p.name) {
                Text(p.review()).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ s: Plugin.Standing) -> Color {
        switch s { case .active: .green; case .disabled: .gray; case .needsApproval: .orange; case .broken: .red }
    }
    private func label(_ s: Plugin.Standing) -> String {
        switch s { case .active: "on"; case .disabled: "off"; case .needsApproval: "needs your approval"; case .broken: "broken" }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a plugin folder (it has .claude-plugin/plugin.json)"
        if panel.runModal() == .OK, let u = panel.url { install(u.path) }
    }

    private func install(_ source: String, replacing: Plugin? = nil) {
        busy = true; message = nil
        let previous = replacing?.record
        Task {
            do {
                let r = try await PluginInstaller.install(source: source, replacing: replacing?.name, previous: previous)
                await MCPHub.shared.stopPlugin(r.name)
                settings.value.plugins[r.name] = r.record
                message = (replacing == nil ? "Installed " : "Updated ") + r.name + ". " + (r.record.approved == nil ? "Review it to use it." : "It asks again if its files changed.")
                if replacing == nil { url = "" }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func approve(_ p: Plugin) {
        var r = settings.value.plugins[p.name] ?? p.record
        r.approved = p.fingerprint
        settings.value.plugins[p.name] = r
    }

    private func setEnabled(_ p: Plugin, _ on: Bool) {
        var r = settings.value.plugins[p.name] ?? p.record
        r.enabled = on
        settings.value.plugins[p.name] = r
        if !on { Task { await MCPHub.shared.stopPlugin(p.name) } }
    }

    private func remove(_ p: Plugin) {
        Task { await MCPHub.shared.stopPlugin(p.name) }
        do { try PluginInstaller.remove(p.name); settings.value.plugins[p.name] = nil; message = nil }
        catch { message = error.localizedDescription }
    }
}

/// What approving a plugin means: everything it contains, the commands it would run, verbatim.
private struct PluginReview: View {
    let plugin: Plugin
    let approve: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Approve “\(plugin.name)”?").font(.headline)
            Text("Approving lets this plugin's skills and agents reach the model, its commands appear in the / menu, and its hooks and MCP servers run as you. The approval is for exactly these files: an update that changes one asks again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(plugin.review()).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Approve", action: approve).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16).frame(width: 560, height: 420)
    }
}
