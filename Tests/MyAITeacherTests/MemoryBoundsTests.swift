import XCTest
@testable import MyAITeacher

/// Constant memory: images live on disk by reference, a lesson's window trims by count and bytes, caches are bounded.
final class MemoryBoundsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func image(_ seed: Int, bytes: Int = 30_000) -> String {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }).base64EncodedString()
    }

    func testImagesLiveOnDiskAndReachRequests() throws {
        let store = Services(global: GlobalStore(), workspace: try Workspace(url: dir)).conversations
        let big = image(1), small = image(2, bytes: 100)
        var m = ChatMessage(role: .user, blocks: [.image(mime: "image/png", base64: big), .image(mime: "image/png", base64: small), .text("look")])
        XCTAssertTrue(m.spill(into: store.blobs))
        XCTAssertNil(m.blocks[0].data); XCTAssertNotNil(m.blocks[0].blob)
        XCTAssertEqual(m.blocks[1].data, small, "small payloads stay inline")
        XCTAssertEqual(m.blocks[0].payload, big, "requests get the same bytes back")
        XCTAssertLessThan(m.approxBytes, 2_000, "the message itself is small now")
        store.upsert(m, conversationID: "L", seq: 0)
        let back = store.messages("L")[0]
        XCTAssertEqual(back.blocks[0].blob, m.blocks[0].blob)
        let sent = AnthropicClient.convert([back], model: "m")
        XCTAssertEqual(sent[0]["content"]?[0]?["source"]?["data"]?.string, big, "the provider request carries the image")
        XCTAssertEqual(BlobSchemeHandler.mime(Data([0x89, 0x50, 0x4E, 0x47, 0, 0])), "image/png")
    }

    func testDeletingALessonRemovesOnlyItsUnsharedBlobs() throws {
        let store = Services(global: GlobalStore(), workspace: try Workspace(url: dir)).conversations
        let shared = image(3), own = image(4)
        var a = ChatMessage(role: .user, blocks: [.image(mime: "image/png", base64: shared), .image(mime: "image/png", base64: own)])
        var b = ChatMessage(role: .user, blocks: [.image(mime: "image/png", base64: shared)])
        _ = a.spill(into: store.blobs); _ = b.spill(into: store.blobs)
        store.upsert(a, conversationID: "A", seq: 0); store.upsert(b, conversationID: "B", seq: 0)
        let files = a.blobRefs.map { BlobStore.file($0, in: store.blobs.dir) }
        // Out of the grace period that protects blobs whose message isn't saved yet.
        for f in files { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: f.path) }
        store.delete("A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path), "still used by lesson B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[1].path), "only lesson A used it")
        // Recently written blobs survive even when unreferenced (their message may be about to be saved).
        let fresh = store.blobs.put(base64: image(5))!
        store.blobs.collect([fresh]) { _ in false }
        XCTAssertNotNil(BlobStore.data(fresh))
    }

    func testWindowTrimKeepsWholeTurnsAndEverythingTheRequestNeeds() {
        // 300 turns of user + assistant; the compaction point after message 500.
        let msgs = (0..<600).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, blocks: [.text("m\($0)")]) }
        let drop = ContextPolicy.windowTrim(msgs, cut: 500, window: 400, maxBytes: .max)
        XCTAssertEqual(drop, 200); XCTAssertEqual(msgs[drop].role, .user, "starts on a turn")
        XCTAssertEqual(ContextPolicy.windowTrim(msgs, cut: 100, window: 400, maxBytes: .max), 100, "never past the compaction point")
        XCTAssertEqual(ContextPolicy.windowTrim(msgs, cut: 0, window: 400, maxBytes: .max), 0, "nothing compacted, nothing goes")
        XCTAssertEqual(ContextPolicy.windowTrim(Array(msgs.prefix(300)), cut: 250, window: 400, maxBytes: .max), 0, "within budget")
        // Bytes: a few huge tool results push the window down even under the count.
        var heavy = Array(msgs.prefix(100))
        for i in stride(from: 1, to: 60, by: 2) { heavy[i].blocks = [.text(String(repeating: "x", count: 100_000))] }
        let d = ContextPolicy.windowTrim(heavy, cut: 80, window: 400, maxBytes: 1_000_000)
        XCTAssertGreaterThan(d, 0)
        XCTAssertLessThanOrEqual(heavy[d...].reduce(0) { $0 + $1.approxBytes }, 1_000_000 + 101_000)
    }

    func testFetchCacheIsBoundedBySize() async {
        let c = FetchCache()
        for i in 0..<20 { await c.put("u\(i)", String(repeating: "a", count: 400_000), nil) }
        var kept = 0
        for i in 0..<20 where await c.get("u\(i)") != nil { kept += 1 }
        XCTAssertLessThanOrEqual(kept * 400_000, FetchCache.maxChars)
        let newest = await c.get("u19"); XCTAssertNotNil(newest, "newest stays")
        await c.clear()
        let gone = await c.get("u19"); XCTAssertNil(gone)
    }

    @MainActor func testSheddingFreesIndexesThatRebuildOnUse() throws {
        let fx = try MemoryFixture(), learner = fx.hub.learner
        _ = learner.add(kind: .preference, content: "Prefers worked examples before theory", subject: nil, importance: 0.7, origin: "learner", source: nil)
        XCTAssertEqual(learner.count(), 1)
        XCTAssertNotNil(MemoryGovernor.footprint())
        MemoryGovernor.shared.shed(critical: false, reason: "test")
        XCTAssertEqual(learner.count(), 1, "the index rebuilds from the database")
        XCTAssertFalse(learner.search("worked examples", limit: 3, minRelevance: 0).isEmpty)
    }
}
