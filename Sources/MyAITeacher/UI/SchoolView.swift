import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The school, as the learner sees it: what they're enrolled in and what's next, the catalog, and the transcript. Levels
/// are per competency and come from evidence; courses complete themselves when the evidence says so.
@MainActor
final class SchoolModel: ObservableObject {
    @Published var graph = CompetencyGraph.builtIn
    @Published var estimates: [String: Estimate] = [:]
    @Published var enrollments: [Enrollment] = []
    @Published var profile: SchoolProfile?
    @Published var measures = SchoolStore.Measures()
    @Published var placement: Placement?

    func reload(_ school: SchoolStore) {
        school.progressCourses()
        graph = school.graph
        estimates = school.estimates()
        enrollments = school.enrollments()
        profile = school.profile
        measures = school.measures()
        placement = school.placement
    }
}

struct SchoolView: View {
    enum Tab: String, CaseIterable { case dashboard = "Dashboard", catalog = "Catalog", transcript = "Transcript" }
    @EnvironmentObject var app: AppModel
    @StateObject private var model = SchoolModel()
    @State private var tab: Tab = .dashboard
    @State private var editingProfile = false
    private var school: SchoolStore { app.services.school }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("School").font(.largeTitle.bold())
                Spacer()
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .dashboard: dashboard
                    case .catalog: catalog
                    case .transcript: transcript
                    }
                }
                .padding(20).frame(maxWidth: 900, alignment: .leading)
            }
        }
        .onAppear { model.reload(school) }
        .onReceive(EventBus.subject.receive(on: RunLoop.main)) { e in if case .studyDataChanged = e { model.reload(school) } }
        .sheet(isPresented: $editingProfile) {
            ProfileSheet(profile: model.profile ?? SchoolProfile()) { p, place in
                school.profile = p
                model.reload(school)
                if place { startPlacement(p) }
            }
        }
    }

    // MARK: Dashboard

    @ViewBuilder private var dashboard: some View {
        if let p = model.profile {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.goal.isEmpty ? "No goal set" : p.goal).font(.title3.weight(.semibold))
                    Text("\(p.track.title) track · \(p.hoursPerWeek) h a week" + (p.wants.isEmpty ? "" : " · wants \(p.wants.joined(separator: ", "))")).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { editingProfile = true }
                Button(model.placement.map { $0.done ? "Place me again" : "Continue placement" } ?? "Take placement") { startPlacement(p) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start here").font(.headline)
                    Text("Say what you want to be able to do, the track you're aiming for and the time you have. A short adaptive placement then finds your level for each topic — a level is per topic and moves with your evidence, never a label for you.")
                        .foregroundStyle(.secondary)
                    Button("Set up my school") { editingProfile = true }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
        let enrolled = model.enrollments.filter { $0.status == "enrolled" }.compactMap { model.graph.course($0.course) }
        section("Your courses") {
            if enrolled.isEmpty { Text("No courses yet: open the Catalog, or take the placement to see where to start.").foregroundStyle(.secondary) }
            ForEach(enrolled) { c in courseCard(c) }
        }
        let due = model.estimates.values.filter(\.recheckDue).compactMap { e in model.graph[e.competency] }
        if !due.isEmpty {
            section("Due a re-check") {
                Text("You've shown these before, but not unaided for a while: a short unseen check keeps the level honest.").font(.callout).foregroundStyle(.secondary)
                ButtonFlow(items: due.map(\.title)) { t in
                    Button(t) { startLesson("Give me a short unseen check on \(t): one task, no hints unless I ask.", competency: model.graph.resolve(t)?.id, course: nil) }
                }
            }
        }
        section("Your levels") {
            if model.estimates.isEmpty { Text("Levels appear as you answer, build and explain: each piece of evidence counts by how reliable it is and how much help you had.").foregroundStyle(.secondary) }
            ForEach(model.estimates.values.sorted { ($0.level?.rawValue ?? 0, $0.evidenceCount) > ($1.level?.rawValue ?? 0, $1.evidenceCount) }.prefix(40), id: \.competency) { e in
                levelRow(e)
            }
        }
        section("How the learning is going") {
            HStack(spacing: 12) {
                stat(model.measures.hintDependence.map { "\(Int($0 * 100))%" } ?? "—", "help in the last 30 days", "Share of your recent answers that had a hint or a solution")
                stat(model.measures.retention.map { "\(Int($0 * 100))%" } ?? "—", "retained after 30+ days", "Unaided success on topics first shown at least 30 days earlier")
                stat(model.measures.transfer.map { "\(Int($0 * 100))%" } ?? "—", "transfer", "Success using a concept in a new context or language")
            }
        }
    }

    private func courseCard(_ c: Course) -> some View {
        let p = school.progress(c, estimates: model.estimates)
        let next = p.next(model.graph).flatMap { model.graph[$0] }
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(c.id) · \(c.title)").font(.headline)
                    levelChip(c.level)
                    Spacer()
                    Text("\(p.met.count)/\(c.competencies.count) outcomes").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: Double(p.met.count), total: Double(max(1, c.competencies.count)))
                if let next {
                    HStack {
                        Text("Next: \(next.title) — \(next.outcome(c.level))").font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Continue") {
                            startLesson("Continue \(c.id) \(c.title): teach me \(next.title).", competency: next.id, course: c.id, mode: c.program == "programming" && c.assessments.contains("project") ? .code : .tutor)
                        }
                    }
                }
                if !p.summative, p.remaining.isEmpty {
                    Text("Every outcome is shown: a summative task (an unseen problem, tests on your own code, a review or a defence) completes it.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
        .contextMenu { Button("Drop this course") { school.drop(c.id); model.reload(school) } }
    }

    private func levelRow(_ e: Estimate) -> some View {
        HStack(spacing: 10) {
            Text(model.graph[e.competency]?.title ?? e.competency).frame(width: 240, alignment: .leading).lineLimit(1)
            if let l = e.level {
                levelChip(l)
                if let d = e.developing { Text("→ \(d.title.lowercased())").font(.caption).foregroundStyle(.secondary) }
            } else if let s = e.shown {
                Text("shown once at \(s.title.lowercased())").font(.caption).foregroundStyle(.secondary).help("One unaided success at this level: another task in a second skill makes it held")
            } else {
                Text("not yet shown").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(Skill.allCases, id: \.self) { s in
                Circle().fill(e.skills[s].map { Self.color($0) } ?? Color.secondary.opacity(0.15)).frame(width: 8, height: 8)
                    .help("\(s.rawValue.capitalized): " + (e.skills[s].map { "shown unaided at \($0.title.lowercased()) level" } ?? "not shown yet"))
            }
            Text(e.independence.map { "\(Int($0 * 100))% alone" } ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Catalog

    @ViewBuilder private var catalog: some View {
        Text("Courses at five levels — school, college, university, research — each with outcomes it certifies from evidence. Completion and grades come from your evidence; a placement can show a prerequisite you already hold.")
            .foregroundStyle(.secondary)
        let status = Dictionary(model.enrollments.map { ($0.course, $0.status) }, uniquingKeysWith: { a, _ in a })
        ForEach(Level.allCases.filter { l in model.graph.courses.contains { $0.level == l } }) { level in
            section(level.title) {
                ForEach(model.graph.courses.filter { $0.level == level }) { c in
                    let unmet = school.unmetPrerequisites(c, graph: model.graph, estimates: model.estimates)
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(c.id) · \(c.title)").font(.headline)
                                Text("\(c.hours) h").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                switch status[c.id] {
                                case "completed": Label("Completed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                                case "enrolled": Text("Enrolled").foregroundStyle(.secondary)
                                default:
                                    Button("Enroll") { _ = school.enroll(c.id); model.reload(school) }.disabled(!unmet.isEmpty)
                                        .help(unmet.isEmpty ? "Add it to your courses" : "Needs \(unmet.joined(separator: ", ")) first (or show the level in a placement)")
                                        .contextMenu { if !unmet.isEmpty { Button("Enroll anyway") { _ = school.enroll(c.id, override: true); model.reload(school) } } }
                                }
                            }
                            Text(c.summary).font(.callout)
                            Text("Outcomes: " + c.competencies.compactMap { model.graph[$0]?.title }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            Text("Assessed by " + c.assessments.joined(separator: ", ") + (c.prereqs.isEmpty ? "" : " · after " + c.prereqs.joined(separator: ", ")))
                                .font(.caption).foregroundStyle(unmet.isEmpty ? Color.secondary : Color.orange)
                        }.padding(4)
                    }
                }
            }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        Label("An internal learning record built from evidence: not an accredited qualification or a degree.", systemImage: "info.circle").foregroundStyle(.secondary)
        let done = model.enrollments.filter { $0.status == "completed" }
        section("Completed courses") {
            if done.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
            ForEach(done, id: \.course) { e in
                HStack {
                    Text("\(e.course) · \(model.graph.course(e.course)?.title ?? "")")
                    Spacer()
                    Text(e.grade ?? "").bold()
                    if let d = e.completedAt { Text(d, style: .date).foregroundStyle(.secondary) }
                }
            }
        }
        section("Competencies") {
            ForEach(model.estimates.values.filter { $0.level != nil }.sorted { ($0.level!.rawValue, $0.competency) > ($1.level!.rawValue, $1.competency) }, id: \.competency) { e in levelRow(e) }
        }
        Button("Export transcript…") {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = "Transcript.md"
            if panel.runModal() == .OK, let url = panel.url { try? Data(SchoolReport.markdown(school).utf8).write(to: url) }
        }
    }

    // MARK: Actions

    private func startPlacement(_ p: SchoolProfile) {
        let resume = model.placement.map { !$0.done } ?? false
        startLesson(resume ? "Let's continue my placement." :
                    "Place me, please. My goal: \(p.goal.isEmpty ? "general programming" : p.goal). I'm aiming for the \(p.track.title.lowercased()) track. Use the school placement: one short question at a time, and ask how sure I am.",
                    competency: nil, course: nil)
    }

    private func startLesson(_ prompt: String, competency: String?, course: String?, mode: TeachingMode = .tutor) {
        let id = app.newLesson(mode: mode)
        if competency != nil || course != nil { school.setLink(id, competency: competency, course: course) }
        app.session(for: id)?.send(prompt)
    }

    // MARK: Bits

    static func color(_ l: Level) -> Color {
        switch l { case .school: .teal; case .college: .blue; case .university: .indigo; case .research: .purple; case .expert: .pink }
    }
    private func levelChip(_ l: Level) -> some View {
        Text(l.title).font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Self.color(l).opacity(0.18))).foregroundStyle(Self.color(l))
    }
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.title2.bold()); content() }
    }
    private func stat(_ value: String, _ label: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10).frame(minWidth: 150, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .help(help)
    }
}

