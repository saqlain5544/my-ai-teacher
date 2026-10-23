import XCTest
import AppKit
@testable import MyAITeacher

/// A photo's text read on device in the lesson's language (Vision).
final class OCRTests: XCTestCase {
    private func image(_ text: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 900, height: 160))
        img.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 160).fill()
        (text as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black])
        img.unlockFocus()
        return img
    }
    func testTextInAPhotoIsReadInTheLessonsLanguage() async {
        XCTAssertEqual(OCR.languages(for: "ja").first, "ja-JP")
        let ja = await OCR.text(in: image("本日のランチ 800円"), lang: "ja")
        XCTAssertTrue(ja?.contains("ランチ") ?? false, ja ?? "nil")
        let es = await OCR.text(in: image("Menú del día: 12 €"), lang: "es")
        XCTAssertTrue(es?.contains("Menú") ?? false, es ?? "nil")
    }
}
