import Foundation

/// 清单只含相对路径和摘要，不传送电脑上的绝对路径或安全书签。
public struct TransferManifest: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var documentID: UUID
        public var relativePath: String
        public var checksum: String
        public var byteCount: Int
        public init(documentID: UUID, relativePath: String, checksum: String, byteCount: Int) {
            self.documentID = documentID; self.relativePath = relativePath; self.checksum = checksum; self.byteCount = byteCount
        }
    }
    public var id: UUID
    public var title: String
    public var collection: NovelCollection?
    public var items: [Item]
    public init(id: UUID = UUID(), title: String, collection: NovelCollection? = nil, items: [Item]) {
        self.id = id; self.title = title; self.collection = collection; self.items = items
        self.collection?.sourceFolder = nil
        self.collection?.sourceFolderBookmark = nil
    }
    public static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 4096 && !path.contains("\\") && !path.contains("\0") && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }
    }
    public func validated() throws -> Self {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              !items.isEmpty, items.count <= 10_000,
              Set(items.map(\.documentID)).count == items.count,
              Set(items.map(\.relativePath)).count == items.count,
              items.allSatisfy({ Self.safePath($0.relativePath) && $0.byteCount >= 0 && $0.byteCount <= 20 * 1024 * 1024 && $0.checksum.count == 64 && $0.checksum.allSatisfy(\.isHexDigit) }),
              items.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 2 * 1024 * 1024 * 1024 else { throw InkError.invalidDocument }
        if let collection {
            guard collection.sourceFolder == nil, collection.sourceFolderBookmark == nil, !collection.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, collection.alias.count <= 200,
                  Set(collection.entries.map(\.documentID)) == Set(items.map(\.documentID)), collection.entries.count == items.count,
                  collection.entries.allSatisfy({ entry in items.contains { $0.documentID == entry.documentID && $0.relativePath == entry.relativePath } }) else { throw InkError.invalidDocument }
        } else if items.count != 1 { throw InkError.invalidDocument }
        return self
    }
}

public struct PreparedTransfer: Sendable {
    public var manifest: TransferManifest
    public var directory: URL
    public init(manifest: TransferManifest, directory: URL) { self.manifest = manifest; self.directory = directory }
    public func documentURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    public func document(_ item: TransferManifest.Item) throws -> Manuscript {
        let document = try JSONDecoder().decode(Manuscript.self, from: Data(contentsOf: documentURL(item.documentID))).validated()
        guard document.id == item.documentID, document.checksum == item.checksum, document.content.utf8.count == item.byteCount else { throw InkError.invalidDocument }
        return document
    }
    public func remove() { try? FileManager.default.removeItem(at: directory) }
}

public struct TransferReceipt: Sendable {
    public var count: Int
    public var conflicts: Int
    public var keptLocal: Int
    /// 接收端真正可打开的入口；单文件冲突时指向新副本，目录始终指向保留章节结构的目录。
    public var entry: RecentEntry
    public var note: String { L10n.tr("已同步 \(count) 个文件") + (conflicts > 0 ? L10n.tr("，保留 \(conflicts) 个冲突副本") : "") + (keptLocal > 0 ? L10n.tr("，\(keptLocal) 个本地较新版本保持原样") : "") }
}
