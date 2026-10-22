import SwiftUI

/// Watches the lesson's course board (the app's study store) and reloads it when study data changes.
@MainActor
final class BoardModel: ObservableObject {
    @Published private(set) var board: CourseBoard?
    private var lesson: String?
    private var study: StudyStore?

    func bind(_ session: ChatSession) {
        lesson = session.id
        study = session.services.study
        reload()
    }
    func reload() {
        guard let lesson, let study else { board = nil; return }
        board = study.board(forLesson: lesson)
    }
    /// The learner shelves a question for later: a parked card the mentor sees in the state header.
    func park(_ text: String) {
        guard let lesson, let study, var b = board else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, (try? b.add(title: MemoryText.clip(t, 80), lane: .parked, note: t.count > 80 ? t : nil,
                                       reason: "saved by the learner for later", actor: "learner")) != nil else { return }
        study.save(b, conversationID: lesson)
        EventBus.publish(.studyDataChanged)
    }
}

/// Inspector tab: the course board — the focus card first, then the lanes and a parked drawer. The learner can shelve a
/// question or ask for a check; only the mentor marks cards done (with evidence).
struct BoardPanel: View {
    @EnvironmentObject var app: AppModel
    var session: ChatSession?
    @StateObject private var model = BoardModel()
    @State private var parkText = ""
    @State private var parkedOpen = true

    var body: some View {
        Group {
            if let b = model.board {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(b)
                        focus(b)
                        lane(b, .review, empty: nil)
                        lane(b, .backlog, empty: "Nothing queued.")
                        lane(b, .done, empty: nil)
                        parked(b)
                        saveForLater
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView("No course board yet", systemImage: "rectangle.3.group",
                                       description: Text("Ask your teacher for a learning plan for a bigger goal, or continue one from the Progress screen."))
            }
        }
        .onAppear { if let s = session { model.bind(s) } }
        .onChange(of: session?.id) { _, _ in if let s = session { model.bind(s) } }
        .onReceive(EventBus.subject.receive(on: RunLoop.main)) { e in
            if case .studyDataChanged = e { model.reload() }
        }
    }

    private func header(_ b: CourseBoard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(b.title).font(.headline)
            if let g = b.goal, !g.isEmpty { Text(g).font(.callout).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                ProgressView(value: b.courseCount == 0 ? 0 : Double(b.doneCount) / Double(b.courseCount))
                Text("\(b.doneCount)/\(b.courseCount)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let d = b.daysLeft() {
                Text(d < 0 ? "Deadline passed" : d == 0 ? "Deadline today" : "\(d) day\(d == 1 ? "" : "s") left").font(.caption).foregroundStyle(d <= 3 ? .orange : .secondary)
            }
        }
    }

