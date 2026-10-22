import XCTest
@testable import InkCore

final class WorkingDraftTests: XCTestCase {
    private func library(documents: Bool = false) throws -> (URL, LibraryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkingDraftTests-" + UUID().uuidString)
        return (root, try LibraryRepository(root: root.appendingPathComponent("Library"), documentsDirectory: documents ? root.appendingPathComponent("Documents") : nil))
    }

    func testRecoveryRestoresLatestReadingPositionWithoutSavingUnsavedBody() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Manuscript(title: "位置", format: .txt, content: "原始正文。")
        try await repository.save(baseline)
        var working = baseline; working.edit(content: "尚未保存的正文😀，继续阅读。")
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: false))
        try await repository.savePosition(id: working.id, revision: working.revision, cursor: 10)
        let reopened = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let draft = try await reopened.workingDraft(working.id)
        XCTAssertEqual(draft?.document.cursor, 10)
        XCTAssertEqual(draft?.document.content, working.content)
        XCTAssertEqual(draft?.document.revision, working.revision)
        XCTAssertTrue(draft?.hasChanges == true)
        let formal = try await reopened.load(working.id)
        XCTAssertEqual(formal.content, baseline.content)
        XCTAssertEqual(formal.cursor, baseline.cursor)
        // A newer draft checkpoint must supersede an older position sidecar.
        working.cursor = 4
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: false))
        let newer = try await reopened.workingDraft(working.id)
        XCTAssertEqual(newer?.document.cursor, 4)
    }

    func testRecoveryPositionRejectsAnotherRevisionAndClampsSameRevision() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        var book = Manuscript(title: "位置", format: .txt, content: "中文😀正文")
        book.cursor = 2
        try await repository.save(book)
        try await repository.saveWorkingDraft(.init(document: book, baseline: book, isNew: false))
        try await repository.savePosition(id: book.id, revision: UUID(), cursor: 4)
        let stale = try await repository.workingDraft(book.id)
        XCTAssertEqual(stale?.document.cursor, 2)
        try await repository.savePosition(id: book.id, revision: book.revision, cursor: 999)
        let current = try await repository.workingDraft(book.id)
        XCTAssertEqual(current?.document.cursor, book.content.utf16.count)
        XCTAssertFalse(current?.hasChanges ?? true)
        let formal = try await repository.load(book.id)
        XCTAssertEqual(formal.cursor, current?.document.cursor)
    }

    func testTabReorderingPreservesPinsAndRejectsStaleTargets() {
        let pinned = WorkspaceTab(id: UUID(), pinned: true), a = WorkspaceTab(id: UUID()), b = WorkspaceTab(id: UUID())
        var pane = WorkspacePane(tabs: [pinned, a, b], selected: a.id)
        XCTAssertTrue(pane.moveTab(a.id, before: nil))
        XCTAssertEqual(pane.tabs.map(\.id), [pinned.id, b.id, a.id])
        XCTAssertTrue(pane.moveTab(b.id, before: pinned.id))
        XCTAssertEqual(pane.tabs.map(\.id), [pinned.id, b.id, a.id])
        let unchanged = pane
        XCTAssertFalse(pane.moveTab(a.id, before: UUID()))
        XCTAssertEqual(pane, unchanged)
        XCTAssertEqual(pane.selected, a.id)
    }

    func testTabSortingIsStableAndKeepsTheActiveDocumentAndPinGroup() {
        let pinned = WorkspaceTab(id: UUID(), pinned: true), a = WorkspaceTab(id: UUID()), b = WorkspaceTab(id: UUID()), c = WorkspaceTab(id: UUID())
        var pane = WorkspacePane(tabs: [pinned, a, b, c], selected: a.id)
        let ranks = [pinned.id: 9, a.id: 2, b.id: 1, c.id: 2]
        pane.sortTabs { ranks[$0.id]! < ranks[$1.id]! }
        XCTAssertEqual(pane.tabs.map(\.id), [pinned.id, b.id, a.id, c.id])
        XCTAssertEqual(pane.selected, a.id)
    }

    func testRecentlyClosedMetadataSurvivesWorkspaceRestoreWithoutRecreatingOpenTabs() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceWindow(), tab = WorkspaceTab(id: UUID(), pinned: true, color: 2)
        let record = ClosedWorkspaceTab(tab: tab, window: window.id, pane: window.focusedPane, index: 3, fileName: "章节.md", editing: false, cursor: 42)
        try await repository.saveWorkspace(.init(windows: [window], recentlyClosed: [record]))
        let restored = try await repository.workspaceSnapshot()
        XCTAssertEqual(restored?.recentlyClosed?.first?.tab, tab)
        XCTAssertEqual(restored?.recentlyClosed?.first?.cursor, 42)
        XCTAssertTrue(restored?.windows.first?.panes.first?.tabs.isEmpty == true)
    }

    func testWorkspaceSidebarVisibilitySurvivesRestoreAndOldSnapshotsRemainReadable() throws {
        var window = WorkspaceWindow()
        window.sidebarVisible = false
        let data = try JSONEncoder().encode(WorkspaceSnapshot(windows: [window]))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data).windows.first?.sidebarVisible, false)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var windows = try XCTUnwrap(old["windows"] as? [[String: Any]])
        windows[0].removeValue(forKey: "sidebarVisible"); old["windows"] = windows
        let legacy = try JSONSerialization.data(withJSONObject: old)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy).windows.first?.sidebarVisible)
    }

    func testRecoveryNeverWritesOriginalOrFormalLibraryAndDiscardSurvivesRestart() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("正文.md")
        let original = Data([0xef, 0xbb, 0xbf]) + Data("# 原正文\r\n".utf8)
        try original.write(to: source)
        let baseline = try await repository.openLocalFile(source).document
        var working = baseline; working.edit(content: "未保存😀")
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: false))
        let reopened = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let restored = try await reopened.workingDraft(baseline.id)
        XCTAssertEqual(restored?.document.content, "未保存😀")
        XCTAssertEqual(restored?.baseline.content, baseline.content)
        XCTAssertTrue(restored?.hasChanges == true)
        let formal = try await reopened.load(baseline.id)
        XCTAssertEqual(formal.content, baseline.content)
        XCTAssertEqual(try Data(contentsOf: source), original)
        try await reopened.removeWorkingDraft(baseline.id)
        let discarded = try await reopened.workingDraft(baseline.id)
        XCTAssertNil(discarded)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testIPadRecoveryIsNotPublishedByVisibleDirectoryReconciliation() async throws {
        let (root, repository) = try library(documents: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Manuscript(title: "已保存", content: "原文")
        try await repository.save(baseline)
        _ = try await repository.reconcileDocumentsDirectory()
        var working = baseline; working.edit(content: "不能提前写入文件App")
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: false))
        _ = try await repository.reconcileDocumentsDirectory()
        let formal = try await repository.load(baseline.id)
        XCTAssertEqual(formal.content, "原文")
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Documents"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try String(contentsOf: files[0], encoding: .utf8), "原文")
    }

    func testNewDraftDoesNotBecomeFormalDocumentOrHistoryEntry() async throws {
        let (root, repository) = try library(documents: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Manuscript(title: "未命名 1", format: .txt)
        var working = baseline; working.edit(content: "临时文本")
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: true))
        _ = try await repository.reconcileDocumentsDirectory()
        let list = try await repository.list(), history = try await repository.recentHistory()
        XCTAssertTrue(list.isEmpty); XCTAssertTrue(history.entries.isEmpty)
        let ids = try await repository.workingDraftIDs()
        XCTAssertEqual(ids, [baseline.id])
    }

    func testUndoBackToBaselineIsUnmodifiedButNewNonemptyDraftNeedsSave() {
        let baseline = Manuscript(title: "基线", content: "正文")
        var working = baseline; working.edit(content: "改过"); working.edit(content: "正文")
        XCTAssertFalse(WorkingDraft(document: working, baseline: baseline, isNew: false).hasChanges)
        XCTAssertTrue(WorkingDraft(document: baseline, baseline: baseline, isNew: true).hasChanges)
        let empty = Manuscript(title: "空白", content: "")
        XCTAssertFalse(WorkingDraft(document: empty, baseline: empty, isNew: true).hasChanges)
    }

    func testCleanupProtectsRecoveryEvenAfterHistoryRemoval() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Manuscript(title: "草稿", content: "原文")
        try await repository.save(baseline)
        var history = try await repository.recentHistory(); history.remove(baseline.id)
        try await repository.saveHistory(history)
        var working = baseline; working.edit(content: "另一个标签中的编辑")
        try await repository.saveWorkingDraft(.init(document: working, baseline: baseline, isNew: false))
        let removed = try await repository.clearRemovedDrafts()
        XCTAssertTrue(removed.isEmpty)
        let recovered = try await repository.workingDraft(baseline.id)
        XCTAssertEqual(recovered?.document.content, working.content)
    }

    func testClonedTabsRestoreOneIdentityAcrossPanesAndWindows() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let tab = WorkspaceTab(id: id, pinned: true, color: 3)
        let first = WorkspaceWindow(panes: [.init(tabs: [tab]), .init(tabs: [tab])])
        let second = WorkspaceWindow(panes: [.init(tabs: [tab])])
        try await repository.saveWorkspace(.init(windows: [first, second]))
        let snapshot = try await repository.workspaceSnapshot()
        XCTAssertEqual(snapshot?.windows, [first, second])
    }

    func testShareSnapshotDoesNotCommitWorkingTextAndKeepsBookmarks() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        var baseline = Manuscript(title: "分享", content: "原文")
        baseline.bookmarks = [.init(name: "书签", offset: 0, content: baseline.content)]
        try await repository.save(baseline)
        var working = baseline; working.edit(content: "分享当前修改😀")
        let transfer = try await repository.prepareTransfer(id: baseline.id, isFolder: false, overrides: [baseline.id: working])
        defer { transfer.remove() }
        XCTAssertEqual(try transfer.document(transfer.manifest.items[0]).content, working.content)
        XCTAssertEqual(try transfer.document(transfer.manifest.items[0]).bookmarks.map(\.id), baseline.bookmarks.map(\.id))
        let formal = try await repository.load(baseline.id)
        XCTAssertEqual(formal.content, baseline.content)
    }

    func testRecoveryRejectsMismatchedDocumentIdentity() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await repository.saveWorkingDraft(.init(document: .init(title: "甲"), baseline: .init(title: "乙"), isNew: true))
            XCTFail("Recovery must not mix document identities")
        } catch { XCTAssertEqual(error as? InkError, .invalidDocument) }
    }

    func testBookmarkChangesCanPersistWithoutCommittingUnsavedBody() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Manuscript(title: "书签与草稿", content: "原文第一段。\n原文第二段。")
        try await repository.save(baseline)
        var working = baseline; working.edit(content: "未保存的开头。\n" + baseline.content)
        let mark = ReadingBookmark(name: "新书签", offset: 9, content: working.content)
        working.bookmarks.append(mark); working.advanceRevision()
        let metadata = try XCTUnwrap(WorkingDraft(document: working, baseline: baseline, isNew: false).metadataOnlyUpdate)
        XCTAssertEqual(metadata.content, baseline.content)
        XCTAssertEqual(metadata.bookmarks.map(\.id), [mark.id])
        try await repository.save(metadata)
        try await repository.saveWorkingDraft(.init(document: working, baseline: metadata, isNew: false))
        try await repository.removeWorkingDraft(baseline.id)
        let formal = try await repository.load(baseline.id)
        XCTAssertEqual(formal.content, baseline.content)
        XCTAssertEqual(formal.bookmarks.first?.name, "新书签")
    }

    func testBodyRelocationAloneDoesNotCommitBookmarkMetadata() {
        var baseline = Manuscript(title: "锚点", content: "第一段。\n第二段。")
        baseline.bookmarks = [.init(name: "第二段", offset: 5, content: baseline.content)]
        var working = baseline; working.edit(content: "加入尚未保存的一段。\n" + baseline.content)
        XCTAssertNil(WorkingDraft(document: working, baseline: baseline, isNew: false).metadataOnlyUpdate)
    }

    func testClonesPersistIndependentSelectionScrollAndReadingMode() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        var left = WorkspacePane(tabs: [.init(id: id)]), right = WorkspacePane(tabs: [.init(id: id)])
        left.viewPositions = [id.uuidString: .init(cursor: 20, selectionLength: 4, x: 12, y: 300, editing: true, wrapsLines: false, columnMode: true)]
        right.viewPositions = [id.uuidString: .init(cursor: 600, selectionLength: 0, x: 0, y: 900, editing: false)]
        try await repository.saveWorkspace(.init(windows: [.init(panes: [left, right])]))
        let restored = try await repository.workspaceSnapshot()
        XCTAssertEqual(restored?.windows.first?.panes, [left, right])
        XCTAssertNotEqual(restored?.windows.first?.panes[0].viewPositions, restored?.windows.first?.panes[1].viewPositions)
    }

    func testWorkspaceWithoutNewViewStateFieldsStillRestoresDocumentIdentity() async throws {
        let (root, repository) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = UUID(), pane = UUID(), document = UUID()
        let legacy = """
        {"version":1,"windows":[{"id":"\(window)","focusedPane":"\(pane)","panes":[{"id":"\(pane)","tabs":[{"id":"\(document)","pinned":false}],"selected":"\(document)"}]}]}
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("Library/Workspace.json"))
        let restored = try await repository.workspaceSnapshot()
        XCTAssertEqual(restored?.windows.first?.panes.first?.selected, document)
        XCTAssertNil(restored?.windows.first?.panes.first?.viewPositions)
    }
}