/// Wrapping row of small buttons.
private struct ButtonFlow<Content: View>: View {
    let items: [String]
    let content: (String) -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// Goal, track, time and the evidence wanted: what the school plans around.
struct ProfileSheet: View {
    @State var profile: SchoolProfile
    var save: (SchoolProfile, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var languages = ""
    static let wantsOptions = ["understanding", "project", "portfolio", "certificate", "research"]

    var body: some View {
        Form {
            TextField("What do you want to be able to do?", text: $profile.goal, axis: .vertical).lineLimit(2...4)
            Picker("Track", selection: $profile.track) {
                ForEach([Level.school, .college, .university, .research]) { Text($0.title).tag($0) }
            }
            Text(profile.track.descriptor.prefix(1).uppercased() + profile.track.descriptor.dropFirst() + ".").font(.caption).foregroundStyle(.secondary)
            Stepper("\(profile.hoursPerWeek) hours a week", value: $profile.hoursPerWeek, in: 1...60)
            Section("The evidence you want at the end") {
                ForEach(Self.wantsOptions, id: \.self) { w in
                    Toggle(w.capitalized, isOn: Binding(get: { profile.wants.contains(w) },
                                                        set: { on in if on { profile.wants.append(w) } else { profile.wants.removeAll { $0 == w } } }))
                }
            }
            TextField("Languages you use or want (comma-separated)", text: $languages)
            if profile.wants.contains("certificate") {
                Text("Certificates here are internal records of evidence, not accredited qualifications.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit(false) }
                Button("Save and take placement") { commit(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped).frame(width: 480).padding()
        .onAppear { languages = profile.languages.joined(separator: ", ") }
    }

    private func commit(_ place: Bool) {
        profile.languages = languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        profile.updatedAt = Date()
        save(profile, place)
        dismiss()
    }
}
