import SwiftUI

/// Progress › "How you work as an engineer": what the code mentor's reviews show across projects, with the evidence
/// behind every pattern. Counts and findings, no scores. The learner can dismiss a pattern (the mentor stops using it)
/// or reset it all; the data stays in the app's learner-wide store, never in a project folder.
struct EngineerProfileView: View {
    @EnvironmentObject var app: AppModel
    @State private var profile = EngineerProfile(stats: [], reviewCount: 0, latestLanguage: nil)
    @State private var dismissedCount = 0
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How you work as an engineer").font(.title3.bold())
            if profile.reviewCount == 0 {
                Text("After a few code reviews this shows what your mentor keeps noticing across projects, with the reviews behind it. Nothing is concluded from a single review.")
                    .foregroundStyle(.secondary)
            } else if profile.patterns.isEmpty && profile.improved.isEmpty {
                Text("\(profile.reviewCount) review round\(profile.reviewCount == 1 ? "" : "s") so far. No habit has come up often enough to name: that takes the same thing showing up in several projects.")
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.patterns) { s in patternCard(s) }
            if !profile.improved.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Moving past").font(.headline)
                    ForEach(profile.improved) { s in
                        Label("\(s.area.title)\(s.language.isEmpty ? "" : " in " + EngineerLanguage.label(s.language)): it came up \(s.allHits) times before, and not in your last two reviews.",
                              systemImage: "arrow.down.right.circle").font(.callout).foregroundStyle(.green)
                    }
                }
            }
            let seen = profile.stats.filter { $0.status == .seen }
            if !seen.isEmpty {
                DisclosureGroup("Also noticed once or twice") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(seen) { s in
                            Text("\(s.area.title)\(s.language.isEmpty ? "" : " · " + EngineerLanguage.label(s.language)): in \(s.hits) of the last \(s.window) review\(s.window == 1 ? "" : "s")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 4)
                }
            }
            if profile.reviewCount > 0 || dismissedCount > 0 {
                HStack(spacing: 14) {
                    Text("Built from your code reviews, kept on this Mac. Your mentor uses the patterns to choose what to practise and check first.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if dismissedCount > 0 { Button("Show \(dismissedCount) dismissed") { app.services.study.engineer.restoreDismissed(); reload() } }
                    Button("Reset…") { confirmReset = true }
                }.buttonStyle(.link).font(.caption)
            }
        }
        .onAppear(perform: reload)
        .onReceive(EventBus.subject.filter { if case .studyDataChanged = $0 { return true }; return false }) { _ in reload() }
        .confirmationDialog("Forget what your reviews showed?", isPresented: $confirmReset) {
            Button("Reset profile", role: .destructive) { app.services.study.engineer.reset(); reload() }
        } message: {
            Text("This clears the profile and its dismissed patterns. Your projects and their reviews stay as they are; only reviews from now on count.")
        }
    }

    private func reload() {
        let store = app.services.study.engineer
        profile = store.profile(); dismissedCount = store.dismissed().count
    }

    private func patternCard(_ s: EngineerProfile.AreaStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.area.title).font(.headline)
                if !s.language.isEmpty { Text(EngineerLanguage.label(s.language)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Dismiss") { app.services.study.engineer.dismiss(area: s.area, language: s.language); reload() }
                    .buttonStyle(.link).font(.caption).help("Not a habit of yours, or no longer: your mentor stops using it")
            }
            Text(profile.sentence(s)).font(.callout)
            Text(detail(s)).font(.caption).foregroundStyle(.secondary)
            ForEach(s.evidence) { f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: f.resolved ? "checkmark.circle" : "circle.dashed").foregroundStyle(f.resolved ? .green : .orange).font(.caption)
                    Button { open(f) } label: {
                        Text("\(f.file)\(f.line.map { ":\($0)" } ?? "")").font(.caption.monospaced())
                    }.buttonStyle(.link).help("Open in your editor")
                    Text(f.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    /// Fixes alone and fixes with hints are told apart, and a trend only when the reviews can show one.
    private func detail(_ s: EngineerProfile.AreaStat) -> String {
        var parts: [String] = []
        switch s.trend {
        case .less: parts.append("showing up less lately")
        case .more: parts.append("showing up more lately")
        case .steady: parts.append("about as often as before")
        case .unknown: parts.append("too early to see a trend")
        }
        if s.fixedAlone > 0 { parts.append("\(s.fixedAlone) fixed on your own") }
        if s.fixedAided > 0 { parts.append("\(s.fixedAided) fixed after hints") }
        if s.open > 0 { parts.append("\(s.open) still open") }
        return parts.joined(separator: " · ")
    }

    private func open(_ f: EngineerFinding) {
        let url = URL(fileURLWithPath: f.folder).appendingPathComponent(f.file)
        if FileManager.default.fileExists(atPath: url.path) { EditorLink.open(url, line: f.line) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: f.folder)) }
    }
}
