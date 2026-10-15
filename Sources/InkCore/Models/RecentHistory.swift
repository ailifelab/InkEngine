import Foundation

public struct RecentEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var isFolder: Bool
    public var openedAt: Date
    public init(id: UUID, isFolder: Bool = false, openedAt: Date = Date()) {
        self.id = id; self.isFolder = isFolder; self.openedAt = openedAt
    }
}

/// 历史记录与文稿分开保存，淘汰历史条目不会删除文件。
public struct RecentHistory: Codable, Sendable, Equatable {
    public static let limit = 100
    public private(set) var entries: [RecentEntry] = []
    public private(set) var pinned: [UUID] = []
    public init() {}
    public var ordered: [RecentEntry] {
        let lookup = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pins = Set(pinned)
        return pinned.compactMap { lookup[$0] } + entries.filter { !pins.contains($0.id) }.sorted { $0.openedAt > $1.openedAt }
    }
    public mutating func opened(_ entry: RecentEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.append(entry) }
        let pins = Set(pinned)
        entries.sort { $0.openedAt > $1.openedAt }
        while entries.count > Self.limit {
            guard let index = entries.lastIndex(where: { !pins.contains($0.id) }) else { entries.removeLast(); break }
            entries.remove(at: index)
        }
        pinned = pinned.filter { id in entries.contains { $0.id == id } }
    }
    public mutating func togglePin(_ entry: RecentEntry) {
        if pinned.contains(entry.id) { pinned.removeAll { $0 == entry.id }; return }
        guard pinned.count < Self.limit else { return }
        pinned.append(entry.id); opened(entry)
    }
    public mutating func reorderPins(_ ids: [UUID]) {
        guard ids.count == pinned.count, Set(ids) == Set(pinned) else { return }
        pinned = ids
    }
    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }; pinned.removeAll { $0 == id }
    }
}
