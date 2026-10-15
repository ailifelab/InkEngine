import XCTest
@testable import InkCore

final class DocumentTransferTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testDirectorySnapshotRoundTripWithNestedPathsAndOfflineOrder() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let first = Manuscript(title: "第1章", format: .markdown, content: "# 一\n正文😀", cursor: 4)
        let second = Manuscript(title: "第10章", format: .txt, content: "后续正文")
        try await sender.save(first); try await sender.save(second)
        let collection = NovelCollection(alias: "整部小说", sourceFolder: "/private/电脑目录", entries: [.init(documentID: second.id, relativePath: "下篇/第10章.txt"), .init(documentID: first.id, relativePath: "第1章.md")])
        try await sender.saveCollection(collection)
        let prepared = try await sender.prepareTransfer(id: collection.id, isFolder: true); defer { prepared.remove() }
        XCTAssertNil(prepared.manifest.collection?.sourceFolder)
        let receipt = try await receiver.receiveTransfer(prepared)
        XCTAssertEqual(receipt.count, 2)
        let copies = try await receiver.collections(), received = try await receiver.load(first.id)
        XCTAssertEqual(received.content, first.content); XCTAssertEqual(received.cursor, first.cursor)
        XCTAssertEqual(copies.first?.entries, prepared.manifest.collection?.entries)
        XCTAssertNil(copies.first?.sourceFolder)
    }
    func testConflictingChapterKeepsBothInDirectory() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let base = Manuscript(title: "章节", format: .txt, content: "原文")
        var remote = base, local = base; remote.edit(content: "电脑修改"); local.edit(content: "平板修改")
        try await sender.save(remote); try await receiver.save(local)
        let collection = NovelCollection(alias: "冲突测试", entries: [.init(documentID: base.id, relativePath: base.fileName)])
        try await sender.saveCollection(collection); try await receiver.saveCollection(collection)
        let transfer = try await sender.prepareTransfer(id: collection.id, isFolder: true); defer { transfer.remove() }
        let receipt = try await receiver.receiveTransfer(transfer)
        XCTAssertEqual(receipt.conflicts, 1)
        let books = try await receiver.list(), folder = try await receiver.collections()[0]
        XCTAssertEqual(books.count, 2); XCTAssertEqual(folder.entries.count, 2)
        let retained = try await receiver.load(base.id); XCTAssertEqual(retained.content, "平板修改")
        let copied = try await receiver.load(books.first { $0.id != base.id }!.id)
        XCTAssertEqual(copied.content, "电脑修改"); XCTAssertEqual(copied.conflictOf, base.id)
        let reshared = try await receiver.prepareTransfer(id: collection.id, isFolder: true); defer { reshared.remove() }
        XCTAssertEqual(Set(reshared.manifest.items.map(\.relativePath)).count, 2)
    }
    func testIncompleteDirectoryDoesNotWriteAnyDocument() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let a = Manuscript(title: "甲", format: .txt, content: "甲"), b = Manuscript(title: "乙", format: .txt, content: "乙")
        try await sender.save(a); try await sender.save(b)
        let collection = NovelCollection(alias: "小说", entries: [.init(documentID: a.id, relativePath: a.fileName), .init(documentID: b.id, relativePath: b.fileName)])
        try await sender.saveCollection(collection)
        let transfer = try await sender.prepareTransfer(id: collection.id, isFolder: true); defer { transfer.remove() }
        try FileManager.default.removeItem(at: transfer.documentURL(b.id))
        do { _ = try await receiver.receiveTransfer(transfer); XCTFail("Must reject an incomplete directory") } catch { }
        let books = try await receiver.list(), folders = try await receiver.collections()
        XCTAssertTrue(books.isEmpty); XCTAssertTrue(folders.isEmpty)
    }
    func testTransferUpdatesLinkedFileButExternalEditsBecomeConflicts() async throws {
        let directory = try temporary(), original = directory.appendingPathComponent("原件.txt")
        try Data("初稿".utf8).write(to: original)
        let receiver = try LibraryRepository(root: directory.appendingPathComponent("Library")), sender = try LibraryRepository(root: temporary())
        let base = try await receiver.openLocalFile(original).document
        var incoming = base; incoming.edit(content: "电脑新版")
        try await sender.save(incoming)
        let transfer = try await sender.prepareTransfer(id: base.id, isFolder: false); defer { transfer.remove() }
        let receipt = try await receiver.receiveTransfer(transfer)
        XCTAssertEqual(receipt.conflicts, 0); XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "电脑新版")
        incoming.edit(content: "电脑再改"); try await sender.save(incoming)
        try Data("其他应用修改".utf8).write(to: original)
        let next = try await sender.prepareTransfer(id: base.id, isFolder: false); defer { next.remove() }
        let conflict = try await receiver.receiveTransfer(next)
        XCTAssertEqual(conflict.conflicts, 1); XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "其他应用修改")
    }
    func testFailureDuringCommitRollsBackLinkedOriginalAndNewChapters() async throws {
        let directory = try temporary(), original = directory.appendingPathComponent("原件.txt")
        try Data("初稿".utf8).write(to: original)
        let receiver = try LibraryRepository(root: directory.appendingPathComponent("Library")), sender = try LibraryRepository(root: temporary())
        let base = try await receiver.openLocalFile(original).document
        var changed = base; changed.edit(content: "电脑新版")
        let extra = Manuscript(title: "新章", format: .txt, content: "新章正文")
        try await sender.save(changed); try await sender.save(extra)
        let folder = NovelCollection(alias: "提交失败测试", entries: [.init(documentID: base.id, relativePath: base.fileName), .init(documentID: extra.id, relativePath: extra.fileName)])
        try await sender.saveCollection(folder)
        let transfer = try await sender.prepareTransfer(id: folder.id, isFolder: true); defer { transfer.remove() }
        // 用目录占住资料库清单文件的位置，使最后提交目录失败，验证前面的文件写入也能回滚。
        let blocked = directory.appendingPathComponent("Library/Collections/" + folder.id.uuidString + ".json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        do { _ = try await receiver.receiveTransfer(transfer); XCTFail("Commit must fail") } catch { }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "初稿")
        let retained = try await receiver.load(base.id), books = try await receiver.list()
        XCTAssertEqual(retained.content, "初稿"); XCTAssertEqual(books.map(\.id), [base.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
    }
    func testResyncRestoresRemovedHistoryAndKeepsPinnedOrder() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let book = Manuscript(title: "收到的文件", format: .txt, content: "离线正文")
        let pin = Manuscript(title: "固定文稿", format: .txt, content: "原来的正文")
        try await sender.save(book); try await receiver.save(pin)
        let transfer = try await sender.prepareTransfer(id: book.id, isFolder: false); defer { transfer.remove() }
        _ = try await receiver.receiveTransfer(transfer)
        var history = try await receiver.recentHistory(); history.togglePin(RecentEntry(id: pin.id)); history.remove(book.id)
        try await receiver.saveHistory(history)
        let receipt = try await receiver.receiveTransfer(transfer), restored = try await receiver.recentHistory()
        XCTAssertEqual(receipt.entry.id, book.id); XCTAssertFalse(receipt.entry.isFolder)
        XCTAssertEqual(restored.entries.first?.id, book.id); XCTAssertEqual(restored.pinned, [pin.id])
        let opened = try await receiver.load(receipt.entry.id); XCTAssertEqual(opened.content, "离线正文")
    }
    func testResyncedFolderReturnsOneOpenableHistoryEntry() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let one = Manuscript(title: "第1章", format: .txt, content: "一"), two = Manuscript(title: "第2章", format: .txt, content: "二")
        try await sender.save(one); try await sender.save(two)
        let folder = NovelCollection(alias: "同步小说", entries: [.init(documentID: one.id, relativePath: one.fileName), .init(documentID: two.id, relativePath: two.fileName)])
        try await sender.saveCollection(folder)
        let transfer = try await sender.prepareTransfer(id: folder.id, isFolder: true); defer { transfer.remove() }
        _ = try await receiver.receiveTransfer(transfer)
        var history = RecentHistory(); history.opened(RecentEntry(id: one.id)); history.opened(RecentEntry(id: two.id))
        try await receiver.saveHistory(history)
        let receipt = try await receiver.receiveTransfer(transfer), restored = try await receiver.recentHistory()
        XCTAssertEqual(receipt.entry.id, folder.id); XCTAssertTrue(receipt.entry.isFolder)
        XCTAssertEqual(restored.entries.map(\.id), [folder.id])
        let folders = try await receiver.collections(); XCTAssertEqual(folders.first?.id, receipt.entry.id)
    }
    func testConflictingFileReceiptOpensReceivedCopy() async throws {
        let sender = try LibraryRepository(root: temporary()), receiver = try LibraryRepository(root: temporary())
        let base = Manuscript(title: "两端修改", format: .txt, content: "初稿")
        var local = base, remote = base; local.edit(content: "手机内容"); remote.edit(content: "电脑内容")
        try await receiver.save(local); try await sender.save(remote)
        let transfer = try await sender.prepareTransfer(id: base.id, isFolder: false); defer { transfer.remove() }
        let receipt = try await receiver.receiveTransfer(transfer)
        XCTAssertEqual(receipt.conflicts, 1); XCTAssertNotEqual(receipt.entry.id, base.id)
        let received = try await receiver.load(receipt.entry.id), retained = try await receiver.load(base.id)
        XCTAssertEqual(received.content, "电脑内容"); XCTAssertEqual(retained.content, "手机内容")
    }
    func testPathsAndDuplicateIDsAreRejected() throws {
        let book = Manuscript(title: "章", format: .txt, content: "文")
        let item = TransferManifest.Item(documentID: book.id, relativePath: "章.txt", checksum: book.checksum, byteCount: 3)
        XCTAssertThrowsError(try TransferManifest(title: "重复", items: [item, item]).validated())
        for path in ["../章.txt", "/章.txt", "a//b", "a\\b", "a/./b", "a/../b", "a\0b"] {
            let manifest = TransferManifest(title: "小说", items: [.init(documentID: book.id, relativePath: path, checksum: book.checksum, byteCount: 3)])
            XCTAssertThrowsError(try manifest.validated())
            XCTAssertThrowsError(try ZIPArchive.write(to: temporary().appendingPathComponent("x.zip"), paths: [path]) { _ in Data() })
        }
    }
    #if os(macOS)
    func testZIPCanBeReadBySystemPythonIncludingChineseAndEmptyFile() throws {
        let directory = try temporary(), archive = directory.appendingPathComponent("小说.zip")
        let text = Data("正文😀\n第二行".utf8)
        try ZIPArchive.write(to: archive, paths: ["小说/正文/第1章.txt", "小说/空章.txt"]) { $0 == 0 ? text : Data() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert z.namelist()==['小说/正文/第1章.txt','小说/空章.txt']; assert z.read(z.namelist()[0]).decode()=='正文😀\\n第二行'; assert z.read(z.namelist()[1])==b''", archive.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    #endif
}
