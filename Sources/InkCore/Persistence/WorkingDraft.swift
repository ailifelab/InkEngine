import Foundation

/// 恢复草稿独立存放，不出现在正式文稿索引中，也不代表已写回原文件。
/// document 是未保存工作副本，baseline 是检测未保存修改和外部冲突的正式版本基线。
public struct WorkingDraft: Codable, Sendable {
    public var document: Manuscript
    public var baseline: Manuscript
    public var isNew: Bool
    /// 以当前工作副本和正式版本基线创建恢复记录；isNew 标识尚未正式落盘的文稿。
    public init(document: Manuscript, baseline: Manuscript, isNew: Bool) {
        self.document = document; self.baseline = baseline; self.isNew = isNew
    }
    /// 比较正文与基线；新文稿只有输入正文后才视为需要提示的未保存修改。
    public var hasChanges: Bool { document.content != baseline.content || (isNew && !document.content.isEmpty) }
    /// 将明确的书签或设置修改从未保存正文中分离，以便只提交元数据而不误保存正文。
    public var metadataOnlyUpdate: Manuscript? {
        guard !isNew else { return nil }
        let old = Dictionary(uniqueKeysWithValues: baseline.bookmarks.map { ($0.id, $0) })
        let changedBookmarks = document.bookmarks.count != baseline.bookmarks.count || document.bookmarks.contains { mark in
            guard let previous = old[mark.id] else { return true }
            return mark.name != previous.name || mark.updatedAt != previous.updatedAt || mark.deletedAt != previous.deletedAt
        }
        guard changedBookmarks || document.fileName != baseline.fileName || document.highlightOverride != baseline.highlightOverride else { return nil }
        var metadata = document
        metadata.edit(content: baseline.content)
        return metadata
    }
}

/// 标签只保存文稿标识与显示元数据，正文和撤销栈由工作区会话持有。
public struct WorkspaceTab: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pinned: Bool
    public var color: Int?
    /// 创建文稿标签；颜色索引与固定状态可随工作区持久化。
    public init(id: UUID, pinned: Bool = false, color: Int? = nil) { self.id = id; self.pinned = pinned; self.color = color }
}

/// 单个分栏的标签顺序、选择和视图位置；不持有文稿副本。
public struct WorkspacePane: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tabs: [WorkspaceTab]
    public var selected: UUID?
    public var viewPositions: [String: WorkspaceViewPosition]?
    public var sidebarVisible: Bool?
    /// 创建分栏；未指定选择时使用首个标签，视图位置从空映射开始。
    public init(id: UUID = UUID(), tabs: [WorkspaceTab] = [], selected: UUID? = nil) {
        self.id = id; self.tabs = tabs; self.selected = selected ?? tabs.first?.id; viewPositions = [:]
    }

    /// 将标签移到目标之前，目标为空时移到末尾；固定标签仍保持前置，非法目标返回 false。
    @discardableResult public mutating func moveTab(_ id: UUID, before target: UUID?) -> Bool {
        guard id != target, let index = tabs.firstIndex(where: { $0.id == id }),
              target == nil || tabs.contains(where: { $0.id == target }) else { return false }
        let tab = tabs.remove(at: index)
        let insertion = target.flatMap { target in tabs.firstIndex(where: { $0.id == target }) } ?? tabs.count
        tabs.insert(tab, at: insertion)
        tabs = tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
        return true
    }

    /// 排序键相同的标签保留原顺序；固定标签始终集中在最前方。
    public mutating func sortTabs(by less: (WorkspaceTab, WorkspaceTab) -> Bool) {
        tabs = tabs.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// 重新打开时只恢复标签元数据，不恢复用户已明确丢弃的编辑正文。
public struct ClosedWorkspaceTab: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var tab: WorkspaceTab
    public var window: UUID
    public var pane: UUID
    public var index: Int
    public var fileName: String
    public var editing: Bool
    public var cursor: Int
    /// 记录关闭前的标签位置、模式和游标，供重新打开时恢复界面。
    public init(tab: WorkspaceTab, window: UUID, pane: UUID, index: Int, fileName: String, editing: Bool, cursor: Int) {
        self.tab = tab; self.window = window; self.pane = pane; self.index = index
        self.fileName = fileName; self.editing = editing; self.cursor = cursor
    }
}

