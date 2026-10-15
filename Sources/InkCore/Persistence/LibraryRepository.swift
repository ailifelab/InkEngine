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

public actor LibraryRepository {
    private struct Position: Codable { var revision: UUID; var cursor: Int }
    public let root: URL
    public let documentsDirectory: URL?
    public internal(set) var documentsDirectoryIssues: [String] = []
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private struct CachedSummary { let modified: Date?; let size: Int?; let revision: UUID; var summary: BookSummary }
    private var summaryCache: [UUID: CachedSummary] = [:]

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
    public func saveHistory(_ history: RecentHistory) throws {
        try encoder.encode(history).write(to: root.appendingPathComponent("Recent.json"), options: .atomic)
    }
    private func referenceURL(_ id: UUID) -> URL { root.appendingPathComponent("Sources/\(id.uuidString).json") }
    private func reference(_ id: UUID) -> LocalFileReference? {
        guard let data = try? Data(contentsOf: referenceURL(id)) else { return nil }
        return try? decoder.decode(LocalFileReference.self, from: data)
    }
    public func sourcePath(_ id: UUID) -> String? { reference(id)?.path }
    /// 使用安全书签解析实际文件位置，保持移动文件后的路径和相邻资源关系。
    public func sourceURL(_ id: UUID) throws -> URL? { try reference(id)?.resolved() }
    public func attachSource(_ source: URL, to id: UUID) throws {
        let book = try load(id), ref = try LocalFileReference(url: source, content: book.content)
        try encoder.encode(ref).write(to: referenceURL(id), options: .atomic)
    }
    public func openLocalFile(_ source: URL) throws -> ImportReceipt {
        if let file = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil).first(where: { file in
            guard let data = try? Data(contentsOf: file), let ref = try? decoder.decode(LocalFileReference.self, from: data) else { return false }
            return (try? ref.resolved().standardizedFileURL.path) == source.standardizedFileURL.path
        }), let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) {
            let existing = try reloadLocalFile(id); return .init(document: existing, message: "已打开原文件 · 编辑会保存回原文件")
        }
        let book = try decodedFile(source); try save(book); try attachSource(source, to: book.id)
        return .init(document: book, message: "已打开原文件 · 编辑会保存回原文件")
    }
    /// 只在文件事件或回到前台时核对；不对所有历史文件进行轮询。
    public func sourceHasChanges(_ id: UUID) throws -> Bool {
        guard let ref = reference(id) else { return false }
        let source = try ref.resolved(), access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Manuscript.maximumBytes { throw InkError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
        return ref.path != source.path || LocalFileReference.digest(data) != ref.diskDigest
    }
    public func localFileUpdate(_ id: UUID) throws -> LocalFileUpdate? {
        var book = try load(id)
        guard let ref = reference(id) else { return nil }
        let source = try ref.resolved(), access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Manuscript.maximumBytes { throw InkError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
        if source.path == ref.path, source.lastPathComponent == book.fileName, book.checksum == ref.contentDigest, LocalFileReference.digest(data) == ref.diskDigest { return nil }
        let fresh = try decodedFile(source, data: data)
        book.edit(content: fresh.content)
        if book.fileName != source.lastPathComponent { try book.configure(fileName: source.lastPathComponent, highlightOverride: book.highlightOverride) }
        return LocalFileUpdate(document: book, reference: try LocalFileReference(url: source, content: fresh.content, data: data))
    }
    public func acceptLocalFileUpdate(_ update: LocalFileUpdate) throws {
        guard update.document.checksum == update.reference.contentDigest else { throw InkError.invalidDocument }
        try save(update.document)
        try encoder.encode(update.reference).write(to: referenceURL(update.document.id), options: .atomic)
    }
    public func reloadLocalFile(_ id: UUID) throws -> Manuscript {
        guard let update = try localFileUpdate(id) else { return try load(id) }
        try acceptLocalFileUpdate(update)
        return update.document
    }
    public func allBookmarks(includeDeleted: Bool = false) throws -> [BookmarkRecord] {
        let folders = try collections()
        return try list().filter { $0.trashedAt == nil }.flatMap { summary in
            let folder = folders.first { $0.entries.contains { $0.documentID == summary.id } }
            return try load(summary.id).bookmarks.filter { includeDeleted || $0.deletedAt == nil }.map { BookmarkRecord(documentID: summary.id, fileName: summary.fileName, folderID: folder?.id, bookmark: $0) }
        }
    }
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
    public func clearSnapshotCache(documentIDs: Set<UUID>? = nil) throws {
        let folder = root.appendingPathComponent("History")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            if documentIDs == nil || UUID(uuidString: file.lastPathComponent).map({ documentIDs!.contains($0) }) == true { try FileManager.default.removeItem(at: file) }
        }
    }
    public func purgeAllBookmarks(documentIDs: Set<UUID>? = nil) throws {
        var ids = Set<UUID>()
        for summary in try list() where documentIDs == nil || documentIDs!.contains(summary.id) {
            ids.formUnion(try load(summary.id).bookmarks.map(\.id))
        }
        try deleteBookmarks(ids)
    }

    public func collections() throws -> [NovelCollection] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Collections"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(NovelCollection.self, from: Data(contentsOf: $0)) }
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

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
    public func importFolder(_ source: URL, alias: String, linkOriginals: Bool = false) throws -> FolderImportReceipt {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 200 else { throw CollectionError.invalidAlias }
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL.path
        if var previous = try collections().first(where: { $0.sourceFolder == canonical }) {
            previous.alias = clean; try saveCollection(previous)
            return FolderImportReceipt(collection: previous, skippedFiles: 0, reused: true)
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else { throw CollectionError.emptyFolder }
        let allowed = Set(TextFormat.allCases.map(\.fileExtension) + ["markdown", "yml", "htm", "mjs", "cjs"])
        var documents: [(Manuscript, String)] = [], skipped = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { enumerator.skipDescendants(); skipped += 1; continue }
            guard values.isRegularFile == true else { continue }
            guard allowed.contains(file.pathExtension.lowercased()) else { skipped += 1; continue }
            let book = try decodedFile(file)
            let relative = String(file.path.dropFirst(source.path.hasSuffix("/") ? source.path.count : source.path.count + 1))
            documents.append((book, relative))
        }
        if let enumerationError { throw enumerationError }
        guard !documents.isEmpty else { throw CollectionError.emptyFolder }
        let collection = NovelCollection(alias: clean, sourceFolder: canonical, entries: documents.map { .init(documentID: $0.0.id, relativePath: $0.1, includedInReading: NovelCollection.isReadingChapter(fileName: $0.0.fileName)) })
        let originalHistory = try recentHistory()
        do {
            for (book, relative) in documents {
                try Task.checkCancellation(); try save(book)
                if linkOriginals { try attachSource(source.appendingPathComponent(relative), to: book.id) }
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

    public func load(_ id: UUID) throws -> Manuscript {
        var book = try decoder.decode(Manuscript.self, from: Data(contentsOf: url(id))).validated()
        let positionURL = root.appendingPathComponent("Positions/\(id.uuidString).json")
        if let data = try? Data(contentsOf: positionURL), let position = try? decoder.decode(Position.self, from: data), position.revision == book.revision {
            book.cursor = min(max(0, position.cursor), book.content.utf16.count)
        }
        return book
    }

    // 阅读位置单独保存，长篇小说也只写少量元数据，不改写或重读正文。
    public func savePosition(id: UUID, revision: UUID, cursor: Int) throws {
        guard cursor >= 0 else { throw InkError.invalidDocument }
        let positionURL = root.appendingPathComponent("Positions/\(id.uuidString).json")
        try encoder.encode(Position(revision: revision, cursor: cursor)).write(to: positionURL, options: .atomic)
    }

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

    public func importFile(_ source: URL) throws -> ImportReceipt {
        let book = try decodedFile(source)
        try save(book)
        return ImportReceipt(document: book, message: "已创建离线副本，原文件未修改。")
    }

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

    public func setTrashed(_ id: UUID, trashed: Bool) throws {
        var book = try load(id); book.trashedAt = trashed ? Date() : nil
        try save(book)
    }

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
    public func prepareTransfer(id: UUID, isFolder: Bool) throws -> PreparedTransfer {
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
                let document = try reloadLocalFile(id).validated()
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
