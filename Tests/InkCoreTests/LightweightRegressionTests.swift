import XCTest
@testable import InkCore

final class LightweightRegressionTests: XCTestCase {
    func testSharedSyntaxRulesPreserveConcurrentMatchesAndOffsets() async {
        let source = "<p title=\"中文123\">正文</p><!-- 'comment' -->"
        let expected = SyntaxHighlighter.tokens(in: source, format: .html, baseOffset: 90)
        XCTAssertTrue(expected.contains { $0.kind == .markup && $0.range.location == 90 })
        XCTAssertEqual(expected.last?.kind, .comment)
        await withTaskGroup(of: [SyntaxToken].self) { group in
            for _ in 0..<40 { group.addTask { SyntaxHighlighter.tokens(in: source, format: .html, baseOffset: 90) } }
            for await tokens in group {
                XCTAssertEqual(tokens.map(\.range), expected.map(\.range))
                XCTAssertEqual(tokens.map(\.kind), expected.map(\.kind))
            }
        }
        XCTAssertTrue(SyntaxHighlighter.tokens(in: source, format: .txt).isEmpty)
    }

    func testPreviewSourceKeepsOriginalDirectoryAndLatestSavedText() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
        let site = folder.appendingPathComponent("Site")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        let file = site.appendingPathComponent("index.htm")
        try Data("<link href=\"style.css\"><p>Before</p>".utf8).write(to: file)
        try Data("body{}".utf8).write(to: site.appendingPathComponent("style.css"))
        var book = try await repo.openLocalFile(file).document
        book.edit(content: "<link href=\"style.css\"><p>After</p>")
        try await repo.save(book, writeSource: true)
        let resolved = try await repo.sourceURL(book.id)
        XCTAssertEqual(resolved?.standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(resolved), encoding: .utf8), book.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: site.appendingPathComponent("style.css").path))
        let copy = Manuscript(title: "Copy", format: .html, content: book.content)
        try await repo.save(copy)
        let missing = try await repo.sourceURL(copy.id)
        XCTAssertNil(missing)
    }
    func testExternalAtomicReplacementReloadAndSaveRemainOnOriginalFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("Original".utf8).write(to: file)
        let first = try await repo.openLocalFile(file).document
        let unchanged = try await repo.reloadLocalFile(first.id)
        XCTAssertEqual(unchanged.revision, first.revision)
        let initiallyChanged = try await repo.sourceHasChanges(first.id)
        XCTAssertFalse(initiallyChanged)
        try Data("External replacement".utf8).write(to: file, options: .atomic)
        let changed = try await repo.sourceHasChanges(first.id)
        XCTAssertTrue(changed)
        var updated = try await repo.reloadLocalFile(first.id)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.content, "External replacement")
        updated.edit(content: "Saved by editor")
        try await repo.save(updated, writeSource: true)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Saved by editor")
        let afterSave = try await repo.sourceHasChanges(first.id)
        XCTAssertFalse(afterSave)
        let sharedDirectory = await repo.documentsDirectory
        XCTAssertNil(sharedDirectory)
    }

    func testReselectingUnchangedMarkdownRenewsBrokenBookmarkWithoutLosingState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Library")
        let repo = try LibraryRepository(root: root)
        let file = folder.appendingPathComponent("章节.md")
        let bytes = Data("# 标题\n\n保留正文😀。".utf8)
        try bytes.write(to: file)
        var original = try await repo.openLocalFile(file).document
        original.cursor = 4
        original.bookmarks = [.init(name: "保留书签", offset: 4, content: original.content)]
        try await repo.save(original)
        let referenceURL = root.appendingPathComponent("Sources/\(original.id.uuidString).json")
        var reference = try JSONDecoder().decode(LocalFileReference.self, from: Data(contentsOf: referenceURL))
        reference.bookmark = Data("unusable security-scoped bookmark".utf8)
        try JSONEncoder().encode(reference).write(to: referenceURL)

        let reopened = try await repo.openLocalFile(file).document
        XCTAssertEqual(reopened, original)
        let renewed = try JSONDecoder().decode(LocalFileReference.self, from: Data(contentsOf: referenceURL))
        XCTAssertNotEqual(renewed.bookmark, reference.bookmark)
        #if os(macOS)
        XCTAssertNotNil(renewed.bookmark)
        #endif
        XCTAssertEqual(renewed.diskDigest, LocalFileReference.digest(bytes))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let books = try await repo.list()
        XCTAssertEqual(books.map(\.id), [original.id])
        let freshRepository = try LibraryRepository(root: root)
        let restored = try await freshRepository.reloadLocalFile(original.id)
        XCTAssertEqual(restored, original)
    }

    func testReconnectingRenamedMarkdownPreservesIdentityBookmarksAndProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
        let oldFile = folder.appendingPathComponent("旧章名.md"), newFile = folder.appendingPathComponent("新章名.md")
        let bytes = Data("# 标题\n\n保留正文😀。".utf8)
        try bytes.write(to: oldFile)
        var original = try await repo.openLocalFile(oldFile).document
        original.cursor = 4
        original.bookmarks = [.init(name: "保留书签", offset: 4, content: original.content)]
        try await repo.save(original)
        try FileManager.default.moveItem(at: oldFile, to: newFile)

        var reconnected = try await repo.reconnectLocalFile(newFile, to: original.id)
        XCTAssertEqual(reconnected.id, original.id)
        XCTAssertEqual(reconnected.cursor, original.cursor)
        XCTAssertEqual(reconnected.bookmarks, original.bookmarks)
        XCTAssertEqual(reconnected.fileName, "新章名.md")
        XCTAssertEqual(reconnected.content, original.content)
        XCTAssertEqual(try Data(contentsOf: newFile), bytes)
        // 恢复关联之后的保存仍须拒绝覆盖更晚的外部修改。
        try Data("外部更新".utf8).write(to: newFile, options: .atomic)
        reconnected.edit(content: "应用内修改")
        do { try await repo.save(reconnected, writeSource: true); XCTFail("Must protect newer external text") }
        catch { XCTAssertTrue(error.localizedDescription.contains("其他应用修改")) }
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "外部更新")
    }

    func testExternalChangesRejectOverwriteAndKeepUnsavedCopyRecoverable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("Original".utf8).write(to: file)
        var local = try await repo.openLocalFile(file).document
        local.edit(content: "Local edits")
        try Data("External edits".utf8).write(to: file, options: .atomic)
        do { try await repo.save(local, writeSource: true); XCTFail("Must reject conflicting writes") }
        catch { XCTAssertTrue(error.localizedDescription.contains("其他应用修改")) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "External edits")
        // 用户另存后可重新关联新文件，不改写发生冲突的旧原文件。
        let copy = folder.appendingPathComponent("copy.txt")
        try Data(local.content.utf8).write(to: copy)
        try await repo.save(local)
        try await repo.attachSource(copy, to: local.id)
        local.edit(content: "Continued edits")
        try await repo.save(local, writeSource: true)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "Continued edits")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "External edits")
    }

    func testStagedExternalReadDoesNotAcknowledgeChangesBeforeEditorAccepts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try LibraryRepository(root: folder.appendingPathComponent("Library"))
        let file = folder.appendingPathComponent("chapter.txt")
        try Data("Original".utf8).write(to: file)
        let original = try await repo.openLocalFile(file).document
        try Data("External snapshot".utf8).write(to: file, options: .atomic)
        let pending = try await repo.localFileUpdate(original.id)
        let candidate = try XCTUnwrap(pending)
        let cached = try await repo.load(original.id)
        XCTAssertEqual(cached.content, "Original")
        let stillChanged = try await repo.sourceHasChanges(original.id)
        XCTAssertTrue(stillChanged)
        // 候选读取之后磁盘再次改变，接受旧候选也不能允许下一次保存覆盖更晚的修改。
        try Data("Newer external text".utf8).write(to: file, options: .atomic)
        try await repo.acceptLocalFileUpdate(candidate)
        var edited = candidate.document; edited.edit(content: "Local edits")
        do { try await repo.save(edited, writeSource: true); XCTFail("Must protect newer external text") }
        catch { XCTAssertTrue(error.localizedDescription.contains("其他应用修改")) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Newer external text")
    }

}
