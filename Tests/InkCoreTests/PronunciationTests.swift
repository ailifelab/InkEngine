import XCTest
@testable import InkCore

final class PronunciationTests: XCTestCase {
    func testCommonPolyphonicPhrasesAndOrdinaryWalking() {
        let dictionary = PronunciationDictionary()
        XCTAssertGreaterThan(dictionary.rules.count, 300)
        XCTAssertEqual(dictionary.applying(to: "折行、行号、银行行长。行走、行为、我们同行。"), "折航、航号、银航航掌。行走、行为、我们同行。")
        XCTAssertEqual(dictionary.applying(to: "重新称重量，重庆音乐，成长为长者。"), "崇新称众量，崇庆音月，成掌为掌者。")
        XCTAssertEqual(dictionary.applying(to: "干脆出差去西藏，收藏宝藏。"), "甘脆出拆去西葬，收仓宝葬。")
        XCTAssertEqual(dictionary.applying(to: "大家大都喜欢单行侠。公差尺寸，重读音节。"), "大家大都喜欢单行侠。公差尺寸，重读音节。")
    }
    func testLongestPhraseCustomOverrideNeverCascadesOrChangesOriginal() {
        let source = "音乐😀长乐。音乐" // 长乐既有地名也有不同人名，不内置单一读音。
        let dictionary = PronunciationDictionary(custom: [.init(phrase: "音乐", spoken: "乐音"), .init(phrase: "乐音", spoken: "不要二次替换"), .init(phrase: "", spoken: "无效")])
        XCTAssertEqual(dictionary.applying(to: source), "乐音😀长乐。乐音")
        XCTAssertEqual(source, "音乐😀长乐。音乐")
        XCTAssertNotEqual(dictionary.cacheKey, PronunciationDictionary().cacheKey)
        XCTAssertEqual(PronunciationDictionary().cacheKey, PronunciationDictionary().cacheKey)
        XCTAssertEqual(PronunciationDictionary().applying(to: "落下病根，丢三落四，一行文字。"), "涝下病根，丢三辣四，一航文字。")
    }
}
