import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The code mentor's project as the learner sees it, read from `.teacher/project.json`: reloaded when the record changes.
/// The learner acts here without asking the mentor: run the tests (all or one), ask for a review with their own
/// self-review first, reveal a finding's hints one rung at a time, open a file at a line.
@MainActor
final class ProjectModel: ObservableObject {
    @Published private(set) var project: MentorProject?
    @Published private(set) var earlier: [MentorProject] = []
    @Published private(set) var changes: [ProjectStore.Change] = []
    @Published var running: String?
    @Published var output: String?
    private(set) weak var session: ChatSession?
    private var ws: Workspace? { session?.services.workspace }

    func bind(_ s: ChatSession) { session = s; reload() }

    func reload() {
        guard let ws else { project = nil; earlier = []; return }
        let loaded = ProjectStore.load(ws)
        if loaded?.createdAt != project?.createdAt { output = nil }   // the next project doesn't show the last one's run
        project = loaded
        earlier = ProjectStore.earlier(ws)
        Task { [weak self] in
            let c = await ProjectStore.changes(ws)
            self?.changes = c
        }
    }

    func runTests(_ test: String? = nil) {
        guard let ws, let command = project?.testCommand, running == nil else { return }
        let cmd = test.flatMap { ProjectTestRunner.filtered(command, test: $0) } ?? command
        running = test ?? "all"
        Task { [weak self] in
            let (run, out) = await ProjectTestRunner.run(cmd, ws: ws, timeout: 300, why: test == nil ? "learner" : "learner, one test")
            self?.running = nil
            self?.output = ProjectTestRunner.describe(run, output: out)
            self?.reload()
        }
    }

    /// The learner moves on: the project stays on the record unfinished, and the mentor hears it with their next message.
    func putAside() {
        guard let ws, let session, project?.isOpen == true else { return }
        let title = project?.title ?? "the project"
        ProjectStore.mutate(ws) { $0.parkedAt = Date(); $0.parkedWhy = "put aside by the learner"; $0.log("parked", "put aside by the learner") }
        session.studyNotes.append("The learner put “\(title)” aside unfinished from the Project panel: it's on the record as not passed. Don't review it; `project_tests` set starts the next project.")
        reload()
    }

    func requestReview(_ r: MentorProject.SelfReview) {
        guard let ws, let session else { return }
        ProjectStore.mutate(ws) { $0.selfReview = r }
        // Asking for a review is asking for the tests to run: the mentor's review shouldn't stop to ask again.
        AppModel.shared.interactions.grant("tests", conversationID: session.id)
        var msg = "Please review my project."
        if !r.fixed.isEmpty { msg += "\nWhat I fixed: \(r.fixed)" }
        if !r.unsure.isEmpty { msg += "\nWhat I'm unsure about: \(r.unsure)" }
        if !r.expectFail.isEmpty { msg += "\nWhat I expect to fail: \(r.expectFail)" }
        session.send(msg)
    }

    func revealHint(_ id: Int) {
        guard let ws else { return }
        ProjectStore.mutate(ws) { p in
            guard let r = p.rounds.indices.last, let i = p.rounds[r].findings.firstIndex(where: { $0.id == id }) else { return }
            let n = min((p.rounds[r].findings[i].revealed ?? 0) + 1, p.rounds[r].findings[i].hints?.count ?? 0)
            p.rounds[r].findings[i].revealed = n
            p.help = (p.help ?? []) + [MentorProject.HelpUse(at: Date(), kind: "hint", detail: "finding [\(id)], hint \(n)")]
        }
    }

    func askHint(test: String) {
        guard let ws, let session else { return }
        ProjectStore.mutate(ws) { $0.help = ($0.help ?? []) + [MentorProject.HelpUse(at: Date(), kind: "hint", detail: "asked about \(test)")] }
        session.send("I'm stuck on the failing test `\(ProjectTestRunner.shortName(test))`. A hint please: the smallest nudge first, no code.")
    }

