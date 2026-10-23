import SwiftUI

/// The learner model, made visible: subjects → concepts (mastery, prerequisites, misconceptions), cross-subject
/// connections, profile/goals/preferences, and every memory with its provenance. Everything is editable.
struct MemoryView: View {
    @EnvironmentObject var app: AppModel

    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", map = "Learning map", me = "About me", all = "All memories"; var id: String { rawValue } }

    @State private var tab: Tab = .overview
    @State private var concepts: [Concept] = []
    @State private var ready: [Concept] = []
    @State private var fading: [Concept] = []
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
                case .overview: overviewTab
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

    // MARK: Overview

    /// The learner model at a glance: where you stand, what to learn next, what's slipping, what trips you up.
    @ViewBuilder private var overviewTab: some View {
        if concepts.isEmpty && memories.isEmpty {
            Text("Your teacher builds this as you learn: concepts with mastery that fades unless practised, what you're ready to learn next, misconceptions to watch for, and your goals.")
                .foregroundStyle(.secondary).padding(.vertical, 8)
        } else {
            Section { statsRow } header: { Label("Where you stand", systemImage: "gauge.with.dots.needle.67percent") }
            if !ready.isEmpty {
                Section { chips(ready, tint: .accentColor, detail: { c in c.pKnown == nil ? (c.status ?? "new") : "\(Int(((c.effectiveMastery() ?? 0) * 100).rounded()))%" }) }
                header: { Label("Ready to learn next — everything it builds on is solid", systemImage: "arrow.forward.circle") }
            }
            if !fading.isEmpty {
                Section { chips(fading, tint: .orange, detail: { c in "was \(Int(((c.pKnown ?? 0) * 100).rounded()))% → ~\(Int(((c.effectiveMastery() ?? 0) * 100).rounded()))%" }) }
                header: { Label("Fading — a quick review question will lock these in", systemImage: "hourglass") }
            }
            let watch = memories.filter { $0.kind == .misconception }
            if !watch.isEmpty {
                Section { ForEach(watch.prefix(8)) { m in Label { Text(m.content) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) } } }
                header: { Label("Watch for", systemImage: "eye") }
            }
            let goals = memories.filter { $0.kind == .goal }
            if !goals.isEmpty {
                Section { ForEach(goals.prefix(6)) { m in Label(m.content, systemImage: "flag") } } header: { Label("Goals", systemImage: "target") }
            }
            if !subjects.isEmpty {
                Section { ForEach(subjects, id: \.subject) { g in subjectTiles(g.subject, g.concepts) } }
                header: { Label("Mastery by subject (with forgetting)", systemImage: "square.grid.3x3.fill") }
            }
        }
    }

    private var statsRow: some View {
        let measured = concepts.compactMap { $0.effectiveMastery() }
        let solid = concepts.filter { $0.isSolid() }.count
        let weak = concepts.filter { ($0.effectiveMastery() ?? 1) < 0.5 || $0.status == "struggling" }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stat("\(concepts.count)", "concepts")
                stat("\(solid)", "solid", .green)
                stat("\(concepts.count - solid - weak)", "learning", .accentColor)
                stat("\(weak)", "need work", .orange)
                stat("\(fading.count)", "fading", .orange)
                stat("\(memories.filter { $0.kind == .misconception }.count)", "misconceptions", .red)
            }
            if !measured.isEmpty {
                // Distribution of current mastery across measured concepts.
                GeometryReader { geo in
                    let buckets = [measured.filter { $0 < 0.5 }.count, measured.filter { $0 >= 0.5 && $0 < 0.8 }.count, measured.filter { $0 >= 0.8 }.count]
                    let total = max(1, measured.count)
                    HStack(spacing: 2) {
                        ForEach(Array(zip([Color.orange, .accentColor, .green], buckets).enumerated()), id: \.offset) { _, pair in
                            if pair.1 > 0 { RoundedRectangle(cornerRadius: 3).fill(pair.0.opacity(0.8)).frame(width: max(4, geo.size.width * CGFloat(pair.1) / CGFloat(total) - 2)) }
                        }
                    }
                }.frame(height: 8)
                Text("Average current mastery \(Int((measured.reduce(0, +) / Double(measured.count) * 100).rounded()))% across \(measured.count) measured concepts · mastery fades without practice; each correct recall makes it last longer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 84, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.secondary.opacity(0.08)))
    }

    private func chips(_ cs: [Concept], tint: Color, detail: @escaping (Concept) -> String) -> some View {
        FlowRow(spacing: 6) {
            ForEach(cs) { c in
                Button { search = c.name; tab = .map } label: {
                    HStack(spacing: 5) {
                        Text(c.name).lineLimit(1)
                        Text(detail(c)).foregroundStyle(.secondary).font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(tint.opacity(0.12)))
                }.buttonStyle(.plain).help("Open in the learning map")
            }
        }.padding(.vertical, 2)
    }

    private func subjectTiles(_ subject: String, _ cs: [Concept]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(subject.capitalized).font(.subheadline.weight(.semibold))
            FlowRow(spacing: 3) {
                ForEach(cs) { c in
                    let p = c.effectiveMastery()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(p.map { $0 >= 0.8 ? Color.green : $0 >= 0.5 ? Color.accentColor : Color.orange }.map { AnyShapeStyle($0.opacity(0.35 + 0.65 * (p ?? 0))) } ?? AnyShapeStyle(Color.secondary.opacity(0.18)))
                        .frame(width: 18, height: 18)
                        .help("\(c.name): " + (p.map { "\(Int(($0 * 100).rounded()))% now" + (c.isFading() ? " (fading)" : "") } ?? (c.status ?? "no quiz data yet")))
                        .onTapGesture { search = c.name; tab = .map }
                }
            }
        }.padding(.vertical, 3)
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
            Button { provenance = m } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless).accessibilityLabel("Where this came from").help("Where this came from")
            Button { editing = m.id; draft = m.content } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).accessibilityLabel("Edit memory").help("Edit")
            if m.kind == .misconception || m.kind == .goal {
                Button { hub.resolveItem(m.id); reload(); app.refreshCounts() } label: { Image(systemName: "checkmark.circle") }.accessibilityLabel(m.kind == .goal ? "Goal reached" : "No longer a problem")
                    .buttonStyle(.borderless).help(m.kind == .goal ? "Goal reached" : "No longer a problem")
            }
            Button { hub.delete(m.id); reload(); app.refreshCounts() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete memory").help("Delete")
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
        concepts = hub.graph?.all() ?? []
        ready = hub.graph?.readyToLearn(limit: 12) ?? []
        fading = hub.graph?.fading(limit: 12) ?? []
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


/// Wrapping row of chips (a minimal flow layout).
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}