    private func focus(_ b: CourseBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Focus").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if let f = b.focus {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(f.id.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text(f.title).font(.title3.weight(.semibold))
                    }
                    Text(f.next.map { "Next: \($0)" } ?? "Next action not set yet.").font(.callout)
                        .foregroundStyle(f.next == nil ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                    if !f.objectives.isEmpty {
                        ForEach(f.objectives, id: \.self) { o in Label(o, systemImage: "circle").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !f.evidence.isEmpty {
                        Text("Evidence: " + f.evidence.suffix(3).joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                    }
                    check(f)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
            } else {
                Text(b.cards.isEmpty ? "The board is empty." : "No focus card: your teacher picks the next one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func lane(_ b: CourseBoard, _ l: CourseBoard.Lane, empty: String?) -> some View {
        let cards = b.lane(l)
        return Group {
            if !cards.isEmpty || empty != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(l.title) · \(cards.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    if cards.isEmpty, let empty { Text(empty).font(.caption).foregroundStyle(.tertiary) }
                    ForEach(cards) { c in row(c) }
                }
            }
        }
    }

    private func row(_ c: CourseBoard.Card) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: c.lane == .done ? "checkmark.circle.fill" : c.lane == .review ? "arrow.triangle.2.circlepath.circle" : "circle")
                .foregroundStyle(c.lane == .done ? .green : c.lane == .review ? .orange : .secondary)
                .accessibilityLabel(c.lane.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(c.id.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    Text(c.title).font(.callout).strikethrough(c.lane == .done, color: .secondary).foregroundStyle(c.lane == .done ? .secondary : .primary)
                }
                if let n = c.next, c.lane != .done { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                if !c.after.isEmpty, c.lane != .done { Text("after " + c.after.map { $0.uppercased() }.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary) }
                if c.lane == .done, let e = c.evidence.last { Text(e).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if c.lane != .done { check(c, compact: true) }
        }
        .padding(.vertical, 3)
    }

    /// "I think I know this": the mentor checks it with a fresh question, and decides what counts as done.
    private func check(_ c: CourseBoard.Card, compact: Bool = false) -> some View {
        Button {
            session?.send("I think I know \(c.title) (\(c.id.uppercased())). Check me with a fresh question before we move on.")
        } label: {
            if compact { Image(systemName: "checkmark.message") } else { Label("Ask for a check", systemImage: "checkmark.message") }
        }
        .buttonStyle(.borderless).font(.caption).disabled(session == nil || session?.isRunning == true)
        .help("Ask your teacher to check this with a question")
    }

    private func parked(_ b: CourseBoard) -> some View {
        let cards = b.lane(.parked)
        return DisclosureGroup(isExpanded: $parkedOpen) {
            if cards.isEmpty { Text("Nothing parked. Detours and questions for later land here.").font(.caption).foregroundStyle(.tertiary) }
            ForEach(cards) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "tray").foregroundStyle(.secondary).accessibilityLabel("Parked")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.callout)
                        if let r = c.parkedReason { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    Button {
                        session?.send("Let's come back to \(c.title) (\(c.id.uppercased())) now.")
                    } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).disabled(session == nil || session?.isRunning == true).help("Ask to come back to this now")
                }
                .padding(.vertical, 3)
            }
        } label: {
            Text("Parked · \(cards.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
        }
    }

    private var saveForLater: some View {
        HStack(spacing: 6) {
            TextField("Save a question for later…", text: $parkText)
                .textFieldStyle(.roundedBorder).onSubmit(park)
            Button("Park", action: park).disabled(parkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .font(.callout)
    }

    private func park() {
        model.park(parkText)
        parkText = ""
    }
}

/// One line above the composer: where the lesson is, at a glance. Click opens the board.
struct BoardStrip: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ChatSession
    @StateObject private var model = BoardModel()

    var body: some View {
        Group {
            if let b = model.board, !session.conversation.mode.isAgent {
                Button {
                    app.inspectorTab = .plan
                    app.inspectorShown = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.3.group").foregroundStyle(Color.accentColor)
                        Text(Self.line(b)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Course board: " + Self.line(b))
                .help("Open the course board")
            }
        }
        .onAppear { model.bind(session) }
        .onChange(of: session.id) { _, _ in model.bind(session) }
        .onReceive(EventBus.subject.receive(on: RunLoop.main)) { e in
            if case .studyDataChanged = e { model.reload() }
        }
    }

    static func line(_ b: CourseBoard) -> String {
        var parts: [String] = []
        if let f = b.focus { parts.append("Focus: \(f.title)" + (f.next.map { " — next: \(MemoryText.clip($0, 70))" } ?? "")) }
        else { parts.append(b.cards.isEmpty ? "Board empty" : "No focus card") }
        let parked = b.lane(.parked).count
        if parked > 0 { parts.append("\(parked) parked") }
        parts.append("\(b.doneCount)/\(b.courseCount) done")
        if let d = b.daysLeft(), d >= 0 { parts.append(d == 0 ? "deadline today" : "\(d) day\(d == 1 ? "" : "s") left") }
        return parts.joined(separator: " · ")
    }
}