    func unlockTests() {
        guard let ws else { return }
        ProjectStore.mutate(ws) { $0.testsUnlockedAt = Date(); $0.log("unlocked", "the learner unlocked the tests from the Project panel") }
    }

    /// Puts the learner's files back as they were at the last review (or the starter). What they have now goes to the
    /// Trash first, so it can be recovered.
    func restoreBaseline() {
        guard let ws else { return }
        let fm = FileManager.default, snap = ProjectStore.snapshotDir(ws)
        var trashed: [URL] = []
        for c in changes {
            let live = ws.url.appendingPathComponent(c.path)
            if c.kind != "deleted", fm.fileExists(atPath: live.path) {
                if (try? fm.trashItem(at: live, resultingItemURL: nil)) != nil { trashed.append(live) } else { continue }
            }
            if c.kind != "added" {
                try? fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: snap.appendingPathComponent(c.path), to: live)
            }
        }
        ProjectStore.mutate(ws) { $0.log("restored", "the learner restored \(changes.count) file(s) to the \($0.snapshotWhy ?? "baseline")") }
        reload()
    }

    /// The project as a Markdown report: the brief, the test history, every review round, help, explain-back.
    func report() -> String {
        guard let p = project else { return "" }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var s = "# \(p.title ?? "Project")\n\n"
        if let c = p.concept { s += "Concept: **\(c)**" + (p.subject.map { " (\($0))" } ?? "") + "\n\n" }
        s += "Started \(df.string(from: p.createdAt)). Tests: `\(p.testCommand ?? "—")`.\n\n"
        s += "## Test runs\n\n" + p.runs.map { "- \(df.string(from: $0.at)) (\($0.why)): \($0.line)" }.joined(separator: "\n") + "\n\n"
        s += "## Reviews\n\n"
        for r in p.rounds {
            s += "### Round \(r.number): \(r.verdict) — \(df.string(from: r.at))\n\n"
            if let t = r.tests { s += "Tests: \(t.line). " }
            if let h = r.help { s += "Help: \(h). " }
            if let sum = r.summary { s += sum }
            s += "\n\n"
            if let sr = r.selfReview { s += "Self-review — fixed: \(sr.fixed); unsure: \(sr.unsure); expected to fail: \(sr.expectFail)\n\n" }
            for f in r.findings { s += "- [\(f.resolved ? "x" : " ")] **\(f.severity)** `\(f.file)\(f.line.map { ":\($0)" } ?? "")` — \(f.text)\n" }
            s += "\n"
        }
        if let e = p.explainBack { s += "## Explain-back\n\n" + (e.question.map { "Q: \($0)\n\n" } ?? "") + "Result: \(e.verdict ?? "pending")\n\n" }
        if let h = p.help, !h.isEmpty { s += "## Help used\n\n" + h.map { "- \(df.string(from: $0.at)): \($0.kind) — \($0.detail)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

/// Opens a file at a line in the learner's editor when one with a line-aware link is installed, else in the default app.
enum EditorLink {
    static let editors: [(id: String, name: String, url: (String, Int) -> String)] = [
        ("com.microsoft.VSCode", "VS Code", { "vscode://file\(enc($0)):\($1)" }),
        ("com.todesktop.230313mzl4w4u92", "Cursor", { "cursor://file\(enc($0)):\($1)" }),
        ("dev.zed.Zed", "Zed", { "zed://file\(enc($0)):\($1)" }),
        ("com.sublimetext.4", "Sublime Text", { "subl://open?url=file://\(enc($0))&line=\($1)" }),
    ]
    static func enc(_ p: String) -> String { p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p }
    static var installed: (id: String, name: String, url: (String, Int) -> String)? {
        editors.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
    static func open(_ file: URL, line: Int?) {
        if let e = installed, let u = URL(string: e.url(file.path, line ?? 1)) { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(file) }
    }
}

/// Inspector tab: the project cockpit.
struct ProjectPanel: View {
    @EnvironmentObject var app: AppModel
    var session: ChatSession?
    @StateObject private var model = ProjectModel()
    @State private var reviewing = false
    @State private var openDiff: String?
    @State private var confirmRestore = false
    @State private var confirmPark = false

    var body: some View {
        Group {
            if let p = model.project, p.testCommand != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(p)
                        actions(p)
                        if let o = model.output { outputBox(o) }
                        tests(p)
                        findings(p)
                        diff
                        guardBox(p)
                        earlierBox
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView("No project yet", systemImage: "hammer",
                                       description: Text("In a Code mentor lesson, ask for a project: the mentor writes a starter and tests, and the project shows here — your tests, reviews and findings."))
            }
        }
        .onAppear { if let s = session { model.bind(s) } }
        .onChange(of: session?.id) { _, _ in if let s = session { model.bind(s) } }
        .onReceive(EventBus.subject.receive(on: RunLoop.main)) { e in
            switch e {
            case .projectChanged(let folder) where folder == session?.services.workspace.url.path: model.reload()
            case .toolFinished(let c, _, _, _) where c == session?.id: model.reload()
            default: break
            }
        }
        .sheet(isPresented: $reviewing) { SelfReviewSheet { model.requestReview($0) } }
        .confirmationDialog("Put “\(model.project?.title ?? "this project")” aside unfinished?", isPresented: $confirmPark) {
            Button("Put it aside") { model.putAside() }
        } message: { Text("It stays on your record as not passed, and your files stay as they are. Ask the mentor for the next project when you're ready.") }
        .confirmationDialog("Restore your files to the \(model.project?.snapshotWhy ?? "baseline")?", isPresented: $confirmRestore) {
            Button("Restore \(model.changes.count) file\(model.changes.count == 1 ? "" : "s")", role: .destructive) { model.restoreBaseline() }
        } message: {
            Text(model.changes.map(\.path).joined(separator: "\n") + "\n\nYour current versions go to the Trash first.")
        }
    }

    private func header(_ p: MentorProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.title ?? "Project").font(.headline)
            if let c = p.concept { Text(c).font(.callout).foregroundStyle(.secondary) }
            Text(p.testCommand ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            trend(p.runs.suffix(24))
            HStack(spacing: 10) {
                if let r = p.lastRun { Label(r.line, systemImage: r.green ? "checkmark.circle.fill" : r.errored ? "exclamationmark.triangle" : "xmark.circle").foregroundStyle(r.green ? .green : r.errored ? .orange : .red) }
                if p.parkedAt != nil { Text("Put aside").foregroundStyle(.secondary) }
                else if let r = p.rounds.last { Text("Round \(r.number): \(r.verdict)").foregroundStyle(.secondary) }
            }.font(.caption)
            if let e = p.explainBack {
                Label(e.verdict.map { "Explain-back: \($0)" } ?? "Explain-back: your mentor will ask you to explain a choice", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The last run as a progress bar ("17 of 19"), then the pass rate per run, oldest first: green bars are all-green
    /// runs, grey ones couldn't run. A lone pair of unlabelled bars didn't read as progress.
    private func trend(_ runs: ArraySlice<MentorProject.TestRun>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let r = runs.last, !r.errored {
                ProgressView(value: r.rate)
                    .tint(r.green ? .green : .orange)
                    .accessibilityLabel("Last run: " + (r.counted == false ? r.line : "\(r.passed) of \(r.passed + r.failed) passing"))
            }
            if runs.count > 1 {
                HStack(alignment: .bottom, spacing: 6) { bars(runs); Text("runs").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    private func bars(_ runs: ArraySlice<MentorProject.TestRun>) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                RoundedRectangle(cornerRadius: 1)
                    .fill(r.errored ? Color.secondary.opacity(0.4) : r.green ? Color.green : Color.orange)
                    .frame(width: 6, height: r.errored ? 3 : max(2, 14 * CGFloat(r.rate)))
                    .help("\(r.line) · \(r.why) · \(ProjectTestsTool.ago(r.at))")
            }
        }
        .frame(height: 15, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Test history: " + runs.map { $0.counted == false ? $0.line : "\($0.passed) of \($0.passed + $0.failed)" }.joined(separator: ", "))
    }

    private func actions(_ p: MentorProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { model.runTests() } label: { Label(model.running == "all" ? "Running…" : "Run tests", systemImage: "play.fill") }
                    .disabled(model.running != nil)
                Button { reviewing = true } label: { Label("Request review", systemImage: "checklist") }
                    .disabled(model.changes.isEmpty || session?.isRunning == true)
                    .help(model.changes.isEmpty ? "Nothing changed since the last review" : "Say what you fixed first, then the mentor reviews")
            }
            HStack {
                Button("Folder") { NSWorkspace.shared.open(app.workspace.url) }
                Button("Export report…") { export() }
                Button("Restore…") { confirmRestore = true }.disabled(model.changes.isEmpty)
                    .help("Put your files back as they were at the \(p.snapshotWhy ?? "baseline")")
                if p.isOpen { Button("Put aside…") { confirmPark = true }.help("Move on to something else; this project stays on your record as unfinished") }
            }
            .buttonStyle(.link).font(.caption)
        }
    }

    private func outputBox(_ o: String) -> some View {
        GroupBox {
            ScrollView { Text(o).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
        } label: {
            HStack { Text("Last run"); Spacer(); Button { model.output = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Close output") }
        }
    }

    @ViewBuilder private func tests(_ p: MentorProject) -> some View {
        if let r = p.lastRun, !r.failing.isEmpty {
            section("Failing tests") {
                ForEach(r.failing, id: \.self) { t in
                    HStack {
                        Image(systemName: "xmark.circle").foregroundStyle(.red)
                        Text(ProjectTestRunner.shortName(t)).font(.callout).lineLimit(2).help(t)
                        Spacer()
                        if ProjectTestRunner.filtered(p.testCommand ?? "", test: t) != nil {
                            Button { model.runTests(t) } label: { Image(systemName: model.running == t ? "hourglass" : "arrow.clockwise") }
                                .buttonStyle(.borderless).help("Run only this test").accessibilityLabel("Rerun \(t)").disabled(model.running != nil)
                        }
                        Button("Hint") { model.askHint(test: t) }.buttonStyle(.link).font(.caption).disabled(session?.isRunning == true)
                            .help("Ask the mentor for the smallest nudge (recorded as help)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func findings(_ p: MentorProject) -> some View {
        let open = p.rounds.last?.findings.filter { !$0.resolved } ?? []
        if !open.isEmpty {
            section("Open findings") {
                ForEach(Dictionary(grouping: open, by: \.file).sorted { $0.key < $1.key }, id: \.key) { file, items in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file).font(.caption.monospaced().weight(.semibold))
                        ForEach(items) { f in finding(f) }
                    }
                }
            }
        }
    }

    private func finding(_ f: MentorProject.Finding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.severity).font(.caption2.weight(.bold)).padding(.horizontal, 4)
                    .background(f.severity == "must" ? Color.red.opacity(0.2) : f.severity == "should" ? Color.orange.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                if let l = f.line { Text("line \(l)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    let url = app.workspace.url.appendingPathComponent(f.file)
                    Button("Open in \(EditorLink.installed?.name ?? "default app")") { EditorLink.open(url, line: f.line) }
                    Button("Show in Files") { app.reveal(url) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Copy path:line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(f.file + (f.line.map { ":\($0)" } ?? ""), forType: .string)
                    }
                } label: { Image(systemName: "arrow.up.forward.square") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Open \(f.file)")
            }
            Text(f.text).font(.callout).textSelection(.enabled)
            if let hints = f.hints, !hints.isEmpty {
                let shown = f.revealed ?? 0
                ForEach(0..<min(shown, hints.count), id: \.self) { i in
                    Label(hints[i], systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                }
                if shown < hints.count {
                    Button(shown == 0 ? "Show a hint" : "A bigger hint (\(shown + 1) of \(hints.count))") { model.revealHint(f.id) }
                        .buttonStyle(.link).font(.caption).help("Each hint you reveal is recorded as help")
                }
            }
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var diff: some View {
        if !model.changes.isEmpty {
            section("Changed since the \(model.project?.snapshotWhy ?? "baseline")") {
                ForEach(model.changes, id: \.path) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { openDiff = openDiff == c.path ? nil : c.path } label: {
                            HStack {
                                Image(systemName: openDiff == c.path ? "chevron.down" : "chevron.right").font(.caption2)
                                Text(c.path).font(.caption.monospaced())
                                Spacer()
                                Text("+\(c.added) −\(c.removed)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                        if openDiff == c.path {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(c.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, l in
                                        Text(String(l)).font(.caption2.monospaced())
                                            .foregroundStyle(l.hasPrefix("+") ? Color.green : l.hasPrefix("-") ? Color.red : l.hasPrefix("@@") ? Color.blue : Color.primary)
                                    }
                                }.textSelection(.enabled)
                            }.frame(maxHeight: 220)
                        }
                    }
                }
            }
        }
    }

    private func guardBox(_ p: MentorProject) -> some View {
        section("Protection") {
            if p.isOpen {
                Label("Your files are yours: the mentor can't edit them\(p.snapshotAt.map { " (since \(ProjectTestsTool.ago($0)))" } ?? "").", systemImage: "lock.shield").font(.caption)
            }
            Label(p.testsUnlockedAt != nil ? "Tests unlocked: the mentor may change them until it re-baselines." : "Tests locked since the baseline.",
                  systemImage: p.testsUnlockedAt != nil ? "lock.open" : "checkmark.seal").font(.caption).foregroundStyle(.secondary)
            if p.testsUnlockedAt == nil, p.isOpen {
                Button("Unlock the tests for the mentor") { model.unlockTests() }.buttonStyle(.link).font(.caption)
                    .help("For a wrong test or a stretch goal: the mentor changes them, then re-baselines")
            }
            if let log = p.guardLog, !log.isEmpty {
                DisclosureGroup("What the guard stopped (\(log.count))") {
                    ForEach(Array(log.suffix(20).reversed().enumerated()), id: \.offset) { _, e in
                        Text("\(ProjectTestsTool.ago(e.at)) · \(e.kind): \(e.detail)").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption)
            }
        }
    }

    /// What came before this project in the folder: each one's outcome at a glance.
    @ViewBuilder private var earlierBox: some View {
        if !model.earlier.isEmpty {
            section("Earlier projects") {
                ForEach(Array(model.earlier.enumerated()), id: \.offset) { _, e in
                    let passed = e.rounds.last?.verdict == "pass"
                    HStack(spacing: 6) {
                        Image(systemName: passed ? "checkmark.seal.fill" : e.parkedAt != nil ? "pause.circle" : "circle.dashed")
                            .foregroundStyle(passed ? Color.green : Color.secondary)
                        Text(e.title ?? "Project").lineLimit(1)
                        Spacer(minLength: 4)
                        Text(passed ? "passed in \(e.rounds.count) round\(e.rounds.count == 1 ? "" : "s")" : e.parkedAt != nil ? "put aside" : (e.lastRun?.line ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                    .help(e.lastRun.map { "Last run: \($0.line)" } ?? "")
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (model.project?.title ?? "project").replacingOccurrences(of: "/", with: "-") + " report.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(model.report().utf8).write(to: url)
    }
}

/// Before a review: the learner's own read of their work, shown to the mentor and kept with the round.
struct SelfReviewSheet: View {
    var submit: (MentorProject.SelfReview) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fixed = ""
    @State private var unsure = ""
    @State private var expectFail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before the review").font(.headline)
            Text("A minute on your own read of your work: the mentor answers it in the review.").font(.callout).foregroundStyle(.secondary)
            field("What did you fix or build?", $fixed)
            field("What are you unsure about?", $unsure)
            field("Which test do you expect to fail, if any?", $expectFail)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Request review") {
                    submit(MentorProject.SelfReview(at: Date(), fixed: fixed.trimmed, unsure: unsure.trimmed, expectFail: expectFail.trimmed))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(fixed.trimmed.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout)
            TextField("", text: text, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
