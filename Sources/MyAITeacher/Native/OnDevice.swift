import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Small jobs for Apple's on-device model (Neural Engine): no network, no API cost, no tokens in the lesson.
/// Everything here is optional; callers keep a local fallback when the model isn't available.
enum OnDevice {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// A 2–6 word lesson title from the learner's first message.
    static func title(for text: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You name tutoring lessons. Reply with a noun phrase of 2 to 6 words naming the topic being learned \
            (e.g. "Rayleigh Scattering", "Zig Compiler Internals"), in the learner's language. No quotes, no greeting, \
            no trailing punctuation, nothing else.
            """)
        let prompt = "Learner's first message:\n\(text.prefix(1200))"
        guard let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 24)) else { return nil }
        let t = r.content.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’*#.:")) ?? ""
        return (2...60).contains(t.count) ? t : nil
        #else
        return nil
        #endif
    }

    /// A sentence translated by the on-device model, for the reading popover when Apple's Translation has no installed
    /// pair: the model covers fewer languages (no Arabic, Russian, Hindi) and can be loose, which the popover says.
    static func translate(_ text: String, from: String, to: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), SystemLanguageModel.default.isAvailable else { return nil }
        let langs = Set(SystemLanguageModel.default.supportedLanguages.compactMap { $0.languageCode?.identifier })
        guard langs.contains(from), langs.contains(to) else { return nil }
        let session = LanguageModelSession(instructions: """
            Translate the learner's sentence from \(Languages.englishName(from)) into natural \(Languages.englishName(to)). \
            Reply with the translation only: no notes, no quotes, no romanisation.
            """)
        guard let r = try? await session.respond(to: String(text.prefix(800)), options: GenerationOptions(temperature: 0, maximumResponseTokens: 200)) else { return nil }
        let t = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
        #else
        return nil
        #endif
    }
}
