import SwiftUI

/// Right-hand panel tab: what changed in the folder since the last checkpoint (git), file by file with a coloured diff.
/// No git knowledge needed: "Track changes" sets it up, "Save checkpoint" records the current state.
struct ChangesPanel: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = ChangesModel()

    var body: some View {
        let folder = app.workspace.url
        let canWrite = app.access(for: app.workspace) >= .write
        VStack(spacing: 0) {
            switch model.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notRepo:
                ContentUnavailableView {
                    Label("Changes aren't tracked here yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Track changes to see exactly what the agent edits and save checkpoints you can go back to (uses git).")
                } actions: {
                    Button("Track changes") { Task { await model.initRepo(folder) } }.disabled(!canWrite)
                    if !canWrite { Text("Needs write access to this folder.").font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxHeight: .infinity)
            case .ready:
                header(folder, canWrite: canWrite)
                Divider()
                if model.files.isEmpty {
                    ContentUnavailableView("No changes since the last checkpoint", systemImage: "checkmark.circle",
                                           description: Text(model.lastCommit.map { "Last checkpoint: \($0)" } ?? ""))
                        .frame(maxHeight: .infinity)
                } else {
                    List(model.files, selection: $model.selected) { f in
                        HStack(spacing: 6) {
                            Text(f.status).font(.caption.monospaced().bold()).foregroundStyle(f.color).frame(width: 18)
                            Text(f.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if f.added > 0 { Text("+\(f.added)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
                            if f.removed > 0 { Text("−\(f.removed)").font(.caption.monospacedDigit()).foregroundStyle(.red) }
                        }.tag(f.path)
                    }
                    .listStyle(.plain).frame(minHeight: 80, maxHeight: 220)
                    Divider()
                    DiffView(lines: model.diff)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // the header stays on top when the list is empty
        .task(id: folder) { await model.reload(folder) }
        .onChange(of: model.selected) { _, p in Task { await model.loadDiff(folder, p) } }
        .onReceive(EventBus.subject.filter {
            if case .toolFinished(_, let t, _, _) = $0 { return ["edit", "write", "bash", "run_code"].contains(t) }
            if case .turnFinished = $0 { return true }
            return false
        }) { _ in Task { await model.reload(folder) } }
    }

    private func header(_ folder: URL, canWrite: Bool) -> some View {
        HStack(spacing: 8) {
            Text(model.files.isEmpty ? "Up to date" : "\(model.files.count) changed file\(model.files.count == 1 ? "" : "s")").font(.headline)
            Spacer()
            Button { Task { await model.reload(folder) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
            Button("Save checkpoint") { Task { await model.checkpoint(folder) } }
                .disabled(!canWrite || model.files.isEmpty)
                .help(canWrite ? "Record the current state of every file (git commit)" : "Needs write access to this folder")
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// A unified diff, coloured by line kind. Lazy, so a long diff stays fast.
private struct DiffView: View {
    let lines: [String]
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l.isEmpty ? " " : l)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(color(l))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(bg(l))
                }
            }.textSelection(.enabled).padding(.vertical, 6)
        }
    }
    private func color(_ l: String) -> Color {
        l.hasPrefix("@@") ? .accentColor : l.hasPrefix("+") && !l.hasPrefix("+++") ? .green : l.hasPrefix("-") && !l.hasPrefix("---") ? .red : .primary
    }
    private func bg(_ l: String) -> Color {
        l.hasPrefix("+") && !l.hasPrefix("+++") ? .green.opacity(0.08) : l.hasPrefix("-") && !l.hasPrefix("---") ? .red.opacity(0.08) : .clear
    }
}

@MainActor
final class ChangesModel: ObservableObject {
    enum State { case loading, notRepo, ready }
    struct File: Identifiable, Hashable {
        let path: String, status: String, added: Int, removed: Int
        var id: String { path }
        var color: Color { status == "A" || status == "??" ? .green : status == "D" ? .red : .orange }
    }
    @Published var state: State = .loading
    @Published var files: [File] = []
    @Published var selected: String?
    @Published var diff: [String] = []
    @Published var lastCommit: String?

    static let maxDiffLines = 5000

    private func git(_ folder: URL, _ args: [String], timeout: TimeInterval = 15) async -> ProcessResult {
        await ProcessRunner.run("/usr/bin/git", ["-C", folder.path] + args, cwd: folder, timeout: timeout)
    }

    func reload(_ folder: URL) async {
        let top = await git(folder, ["rev-parse", "--is-inside-work-tree"])
        guard top.exitCode == 0, top.stdout.contains("true") else { state = .notRepo; files = []; return }
        let status = await git(folder, ["status", "--porcelain=v1", "--untracked-files=all"])
        let numstat = await git(folder, ["diff", "HEAD", "--numstat"])
        var counts: [String: (Int, Int)] = [:]
        for line in numstat.stdout.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 2)
            if p.count == 3 { counts[String(p[2])] = (Int(p[0]) ?? 0, Int(p[1]) ?? 0) }
        }
        files = status.stdout.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let c = counts[path] ?? (0, 0)
            return File(path: path, status: code == "??" ? "??" : String(code.prefix(1)), added: c.0, removed: c.1)
        }
        lastCommit = await git(folder, ["log", "-1", "--format=%s · %cr"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        state = .ready
        if selected == nil || !files.contains(where: { $0.path == selected }) { selected = files.first?.path }
        await loadDiff(folder, selected)
    }

    func loadDiff(_ folder: URL, _ path: String?) async {
        guard let path, let f = files.first(where: { $0.path == path }) else { diff = []; return }
        let out: String
        if f.status == "??" {
            let text = (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? "(binary or unreadable file)"
            out = "new file \(path)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        } else {
            out = await git(folder, ["diff", "HEAD", "--", path]).stdout
        }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        diff = lines.count > Self.maxDiffLines ? Array(lines.prefix(Self.maxDiffLines)) + ["… \(lines.count - Self.maxDiffLines) more lines"] : lines
    }

    func initRepo(_ folder: URL) async {
        _ = await git(folder, ["init"])
        _ = await git(folder, ["add", "-A"])
        _ = await git(folder, ["-c", "user.name=My AI Teacher", "-c", "user.email=teacher@localhost", "commit", "-m", "Starting point", "--allow-empty"])
        await reload(folder)
    }

    func checkpoint(_ folder: URL) async {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        _ = await git(folder, ["add", "-A"])
        _ = await git(folder, ["-c", "user.name=My AI Teacher", "-c", "user.email=teacher@localhost", "commit", "-m", "Checkpoint \(df.string(from: Date()))"])
        await reload(folder)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
