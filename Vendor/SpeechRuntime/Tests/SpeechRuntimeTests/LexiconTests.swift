import XCTest
@testable import SpeechRuntime
final class LexiconTests: XCTestCase {
    func testResamplingRetainsQuietSpeechAndTail() throws {
        let samples: [Float] = (0..<16000).map { i in 0.002 * Float(sin(Double(i) * 2 * .pi * 700 / 16000)) }
        let audio = try SpeechAudio(samples: samples, sampleRate: 16000).resampled()
        XCTAssertEqual(audio.sampleRate, 24000)
        XCTAssertEqual(Double(audio.samples.count) / 24000, 1, accuracy: 0.004)
        XCTAssertGreaterThan(audio.samples.suffix(240).map { abs($0) }.max() ?? 0, 0.001)
        XCTAssertGreaterThan(audio.samples[8000..<16000].map { abs($0) }.max() ?? 0, 0.001)
    }
    func testKnownChineseAndEnglishNumbersKeepWholeUtterance() throws {
        let coverage = ChineseLexiconCoverage(lexicon: "我 wo3\n银 yin2\n行 hang2\n速 su4\n度 du4\n")
        XCTAssertNoThrow(try coverage.validate("我银行，速度1.25，English sentence."))
    }
    func testChineseOnlyFrontendDoesNotSilentlyConsumeEnglish() {
        let coverage = ChineseLexiconCoverage(lexicon: "我 wo3\n")
        XCTAssertThrowsError(try coverage.validate("我 hello", chineseOnly: true))
        XCTAssertNoThrow(try coverage.validate("我123。", chineseOnly: true))
    }
    func testUnknownCommonOrExtendedChineseTriggersFallbackRatherThanSilentDrop() {
        let coverage = ChineseLexiconCoverage(lexicon: "我 wo3\n")
        XCTAssertThrowsError(try coverage.validate("我龘"))
        XCTAssertThrowsError(try coverage.validate("我𠮷"))
    }
}
