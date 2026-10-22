import Foundation

public struct ImportReceipt: Sendable {
    public var document: Manuscript
    public var message: String
}

/// 外部文件的候选更新尚未写入缓存或更新磁盘基线，编辑器可先确认没有并发输入。
public struct LocalFileUpdate: Sendable {
    public var document: Manuscript
    fileprivate var reference: LocalFileReference
}

/// 文稿持久化边界：统一串行处理正式正文、恢复草稿、来源授权和位置元数据。
/// 外部文件只有在显式正式保存时写回，缓存刷新不得改变文稿身份或用户删除决定。
public actor LibraryRepository {
    private struct Position: Codable { var revision: UUID; var cursor: Int }
    public let root: URL
    public let documentsDirectory: URL?
    public internal(set) var documentsDirectoryIssues: [String] = []
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private struct CachedSummary { let modified: Date?; let size: Int?; let revision: UUID; var summary: BookSummary }
    private var summaryCache: [UUID: CachedSummary] = [:]
    /// 目录指纹用于发现新增、删除和重命名；正文内容变更由原文件监听单独处理。
    /// 同时记录 inode、大小和修改时间，避免目录被原子替换后错误复用旧扫描。
    private struct DirectoryStamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
        init(_ url: URL) throws {
            var attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date else { throw InkError.invalidDocument }
            self.inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            self.size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            self.modified = modified
        }
    }
    /// 扫描前记录全部子目录指纹，扫描中发生的变化会在下一轮使缓存失效。
    /// 仅复用目录枚举结果，不缓存正文，也不跨目录授权或目录元数据变更复用。
    private struct LinkedFolderScan {
        let collection: NovelCollection
        let path: String
        let directories: [(url: URL, stamp: DirectoryStamp)]
        func isCurrent(_ collection: NovelCollection, source: URL) -> Bool {
            self.collection == collection && path == source.resolvingSymlinksInPath().standardizedFileURL.path &&
                directories.allSatisfy { (try? DirectoryStamp($0.url)) == $0.stamp }
        }
    }
    private var linkedFolderScans: [UUID: LinkedFolderScan] = [:]

    /// 创建或打开私有书库；documentsDirectory 指定移动端可见文稿目录，nil 表示只关联原文件。
    public init(root: URL, documentsDirectory: URL? = nil) throws {
        self.root = root
        self.documentsDirectory = documentsDirectory
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("History"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Positions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Collections"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        if let documentsDirectory { try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true) }
        #if os(iOS)
        // 锁屏后仍需读取下一章和进度；既有导入文件也统一为首次解锁后可访问。
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let file as URL in files {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            }
        }
        #endif
    }

    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathExtension("ink") }

    /// 读取最近打开及固定历史；历史记录与文稿正文分开保存。
    public func recentHistory() throws -> RecentHistory {
        let file = root.appendingPathComponent("Recent.json")
        if let data = try? Data(contentsOf: file) { return try decoder.decode(RecentHistory.self, from: data) }
        var history = RecentHistory()
        let folders = try collections(), grouped = Set(folders.flatMap { $0.entries.map(\.documentID) })
        for folder in folders { history.opened(.init(id: folder.id, isFolder: true, openedAt: .distantPast)) }
        for book in try list().filter({ $0.trashedAt == nil && !grouped.contains($0.id) }).reversed() {
            history.opened(.init(id: book.id, openedAt: book.updatedAt))
        }
        try saveHistory(history); return history
    }
    /// 原子保存历史顺序与显隐信息，不删除对应正文。
    public func saveHistory(_ history: RecentHistory) throws {
        try encoder.encode(history).write(to: root.appendingPathComponent("Recent.json"), options: .atomic)
    }
    private func referenceURL(_ id: UUID) -> URL { root.appendingPathComponent("Sources/\(id.uuidString).json") }
    private func reference(_ id: UUID) -> LocalFileReference? {
        guard let data = try? Data(contentsOf: referenceURL(id)) else { return nil }
        return try? decoder.decode(LocalFileReference.self, from: data)
    }
    /// 返回已关联的原文件路径；未关联时返回 nil，不请求文件授权。
    public func sourcePath(_ id: UUID) -> String? { reference(id)?.path }
    /// 使用安全书签解析实际文件位置，保持移动文件后的路径和相邻资源关系。
    /// 解析原文件的持久授权书签；调用方负责成对开启、释放安全作用域。
    public func sourceURL(_ id: UUID) throws -> URL? { try reference(id)?.resolved() }
    /// 为现有文稿建立原文件关联，保留文稿身份和恢复记录。
    public func attachSource(_ source: URL, to id: UUID) throws {
        let book = try load(id), ref = try LocalFileReference(url: source, content: book.content)
        try encoder.encode(ref).write(to: referenceURL(id), options: .atomic)
    }
    /// 导入或重新聚焦原文件；返回文稿及是否已有记录，避免重复身份。
    public func openLocalFile(_ source: URL) throws -> ImportReceipt {
        if let file = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil).first(where: { file in
            guard let data = try? Data(contentsOf: file), let ref = try? decoder.decode(LocalFileReference.self, from: data) else { return false }
            return URL(fileURLWithPath: ref.path).standardizedFileURL == source.standardizedFileURL
                || (try? ref.resolved().standardizedFileURL) == source.standardizedFileURL
        }), let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
            // 用户重新选择的 URL 带有本次授权。即使正文没变，也必须更新安全书签，
            // 否则选择器的临时授权结束后仍会使用升级前已失效的书签。
            return .init(document: try reconnectLocalFile(source, to: id), message: L10n.tr("已打开原文件 · 编辑会保存回原文件"))
        }
        let book = try decodedFile(source); try save(book); try attachSource(source, to: book.id)
        return .init(document: book, message: L10n.tr("已打开原文件 · 编辑会保存回原文件"))
    }
    /// 用户明确重新选择原文件时恢复关联，沿用文稿身份、书签与阅读位置。
    /// 将重新授权的文件关联到指定文稿，保留原文稿身份。
    public func reconnectLocalFile(_ source: URL, to id: UUID) throws -> Manuscript {
        guard let update = try localFileUpdate(id, selectedSource: source) else { throw InkError.invalidDocument }
        try acceptLocalFileUpdate(update)
        return update.document
    }

    /// 重新选择原目录时，先验证所有候选，再更新已有文稿的关联。
    /// 改名章节只在同一子目录内按唯一章号匹配；歧义不能覆盖现有关联。
    /// 按目录和章节特征重新关联失效来源；候选不唯一时拒绝猜测。
    public func reconnectFolderSources(_ source: URL) throws -> Int {
        let folder = source.resolvingSymlinksInPath().standardizedFileURL
        let prefix = folder.path + "/"
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var chapters: [String: [URL]] = [:]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw CollectionError.emptyFolder }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { files.skipDescendants(); continue }
            let normalized = file.standardizedFileURL
            if values.isRegularFile == true, let key = Self.chapterSourceKey(normalized) { chapters[key, default: []].append(normalized) }
        }
        var updates: [UUID: LocalFileUpdate] = [:], paths: [UUID: String] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let ref = reference(id) else { continue }
            let old = URL(fileURLWithPath: ref.path).standardizedFileURL
            guard old.path.hasPrefix(prefix) else { continue }
            let candidate: URL
            if FileManager.default.fileExists(atPath: old.path) { candidate = old }
            else if let key = Self.chapterSourceKey(old), let matches = chapters[key], matches.count == 1 { candidate = matches[0] }
            else { throw InkError.invalidDocument }
            let values = try candidate.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  candidate.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix),
                  let update = try localFileUpdate(id, selectedSource: candidate) else { throw InkError.invalidDocument }
            updates[id] = update
            paths[id] = String(candidate.path.dropFirst(prefix.count))
        }
        // 本轮不删除或新增章节，也不把目录中尚未导入的文件塞入历史记录。
        for update in updates.values { try acceptLocalFileUpdate(update) }
        for var collection in try collections() where collection.sourceFolder == folder.path {
            var changed = false
            for index in collection.entries.indices {
                if let path = paths[collection.entries[index].documentID], collection.entries[index].relativePath != path {
                    collection.entries[index].relativePath = path; changed = true
                }
            }
            if changed { try saveCollection(collection) }
        }
        return updates.count
    }

    private static func chapterSourceKey(_ file: URL) -> String? {
        guard ["md", "markdown"].contains(file.pathExtension.lowercased()) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix("第") else { return nil }
        let digits = stem.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), stem.dropFirst(1 + digits.count).hasPrefix("章") else { return nil }
        return file.deletingLastPathComponent().path + "/第\(number)章"
    }
    /// 只在文件事件或回到前台时核对；不对所有历史文件进行轮询。
    /// 比较原文件与已知摘要，判断是否需要提示外部更新。
    public func sourceHasChanges(_ id: UUID) throws -> Bool {
        guard let ref = reference(id) else { return false }
        let source = try ref.resolved(), access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Manuscript.maximumBytes { throw InkError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
        return ref.path != source.path || LocalFileReference.digest(data) != ref.diskDigest
    }
    /// 准备外部文件更新快照；不在检测阶段覆盖编辑缓冲区。
    public func localFileUpdate(_ id: UUID) throws -> LocalFileUpdate? {
        try localFileUpdate(id, selectedSource: nil)
    }
    /// 准备外部文件更新快照；不在检测阶段覆盖编辑缓冲区。
    private func localFileUpdate(_ id: UUID, selectedSource: URL?) throws -> LocalFileUpdate? {
        var book = try load(id)
        guard let ref = reference(id) else { return nil }
        let source = try selectedSource ?? ref.resolved(), access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Manuscript.maximumBytes { throw InkError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
        if selectedSource == nil, source.path == ref.path, source.lastPathComponent == book.fileName, book.checksum == ref.contentDigest, LocalFileReference.digest(data) == ref.diskDigest { return nil }
        let fresh = try decodedFile(source, data: data)
        book.edit(content: fresh.content)
        if book.fileName != source.lastPathComponent { try book.configure(fileName: source.lastPathComponent, highlightOverride: book.highlightOverride) }
        return LocalFileUpdate(document: book, reference: try LocalFileReference(url: source, content: fresh.content, data: data))
    }
    /// 提交已确认的外部更新；保持文件关联与版本一致。
    public func acceptLocalFileUpdate(_ update: LocalFileUpdate) throws {
        guard update.document.checksum == update.reference.contentDigest else { throw InkError.invalidDocument }
        try save(update.document)
        try encoder.encode(update.reference).write(to: referenceURL(update.document.id), options: .atomic)
    }
    /// 有外部更新则接纳，否则读取缓存正文及同版本阅读位置。
    public func reloadLocalFile(_ id: UUID) throws -> Manuscript {
        guard let update = try localFileUpdate(id) else { return try load(id) }
        try acceptLocalFileUpdate(update)
        return update.document
    }
    /// 汇总文稿书签；includeDeleted 决定是否包含软删除记录。
    public func allBookmarks(includeDeleted: Bool = false) throws -> [BookmarkRecord] {
        let folders = try collections()
        return try list().filter { $0.trashedAt == nil }.flatMap { summary in
            let folder = folders.first { $0.entries.contains { $0.documentID == summary.id } }
            return try load(summary.id).bookmarks.filter { includeDeleted || $0.deletedAt == nil }.map { BookmarkRecord(documentID: summary.id, fileName: summary.fileName, folderID: folder?.id, bookmark: $0) }
        }
    }
    /// 永久移除指定书签及历史快照中的摘录，避免清理后残留上下文。
    public func deleteBookmarks(_ ids: Set<UUID>) throws {
        for summary in try list() {
            var book = try load(summary.id)
            guard book.bookmarks.contains(where: { ids.contains($0.id) }) else { continue }
            // 删除所选书签的完整记录及上下文片段，避免清理后仍留下正文摘录。
            book.bookmarks.removeAll { ids.contains($0.id) }; book.advanceRevision(); try save(book)
            let snapshots = root.appendingPathComponent("History/\(book.id.uuidString)")
            for file in (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? [] {
                var old = try decoder.decode(Manuscript.self, from: Data(contentsOf: file))
                old.bookmarks.removeAll { ids.contains($0.id) }
                try encoder.encode(old).write(to: file, options: .atomic)
            }
        }
    }
    /// 统计所选文稿的历史快照占用；nil 表示全部文稿。
    public func snapshotCacheBytes(documentIDs: Set<UUID>? = nil) -> Int {
        let folder = root.appendingPathComponent("History")
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var bytes = 0
        for case let file as URL in files {
            if let ids = documentIDs, !ids.contains(where: { file.path.contains("/" + $0.uuidString + "/") }) { continue }
            let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if info?.isRegularFile == true { bytes += info?.fileSize ?? 0 }
        }
        return bytes
    }
    /// 清除所选历史快照缓存，不删除当前文稿与恢复草稿。
    public func clearSnapshotCache(documentIDs: Set<UUID>? = nil) throws {
        let folder = root.appendingPathComponent("History")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            if documentIDs == nil || UUID(uuidString: file.lastPathComponent).map({ documentIDs!.contains($0) }) == true { try FileManager.default.removeItem(at: file) }
        }
    }

    /// Mac 私有草稿在移出历史后随缓存清理。可见文稿、目录章节及原文件副本不参与。
    @discardableResult public func clearRemovedDrafts(documentIDs: Set<UUID>? = nil, protecting protectedIDs: Set<UUID> = []) throws -> Set<UUID> {
        guard documentsDirectory == nil else { return [] }
        let history = try recentHistory()
        var retained = protectedIDs.union(history.entries.map(\.id)).union(history.pinned)
        retained.formUnion(try workingDraftIDs())
        retained.formUnion(try collections().flatMap { $0.entries.map(\.documentID) })
        let sharedIndex = root.appendingPathComponent("SharedDocuments.json")
        if FileManager.default.fileExists(atPath: sharedIndex.path) {
            retained.formUnion(try decoder.decode(SharedDocumentsIndex.self, from: Data(contentsOf: sharedIndex)).files.map(\.id))
        }
        var removed = Set<UUID>()
        for summary in try list() where !retained.contains(summary.id) && (documentIDs == nil || documentIDs!.contains(summary.id)) {
            // 即便安全书签已损坏或原文件暂不可访问，也不能把原文件副本当作废弃草稿。
            guard !FileManager.default.fileExists(atPath: referenceURL(summary.id).path) else { continue }
            let book = try load(summary.id)
            guard book.sourceName == nil, book.conflictOf == nil else { continue }
            removed.insert(book.id)
        }
        guard !removed.isEmpty else { return [] }
        let manager = FileManager.default
        let staging = root.appendingPathComponent(".delete-drafts-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            for id in removed {
                for file in [url(id), root.appendingPathComponent("Positions/\(id.uuidString).json"), root.appendingPathComponent("History/\(id.uuidString)")] where manager.fileExists(atPath: file.path) {
                    let backup = staging.appendingPathComponent(UUID().uuidString)
                    try manager.moveItem(at: file, to: backup); moved.append((file, backup))
                }
            }
        } catch {
            for (file, backup) in moved.reversed() { try? manager.moveItem(at: backup, to: file) }
            if (try? manager.contentsOfDirectory(atPath: staging.path).isEmpty) == true { try? manager.removeItem(at: staging) }
            throw error
        }
        try manager.removeItem(at: staging)
        for id in removed { summaryCache.removeValue(forKey: id) }
        return removed
    }
    /// 清除指定文稿的全部书签；nil 表示全部，正文保持不变。
    public func purgeAllBookmarks(documentIDs: Set<UUID>? = nil) throws {
        var ids = Set<UUID>()
        for summary in try list() where documentIDs == nil || documentIDs!.contains(summary.id) {
            ids.formUnion(try load(summary.id).bookmarks.map(\.id))
        }
        try deleteBookmarks(ids)
    }

    /// 读取小说目录元数据；目录身份独立于历史记录显隐。
    public func collections() throws -> [NovelCollection] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Collections"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(NovelCollection.self, from: Data(contentsOf: $0)) }
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    /// 校验并原子保存目录及章节映射。
    public func saveCollection(_ value: NovelCollection) throws {
        let isNew = !FileManager.default.fileExists(atPath: root.appendingPathComponent("Collections/\(value.id.uuidString).json").path)
        let clean = value.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200, Set(value.entries.map(\.documentID)).count == value.entries.count else { throw CollectionError.invalidAlias }
        var collection = value; collection.alias = clean
        try encoder.encode(collection).write(to: root.appendingPathComponent("Collections/\(value.id.uuidString).json"), options: .atomic)
        if isNew {
            var recent = try recentHistory()
            for entry in collection.entries where !recent.pinned.contains(entry.documentID) { recent.remove(entry.documentID) }
            recent.opened(.init(id: collection.id, isFolder: true)); try saveHistory(recent)
        }
    }

    /// 全部文件验证成功后才写入资料库；失败时回滚本次新增副本。
    /// 导入小说目录；linkOriginals 控制关联原文件还是保留离线副本。
    public func importFolder(_ source: URL, alias: String, linkOriginals: Bool = false) throws -> FolderImportReceipt {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200 else { throw CollectionError.invalidAlias }
        let directory = source.resolvingSymlinksInPath().standardizedFileURL
        let canonical = directory.path
        if var previous = try collections().first(where: { $0.sourceFolder == canonical }) {
            if linkOriginals {
                _ = try reconnectFolderSources(source)
                previous = try collections().first(where: { $0.id == previous.id }) ?? previous
            }
            previous.alias = clean
            if linkOriginals { previous.sourceFolderBookmark = try folderBookmark(source) }
            let result = try addFolderFiles(source, to: previous, linkOriginals: linkOriginals)
            return FolderImportReceipt(collection: result.collection, skippedFiles: result.skipped, reused: true)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw CollectionError.emptyFolder }
        let allowed = Set(TextFormat.allCases.map(\.fileExtension) + ["markdown", "yml", "htm", "mjs", "cjs"])
        var documents: [(Manuscript, String)] = [], skipped = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); skipped += 1; continue }
            guard values.isRegularFile == true else { continue }
            guard allowed.contains(file.pathExtension.lowercased()) else { skipped += 1; continue }
            let book = try decodedFile(file)
            let normalized = file.standardizedFileURL
            guard normalized.path.hasPrefix(canonical + "/") else { throw InkError.invalidDocument }
            let relative = String(normalized.path.dropFirst(canonical.count + 1))
            documents.append((book, relative))
        }
        if let enumerationError { throw enumerationError }
        guard !documents.isEmpty else { throw CollectionError.emptyFolder }
        var collection = NovelCollection(alias: clean, sourceFolder: canonical, entries: documents.map { .init(documentID: $0.0.id, relativePath: $0.1, includedInReading: NovelCollection.isReadingChapter(fileName: $0.0.fileName)) })
        if linkOriginals { collection.sourceFolderBookmark = try folderBookmark(source) }
        let originalHistory = try recentHistory()
        do {
            for (book, relative) in documents {
                try Task.checkCancellation(); try save(book)
                if linkOriginals { try attachSource(directory.appendingPathComponent(relative), to: book.id) }
            }
            try saveCollection(collection)
        } catch {
            for (book, _) in documents {
                try? FileManager.default.removeItem(at: url(book.id))
                try? FileManager.default.removeItem(at: root.appendingPathComponent("Positions/\(book.id.uuidString).json"))
                try? FileManager.default.removeItem(at: referenceURL(book.id))
            }
            try? saveHistory(originalHistory)
            throw error
        }
        return FolderImportReceipt(collection: collection, skippedFiles: skipped, reused: false)
    }

    /// 用户显式选择的根目录可为符号链接；先解析真实目标，再建立持久授权。
    /// 子目录枚举仍跳过符号链接，避免意外越出用户选定的目录树。
    private func folderBookmark(_ source: URL) throws -> Data {
        let directory = source.resolvingSymlinksInPath().standardizedFileURL
        #if os(macOS)
        return try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try directory.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// 解析目录授权；离线副本不自动变为与外部目录关联的文稿。
    public func linkedFolderURL(_ collection: NovelCollection) throws -> URL? {
        guard let path = collection.sourceFolder else { return nil }
        if let bookmark = collection.sourceFolderBookmark {
            var stale = false
            #if os(macOS)
            return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            return try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
        }
        // Older linked collections have per-file bookmarks only. Use their path
        // while access remains available; never turn offline copies into links.
        guard collection.entries.contains(where: { reference($0.documentID) != nil }) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 只发现新增文件，不重载已有正文、未保存草稿或阅读位置。
    /// 已移除的历史记录保持移除；外部目录暂时不可用时保留缓存。
    /// 增量发现关联目录的新章节；保留既有正文、身份、书签及已删除的历史状态。
    @discardableResult public func refreshLinkedFolders() throws -> Set<UUID> {
        var added = Set<UUID>()
        let folders = try collections()
        linkedFolderScans = linkedFolderScans.filter { id, _ in folders.contains { $0.id == id } }
        for collection in folders {
            guard let source = try? linkedFolderURL(collection) else { continue }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.isReadableFile(atPath: source.path) else { continue }
            if linkedFolderScans[collection.id]?.isCurrent(collection, source: source) == true { continue }
            let updated = try addFolderFiles(source, to: collection, linkOriginals: true).collection
            added.formUnion(Set(updated.entries.map(\.documentID)).subtracting(collection.entries.map(\.documentID)))
        }
        return added
    }

    /// 返回需要监听的根目录和子目录；复用有效扫描结果并跳过子符号链接。
    public func linkedFolderDirectories() throws -> [URL] {
        var directories: [URL] = []
        for collection in try collections() {
            guard let source = try? linkedFolderURL(collection) else { continue }
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.isReadableFile(atPath: source.path) else { continue }
            if let cached = linkedFolderScans[collection.id], cached.isCurrent(collection, source: source) {
                directories += cached.directories.map(\.url)
                continue
            }
            directories.append(source)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            if let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let file as URL in files {
                    let values = try file.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true { files.skipDescendants(); continue }
                    if values.isDirectory == true { directories.append(file) }
                }
            }
        }
        return directories
    }

    /// 只追加新文件，既有章节的身份和正文保持不变；重命名候选交由重新关联处理。
    /// 先完整扫描和校验再提交，任一新增文件失败时回滚新增记录及目录映射。
    private func addFolderFiles(_ source: URL, to original: NovelCollection, linkOriginals: Bool) throws -> (collection: NovelCollection, skipped: Int) {
        let directory = source.resolvingSymlinksInPath().standardizedFileURL
        let prefix = directory.path + "/"
        let known = Set(original.entries.map(\.relativePath))
        // A renamed chapter must be reconciled under its existing identity by
        // reconnectFolderSources, rather than imported a second time on refresh.
        let missingChapterKeys = Set(original.entries.compactMap { entry -> String? in
            let file = directory.appendingPathComponent(entry.relativePath)
            return FileManager.default.fileExists(atPath: file.path) ? nil : Self.chapterSourceKey(file)
        })
        let allowed = Set(TextFormat.allCases.map(\.fileExtension) + ["markdown", "yml", "htm", "mjs", "cjs"])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        // Capture stamps before visiting children. A mutation during enumeration
        // then invalidates this snapshot on the next refresh rather than hiding it.
        var directories: [(url: URL, stamp: DirectoryStamp)] = [(source, try DirectoryStamp(source))]
        var scanError: Error?
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in scanError = error; return false }) else { throw CollectionError.emptyFolder }
        var additions: [(Manuscript, URL, String)] = [], skipped = 0
        for case let file as URL in files {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { files.skipDescendants(); skipped += 1; continue }
            if values.isDirectory == true {
                directories.append((file, try DirectoryStamp(file)))
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard allowed.contains(file.pathExtension.lowercased()) else { skipped += 1; continue }
            let normalized = file.standardizedFileURL
            guard normalized.path.hasPrefix(prefix) else { throw InkError.invalidDocument }
            let relative = String(normalized.path.dropFirst(prefix.count))
            guard !known.contains(relative) else { continue }
            if let key = Self.chapterSourceKey(normalized), missingChapterKeys.contains(key) { continue }
            additions.append((try decodedFile(normalized), normalized, relative))
        }
        if let scanError { throw scanError }
        guard !additions.isEmpty else {
            if try collections().first(where: { $0.id == original.id }) != original { try saveCollection(original) }
            if linkOriginals { linkedFolderScans[original.id] = LinkedFolderScan(collection: original, path: directory.path, directories: directories) }
            return (original, skipped)
        }
        let history = try recentHistory()
        let previous = try collections().first { $0.id == original.id }
        var updated = original
        do {
            for (book, file, relative) in additions {
                try save(book)
                if linkOriginals { try attachSource(file, to: book.id) }
                updated.entries.append(.init(documentID: book.id, relativePath: relative, includedInReading: NovelCollection.isReadingChapter(fileName: file.lastPathComponent)))
            }
            try saveCollection(updated)
            try saveHistory(history)
            if linkOriginals { linkedFolderScans[updated.id] = LinkedFolderScan(collection: updated, path: directory.path, directories: directories) }
        } catch {
            for (book, _, _) in additions {
                for file in [url(book.id), referenceURL(book.id), root.appendingPathComponent("Positions/\(book.id.uuidString).json")] { try? FileManager.default.removeItem(at: file) }
                summaryCache.removeValue(forKey: book.id)
            }
            if let previous { try? saveCollection(previous) }
            try? saveHistory(history)
            throw error
        }
        return (updated, skipped)
    }

    /// 读取文稿摘要并复用有效缓存，避免每次刷新解析全部正文。
    public func list() throws -> [BookSummary] {
        // 历史列表只缓存小型摘要，正文仍按打开的文件读取。原子写入后以文件
        // 时间与大小使摘要失效；阅读位置从小型位置文件读取，不重复解码整本小说。
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "ink" }
        var seen = Set<UUID>()
        let summaries = try files.map { file in
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw InkError.invalidDocument }
                seen.insert(id)
                let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                var summary: BookSummary
                if let cached = summaryCache[id], cached.modified == stamp.contentModificationDate, cached.size == stamp.fileSize { summary = cached.summary }
                else {
                    let book = try load(id); summary = book.summary
                    summaryCache[id] = CachedSummary(modified: stamp.contentModificationDate, size: stamp.fileSize, revision: book.revision, summary: summary)
                }
                let positionURL = root.appendingPathComponent("Positions/\(id.uuidString).json")
                if let data = try? Data(contentsOf: positionURL), let position = try? decoder.decode(Position.self, from: data), position.revision == summaryCache[id]?.revision { summary.cursor = min(max(0, position.cursor), summary.length) }
                return summary
            }
        summaryCache = summaryCache.filter { seen.contains($0.key) }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 读取并校验正文，再叠加相同 revision 的最新阅读位置。
    public func load(_ id: UUID) throws -> Manuscript {
        restoringPosition(in: try decoder.decode(Manuscript.self, from: Data(contentsOf: url(id))).validated())
    }

    // Formal copies and recovery drafts share the same revision-scoped position.
    // Reading can advance without rewriting a large draft or its unsaved body.
    /// 只合并同一版本的位置，并限制在正文 UTF-16 边界内，防止旧位置跨版本套用。
    func restoringPosition(in manuscript: Manuscript) -> Manuscript {
        var book = manuscript
        let positionURL = root.appendingPathComponent("Positions/\(book.id.uuidString).json")
        if let data = try? Data(contentsOf: positionURL), let position = try? decoder.decode(Position.self, from: data), position.revision == book.revision {
            book.cursor = min(max(0, position.cursor), book.content.utf16.count)
        }
        return book
    }

    // 阅读位置单独保存，长篇小说也只写少量元数据，不改写或重读正文。
    /// 单独原子写入阅读位置；不改写长正文，revision 用于恢复时排除过期位置。
    public func savePosition(id: UUID, revision: UUID, cursor: Int) throws {
        guard cursor >= 0 else { throw InkError.invalidDocument }
        let positionURL = root.appendingPathComponent("Positions/\(id.uuidString).json")
        try encoder.encode(Position(revision: revision, cursor: cursor)).write(to: positionURL, options: .atomic)
    }

    /// 保存正式文稿；只有 writeSource 为 true 时才同步写回已关联的原文件。
    public func save(_ manuscript: Manuscript, writeSource: Bool = false) throws {
        let book = try manuscript.validated()
        if writeSource, var ref = reference(book.id), ref.contentDigest != book.checksum {
            try ref.write(book.content)
            try encoder.encode(ref).write(to: referenceURL(book.id), options: .atomic)
        }
        let destination = url(book.id)
        let existed = FileManager.default.fileExists(atPath: destination.path)
        if existed {
            let previous = try load(book.id)
            if previous.revision != book.revision {
                let history = root.appendingPathComponent("History").appendingPathComponent(book.id.uuidString)
                try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
                try encoder.encode(previous).write(to: history.appendingPathComponent(previous.revision.uuidString + ".ink"), options: .atomic)
                let snapshots = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: [.contentModificationDateKey])
                    .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
                for old in snapshots.dropFirst(20) { try FileManager.default.removeItem(at: old) }
            }
        }
        try encoder.encode(book).write(to: destination, options: .atomic)
        summaryCache.removeValue(forKey: book.id)
        try savePosition(id: book.id, revision: book.revision, cursor: book.cursor)
        if !existed {
            var recent = try recentHistory(); recent.opened(.init(id: book.id)); try saveHistory(recent)
        }
    }

    /// 导入单个支持格式的文件并返回导入结果。
    public func importFile(_ source: URL) throws -> ImportReceipt {
        let book = try decodedFile(source)
        try save(book)
        return ImportReceipt(document: book, message: L10n.tr("已创建离线副本，原文件未修改。"))
    }

    /// 按扩展名与编码解析文件；拒绝不支持或超过大小限制的正文。
    func decodedFile(_ source: URL, data supplied: Data? = nil) throws -> Manuscript {
        // 先检查磁盘大小，拒绝超限文件时无需把全文映射、解码进内存。
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Manuscript.maximumBytes { throw InkError.tooLarge }
        let data = try supplied ?? Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8.hasPrefix("\u{feff}") ? String(utf8.dropFirst()) : utf8 }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let utf16 = String(data: data, encoding: .utf16) { text = utf16 }
        else { throw InkError.invalidEncoding }
        var book = Manuscript(title: source.deletingPathExtension().lastPathComponent,
                              format: TextFormat.detect(source.lastPathComponent), content: text)
        book.fileName = source.lastPathComponent
        book.sourceName = source.lastPathComponent
        return try book.validated()
    }

    /// 设置文稿软删除状态，保留可恢复的数据记录。
    public func setTrashed(_ id: UUID, trashed: Bool) throws {
        var book = try load(id); book.trashedAt = trashed ? Date() : nil
        try save(book)
    }

    /// 校验同步正文并按版本关系合并；冲突时保留独立副本。
    public func receive(_ remote: Manuscript, checksum: String) throws -> (Manuscript, MergeDecision) {
        let incoming = try remote.validated()
        guard incoming.checksum == checksum, incoming.trashedAt == nil else { throw InkError.invalidDocument }
        guard FileManager.default.fileExists(atPath: url(incoming.id).path) else {
            try save(incoming); return (incoming, .acceptRemote)
        }
        let local = try load(incoming.id)
        // 接收同步不会悄悄恢复或覆盖已放入回收区的文稿。
        let decision = local.trashedAt != nil ? MergeDecision.conflict : SyncResolver.decide(local: local, remote: incoming)
        switch decision {
        case .same:
            var positioned = local; positioned.cursor = incoming.cursor
            try save(positioned); return (positioned, decision)
        case .acceptRemote: try save(incoming); return (incoming, decision)
        case .keepLocal: return (local, decision)
        case .conflict:
            var copy = incoming; copy.id = UUID(); copy.conflictOf = incoming.id
            copy.title += " · 冲突副本"; copy.trashedAt = nil
            try save(copy); return (copy, decision)
        }
    }
    /// 生成传输快照；overrides 可提供未正式保存的工作区正文，不携带本机授权书签。
    public func prepareTransfer(id: UUID, isFolder: Bool, overrides: [UUID: Manuscript] = [:]) throws -> PreparedTransfer {
        var collection = isFolder ? try collections().first(where: { $0.id == id }) : nil
        if isFolder && collection == nil { throw InkError.invalidDocument }
        let ids = collection?.orderedBooks(from: try list()).map(\.id) ?? [id]
        guard !ids.isEmpty else { throw CollectionError.emptyFolder }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineTransfers/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var items: [TransferManifest.Item] = [], entries: [NovelCollection.Entry] = [], title = collection?.alias ?? ""
            for id in ids {
                try Task.checkCancellation()
                let document = try (overrides[id] ?? reloadLocalFile(id)).validated()
                guard document.trashedAt == nil else { throw InkError.invalidDocument }
                let existing = collection?.entries.first { $0.documentID == id }
                let folder = existing.map { ($0.relativePath as NSString).deletingLastPathComponent } ?? ""
                let path = folder.isEmpty ? document.fileName : folder + "/" + document.fileName
                items.append(.init(documentID: id, relativePath: path, checksum: document.checksum, byteCount: document.content.utf8.count))
                entries.append(.init(documentID: id, relativePath: path, includedInReading: existing?.includedInReading ?? true))
                if collection == nil { title = document.fileName }
                try encoder.encode(document).write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            }
            collection?.entries = entries; collection?.sourceFolder = nil
            let manifest = try TransferManifest(title: title, collection: collection, items: items).validated()
            return PreparedTransfer(manifest: manifest, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// 完整清单验证后提交目录。备份仅覆盖本次涉及的文稿，逐文件操作，避免大目录占满内存。
    /// 提交失败或任务取消时回滚；冲突文稿另建副本并放进同一个目录，不覆盖原章节。
    /// 校验并接收文稿或目录传输，返回合并结果；失败时保留原本机数据。
    public func receiveTransfer(_ transfer: PreparedTransfer) throws -> TransferReceipt {
        let manifest = try transfer.manifest.validated(), files = FileManager.default
        for item in manifest.items { _ = try transfer.document(item); try Task.checkCancellation() }
        let backup = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineTransactions/" + UUID().uuidString)
        try files.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: backup) }
        var originals: [(URL, URL?)] = [], sourceOriginals: [(URL, URL, String)] = [], newIDs: [UUID] = []
        func preserve(_ target: URL) throws {
            if originals.contains(where: { $0.0 == target }) { return }
            if files.fileExists(atPath: target.path) {
                let copy = backup.appendingPathComponent(UUID().uuidString)
                try files.copyItem(at: target, to: copy); originals.append((target, copy))
            } else { originals.append((target, nil)) }
        }
        try preserve(root.appendingPathComponent("Recent.json"))
        if let collection = manifest.collection { try preserve(root.appendingPathComponent("Collections/\(collection.id.uuidString).json")) }
        var mapped: [UUID: UUID] = [:], conflicts = 0, kept = 0
        do {
            for item in manifest.items {
                try Task.checkCancellation()
                try preserve(url(item.documentID))
                try preserve(root.appendingPathComponent("Positions/\(item.documentID.uuidString).json"))
                try preserve(root.appendingPathComponent("History/\(item.documentID.uuidString)"))
                try preserve(referenceURL(item.documentID))
                // 原文件若在另一应用中改过，先更新本地修订再判断冲突，不能拿陈旧副本覆盖磁盘。
                if reference(item.documentID) != nil { _ = try reloadLocalFile(item.documentID) }
                let incoming = try transfer.document(item)
                var (received, decision) = try receive(incoming, checksum: item.checksum)
                mapped[item.documentID] = received.id
                if received.id != item.documentID { newIDs.append(received.id) }
                if decision == .conflict {
                    conflicts += 1
                    let extensionName = (received.fileName as NSString).pathExtension
                    var stem = (received.fileName as NSString).deletingPathExtension
                    while stem.utf8.count > 140 { stem.removeLast() }
                    let name = stem + " · 冲突副本-" + String(received.id.uuidString.prefix(8)) + (extensionName.isEmpty ? "" : "." + extensionName)
                    try received.configure(fileName: name, highlightOverride: received.highlightOverride); try save(received)
                }
                if decision == .keepLocal { kept += 1 }
                if decision == .acceptRemote, let ref = reference(received.id) {
                    let source = try ref.resolved(), access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let copy = backup.appendingPathComponent(UUID().uuidString)
                    try files.copyItem(at: source, to: copy)
                    sourceOriginals.append((source, copy, LocalFileReference.digest(try ref.encodedContent(received.content))))
                    try save(received, writeSource: true)
                }
            }
            try Task.checkCancellation()
            if var collection = manifest.collection {
                let existing = try collections().first { $0.id == collection.id }
                collection.sourceFolder = existing?.sourceFolder
                let oldEntries = existing?.entries ?? []
                var entries = oldEntries
                for entry in collection.entries {
                    var received = entry; received.documentID = mapped[entry.documentID] ?? entry.documentID
                    if received.documentID != entry.documentID {
                        // 首次收到整个目录时，本地已有的原章节也要纳入目录，冲突副本作为资料保留。
                        if !entries.contains(where: { $0.documentID == entry.documentID }), let original = try? load(entry.documentID), original.trashedAt == nil { entries.append(entry) }
                        received.includedInReading = false
                        let name = try load(received.documentID).fileName
                        let folder = (entry.relativePath as NSString).deletingLastPathComponent
                        received.relativePath = folder.isEmpty ? name : folder + "/" + name
                    }
                    if let index = entries.firstIndex(where: { $0.documentID == received.documentID }) { entries[index] = received }
                    else { entries.append(received) }
                }
                collection.entries = entries; try saveCollection(collection)
            }
            try Task.checkCancellation()
            let entry = RecentEntry(id: manifest.collection?.id ?? mapped[manifest.items[0].documentID] ?? manifest.items[0].documentID, isFolder: manifest.collection != nil)
            var recent = try recentHistory()
            if manifest.collection != nil {
                // 再次同步也刷新目录入口；历史曾被移除时要恢复。章节仍由目录管理，不铺成几十条独立记录。
                for id in Set(mapped.values) where !recent.pinned.contains(id) { recent.remove(id) }
            }
            recent.opened(entry); try saveHistory(recent)
            try Task.checkCancellation()
            return TransferReceipt(count: manifest.items.count, conflicts: conflicts, keptLocal: kept, entry: entry)
        } catch {
            // 只回滚仍为本次写入结果的原文件；并发外部修改绝不被回滚覆盖。
            for (source, copy, digest) in sourceOriginals {
                let access = source.startAccessingSecurityScopedResource()
                if let data = try? Data(contentsOf: source), LocalFileReference.digest(data) == digest {
                    try? Data(contentsOf: copy).write(to: source, options: .atomic)
                }
                if access { source.stopAccessingSecurityScopedResource() }
            }
            for id in newIDs { try? files.removeItem(at: url(id)); try? files.removeItem(at: root.appendingPathComponent("Positions/\(id.uuidString).json")); try? files.removeItem(at: root.appendingPathComponent("History/\(id.uuidString)")) }
            for (target, copy) in originals.reversed() {
                try? files.removeItem(at: target)
                if let copy { try? files.copyItem(at: copy, to: target) }
            }
            summaryCache.removeAll(); throw error
        }
    }

}
