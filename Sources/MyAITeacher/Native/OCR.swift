import Foundation
import AppKit
import Vision

/// Text in a photo the learner attaches (a page, a menu, a sign), read on device by Vision in the lesson's language:
/// it goes with the image as text, so the teacher reads the words exactly (and a model without vision still can).
enum OCR {
    /// Vision's language codes for a lesson language, best first, with English for mixed text.
    static func languages(for lang: String?) -> [String] {
        let wanted: [String: [String]] = ["ja": ["ja-JP"], "zh": ["zh-Hans", "zh-Hant"], "ko": ["ko-KR"], "ar": ["ar-SA"], "ru": ["ru-RU"], "uk": ["uk-UA"],
                                          "es": ["es-ES"], "fr": ["fr-FR"], "de": ["de-DE"], "it": ["it-IT"], "pt": ["pt-BR"], "th": ["th-TH"], "vi": ["vi-VT"]]
        let supported = Set((try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [])
        return ((lang.flatMap { wanted[$0] } ?? []) + ["en-US"]).filter { supported.contains($0) }
    }

    static func text(in image: NSImage, lang: String?) async -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let langs = languages(for: lang)
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                if !langs.isEmpty { req.recognitionLanguages = langs }
                guard (try? VNImageRequestHandler(cgImage: cg).perform([req])) != nil else { c.resume(returning: nil); return }
                let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                c.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
        }
    }
}
