import Foundation

/// One step's tool results, bounded together. Each tool already bounds its own output (`bash` and `spillIfLarge` spill
/// past 60k characters), but a step can run many tools at once and a sub-agent's report is one result of any size: six
/// parallel 60k outputs were 90k tokens added in one go. The biggest results keep a head and a tail and the rest goes to
/// `.teacher/outputs`, with the path in the result so the agent can read what it needs.
enum StepCap {
    /// Results shorter than this are never cut, however many there are.
    static let floor = 12_000
    static let head = 5_000, tail = 1_500
    static let ceiling = 160_000, minimum = 40_000

    /// Characters one step may add: about a sixth of the context budget (4 characters a token), within bounds.
    static func limit(budget: Int) -> Int { min(ceiling, max(minimum, budget * 4 / 6)) }

    static func apply(_ results: [Block], limit: Int, dir: URL) -> [Block] {
        var out = results
        var total = out.reduce(0) { $0 + ($1.kind == .toolResult ? ($1.text?.count ?? 0) : 0) }
        guard total > limit else { return out }
        while total > limit {
            let big = out.indices.filter { out[$0].kind == .toolResult && (out[$0].text?.count ?? 0) > floor && out[$0].meta?["stepCapped"]?.bool != true }
            guard let i = big.max(by: { (out[$0].text?.count ?? 0) < (out[$1].text?.count ?? 0) }), let text = out[i].text else { break }
            let n = text.count
            var note = "\n\n[… \(n - head - tail) characters left out: this step's tool results were too large together."
            if out[i].meta?["spilled"]?.bool == true {
                note += " The full output is saved at the path given at the end.]\n\n"
            } else {
                let url = dir.appendingPathComponent("\(out[i].name ?? "tool")-step-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).txt")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if (try? Data(text.utf8).write(to: url)) != nil {
                    note += " Full output saved to \(url.path): use `read` with offset/limit or `grep` on it.]\n\n"
                } else { note += "]\n\n" }
            }
            out[i].text = String(text.prefix(head)) + note + String(text.suffix(tail))
            var meta = out[i].meta?.object ?? [:]; meta["stepCapped"] = true; out[i].meta = .object(meta)
            total -= n - (out[i].text?.count ?? 0)
        }
        return out
    }
}
