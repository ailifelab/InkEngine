import XCTest
@testable import InkCore

final class LocalDocumentManagementTests: XCTestCase {
    private func environment() throws -> (URL, LibraryRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        return (root, try LibraryRepository(root: root.appendingPathComponent("Library"), documentsDirectory: documents), documents)
    }
    private func write(_ content: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file, options: .atomic)
    }
    func testComputerFilesBecomeNestedCollectionsAndRefreshDoesNotRewriteNovel() async throws {
        let (_, repo, documents) = try environment()
        for path in ["小说/第1章.txt", "小说/第10章.txt", "小说/第2章.txt", "小说/卷一/第3章.md", "小说/卷一续/第4章.txt"] { try write("正文😀。", to: documents.appendingPathComponent(path)) }
        try write("独立正文。", to: documents.appendingPathComponent("独立.txt"))
        try await repo.reconcileDocumentsDirectory()
        let folders = try await repo.collections(), books = try await repo.list(), folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folders.count, 1); XCTAssertEqual(folder.alias, "小说"); XCTAssertEqual(books.count, 6)
        let root = folder.directoryContents(books: books)
        XCTAssertEqual(root.files.map(\.fileName), ["第1章.txt", "第2章.txt", "第10章.txt"])
        XCTAssertEqual(root.directories, ["卷一", "卷一续"])
        XCTAssertEqual(folder.directoryContents(at: "卷一", books: books).files.map(\.fileName), ["第3章.md"])
        let before = try await repo.load(books[0].id), file = documents.appendingPathComponent("小说/第1章.txt")
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let unchanged = try await repo.reconcileDocumentsDirectory(); XCTAssertTrue(unchanged.isEmpty)
        let after = try await repo.load(before.id)
        XCTAssertEqual(before.revision, after.revision)
        XCTAssertEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        var history = try await repo.recentHistory(); history.remove(folder.id); try await repo.saveHistory(history)
        try await repo.reconcileDocumentsDirectory()
        let retained = try await repo.recentHistory(), copies = try await repo.list()
        XCTAssertFalse(retained.entries.contains { $0.id == folder.id }); XCTAssertEqual(copies.count, 6)
    }
    func testExternalEditingRelocatesBookmarksAndApplicationEditingSavesBack() async throws {
        let (_, repo, documents) = try environment(), file = documents.appendingPathComponent("章节.txt")
        try write("开头\n保留段落😀。", to: file); try await repo.reconcileDocumentsDirectory()
        let summaries = try await repo.list(); var book = try await repo.load(summaries[0].id)
        book.bookmarks = [.init(name: "位置", offset: 3, content: book.content)]; book.advanceRevision(); try await repo.save(book)
        try await repo.reconcileDocumentsDirectory()
        try write("新增加的开头\n" + book.content, to: file); try await repo.reconcileDocumentsDirectory()
        var updated = try await repo.load(book.id)
        XCTAssertEqual(updated.bookmarks.count, 1); XCTAssertEqual(updated.bookmarks[0].offset, 10)
        updated.edit(content: updated.content + "\n应用内续写。")
        try await repo.save(updated, writeSource: true); try await repo.reconcileDocumentsDirectory()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), updated.content)
        let savedBooks = try await repo.list(); XCTAssertEqual(savedBooks.count, 1)
    }
    func testPrivateAndExternalConcurrentChangesPreserveBothBodies() async throws {
        let (_, repo, documents) = try environment(), file = documents.appendingPathComponent("章节.txt")
        try write("初稿。", to: file); try await repo.reconcileDocumentsDirectory()
        let summaries = try await repo.list(); var privateCopy = try await repo.load(summaries[0].id)
        privateCopy.edit(content: "应用未同步的修改。"); try await repo.save(privateCopy)
        try write("电脑上的外部修改。", to: file); try await repo.reconcileDocumentsDirectory()
        let books = try await repo.list(); XCTAssertEqual(books.count, 2)
        let preserved = try await repo.load(privateCopy.id)
        XCTAssertEqual(preserved.content, "应用未同步的修改。")
        let remote = try await repo.load(books.first { $0.id != privateCopy.id }!.id)
        XCTAssertEqual(remote.content, "电脑上的外部修改。"); XCTAssertEqual(remote.conflictOf, privateCopy.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), remote.content)
        try await repo.reconcileDocumentsDirectory(); let repeated = try await repo.list(); XCTAssertEqual(repeated.count, 2)
    }
    func testDeleteLocalDocumentRemovesCopyBookmarksSnapshotsAndVisibleFileOnly() async throws {
        let (root, repo, documents) = try environment(), original = root.appendingPathComponent("外部原件.txt")
        try write("外部原件绝不删除。", to: original)
        var book = try await repo.openLocalFile(original).document
        book.bookmarks = [.init(name: "书签", offset: 0, content: book.content)]; book.advanceRevision(); try await repo.save(book)
        try await repo.reconcileDocumentsDirectory()
        let other = Manuscript(title: "保留", format: .txt, content: "其他文稿。")
        try await repo.save(other); try await repo.reconcileDocumentsDirectory()
        var history = try await repo.recentHistory(); history.togglePin(.init(id: other.id)); try await repo.saveHistory(history)
        let removed = try await repo.deleteLocalEntry(.init(id: book.id)); XCTAssertEqual(removed, [book.id])
        try await repo.reconcileDocumentsDirectory()
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "外部原件绝不删除。")
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent(book.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/History/\(book.id.uuidString)").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Sources/\(book.id.uuidString).json").path))
        let books = try await repo.list(), bookmarks = try await repo.allBookmarks(), remaining = try await repo.recentHistory()
        XCTAssertEqual(books.map(\.id), [other.id]); XCTAssertTrue(bookmarks.isEmpty); XCTAssertEqual(remaining.pinned, [other.id])
    }
    func testDeleteDirectoryKeepsSharedDocumentAndOtherHistory() async throws {
        let (_, repo, _) = try environment()
        let a = Manuscript(title: "共用", content: "共用正文。"), b = Manuscript(title: "删除", content: "删除正文。")
        try await repo.save(a); try await repo.save(b)
        let first = NovelCollection(alias: "目录甲", entries: [.init(documentID: a.id, relativePath: a.fileName), .init(documentID: b.id, relativePath: "下篇/" + b.fileName)])
        let second = NovelCollection(alias: "目录乙", entries: [.init(documentID: a.id, relativePath: a.fileName)])
        try await repo.saveCollection(first); try await repo.saveCollection(second); try await repo.reconcileDocumentsDirectory()
        let deleted = try await repo.deleteLocalEntry(.init(id: first.id, isFolder: true)); XCTAssertEqual(deleted, [b.id])
        try await repo.reconcileDocumentsDirectory()
        let folders = try await repo.collections(), books = try await repo.list()
        XCTAssertEqual(folders.map(\.id), [second.id]); XCTAssertEqual(books.map(\.id), [a.id])
    }
    func testSameNamesAreExportedSeparatelyAndInvalidFilesDoNotBlockOthers() async throws {
        let (_, repo, documents) = try environment()
        for text in ["甲。", "乙。"] { try await repo.save(Manuscript(title: "同名", format: .txt, content: text)) }
        try Data([0x80, 0x81]).write(to: documents.appendingPathComponent("未复制完整.txt"))
        try await repo.reconcileDocumentsDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: documents.path)
        XCTAssertTrue(files.contains("同名.txt")); XCTAssertTrue(files.contains("同名 (2).txt"))
        let books = try await repo.list(), issues = await repo.documentsDirectoryIssues
        XCTAssertEqual(books.count, 2); XCTAssertEqual(issues.count, 1)
        try await repo.reconcileDocumentsDirectory(); let repeated = try await repo.list(); XCTAssertEqual(repeated.count, 2)
    }
    func testSymlinkCannotImportOrDeleteAnExternalOriginal() async throws {
        let (root, repo, documents) = try environment(), external = root.appendingPathComponent("外部")
        try write("外部正文。", to: external.appendingPathComponent("原件.txt"))
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("链接"), withDestinationURL: external)
        try await repo.reconcileDocumentsDirectory(); let books = try await repo.list(); XCTAssertTrue(books.isEmpty)
        do { try await repo.deleteLocalEntry(.init(id: UUID())); XCTFail("Unknown document must fail") } catch { }
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("原件.txt"), encoding: .utf8), "外部正文。")
    }
}
