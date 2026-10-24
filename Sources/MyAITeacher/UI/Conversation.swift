import SwiftUI
import Combine

/// A spoken conversation in the language being learned, turn by turn: the learner speaks (the best recogniser this Mac
/// has for the language; the turn ends after a pause, or with "Done speaking"), what was heard goes to the lesson as
/// their message, the mentor answers in the language as a conversation partner — short, no corrections yet — and the
/// answer is spoken with the best voice; then the Mac listens again. "End conversation" asks for the corrections,
/// collected from everything they said. Every turn is an ordinary message, so the lesson keeps the transcript.
@MainActor
final class ConversationController: ObservableObject {
    enum Phase: Equatable { case off, listening, thinking, speaking, paused }
    @Published private(set) var phase: Phase = .off
    @Published private(set) var heard = ""
    @Published private(set) var engine = ""
    @Published private(set) var turns = 0
    private weak var session: ChatSession?
    private var language = ""
    private var running: AnyCancellable?
    private let speech = AppModel.shared.speech

    /// What the mentor is told on every conversation turn (hidden, for that request only).
    static func turnNote(_ lang: String) -> String {
        """
        <conversation lang="\(lang)">Spoken conversation in \(Languages.englishName(lang)): the learner's message is what the Mac heard them say (recognition can mishear). Answer as a conversation partner, in \(Languages.englishName(lang)) only, 1–3 short sentences at their level, then a question that keeps it going. Don't correct them now — note their mistakes for the end. No quizzes, tools or blocks: your reply is read aloud.</conversation>
        """
    }
    static func endNote(_ lang: String) -> String {
        """
        <conversation_end lang="\(lang)">The spoken conversation is over. Now give the feedback you held back: for each of their turns that had mistakes, a ```correction (original: what was heard, exactly; corrected; errors with why) — say when a "mistake" may be the recogniser mishearing — then what went well and one thing to practise next.</conversation_end>
        """
    }

    func start(_ session: ChatSession, listenNow: Bool = true) {
        guard let lang = session.language?.target else { return }
        self.session = session; language = lang; turns = 0
        running = session.$isRunning.removeDuplicates().sink { [weak self] running in
            guard let self, !running, self.phase == .thinking else { return }
            DispatchQueue.main.async { self.replyFinished() }
        }
        if listenNow { listen() } else { phase = .paused }
    }
    /// Test runs: the Mac doesn't listen (no microphone prompt); turns come from `simulateHeard`.
    var quiet = false

    func listen() {
        guard let s = session, phase != .off || turns == 0 else { return }
        if quiet { phase = .paused; return }
        heard = ""; phase = .listening
        speech.dictate(language: language, stopAfterSilence: 1.4) { [weak self] text, final, info in
            guard let self, self.phase == .listening else { return }
            self.heard = text
            if let e = info?["engine"]?.string { self.engine = e } else if !self.speech.engineName.isEmpty { self.engine = self.speech.engineName }
            guard final else { return }
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty { self.phase = .paused; return }   // nothing heard: wait for the learner to try again
            self.send(said, to: s)
        }
    }

    /// The learner's turn, as their message, with the conversation note hidden beside it.
    func send(_ said: String, to s: ChatSession) {
        guard !s.isRunning else { return }
        turns += 1; phase = .thinking
        s.send(said, attachments: [Block(kind: .text, text: Self.turnNote(language), meta: ["hidden": true, "ephemeral": true, "spoken": .string(language)])])
    }

    func doneSpeaking() { if phase == .listening { speech.stopListening() } }
    func pause() { if phase == .listening { phase = .paused; speech.stopListening() } else if phase == .speaking { speech.stop(); phase = .paused } }
    func resume() { if phase == .paused { listen() } }

    private func replyFinished() {
        guard let s = session, phase == .thinking else { return }
        let reply = s.messages.last(where: { $0.role == .assistant })?.plainText ?? ""
        guard !reply.isEmpty else { listen(); return }
        phase = .speaking
        speech.speak(reply, language: language, voice: nil, rate: AppModel.shared.settings.value.speechRate) { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.listen()
        }
    }

    func end() {
        let was = phase
        phase = .off
        speech.stopListening(); speech.stop()
        running = nil
        guard let s = session, turns > 0, was != .thinking || !s.isRunning else { return }
        s.send("That's the end of our conversation. What should I fix?", attachments: [Block(kind: .text, text: Self.endNote(language), meta: ["hidden": true, "ephemeral": true])])
    }

    /// Test hook: a learner's turn as if heard (the recogniser itself is tested elsewhere).
    func simulateHeard(_ text: String) {
        guard let s = session, phase == .listening || phase == .paused else { return }
        speech.stopListening()
        phase = .listening
        heard = text
        send(text, to: s)
    }
}

/// The bar above the composer while a conversation is on: who is talking, what was heard, which engine heard it.
struct ConversationBar: View {
    @ObservedObject var talk: ConversationController
    let language: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 18)).symbolEffect(.pulse, isActive: talk.phase == .listening || talk.phase == .speaking)
            VStack(alignment: .leading, spacing: 2) {
                Text(status).font(.callout.bold())
                if !talk.heard.isEmpty, talk.phase == .listening || talk.phase == .thinking { Text(talk.heard).font(.callout).lineLimit(2) }
                Text(talk.engine.isEmpty ? "Speech recognition in \(Languages.englishName(language))" : talk.engine)
                    .font(.caption2).foregroundStyle(talk.engine.contains("online") ? .orange : .secondary)
            }
            Spacer()
            switch talk.phase {
            case .listening: Button("Done speaking") { talk.doneSpeaking() }.controlSize(.small)
            case .paused: Button("Speak") { talk.resume() }.controlSize(.small).buttonStyle(.borderedProminent)
            case .speaking: Button("Skip") { talk.pause() }.controlSize(.small)
            default: EmptyView()
            }
            Button("End conversation") { talk.end() }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
    }
    private var icon: String {
        switch talk.phase { case .listening: "mic.fill"; case .speaking: "speaker.wave.2.fill"; case .thinking: "ellipsis.bubble"; default: "mic.slash" }
    }
    private var color: Color { talk.phase == .listening ? .red : .accentColor }
    private var status: String {
        switch talk.phase {
        case .listening: "Your turn — speak in \(Languages.englishName(language)); a pause ends it"
        case .thinking: "Your teacher is answering…"
        case .speaking: "Your teacher is speaking"
        case .paused: talk.heard.isEmpty && talk.turns == 0 ? "Ready — press Speak and talk in \(Languages.englishName(language))" : "Paused — nothing clear was heard, or you paused"
        case .off: ""
        }
    }
}
