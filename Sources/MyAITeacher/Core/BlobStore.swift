import Foundation
import CryptoKit
import WebKit

/// Large payloads (images: attachments, screenshots, fetched pictures) live on disk, content-addressed, next to the
/// database that owns the lesson (`<db dir>/blobs/ab/<sha256>`); messages carry only the reference. A lesson's memory
/// then doesn't grow with its images: a payload is read back only when a request sends it, and the transcript loads it
/// through `teacher-blob://` instead of holding base64 in the DOM.
/// One store per database: deleting a lesson removes exactly the blobs nothing else in that database uses (the
/// `blob_refs` table), and a moved folder takes its blobs with it.
final class BlobStore: @unchecked Sendable {
    /// Payloads at least this long (base64 characters) go to disk; smaller ones aren't worth a file.
    static let spillChars = 16_384
    /// A blob written or reused this recently is never collected: its message may not have recorded the reference yet.
    static let graceSeconds: TimeInterval = 600
    let dir: URL
    private static let lock = NSLock()
    private static var roots: [URL] = []

    init(dir: URL) {
        self.dir = dir
        Self.lock.withLock { if !Self.roots.contains(dir) { Self.roots.append(dir) } }
    }

    /// The store beside a database file (a temporary one for an in-memory database).
    convenience init(databasePath path: String) {
        let base = path.isEmpty || path == ":memory:"
            ? FileManager.default.temporaryDirectory.appendingPathComponent("myaiteacher-blobs-\(ProcessInfo.processInfo.processIdentifier)")
            : URL(fileURLWithPath: path).deletingLastPathComponent()
        self.init(dir: base.appendingPathComponent("blobs", isDirectory: true))
    }

    /// Stores a base64 payload; returns its reference, or nil when it can't be decoded or written (the caller keeps it inline).
    func put(base64 payload: String) -> String? {
        guard let bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        let ref = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let url = Self.file(ref, in: dir)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // reused: restart its grace period
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? bytes.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return ref
    }

    /// Reads a reference back from whichever open database's store holds it.
    static func data(_ ref: String) -> Data? {
        guard valid(ref) else { return nil }
        for root in lock.withLock({ roots }) { if let d = try? Data(contentsOf: file(ref, in: root)) { return d } }
        return nil
    }
    /// The base64 form requests send. Every step resends the recent turns' images, which read the file and encoded it
    /// again each time; the encoded strings are kept (content-addressed, so never stale) up to `cacheBytes`, oldest out.
    static func base64(_ ref: String) -> String? {
        if let hit = encoded.mutate({ $0.get(ref) }) { return hit }
        guard let s = data(ref)?.base64EncodedString() else { return nil }
        encoded.mutate { $0.put(ref, s) }
        return s
    }
    static let cacheBytes = 32 << 20
    private static let encoded = Locked(LRU(limit: cacheBytes))
    /// Memory pressure (MemoryGovernor): the encoded images go; they are rebuilt from disk on the next request.
    static func releaseMemory() { encoded.mutate { $0 = LRU(limit: cacheBytes) } }

    /// Strings by key, bounded by total UTF-8 bytes; least recently used out first.
    struct LRU {
        let limit: Int
        private(set) var bytes = 0
        private var values: [String: String] = [:]
        private var order: [String] = []   // least recent first; short (a few dozen images fit the limit)
        init(limit: Int) { self.limit = limit }
        mutating func get(_ k: String) -> String? {
            guard let v = values[k] else { return nil }
            order.removeAll { $0 == k }; order.append(k)
            return v
        }
        mutating func put(_ k: String, _ v: String) {
            let n = v.utf8.count
            guard n <= limit else { return }   // bigger than the whole cache: not worth evicting everything for
            if let old = values.updateValue(v, forKey: k) { bytes -= old.utf8.count; order.removeAll { $0 == k } }
            order.append(k); bytes += n
            while bytes > limit, let first = order.first {
                order.removeFirst()
                bytes -= values.removeValue(forKey: first)?.utf8.count ?? 0
            }
        }
        var count: Int { values.count }
    }

    /// Deletes the given blobs unless `inUse` says a message still needs them or they're within the grace period.
    func collect(_ refs: some Sequence<String>, inUse: (String) -> Bool) {
        let fm = FileManager.default
        for ref in refs where Self.valid(ref) && !inUse(ref) {
            let url = Self.file(ref, in: dir)
            guard let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(m) > Self.graceSeconds else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Every blob in this store (for the startup sweep of orphans).
    func all() -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).flatMap { sub in
            ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? []).filter(Self.valid)
        }
    }

    static func file(_ ref: String, in root: URL) -> URL {
        root.appendingPathComponent(String(ref.prefix(2)), isDirectory: true).appendingPathComponent(ref)
    }
    static func valid(_ ref: String) -> Bool {
        ref.utf8.count == 64 && ref.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Serves `teacher-blob://img/<ref>` to the transcript from the blob stores.
final class BlobSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "teacher-blob"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let data = BlobStore.data(url.lastPathComponent) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": Self.mime(data), "Cache-Control": "max-age=31536000, immutable"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// The image type from its first bytes (content-addressed files carry no extension).
    static func mime(_ d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if b.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        return "application/octet-stream"
    }
}
