import SwiftUI

/// The learner model, made visible: subjects → concepts (mastery, prerequisites, misconceptions), cross-subject
/// connections, profile/goals/preferences, and every memory with its provenance. Everything is editable.
struct MemoryView: View {
    @EnvironmentObject var app: AppModel

    enum Tab: String, CaseIterable, Identifiable { case map = "Learning map", me = "About me", all = "All memories"; var id: String { rawValue } }

    @State private var tab: Tab = .map
    @State private var memories: [Memory] = []
    @State private var subjects: [(subject: String, concepts: [Concept])] = []
    @State private var links: [ConceptGraph.SubjectLink] = []
    @State private var lessonTitles: [String: String] = [:]
    @State private var search = ""
    @State private var editing: String?
    @State private var draft = ""
    @State private var newKind: MemoryKind = .goal
    @State private var newText = ""
    @State private var confirmClear = false
    @State private var editingConcept: Concept?
    @State private var provenance: Memory?

    private var hub: MemoryHub { app.services.memory }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 28).padding(.bottom, 8)
            List {
                switch tab {
                case .map: mapTab
                case .me: aboutTab
                case .all: allTab
                }
            }
            .listStyle(.inset)
            footer
        }
        .navigationTitle("Memory")
        .onAppear(perform: reload)
        .onReceive(EventBus.subject.filter { if case .memoryChanged(let c) = $0 { return c.kind != .recalled }; return false }) { _ in reload() }
        .onReceive(EventBus.subject.filter { if case .studyDataChanged = $0 { return true }; return false }) { _ in reload() }
        .onChange(of: app.workspace.id) { _, _ in reload() }
        .sheet(item: $editingConcept) { c in ConceptEditor(concept: c, hub: hub) { reload(); app.refreshCounts() } }
        .sheet(item: $provenance) { m in ProvenanceSheet(memory: m, history: hub.history(m.id), lesson: m.source.flatMap { lessonTitles[$0] }) }
        .confirmationDialog("Delete all memories?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { hub.deleteAll(); reload(); app.refreshCounts() }
        } message: { Text("Your teacher will forget everything it has learned about you, including the learning map. Quiz history and flashcards stay. This can't be undone.") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory").font(.largeTitle.bold())
                Text("Your teacher's model of you — what you're learning, how well, what trips you up, and how you like to learn. Edit or delete anything.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search memory", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        .padding([.horizontal, .top], 28).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Text("\(memories.count) memories · \(subjects.reduce(0) { $0 + $1.concepts.count }) concept entries · learner memory follows you everywhere; folder memory lives in “\(app.workspace.name)/.teacher”")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Tidy up memory") { app.extensions.get(MemoryExtension.self)?.consolidateNow() }
                .help("Merge duplicates, link concepts across subjects, sharpen vague facts and remove noise")
            Button("Forget everything…", role: .destructive) { confirmClear = true }
        }.padding(.horizontal, 28).padding(.vertical, 10)
    }

    // MARK: Learning map

    @ViewBuilder private var mapTab: some View {
        if subjects.isEmpty {
            Text("The learning map fills in as you take lessons and quizzes: each concept you work on appears under its subjects with its mastery, prerequisites and any misconceptions.")
                .foregroundStyle(.secondary).padding(.vertical, 8)
        }
        if !links.isEmpty && search.isEmpty {
            Section {
                ForEach(links, id: \.self) { l in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(l.a.capitalized) ↔ \(l.b.capitalized)").bold()
                        Text(l.via.prefix(3).joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            } header: { Label("Connections across subjects", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        ForEach(filteredSubjects, id: \.subject) { group in
            Section {
                ForEach(group.concepts) { c in conceptRow(c, in: group.subject) }
            } header: {
                HStack {
                    Label(group.subject.capitalized, systemImage: "books.vertical")
                    Spacer()
                    let measured = group.concepts.compactMap(\.pKnown)
                    if !measured.isEmpty {
                        Text("avg mastery \(Int((measured.reduce(0, +) / Double(measured.count) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var filteredSubjects: [(subject: String, concepts: [Concept])] {
        guard !search.isEmpty else { return subjects }
        return subjects.compactMap { g in
            let cs = g.concepts.filter { $0.name.localizedCaseInsensitiveContains(search) || g.subject.localizedCaseInsensitiveContains(search) }
            return cs.isEmpty ? nil : (g.subject, cs)
        }
    }

    @ViewBuilder private func conceptRow(_ c: Concept, in subject: String) -> some View {
        let prereqs = hub.graph?.prerequisites(of: c.rowid) ?? []
        let misconceptions = memories.filter { $0.conceptID == c.rowid && $0.kind == .misconception }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(c.name).font(.body.weight(.medium))
                ForEach(c.subjects.filter { $0 != subject }, id: \.self) { s in badge(s) }
                if let st = c.status, c.pKnown == nil { Text(st).font(.caption2).foregroundStyle(st == "struggling" ? .orange : .secondary) }
                Spacer()
                masteryBar(c)
                Menu {
                    Button("Edit…") { editingConcept = c }
                    Button("Delete concept", role: .destructive) { hub.delete(c.id); reload(); app.refreshCounts() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            }
            if !prereqs.isEmpty {
                Text("Builds on: " + prereqs.map { "\($0.name) (\($0.masteryLabel))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let s = c.summary { Text(s).font(.caption).foregroundStyle(.secondary) }
            ForEach(misconceptions) { m in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    memoryBody(m, compact: true)
                }.padding(.leading, 12)
            }
        }.padding(.vertical, 3)
    }

    private func masteryBar(_ c: Concept) -> some View {
        HStack(spacing: 6) {
            if let p = c.pKnown {
                ProgressView(value: p).frame(width: 80).tint(p >= 0.95 ? .green : (p < 0.5 ? .orange : .accentColor))
                Text(c.masteryLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            } else {
                Text("no quiz data yet").font(.caption).foregroundStyle(.tertiary)
            }
        }.help(c.pKnown == nil ? "Mastery appears after quizzes or practice questions on this concept" : "Bayesian Knowledge Tracing estimate from your answers")
    }

    // MARK: About me

    @ViewBuilder private var aboutTab: some View {
        Section("Add something your teacher should know") {
            HStack {
                Picker("", selection: $newKind) {
                    ForEach([MemoryKind.profile, .goal, .preference, .misconception, .fact]) { k in Text(k.title).tag(k) }
                }.labelsHidden().frame(width: 170)
                TextField("e.g. I'm studying for the AP Calculus exam in May", text: $newText).onSubmit(add)
                Button("Add", action: add).disabled(newText.isEmpty)
            }
        }
        ForEach([MemoryKind.profile, .goal, .preference, .misconception, .fact, .knowledge]) { kind in
            let items = filtered.filter { $0.kind == kind && $0.scope == .learner && !(kind == .misconception && $0.conceptID != nil && search.isEmpty) }
            if !items.isEmpty {
                Section { ForEach(items) { m in memoryRow(m) } } header: { Label(kind.title, systemImage: kind.symbol) }
            }
        }
    }

    // MARK: All memories

    @ViewBuilder private var allTab: some View {
        ForEach(MemoryKind.allCases) { kind in
            let items = filtered.filter { $0.kind == kind }
            if !items.isEmpty {
                Section { ForEach(items) { m in memoryRow(m) } } header: { Label(kind.title, systemImage: kind.symbol) }
            }
        }
    }

    private var filtered: [Memory] {
        guard !search.isEmpty else { return memories }
        let hits = Set(hub.search(search, limit: 50, minScore: 0.2).map(\.id))
        return memories.filter { hits.contains($0.id) || $0.content.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private func memoryRow(_ m: Memory) -> some View {
        HStack(alignment: .top, spacing: 10) { memoryBody(m, compact: false) }.padding(.vertical, 3)
    }

    @ViewBuilder private func memoryBody(_ m: Memory, compact: Bool) -> some View {
        if editing == m.id {
            TextField("", text: $draft, axis: .vertical).onSubmit { save(m) }
            Button("Save") { save(m) }
            Button("Cancel") { editing = nil }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(m.content).textSelection(.enabled).font(compact ? .callout : .body)
                HStack(spacing: 8) {
                    if m.scope == .folder { Label("This folder", systemImage: "folder").labelStyle(.titleAndIcon) }
                    if !compact, let s = m.subject { badge(s) }
                    if !compact, let cid = m.conceptID, let c = hub.graph?.concept(cid) { Label(c.name, systemImage: "circle.hexagongrid") }
                    Text(originText(m.origin))
                    Text("· \(m.updatedAt.formatted(.relative(presentation: .named)))")
                    if m.evidence > 1 { Text("· seen \(m.evidence)×") }
                    if m.useCount > 0 { Text("· used \(m.useCount)×") }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if !compact { importanceDots(m.importance) }
            Button { provenance = m } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).help("Where this came from")
            Button { editing = m.id; draft = m.content } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
            if m.kind == .misconception || m.kind == .goal {
                Button { hub.resolveItem(m.id); reload(); app.refreshCounts() } label: { Image(systemName: "checkmark.circle") }
                    .buttonStyle(.borderless).help(m.kind == .goal ? "Goal reached" : "No longer a problem")
            }
            Button { hub.delete(m.id); reload(); app.refreshCounts() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private func originText(_ o: String) -> String {
        switch o {
        case "explicit": "you told me"
        case "reflection": "learned after a lesson"
        case "consolidation": "inferred while tidying"
        case "mastery": "from quizzes"
        default: "noticed in a lesson"
        }
    }

    private func badge(_ s: String) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    private func importanceDots(_ v: Double) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in Circle().fill(Double(i) < v * 5 ? Color.accentColor : Color.primary.opacity(0.12)).frame(width: 5, height: 5) }
        }.help("Importance \(Int(v * 100))%").padding(.top, 6)
    }

    private func reload() {
        memories = hub.all()
        hub.graph?.syncMastery()
        subjects = hub.graph?.subjects() ?? []
        links = hub.graph?.crossSubjectLinks() ?? []
        lessonTitles = Dictionary(app.services.conversations.all().map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    private func add() {
        guard !newText.isEmpty else { return }
        hub.add(kind: newKind, content: newText, importance: 0.8, origin: "explicit")
        newText = ""; reload(); app.refreshCounts()
    }

    private func save(_ m: Memory) {
        hub.update(m.id, content: draft)
        editing = nil; reload()
    }
}

private struct ProvenanceSheet: View {
    let memory: Memory
    let history: [MemoryHistoryEntry]
    let lesson: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where this memory came from").font(.title3.bold())
            Text(memory.content).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                row("Kind", memory.kind.title + (memory.scope == .folder ? " · this folder" : ""))
                row("Origin", memory.origin)
                row("Lesson", lesson ?? (memory.source == nil ? "—" : "a lesson that was deleted"))
                row("Created", memory.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Last changed", memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
                row("Observed", "\(memory.evidence)×")
                row("Used in replies", "\(memory.useCount)×" + (memory.lastUsedAt.map { ", last \($0.formatted(.relative(presentation: .named)))" } ?? ""))
            }
            if !history.isEmpty {
                Text("Earlier versions").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(history, id: \.self) { h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.content).font(.callout)
                                Text("\(h.change) · \(h.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxHeight: 180)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22).frame(width: 460)
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary); Text(v).textSelection(.enabled) }
    }
}

private struct ConceptEditor: View {
    let concept: Concept
    let hub: MemoryHub
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subjects = ""
    @State private var prereqs = ""
    @State private var summary = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit concept").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                TextField("Subjects (comma-separated)", text: $subjects)
                TextField("Builds on (comma-separated concepts)", text: $prereqs)
                TextField("Notes", text: $summary, axis: .vertical)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            name = concept.name
            subjects = concept.subjects.joined(separator: ", ")
            prereqs = (hub.graph?.prerequisites(of: concept.rowid) ?? []).map(\.name).joined(separator: ", ")
            summary = concept.summary ?? ""
        }
    }

    private func split(_ s: String) -> [String] { s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func save() {
        guard let g = hub.graph else { return }
        g.update(concept.rowid, name: name, summary: summary, subjects: split(subjects))
        let wanted = Set(split(prereqs).map(MemoryText.conceptKey))
        for p in g.prerequisites(of: concept.rowid) where !wanted.contains(MemoryText.conceptKey(p.name)) { g.unlink(concept.rowid, p.rowid) }
        hub.saveConcept(name: name, prerequisites: split(prereqs), origin: "explicit")
        EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: [concept.id])))
        onSave()
    }
}
