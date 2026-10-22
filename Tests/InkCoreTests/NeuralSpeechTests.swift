import XCTest
@testable import InkCore

final class NeuralSpeechTests: XCTestCase {
    func testExplicitPlayAtSavedEOFRestartsLastParagraphWithoutLoopingTheQueue() throws {
        let source = "前面的段落已经读过。\n\n最后一段仍然要能开始朗读。\n\n\n"
        let parsed = TextParser.parse(source, format: .txt)
        let eof = parsed.speechCursor(at: source.utf16.count)
        for renderer in ["system", "zipvoice", "zipvoice-male", "qwen"] {
            XCTAssertNil(parsed.speechChunk(from: eof, skipCode: true, renderer: renderer))
            let start = try XCTUnwrap(parsed.explicitPlaybackCursor(from: eof, skipCode: true, renderer: renderer))
            let chunk = try XCTUnwrap(parsed.speechChunk(from: start, skipCode: true, renderer: renderer))
            XCTAssertEqual(chunk.text, "最后一段仍然要能开始朗读。")
            XCTAssertEqual(chunk.sourceOffset, (source as NSString).range(of: "最后一段").location)
        }
    }

    func testExplicitPlayKeepsAnExistingMidSentenceAnchor() throws {
        let source = "前面的句子。\n\n继续从这里开始，不能重读前面的文字。"
        let parsed = TextParser.parse(source, format: .txt)
        let offset = (source as NSString).range(of: "从这里").location
        let cursor = parsed.speechCursor(at: offset)
        for renderer in ["system", "zipvoice"] {
            let start = try XCTUnwrap(parsed.explicitPlaybackCursor(from: cursor, skipCode: true, renderer: renderer))
            XCTAssertEqual(start, cursor)
            XCTAssertEqual(parsed.speechChunk(from: start, skipCode: true, renderer: renderer)?.sourceOffset, offset)
        }
    }

    func testExplicitPlayAtEOFFindsTextBeforeSkippedCode() throws {
        let source = "**最后一段中文正文。**\n\n```swift\nlet value = 42\n```\n"
        let parsed = TextParser.parse(source, format: .markdown)
        let eof = parsed.speechCursor(at: source.utf16.count)
        let start = try XCTUnwrap(parsed.explicitPlaybackCursor(from: eof, skipCode: true, renderer: "system"))
        XCTAssertEqual(parsed.speechChunk(from: start, skipCode: true, renderer: "system")?.text, "最后一段中文正文。")
        let codeOnly = TextParser.parse("```swift\nlet value = 42\n```", format: .markdown)
        XCTAssertNil(codeOnly.explicitPlaybackCursor(from: codeOnly.speechCursor(at: 1000), skipCode: true, renderer: "system"))
        XCTAssertNil(TextParser.parse("", format: .txt).explicitPlaybackCursor(from: SpeechCursor(segment: 0), skipCode: true, renderer: "system"))
    }

