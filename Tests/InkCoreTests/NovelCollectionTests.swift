import XCTest
@testable import InkCore

final class NovelCollectionTests: XCTestCase {
    func testReopeningLinkedRootSymlinkFindsAdditionsWithoutFollowingChildSymlinks() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel"), selected = temporary.appendingPathComponent("SelectedFolder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: source)
        try Data("原章节。".utf8).write(to: source.appendingPathComponent("第1章.md"))
        let repo = try LibraryRepository(root: temporary.appendingPathComponent("Library"))
        let initial = try await repo.importFolder(selected, alias: "小说", linkOriginals: true)
        try Data("新增章节。".utf8).write(to: source.appendingPathComponent("第2章.md"))
        let outside = temporary.appendingPathComponent("External.md")
        try Data("不应导入的外部正文。".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("第3章.md"), withDestinationURL: outside)
        let reopened = try await repo.importFolder(selected, alias: "小说", linkOriginals: true)
        XCTAssertTrue(reopened.reused); XCTAssertEqual(reopened.collection.id, initial.collection.id)
        XCTAssertEqual(reopened.collection.entries.count, 2)
        XCTAssertEqual(reopened.collection.entries.first?.documentID, initial.collection.entries.first?.documentID)
        let refreshed = try await repo.refreshLinkedFolders(); XCTAssertTrue(refreshed.isEmpty)
        let books = try await repo.list(); XCTAssertEqual(books.count, 2)
        XCTAssertFalse(books.contains { $0.fileName == "第3章.md" })
    }

    func testRepeatedLinkedFolderRefreshStillFindsNestedAdditionsAndKeepsMissingChapters() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel"), nested = source.appendingPathComponent("卷一")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let firstFile = nested.appendingPathComponent("第1章.md")
        try Data("第一章原文。".utf8).write(to: firstFile)
        let repo = try LibraryRepository(root: temporary.appendingPathComponent("Library"))
        let imported = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        let firstID = try XCTUnwrap(imported.collection.entries.first?.documentID)
        let first = try await repo.load(firstID)
        _ = try await repo.refreshLinkedFolders()
        let initialDirectories = try await repo.linkedFolderDirectories()
        XCTAssertEqual(Set(initialDirectories.map { $0.resolvingSymlinksInPath().path }), Set([source, nested].map { $0.resolvingSymlinksInPath().path }))
        for _ in 0..<3 { let unchanged = try await repo.refreshLinkedFolders(); XCTAssertTrue(unchanged.isEmpty) }
        try Data("第二章新增正文。".utf8).write(to: nested.appendingPathComponent("第2章.md"))
        let nestedAdded = try await repo.refreshLinkedFolders(); XCTAssertEqual(nestedAdded.count, 1)
        let deeper = nested.appendingPathComponent("后记")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        try Data("嵌套资料。".utf8).write(to: deeper.appendingPathComponent("说明.md"))
        let deeperAdded = try await repo.refreshLinkedFolders(); XCTAssertEqual(deeperAdded.count, 1)
        let directories = try await repo.linkedFolderDirectories()
        XCTAssertEqual(Set(directories.map { $0.resolvingSymlinksInPath().path }), Set([source, nested, deeper].map { $0.resolvingSymlinksInPath().path }))
        try FileManager.default.removeItem(at: firstFile)
        let afterRemoval = try await repo.refreshLinkedFolders(); XCTAssertTrue(afterRemoval.isEmpty)
        let kept = try await repo.load(firstID); XCTAssertEqual(kept, first)
        let books = try await repo.list(); XCTAssertEqual(books.count, 3)
        let folders = try await repo.collections()
        XCTAssertEqual(folders.first?.id, imported.collection.id)
        XCTAssertEqual(folders.first?.entries.count, 3)
    }

    func testLinkedFolderRefreshAddsNestedFilesWithoutResurrectingHistoryOrChangingExistingBooks() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel"), root = temporary.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("第一章正文😀。".utf8).write(to: source.appendingPathComponent("第1章.md"))
        let repo = try LibraryRepository(root: root)
        let receipt = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        let id = try XCTUnwrap(receipt.collection.entries.first?.documentID)
        var original = try await repo.load(id)
        original.bookmarks = [.init(name: "原书签", offset: 3, content: original.content)]; original.cursor = 3
        try await repo.save(original)
        var history = try await repo.recentHistory(); history.remove(receipt.collection.id); try await repo.saveHistory(history)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("卷二"), withIntermediateDirectories: true)
        try Data("第二章正文。".utf8).write(to: source.appendingPathComponent("卷二/第2章.md"))
        // Existing content changed externally must not overwrite a live editor on a directory refresh.
        try Data("外部修改".utf8).write(to: source.appendingPathComponent("第1章.md"))
        let added = try await repo.refreshLinkedFolders()
        XCTAssertEqual(added.count, 1)
        let unchanged = try await repo.load(id); XCTAssertEqual(unchanged, original)
        let folders = try await repo.collections(); let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folder.id, receipt.collection.id)
        XCTAssertEqual(Set(folder.entries.map(\.relativePath)), ["第1章.md", "卷二/第2章.md"])
        let afterHistory = try await repo.recentHistory(); XCTAssertEqual(afterHistory, history)
        let again = try await repo.refreshLinkedFolders(); XCTAssertTrue(again.isEmpty)
        let books = try await repo.list(); XCTAssertEqual(books.count, 2)
        let reopened = try await repo.importFolder(source, alias: "重开小说", linkOriginals: true)
        XCTAssertTrue(reopened.reused); XCTAssertEqual(reopened.collection.entries, folder.entries)
        XCTAssertEqual(reopened.collection.alias, "重开小说")
        let reloaded = try await repo.load(id)
        // Explicit reopen accepts the external edit and relocates the same bookmark.
        XCTAssertEqual(reloaded.bookmarks.map(\.id), original.bookmarks.map(\.id))
        XCTAssertEqual(reloaded.bookmarks.map(\.name), original.bookmarks.map(\.name))
        XCTAssertEqual(reloaded.content, "外部修改")
        let freshRepository = try LibraryRepository(root: root)
        let additionsAfterRestart = try await freshRepository.refreshLinkedFolders(); XCTAssertTrue(additionsAfterRestart.isEmpty)
    }

    func testFolderAdditionValidationDoesNotPartiallyImportOrConvertOfflineCopies() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("正文".utf8).write(to: source.appendingPathComponent("第1章.md"))
        let repo = try LibraryRepository(root: temporary.appendingPathComponent("Library"))
        let initial = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        let history = try await repo.recentHistory()
        try Data("新增正文".utf8).write(to: source.appendingPathComponent("第2章.md"))
        try Data([0x80, 0x81]).write(to: source.appendingPathComponent("第3章.md"))
        do { _ = try await repo.refreshLinkedFolders(); XCTFail("Invalid additions must fail before writes") }
        catch { XCTAssertEqual(error as? InkError, .invalidEncoding) }
        let folders = try await repo.collections(); XCTAssertEqual(folders, [initial.collection])
        let books = try await repo.list(); XCTAssertEqual(books.count, 1)
        let afterHistory = try await repo.recentHistory(); XCTAssertEqual(afterHistory, history)
        try FileManager.default.removeItem(at: source.appendingPathComponent("第3章.md"))
        let copyRepository = try LibraryRepository(root: temporary.appendingPathComponent("Offline"))
        _ = try await copyRepository.importFolder(source, alias: "离线副本")
        try Data("第三章正文".utf8).write(to: source.appendingPathComponent("第3章.md"))
        let copied = try await copyRepository.refreshLinkedFolders(); XCTAssertTrue(copied.isEmpty)
        let offlineBooks = try await copyRepository.list(); XCTAssertEqual(offlineBooks.count, 2)
        let explicitReimport = try await copyRepository.importFolder(source, alias: "再次打开")
        XCTAssertTrue(explicitReimport.reused); XCTAssertEqual(explicitReimport.collection.entries.count, 3)
        XCTAssertEqual(Set(offlineBooks.map(\.id)).subtracting(explicitReimport.collection.entries.map(\.documentID)), [])
    }

    func testReopeningLinkedFolderRepairsAllRenamedChaptersAndKeepsIDsAndBookmarks() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel"), root = temporary.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["第001章_旧名.md", "第002章_旧名.markdown", "章节目录.md"] { try Data("# 标题\n正文😀。".utf8).write(to: source.appendingPathComponent(name)) }
        let repo = try LibraryRepository(root: root)
        let first = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        let original = try await repo.list()
        let selected = try XCTUnwrap(original.first { $0.fileName.hasPrefix("第001") })
        var bookmarked = try await repo.load(selected.id)
        bookmarked.bookmarks = [.init(name: "保留", offset: 4, content: bookmarked.content)]; bookmarked.cursor = 4
        try await repo.save(bookmarked)
        let history = try await repo.recentHistory()
        for (old, new) in [("第001章_旧名.md", "第1章_新名.md"), ("第002章_旧名.markdown", "第002章_新名.md")] {
            try FileManager.default.moveItem(at: source.appendingPathComponent(old), to: source.appendingPathComponent(new))
        }
        let result = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        XCTAssertTrue(result.reused); XCTAssertEqual(result.collection.id, first.collection.id)
        XCTAssertEqual(Set(result.collection.entries.map(\.documentID)), Set(first.collection.entries.map(\.documentID)))
        XCTAssertEqual(Set(result.collection.entries.map(\.relativePath)), ["第1章_新名.md", "第002章_新名.md", "章节目录.md"])
        let reopened = try await repo.reloadLocalFile(selected.id)
        XCTAssertEqual(reopened.bookmarks, bookmarked.bookmarks); XCTAssertEqual(reopened.cursor, 4)
        XCTAssertEqual(reopened.fileName, "第1章_新名.md")
        let afterHistory = try await repo.recentHistory()
        XCTAssertEqual(afterHistory, history)
        let books = try await repo.list(); XCTAssertEqual(books.count, 3)
        for book in books {
            let resolved = try await repo.sourceURL(book.id)
            let file = try XCTUnwrap(resolved)
            let reloaded = try await repo.reloadLocalFile(book.id)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), reloaded.content)
        }
    }

    func testAmbiguousRenamedChapterDoesNotPartiallyUpdateSources() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Novel"), root = temporary.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["第001章_旧名.md", "第002章_旧名.md"] { try Data("正文".utf8).write(to: source.appendingPathComponent(name)) }
        let repo = try LibraryRepository(root: root)
        let first = try await repo.importFolder(source, alias: "小说", linkOriginals: true)
        let originals = try await repo.list()
        try FileManager.default.moveItem(at: source.appendingPathComponent("第001章_旧名.md"), to: source.appendingPathComponent("第001章_新名.md"))
        try FileManager.default.removeItem(at: source.appendingPathComponent("第002章_旧名.md"))
        for name in ["第2章_甲.md", "第002章_乙.md"] { try Data("歧义正文".utf8).write(to: source.appendingPathComponent(name)) }
        do { _ = try await repo.importFolder(source, alias: "小说", linkOriginals: true); XCTFail("Ambiguous matching must fail before any writes") }
        catch { XCTAssertEqual(error as? InkError, .invalidDocument) }
        let after = try await repo.list(); XCTAssertEqual(after, originals)
        let collections = try await repo.collections(); XCTAssertEqual(collections, [first.collection])
    }

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
