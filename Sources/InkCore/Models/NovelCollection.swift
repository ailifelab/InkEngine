import Foundation

/// 小说目录保存文稿引用；别名只用于管理界面，不会重命名源文件。
public struct NovelCollection: Codable, Identifiable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var documentID: UUID
        public var relativePath: String
        public var includedInReading: Bool
        public init(documentID: UUID, relativePath: String, includedInReading: Bool = true) {
            self.documentID = documentID; self.relativePath = relativePath; self.includedInReading = includedInReading
        }
    }
    public var id: UUID
    public var alias: String
    public var sourceFolder: String?
    public var sourceFolderBookmark: Data?
    public var entries: [Entry]
    public init(id: UUID = UUID(), alias: String, sourceFolder: String? = nil, entries: [Entry] = []) {
        self.id = id; self.alias = alias; self.sourceFolder = sourceFolder; self.entries = entries
    }
    public func orderedBooks(from books: [BookSummary], readingOnly: Bool = false) -> [BookSummary] {
        let indexed = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
        return entries.filter { !readingOnly || $0.includedInReading }.compactMap { entry -> (BookSummary, String, Bool)? in
            guard let book = indexed[entry.documentID], book.trashedAt == nil else { return nil }
            let directory = (entry.relativePath as NSString).deletingLastPathComponent
            return (book, directory.isEmpty ? book.fileName : directory + "/" + book.fileName, entry.includedInReading)
        }.sorted {
            if $0.2 != $1.2 { return $0.2 }
            let comparison = $0.1.compare($1.1, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "zh_Hans_CN"))
            return comparison == .orderedSame ? $0.0.id.uuidString < $1.0.id.uuidString : comparison == .orderedAscending
        }.map { $0.0 }
    }
    public func nextChapter(after id: UUID, books: [BookSummary]) -> BookSummary? {
        let chapters = orderedBooks(from: books, readingOnly: true)
        guard let index = chapters.firstIndex(where: { $0.id == id }), chapters.indices.contains(index + 1) else { return nil }
        return chapters[index + 1]
    }
    /// 仅显示当前目录的直接子项；按路径组件匹配，避免把“卷一续”归入“卷一”。
    public func directoryContents(at path: String = "", books: [BookSummary]) -> (directories: [String], files: [BookSummary]) {
        let prefix = path.isEmpty ? "" : path + "/"
        let live = Dictionary(books.filter { $0.trashedAt == nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var directories = Set<String>(), direct = Set<UUID>()
        for entry in entries where live[entry.documentID] != nil && entry.relativePath.hasPrefix(prefix) {
            let remaining = String(entry.relativePath.dropFirst(prefix.count))
            if let slash = remaining.firstIndex(of: "/") { directories.insert(prefix + remaining[..<slash]) }
            else { direct.insert(entry.documentID) }
        }
        return (directories.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, orderedBooks(from: books).filter { direct.contains($0.id) })
    }
    public static func isReadingChapter(fileName: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        return !["章节目录", "目录", "toc", "readme", "说明", "大纲", "人物设定", "设定"].contains(stem)
    }
}

public struct FolderImportReceipt: Sendable {
    public var collection: NovelCollection
    public var skippedFiles: Int
    public var reused: Bool
}

public enum CollectionError: LocalizedError {
    case emptyFolder, invalidAlias
    public var errorDescription: String? {
        switch self { case .emptyFolder: return L10n.tr("目录中没有支持的文本文件。"); case .invalidAlias: return L10n.tr("请输入不超过 200 个字的小说名称。") }
    }
}
