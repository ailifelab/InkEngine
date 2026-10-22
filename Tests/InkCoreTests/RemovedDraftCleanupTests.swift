import XCTest
@testable import InkCore

final class RemovedDraftCleanupTests: XCTestCase {
    private func environment(visibleDocuments: Bool = false) throws -> (URL, LibraryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try LibraryRepository(root: root, documentsDirectory: visibleDocuments ? root.appendingPathComponent("Documents") : nil))
    }

    private func removeHistory(_ ids: Set<UUID>, from repository: LibraryRepository) async throws {
        var history = try await repository.recentHistory()
        for id in ids { history.remove(id) }
        try await repository.saveHistory(history)
    }

    func testCleanupPermanentlyRemovesDraftBodyBookmarksSnapshotsAndPositionAcrossRestart() async throws {
        let (root, repository) = try environment()
        var draft = Manuscript(title: "废弃草稿", content: "不再保留的正文。")
        try await repository.save(draft)
        draft.bookmarks = [.init(name: "草稿书签", offset: 0, content: draft.content)]
        draft.advanceRevision(); try await repository.save(draft)
        try await removeHistory([draft.id], from: repository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("History/\(draft.id)").path))
        let removed = try await repository.clearRemovedDrafts()
        XCTAssertEqual(removed, [draft.id])
        for path in ["\(draft.id).ink", "Positions/\(draft.id).json", "History/\(draft.id)"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        let reopened = try LibraryRepository(root: root)
        let books = try await reopened.list(), bookmarks = try await reopened.allBookmarks(includeDeleted: true)
        let history = try await reopened.recentHistory(), repeated = try await reopened.clearRemovedDrafts()
        XCTAssertTrue(books.isEmpty); XCTAssertTrue(bookmarks.isEmpty); XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(repeated.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".delete-") })
    }

    func testCleanupPreservesOpenHistoryPinnedCollectionAndExternalDocuments() async throws {
        let (root, repository) = try environment()
        let removed = Manuscript(title: "待清理", content: "删除这份。")
        let current = Manuscript(title: "当前打开", content: "当前正文。")
        let visible = Manuscript(title: "仍在历史", content: "历史正文。")
        let pinned = Manuscript(title: "固定", content: "固定正文。")
        let chapter = Manuscript(title: "章节", content: "章节正文。")
        var imported = Manuscript(title: "旧导入副本", content: "旧副本。")
        imported.sourceName = "旧原件.md"
        var conflict = Manuscript(title: "冲突副本", content: "冲突正文。")
        conflict.conflictOf = current.id
        let brokenReference = Manuscript(title: "失效关联", content: "不能因关联损坏删除。")
        for draft in [removed, current, visible, pinned, chapter, imported, conflict, brokenReference] { try await repository.save(draft) }
        let original = root.appendingPathComponent("外部原件.txt")
        try Data("原文件保持不变。".utf8).write(to: original)
        let external = try await repository.openLocalFile(original).document
        let folder = NovelCollection(alias: "移出历史的目录", entries: [.init(documentID: chapter.id, relativePath: chapter.fileName)])
        try await repository.saveCollection(folder)
        try Data("损坏的书签".utf8).write(to: root.appendingPathComponent("Sources/\(brokenReference.id).json"))
        let all = [removed, current, chapter, imported, conflict, brokenReference, external].map(\.id)
        try await removeHistory(Set(all + [folder.id]), from: repository)
        var history = try await repository.recentHistory(); history.togglePin(.init(id: pinned.id)); try await repository.saveHistory(history)
        let cleared = try await repository.clearRemovedDrafts(protecting: [current.id])
        XCTAssertEqual(cleared, [removed.id])
        for book in [current, visible, pinned, chapter, imported, conflict, brokenReference, external] {
            let saved = try await repository.load(book.id)
            XCTAssertEqual(saved.content, book.content)
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "原文件保持不变。")
    }

    func testCleanupRespectsSelectedScopeAndKeepsMobileLocalDocuments() async throws {
        let (_, repository) = try environment()
        let first = Manuscript(title: "选中的草稿"), second = Manuscript(title: "其他草稿")
        try await repository.save(first); try await repository.save(second)
        try await removeHistory([first.id, second.id], from: repository)
        let empty = try await repository.clearRemovedDrafts(documentIDs: [])
        XCTAssertTrue(empty.isEmpty)
        let selected = try await repository.clearRemovedDrafts(documentIDs: [first.id])
        XCTAssertEqual(selected, [first.id])
        let retained = try await repository.load(second.id); XCTAssertEqual(retained.id, second.id)
        let (_, mobile) = try environment(visibleDocuments: true)
        try await mobile.save(first); try await mobile.reconcileDocumentsDirectory()
        try await removeHistory([first.id], from: mobile)
        let mobileCleared = try await mobile.clearRemovedDrafts()
        XCTAssertTrue(mobileCleared.isEmpty)
        let mobileBook = try await mobile.load(first.id); XCTAssertEqual(mobileBook.id, first.id)
    }

    func testUnreadableHistoryAbortsCleanupBeforeDeletingDrafts() async throws {
        let (root, repository) = try environment()
        let draft = Manuscript(title: "不能误删")
        try await repository.save(draft)
        try Data("损坏的历史".utf8).write(to: root.appendingPathComponent("Recent.json"))
        do { _ = try await repository.clearRemovedDrafts(); XCTFail("Invalid history must abort cleanup") } catch { }
        let preserved = try await repository.load(draft.id); XCTAssertEqual(preserved.id, draft.id)
    }
}
