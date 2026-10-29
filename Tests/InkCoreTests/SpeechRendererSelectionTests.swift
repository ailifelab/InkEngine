import XCTest
@testable import InkCore

final class SpeechRendererSelectionTests: XCTestCase {
    func testRetiredQwenMigratesToZipVoiceOrSystemWhenModelsAreMissing() {
        XCTAssertEqual(SpeechRendererSelection.restored("qwen", zipVoiceReady: true, maleReady: true), "zipvoice")
        XCTAssertEqual(SpeechRendererSelection.restored("qwen", zipVoiceReady: false, maleReady: false), "system")
    }
    func testExistingVoicesAndUnknownPreferencesRemainSafe() {
        XCTAssertEqual(SpeechRendererSelection.restored("zipvoice-male", zipVoiceReady: true, maleReady: true), "zipvoice-male")
        XCTAssertEqual(SpeechRendererSelection.restored("zipvoice-male", zipVoiceReady: true, maleReady: false), "zipvoice")
        XCTAssertEqual(SpeechRendererSelection.restored("zipvoice", zipVoiceReady: false, maleReady: false), "system")
        for saved in [nil, "system", "unknown"] as [String?] {
            XCTAssertEqual(SpeechRendererSelection.restored(saved, zipVoiceReady: true, maleReady: true), "system")
        }
    }
}
