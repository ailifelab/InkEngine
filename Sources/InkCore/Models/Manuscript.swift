import Foundation
import CryptoKit

public enum TextFormat: String, Codable, Sendable, CaseIterable {
    case txt, markdown, sql, csv, tsv, java, javascript, yaml, json, xml, html
    public var fileExtension: String { self == .markdown ? "md" : self == .javascript ? "js" : rawValue }
    public var label: String { self == .markdown ? "Markdown" : self == .javascript ? "JavaScript" : self == .java ? "Java" : rawValue.uppercased() }
    public static func detect(_ name: String) -> TextFormat {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext { case "md", "markdown": return .markdown; case "js", "mjs", "cjs": return .javascript; case "yml": return .yaml; case "htm": return .html; default: return TextFormat(rawValue: ext) ?? .txt }
    }
}

public enum InkError: LocalizedError, Equatable {
    case invalidDocument, tooLarge, invalidEncoding, invalidFrame, authentication, replay, unpaired
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "文稿数据或校验不正确，未覆盖本地文稿。"
        case .tooLarge: return "初版支持最多 20 MiB 的 UTF-8 文稿。请先拆分文件。"
        case .invalidEncoding: return "无法识别文件编码，请先转为 UTF-8 或 UTF-16 文本文件。"
        case .invalidFrame: return "接收到无效或过大的传输数据。"
        case .authentication: return "安全校验失败，请断开后重新配对。"
        case .replay: return "传输序列校验失败。"
        case .unpaired: return "请先在两台设备上确认配对。"
        }
    }
}

public struct Manuscript: Codable, Identifiable, Sendable, Equatable {
    public static let maximumBytes = 20 * 1024 * 1024
    public var id: UUID
    public var title: String
    public var format: TextFormat
    public var content: String
    public var revision: UUID
    public var ancestors: [UUID]
    public var updatedAt: Date
    public var cursor: Int // UTF-16 source position, shared with native text systems.
    public var trashedAt: Date?
    public var conflictOf: UUID?
    public var sourceName: String?
    public var fileName: String
    public var highlightOverride: TextFormat?
    public var bookmarks: [ReadingBookmark]
    public var highlightFormat: TextFormat { highlightOverride ?? TextFormat.detect(fileName) }

    public init(id: UUID = UUID(), title: String, format: TextFormat = .markdown, content: String = "", cursor: Int = 0) {
        self.id = id; self.title = title; self.format = format; self.content = content
        revision = UUID(); ancestors = []; updatedAt = Date(); self.cursor = cursor
        fileName = Self.suggestedFileName(title: title, format: format); bookmarks = []
    }

    private enum CodingKeys: String, CodingKey { case id, title, format, content, revision, ancestors, updatedAt, cursor, trashedAt, conflictOf, sourceName, fileName, highlightOverride, bookmarks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        format = try c.decode(TextFormat.self, forKey: .format); content = try c.decode(String.self, forKey: .content)
        revision = try c.decode(UUID.self, forKey: .revision); ancestors = try c.decode([UUID].self, forKey: .ancestors)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt); cursor = try c.decode(Int.self, forKey: .cursor)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt); conflictOf = try c.decodeIfPresent(UUID.self, forKey: .conflictOf)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? Self.suggestedFileName(title: title, format: format)
        highlightOverride = try c.decodeIfPresent(TextFormat.self, forKey: .highlightOverride)
        bookmarks = try c.decodeIfPresent([ReadingBookmark].self, forKey: .bookmarks) ?? []
    }
    public mutating func advanceRevision() { ancestors.append(revision); revision = UUID(); updatedAt = Date() }
    public mutating func configure(fileName: String, highlightOverride: TextFormat?) throws {
        guard Self.validFileName(fileName) else { throw InkError.invalidDocument }
        guard self.fileName != fileName || self.highlightOverride != highlightOverride else { return }
        advanceRevision(); self.fileName = fileName; self.highlightOverride = highlightOverride
        format = TextFormat.detect(fileName); title = (fileName as NSString).deletingPathExtension
    }
    public static func validFileName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." && name.utf8.count <= 240 && !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline || $0.unicodeScalars.contains(where: { $0.value < 32 }) })
    }
    public static func suggestedFileName(title: String, format: TextFormat) -> String {
        var stem = title.map { character in
            character == "/" || character == "\\" || character == ":" || character.isNewline || character.unicodeScalars.contains(where: { $0.value < 32 }) ? "_" : String(character)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.utf8.count > 200 { stem.removeLast() }
        if stem.isEmpty || stem == "." || stem == ".." { stem = "文稿" }
        return stem + "." + format.fileExtension
    }

    public var checksum: String { Self.digest(content) }
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func edit(content: String, title: String? = nil) {
        guard content != self.content || (title != nil && title != self.title) else { return }
        let relocation = AnchorRelocation(old: self.content, new: content)
        let wasEmpty = self.content.isEmpty
        cursor = wasEmpty ? 0 : relocation.map(cursor)
        for index in bookmarks.indices { bookmarks[index].offset = wasEmpty ? 0 : relocation.map(bookmarks[index].offset, context: bookmarks[index].context); bookmarks[index].context = ReadingBookmark.context(in: content, at: bookmarks[index].offset) }
        advanceRevision(); self.content = content
        if let title { self.title = title }
        cursor = min(max(0, cursor), content.utf16.count)
    }

    public func validated() throws -> Manuscript {
        guard content.utf8.count <= Self.maximumBytes else { throw InkError.tooLarge }
        guard !title.isEmpty, title.utf8.count <= 1024, ancestors.count <= 100_000,
              Self.validFileName(fileName), bookmarks.count <= 10_000,
              Set(bookmarks.map(\.id)).count == bookmarks.count,
              bookmarks.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1024 && $0.context.utf16.count <= 120 && $0.offset >= 0 && $0.offset <= content.utf16.count }),
              cursor >= 0, cursor <= content.utf16.count else { throw InkError.invalidDocument }
        return self
    }

    public var summary: BookSummary {
        BookSummary(id: id, title: title, format: format, updatedAt: updatedAt, cursor: cursor,
                    length: content.utf16.count, trashedAt: trashedAt, conflictOf: conflictOf, fileName: fileName)
    }
}

public struct BookSummary: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var format: TextFormat
    public var updatedAt: Date
    public var cursor: Int
    public var length: Int
    public var trashedAt: Date?
    public var conflictOf: UUID?
    public var fileName: String
}

public enum MergeDecision: Equatable, Sendable { case same, acceptRemote, keepLocal, conflict }

public enum SyncResolver {
    public static func decide(local: Manuscript, remote: Manuscript) -> MergeDecision {
        guard local.id == remote.id else { return .conflict }
        if local.checksum == remote.checksum && local.title == remote.title && local.format == remote.format && local.fileName == remote.fileName && local.highlightOverride == remote.highlightOverride && local.bookmarks == remote.bookmarks { return .same }
        if remote.ancestors.contains(local.revision) { return .acceptRemote }
        if local.ancestors.contains(remote.revision) { return .keepLocal }
        return .conflict
    }
}
