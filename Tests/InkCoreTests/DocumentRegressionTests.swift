import XCTest
@testable import InkCore

final class DocumentRegressionTests: XCTestCase {
    func testSavedEndOfFilePositionReturnsLastReadableParagraph() {
        let source = "首段😀。\n\n末段正文。\n\n\n"
        let parsed = TextParser.parse(source, format: .txt)
        XCTAssertEqual(parsed.readingStart(at: source.utf16.count), parsed.segments.last?.sourceRange.location)
        XCTAssertEqual(parsed.readingStart(at: source.utf16.count - 1), parsed.segments.last?.sourceRange.location)
        XCTAssertEqual(parsed.readingStart(at: 0), 0)
        let markdown = TextParser.parse("**末段**\n\n```\n", format: .markdown)
        XCTAssertEqual(markdown.readingStart(at: 1000), 0)
        XCTAssertTrue(TextParser.parse("\n\n", format: .txt).segments.isEmpty)
    }
    func testNewBlankDocumentStartsReadingAtBeginningAfterTyping() {
        var book = Manuscript(title: "新建", format: .txt)
        book.edit(content: "新建后的第一段。\n\n第二段。")
        XCTAssertEqual(book.cursor, 0)
    }
    func testLegacyMigrationPreservesIDRevisionPositionAndContent() throws {
        let original = Manuscript(title: "旧文稿", content: "旧正文😀", cursor: 3)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for key in ["fileName", "highlightOverride", "bookmarks"] { json.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(Manuscript.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.id, original.id); XCTAssertEqual(migrated.revision, original.revision)
        XCTAssertEqual(migrated.content, original.content); XCTAssertEqual(migrated.cursor, 3)
        XCTAssertEqual(migrated.fileName, "旧文稿.md"); XCTAssertTrue(migrated.bookmarks.isEmpty)
        _ = try migrated.validated()
    }
    func testElevenImportsAndIndependentFilenameHighlightRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Formats-" + UUID().uuidString)
        let repo = try LibraryRepository(root: root)
        XCTAssertEqual(TextFormat.allCases.count, 11)
        for format in TextFormat.allCases {
            let name = "文稿." + format.fileExtension
            let source = root.appendingPathComponent(name)
            try Data("中文😀 raw body 42".utf8).write(to: source)
            var book = try await repo.importFile(source).document
            XCTAssertEqual(book.fileName, name); XCTAssertEqual(book.highlightFormat, format)
            try book.configure(fileName: "自定义.backup.custom", highlightOverride: .sql)
            XCTAssertEqual(book.highlightFormat, .sql); XCTAssertEqual(book.fileName, "自定义.backup.custom")
            try book.configure(fileName: "修改名.json", highlightOverride: book.highlightOverride)
            XCTAssertEqual(book.highlightFormat, .sql); XCTAssertEqual(book.format, .json)
            try await repo.save(book)
            let loaded = try await repo.load(book.id)
            XCTAssertEqual(loaded.fileName, "修改名.json"); XCTAssertEqual(loaded.highlightOverride, .sql)
            XCTAssertEqual(loaded.content, "中文😀 raw body 42")
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), loaded.content)
        }
    }
    func testBookmarksRelocatePersistRenameDeleteAndRemainIndependentOfProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Bookmarks-" + UUID().uuidString)
        let repo = try LibraryRepository(root: root)
        var book = Manuscript(title: "甲", format: .txt, content: "开头😀\n目标段落\n结尾段落", cursor: 5)
        let target = (book.content as NSString).range(of: "目标段落").location
        book.bookmarks = [ReadingBookmark(name: "目标", offset: target, content: book.content), ReadingBookmark(name: "结尾", offset: 11, content: book.content)]
        book.edit(content: "新增中文😀\n" + book.content)
        XCTAssertEqual(book.bookmarks[0].offset, target + "新增中文😀\n".utf16.count)
        XCTAssertEqual((book.content as NSString).substring(from: book.bookmarks[0].offset).prefix(4), "目标段落")
        book.bookmarks[0].name = "改名"; book.bookmarks[1].deletedAt = Date(); book.advanceRevision()
        try await repo.save(book)
        for cycle in 1...3 {
            let progress = min(cycle * 3, book.content.utf16.count)
            try await repo.savePosition(id: book.id, revision: book.revision, cursor: progress)
            let freshRepository = try LibraryRepository(root: root)
            let resumed = try await freshRepository.load(book.id)
            XCTAssertEqual(resumed.cursor, progress); XCTAssertEqual(resumed.bookmarks, book.bookmarks)
        }
        let other = Manuscript(title: "乙", content: "别的文稿", cursor: 2); try await repo.save(other)
        let savedOther = try await repo.load(other.id); XCTAssertEqual(savedOther.cursor, 2); XCTAssertTrue(savedOther.bookmarks.isEmpty)
        book.edit(content: book.content.replacingOccurrences(of: "目标段落", with: "替换"))
        XCTAssertLessThanOrEqual(book.bookmarks[0].offset, book.content.utf16.count); XCTAssertEqual(book.bookmarks.count, 2)
    }
    func testConcurrentMetadataAndBookmarksProduceRecoverableConflict() async throws {
        let repo = try LibraryRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("MetaConflict-" + UUID().uuidString))
        let base = Manuscript(title: "原稿", content: "相同正文")
        var local = base, remote = base
        local.bookmarks.append(ReadingBookmark(name: "Mac书签", offset: 1, content: base.content)); local.advanceRevision()
        remote.bookmarks.append(ReadingBookmark(name: "手机书签", offset: 2, content: base.content)); remote.advanceRevision()
        try remote.configure(fileName: "另一名称.custom", highlightOverride: .sql)
        try await repo.save(local)
        let (copy, decision) = try await repo.receive(remote, checksum: remote.checksum)
        XCTAssertEqual(decision, .conflict)
        let preserved = try await repo.load(base.id)
        XCTAssertEqual(preserved.bookmarks.first?.name, "Mac书签")
        XCTAssertEqual(copy.bookmarks.first?.name, "手机书签"); XCTAssertEqual(copy.fileName, "另一名称.custom")
    }
    func testHighlightAllFormatsBoundsAndPlainText() {
        let samples: [TextFormat: String] = [.sql: "SELECT 42 -- comment", .markdown: "# 标题\n**bold**", .csv: "name,42", .tsv: "name\t42", .java: "public class A { int n = 42; }", .javascript: "const n = 42;", .yaml: "name: value # comment", .json: "{\"n\":42}", .xml: "<a>hello</a>", .html: "<body>hello</body>", .txt: "文字"]
        for format in TextFormat.allCases {
            let text = samples[format]!
            let tokens = SyntaxHighlighter.tokens(in: text, format: format, baseOffset: 500)
            if format == .txt { XCTAssertTrue(tokens.isEmpty) } else { XCTAssertFalse(tokens.isEmpty, format.label) }
            for token in tokens { XCTAssertGreaterThanOrEqual(token.range.location, 500); XCTAssertLessThanOrEqual(NSMaxRange(token.range), 500 + text.utf16.count) }
        }
    }
    func testFilenameExactExtensionValidation() throws {
        var book = Manuscript(title: "原稿")
        for name in ["文件", "文件.abc", "a.custom.json", "中文.sql"] { try book.configure(fileName: name, highlightOverride: .java); XCTAssertEqual(book.fileName, name) }
        for name in ["../a", "a/b.txt", "a:b", "", ".."] { XCTAssertThrowsError(try book.configure(fileName: name, highlightOverride: nil)) }
    }
}
