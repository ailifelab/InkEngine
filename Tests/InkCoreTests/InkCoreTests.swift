import XCTest
import CryptoKit
@testable import InkCore

final class InkCoreTests: XCTestCase {
    private func repository() throws -> LibraryRepository {
        try LibraryRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("InkTests-\(UUID())"))
    }
    func testSourceLineIndexKeepsLogicalLinesAndUTF16Offsets() {
        let text = "中文😀\r\n\r\n第三行\u{2028}尾\n"
        let index = SourceLineIndex(text)
        XCTAssertEqual(index.starts, [0, 6, 8, 12, 14])
        XCTAssertEqual(index.line(at: 4), 0)
        XCTAssertEqual(index.line(at: 6), 1)
        XCTAssertEqual(index.line(at: 9), 2)
        XCTAssertEqual(index.line(at: 14), 4)
        XCTAssertEqual(index.line(at: 999), 4)
        XCTAssertEqual(index.line(at: -1), 0)
        XCTAssertEqual(SourceLineIndex("").starts, [0])
        let long = SourceLineIndex(String(repeating: "😀中文\n", count: 100_000))
        XCTAssertEqual(long.starts.count, 100_001)
        XCTAssertEqual(long.line(at: 500_000), 100_000)
    }

    func testAtomicSaveReloadAndHistory() async throws {
        let repo = try repository()
        var book = Manuscript(title: "小说", content: "最初的正文😀")
        try await repo.save(book)
        let first = book.revision
        book.edit(content: "修改后的正文😀"); book.cursor = 4
        try await repo.save(book)
        let reloaded = try await repo.load(book.id)
        XCTAssertEqual(reloaded, book); XCTAssertTrue(reloaded.ancestors.contains(first))
        let root = await repo.root
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("History/\(book.id.uuidString)"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
    }
    func testPositionSidecarPreservesRevisionAndRejectsStalePosition() async throws {
        let repo = try repository()
        var book = Manuscript(title: "小说", content: "正文😀和阅读位置")
        try await repo.save(book)
        try await repo.savePosition(id: book.id, revision: book.revision, cursor: 4)
        let positioned = try await repo.load(book.id)
        XCTAssertEqual(positioned.cursor, 4); XCTAssertEqual(positioned.revision, book.revision); XCTAssertEqual(positioned.content, book.content)
        let oldRevision = book.revision
        book.edit(content: "修改后"); book.cursor = 1; try await repo.save(book)
        try await repo.savePosition(id: book.id, revision: oldRevision, cursor: 999)
        let fresh = try await repo.load(book.id); XCTAssertEqual(fresh.cursor, 1)
    }
    func testImportCopyTrashAndRecoveryPreserveOriginal() async throws {
        let repo = try repository()
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        let content = "# 小说\r\n\r\n你好😀"
        try Data(content.utf8).write(to: original)
        let receipt = try await repo.importFile(original)
        var edited = receipt.document; edited.edit(content: "只改副本")
        try await repo.save(edited)
        try await repo.setTrashed(edited.id, trashed: true)
        let trashed = try await repo.load(edited.id); XCTAssertNotNil(trashed.trashedAt)
        try await repo.setTrashed(edited.id, trashed: false)
        let restored = try await repo.load(edited.id); XCTAssertNil(restored.trashedAt); XCTAssertEqual(restored.content, "只改副本")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), content)
    }
    func testUTF16ImportAndInvalidEncoding() async throws {
        let repo = try repository()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try "中文😀".data(using: .utf16)!.write(to: file)
        let receipt = try await repo.importFile(file); XCTAssertEqual(receipt.document.content, "中文😀")
        try Data([0xff, 0x81, 0x82]).write(to: file)
        do { _ = try await repo.importFile(file); XCTFail("invalid encoding accepted") } catch { XCTAssertEqual(error as? InkError, .invalidEncoding) }
    }
    func testFastForwardAndConflictNeverOverwrite() async throws {
        let repo = try repository()
        let original = Manuscript(title: "小说", content: "原稿")
        try await repo.save(original)
        var remote = original; remote.edit(content: "手机修改")
        let (_, forward) = try await repo.receive(remote, checksum: remote.checksum); XCTAssertEqual(forward, .acceptRemote)
        var local = remote; local.edit(content: "Mac修改"); try await repo.save(local)
        var divergent = remote; divergent.edit(content: "iPad修改")
        let (conflict, decision) = try await repo.receive(divergent, checksum: divergent.checksum)
        XCTAssertEqual(decision, .conflict); XCTAssertEqual(conflict.conflictOf, original.id)
        XCTAssertNotEqual(conflict.id, original.id)
        let saved = try await repo.load(original.id); XCTAssertEqual(saved.content, "Mac修改")
        let savedConflict = try await repo.load(conflict.id); XCTAssertEqual(savedConflict.content, "iPad修改")
    }
    func testSameContentPositionAndOlderVersion() async throws {
        let repo = try repository(); var local = Manuscript(title: "小说", content: "内容")
        let old = local; local.edit(content: "新内容"); try await repo.save(local)
        let (_, decision) = try await repo.receive(old, checksum: old.checksum); XCTAssertEqual(decision, .keepLocal)
        var same = local; same.cursor = 2
        let (positioned, equal) = try await repo.receive(same, checksum: same.checksum)
        XCTAssertEqual(equal, .same); XCTAssertEqual(positioned.cursor, 2)
    }
    func testChecksumFailureAndTrashReceive() async throws {
        let repo = try repository(); let book = Manuscript(title: "书", content: "原稿")
        try await repo.save(book)
        do { _ = try await repo.receive(book, checksum: "fake"); XCTFail() } catch { XCTAssertEqual(error as? InkError, .invalidDocument) }
        try await repo.setTrashed(book.id, trashed: true)
        let (copy, decision) = try await repo.receive(book, checksum: book.checksum)
        XCTAssertEqual(decision, .conflict); XCTAssertNotEqual(copy.id, book.id)
        let original = try await repo.load(book.id); XCTAssertNotNil(original.trashedAt)
    }
    func testMarkdownSpeechMappingAndCode() {
        let source = "# 第一章\r\n\r\n**你好😀** [世界](https://example.org) ![图片](a.png)\n```swift\nprint(42)\n```\n第二章 归来\n"
        let parsed = TextParser.parse(source, format: .markdown)
        XCTAssertEqual(parsed.chapters.count, 2)
        let prose = parsed.segments[1]
        XCTAssertEqual(prose.text, "你好😀 世界 ")
        XCTAssertEqual(prose.sourceOffsets.count, prose.text.utf16.count)
        let range = prose.sourceRange(forSpoken: NSRange(location: 0, length: 4))!
        XCTAssertEqual((source as NSString).substring(with: range), "你好😀")
        XCTAssertTrue(parsed.segments[2].isCode)
        XCTAssertFalse(parsed.segments.last!.isCode)
        XCTAssertEqual(parsed.segmentIndex(at: range.location), 1)
    }
    func testLongNovelBoundedChunksAndUTF16() {
        let line = String(repeating: "很长的句子😀。", count: 2000)
        let source = "# 第一章\n" + String(repeating: line + "\n\n", count: 100)
        let start = Date(); let parsed = TextParser.parse(source, format: .markdown)
        XCTAssertFalse(parsed.segments.isEmpty)
        for segment in parsed.segments {
            XCTAssertLessThanOrEqual(segment.text.utf16.count, 800)
            XCTAssertEqual(segment.text.utf16.count, segment.sourceOffsets.count)
            XCTAssertFalse(segment.text.contains("\u{fffd}"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
        XCTAssertEqual(TextParser.search("第一章", in: source).count, 1)
    }
    func testSearchLimitAndEmpty() {
        XCTAssertEqual(TextParser.search("", in: "123"), [])
        XCTAssertEqual(TextParser.search("字", in: String(repeating: "字", count: 500)).count, 200)
    }
    func testEncryptedRoundTripReplayTamperAndReflection() throws {
        let a = try SessionHandshake(identity: .init(), deviceID: UUID(), name: "Mac")
        let b = try SessionHandshake(identity: .init(), deviceID: UUID(), name: "iPhone")
        let sender = try a.establish(with: b.hello), receiver = try b.establish(with: a.hello)
        XCTAssertEqual(sender.pairingCode, receiver.pairingCode)
        let book = Manuscript(title: "测试", content: "保密正文😀", cursor: 2)
        let packet = try sender.seal(TransferMessage(.document, document: book, transferID: UUID()))
        XCTAssertFalse(String(decoding: packet, as: UTF8.self).contains(book.content))
        XCTAssertEqual(try receiver.open(packet).document, book)
        XCTAssertThrowsError(try receiver.open(packet)) { XCTAssertEqual($0 as? InkError, .replay) }
        XCTAssertThrowsError(try sender.open(packet)) // Separate directional keys block reflection.
        let valid = try receiver.seal(TransferMessage(.receipt, note: "保存"))
        var tampered = valid; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try sender.open(tampered))
        XCTAssertEqual(try sender.open(valid).note, "保存")
    }
    func testHelloCannotBeForged() throws {
        let a = try SessionHandshake(identity: .init(), deviceID: UUID(), name: "Mac")
        var invalid = a.hello; invalid.signature = Data(repeating: 0, count: 64)
        XCTAssertThrowsError(try invalid.verify())
        let b = try SessionHandshake(identity: .init(), deviceID: a.hello.deviceID, name: "copy")
        XCTAssertThrowsError(try b.establish(with: a.hello))
    }
    func testFramingFragmentationMultipleAndInvalidLength() throws {
        let first = Data("one".utf8), second = Data("two😀".utf8)
        let wire = try FrameDecoder.frame(first) + FrameDecoder.frame(second)
        var decoder = FrameDecoder(), decoded: [Data] = []
        for byte in wire { decoded += try decoder.append(Data([byte])) }
        XCTAssertEqual(decoded, [first, second])
        var invalid = FrameDecoder(); XCTAssertThrowsError(try invalid.append(Data([0xff, 0xff, 0xff, 0xff])))
        XCTAssertThrowsError(try FrameDecoder.frame(Data()))
    }
}