    func testNativeModelCapacityDoesNotLoseTextAcrossChunks() throws {
        let source = "夜风穿过窗棂，书页轻轻翻动。她说：“明天我们去银行，先等雨停。”" + String(repeating: "银行行长正在看账本，", count: 8)
        let parsed = TextParser.parse(source, format: .txt)
        for renderer in ["zipvoice", "zipvoice-male", "qwen"] {
            var cursor = SpeechCursor(segment: 0), chunks: [String] = []
            while let chunk = parsed.speechChunk(from: cursor, skipCode: true, renderer: renderer) {
                XCTAssertNotEqual(chunk.next, cursor)
                XCTAssertLessThanOrEqual((chunk.text as NSString).length, 26)
                chunks.append(chunk.text); cursor = chunk.next
            }
            XCTAssertEqual(chunks.joined(), source)
        }
    }
    func testContinuousSpeechConservesAllParsedTextAndSourcePositions() throws {
        let paragraph = "她说：“折行不是行走。”银行行长回答：速度1.25倍。我们继续读下一句！👨‍👩‍👧‍👦没有遗漏。"
        for format in [TextFormat.txt, .markdown] {
            let source = (format == .markdown ? "# 连续朗读\n\n" : "") + String(repeating: paragraph, count: 120) + "\n最后一行。"
            let parsed = TextParser.parse(source, format: format)
            var cursor = SpeechCursor(segment: 0), pieces: [String] = [], previous = -1
            while let chunk = parsed.continuousSpeechChunk(from: cursor, skipCode: false) {
                XCTAssertNotEqual(chunk.cursor, chunk.next)
                XCTAssertGreaterThanOrEqual(chunk.sourceOffset, previous)
                XCTAssertEqual(chunk.text, (parsed.segments[chunk.cursor.segment].text as NSString).substring(with: chunk.spokenRange))
                previous = chunk.sourceOffset; pieces.append(chunk.text); cursor = chunk.next
                XCTAssertLessThan(pieces.count, 1000)
            }
            XCTAssertEqual(pieces.joined(), parsed.segments.map(\.text).joined())
        }
    }
    func testContinuousContextRetainsThreeSentencesAndClosingQuotes() throws {
        let parsed = TextParser.parse("她说：“我们出发。”他点头。第三句！第四句。", format: .txt)
        let chunk = try XCTUnwrap(parsed.continuousSpeechChunk(from: SpeechCursor(segment: 0), skipCode: true))
        XCTAssertEqual(chunk.text, "她说：“我们出发。”他点头。第三句！")
        XCTAssertEqual(parsed.continuousSpeechChunk(from: chunk.next, skipCode: true)?.text, "第四句。")
    }
    func testMatchaAccelerationRetainsNativeSyllablesAndPiperRates() {
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "matcha", selected: 1.25), 1)
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "matcha", selected: 2), 1)
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "matcha", selected: 0.75), 0.75)
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "piper", selected: 1.25), 1.25)
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "piper", selected: 2), 1.5)
        XCTAssertEqual(SpeechRatePolicy.nativeRate(renderer: "system", selected: 1.25), 1)
    }
    func testProsodyPunctuationPreservesMeaningAndOriginalCursor() throws {
        XCTAssertEqual(SpeechInput.preparing("甲。乙.丙．丁，戊！己？庚：辛；壬、癸（引号）“正文”…——【括号】/|<>"), "甲。乙.丙。丁，戊！己？庚：辛；壬，癸引号正文。括号，")
        XCTAssertEqual(SpeechInput.preparing("速度1.25倍，版本26.0。English sentence. 下一句。"), "速度1.25倍，版本26.0。English sentence. 下一句。")
        XCTAssertEqual(SpeechInput.preparing("她说：“等一等……雨停后——我们再出发。”"), "她说：等一等。雨停后，我们再出发。")
        XCTAssertFalse(SpeechInput.hasSpokenContent(SpeechInput.preparing("……——【】!?")))
        XCTAssertTrue(SpeechInput.hasSpokenContent(SpeechInput.preparing("正文123")))
        for format in [TextFormat.txt, .markdown] {
            let original = format == .txt ? "她说：“折行。第二句，开始！”" : "# 标题\n\n**她说**：“折行。第二句，开始！”"
            let parsed = TextParser.parse(original, format: format)
            let offset = (original as NSString).range(of: "第二句").location
            let cursor = parsed.speechCursor(at: offset)
            let chunk = try XCTUnwrap(parsed.neuralChunk(from: cursor, skipCode: true))
            XCTAssertEqual(chunk.sourceOffset, offset)
            XCTAssertEqual(SpeechInput.preparing(chunk.text), "第二句，开始！")
            XCTAssertEqual(parsed.neuralChunk(from: cursor, skipCode: true), chunk)
            XCTAssertTrue(parsed.segments.map(\.text).joined().contains("折行。"))
        }
    }
    func testShortClauseAndWordsAreNotCutInHalfAtBudgetBoundary() throws {
        let text = "他走到门前，" + String(repeating: "银行行长", count: 30) + "。"
        let parsed = TextParser.parse(text, format: .txt)
        let first = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: 0), skipCode: true, limit: 32))
        XCTAssertEqual(first.text, "他走到门前，")
        let words = TextParser.parse("one two extraordinary final words without punctuation", format: .txt)
        let chunk = try XCTUnwrap(words.neuralChunk(from: SpeechCursor(segment: 0), skipCode: true, limit: 14))
        XCTAssertEqual(chunk.text, "one two ")
        let numbers = TextParser.parse("速度1.25倍。Next sentence. Final sentence.", format: .txt)
        let number = try XCTUnwrap(numbers.neuralChunk(from: SpeechCursor(segment: 0), skipCode: true))
        XCTAssertEqual(number.text, "速度1.25倍。")
        XCTAssertEqual(numbers.neuralChunk(from: number.next, skipCode: true)?.text, "Next sentence.")
    }
    func testSixMillionCharactersMaterializeOnlyRequestedParagraphs() throws {
        let source = String(repeating: "大文本正文，按页加载中文，不会遗漏字符。\n", count: 300000)
        let parsed = TextParser.parse(source, format: .txt)
        XCTAssertEqual(parsed.segments.count, 300000)
        XCTAssertEqual(parsed.segments.materializedSegmentCount, 0)
        let offset = (source as NSString).length / 2
        let index = parsed.segmentIndex(at: offset)
        XCTAssertEqual(parsed.segments.materializedSegmentCount, 0, "Seeking must use ranges without rendering the whole novel")
        let chunk = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: index), skipCode: true))
        XCTAssertFalse(chunk.text.isEmpty)
        XCTAssertLessThanOrEqual(parsed.segments.materializedSegmentCount, 1)
        for i in 0..<1000 { _ = parsed.segments[i].text }
        XCTAssertLessThanOrEqual(parsed.segments.materializedSegmentCount, 64)
    }
    func testSemicolonAndColonKeepSentenceProsodyAndClosingQuote() throws {
        let parsed = TextParser.parse("她说：“先等一等；雨停后，我们再出发。”他点了点头。", format: .txt)
        let first = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: 0), skipCode: true))
        XCTAssertEqual(first.text, "她说：“先等一等；雨停后，我们再出发。”")
        XCTAssertEqual(parsed.neuralChunk(from: first.next, skipCode: true)?.text, "他点了点头。")
    }
    func testParserKeepsFamilyEmojiWholeAtItsOwnChunkBoundary() {
        let source = String(repeating: "👨‍👩‍👧‍👦", count: 180)
        let parsed = TextParser.parse(source, format: .txt)
        XCTAssertEqual(parsed.segments.map(\.text).joined(), source)
        for segment in parsed.segments {
            XCTAssertEqual(segment.text.count * 11, segment.text.utf16.count)
            XCTAssertLessThanOrEqual(segment.text.utf16.count, 800)
        }
    }
    func testLongParagraphHasNoOmissionAndDoesNotSplitEmojiOrSourceMapping() throws {
        let source = String(repeating: "**窗外**下雨了👨‍👩‍👧‍👦。她说：“明天再出发。”银行行长在长江边等待。", count: 90)
        let parsed = TextParser.parse(source, format: .markdown)
        var cursor = SpeechCursor(segment: 0), joined = "", count = 0
        while let chunk = parsed.neuralChunk(from: cursor, skipCode: true) {
            XCTAssertLessThanOrEqual(chunk.text.utf16.count, 180)
            XCTAssertFalse(chunk.text.contains("�"))
            let segment = parsed.segments[chunk.cursor.segment]
            XCTAssertEqual((segment.text as NSString).substring(with: chunk.spokenRange), chunk.text)
            let mapped = try XCTUnwrap(segment.sourceRange(forSpoken: NSRange(location: chunk.cursor.offset, length: 1)))
            XCTAssertEqual(chunk.sourceOffset, mapped.location)
            joined += chunk.text; cursor = chunk.next; count += 1
        }
        XCTAssertGreaterThan(count, 10)
        XCTAssertEqual(joined, parsed.segments.map(\.text).joined())
    }
    func testSeekSkipsCodeAndUsesSourceOffsetAfterMarkdownDeletion() throws {
        let source = "# 标题\n\n```swift\nlet hidden = 1\n```\n\n[第二段](https://example.com)。继续中文朗读。"
        let parsed = TextParser.parse(source, format: .markdown)
        let code = try XCTUnwrap(parsed.segments.firstIndex(where: \.isCode))
        let paragraph = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: code), skipCode: true))
        XCTAssertEqual(paragraph.text, "第二段。")
        XCTAssertEqual(parsed.neuralChunk(from: paragraph.next, skipCode: true)?.text, "继续中文朗读。")
        XCTAssertTrue(try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: code), skipCode: false)).text.contains("hidden"))
        let offset = (source as NSString).range(of: "继续").location
        let chunk = try XCTUnwrap(parsed.neuralChunk(from: parsed.speechCursor(at: offset), skipCode: true))
        XCTAssertEqual(chunk.text, "继续中文朗读。")
        XCTAssertEqual(chunk.sourceOffset, offset)
    }
    func testParagraphNavigationSkipsEveryRenderingSliceOfALongParagraph() throws {
        let source = "上一段。\n" + String(repeating: "长段落中的连续句子。", count: 200) + "\n下一段。"
        let parsed = TextParser.parse(source, format: .txt)
        XCTAssertGreaterThan(parsed.segments.count, 4)
        let middle = 2
        let next = try XCTUnwrap(parsed.adjacentParagraph(from: middle, forward: true))
        XCTAssertEqual(parsed.segments[next].text, "下一段。")
        XCTAssertEqual(parsed.adjacentParagraph(from: middle, forward: false), 0)
        XCTAssertEqual(parsed.adjacentParagraph(from: next, forward: false), 1)
        XCTAssertNil(parsed.adjacentParagraph(from: next, forward: true))
    }
    func testLookaheadPauseAndStaleSeekCannotAdvanceRenderedPosition() throws {
        let parsed = TextParser.parse("第一段。\n第二段。\n第三段。", format: .txt)
        var ledger = SpeechPlaybackLedger()
        let first = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: 0), skipCode: true))
        let second = try XCTUnwrap(parsed.neuralChunk(from: first.next, skipCode: true))
        let old = ledger.generation
        XCTAssertTrue(ledger.append(first, frames: 24000, generation: old))
        XCTAssertTrue(ledger.append(second, frames: 48000, generation: old))
        XCTAssertEqual(ledger.current?.chunk.cursor, first.cursor)
        ledger.render(to: 12500, generation: old); ledger.pause()
        ledger.render(to: 45000, generation: old)
        XCTAssertEqual(ledger.renderedFrames, 12500)
        ledger.resume(); ledger.render(to: 25000, generation: old)
        XCTAssertEqual(ledger.current?.chunk.cursor, second.cursor)
        ledger.reset()
        XCTAssertFalse(ledger.append(first, frames: 24000, generation: old))
        ledger.render(to: 72000, generation: old)
        XCTAssertEqual(ledger.renderedFrames, 0)
        XCTAssertTrue(ledger.append(second, frames: 48000, generation: ledger.generation))
        XCTAssertEqual(ledger.current?.chunk.cursor, second.cursor)
    }
}
