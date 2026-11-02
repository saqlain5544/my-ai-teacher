import Foundation
import CryptoKit

/// What a folder's reviews have learned (`code` action=learn): rules the user gave after a review ("that's fine here",
/// "always check the migration"), shown with every later review brief so the same finding isn't raised twice. Kept in
/// the app's support folder, never in the project.
enum ReviewMemory {
    struct Rule: Codable, Sendable, Equatable { var text: String; var at: Date }
    static let maxRules = 40
    static let maxLength = 400

    static func url(_ root: URL) -> URL {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let h = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AppPaths.support.appendingPathComponent("review-rules/\(h).json")
    }

    static func load(_ root: URL) -> [Rule] {
        guard let d = try? Data(contentsOf: url(root)) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Rule].self, from: d)) ?? []
    }

    private static func save(_ rules: [Rule], _ root: URL) {
        let u = url(root)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(rules) { try? d.write(to: u, options: .atomic) }
    }

    /// Adds `text` (one line, bounded); the same rule twice is kept once, and past the cap the oldest goes.
    @discardableResult
    static func learn(_ text: String, root: URL, now: Date = Date()) -> [Rule] {
        let t = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var rules = load(root)
        guard !t.isEmpty else { return rules }
        let clipped = String(t.prefix(maxLength))
        if !rules.contains(where: { $0.text.lowercased() == clipped.lowercased() }) { rules.append(Rule(text: clipped, at: now)) }
        if rules.count > maxRules { rules.removeFirst(rules.count - maxRules) }
        save(rules, root)
        return rules
    }

    /// Drops the rules containing `fragment` (case-insensitive); returns how many.
    static func forget(_ fragment: String, root: URL) -> Int {
        let f = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return 0 }
        let rules = load(root), kept = rules.filter { !$0.text.lowercased().contains(f) }
        if kept.count != rules.count { save(kept, root) }
        return rules.count - kept.count
    }

    static func render(_ rules: [Rule]) -> String? {
        rules.isEmpty ? nil : rules.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
    }
}
