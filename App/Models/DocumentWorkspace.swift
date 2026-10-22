import SwiftUI
import InkCore
import Combine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor final class EditorViewState {
    var host: EditorHost?
    var active = false
    var restoredPosition: WorkspaceViewPosition?
    var readerOffset: Int?
    let undo: UndoManager
    let storage: NSTextStorage
    /// 将分栏的原生撤销栈与共享文本存储绑定，布局切换时复用同一编辑状态。
    init(undo: UndoManager, storage: NSTextStorage) { self.undo = undo; self.storage = storage }
}

struct EditorStateKey: EnvironmentKey {
    static let defaultValue: EditorViewState? = nil
}
extension EnvironmentValues {
    var workspaceEditorState: EditorViewState? {
        get { self[EditorStateKey.self] }
        set { self[EditorStateKey.self] = newValue }
    }
}

enum CloseChoice { case save, discard, cancel }
struct CloseQuestion: Identifiable {
    let id = UUID()
    let window: UUID
    let name: String
    let index: Int
    let count: Int
}

/// 每个进程共享一个文稿注册表；窗口与分栏引用会话，不复制正文。
/// UI 焦点、编辑缓冲、原生撤销栈和朗读所有权分开管理，防止切换布局时丢失状态。
@MainActor final class DocumentWorkspace: ObservableObject {
    let library: AppModel
    @Published var windows: [WorkspaceWindow] = []
    @Published var sessions: [UUID: AppModel] = [:]
    @Published var focusedWindow: UUID?
    @Published var closeQuestion: CloseQuestion?
    @Published var closing = false
    @Published private(set) var maintenance = false
    @Published var ready = false
    @Published var speechDocument: UUID?
    @Published var focusModeWindows: Set<UUID> = []
    @Published private(set) var recentlyClosedTabs: [ClosedWorkspaceTab] = []
    @Published private(set) var singleDocumentWindows: Set<UUID> = []
    @Published var tabManagerWindow: UUID?
    private var speechSubscription: AnyCancellable?
    @Published var failure: String?
    #if DEBUG
    @Published var diskEvidence = ""
    @Published var closeEvidence = ""
    var undoEvidence: String {
        sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }).map { id in
            (sessions[id]?.book?.fileName ?? "") + ":" + String(documentUndoManager(id)?.canUndo ?? false) + ":" + (documentUndoManager(id)?.undoActionName ?? "")
        }.joined(separator: "|")
    }
    #endif
    @Published var exportSnapshot: Manuscript?
    private var exportDirectoryAccess: URL?
    @Published var exportWindow: UUID?
    @Published var fileOperation: FileOperation?
    @Published var folderWindow: UUID?
    var folderInitialURL: URL?
    private var closeReply: CheckedContinuation<CloseChoice, Never>?
    private var exportReply: CheckedContinuation<URL?, Never>?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var librarySubscription: AnyCancellable?
    private var editorStates: [UUID: [UUID: EditorViewState]] = [:]
    private var undoManagers: [UUID: UndoManager] = [:]
    private var textStorages: [UUID: NSTextStorage] = [:]
    private var restoring = false
    private var openingIDs = Set<UUID>()
    private var pendingOperations = 0
    private(set) var savingDocuments = Set<UUID>()
    private var stateTask: Task<Void, Never>?
    private var readingTransitions: Set<UUID> = []
    private var untitledSerial = 0
    private var focusedDocument: UUID?
    private var focusGeneration = UUID()
    private var restoredWindowsClaimed = false
    #if os(iOS)
    private final class SceneReference {
        weak var value: UIWindowScene?
        init(_ value: UIWindowScene) { self.value = value }
    }
    private var sceneReferences: [UUID: SceneReference] = [:]
    private var testSceneSession: String?
    /// 记录窗口对应的系统场景；隔离测试中防止重复恢复默认窗口。
    func registerScene(_ scene: UIWindowScene, window: UUID) {
        let session = scene.session.persistentIdentifier
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
            if let first = testSceneSession, first != session, window == Self.defaultWindowID {
                UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
                return
            }
            testSceneSession = session
        }
        sceneReferences[window] = SceneReference(scene)
    }
    /// 请求系统销毁对应场景；实际文稿关闭确认由工作区流程处理。
    func dismissSystemWindow(_ window: UUID) {
        guard let session = sceneReferences[window]?.value?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        sceneReferences[window] = nil
    }
    #endif
    var protectedDocumentIDs: Set<UUID> { Set(sessions.keys) }
    var workingSnapshots: [UUID: Manuscript] { sessions.compactMapValues { $0.workingSnapshot() } }
    var focusedModel: AppModel? { focusedDocument.flatMap { sessions[$0] } }

    struct FileOperation: Identifiable {
        enum Kind { case rename, delete, reload }
        let id = UUID()
        let document: UUID
        let window: UUID
        let kind: Kind
    }

    /// 创建工作区并绑定资料库；恢复已保存的窗口布局，不复制文稿正文或朗读引擎。
    init(library provided: AppModel? = nil) {
        let library = provided ?? AppModel()
        self.library = library
        library.workspace = Self.supported ? self : nil
        guard Self.supported else { return }
        speechSubscription = library.speech.$playing.combineLatest(library.speech.$paused, library.speech.$scrubbing)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }
            .sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
        librarySubscription = library.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = self.library.error, self.focusedModel != nil {
                    self.failure = error; self.library.error = nil
                }
                for model in self.sessions.values {
                    model.books = self.library.books; model.novels = self.library.novels
                    model.history = self.library.history; model.receivedSync = self.library.receivedSync
                }
                self.objectWillChange.send()
            }
        }
    }

    static let defaultWindowID = UUID(uuidString: "54758064-7964-4B69-9F18-8076A616028A")!

    static var supported: Bool {
        true
    }

    /// 尝试进入互斥维护状态；已有打开、保存或关闭操作时返回 false。
    func beginMaintenance() -> Bool {
        guard !maintenance, !closing, pendingOperations == 0, openingIDs.isEmpty, savingDocuments.isEmpty else { return false }
        maintenance = true; return true
    }
    /// 退出维护状态，重新允许文稿操作。
    func endMaintenance() { maintenance = false }

    /// 按稳定窗口 ID 查找布局；窗口已关闭时返回 nil。
    func window(_ id: UUID) -> WorkspaceWindow? { windows.first { $0.id == id } }
    /// 取得窗口或指定分栏的当前文稿模型，空工作区回退到书库模型。
    func model(_ window: UUID, pane: UUID? = nil) -> AppModel {
        guard let layout = self.window(window),
              let selected = layout.panes.first(where: { $0.id == (pane ?? layout.focusedPane) })?.selected else { return library }
        return sessions[selected] ?? library
    }
    /// 按分栏和文稿复用编辑视图状态，保持选区、滚动及撤销上下文。
    func editorState(document: UUID, pane: UUID) -> EditorViewState {
        let active = windows.flatMap(\.panes).first(where: { $0.id == pane })?.selected == document
        if let state = editorStates[pane]?[document] { state.active = active; return state }
        let undo = undoManagers[document] ?? UndoManager()
        undoManagers[document] = undo
        let storage = textStorages[document] ?? NSTextStorage(string: sessions[document]?.editorText ?? "")
        textStorages[document] = storage
        let state = EditorViewState(undo: undo, storage: storage)
        state.active = active
        state.restoredPosition = windows.flatMap(\.panes).first(where: { $0.id == pane })?.viewPositions?[document.uuidString]
        if state.restoredPosition?.editing == false { state.readerOffset = state.restoredPosition?.cursor }
        editorStates[pane, default: [:]][document] = state
        return state
    }

    /// 恢复窗口和标签，优先加载未保存草稿，再恢复模式与阅读位置。
    func restore() async {
        guard !ready, !restoring else { return }
        restoring = true
        defer { restoring = false; ready = true }
        do {
            if let snapshot = try await library.repository.workspaceSnapshot() {
                windows = snapshot.windows; recentlyClosedTabs = Array((snapshot.recentlyClosed ?? []).prefix(20))
            }
            if windows.isEmpty { windows = [.init(id: Self.defaultWindowID)] }
            focusedWindow = windows.first?.id
            let ids = Set(windows.flatMap { $0.panes.flatMap { $0.tabs.map(\.id) } })
                .union(try await library.repository.workingDraftIDs())
            for id in ids {
                do {
                    let draft = try await library.repository.workingDraft(id)
                    let session = makeSession()
                    if let draft {
                        session.book = draft.document; session.editorText = draft.document.content
                        session.savedBaseline = draft.baseline; session.isNewDraft = draft.isNew
                        session.dirty = draft.hasChanges; session.textLength = draft.document.content.utf16.count
                        session.editorPosition = draft.document.cursor; session.editing = true
                        session.sourcePath = await library.repository.sourcePath(id)
                    } else {
                        session.loadingWorkspaceDocument = true
                        await session.open(id, recoverSource: false)
                        session.loadingWorkspaceDocument = false
                        guard session.book?.id == id else { throw InkError.invalidDocument }
                    }
                    if let settings = windows.flatMap(\.panes).compactMap({ $0.viewPositions?[id.uuidString] }).first {
                        session.editing = settings.editing ?? session.editing
                        session.wrapsLines = settings.wrapsLines ?? false; session.columnMode = settings.columnMode ?? false
                    }
                    install(session, id: id)
                    if !windows.contains(where: { $0.panes.contains(where: { $0.tabs.contains(where: { $0.id == id }) }) }) {
                        windows[0].panes[0].tabs.append(.init(id: id)); windows[0].panes[0].selected = id
                    }
                } catch {
                    // Keep inaccessible entries and recovery files; reopening can request a new grant.
                    failure = error.localizedDescription
                }
            }
            if let first = windows.first {
                await focus(window: first.id, pane: first.focusedPane)
            }
        } catch {
            failure = error.localizedDescription
            if windows.isEmpty { windows = [.init(id: Self.defaultWindowID)] }
        }
    }

    private func makeSession() -> AppModel {
        let session = AppModel(sharedWith: library)
        session.workspace = self
        return session
    }
    private func install(_ model: AppModel, id: UUID) {
        sessions[id] = model
        subscriptions[id] = model.objectWillChange.sink { [weak self, weak model] _ in
            Task { @MainActor [weak self, weak model] in
                guard let self, let model else { return }
                for other in self.sessions.values where other !== model {
                    if other.fontSize != model.fontSize { other.fontSize = model.fontSize }
                    if other.readingTheme != model.readingTheme { other.readingTheme = model.readingTheme }
                }
                if self.library.fontSize != model.fontSize { self.library.fontSize = model.fontSize }
                if self.library.readingTheme != model.readingTheme { self.library.readingTheme = model.readingTheme }
                self.objectWillChange.send()
                self.scheduleLayout()
            }
        }
    }

    /// 查询窗口是否允许多文稿；普通 iPhone 与 Duo 单文稿窗口遵循同一规则。
    func multipleDocumentsAllowed(window: UUID) -> Bool { !singleDocumentWindows.contains(window) }

    /// 查询文稿是否启用自动正式保存；恢复草稿始终独立暂存。
    func automaticallySaves(_ document: UUID) -> Bool {
        let owners = windows.filter { $0.panes.contains { $0.tabs.contains { $0.id == document } } }
        return !owners.isEmpty && owners.allSatisfy { !multipleDocumentsAllowed(window: $0.id) }
    }

    /// 更新窗口的多文稿策略，保持当前文稿并协调单文稿替换。
    func setMultipleDocumentsAllowed(_ allowed: Bool, window: UUID) {
        guard multipleDocumentsAllowed(window: window) != allowed else { return }
        if allowed { singleDocumentWindows.remove(window) }
        else { singleDocumentWindows.insert(window) }
    }

    private func prepareSingleDocumentReplacement(_ id: UUID?, window: UUID) async -> Bool {
        guard !multipleDocumentsAllowed(window: window) else { return true }
        let previous = Set(self.window(window)?.panes.flatMap { $0.tabs.map(\.id) } ?? []).filter { $0 != id }
        guard !previous.isEmpty else { return true }
        // Ordinary iPhone keeps its original automatic-save contract. A failed save
        // leaves the current document open instead of dropping its recovery draft.
        do {
            for document in previous {
                guard let model = sessions[document] else { continue }
                model.commitEditing()
                if model.dirty || model.isNewDraft { try await model.save(formal: true) }
            }
        } catch { failure = error.localizedDescription; return false }
        return await close(Array(previous), window: window, rememberClosed: false)
    }

    /// 在目标窗口或分栏新建未命名草稿，不立即写入用户文件。
    func create(in windowID: UUID? = nil, pane paneID: UUID? = nil) async {
        guard !closing, !maintenance else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        focusedModel?.commitEditing()
        let target = windowID ?? focusedWindow ?? ensureWindow()
        guard await prepareSingleDocumentReplacement(nil, window: target) else { return }
        untitledSerial = max(untitledSerial, library.preferences.integer(forKey: "workspaceUntitledSerial")) + 1
        library.preferences.set(untitledSerial, forKey: "workspaceUntitledSerial")
        let document = Manuscript(title: L10n.tr("未命名 \(untitledSerial)"), format: .txt)
        let session = makeSession()
        session.book = document; session.savedBaseline = document; session.isNewDraft = true
        session.editing = true
        install(session, id: document.id)
        insert(document.id, into: target, pane: paneID)
        do { try await session.stashWorkingDraft(); try await persistLayout() }
        catch { failure = error.localizedDescription }
        await focus(window: target, pane: paneID)
    }

    /// 打开或聚焦文稿；阅读模式可复用当前标签，编辑模式保留独立标签。
    func open(_ id: UUID, reading: Bool? = nil, fromBeginning: Bool = false, recoverSource: Bool = true, in windowID: UUID? = nil, pane paneID: UUID? = nil, reuseReadingTab: Bool = true) async {
        if !ready { await restore(); while !ready { await Task.yield() } }
        let target = windowID ?? focusedWindow ?? ensureWindow()
        if reading == true, reuseReadingTab {
            await openReadingChapter(id, fromBeginning: fromBeginning, recoverSource: recoverSource, in: target, pane: paneID)
            return
        }
        guard !closing, !maintenance, !openingIDs.contains(id) else { return }
        openingIDs.insert(id)
        defer { openingIDs.remove(id) }
        if id != focusedDocument { focusedModel?.commitEditing() }
        var loadedSession: AppModel?
        if sessions[id] == nil {
            let session = makeSession()
            session.loadingWorkspaceDocument = true
            await session.open(id, reading: reading, fromBeginning: fromBeginning, recoverSource: recoverSource)
            session.loadingWorkspaceDocument = false
            guard session.book?.id == id else { failure = session.error; return }
            session.editing = !(reading ?? false)
            loadedSession = session
        }
        guard await prepareSingleDocumentReplacement(id, window: target) else { return }
        if let loadedSession { install(loadedSession, id: id) }
        insert(id, into: target, pane: paneID)
        if let session = sessions[id] {
            if reading == true && session.editing {
                session.commitEditing()
                await session.reparse()
            }
            if let reading { session.editing = !reading }
            if fromBeginning { session.jump(0) }
            session.detailRequest = UUID()
        }
        await focus(window: target, pane: paneID)
        // An already loaded tab still counts as an explicit open. Its history
        // entry may have been removed while the document remained open.
        await library.recordOpened(id)
        scheduleLayout()
    }

    /// 阅读跳章时原位替换标签；串行处理并保留需要恢复的未保存修改。
    func openReadingChapter(_ id: UUID, fromBeginning: Bool = true, recoverSource: Bool = true, in windowID: UUID? = nil, pane paneID: UUID? = nil) async {
        guard let window = windowID ?? focusedWindow, let layout = self.window(window),
              let original = layout.panes.first(where: { $0.id == (paneID ?? layout.focusedPane) }),
              !readingTransitions.contains(original.id), !closing, !maintenance else { return }
        let pane = original.id
        readingTransitions.insert(pane)
        defer { readingTransitions.remove(pane) }
        let previous = original.selected
        if let previous {
            sessions[previous]?.commitEditing()
            // A failed checkpoint must leave the old document and tab intact.
            do { try await sessions[previous]?.stashWorkingDraft() }
            catch { failure = error.localizedDescription; return }
        }
        await open(id, reading: true, fromBeginning: fromBeginning, recoverSource: recoverSource, in: window, pane: pane, reuseReadingTab: false)
        guard sessions[id]?.book?.id == id,
              self.window(window)?.panes.first(where: { $0.id == pane })?.selected == id else { return }
        if let previous, previous != id, let model = sessions[previous], !model.editing,
           !model.dirty, !model.isNewDraft,
           original.tabs.first(where: { $0.id == previous })?.pinned == false {
            // Keep the reading slot in the same position. The destination may already be open.
            reorder(id, before: previous, window: window, pane: pane)
            _ = await close([previous], window: window, pane: pane, rememberClosed: false)
        }
    }

    /// 导入用户选择的文件并打开对应文稿；遵循当前窗口单、多文稿策略。
    func importFiles(_ urls: [URL]) async {
        guard !closing, !maintenance else { return }
        pendingOperations += 1
        defer { pendingOperations -= 1 }
        let target = focusedWindow ?? ensureWindow()
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            do {
                // Do not reload an already-open buffer through the repository.
                if let existing = await matchingSession(url) {
                    await open(existing, in: target)
                } else {
                    let receipt = try await library.repository.openLocalFile(url)
                    await open(receipt.document.id, in: target)
                }
            } catch { failure = url.lastPathComponent + ": " + error.localizedDescription }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        await focus(window: target); scheduleLayout()
    }

    private func matchingSession(_ url: URL) async -> UUID? {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        for id in sessions.keys {
            if let source = try? await library.repository.sourceURL(id), source.resolvingSymlinksInPath().standardizedFileURL == canonical { return id }
        }
        return nil
    }

    /// 一次性领取待恢复的附加窗口，避免 SwiftUI 多次渲染重复开窗。
    func restoredWindowIDs() -> [UUID] {
        guard !restoredWindowsClaimed else { return [] }
        restoredWindowsClaimed = true
        return Array(windows.dropFirst().map(\.id))
    }

    /// 复用仍有效的窗口 ID；不存在时建立默认布局，不重复创建文稿会话。
    @discardableResult func ensureWindow(_ requested: UUID? = nil) -> UUID {
        if let requested, window(requested) != nil { return requested }
        if requested == nil, let first = windows.first { return first.id }
        let value = WorkspaceWindow(id: requested ?? Self.defaultWindowID); windows.append(value)
        focusedWindow = value.id; scheduleLayout(); return value.id
    }
    /// 将文稿加入目标分栏并选中；同分栏不重复创建相同文稿标签。
    func insert(_ id: UUID, into target: UUID, pane paneID: UUID? = nil) {
        guard let w = windows.firstIndex(where: { $0.id == target }),
              let p = windows[w].panes.firstIndex(where: { $0.id == (paneID ?? windows[w].focusedPane) }) else { return }
        if !windows[w].panes[p].tabs.contains(where: { $0.id == id }) { windows[w].panes[p].tabs.append(.init(id: id)) }
        windows[w].panes[p].selected = id
    }

    /// 切换窗口、分栏或文稿焦点；朗读所有权独立于界面焦点，切换标签不抢占播放。
    func focus(window: UUID, pane: UUID? = nil, document: UUID? = nil) async {
        guard let w = windows.firstIndex(where: { $0.id == window }) else { return }
        let previousPane = windows[w].focusedPane
        let previousDocument = model(window).book?.id
        if (pane != nil && pane != previousPane) || (document != nil && document != previousDocument) {
            if let previousDocument { commitNativeDocument(previousDocument) }
        }
        if let pane { windows[w].focusedPane = pane }
        if let document { insert(document, into: window, pane: pane) }
        let target = model(window, pane: pane)
        let targetPane = windows[w].focusedPane
        let generation = UUID(); focusGeneration = generation
        focusedWindow = window
        if let id = target.book?.id { library.preferences.set(id.uuidString, forKey: "lastBook") }
        for session in sessions.values { session.acceptsActions = session === target }
        library.acceptsActions = target === library
        if focusedDocument != target.book?.id {
            focusedModel?.commitEditing()
            do { try await focusedModel?.save() } catch { failure = error.localizedDescription }
            guard focusGeneration == generation, self.window(window) != nil else { return }
            focusedDocument = target.book?.id
            await target.refresh()
            if !library.speech.playing { await target.activateSpeech() }
        } else { await target.refresh() }
        #if os(macOS)
        await target.checkSourceChanges()
        #else
        await target.checkWorkspaceSourceChanges()
        #endif
        guard focusGeneration == generation, self.window(window) != nil else { return }
        if target.editing, let selected = target.book?.id,
           let state = editorStates[targetPane]?[selected], let host = state.host {
            #if os(macOS)
            if host.editor.window?.firstResponder !== host.editor { host.editor.window?.makeFirstResponder(host.editor) }
            #else
            if !host.editor.isFirstResponder { _ = host.editor.becomeFirstResponder() }
            #endif
        }
        scheduleLayout()
    }

    /// 提交原生编辑器的输入法组合文本和选区，不隐式写回原文件。
    @discardableResult func commitNativeDocument(_ id: UUID) -> Bool {
        guard let model = sessions[id] else { return false }
        for states in editorStates.values {
            guard let host = states[id]?.host else { continue }
            #if os(macOS)
            if host.editor.window?.isKeyWindow == true, host.editor.window?.firstResponder === host.editor {
                host.editor.unmarkText()
                model.editorPosition = host.editor.selectedRange().location
                if model.acceptsActions { host.editor.window?.makeFirstResponder(nil) }
            }
            #else
            if host.editor.window?.isKeyWindow == true, host.editor.isFirstResponder {
                host.editor.unmarkText()
                model.editorPosition = host.editor.selectedRange.location
                host.editor.resignFirstResponder()
            }
            #endif
        }
        if let text = textStorages[id]?.string {
            model.textChanged(String(decoding: text.utf8, as: UTF8.self))
        }
        return true
    }

    private var nativeFieldUndo: UndoManager? {
        #if os(macOS)
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.identifier?.rawValue != "manuscriptEditor" else { return nil }
        return editor.undoManager
        #else
        func field(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view is ColumnTextView ? nil : view }
            for child in view.subviews { if let result = field(in: child) { return result } }
            return nil
        }
        guard let focusedWindow, let scene = sceneReferences[focusedWindow]?.value else { return nil }
        for window in scene.windows where window.isKeyWindow { if let view = field(in: window) { return view.undoManager } }
        return nil
        #endif
    }
    private func documentUndoManager(_ id: UUID) -> UndoManager? {
        #if os(macOS)
        return undoManagers[id]
        #else
        // UIKit records keyboard and input-method edits in the retained text view's
        // native manager. Custom edits use that same manager, preserving their order.
        if let window = focusedWindow, let pane = self.window(window)?.focusedPane,
           let editor = editorStates[pane]?[id]?.host?.editor { return editor.undoManager }
        return editorStates.values.compactMap { $0[id]?.host?.editor.undoManager }.first
        #endif
    }
    var canUndo: Bool {
        if let field = nativeFieldUndo { return field.canUndo }
        return focusedModel?.editing == true && focusedModel?.documentReadOnly != true && (focusedDocument.flatMap { documentUndoManager($0)?.canUndo } ?? false)
    }
    var canRedo: Bool {
        if let field = nativeFieldUndo { return field.canRedo }
        return focusedModel?.editing == true && focusedModel?.documentReadOnly != true && (focusedDocument.flatMap { documentUndoManager($0)?.canRedo } ?? false)
    }
    /// 将撤销或重做交给当前文稿的原生撤销栈。
    func performUndo(redo: Bool = false) {
        if let field = nativeFieldUndo {
            if redo { if field.canRedo { field.redo() } } else if field.canUndo { field.undo() }
            return
        }
        guard let id = focusedDocument, sessions[id]?.editing == true, sessions[id]?.documentReadOnly != true, let manager = documentUndoManager(id) else { return }
        if redo { if manager.canRedo { manager.redo() } }
        else { if manager.canUndo { manager.undo() } }
        #if os(iOS)
        // UITextInput 的撤销结果以当前原生编辑器为准；共享存储在 UIKit
        // 完成同步前可能还是上一版，不能在重做后把旧正文重新写回会话。
        if let editor = editorStates.values.compactMap({ $0[id]?.host?.editor }).first(where: { $0.undoManager === manager }) {
            sessions[id]?.textChanged(editor.text)
        }
        #else
        if let text = textStorages[id]?.string { sessions[id]?.textChanged(text) }
        #endif
        objectWillChange.send()
    }

    /// 按相对顺序切换标签，保持原生编辑和阅读状态。
    func selectRelative(_ delta: Int, window: UUID) async {
        guard let layout = self.window(window), let pane = layout.panes.first(where: { $0.id == layout.focusedPane }),
              !pane.tabs.isEmpty else { return }
        let index = pane.tabs.firstIndex(where: { $0.id == pane.selected }) ?? 0
        await focus(window: window, pane: pane.id, document: pane.tabs[(index + delta + pane.tabs.count) % pane.tabs.count].id)
    }

    /// 保存指定分栏的侧栏显隐状态。
    func setSidebarVisible(_ visible: Bool, window: UUID, pane: UUID) {
        guard let w = windows.firstIndex(where: { $0.id == window }), let p = windows[w].panes.firstIndex(where: { $0.id == pane }) else { return }
        windows[w].panes[p].sidebarVisible = visible; scheduleLayout()
    }

    /// 统一更新窗口侧栏显隐，保持分栏与窗口布局一致。
    func setWindowSidebarVisible(_ visible: Bool, window: UUID) {
        guard let w = windows.firstIndex(where: { $0.id == window }) else { return }
        #if os(iOS)
        if visible, let document = model(window).book?.id { _ = commitNativeDocument(document) }
        #endif
        windows[w].sidebarVisible = visible
        if visible { focusModeWindows.remove(window) }
        scheduleLayout()
    }

    /// 切换窗口专注模式，隐藏或恢复辅助界面。
    func toggleFocusMode(window: UUID) {
        if focusModeWindows.contains(window) { focusModeWindows.remove(window) }
        else { focusModeWindows.insert(window) }
    }

    /// 修改指定标签元数据，随后安排保存布局。
    func updateTab(_ id: UUID, window: UUID, pane: UUID, change: (inout WorkspaceTab) -> Void) {
        guard let w = windows.firstIndex(where: { $0.id == window }), let p = windows[w].panes.firstIndex(where: { $0.id == pane }),
              let t = windows[w].panes[p].tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&windows[w].panes[p].tabs[t])
        windows[w].panes[p].tabs = windows[w].panes[p].tabs.filter(\.pinned) + windows[w].panes[p].tabs.filter { !$0.pinned }
        scheduleLayout()
    }
    /// 在同分栏调整标签顺序；固定标签仍遵循固定分组约束。
    func reorder(_ id: UUID, before target: UUID?, window: UUID, pane: UUID) {
        guard !closing, !maintenance,
              let w = windows.firstIndex(where: { $0.id == window }), let p = windows[w].panes.firstIndex(where: { $0.id == pane }) else { return }
        if windows[w].panes[p].moveTab(id, before: target) { scheduleLayout() }
    }

    /// 通过键盘命令向左或向右移动标签。
    func shiftTab(_ id: UUID, direction: Int, window: UUID, pane: UUID) {
        guard let tabs = self.window(window)?.panes.first(where: { $0.id == pane })?.tabs,
              let index = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index + direction),
              tabs[index].pinned == tabs[index + direction].pinned else { return }
        let targetIndex = direction < 0 ? index - 1 : index + 2
        reorder(id, before: tabs.indices.contains(targetIndex) ? tabs[targetIndex].id : nil, window: window, pane: pane)
    }

    /// 跨窗口或分栏移动标签，同时迁移视图状态并保持文稿身份不变。
    func moveTab(_ id: UUID, from sourceWindow: UUID, pane sourcePane: UUID, to targetWindow: UUID, pane targetPane: UUID, before target: UUID?) async {
        guard !closing, !maintenance, sessions[id] != nil,
              let source = window(sourceWindow)?.panes.first(where: { $0.id == sourcePane }),
              let tab = source.tabs.first(where: { $0.id == id }),
              let w = windows.firstIndex(where: { $0.id == targetWindow }),
              let p = windows[w].panes.firstIndex(where: { $0.id == targetPane }),
              target == nil || windows[w].panes[p].tabs.contains(where: { $0.id == target }) else { return }
        focusedModel?.commitEditing()
        if !windows[w].panes[p].tabs.contains(where: { $0.id == id }) {
            windows[w].panes[p].tabs.append(tab)
            if windows[w].panes[p].viewPositions == nil { windows[w].panes[p].viewPositions = [:] }
            windows[w].panes[p].viewPositions?[id.uuidString] = source.viewPositions?[id.uuidString]
        }
        if sourceWindow != targetWindow || sourcePane != targetPane {
            removeReferences([id], window: sourceWindow, pane: sourcePane)
        }
        reorder(id, before: target, window: targetWindow, pane: targetPane)
        await focus(window: targetWindow, pane: targetPane, document: id)
        scheduleLayout()
    }

    enum TabSortField: String, CaseIterable, Identifiable {
        case name, path, type, length, modified
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: L10n.tr("文件名")
            case .path: L10n.tr("完整路径")
            case .type: L10n.tr("文件类型")
            case .length: L10n.tr("字符数")
            case .modified: L10n.tr("修改时间")
            }
        }
    }

    /// 按名称、路径等字段稳定排序，保留固定分组与当前选中项。
    func sortTabs(window: UUID, pane: UUID, field: TabSortField, ascending: Bool) {
        guard !closing, !maintenance, let w = windows.firstIndex(where: { $0.id == window }),
              let p = windows[w].panes.firstIndex(where: { $0.id == pane }) else { return }
        let models = sessions
        windows[w].panes[p].sortTabs { a, b in
            let left = models[a.id], right = models[b.id]
            let result: ComparisonResult
            switch field {
            case .name: result = (left?.book?.fileName ?? "").localizedStandardCompare(right?.book?.fileName ?? "")
            case .path: result = (left?.sourcePath ?? left?.book?.fileName ?? "").localizedStandardCompare(right?.sourcePath ?? right?.book?.fileName ?? "")
            case .type: result = ((left?.book?.fileName ?? "") as NSString).pathExtension.localizedStandardCompare(((right?.book?.fileName ?? "") as NSString).pathExtension)
            case .length:
                let l = left?.textLength ?? 0, r = right?.textLength ?? 0
                result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
            case .modified:
                let l = left?.book?.updatedAt ?? .distantPast, r = right?.book?.updatedAt ?? .distantPast
                result = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        scheduleLayout()
    }

    /// 文稿被永久删除时同步清理最近关闭记录，避免提供无法重开的标签。
    func forgetClosedTabs(for id: UUID) {
        recentlyClosedTabs.removeAll { $0.tab.id == id }
        scheduleLayout()
    }

    /// 恢复最近关闭标签及位置；文稿已不存在时不重建空白副本。
    func reopenClosedTab(_ record: ClosedWorkspaceTab? = nil, in windowID: UUID? = nil, pane paneID: UUID? = nil) async {
        guard !closing, !maintenance, let record = record ?? recentlyClosedTabs.first else { return }
        guard let formal = try? await library.repository.load(record.tab.id), formal.trashedAt == nil else {
            forgetClosedTabs(for: record.tab.id); failure = InkError.invalidDocument.localizedDescription; return
        }
        let target = windowID ?? focusedWindow ?? ensureWindow()
        guard let layout = window(target), let pane = layout.panes.first(where: { $0.id == (paneID ?? layout.focusedPane) }) else { return }
        let existing = pane.tabs.contains { $0.id == record.tab.id }
        await open(record.tab.id, reading: sessions[record.tab.id] == nil ? !record.editing : nil,
                   in: target, pane: pane.id, reuseReadingTab: false)
        guard window(target)?.panes.first(where: { $0.id == pane.id })?.selected == record.tab.id else { return }
        if !existing {
            updateTab(record.tab.id, window: target, pane: pane.id) { $0 = record.tab }
            let tabs = window(target)?.panes.first(where: { $0.id == pane.id })?.tabs.filter { $0.id != record.tab.id } ?? []
            reorder(record.tab.id, before: tabs.indices.contains(record.index) ? tabs[record.index].id : nil, window: target, pane: pane.id)
            sessions[record.tab.id]?.jump(record.cursor)
        }
        recentlyClosedTabs.removeAll { $0.id == record.id }
        scheduleLayout()
    }

    /// 创建第二分栏；clone 为 true 时共享同一文稿身份及正文。
    func split(_ document: UUID, window: UUID, pane: UUID, clone: Bool) async {
        focusedModel?.commitEditing()
        guard !closing, !maintenance, let w = windows.firstIndex(where: { $0.id == window }) else { return }
        if windows[w].panes.count == 1 { windows[w].panes.append(.init()) }
        guard let other = windows[w].panes.first(where: { $0.id != pane })?.id else { return }
        insert(document, into: window, pane: other)
        if !clone { removeReferences([document], window: window, pane: pane) }
        await focus(window: window, pane: other); scheduleLayout()
    }

    /// 创建文稿窗口，可选择从原窗口移入标签。
    func newWindow(document: UUID?, movingFrom source: UUID? = nil, pane: UUID? = nil) -> UUID {
        focusedModel?.commitEditing()
        let target = UUID(); _ = ensureWindow(target)
        if let document { insert(document, into: target) }
        if let document, let source { removeReferences([document], window: source, pane: pane) }
        scheduleLayout(); return target
    }

    /// 完成正在等待的保存确认；保存、放弃和取消由统一关闭流程消费。
    func answerClose(_ value: CloseChoice) {
        let reply = closeReply; closeReply = nil; closeQuestion = nil
        Task { @MainActor in
            // SwiftUI must dismiss the preceding alert before the next batch question is presented.
            try? await Task.sleep(for: .milliseconds(300))
            reply?.resume(returning: value)
        }
    }
    /// 向正在等待的另存为流程返回目标 URL；nil 表示用户取消。
    func finishExport(_ url: URL?) {
        let reply = exportReply; exportReply = nil; exportSnapshot = nil; exportWindow = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            reply?.resume(returning: url)
        }
    }

    /// 协调写入另存为目标，并在建立持久关联前保持目录授权有效。
    func writeExport(_ snapshot: Manuscript, folder: URL, name: String) async throws {
        guard Manuscript.validFileName(name) else { throw InkError.invalidDocument }
        let access = folder.startAccessingSecurityScopedResource()
        let target = folder.appendingPathComponent(name)
        do {
            if let owner = await matchingSession(target), owner != snapshot.id { throw InkError.invalidDocument }
            // Hold the directory grant until finishSaveAs has established the persistent source reference.
            var coordinationError: NSError?, writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &coordinationError) { destination in
                do { try Data(snapshot.content.utf8).write(to: destination, options: .atomic) }
                catch { writeError = error }
            }
            if let error = coordinationError ?? writeError as NSError? { throw error }
            if access { exportDirectoryAccess = folder }
            finishExport(target)
        } catch {
            if access { folder.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// 正式保存指定文稿；未命名文稿或 saveAs 会请求目标，取消或失败返回 false。
    @discardableResult func saveDocument(_ id: UUID, window: UUID? = nil, saveAs: Bool = false) async -> Bool {
        guard !maintenance, let model = sessions[id], !savingDocuments.contains(id) else { return false }
        savingDocuments.insert(id)
        defer { savingDocuments.remove(id) }
        model.commitEditing()
        guard !model.documentReadOnly || saveAs else { failure = L10n.tr("文稿为只读，请先取消只读再保存。"); return false }
        defer {
            exportDirectoryAccess?.stopAccessingSecurityScopedResource(); exportDirectoryAccess = nil
        }
        do {
            if saveAs || model.isNewDraft || model.sourcePath == nil {
                guard let snapshot = model.snapshotForSaveAs() else { return false }
                let url: URL?
                #if os(macOS)
                url = try await DocumentActions.saveAs(snapshot) { [weak self] url in
                    if let owner = await self?.matchingSession(url), owner != id { throw InkError.invalidDocument }
                }
                #else
                guard exportReply == nil else { return false }
                exportWindow = window ?? focusedWindow
                url = await withCheckedContinuation { continuation in exportReply = continuation; exportSnapshot = snapshot }
                #endif
                guard let url else { return false }
                // A save-as must never silently bind two buffers to one destination.
                if let owner = await matchingSession(url), owner != id { throw InkError.invalidDocument }
                try await model.finishSaveAs(url, snapshot: snapshot)
            } else { try await model.save(formal: true) }
            if model.dirty { try await model.stashWorkingDraft(); return false }
            try await persistLayout()
            #if DEBUG
            await refreshOriginalFileEvidence()
            #endif
            return true
        } catch { failure = error.localizedDescription; return false }
    }

    /// 依次保存窗口中有修改的文稿；任一取消或失败即停止后续保存。
    func saveAll(window: UUID) async {
        for id in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) where sessions[id]?.dirty == true || sessions[id]?.isNewDraft == true {
            if !(await saveDocument(id, window: window)) { return }
        }
    }

    /// 关闭窗口内全部文稿，复用逐文稿保存确认流程。
    func closeAll(in window: UUID) async {
        let ids = self.window(window)?.panes.flatMap { $0.tabs.map(\.id) } ?? []
        guard await close(ids, window: window) else { return }
        if self.window(window)?.panes.allSatisfy({ $0.tabs.isEmpty }) == true { await create(in: window) }
    }

    /// 关闭指定文稿标签；未保存修改先询问，取消时保留原状。
    func closeDocument(_ id: UUID) async {
        guard let window = focusedWindow, let pane = self.window(window)?.focusedPane else { return }
        _ = await close([id], window: window, pane: pane)
    }

    /// 串行关闭一组文稿：先提交输入，再逐项确认保存；任何取消都终止本次关闭。
    /// entireApplication 保留重启布局，rememberClosed 控制是否加入最近关闭记录。
    @discardableResult func close(_ ids: [UUID], window: UUID, pane: UUID? = nil, entireApplication: Bool = false, rememberClosed: Bool = true) async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") { closeEvidence = "requested:" + String(ids.count) }
        #endif
        guard !closing, !maintenance, savingDocuments.isDisjoint(with: ids) else { return false }
        closing = true
        defer { closing = false }
        focusedModel?.commitEditing()
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let finalIDs = unique.filter { id in
            entireApplication || !windows.contains(where: { layout in layout.panes.contains(where: { candidate in
                let affected = layout.id == window && (pane == nil || candidate.id == pane)
                return !affected && candidate.tabs.contains(where: { $0.id == id })
            }) })
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") { closeEvidence += " final:" + String(finalIDs.count) }
        #endif
        var discarded = Set<UUID>()
        for (index, id) in finalIDs.enumerated() {
            guard let model = sessions[id] else { continue }
            model.commitEditing()
            do { try await model.stashWorkingDraft() } catch { failure = error.localizedDescription; return false }
            if model.dirty {
                let choice = await withCheckedContinuation { continuation in
                    closeReply = continuation
                    closeQuestion = .init(window: window, name: model.book?.fileName ?? "", index: index + 1, count: finalIDs.count)
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") { closeEvidence += " asking:" + (model.book?.fileName ?? "") }
                    #endif
                }
                switch choice {
                case .cancel: return false
                case .save: if !(await saveDocument(id, window: window)) { return false }
                case .discard: discarded.insert(id)
                }
            }
        }
        let previousClosed = recentlyClosedTabs
        if rememberClosed && !entireApplication {
            for candidate in self.window(window)?.panes ?? [] where pane == nil || candidate.id == pane {
                for (index, tab) in candidate.tabs.enumerated() where unique.contains(tab.id) {
                    guard let model = sessions[tab.id], !model.isNewDraft else { continue }
                    recentlyClosedTabs.removeAll { $0.tab.id == tab.id && $0.window == window && $0.pane == candidate.id }
                    recentlyClosedTabs.insert(.init(tab: tab, window: window, pane: candidate.id, index: index,
                        fileName: model.book?.fileName ?? "", editing: model.editing,
                        cursor: model.editing ? model.editorPosition : (model.book?.cursor ?? 0)), at: 0)
                }
            }
            recentlyClosedTabs = Array(recentlyClosedTabs.prefix(20))
        }
        // Remove the persistent references before deleting recoveries. A cancelled batch changes neither.
        let previous = windows
        if entireApplication {
            // Keep saved tabs for the next launch; unnamed discarded drafts have no formal document to restore.
            for w in windows.indices {
                for p in windows[w].panes.indices {
                    windows[w].panes[p].tabs.removeAll { sessions[$0.id]?.isNewDraft == true }
                    if !windows[w].panes[p].tabs.contains(where: { $0.id == windows[w].panes[p].selected }) {
                        windows[w].panes[p].selected = windows[w].panes[p].tabs.first?.id
                    }
                }
            }
        } else { removeReferences(unique, window: window, pane: pane) }
        do { try await persistLayout() }
        catch { windows = previous; recentlyClosedTabs = previousClosed; failure = error.localizedDescription; return false }
        for id in finalIDs {
            if speechDocument == id { library.speech.stop(); speechDocument = nil }
            do { try await library.repository.removeWorkingDraft(id) }
            catch { failure = error.localizedDescription; windows = previous; recentlyClosedTabs = previousClosed; try? await persistLayout(); return false }
            if discarded.contains(id), let baseline = sessions[id]?.savedBaseline { sessions[id]?.book = baseline; sessions[id]?.editorText = baseline.content }
            subscriptions[id] = nil; undoManagers[id]?.removeAllActions(); undoManagers[id] = nil; textStorages[id] = nil
            #if os(iOS)
            for states in editorStates.values { states[id]?.host?.editor.undoManager?.removeAllActions() }
            #endif
            for key in Array(editorStates.keys) { editorStates[key]?[id] = nil }
            sessions[id] = nil
        }
        if !entireApplication { await focus(window: window) }
        if let pane, self.window(window)?.panes.first(where: { $0.id == pane })?.tabs.isEmpty == true {
            Task { [weak self] in
                guard let self, self.window(window)?.panes.contains(where: { $0.id == pane && $0.tabs.isEmpty }) == true else { return }
                await self.focus(window: window, pane: pane); await self.create(in: window)
            }
        }
        return true
    }

    /// 先确认全部文稿的关闭，再移除窗口；取消时返回 false。
    func closeWindow(_ id: UUID) async -> Bool {
        let ids = window(id)?.panes.flatMap { $0.tabs.map(\.id) } ?? []
        guard await close(ids, window: id) else { return false }
        windows.removeAll { $0.id == id }; scheduleLayout(); return true
    }

    /// 执行全应用关闭确认，保留下一次启动需要恢复的工作区信息。
    func closeApplication() async -> Bool {
        guard let target = focusedWindow ?? windows.first?.id else { return true }
        return await close(Array(sessions.keys), window: target, entireApplication: true)
    }

    private func removeReferences(_ ids: [UUID], window: UUID, pane: UUID?) {
        guard let w = windows.firstIndex(where: { $0.id == window }) else { return }
        for p in windows[w].panes.indices where pane == nil || windows[w].panes[p].id == pane {
            let previous = windows[w].panes[p].tabs.firstIndex(where: { $0.id == windows[w].panes[p].selected }) ?? 0
            windows[w].panes[p].tabs.removeAll { ids.contains($0.id) }
            for id in ids { windows[w].panes[p].viewPositions?[id.uuidString] = nil }
            if !windows[w].panes[p].tabs.contains(where: { $0.id == windows[w].panes[p].selected }) {
                let tabs = windows[w].panes[p].tabs
                windows[w].panes[p].selected = tabs.isEmpty ? nil : tabs[min(previous, tabs.count - 1)].id
            }
        }
    }

    /// 提交原生输入并暂存所有恢复草稿和布局；不等价于用户执行正式保存。
    func checkpoint() async {
        focusedModel?.commitEditing()
        do {
            for model in sessions.values { model.commitEditing(); try await model.stashWorkingDraft() }
            try await persistLayout()
        } catch { failure = error.localizedDescription }
    }
    private func scheduleLayout() {
        guard ready, !restoring else { return }
        stateTask?.cancel()
        stateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            do { try await self.persistLayout() } catch { self.failure = error.localizedDescription }
        }
    }
    private func persistLayout() async throws {
        for w in windows.indices {
            for p in windows[w].panes.indices {
                let pane = windows[w].panes[p].id
                if windows[w].panes[p].viewPositions == nil { windows[w].panes[p].viewPositions = [:] }
                for tab in windows[w].panes[p].tabs {
                    guard let model = sessions[tab.id] else { continue }
                    var range = NSRange(location: model.book?.cursor ?? 0, length: 0), origin = CGPoint.zero
                    if model.editing, let host = editorStates[pane]?[tab.id]?.host {
                        #if os(macOS)
                        range = host.editor.selectedRange(); origin = host.scroll.contentView.bounds.origin
                        #else
                        range = host.editor.selectedRange; origin = CGPoint(x: host.horizontalScroll.contentOffset.x, y: host.editor.contentOffset.y)
                        #endif
                    } else if let offset = editorStates[pane]?[tab.id]?.readerOffset { range.location = offset }
                    windows[w].panes[p].viewPositions?[tab.id.uuidString] = .init(cursor: range.location, selectionLength: range.length, x: origin.x, y: origin.y, editing: model.editing, wrapsLines: model.wrapsLines, columnMode: model.columnMode)
                }
            }
        }
        stateTask?.cancel(); stateTask = nil
        try await library.repository.saveWorkspace(.init(windows: windows, recentlyClosed: recentlyClosedTabs))
    }
}

#if DEBUG
extension DocumentWorkspace {
    /// 仅隔离 UI 测试使用：自动读取测试原文件，核对“暂存”和“正式保存”的边界。
    /// 不创建可见按钮，不定时轮询，也不进入 Release；结果只供无障碍断言读取。
    func refreshOriginalFileEvidence() async {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") else { return }
        var evidence: [String] = []
        let ids = Set((try? await library.repository.list().map(\.id)) ?? []).union(sessions.keys)
        for id in ids {
            if let url = try? await library.repository.sourceURL(id) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    evidence.append(url.lastPathComponent + "=" + content)
                }
            }
        }
        diskEvidence = evidence.sorted().joined(separator: "|")
    }
}
#endif
