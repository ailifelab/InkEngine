import XCTest
@testable import InkCore

final class EditorHistoryTests: XCTestCase {
    func testBrokenFileBookmarkRecoversOnlyReadableOriginalPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("正文.txt")
        try Data("旧正文".utf8).write(to: url)
        var reference = try LocalFileReference(url: url, content: "旧正文")
        reference.bookmark = Data([0, 1, 2])
        XCTAssertEqual(try reference.resolved(), url)
        try reference.write("新正文😀")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "新正文😀")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try reference.resolved(), "Missing files must not become invented accessible URLs")
    }
    func testOriginalFileAtomicReplacementReloadsAndRemainsWritable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Replaced-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("正文.txt")
        try Data("替换前".utf8).write(to: original)
        let repository = try LibraryRepository(root: root.appendingPathComponent("Library"))
        let receipt = try await repository.openLocalFile(original)
        try Data("原子替换后的正文😀".utf8).write(to: original, options: .atomic)
        var book = try await repository.reloadLocalFile(receipt.document.id)
        XCTAssertEqual(book.content, "原子替换后的正文😀")
        book.edit(content: "重新编辑并保存")
        try await repository.save(book, writeSource: true)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "重新编辑并保存")
    }
    func testSummaryCacheReadsPositionsAndInvalidatesChangedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try LibraryRepository(root: root)
        var book = Manuscript(title: "摘要缓存", format: .txt, content: "中文正文😀")
        try await repository.save(book)
        let initial = try await repository.list(); XCTAssertEqual(initial.first?.length, book.content.utf16.count)
        try await repository.savePosition(id: book.id, revision: book.revision, cursor: 3)
        let moved = try await repository.list(); XCTAssertEqual(moved.first?.cursor, 3)
        try await repository.savePosition(id: book.id, revision: UUID(), cursor: 7)
        let stale = try await repository.list(); XCTAssertEqual(stale.first?.cursor, 0)
        book.edit(content: "替换为更长的一份正文。")
        try await repository.save(book)
        let changed = try await repository.list(); XCTAssertEqual(changed.first?.length, book.content.utf16.count)
    }
    func testHistoryCapsRecordsProtectsPinsAndReordersWithoutChangingRecency() {
        var history = RecentHistory()
        let first = RecentEntry(id: UUID(), openedAt: Date(timeIntervalSince1970: 1))
        let second = RecentEntry(id: UUID(), openedAt: Date(timeIntervalSince1970: 2))
        history.togglePin(first); history.togglePin(second)
        for n in 3...150 { history.opened(.init(id: UUID(), openedAt: Date(timeIntervalSince1970: Double(n)))) }
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.ordered.prefix(2).map(\.id), [first.id, second.id])
        history.reorderPins([second.id, first.id])
        XCTAssertEqual(history.ordered.prefix(2).map(\.id), [second.id, first.id])
        let latest = history.ordered[2]
        history.opened(.init(id: history.ordered.last!.id, openedAt: Date(timeIntervalSince1970: 1000)))
        XCTAssertNotEqual(history.ordered[2].id, latest.id)
        history.remove(first.id); XCTAssertEqual(history.pinned, [second.id])
    }
    func testAllPinnedStillHonorsCapAndBadReorderCannotLosePins() {
        var history = RecentHistory()
        for n in 0..<100 { history.togglePin(.init(id: UUID(), openedAt: Date(timeIntervalSince1970: Double(n)))) }
        let pins = history.pinned
        history.opened(.init(id: UUID())); history.reorderPins([])
        XCTAssertEqual(history.pinned, pins); XCTAssertEqual(history.entries.count, 100)
    }
    func testLiteralReplacementDoesNotInterpretDollarOrBackslash() throws {
        let options = FindOptions()
        let output = try FindReplace.replacing("文字", with: "$1\\n", in: "文字😀文字", options: options)
        XCTAssertEqual(output.text, "$1\\n😀$1\\n"); XCTAssertEqual(output.count, 2)
    }
    func testRegexMultilineGroupsAndEscapes() throws {
        let options = FindOptions(regularExpression: true, caseSensitive: true, escapes: true)
        let result = try FindReplace.replacing("^第(\\d+)章[ ]+(.*)$", with: "$2\\t章节$1", in: "第1章 开始\n第20章 终点", options: options)
        XCTAssertEqual(result.text, "开始\t章节1\n终点\t章节20")
        XCTAssertEqual(result.count, 2)
        XCTAssertThrowsError(try FindReplace.matches("[", in: "abc", options: options))
    }
    func testUnicodeRangesSingleReplaceAndZeroWidthRegex() throws {
        let options = FindOptions(regularExpression: true)
        let text = "😀a😀a"
        let matches = try FindReplace.matches("a", in: text, options: options)
        XCTAssertEqual(matches.map(\.location), [2, 5])
        XCTAssertEqual(try FindReplace.replacing("a", with: "中", in: text, options: options, range: matches[1]).text, "😀a😀中")
        XCTAssertEqual(try FindReplace.replacing("^", with: ">", in: "a\nb", options: options).text, ">a\n>b")
        XCTAssertEqual(try FindReplace.matches("", in: text, options: options), [])
    }
    func testLiteralEscapesAndResultBound() throws {
        let options = FindOptions(escapes: true)
        XCTAssertEqual(try FindReplace.replacing("\\t", with: "\\n", in: "a\tb", options: options).text, "a\nb")
        XCTAssertEqual(FindReplace.unescape("\\\\n\\q"), "\\n\\q")
        XCTAssertEqual(try FindReplace.matches("a", in: String(repeating: "a", count: 5000), options: options).count, 2000)
    }
    func testColumnSelectionRaggedLinesAndEmojiRemainWhole() {
        let text = "a😀c\na\n12345"
        let ranges = ColumnSelection.ranges(in: text, from: 1, to: 9)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["😀", "", "2"])
        let result = ColumnSelection.replacing(text, ranges: ranges, with: "X")
        XCTAssertEqual(result.text, "aXc\naX\n1X345")
        XCTAssertEqual(result.carets.map(\.location), [2, 6, 9])
    }
    func testColumnPasteMapsRowsAndRejectsOverlappingRanges() {
        XCTAssertEqual(ColumnSelection.replacing("ab\ncd", ranges: [NSRange(location: 1, length: 1), NSRange(location: 4, length: 1)], with: "1\n2").text, "a1\nc2")
        XCTAssertEqual(ColumnSelection.replacing("abc", ranges: [NSRange(location: 0, length: 2), NSRange(location: 1, length: 2)], with: "x").text, "abc")
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testLocalSaveWritesOriginalPreservesUTF16AndReadonlyMetadataDoesNotWrite() async throws {
        let root = try temporary(), source = root.appendingPathComponent("中文.txt")
        try "原文\n".data(using: .utf16)!.write(to: source)
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        var book = try await repo.openLocalFile(source).document
        let original = try Data(contentsOf: source)
        book.bookmarks = [ReadingBookmark(name: "位置", offset: 0, content: book.content)]
        book.advanceRevision(); try await repo.save(book)
        XCTAssertEqual(try Data(contentsOf: source), original)
        book.edit(content: "修改😀\n"); try await repo.save(book, writeSource: true)
        XCTAssertEqual(String(data: try Data(contentsOf: source), encoding: .utf16), "修改😀\n")
        let reopened = try await repo.openLocalFile(source).document
        XCTAssertEqual(reopened.id, book.id)
        let links = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Library/Sources"), includingPropertiesForKeys: nil)
        XCTAssertEqual(links.count, 1)
    }
    func testLocalConflictPreservesExternalChangesAndHistoryRemovalLeavesFile() async throws {
        let root = try temporary(), source = root.appendingPathComponent("正文.md")
        try Data("原始内容".utf8).write(to: source)
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        var book = try await repo.openLocalFile(source).document
        book.edit(content: "应用编辑")
        try Data("其他应用修改".utf8).write(to: source)
        do { try await repo.save(book, writeSource: true); XCTFail("must detect external overwrite") } catch { }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "其他应用修改")
        var history = try await repo.recentHistory(); history.remove(book.id); try await repo.saveHistory(history)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let reloaded = try await repo.reloadLocalFile(book.id)
        XCTAssertEqual(reloaded.content, "其他应用修改")
    }
    func testBatchBookmarkPurgeIncludesSnapshotsAndNeverTouchesSource() async throws {
        let root = try temporary(), source = root.appendingPathComponent("书.txt")
        try Data("书签私密上下文".utf8).write(to: source)
        let repo = try LibraryRepository(root: root.appendingPathComponent("Library"))
        var book = try await repo.openLocalFile(source).document
        let a = ReadingBookmark(name: "甲", offset: 0, content: book.content), b = ReadingBookmark(name: "乙", offset: 1, content: book.content)
        book.bookmarks = [a,b]; book.advanceRevision(); try await repo.save(book)
        book.advanceRevision(); try await repo.save(book)
        try await repo.deleteBookmarks([a.id])
        let fresh = try await repo.load(book.id)
        XCTAssertEqual(fresh.bookmarks.map(\.id), [b.id])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "书签私密上下文")
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Library/History/\(book.id.uuidString)"), includingPropertiesForKeys: nil) {
            let old = try JSONDecoder().decode(Manuscript.self, from: Data(contentsOf: file))
            XCTAssertFalse(old.bookmarks.contains { $0.id == a.id })
        }
    }
}
