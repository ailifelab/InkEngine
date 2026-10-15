import XCTest
@testable import InkCore

final class NovelCollectionTests: XCTestCase {
    func testFolderCopiesNaturalChapterOrderAliasAndExtrasPersistWithoutChangingSources() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("原小说"), library = temporary.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("第二卷"), withIntermediateDirectories: true)
        for name in ["第10章.md", "第2章.md", "第1章.md", "章节目录.md", "第二卷/第11章.txt"] {
            try Data("# \(name)\n\n中文正文😀。".utf8).write(to: source.appendingPathComponent(name))
        }
        try Data([0, 255]).write(to: source.appendingPathComponent("封面.png"))
        try Data("不可导入".utf8).write(to: source.appendingPathComponent(".hidden.md"))
        let repo = try LibraryRepository(root: library)
        let receipt = try await repo.importFolder(source, alias: "我的小说")
        XCTAssertEqual(receipt.skippedFiles, 1)
        let books = try await repo.list()
        XCTAssertEqual(receipt.collection.orderedBooks(from: books, readingOnly: true).map(\.fileName), ["第1章.md", "第2章.md", "第10章.md", "第11章.txt"])
        let first = try XCTUnwrap(receipt.collection.orderedBooks(from: books).first)
        XCTAssertEqual(receipt.collection.nextChapter(after: first.id, books: books)?.fileName, "第2章.md")
        var novel = receipt.collection; novel.alias = "修改后的小说名称"; try await repo.saveCollection(novel)
        let reopened = try LibraryRepository(root: library)
        let persisted = try await reopened.collections()
        XCTAssertEqual(persisted.first?.alias, "修改后的小说名称")
        var copy = try await repo.load(first.id); copy.edit(content: "副本修改"); try await repo.save(copy)
        XCTAssertTrue(try String(contentsOf: source.appendingPathComponent("第1章.md"), encoding: .utf8).contains("中文正文"))
        let repeated = try await repo.importFolder(source, alias: "再次导入")
        XCTAssertTrue(repeated.reused); XCTAssertEqual(repeated.collection.id, novel.id)
        let repeatedBooks = try await repo.list(); XCTAssertEqual(repeatedBooks.count, 5)
        let preserved = try await repo.load(first.id); XCTAssertEqual(preserved.content, "副本修改")
        try await repo.setTrashed(receipt.collection.nextChapter(after: first.id, books: books)!.id, trashed: true)
        let afterTrash = try await repo.list()
        XCTAssertEqual(novel.nextChapter(after: first.id, books: afterTrash)?.fileName, "第10章.md")
    }
    func testInvalidTextRollsBackEntireImportAndEmptyFolderDoesNotCreateCollection() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let repo = try LibraryRepository(root: temporary.appendingPathComponent("Library"))
        do { _ = try await repo.importFolder(source, alias: "小说"); XCTFail("Empty folder should fail") } catch { XCTAssertTrue(error is CollectionError) }
        try Data("正文".utf8).write(to: source.appendingPathComponent("1.txt"))
        try Data([0x80, 0x81, 0x82]).write(to: source.appendingPathComponent("2.txt"))
        do { _ = try await repo.importFolder(source, alias: "小说"); XCTFail("Invalid text should fail") } catch { XCTAssertEqual(error as? InkError, .invalidEncoding) }
        let books = try await repo.list(), novels = try await repo.collections()
        XCTAssertTrue(books.isEmpty); XCTAssertTrue(novels.isEmpty)
    }
}
