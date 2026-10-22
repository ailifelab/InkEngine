import XCTest
@testable import InkCore

final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionUsesScriptRegionAndFallback() {
        for identifier in ["zh-Hant", "zh-TW", "zh_HK", "zh-MO"] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [identifier]), .traditionalChinese)
        }
        for identifier in ["zh-Hans", "zh-CN", "zh-SG", "zh-Hans-HK"] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [identifier]), .simplifiedChinese)
        }
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr", "zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja"]), .english)
        XCTAssertEqual(AppLanguage.traditionalChinese.resolved(preferredLanguages: ["en"]), .traditionalChinese)
    }

    func testAllThreeLanguagesTranslateActionsAndPreserveDocumentArguments() {
        XCTAssertEqual(L10n.tr("保存", language: .english), "Save")
        XCTAssertEqual(L10n.tr("保存", language: .traditionalChinese), "儲存")
        XCTAssertEqual(L10n.tr("保存", language: .simplifiedChinese), "保存")
        let document = "原稿 %@ 100% 😀"
        XCTAssertEqual(L10n.tr("《\(document)》已读完", language: .english), "Finished “\(document)”")
        XCTAssertEqual(L10n.tr("《\(document)》已读完", language: .traditionalChinese), "《\(document)》已讀完")
        XCTAssertEqual(L10n.tr("已接收 \(2)/\(5) 个文件，尚未提交。", language: .english), "Received 2/5 files; not yet committed.")
    }

    func testMissingTranslationFallsBackWithoutInterpretingArgumentPercentSigns() {
        let text = "原稿 %@ 100% 😀"
        for language in [AppLanguage.english, .traditionalChinese, .simplifiedChinese] {
            XCTAssertEqual(L10n.tr("Missing key: \(text) 100%", language: language), "Missing key: \(text) 100%")
        }
    }
}
