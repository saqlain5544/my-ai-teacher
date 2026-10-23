import XCTest
@testable import MyAITeacher

/// The learner's own texts: a web page becomes plain text for the reading component.
final class OwnTextTests: XCTestCase {
    func testAPageBecomesPlainTextToRead() {
        let md = "# El teletrabajo\n\n![foto](https://x/y.jpg)\n\n  Cada vez **más**^[1]^ empresas [permiten](https://a.b) trabajar desde casa.\n\n| a | b |\n|---|---|\n\n- Ventajas: menos viajes\n\n> Una cita.\n\n```\ncode\n```"
        let t = LanguageWork.plainText(md)
        XCTAssertTrue(t.hasPrefix("El teletrabajo"), t)
        XCTAssertTrue(t.contains("Cada vez más empresas permiten trabajar desde casa."), t)
        XCTAssertTrue(t.contains("Ventajas: menos viajes") && t.contains("Una cita."), t)
        XCTAssertFalse(t.contains("http") || t.contains("**") || t.contains("```") || t.contains("|---"), t)
        XCTAssertTrue(t.contains("\n\n"), "paragraphs stay apart")
    }
}
