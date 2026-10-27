import SwiftUI
import AppKit

/// Background tasks (Claude Code's tasks panel): every command, server, sub-agent, MCP server and app job, running ones
/// first, with when each was asked for and started, how long it waited, how long it has run or took, how it ended, and
/// Stop. The sidebar's Tasks page shows them all; the side panel's Tasks tab, by default, the open lesson's.
struct TasksView: View {
    @EnvironmentObject var app: AppModel
    /// The side panel's: starts on the open lesson's tasks.
    var conversationID: String?
    var compact = false
    @State private var onlyLesson = true
    @State private var selected: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let all = BackgroundTasks.snapshot(app: app)
            let shown = compact && onlyLesson && conversationID != nil ? all.filter { $0.conversationID == conversationID || $0.conversationID == nil && $0.state.active } : all
            let running = shown.filter { $0.state.active }, ended = shown.filter { !$0.state.active }
            VStack(alignment: .leading, spacing: 0) {
                header(running: running.count, total: shown.count)
                if shown.isEmpty {
                    ContentUnavailableView("Nothing in the background", systemImage: "checkmark.circle",
                                           description: Text("Builds, test runs, servers, sub-agents, MCP servers and the app's own jobs show here while they run, and for a while after."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selected) {
                        if !running.isEmpty {
                            Section("Running · \(running.count)") { ForEach(running) { row($0, now: context.date) } }
                        }
                        if !ended.isEmpty {
                            Section("Finished") { ForEach(ended) { row($0, now: context.date) } }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle("Tasks")
    }

    private func header(running: Int, total: Int) -> some View {
        HStack {
            if !compact {
                Text("Background tasks").font(.title2.bold())
            }
            Text(running == 0 ? "none running" : "\(running) running").font(.callout).foregroundStyle(.secondary)
            Spacer()
            if compact, conversationID != nil {
                Picker("", selection: $onlyLesson) { Text("This lesson").tag(true); Text("All").tag(false) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, compact ? 10 : 20).padding(.vertical, compact ? 8 : 14)
    }

    @ViewBuilder private func row(_ t: BackgroundTask, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: t.kind.symbol).foregroundStyle(color(t)).frame(width: 18)
                Text(t.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let h = t.handle { Text(h).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Spacer(minLength: 6)
                badge(t)
                if BackgroundTasks.canStop(t) {
                    Button("Stop") { BackgroundTasks.stop(t) }.controlSize(.small).help("Stop this \(t.kind.title.lowercased())")
                }
            }
            if let d = t.detail, d != t.title {
                Text(d).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(compact ? 2 : 3).truncationMode(.tail).textSelection(.enabled)
            }
            Text(timing(t, now: now)).font(.caption).foregroundStyle(.secondary)
            let extra = facts(t)
            if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(.tertiary).lineLimit(2) }
            if let u = t.url, let url = URL(string: u) { Link(u, destination: url).font(.caption) }
            if let note = t.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(t.state == .failed ? Color.red : Color.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .tag(t.id)
        .contextMenu {
            if let d = t.detail { Button("Copy Command") { copy(d) } }
            if let u = t.url { Button("Copy URL") { copy(u) } }
            if let c = t.conversationID { Button("Open Lesson") { app.selection = .lesson(c) } }
            if BackgroundTasks.canStop(t) { Button("Stop", role: .destructive) { BackgroundTasks.stop(t) } }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Asked 14:03:09 · started 14:03:11 (waited 1.9s) · running 2m 14s", or "… · took 41s".
    private func timing(_ t: BackgroundTask, now: Date) -> String {
        var parts: [String] = []
        let f = Date.FormatStyle.dateTime.hour().minute().second()
        if let w = t.waited, let q = t.queuedAt { parts.append("asked \(q.formatted(f))") ; parts.append("started \(t.startedAt!.formatted(f)) (waited \(BackgroundTasks.duration(w)))") }
        else if let s = t.startedAt { parts.append("started \(s.formatted(f))") }
        else if let q = t.queuedAt { parts.append("asked \(q.formatted(f)), waiting \(BackgroundTasks.duration(now.timeIntervalSince(q)))") }
        if let r = t.ran(now: now) { parts.append(t.state.active ? "running \(BackgroundTasks.duration(r))" : "took \(BackgroundTasks.duration(r))") }
        if let e = t.endedAt, !t.state.active { parts.append("ended \(e.formatted(f))") }
        return parts.joined(separator: " · ")
    }

    private func facts(_ t: BackgroundTask) -> String {
        var parts = [t.kind.title]
        if let c = t.conversationID, let title = app.conversations.first(where: { $0.id == c })?.title { parts.append(title) }
        if let code = t.exitCode { parts.append("exit \(code)") }
        if let pid = t.pid { parts.append("pid \(pid)") }
        if t.restarts > 0 { parts.append("\(t.restarts) restart\(t.restarts == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func badge(_ t: BackgroundTask) -> some View {
        Text(t.state.rawValue)
            .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color(t).opacity(0.15))).foregroundStyle(color(t))
    }

    private func color(_ t: BackgroundTask) -> Color {
        switch t.state { case .running: .accentColor; case .queued: .orange; case .done: .green; case .failed: .red; case .stopped: .secondary }
    }

    private func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}
