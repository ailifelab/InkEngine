import XCTest
@testable import InkCore

final class MarkdownTableTests: XCTestCase {
    func testTableCellsAlignmentsAndOriginalOffsets() throws {
        let source = "# 目录\n\n| 章节 | 内容 | 字数 |\n| :--- | :---: | ---: |\n| 第一章 | **中文😀** [山路](https://example.org) | 2048 |\n"
        let parsed = TextParser.parse(source, format: .markdown)
        XCTAssertEqual(parsed.segments.count, 3)
        XCTAssertEqual(parsed.segments.materializedSegmentCount, 0)
        let header = try XCTUnwrap(parsed.segments[1].table), row = try XCTUnwrap(parsed.segments[2].table)
        XCTAssertTrue(header.isHeader); XCTAssertFalse(row.isHeader)
        XCTAssertEqual(header.alignments, [.left, .center, .right])
        XCTAssertEqual(row.cells.map(\.text), ["第一章", "中文😀 山路", "2048"])
        for cell in row.cells {
            XCTAssertEqual(cell.text.utf16.count, cell.sourceOffsets.count)
            let units = Array(source.utf16)
            for (index, value) in cell.text.utf16.enumerated() { XCTAssertEqual(units[cell.sourceOffsets[index]], value) }
        }
        let speech = try XCTUnwrap(parsed.neuralChunk(from: SpeechCursor(segment: 2), skipCode: true))
        XCTAssertFalse(speech.text.contains("|")); XCTAssertFalse(speech.text.contains("---"))
        let cellOffset = row.cells[1].sourceOffsets.first!
        XCTAssertEqual(parsed.speechCursor(at: cellOffset).offset, "第一章\t".utf16.count)
    }
    func testEscapedPipesCodePipesAndNonTableText() throws {
        let source = "名称 | 值\n--- | ---\n甲\\|乙 | `x|y`\n\n普通 | 文本\n\n```\n| 代码 | 保留 |\n| --- | --- |\n```\n"
        let parsed = TextParser.parse(source, format: .markdown)
        XCTAssertEqual(try XCTUnwrap(parsed.segments[1].table).cells.map(\.text), ["甲|乙", "x|y"])
        XCTAssertNil(parsed.segments[2].table)
        XCTAssertTrue(parsed.segments[3].isCode); XCTAssertNil(parsed.segments[3].table)
        XCTAssertTrue(TextParser.parse(source, format: .txt).segments.allSatisfy { $0.table == nil })
    }
    func testLargeTableRemainsLazyAndHasNoSeparatorSpeech() {
        let source = "| 章 | 内容 |\n| --- | --- |\n" + (1...1000).map { "| \($0) | 中文正文😀 |\n" }.joined()
        let parsed = TextParser.parse(source, format: .markdown)
        XCTAssertEqual(parsed.segments.count, 1001)
        XCTAssertEqual(parsed.segments.materializedSegmentCount, 0)
        for index in 0..<parsed.segments.count { XCTAssertNotNil(parsed.segments[index].table) }
        XCTAssertEqual(parsed.segments.materializedSegmentCount, 64)
    }
}