/// 每个分栏独立保存 UTF-16 选区、滚动偏移与编辑显示方式，避免克隆视图互相覆盖。
public struct WorkspaceViewPosition: Codable, Equatable, Sendable {
    public var cursor: Int
    public var selectionLength: Int
    public var x: Double
    public var y: Double
    public var editing: Bool?
    public var wrapsLines: Bool?
    public var columnMode: Bool?
    /// 创建分栏视图位置；可选显示参数兼容未记录这些字段的旧工作区。
    public init(cursor: Int, selectionLength: Int, x: Double, y: Double, editing: Bool? = nil, wrapsLines: Bool? = nil, columnMode: Bool? = nil) {
        self.cursor = cursor; self.selectionLength = selectionLength; self.x = x; self.y = y
        self.editing = editing; self.wrapsLines = wrapsLines; self.columnMode = columnMode
    }
}

/// 窗口布局快照，最多两个分栏；文稿内容由各标签标识关联。
public struct WorkspaceWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var panes: [WorkspacePane]
    public var focusedPane: UUID
    public var sidebarVisible: Bool?
    /// 创建窗口；空分栏数组会补一个默认分栏，并将首个分栏设为焦点。
    public init(id: UUID = UUID(), panes: [WorkspacePane] = [.init()]) {
        self.id = id; self.panes = panes.isEmpty ? [.init()] : panes; focusedPane = self.panes[0].id
    }
}

/// 可持久化的工作区布局版本，不包含未保存正文。
public struct WorkspaceSnapshot: Codable, Sendable {
    public var version: Int = 1
    public var windows: [WorkspaceWindow]
    public var recentlyClosed: [ClosedWorkspaceTab]?
    /// 汇总窗口与最近关闭记录；缺省关闭记录兼容旧版布局。
    public init(windows: [WorkspaceWindow], recentlyClosed: [ClosedWorkspaceTab]? = nil) {
        self.windows = windows; self.recentlyClosed = recentlyClosed
    }
}

extension LibraryRepository {
    private var workingDirectory: URL { root.appendingPathComponent("WorkingDrafts", isDirectory: true) }
    /// 原子暂存恢复草稿并同步同版本阅读位置；不写回原文件或正式正文。
    public func saveWorkingDraft(_ draft: WorkingDraft) throws {
        _ = try draft.document.validated(); _ = try draft.baseline.validated()
        guard draft.document.id == draft.baseline.id else { throw InkError.invalidDocument }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: workingDirectory.appendingPathComponent(draft.document.id.uuidString + ".json"), options: .atomic)
        try savePosition(id: draft.document.id, revision: draft.document.revision, cursor: draft.document.cursor)
    }
    /// 读取恢复草稿并叠加同版本位置；保留未保存正文及其正式基线。
    public func workingDraft(_ id: UUID) throws -> WorkingDraft? {
        let file = workingDirectory.appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var draft = try JSONDecoder().decode(WorkingDraft.self, from: Data(contentsOf: file))
        guard draft.document.id == id, draft.baseline.id == id else { throw InkError.invalidDocument }
        _ = try draft.document.validated(); _ = try draft.baseline.validated()
        draft.document = restoringPosition(in: draft.document)
        return draft
    }
    /// 列出已有恢复草稿的文稿 ID，供工作区重启恢复使用。
    public func workingDraftIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: workingDirectory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(at: workingDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
    }
    /// 移除指定恢复记录；正式保存或明确放弃修改后调用。
    public func removeWorkingDraft(_ id: UUID) throws {
        let file = workingDirectory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    /// 原子保存窗口、分栏、标签和最近关闭记录，不隐式保存文稿正文。
    public func saveWorkspace(_ snapshot: WorkspaceSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("Workspace.json"), options: .atomic)
    }
    /// 读取并校验工作区结构；不合法的窗口、分栏和标签映射会抛出错误。
    public func workspaceSnapshot() throws -> WorkspaceSnapshot? {
        let file = root.appendingPathComponent("Workspace.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: file))
        guard snapshot.version == 1, Set(snapshot.windows.map(\.id)).count == snapshot.windows.count,
              snapshot.windows.allSatisfy({ window in
                  !window.panes.isEmpty && window.panes.count <= 2
                  && Set(window.panes.map(\.id)).count == window.panes.count
                  && window.panes.contains(where: { $0.id == window.focusedPane })
                  && window.panes.allSatisfy({ pane in
                      Set(pane.tabs.map(\.id)).count == pane.tabs.count
                      && (pane.selected == nil || pane.tabs.contains(where: { $0.id == pane.selected }))
                  })
              }) else { throw InkError.invalidDocument }
        return snapshot
    }
}
