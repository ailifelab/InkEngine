import Foundation

// 可见目录只保存普通文本；稳定文稿 ID、阅读位置、书签与同步元数据仍在私有资料库。
// 指纹使用文件时间和大小，未变化的长篇小说不会在每次刷新时重新读取全文。
struct SharedDocumentsIndex: Codable {
    struct File: Codable {
        var id: UUID
        var path: String
        var digest: String
        var updatedAt: Date
        var modified: Date?
        var size: Int?
    }
    var files: [File] = []
    var folders: [String: UUID] = [:]
}

extension LibraryRepository {
    private var sharedIndexURL: URL { root.appendingPathComponent("SharedDocuments.json") }
    private func sharedIndex() throws -> SharedDocumentsIndex {
        guard FileManager.default.fileExists(atPath: sharedIndexURL.path) else { return .init() }
        return try JSONDecoder().decode(SharedDocumentsIndex.self, from: Data(contentsOf: sharedIndexURL))
    }
    private func sharedURL(_ path: String) throws -> URL {
        guard let directory = documentsDirectory, TransferManifest.safePath(path) else { throw InkError.invalidDocument }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(path)
        // Finder/“文件”App 可改动目录，不能沿符号链接写到应用文稿目录之外。
        guard file.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { throw InkError.invalidDocument }
        return file
    }
    private func safeName(_ name: String) -> String {
        let result = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "文稿" : String(result.prefix(120))
    }
    private func availableSharedPath(_ proposed: String, occupied: Set<String>) throws -> String {
        var path = proposed, number = 2
        while try occupied.contains(path) || FileManager.default.fileExists(atPath: sharedURL(path).path) {
            let stem = (proposed as NSString).deletingPathExtension, ext = (proposed as NSString).pathExtension
            path = stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext); number += 1
        }
        return path
    }

    /// 刷新时双向对齐普通文本与私有副本；新增文件自动归入它所在的顶层目录。
    /// 两边同时修改时保留两份正文。外部移除文件不会永久删除书签或私有副本。
    @discardableResult public func reconcileDocumentsDirectory() throws -> Set<UUID> {
        guard let directory = documentsDirectory else { return [] }
        // /var 与 /private/var 在 Apple 系统上可能指向同处，先统一路径再截取相对部分。
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default, encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        documentsDirectoryIssues = []
        var index = try sharedIndex(), folders = try collections(), summaries = try list()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let allowed = Set(TextFormat.allCases.map(\.fileExtension) + ["markdown", "yml", "htm", "mjs", "cjs"])
        var changed = Set<UUID>(), occupied = Set(index.files.map(\.path))
        var paths: [String] = []
        if let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL
                if values.isRegularFile == true && allowed.contains(file.pathExtension.lowercased()), canonicalFile.path.hasPrefix(base.path + "/") { paths.append(String(canonicalFile.path.dropFirst(base.path.count + 1))) }
            }
        }
        for path in paths.sorted() {
            try Task.checkCancellation()
            let file = try sharedURL(path), stamp = try file.resourceValues(forKeys: keys)
            let previous = index.files.first { $0.path == path }
            if let previous, previous.modified == stamp.contentModificationDate, previous.size == stamp.fileSize,
               summaries.contains(where: { $0.id == previous.id }) { continue }
            let fresh: Manuscript
            do { fresh = try decodedFile(file) }
            catch { documentsDirectoryIssues.append(path + "：" + error.localizedDescription); continue }
            if let position = index.files.firstIndex(where: { $0.path == path }), let summary = summaries.first(where: { $0.id == index.files[position].id }) {
                let record = index.files[position]
                var local = try load(summary.id)
                if fresh.checksum != local.checksum {
                    if local.checksum != record.digest {
                        // 私有副本也被编辑过：原文稿另存到新路径，外部文本保留为独立冲突副本。
                        var copy = fresh; copy.conflictOf = local.id; copy.title += " · 外部修改副本"
                        try save(copy); index.files[position].id = copy.id; changed.insert(copy.id)
                    } else {
                        local.edit(content: fresh.content); try save(local); changed.insert(local.id)
                    }
                }
                let id = index.files[position].id, saved = try load(id)
                index.files[position] = .init(id: id, path: path, digest: saved.checksum, updatedAt: saved.updatedAt, modified: stamp.contentModificationDate, size: stamp.fileSize)
            } else {
                let linked = summaries.first { sourcePath($0.id) == file.path }
                let saved: Manuscript
                if let linked { saved = try reloadLocalFile(linked.id) }
                else { saved = fresh; try save(saved) }
                index.files.removeAll { $0.path == path }
                index.files.append(.init(id: saved.id, path: path, digest: saved.checksum, updatedAt: saved.updatedAt, modified: stamp.contentModificationDate, size: stamp.fileSize))
                occupied.insert(path); changed.insert(saved.id)
            }
            let record = index.files.first { $0.path == path }!
            if let slash = path.firstIndex(of: "/") {
                let top = String(path[..<slash]), relative = String(path[path.index(after: slash)...])
                var folder = index.folders[top].flatMap { id in folders.first { $0.id == id } } ?? NovelCollection(alias: top)
                if !folder.entries.contains(where: { $0.documentID == record.id }) {
                    folder.entries.append(.init(documentID: record.id, relativePath: relative, includedInReading: NovelCollection.isReadingChapter(fileName: file.lastPathComponent)))
                    try saveCollection(folder)
                    folders.removeAll { $0.id == folder.id }; folders.append(folder); index.folders[top] = folder.id
                }
                var recent = try recentHistory()
                if !recent.pinned.contains(record.id) { recent.remove(record.id); try saveHistory(recent) }
            }
            if sourcePath(record.id) == nil || sourcePath(record.id)?.hasPrefix(base.path + "/") == true { try attachSource(file, to: record.id) }
        }
        summaries = try list()
        // 先分配目录名称，再输出章节。已分配的目录不随别名变化而重命名，避免影响电脑正在复制的文件。
        for folder in folders where !index.folders.values.contains(folder.id) {
            let name = try availableSharedPath(safeName(folder.alias), occupied: Set(index.folders.keys))
            index.folders[name] = folder.id
        }
        for summary in summaries where summary.trashedAt == nil {
            let existing = index.files.firstIndex { $0.id == summary.id }
            if let existing, index.files[existing].updatedAt == summary.updatedAt, fm.fileExists(atPath: try sharedURL(index.files[existing].path).path) { continue }
            let book = try load(summary.id)
            let path: String
            if let existing { path = index.files[existing].path }
            else {
                let folder = folders.first { $0.entries.contains { $0.documentID == book.id } }
                let relative = folder?.entries.first { $0.documentID == book.id }?.relativePath
                let parent = folder.flatMap { collection in index.folders.first { $0.value == collection.id }?.key }
                let proposed = parent.map { $0 + "/" + (relative.map { ($0 as NSString).deletingLastPathComponent }.flatMap { $0.isEmpty ? nil : $0 + "/" } ?? "") + safeName(book.fileName) } ?? safeName(book.fileName)
                path = try availableSharedPath(proposed, occupied: occupied)
            }
            let target = try sharedURL(path)
            if documentsDirectoryIssues.contains(where: { $0.hasPrefix(path + "：") }) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 保持现有 UTF-16 编码和 BOM；未变正文仅刷新指纹，不改写磁盘文件。
            if try !fm.fileExists(atPath: target.path) || decodedFile(target).checksum != book.checksum {
                try Data(book.content.utf8).write(to: target, options: .atomic)
            }
            let stamp = try target.resourceValues(forKeys: keys)
            let record = SharedDocumentsIndex.File(id: book.id, path: path, digest: book.checksum, updatedAt: book.updatedAt, modified: stamp.contentModificationDate, size: stamp.fileSize)
            if let existing { index.files[existing] = record } else { index.files.append(record) }
            occupied.insert(path)
            if sourcePath(book.id) == nil || sourcePath(book.id)?.hasPrefix(base.path + "/") == true { try attachSource(target, to: book.id) }
        }
        let data = try encoder.encode(index)
        if (try? Data(contentsOf: sharedIndexURL)) != data { try data.write(to: sharedIndexURL, options: .atomic) }
        return changed
    }

    /// 永久删除仅在界面确认后调用；只移除应用副本及其索引，绝不解析/删除外部原文件路径。
    @discardableResult public func deleteLocalEntry(_ entry: RecentEntry) throws -> Set<UUID> {
        let fm = FileManager.default, encoder = JSONEncoder(), folders = try collections()
        let folder = folders.first { $0.id == entry.id }
        if entry.isFolder { guard folder != nil else { throw InkError.invalidDocument } }
        else { _ = try load(entry.id) }
        let shared = Set(folders.filter { $0.id != entry.id }.flatMap { $0.entries.map(\.documentID) })
        let ids: Set<UUID> = entry.isFolder ? Set(folder!.entries.map(\.documentID)).subtracting(shared) : [entry.id]
        var history = try recentHistory(); history.remove(entry.id)
        for id in ids { history.remove(id) }
        var index = try sharedIndex()
        let removedDirectories = index.folders.filter { $0.value == entry.id }.map(\.key)
        var removals = ids.flatMap { id in [root.appendingPathComponent(id.uuidString + ".ink"), root.appendingPathComponent("Positions/\(id.uuidString).json"), root.appendingPathComponent("Sources/\(id.uuidString).json"), root.appendingPathComponent("History/\(id.uuidString)")] }
        if documentsDirectory != nil {
            removals += try index.files.filter { ids.contains($0.id) }.map { try sharedURL($0.path) }
        }
        index.files.removeAll { ids.contains($0.id) }
        if entry.isFolder { index.folders = index.folders.filter { $0.value != entry.id }; removals.append(root.appendingPathComponent("Collections/\(entry.id.uuidString).json")) }
        var writes: [(URL, Data)] = [(root.appendingPathComponent("Recent.json"), try encoder.encode(history)), (sharedIndexURL, try encoder.encode(index))]
        for var other in folders where !(entry.isFolder && other.id == entry.id) && other.entries.contains(where: { ids.contains($0.documentID) }) {
            other.entries.removeAll { ids.contains($0.documentID) }
            writes.append((root.appendingPathComponent("Collections/\(other.id.uuidString).json"), try encoder.encode(other)))
        }
        let staging = root.appendingPathComponent(".delete-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = [], written: [URL] = []
        do {
            // 移动而非复制大正文；元数据全部编码成功后才动文件，写入失败则逆序恢复。
            for target in Set(removals + writes.map(\.0)) where fm.fileExists(atPath: target.path) {
                let backup = staging.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: target, to: backup); moved.append((target, backup))
            }
            for (target, data) in writes { try data.write(to: target, options: .atomic); written.append(target) }
        } catch {
            for target in written { try? fm.removeItem(at: target) }
            for (target, backup) in moved.reversed() { try? fm.moveItem(at: backup, to: target) }
            try? fm.removeItem(at: staging); throw error
        }
        try? fm.removeItem(at: staging)
        // 删空可见目录，但保留同目录的封面等非文本文件和其他目录共用的章节。
        if entry.isFolder, let base = documentsDirectory {
            for name in removedDirectories {
                let directory = base.appendingPathComponent(name)
                if let children = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                    let nested = children.compactMap { $0 as? URL }.sorted { $0.path.count > $1.path.count }
                    for child in nested where (try? fm.contentsOfDirectory(atPath: child.path).isEmpty) == true { try? fm.removeItem(at: child) }
                }
                if (try? fm.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try? fm.removeItem(at: directory) }
            }
        }
        return ids
    }

}
