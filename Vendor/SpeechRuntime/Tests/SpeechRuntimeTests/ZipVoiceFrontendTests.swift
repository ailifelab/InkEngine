import XCTest
@testable import SpeechRuntime

final class ZipVoiceFrontendTests: XCTestCase {
    func testUsesPhrasePronunciationAndPreservesPunctuation() throws {
        let frontend = try ZipVoiceFrontend(tokens: "_\t0\nx\t1\ny\t2\n,\t3\n.\t4\n", lexicon: "银 x\n行 x\n银行 x y\n")
        XCTAssertEqual(try frontend.encode("“银行，银行。”"), [1, 2, 3, 1, 2, 4])
    }
    func testDigitsLeadingZeroAndDecimalRemainAudible() throws {
        let frontend = try ZipVoiceFrontend(tokens: "_\t0\nx\t1\ny\t2\n.\t3\n", lexicon: "零 x\n一 y\n二 x\n三 y\n四 x\n五 y\n六 x\n七 y\n八 x\n九 y\n点 x y\n")
        XCTAssertEqual(try frontend.encode("01.25。"), [1, 2, 1, 2, 1, 2, 3])
    }
    func testUnknownCharacterCannotDisappearFromNonemptyRequest() throws {
        let frontend = try ZipVoiceFrontend(tokens: "_\t0\nx\t1\n", lexicon: "银 x\n")
        XCTAssertThrowsError(try frontend.encode("银𠮷"))
        XCTAssertThrowsError(try frontend.encode("银2026"))
    }
}
