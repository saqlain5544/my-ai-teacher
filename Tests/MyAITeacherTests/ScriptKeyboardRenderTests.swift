import XCTest
import SwiftUI
@testable import MyAITeacher

/// The composer's keyboard renders for each script (and, with KEYBOARD_SHOTS=dir, writes PNGs to look at).
final class ScriptKeyboardRenderTests: XCTestCase {
    @MainActor func testTheComposerKeyboardRendersForEachScript() throws {
        for code in ["ja", "ar", "ko", "zh", "hi", "ru", "es"] {
            let layout = try XCTUnwrap(KeyboardLayouts.layout(for: code), code)
            let view = ScriptKeyboardView(layout: layout, sessionID: "test", words: [("電車", "でんしゃ")], draft: "でんしゃ") {}
                .frame(width: 860).padding().background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view)
            r.scale = 2
            let img = try XCTUnwrap(r.nsImage, code)
            XCTAssertGreaterThan(img.size.height, 80, "\(code): a keyboard, not an empty view")
            if let dir = ProcessInfo.processInfo.environment["KEYBOARD_SHOTS"], let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("composer-kbd-\(code).png"))
            }
        }
    }
}
