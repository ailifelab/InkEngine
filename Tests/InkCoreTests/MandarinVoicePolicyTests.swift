import XCTest
@testable import InkCore

final class MandarinVoicePolicyTests: XCTestCase {
    func testEnglishPreferenceCannotReplaceMissingMandarin() {
        let english = SpeechVoiceOption(id: "english", language: "en-US", quality: 3)
        let cantonese = SpeechVoiceOption(id: "cantonese", language: "zh-HK", quality: 3)
        XCTAssertNil(MandarinVoicePolicy.choose(from: [english, cantonese], savedID: "english"))
        let basic = SpeechVoiceOption(id: "basic", language: "zh-CN", quality: 1)
        let enhanced = SpeechVoiceOption(id: "enhanced", language: "zh-CN", quality: 2)
        XCTAssertEqual(MandarinVoicePolicy.choose(from: [english, basic, enhanced], savedID: "english"), "enhanced")
        XCTAssertEqual(MandarinVoicePolicy.choose(from: [basic, enhanced], savedID: "basic"), "basic")
    }
    func testRegionalMandarinAndInvalidStoredID() {
        XCTAssertTrue(MandarinVoicePolicy.supports("zh_Hans_CN"))
        XCTAssertTrue(MandarinVoicePolicy.supports("zh-TW"))
        XCTAssertFalse(MandarinVoicePolicy.supports("yue-CN"))
        let taiwan = SpeechVoiceOption(id: "taiwan", language: "zh-TW", quality: 2)
        XCTAssertEqual(MandarinVoicePolicy.choose(from: [taiwan], savedID: "removed"), "taiwan")
        let regular = SpeechVoiceOption(id: "z-tingting", language: "zh-CN", quality: 1, name: "Tingting")
        let novelty = SpeechVoiceOption(id: "a-eddy", language: "zh-CN", quality: 1, name: "Eddy")
        XCTAssertEqual(MandarinVoicePolicy.choose(from: [novelty, regular], savedID: ""), regular.id)
    }
}
