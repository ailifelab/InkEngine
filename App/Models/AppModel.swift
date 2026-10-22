import SwiftUI
import InkCore

struct ReceivedSync: Codable {
    var entry: RecentEntry
    var title: String
    var count: Int
    var note: String
}

@MainActor final class AppModel: ObservableObject {
    @Published var books: [BookSummary] = []
    @Published var novels: [NovelCollection] = []
    @Published var book: Manuscript?
    @Published var editorText = ""
    @Published var textLength = 0
    @Published var parsed = ParsedText(segments: [], chapters: [])
    @Published var editing = false
    @Published var wrapsLines = false
    /// 自动换行与列选互斥；启用换行时退出列模式，使按钮状态与实际排版一致。
    var lineWrappingEnabled: Bool {
        get { wrapsLines && !columnMode }
        set { if newValue { columnMode = false }; wrapsLines = newValue }
    }
    @Published var editorPosition = 0
    @Published var editorNavigationID = UUID()
    @Published var detailRequest = UUID()
    @Published var readingTheme: ReadingTheme = .white {
        didSet { preferences.set(readingTheme.rawValue, forKey: "readingTheme") }
    }
    @Published var dirty = false
    @Published var busy = false
    @Published private(set) var initialized = false
    @Published var status = L10n.tr("打开本地文件；编辑保存回原文件，阅读模式只读。")
    @Published private(set) var exportStatus: String?
    @Published var error: String?
    @Published var searchQuery = ""
    @Published var replacementQuery = ""
    @Published var findOptions = FindOptions()
    @Published var searchMessage = ""
    @Published var columnMode = false
    @Published var editorMutation: EditorMutation?
    @Published var history = RecentHistory()
    @Published var sourcePath: String?
    @Published var searchResults: [NSRange] = []
    @Published var scrollTarget: Int?
    @Published var pendingSync: RecentEntry?
    @Published var showNearby = false
    #if os(iOS)
    @Published var showLocalDocuments = false
    #else
    @Published private(set) var sourceConflict = false
    private var sourceObserver: LocalFileObserver?
    private var folderObservers: [String: LocalFileObserver] = [:]
    private var checkingSource = false
    #endif
    @Published var receivedSync: ReceivedSync?
    @Published var libraryRequest = UUID()
    var requestedHistoryEntry: RecentEntry?
    @Published var pendingHandoff: UUID?
    @Published var fontSize: Double = 21 { didSet { preferences.set(fontSize, forKey: "fontSize") } }
    let preferences: UserDefaults
    let repository: LibraryRepository
    let speech: SpeechEngine
    let nearby: NearbyService
    weak var workspace: DocumentWorkspace?
    var savedBaseline: Manuscript?
    var isNewDraft = false
    @Published var documentReadOnly = false
    private var checkingWorkspaceSource = false
    private var reportedWorkspaceSourceConflict = false
    var manualSaving: Bool { workspace != nil }
    private var usesAutomaticSaving: Bool {
        !manualSaving || (book.map { workspace?.automaticallySaves($0.id) == true } ?? false)
    }
    var loadingWorkspaceDocument = false
    var acceptsActions = true

    private var saveTask: Task<Void, Never>?
    private var workingSaveTask: Task<Void, Error>?
    private var savingFormal = false
    #if DEBUG
    var onPagePrepared: ((Int, Double, Int, Int) -> Void)?
    #if os(macOS)
    @Published private(set) var testDiskContent = ""
    /// 仅隔离测试使用：修改测试原文件以验证监听和冲突处理，不暴露到正常界面。
    func testWriteSource(_ content: String? = nil) async {
        guard ProcessInfo.processInfo.arguments.contains("--source-watch-ui-testing"), let id = book?.id else { return }
        do {
            guard let url = try await repository.sourceURL(id) else { return }
            if let content { try Data(content.utf8).write(to: url, options: .atomic) }
            testDiskContent = try String(contentsOf: url, encoding: .utf8)
            // 仅改变磁盘，不调用重载：回归必须由真实文件事件触发界面更新。
        } catch { self.error = error.localizedDescription }
    }
    #endif
    #endif
    private var positionTask: Task<Void, Never>?
    private var parseGeneration = UUID()
    private var opening = false
    private var creating = false
    private var modeChanging = false
    private var navigationGeneration = UUID()
    private var historyWriteTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var refreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearingCaches = false

    /// 创建资料库模型或文稿会话；子会话共享仓库、偏好与朗读服务，编辑缓冲独立保存。
    init(sharedWith parent: AppModel? = nil) {
        if let parent {
            preferences = parent.preferences; repository = parent.repository
            speech = parent.speech; nearby = parent.nearby
            readingTheme = parent.readingTheme; fontSize = parent.fontSize
            books = parent.books; novels = parent.novels; history = parent.history; receivedSync = parent.receivedSync
            initialized = true
            return
        }
        let customRoot = ProcessInfo.processInfo.environment["INK_LIBRARY_PATH"]
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        preferences = testing ? UserDefaults(suiteName: "org.ailifelab.InkEngine.UITests")! : .standard
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { preferences.removePersistentDomain(forName: "org.ailifelab.InkEngine.UITests") }
        speech = SpeechEngine(preferences: preferences)
        nearby = NearbyService()
        readingTheme = ReadingTheme(rawValue: preferences.string(forKey: "readingTheme") ?? "white") ?? .white
        fontSize = preferences.double(forKey: "fontSize") == 0 ? 21 : preferences.double(forKey: "fontSize")
        let root = customRoot.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(testing ? (ProcessInfo.processInfo.arguments.contains("--large-file-ui-testing") ? "InkEngineLargeTest/Library" : "InkEngineUITests/Library") : "InkEngine/Library")
        #if DEBUG && targetEnvironment(simulator)
        let integrationRun = ProcessInfo.processInfo.arguments.contains("--nearby-integration") ? ProcessInfo.processInfo.environment["INK_NEARBY_RUN"].flatMap(UUID.init(uuidString:)) : nil
        let actualRoot = integrationRun.map { root.deletingLastPathComponent().appendingPathComponent("NetworkTests/\($0.uuidString)/Library") } ?? root
        #else
        let actualRoot = root
        #endif
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { try? FileManager.default.removeItem(at: root) }
        #if os(iOS)
        let userDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let documents = testing || customRoot != nil ? actualRoot.deletingLastPathComponent().appendingPathComponent("SharedDocuments") : userDocuments
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { try? FileManager.default.removeItem(at: documents) }
        #else
        // Mac 始终关联用户选择的原文件；私有目录只保留恢复、历史与阅读位置。
        let documents: URL? = nil
        #endif
        do { repository = try LibraryRepository(root: actualRoot, documentsDirectory: documents) }
        catch { fatalError(L10n.tr("无法创建书库：\(error.localizedDescription)")) }
        if let data = preferences.data(forKey: "receivedSync") { receivedSync = try? JSONDecoder().decode(ReceivedSync.self, from: data) }
        speech.onPosition = { [weak self] offset in self?.setPosition(offset, fromSpeech: true) }
        speech.onFinished = { [weak self] id, revision in
            guard let self else { return }
            let generation = self.navigationGeneration
            let transport = self.speech.transportGeneration
            Task { await self.continueNovel(after: id, revision: revision, generation: generation, transport: transport) }
        }
        nearby.currentDocument = { [weak self] id in
            guard let self else { return nil }
            try await self.save()
            if let id {
                if let snapshot = self.workspace?.sessions[id]?.workingSnapshot() { return snapshot }
                return try await self.repository.load(id)
            }
            return self.workspace?.focusedModel?.workingSnapshot() ?? self.book
        }
        nearby.receiveDocument = { [weak self] document, checksum in
            guard let self else { throw InkError.invalidDocument }
            if let workspace = self.workspace { await workspace.checkpoint() }
            try await self.save()
            let (received, decision) = try await self.repository.receive(document, checksum: checksum)
            await self.refresh()
            if decision != .keepLocal {
                await self.refreshReceivedSession(received)
                await self.open(received.id)
            }
            let note: String
            switch decision {
            case .same: note = L10n.tr("内容相同，已恢复阅读位置。")
            case .acceptRemote: note = L10n.tr("文稿与位置已保存为离线副本。")
            case .keepLocal: note = L10n.tr("本地版本较新，保留本地。可发送回对方同步。")
            case .conflict: note = L10n.tr("双方有修改，已保留本地文稿与收到的冲突副本。")
            }
            self.status = note
            return note
        }
        nearby.receiveTransfer = { [weak self] transfer in
            guard let self else { throw InkError.invalidDocument }
            if let workspace = self.workspace { await workspace.checkpoint() }
            try await self.save()
            await self.historyWriteTask?.value
            let current = self.book?.id
            let receipt = try await self.repository.receiveTransfer(transfer)
            await self.refresh()
            for item in transfer.manifest.items {
                if let received = try? await self.repository.load(item.documentID) { await self.refreshReceivedSession(received) }
            }
            if let current, transfer.manifest.items.contains(where: { $0.documentID == current }) { await self.open(current, reading: !self.editing) }
            self.history.opened(receipt.entry); await self.queueHistorySave().value
            let title = receipt.entry.isFolder ? self.novels.first(where: { $0.id == receipt.entry.id })?.alias : self.books.first(where: { $0.id == receipt.entry.id })?.fileName
            #if os(iOS)
            let note = receipt.note + L10n.tr("已保存到接收端的本机文稿，可从历史记录打开。")
            #else
            let note = receipt.note + L10n.tr("可从历史记录打开收到的副本，通过另存为选择本地保存位置。")
            #endif
            self.receivedSync = ReceivedSync(entry: receipt.entry, title: title ?? transfer.manifest.title, count: receipt.count, note: note)
            if let data = try? JSONEncoder().encode(self.receivedSync) { self.preferences.set(data, forKey: "receivedSync") }
            self.status = note
            return note
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { nearby.isTesting = true }
        #if DEBUG
        // 只测试确认/取消界面；不建立网络连接，不发送文件，也不触发系统局域网授权。
        if testing && ProcessInfo.processInfo.arguments.contains("--paired-nearby-ui-testing") {
            nearby.ready = true; nearby.peerName = "测试 iPad"; nearby.running = true
        }
        #endif
        Task {
            defer { initialized = true }
            #if os(macOS)
            let startupNavigation = navigationGeneration
            #endif
            #if DEBUG && targetEnvironment(simulator)
            if let integrationRun {
                if ProcessInfo.processInfo.environment["INK_NEARBY_SCENARIO"] == "batch" { await runBatchIntegration(runID: integrationRun) }
                else { await runNearbyIntegration(runID: integrationRun) }
                return
            }
            #endif
            await refresh()
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") && books.isEmpty {
                do {
                    let directory = actualRoot.deletingLastPathComponent().appendingPathComponent("TabFixtures")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let urls = ["标签甲.txt", "标签乙.txt"].map { directory.appendingPathComponent($0) }
                    for url in urls {
                        let text = ProcessInfo.processInfo.arguments.contains("--tab-audio-ui-testing")
                            ? String(repeating: (ProcessInfo.processInfo.arguments.contains("--zipvoice-tab-audio-ui-testing") ? "" : url.lastPathComponent + "。") + "窗外的风带来了雨的气息，她放下手中的书，继续阅读下一段文字。\n", count: 80)
                            : (url.lastPathComponent == "标签甲.txt" ? "Alpha original" : "Beta original")
                        try Data(text.utf8).write(to: url)
                    }
                    if let workspace { await workspace.importFiles(urls) }
                    else { await importFiles(urls) }
                } catch { self.error = error.localizedDescription }
            }
            #endif
            if !testing && ProcessInfo.processInfo.arguments.contains("--clear-generated-caches") { await runGeneratedCacheCleanup() }
            await refresh()
            if !testing { nearby.discoverRememberedDevices() }
            #if DEBUG && os(iOS)
            if testing && ProcessInfo.processInfo.arguments.contains("--speech-quality-probe") { await speech.runVoiceQualityProbe() }
            if testing && ProcessInfo.processInfo.arguments.contains("--local-documents-ui-testing") && books.isEmpty {
                for (name, text) in [("目录浏览测试/第1章.txt", "第一章正文。"), ("目录浏览测试/下篇/第2章.md", "# 第二章\n\n后续正文。"), ("另一部小说/第1章.txt", "另一部小说。"), ("独立文稿.txt", "独立正文。") ] {
                    let file = documents.appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? Data(text.utf8).write(to: file)
                }
                await refresh()
            }
            #endif
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--novel-ui-testing") && novels.isEmpty {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("章节测试-" + UUID().uuidString)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, text) in [("第1章.md", "# 第一章\n\n清风吹来。"), ("第2章.md", "# 第二章\n\n故事继续。"), ("第10章.md", "# 第十章\n\n远山如画。"), ("章节目录.md", "# 目录\n\n第一章、第二章、第十章。") ] {
                    try? Data(text.utf8).write(to: folder.appendingPathComponent(name))
                }
                _ = try? await repository.importFolder(folder, alias: "连续朗读测试")
                await refresh()
            }
            #endif
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--editor-history-ui-testing") && books.isEmpty {
                for name in ["历史甲", "历史乙", "编辑功能测试"] {
                    try? await repository.save(Manuscript(title: name, format: .txt, content: "alpha11\nalpha22\nalpha33"))
                }
                if ProcessInfo.processInfo.arguments.contains("--removed-draft-cache-ui-testing"),
                   let summary = try? await repository.list().first(where: { $0.title == "历史甲" }) {
                    do {
                        var draft = try await repository.load(summary.id)
                        draft.bookmarks = [.init(name: "待清理书签", offset: 0, content: draft.content)]
                        draft.advanceRevision(); try await repository.save(draft)
                        let audio = actualRoot.deletingLastPathComponent().appendingPathComponent("AudioResume")
                        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                        try Data(repeating: 0, count: 4096).write(to: audio.appendingPathComponent(summary.id.uuidString + "-cleanup-test.pcm"))
                    } catch { self.error = error.localizedDescription }
                }
                await refresh()
            }
            #endif
            #if DEBUG
            #if os(macOS)
            if testing && ProcessInfo.processInfo.arguments.contains("--source-watch-ui-testing") && books.isEmpty {
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/SourceWatch")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("原文件测试.txt")
                    try Data("Original text".utf8).write(to: file, options: .atomic)
                    _ = try await repository.openLocalFile(file)
                    await refresh()
                } catch { self.error = error.localizedDescription }
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--html-preview-ui-testing") && books.isEmpty {
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/HTMLPreview")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("HTML预览测试.htm")
                    try Data("<!doctype html><link rel=\"stylesheet\" href=\"style.css\"><p>Original preview</p>".utf8).write(to: file)
                    try Data("body { color: green; }".utf8).write(to: folder.appendingPathComponent("style.css"))
                    _ = try await repository.openLocalFile(file)
                    try await repository.save(Manuscript(title: "无原文件HTML", format: .html, content: "<p>Application document</p>"))
                    try await repository.save(Manuscript(title: "普通文本", format: .txt, content: "Plain text"))
                    await refresh()
                } catch { self.error = error.localizedDescription }
            }
            #endif
            if testing && ProcessInfo.processInfo.arguments.contains("--synthetic-large-ui-testing") && books.isEmpty {
                let paragraph = "阅读性能校验，页码和原文位置需要保持一致。这是自动生成的测试段落，并非真实小说。\n\n"
                let source = String(repeating: paragraph, count: 110_000)
                try? await repository.save(Manuscript(title: "大文件分页测试", format: .txt, content: source))
                await refresh()
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), !ProcessInfo.processInfo.arguments.contains("--empty-history-ui-testing"), books.isEmpty {
                var sample = Manuscript(title: "校稿测试", content: "# 第一章 清晨\n\n窗外的风带来了雨的气息。墨语引擎让每一个句子都可以被听见。\n\n这是第二段，用来验证朗读与位置恢复。\n\n# 第二章 远行\n\n故事从这里继续。\n")
                if ProcessInfo.processInfo.arguments.contains("--speech-ui-testing") {
                    sample.content = "# 第一章 清晨\n\n窗外的风带来了雨的气息。她放下手中的书，望向远处的群山。风吹过树梢，带来草木和泥土的清香。\n\n这是第二个自然段，用来验证连续朗读和暂停恢复。河边的银行已经关门，值班的行长仍在等待。他们走过长江，也登上过长白山。\n\n故事从这里继续。她慢慢整理桌上的书和纸，给远行的朋友写下一封长信。信中的每一句话，都留着平静而温暖的停顿。最后，她合上信纸，推开了窗。\n"
                }
                if testing && ProcessInfo.processInfo.arguments.contains("--editor-layout-testing") {
                    sample.content = "开始：" + String(repeating: "中文 abc😀，透明亚克力键帽。", count: 60) + "\n短行\n\n第四行\n第五行\n第六行\n第七行\n"
                }
                #if DEBUG
                if testing && ProcessInfo.processInfo.arguments.contains("--unrecognized-speech-ui-testing") {
                    sample.content = "汉字𠮷和 English hello 都不能漏掉。接下来继续完整朗读正文。\n\n最后一段用于验证继续的位置。"
                }
                #endif
                #if DEBUG
                if testing && ProcessInfo.processInfo.arguments.contains("--matcha-missing-word-ui-testing") {
                    let line = "石隙藏身终被缚，铜声劝死未援人。"
                    let markdown = ProcessInfo.processInfo.arguments.contains("--missing-word-markdown")
                    sample.format = markdown ? .markdown : .txt
                    sample.content = String(repeating: markdown ? "**" + line + "**\n\n" : line + "\n\n", count: 12)
                }
                #endif
                sample.sourceName = "测试样本"
                if testing && ProcessInfo.processInfo.arguments.contains("--end-of-file-ui-testing") {
                    sample.content = "正文已经写好。\n\n这是最后一段，不能误报没有正文。\n\n\n"
                    sample.cursor = sample.content.utf16.count
                }
                if testing && ProcessInfo.processInfo.arguments.contains("--markdown-table-ui-testing") {
                    sample.title = "表格测试"
                    sample.content = "# 章节目录\n\n| 章节 | 内容 | 字数 |\n| :--- | :---: | ---: |\n" + (1...35).map { "| 第\($0)章 | **山路上的中文正文说明，包含折行与😀。** | \(2000 + $0) |\n" }.joined() + "\n表格结束后的正文。\n"
                }
                if testing && ProcessInfo.processInfo.arguments.contains("--markdown-long-row-ui-testing") {
                    sample.title = "跨页表格"
                    let longCell = (1...400).map { String(format: "续写%04d，", $0) }.joined()
                    sample.content = "| 章节 | 长单元格 | 字数 |\n| --- | --- | ---: |\n| 长行 | \(longCell)跨页终点 | 2800 |\n| 下一行 | 表格后续行 | 10 |\n\n表格结束后的正文。\n"
                }
                if testing && ProcessInfo.processInfo.arguments.contains("--native-listening-test") {
                    sample = Manuscript(title: "原生语音试听测试", format: .txt, content: String(repeating: "夜风穿过窗棂，书页轻轻翻动。他在门前站了一会儿，终于敲响了那扇沉重的木门。她低声问，你怎么现在才来。他摇了摇头，没有回答。\n\n", count: 30))
                }
                if testing && ProcessInfo.processInfo.arguments.contains("--line-tap-ui-testing") {
                    let content = (1...80).map {
                        let base = "第\($0)段。长篇甲的中文正文，校验独立阅读位置和多个书签。重复阅读不会改变正文。"
                        if $0 == 1 {
                            return base.replacingOccurrences(of: "。", with: "，") + String(repeating: "这是同一自然段中的连续正文，用来核对自动折行后的点击位置，", count: 4) + "。\n\n"
                        }
                        return base + "\n\n"
                    }.joined()
                    sample = Manuscript(title: "长篇甲", format: .txt, content: content)
                }
                try? await repository.save(sample); await refresh()
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--regression-fixtures") && !books.contains(where: { $0.title == "长篇甲" }) {
                for title in ["长篇甲", "长篇乙"] {
                    let content = (1...80).map { "第\($0)段。\(title)的中文正文，校验独立阅读位置和多个书签。重复阅读不会改变正文。\n\n" }.joined()
                    try? await repository.save(Manuscript(title: title, format: .txt, content: content))
                }
                let samples: [TextFormat: String] = [.sql: "SELECT name FROM books WHERE id = 42; -- 注释", .markdown: "# 标题\n\n**中文** [链接](https://example.org)", .txt: "中文纯文本", .csv: "name,value\n中文,42", .tsv: "name\tvalue\n中文\t42", .java: "public class Book { int value = 42; } // 中文", .javascript: "const value = 42; // 中文", .yaml: "title: 中文\nvalue: 42 # 注释", .json: "{\"title\": \"中文\", \"value\": 42}", .xml: "<book value=\"42\">中文</book>", .html: "<html><body>中文</body></html>"]
                for format in TextFormat.allCases {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("格式_\(format.label)." + format.fileExtension)
                    try? Data((samples[format] ?? "").utf8).write(to: url)
                    _ = try? await repository.importFile(url)
                }
                await refresh()
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--long-ui") && !books.contains(where: { $0.title == "性能长文" }) {
                let paragraph = String(repeating: "长文性能校验，中文和 emoji😀 不应损坏。", count: 100) + "\n\n"
                try? await repository.save(Manuscript(title: "性能长文", format: .txt, content: String(repeating: paragraph, count: 700)))
                await refresh()
            }
            #if DEBUG
            if testing && ProcessInfo.processInfo.arguments.contains("--hidden-local-document-ui-testing") {
                try? await repository.save(Manuscript(title: "无历史的同步文件", format: .txt, content: "已同步的正文仍可从本机文稿找到。"))
                try? await repository.saveHistory(RecentHistory()); await refresh()
            }
            if testing && (ProcessInfo.processInfo.arguments.contains("--received-file-ui-testing") || ProcessInfo.processInfo.arguments.contains("--received-folder-ui-testing")) {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    let sender = try LibraryRepository(root: temporary)
                    let first = Manuscript(title: "同步第一章", format: .txt, content: "电脑同步来的第一章。正文保留，离线也能阅读。")
                    let second = Manuscript(title: "同步第二章", format: .markdown, content: "# 第二章\n\n顺序阅读的下一章。")
                    try await sender.save(first); try await sender.save(second)
                    let folder = NovelCollection(alias: "收到的小说", entries: [.init(documentID: first.id, relativePath: first.fileName), .init(documentID: second.id, relativePath: second.fileName)])
                    try await sender.saveCollection(folder)
                    let isFolder = ProcessInfo.processInfo.arguments.contains("--received-folder-ui-testing")
                    let transfer = try await sender.prepareTransfer(id: isFolder ? folder.id : first.id, isFolder: isFolder)
                    defer { transfer.remove() }
                    _ = try await nearby.receiveTransfer?(transfer)
                    if ProcessInfo.processInfo.arguments.contains("--missing-received-history-ui-testing") {
                        try await repository.saveHistory(RecentHistory()); await refresh()
                    }
                    showNearby = true
                } catch { self.error = error.localizedDescription }
                try? FileManager.default.removeItem(at: temporary)
            }
            #endif
            #if os(macOS)
            // 启动读取历史期间，新建/打开/关闭可能先完成，不能再用历史文稿覆盖用户操作。
            if book == nil, !creating, !opening, navigationGeneration == startupNavigation, workspace?.sessions.isEmpty != false {
                if let last = preferences.string(forKey: "lastBook").flatMap(UUID.init(uuidString:)), books.contains(where: { $0.id == last && $0.trashedAt == nil }) { await open(last, recoverSource: false) }
                else if let first = books.first(where: { $0.trashedAt == nil }) { await open(first.id, recoverSource: false) }
            }
            #endif
            #if DEBUG && os(macOS)
            if testing && ProcessInfo.processInfo.arguments.contains("--native-mac-probe"),
               let sample = books.first(where: { $0.title == "校稿测试" }) {
                await open(sample.id)
                await speech.runNativeMacProbe()
            }
            #endif
            #if DEBUG && os(iOS)
            if testing && ProcessInfo.processInfo.arguments.contains("--native-listening-test"),
               let sample = books.first(where: { $0.title == "原生语音试听测试" }) {
                await open(sample.id, reading: true, fromBeginning: true)
                await speech.runNativeListeningProbe()
            }
            if testing && (ProcessInfo.processInfo.arguments.contains("--speech-performance-probe") || ProcessInfo.processInfo.arguments.contains("--speech-rate-performance-probe")) { await speech.runPerformanceProbe() }
            if testing && ProcessInfo.processInfo.arguments.contains("--background-speech-testing"),
               let sample = books.first(where: { $0.title == "长篇甲" }) {
                await open(sample.id, reading: true, fromBeginning: true)
                await speech.runBackgroundProbe()
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--speech-device-probe"),
               let sample = books.first(where: { $0.title == "校稿测试" }) {
                await open(sample.id)
                await speech.runDeviceProbe()
            }
            if !testing, ProcessInfo.processInfo.arguments.contains("--large-file-device-probe") { await runLargeFileProbe() }
            if !testing, ProcessInfo.processInfo.arguments.contains("--background-audio-probe") {
                await runBackgroundAudioProbe()
            }
            if !testing, let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--novel-device-probe"), ProcessInfo.processInfo.arguments.indices.contains(flag + 1) {
                await runNovelDeviceProbe(alias: ProcessInfo.processInfo.arguments[flag + 1])
            }
            #endif
        }
    }

    /// 仅显式维护启动时执行清理；删除已移除的私有草稿，保留仍被引用的文稿。
    private func runGeneratedCacheCleanup() async {
        clearingCaches = true
        defer { clearingCaches = false }
        let manager = FileManager.default
        var errors: [String] = []
        var removedDrafts = 0
        do { removedDrafts = try await clearRemovedDrafts().count } catch { errors.append(error.localizedDescription) }
        do { try speech.clearAudioCache() } catch { errors.append(error.localizedDescription) }
        let folders = [manager.urls(for: .cachesDirectory, in: .userDomainMask).first, manager.temporaryDirectory].compactMap { $0 }
        for folder in folders {
            do {
                for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { try manager.removeItem(at: file) }
            } catch { errors.append(folder.path + ": " + error.localizedDescription) }
        }
        let report: [String: Any] = ["date": Date().timeIntervalSince1970, "errors": errors,
                                   "cleared": folders.map(\.path), "audioCacheBytes": speech.audioCacheBytes(), "removedDrafts": removedDrafts]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkEngine")
        do {
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: support.appendingPathComponent("Cache-cleanup.json"), options: .atomic)
        } catch { NSLog("Cache cleanup report failed: %@", error.localizedDescription) }
    }

    enum CacheCleanup { case audio, snapshots, temporaryExports }

    /// 所有缓存清理入口共用草稿清理逻辑，并严格遵守用户选择的范围。
    /// 清理指定缓存范围；保护当前文稿与打开草稿，返回已永久删除的移出历史草稿数。
    @discardableResult func clearCaches(_ kind: CacheCleanup, documentIDs: Set<UUID>? = nil) async throws -> Int {
        if let workspace, !workspace.beginMaintenance() {
            throw NSError(domain: "InkEngine.Cache", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("正在处理文稿，请稍后再清理缓存。")])
        }
        defer { workspace?.endMaintenance() }
        guard !clearingCaches, !opening, !creating, !modeChanging else {
            throw NSError(domain: "InkEngine.Cache", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("正在处理文稿，请稍后再清理缓存。")])
        }
        clearingCaches = true
        defer { clearingCaches = false }
        do {
            commitEditing(); try await save(); await historyWriteTask?.value
            let removed = try await clearRemovedDrafts(documentIDs: documentIDs)
            switch kind {
            case .audio: try speech.clearAudioCache(documentIDs: documentIDs)
            case .snapshots: try await repository.clearSnapshotCache(documentIDs: documentIDs)
            case .temporaryExports: try DocumentActions.clearTemporaryExports()
            }
            await refresh()
            return removed.count
        } catch { await refresh(); throw error }
    }

    /// 永久清理已移出历史且未被工作区保护的草稿，并同步移除失效的最近关闭项。
    private func clearRemovedDrafts(documentIDs: Set<UUID>? = nil) async throws -> Set<UUID> {
        await historyWriteTask?.value
        let removed = try await repository.clearRemovedDrafts(documentIDs: documentIDs, protecting: workspace?.protectedDocumentIDs ?? Set(book.map { [$0.id] } ?? []))
        guard !removed.isEmpty else { return [] }
        // Permanently removed drafts must not remain offered as reopenable tabs.
        for id in removed { workspace?.forgetClosedTabs(for: id) }
        if let last = preferences.string(forKey: "lastBook").flatMap(UUID.init(uuidString:)), removed.contains(last) { preferences.removeObject(forKey: "lastBook") }
        for id in removed { preferences.removeObject(forKey: "namedDocument:" + id.uuidString) }
        if let receipt = receivedSync, removed.contains(receipt.entry.id) { receivedSync = nil; preferences.removeObject(forKey: "receivedSync") }
        if let id = pendingHandoff, removed.contains(id) { pendingHandoff = nil }
        if let entry = pendingSync, removed.contains(entry.id) { pendingSync = nil }
        try speech.clearAudioCache(documentIDs: removed)
        return removed
    }
    /// 合并并发刷新请求并等待至少一轮新数据，避免导入完成后仍显示旧列表。
    func refresh() async {
        if refreshing {
            // Import/focus may request a refresh after an in-flight list read.
            // Wait for one fresh pass instead of returning stale book summaries.
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        repeat {
            refreshAgain = false
            // 书库由窗口和面板共享，刷新不能继承某个页面或旧暂存任务的取消状态。
            // 独立持有这一轮任务，让已排队的调用者拿到完整结果；真实读写错误仍照常报告。
            // 否则正常页面切换会抛 CancellationError，错误弹窗反而中断新面板的操作。
            await Task { @MainActor in await self.refreshContents() }.value
        } while refreshAgain
        refreshing = false
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func refreshContents() async {
        let generation = historyGeneration
        do {
            await historyWriteTask?.value
            if let workspace, workspace.library !== self { await workspace.library.historyWriteTask?.value }
            let changed = try await repository.reconcileDocumentsDirectory()
            // A malformed new external file must not hide the cached library.
            do { _ = try await repository.refreshLinkedFolders() }
            catch { self.error = error.localizedDescription }
            books = try await repository.list(); novels = try await repository.collections()
            let saved = try await repository.recentHistory()
            if generation == historyGeneration { history = saved }
            if let workspace, workspace.library !== self {
                workspace.library.books = books; workspace.library.novels = novels; workspace.library.history = history
            }
            #if os(macOS)
            try await (workspace?.library ?? self).observeLinkedFolders()
            #endif
            if let current = book, changed.contains(current.id), !dirty {
                let loaded = try await repository.load(current.id)
                guard book?.id == current.id, !dirty, editorText == current.content else { return }
                savedBaseline = loaded
                stopOwnedSpeech(); book = loaded; editorText = loaded.content; textLength = loaded.content.utf16.count
                editorPosition = loaded.cursor; editorNavigationID = UUID(); await reparse()
                status = L10n.tr("已更新本机目录中的文稿")
            }
        } catch { self.error = error.localizedDescription }
    }
    var availableReceivedSync: ReceivedSync? {
        guard let receivedSync else { return nil }
        let exists = receivedSync.entry.isFolder ? novels.contains { $0.id == receivedSync.entry.id } : books.contains { $0.id == receivedSync.entry.id && $0.trashedAt == nil }
        return exists ? receivedSync : nil
    }
    /// 收到同步版本后刷新已打开的干净会话，避免下一次保存使用旧版本基线。
    private func refreshReceivedSession(_ received: Manuscript) async {
        guard let session = workspace?.sessions[received.id], let old = session.book,
              !session.dirty, session.editorText == old.content else { return }
        // 有未保存修改的标签继续保留原缓冲区与恢复草稿；不能用网络副本覆盖。
        // 只在正文版本改变时停止该文稿自己的朗读，其他标签的朗读不受影响。
        if old.revision != received.revision || old.content != received.content {
            session.stopOwnedSpeech()
            session.editorMutation = EditorMutation(text: received.content)
        }
        session.savedBaseline = received
        session.book = received; session.editorText = received.content
        session.textLength = received.content.utf16.count
        session.editorPosition = received.cursor; session.editorNavigationID = UUID()
        await session.reparse()
        session.scrollTarget = session.parsed.segments.isEmpty ? nil : session.parsed.segmentIndex(at: received.cursor)
    }

    /// 展开指定历史入口及其所属目录；不改变正文或文稿身份。
    func revealHistory(_ entry: RecentEntry) {
        requestedHistoryEntry = entry; libraryRequest = UUID()
    }
    /// 打开最近收到的同步文稿或目录；入口已失效时返回 false。
    func openReceivedSync() async -> Bool {
        guard let received = availableReceivedSync else { return false }
        if received.entry.isFolder { revealHistory(received.entry); return true }
        await open(received.entry.id, reading: true)
        return book?.id == received.entry.id
    }

    @discardableResult private func queueHistorySave() -> Task<Void, Never> {
        historyGeneration += 1
        let updated = history, previous = historyWriteTask
        // 固定、拖动、打开可能连续发生；依次写入，避免较早的异步快照覆盖新顺序。
        let task = Task { [weak self, repository] in
            await previous?.value
            do { try await repository.saveHistory(updated) } catch { self?.error = error.localizedDescription }
        }
        historyWriteTask = task; return task
    }

    /// 记录显式打开行为；与已有刷新写入顺序协调，恢复被隐藏的历史入口。
    func recordOpened(_ id: UUID) async {
        if let workspace, workspace.library !== self { await workspace.library.recordOpened(id); history = workspace.library.history; return }
        let folder = novels.first { $0.entries.contains { $0.documentID == id } }
        await recordOpenedEntry(.init(id: folder?.id ?? id, isFolder: folder != nil))
    }
    private func recordOpenedEntry(_ entry: RecentEntry) async {
        if let workspace, workspace.library !== self { await workspace.library.recordOpenedEntry(entry); history = workspace.library.history; return }
        history.opened(entry)
        await queueHistorySave().value
    }
    /// 切换历史入口的固定状态，并持久保存到历史记录。
    func pin(_ entry: RecentEntry) async {
        if let workspace, workspace.library !== self { await workspace.library.pin(entry); history = workspace.library.history; return }
        history.togglePin(entry)
        await queueHistorySave().value
    }
    /// 调整固定历史项的显示顺序，保持其文稿身份不变。
    func placePin(_ id: UUID, at target: UUID) {
        if let workspace, workspace.library !== self { workspace.library.placePin(id, at: target); history = workspace.library.history; return }
        var ids = history.pinned
        guard id != target, ids.contains(id), let targetIndex = ids.firstIndex(of: target) else { return }
        // 使用移除前的目标序号：向上放在目标前，向下放在目标后，两种方向都能排序。
        ids.removeAll { $0 == id }; ids.insert(id, at: min(targetIndex, ids.count))
        history.reorderPins(ids); queueHistorySave()
    }
    /// 仅移除历史入口；正文与恢复草稿交由明确的缓存清理操作处理。
    func removeRecent(_ id: UUID) async {
        if let workspace, workspace.library !== self { await workspace.library.removeRecent(id); history = workspace.library.history; return }
        history.remove(id)
        await queueHistorySave().value
    }
    /// 记录导出结果并向界面提供状态提示。
    func noteExport(_ fileName: String) {
        let message = L10n.tr("已另存为 ") + fileName
        status = message; exportStatus = message
        // 分享面板切回前台也会触发保存，另存为反馈需独立于自动保存状态。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.exportStatus == message { self?.exportStatus = nil }
        }
    }
    /// 为刚保存的文稿关联目标文件，不重新导入另一份身份。
    func attachSavedFile(_ url: URL) async {
        guard let book else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try await repository.attachSource(url, to: book.id); sourcePath = url.path
            #if os(macOS)
            sourceConflict = false; await observeSource()
            #endif
        } catch { self.error = error.localizedDescription }
    }

    #if DEBUG && os(iOS)
    private func runLargeFileProbe() async {
        let root = await repository.root
        let url = root.deletingLastPathComponent().appendingPathComponent("Large-file-probe.json")
        var events: [[String: String]] = [], readyOffset = -1
        func record(_ phase: String, _ detail: String) {
            events.append(["phase": phase, "detail": detail, "cursor": String(book?.cursor ?? 0)])
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            print("INK_LARGE_FILE_PROBE " + phase + " " + detail)
        }
        onPagePrepared = { offset, elapsed, characters, cached in
            guard characters > 0 else { return }
            readyOffset = offset
            record("page-ready", "offset=\(offset), seconds=\(elapsed), windowCharacters=\(characters), cachedParagraphs=\(cached)")
        }
        defer { onPagePrepared = nil }
        do {
            guard let large = books.first(where: { $0.title.contains("深空彼岸") }) else { throw InkError.invalidDocument }
            let original = try await repository.load(large.id)
            let start = Date()
            await open(large.id, reading: true, fromBeginning: true)
            record("opened", "characters=\(textLength), paragraphs=\(parsed.segments.count), seconds=\(Date().timeIntervalSince(start)), cached=\(parsed.segments.materializedSegmentCount)")
            let timeout = Date().addingTimeInterval(20)
            while readyOffset < 0, Date() < timeout { try await Task.sleep(for: .milliseconds(50)) }
            guard readyOffset >= 0 else { throw InkError.invalidDocument }
            for fraction in [0.5, 0.9, 0.1, 0.0] {
                readyOffset = -1
                jump(Int(Double(textLength) * fraction))
                let deadline = Date().addingTimeInterval(10)
                while readyOffset < 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                guard readyOffset >= 0 else { throw InkError.invalidDocument }
                try await Task.sleep(for: .milliseconds(200))
            }
            jump(original.cursor); try await save()
            record("passed", "Actual 6.3-million-character book opens and seeks; lazy paragraph cache <=64; restored original cursor")
        } catch { record("failed", error.localizedDescription) }
    }
    private func runBackgroundAudioProbe() async {
        let root = await repository.root
        let url = root.deletingLastPathComponent().appendingPathComponent("Background-audio-probe.json")
        var events: [[String: String]] = []
        func record(_ phase: String, _ detail: String = "") {
            let event = ["phase": phase, "elapsed": String(Date().timeIntervalSince1970), "state": String(UIApplication.shared.applicationState.rawValue), "protectedData": String(UIApplication.shared.isProtectedDataAvailable), "thermal": String(ProcessInfo.processInfo.thermalState.rawValue), "file": book?.fileName ?? "", "evidence": speech.playbackEvidence, "detail": detail]
            events.append(event)
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            print("INK_BACKGROUND_PROBE " + phase + " " + event.description)
        }
        do {
            guard let novel = novels.first(where: { $0.alias == "穿越后，我和三叔去盗墓" }), let first = novel.orderedBooks(from: books, readingOnly: true).first else { throw CollectionError.emptyFolder }
            await open(first.id, reading: true, fromBeginning: true)
            speech.rendererMode = "system"; speech.rate = 1.25
            guard !speech.systemVoiceID.isEmpty else { throw InkError.invalidDocument }
            record("ready", speech.voiceDescription)
            speech.playFromBeginning()
            var backgroundSeconds = 0, lastFrame: Int64 = -1
            let started = Date()
            while Date().timeIntervalSince(started) < 300 {
                try await Task.sleep(for: .seconds(5))
                if let error = speech.error { throw NSError(domain: "BackgroundProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                let isBackground = UIApplication.shared.applicationState == .background
                let advancing = speech.renderedFrames > lastFrame
                record("sample", "background=\(isBackground), advancing=\(advancing)")
                if isBackground && advancing { backgroundSeconds += 5 }
                lastFrame = speech.renderedFrames
                if backgroundSeconds >= 110 { record("passed", "110 seconds of advancing PCM in the background at 1.25x"); speech.pause(); try await save(); return }
            }
            record("incomplete", "No verified two-minute background interval")
            speech.pause(); try await save()
        } catch { speech.stop(); record("failed", error.localizedDescription) }
    }
    /// 使用此前导入的小说副本进行真机验证，不覆盖源目录中的正文。
    private func runNovelDeviceProbe(alias: String) async {
        var events: [[String: String]] = []
        let libraryRoot = await repository.root
        let reportURL = libraryRoot.deletingLastPathComponent().appendingPathComponent("Novel-device-probe.json")
        func record(_ phase: String, _ message: String = "") {
            let event = ["phase": phase, "file": book?.fileName ?? "", "cursor": String(book?.cursor ?? 0), "evidence": speech.playbackEvidence, "message": message]
            events.append(event)
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reportURL, options: .atomic) }
            print("INK_NOVEL_PROBE " + phase + " " + (book?.fileName ?? "") + " " + speech.playbackEvidence + " " + message)
        }
        func wait(_ timeout: TimeInterval = 45, until condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(timeout)
            while !condition() {
                if let failure = speech.error { throw NSError(domain: "NovelProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
                guard Date() < end else { throw NSError(domain: "NovelProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "等待实际播放或章节切换超时"]) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            guard let novel = novels.first(where: { $0.alias == alias }) else { throw CollectionError.emptyFolder }
            let chapters = novel.orderedBooks(from: books, readingOnly: true)
            guard chapters.count >= 2 else { throw CollectionError.emptyFolder }
            await open(chapters[0].id, reading: true, fromBeginning: true)
            record("loaded", "\(chapters.count) reading chapters; \(novel.entries.count - chapters.count) supplemental files")
            speech.playFromBeginning()
            try await wait { speech.renderedFrames > 4800 }
            record("playing")
            speech.pause(); let frozen = speech.playbackEvidence
            try await Task.sleep(for: .seconds(1))
            guard speech.playbackEvidence == frozen else { throw InkError.invalidDocument }
            record("paused-stable")
            let pausedFrames = speech.renderedFrames
            speech.resume(); try await wait(15) { speech.renderedFrames > pausedFrames + 2400 }
            record("resumed")
            speech.pause(); speech.next(); let sought = speech.segmentIndex
            try await Task.sleep(for: .seconds(1))
            guard speech.paused, speech.renderedFrames == 0, speech.segmentIndex == sought else { throw InkError.invalidDocument }
            record("paused-next-paragraph")
            speech.resume(); try await wait { speech.renderedFrames > 4800 }
            record("next-paragraph-playing")
            speech.stop()
            guard let last = parsed.segments.last else { throw InkError.invalidDocument }
            jump(last.sourceRange.location)
            speech.play(from: last.id)
            try await wait(55) { book?.id == chapters[1].id }
            try await wait { speech.renderedFrames > 4800 }
            speech.pause(); record("automatic-next-chapter")
            let checkpoint = speech.playbackEvidence.components(separatedBy: "|")
            speech.stop(); speech.play(from: speech.segmentIndex)
            try await wait { speech.renderedFrames > 2400 }
            let recovered = speech.playbackEvidence.components(separatedBy: "|")
            guard recovered.count > 11, recovered[7] == checkpoint[8], recovered[11] == "true" else { throw InkError.invalidDocument }
            speech.pause(); record("verified-pcm-resume")
            try await save(); record("passed")
        } catch { speech.stop(); record("failed", error.localizedDescription); self.error = error.localizedDescription }
    }
    #endif

    var currentNovel: NovelCollection? { novels.first { $0.entries.contains { $0.documentID == book?.id } } }
    /// 查找可参与阅读的前后章节；忽略目录中的说明文件等非阅读项。
    func adjacentNovelChapter(forward: Bool) -> BookSummary? {
        guard let novel = currentNovel, let id = book?.id else { return nil }
        let chapters = novel.orderedBooks(from: books, readingOnly: true)
        guard let index = chapters.firstIndex(where: { $0.id == id }), chapters.indices.contains(index + (forward ? 1 : -1)) else { return nil }
        return chapters[index + (forward ? 1 : -1)]
    }
    /// 手动跨章导航；阅读标签原位复用，并协调当前朗读会话。
    func turnNovelChapter(forward: Bool) {
        guard let next = adjacentNovelChapter(forward: forward) else { return }
        let continueAudio = ownsSpeech && speech.playing && !speech.paused
        Task {
            if let workspace {
                await workspace.openReadingChapter(next.id)
                guard let target = workspace.focusedModel, target.book?.id == next.id else { return }
                if !forward, let last = target.parsed.segments.last { target.jump(last.sourceRange.location) }
                if continueAudio { speech.stop(); await target.activateSpeech(); speech.play(from: target.parsed.segmentIndex(at: target.book?.cursor ?? 0)) }
            } else {
                await open(next.id, reading: true, fromBeginning: true)
                guard book?.id == next.id, error == nil else { return }
                if !forward, let last = parsed.segments.last { jump(last.sourceRange.location) }
                if continueAudio { speech.play(from: parsed.segmentIndex(at: book?.cursor ?? 0)) }
            }
        }
    }
    var standaloneBooks: [BookSummary] {
        let grouped = Set(novels.flatMap { $0.entries.map(\.documentID) })
        return books.filter { $0.trashedAt == nil && !grouped.contains($0.id) }
    }
    /// 导入并重新显示目录历史；显式导入允许恢复被用户隐藏的历史入口。
    func importFolder(_ url: URL, alias: String) async {
        guard !clearingCaches else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            commitEditing(); try await save()
            busy = true
            let receipt = try await repository.importFolder(url, alias: alias, linkOriginals: true)
            await refresh()
            // Reusing a collection does not create it again in the repository.
            // Restore only this explicitly reopened folder to the visible history.
            await recordOpenedEntry(.init(id: receipt.collection.id, isFolder: true))
            (workspace?.library ?? self).revealHistory(.init(id: receipt.collection.id, isFolder: true))
            if let first = receipt.collection.orderedBooks(from: books, readingOnly: true).first ?? receipt.collection.orderedBooks(from: books).first { await open(first.id, reading: true) }
            status = L10n.tr("\(receipt.reused ? L10n.tr("已打开") : L10n.tr("已导入"))《\(receipt.collection.alias)》· \(receipt.collection.entries.count) 个文件") + (receipt.skippedFiles > 0 ? L10n.tr(" · 跳过 \(receipt.skippedFiles) 个非文本文件") : "")
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    /// 修改小说目录显示名，不改动原目录或章节文件名。
    func renameNovel(_ novel: NovelCollection, alias: String) async {
        do { var updated = novel; updated.alias = alias; try await repository.saveCollection(updated); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    /// 切换目录项是否参与连续阅读，不删除该文件。
    func toggleChapterReading(_ novel: NovelCollection, id: UUID) async {
        do {
            var updated = novel
            guard let index = updated.entries.firstIndex(where: { $0.documentID == id }) else { return }
            updated.entries[index].includedInReading.toggle(); try await repository.saveCollection(updated); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    /// 在所选小说目录中新建章节，再按当前平台工作区策略打开。
    func createChapter(in novel: NovelCollection) async {
        await create()
        let created = workspace?.focusedModel?.book ?? book
        guard let book = created, (workspace != nil || book.title == "未命名文稿"), error == nil else { return }
        do {
            var updated = novel; updated.entries.append(.init(documentID: book.id, relativePath: book.fileName))
            try await repository.saveCollection(updated); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func continueNovel(after id: UUID, revision: UUID, generation: UUID, transport: UUID) async {
        guard generation == navigationGeneration, transport == speech.transportGeneration, !editing, book?.id == id, book?.revision == revision, !speech.playing,
              let novel = currentNovel else { return }
        do {
            try await save()
            guard generation == navigationGeneration, transport == speech.transportGeneration, book?.id == id, !editing, !speech.playing else { return }
            let chapters = novel.orderedBooks(from: books, readingOnly: true)
            guard let index = chapters.firstIndex(where: { $0.id == id }) else { return }
            // 空章节和仅有代码的章节不打断小说顺序；继续寻找下一章可朗读正文。
            for next in chapters.dropFirst(index + 1) {
                let candidate = try await repository.load(next.id)
                guard generation == navigationGeneration, transport == speech.transportGeneration, book?.id == id, !editing, !speech.playing else { return }
                if TextParser.parse(candidate.content, format: candidate.format).neuralChunk(from: SpeechCursor(segment: 0), skipCode: speech.skipCode) == nil { continue }
                if let workspace {
                    await workspace.openReadingChapter(next.id)
                    guard let nextModel = workspace.focusedModel, nextModel.book?.id == next.id else { return }
                    await nextModel.activateSpeech()
                } else {
                    await open(next.id, reading: true, fromBeginning: true)
                    guard book?.id == next.id, !editing, error == nil else { return }
                }
                speech.playFromBeginning()
                status = L10n.tr("《\(novel.alias)》· 顺次朗读 ") + next.fileName
                return
            }
            status = L10n.tr("《\(novel.alias)》已读完")
        } catch { self.error = error.localizedDescription }
    }

    /// 创建新的正文草稿；工作区模式交给统一文稿注册表处理。
    func create() async {
        if let workspace { await workspace.create(); return }
        guard !opening, !creating, !modeChanging, !clearingCaches else { return }
        creating = true
        navigationGeneration = UUID()
        defer { creating = false }
        do {
            commitEditing()
            try await save()
            let new = Manuscript(title: "未命名文稿", format: .txt, content: "")
            try await repository.save(new); await refresh(); await open(new.id)
            editing = true
            editorPosition = 0; editorNavigationID = UUID(); detailRequest = UUID()
        } catch { self.error = error.localizedDescription }
    }

    /// 读取文稿或交由工作区打开，恢复来源、正文、模式与同版本阅读位置。
    func open(_ id: UUID, reading: Bool? = nil, fromBeginning: Bool = false, recoverSource: Bool = true) async {
        if let workspace, !loadingWorkspaceDocument {
            await workspace.open(id, reading: reading, fromBeginning: fromBeginning, recoverSource: recoverSource)
            return
        }
        guard !opening, !clearingCaches else { return }
        navigationGeneration = UUID()
        opening = true; busy = true
        defer { opening = false; busy = false }
        do {
            commitEditing(); try await save(); stopOwnedSpeech()
            var loaded: Manuscript
            do { loaded = try await repository.reloadLocalFile(id) }
            catch {
                #if os(macOS)
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain,
                      [NSFileReadCorruptFileError, NSFileReadNoSuchFileError, NSFileNoSuchFileError, NSFileReadNoPermissionError].contains(failure.code),
                      let path = await repository.sourcePath(id) else { throw error }
                guard recoverSource else {
                    status = L10n.tr("上次打开的原文件暂时无法访问，请从历史记录或“打开本地文件…”重新选择。")
                    return
                }
                guard let source = await chooseReplacementSource(path) else { return }
                let granted = source.startAccessingSecurityScopedResource()
                defer { if granted { source.stopAccessingSecurityScopedResource() } }
                loaded = try await repository.reconnectLocalFile(source, to: id)
                #else
                throw error
                #endif
            }
            guard loaded.trashedAt == nil else { return }
            if fromBeginning { loaded.cursor = 0; try await repository.savePosition(id: loaded.id, revision: loaded.revision, cursor: 0) }
            savedBaseline = loaded
            book = loaded; editorText = loaded.content; textLength = loaded.content.utf16.count; dirty = false; searchResults = []
            #if os(macOS)
            editing = true
            #else
            editing = false
            #endif
            if let reading { editing = !reading }
            editorPosition = loaded.cursor; editorNavigationID = UUID()
            await reparse()
            scrollTarget = parsed.segments.isEmpty ? nil : parsed.segmentIndex(at: loaded.cursor)
            detailRequest = UUID()
            preferences.set(id.uuidString, forKey: "lastBook")
            sourcePath = await repository.sourcePath(id)
            #if os(macOS)
            sourceConflict = false; await observeSource()
            #endif
            await recordOpened(id)
            #if os(macOS)
            status = (manualSaving && !usesAutomaticSaving) ? L10n.tr("手动保存 · 自动暂存恢复草稿") : (sourcePath == nil ? L10n.tr("草稿已暂存 · 保存时选择文件位置") : L10n.tr("原文件 · 自动保存"))
            #else
            status = (manualSaving && !usesAutomaticSaving) ? L10n.tr("手动保存 · 自动暂存恢复草稿") : (sourcePath == nil ? L10n.tr("应用文稿 · 自动保存") : L10n.tr("原文件 · 自动保存"))
            #endif
        } catch { self.error = error.localizedDescription }
    }

    #if os(macOS)
    private func chooseReplacementSource(_ path: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        panel.message = L10n.tr("无法访问“\(URL(fileURLWithPath: path).lastPathComponent)”。原文件可能已移动、改名或访问权限已失效。请重新选择对应的文件，保留现有书签与阅读位置。")
        panel.prompt = L10n.tr("重新关联")
        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
            else { panel.begin { continuation.resume(returning: $0) } }
        }
        return response == .OK ? panel.url : nil
    }
    #endif

    /// 关闭当前文稿；工作区模式保留保存、放弃、取消确认语义。
    func closeDocument() async {
        if let workspace, let id = book?.id { await workspace.closeDocument(id); return }
        navigationGeneration = UUID()
        do {
            commitEditing(); try await save(); stopOwnedSpeech()
            #if os(macOS)
            sourceObserver = nil; sourceConflict = false; sourcePath = nil
            #endif
            book = nil; editorText = ""; textLength = 0; dirty = false; editing = false
            parsed = ParsedText(segments: [], chapters: []); scrollTarget = nil; searchResults = []
        } catch { self.error = error.localizedDescription }
    }

    /// 批量导入用户选择的文件；工作区负责去重和标签策略。
    func importFiles(_ urls: [URL]) async {
        if let workspace { await workspace.importFiles(urls); return }
        guard !clearingCaches else { return }
        busy = true
        defer { busy = false }
        do {
            try await save()
            var last: Manuscript?
            for url in urls {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let receipt = try await repository.openLocalFile(url)
                last = receipt.document; status = receipt.message
            }
            await refresh()
            if let last { await open(last.id); status = L10n.tr("已打开原文件 · 编辑会保存回原文件") }
        } catch { self.error = error.localizedDescription }
    }

    /// 接收原生编辑器正文变更，更新未保存状态并安排暂存。
    func textChanged(_ value: String) {
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("modelChange", performanceStart) }
        #endif
        // 原生重做或视图同步可能重复回报同一全文；NSString 直接比较文本存储，避免 Swift 对桥接字符串逐字符比较。
        guard editing, !documentReadOnly else { return }
        let same = (value as NSString).isEqual(to: editorText)
        #if DEBUG
        EditorPerformanceTrace.finish("modelEquality", performanceStart)
        #endif
        guard !same else { return }
        #if DEBUG
        let publishStart = EditorPerformanceTrace.start()
        #endif
        editorText = value; textLength = value.utf16.count
        #if DEBUG
        EditorPerformanceTrace.finish("modelPublish", publishStart)
        let dirtyStart = EditorPerformanceTrace.start()
        #endif
        // 未保存状态按文件实际字符比较。Swift 对桥接全文进行规范等价比较，
        // 在重做恢复相同长前缀时会阻塞主线程；NSString 可直接比较 UTF-16 存储。
        // 仍完整检查基线，确保撤销回已保存内容时能正确清除未保存标记。
        if manualSaving {
            dirty = (savedBaseline.map { !(value as NSString).isEqual(to: $0.content) } ?? true)
                || (isNewDraft && !value.isEmpty)
        } else { dirty = true }
        #if DEBUG
        EditorPerformanceTrace.finish("modelDirty", dirtyStart)
        #endif
        stopOwnedSpeech()
        saveTask?.cancel()
        #if os(macOS)
        guard !sourceConflict || manualSaving else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--manual-save-ui-testing") { return }
        #endif
        #endif
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            // 延迟等待已结束，先释放排队句柄；save() 会取消旧排队任务，不能让它取消自己。
            self.saveTask = nil
            do { try await self.save() } catch { self.error = error.localizedDescription }
        }
    }

    /// 保存当前状态；工作区默认只暂存恢复草稿，formal 才正式写回文件。
    func save(formal: Bool = false) async throws {
        if manualSaving && !formal {
            if usesAutomaticSaving {
                try await save(formal: true)
            } else { try await stashWorkingDraft() }
            return
        }
        guard !manualSaving || !documentReadOnly else { throw InkError.invalidDocument }
        if manualSaving { _ = try? await workingSaveTask?.value; savingFormal = true }
        defer { savingFormal = false }
        saveTask?.cancel(); saveTask = nil
        positionTask?.cancel(); positionTask = nil
        guard var current = book else { return }
        if manualSaving, !isNewDraft, let baseline = savedBaseline {
            let formal = try await repository.load(current.id)
            guard formal.revision == baseline.revision else { throw NSError(domain: "InkEngine.Workspace", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("文稿已有外部更新，请另存当前修改或重新载入。")]) }
        }
        let documentID = current.id
        var changed = false
        // 正式保存同样允许后台计算期间继续输入；在本次保存内部重取快照，
        // 避免递归调用 save 后与等待正式保存结束的草稿任务互相等待。
        while true {
            guard let snapshot = book, snapshot.id == documentID else { return }
            let source = editorText
            #if DEBUG
            let compareStart = EditorPerformanceTrace.start()
            #endif
            changed = !(snapshot.content as NSString).isEqual(to: source)
            #if DEBUG
            EditorPerformanceTrace.finish("formalSaveCompare", compareStart)
            let editStart = EditorPerformanceTrace.start()
            #endif
            current = snapshot
            if changed {
                if (source as NSString).length > 256_000 {
                    current = await revisedLargeDocument(snapshot, content: source)
                } else { current.edit(content: source) }
            }
            #if DEBUG
            EditorPerformanceTrace.finish("formalSaveEdit", editStart)
            let commitStart = EditorPerformanceTrace.start()
            #endif
            guard book?.id == documentID else { return }
            guard book?.revision == snapshot.revision, (editorText as NSString).isEqual(to: source) else {
                #if DEBUG
                EditorPerformanceTrace.finish("formalSaveSuperseded", commitStart)
                #endif
                continue
            }
            if let latestCursor = book?.cursor, latestCursor != snapshot.cursor { current.cursor = latestCursor }
            #if DEBUG
            EditorPerformanceTrace.finish("formalSaveCommit", commitStart)
            #endif
            break
        }
        current.cursor = min(current.cursor, current.content.utf16.count)
        book = current
        // 首次正式保存必须创建文稿本体；空白新稿也不能只保存位置后就标记为已保存。
        if changed || dirty || isNewDraft { try await repository.save(current, writeSource: editing || manualSaving) }
        else { try await repository.savePosition(id: current.id, revision: current.revision, cursor: current.cursor) }
        if book?.revision == current.revision && (editorText as NSString).isEqual(to: current.content) { dirty = false }
        #if os(macOS)
        status = sourcePath == nil ? L10n.tr("草稿已暂存 · 保存时选择文件位置") : L10n.tr("已保存原文件")
        #else
        status = sourcePath == nil ? L10n.tr("已保存应用文稿") : L10n.tr("已保存原文件")
        #endif
        if manualSaving {
            savedBaseline = current; isNewDraft = false
            if !dirty { try await repository.removeWorkingDraft(current.id) }
        }
        await refresh()
        #if DEBUG
        await workspace?.refreshOriginalFileEvidence()
        #endif
    }

    /// 串行暂存恢复草稿，等待前一写入及正式保存，避免旧快照覆盖新内容。
    func stashWorkingDraft() async throws {
        let previous = workingSaveTask
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self else { return }
            while self.savingFormal { await Task.yield() }
            try await self.writeWorkingDraft()
        }
        workingSaveTask = task
        try await task.value
    }

    /// 后台计算长文修订与书签重定位；只操作值类型快照，调用方须校验版本及正文后才能回写。
    private func revisedLargeDocument(_ snapshot: Manuscript, content: String) async -> Manuscript {
        #if DEBUG
        // 仅交错验收延长计算窗口，正常性能测试及发布版本不使用该延迟。
        let delaySnapshot = ProcessInfo.processInfo.arguments.contains("--slow-working-draft-ui-testing")
        #endif
        return await Task.detached(priority: .userInitiated) {
            #if DEBUG
            if delaySnapshot { try? await Task.sleep(for: .seconds(4)) }
            #endif
            var result = snapshot
            result.edit(content: content)
            return result
        }.value
    }

    private func writeWorkingDraft() async throws {
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("workingDraft", performanceStart) }
        #endif
        saveTask?.cancel(); saveTask = nil
        guard var current = book, let baseline = savedBaseline else { return }
        #if DEBUG
        let editStart = EditorPerformanceTrace.start()
        #endif
        if textLength > 256_000 {
            // 长文修订需要重定位书签并扫描新旧正文，放到后台计算不可变快照，避免暂存时卡住输入。
            // 等待期间仍可继续输入；只允许同文稿、同基线和同修订的结果回写，过期结果重新取快照。
            let snapshot = current, source = editorText
            let revised = await revisedLargeDocument(snapshot, content: source)
            #if DEBUG
            let commitStart = EditorPerformanceTrace.start()
            #endif
            guard book?.id == snapshot.id else { return }
            guard book?.revision == snapshot.revision, savedBaseline?.revision == baseline.revision,
                  (editorText as NSString).isEqual(to: source) else {
                #if DEBUG
                EditorPerformanceTrace.finish("workingDraftSuperseded", commitStart)
                #endif
                try await writeWorkingDraft(); return
            }
            current = revised
            // 阅读翻页只更新游标，不一定推进正文修订；保留后台计算期间用户的新位置。
            if !editing, let latestCursor = book?.cursor, latestCursor != snapshot.cursor { current.cursor = latestCursor }
            #if DEBUG
            EditorPerformanceTrace.finish("workingDraftCommit", commitStart)
            #endif
        } else { current.edit(content: editorText) }
        current.cursor = min(editing ? editorPosition : current.cursor, current.content.utf16.count)
        #if DEBUG
        // 长文路径包含后台等待，不能将这个总耗时当作主线程执行耗时。
        EditorPerformanceTrace.finish("workingDraftEdit", editStart)
        let compareStart = EditorPerformanceTrace.start()
        #endif
        book = current
        dirty = !(current.content as NSString).isEqual(to: baseline.content) || (isNewDraft && !current.content.isEmpty)
        #if DEBUG
        EditorPerformanceTrace.finish("workingDraftCompare", compareStart)
        #endif
        if !isNewDraft, dirty, let metadata = WorkingDraft(document: current, baseline: baseline, isNew: false).metadataOnlyUpdate {
            let formal = try await repository.load(current.id)
            guard editorText == current.content, book?.id == current.id else { try await writeWorkingDraft(); return }
            if formal.revision == baseline.revision {
                try await repository.save(metadata)
                savedBaseline = metadata
                if current.revision != metadata.revision { current.ancestors.append(metadata.revision); current.advanceRevision() }
                if editorText == current.content { book = current }
            }
        }
        if !dirty && !isNewDraft {
            let formal = try await repository.load(current.id)
            guard editorText == current.content, book?.id == current.id else { try await writeWorkingDraft(); return }
            if formal.revision != baseline.revision {
                // A sync or another application may have updated the formal copy.
                savedBaseline = formal; book = formal; editorText = formal.content
                textLength = formal.content.utf16.count
                try await repository.removeWorkingDraft(current.id)
                return
            }
            if current.revision != baseline.revision {
                try await repository.save(current)
                savedBaseline = current
            } else { try await repository.savePosition(id: current.id, revision: current.revision, cursor: current.cursor) }
        }
        guard editorText == current.content, book?.id == current.id else { try await writeWorkingDraft(); return }
        try await repository.saveWorkingDraft(.init(document: current, baseline: savedBaseline ?? baseline, isNew: isNewDraft))
        status = dirty ? L10n.tr("修改已暂存，尚未保存") : L10n.tr("已保存")
    }

    /// 取得包含未保存正文和当前阅读位置的传输快照，不写入原文件。
    func workingSnapshot() -> Manuscript? {
        guard var current = book else { return nil }
        current.edit(content: editorText); current.cursor = min(editing ? editorPosition : current.cursor, current.content.utf16.count)
        return current
    }

    /// 检查工作区文稿的原文件变化；存在未保存修改时先报告冲突。
    func checkWorkspaceSourceChanges() async {
        guard manualSaving, !isNewDraft, !checkingWorkspaceSource, let id = book?.id else { return }
        checkingWorkspaceSource = true
        defer { checkingWorkspaceSource = false }
        let text = editorText
        do {
            guard let update = try await repository.localFileUpdate(id), book?.id == id else { return }
            if dirty || editorText != text {
                if !reportedWorkspaceSourceConflict {
                    reportedWorkspaceSourceConflict = true
                    workspace?.failure = L10n.tr("文稿已有外部更新，请另存当前修改或重新载入。")
                }
                return
            }
            let loaded = update.document
            savedBaseline = loaded; book = loaded; editorText = loaded.content; textLength = loaded.content.utf16.count
            editorPosition = min(editorPosition, textLength); editorNavigationID = UUID()
            try await repository.acceptLocalFileUpdate(update)
            sourcePath = await repository.sourcePath(id)
            await reparse()
        } catch { status = error.localizedDescription }
    }

    var ownsSpeech: Bool { !manualSaving || (book?.id != nil && workspace?.speechDocument == book?.id) }

    /// 只控制当前文稿的开始、暂停与恢复；需要时先切换朗读所有权。
    func toggleSpeech() async {
        guard book != nil, !editing else { return }
        if !ownsSpeech || (manualSaving && speech.auditioning) { speech.stop(); await activateSpeech() }
        guard ownsSpeech else { return }
        if speech.playing { speech.paused ? speech.resume() : speech.pause() }
        else { speech.play(from: parsed.segmentIndex(at: book?.cursor ?? 0)) }
    }

    /// 前后跳自然段，暂停状态下跳转仍保持暂停。
    func stepSpeech(forward: Bool) async {
        if !ownsSpeech {
            let segment = parsed.segmentIndex(at: book?.cursor ?? 0)
            if let next = parsed.adjacentParagraph(from: segment, forward: forward), parsed.segments.indices.contains(next) {
                jump(parsed.segments[next].sourceRange.location)
            }
            return
        }
        forward ? speech.next() : speech.previous()
    }

    /// 只停止此文稿拥有的朗读，不能中断其他标签的音频。
    func stopOwnedSpeech() { if ownsSpeech { speech.stop() } }

    /// 将朗读所有权绑定到此文稿并重新解析；普通标签聚焦不抢占其他文稿播放。
    func activateSpeech() async {
        if manualSaving { speech.stop() }
        if manualSaving { workspace?.speechDocument = book?.id }
        speech.onPosition = { [weak self] offset in self?.setPosition(offset, fromSpeech: true) }
        speech.onFinished = { [weak self] id, revision in
            guard let self else { return }
            let generation = self.navigationGeneration, transport = self.speech.transportGeneration
            Task { await self.continueNovel(after: id, revision: revision, generation: generation, transport: transport) }
        }
        await reparse()
    }

    #if os(macOS)
    private func observeLinkedFolders() async throws {
        let directories = try await repository.linkedFolderDirectories()
        let paths = Set(directories.map(\.path))
        folderObservers = folderObservers.filter { paths.contains($0.key) }
        for directory in directories where folderObservers[directory.path] == nil {
            folderObservers[directory.path] = LocalFileObserver(url: directory) { [weak self] in
                Task { await self?.refresh() }
            }
        }
    }

    private func observeSource() async {
        sourceObserver = nil
        guard let id = book?.id, let url = try? await repository.sourceURL(id), book?.id == id else { return }
        sourcePath = url.path
        sourceObserver = LocalFileObserver(url: url) { [weak self] in
            Task { await self?.checkSourceChanges() }
        }
    }

    /// 检查原文件更新并提示冲突；不静默覆盖尚未保存的编辑。
    func checkSourceChanges() async {
        guard !checkingSource, !opening, let id = book?.id, sourcePath != nil else { return }
        checkingSource = true
        defer { checkingSource = false }
        do {
            let changed = try await repository.sourceHasChanges(id)
            guard book?.id == id else { return }
            if !changed { await observeSource(); return }
            // 原生编辑控件先提交最新文本，再决定是否能安全接受外部修改。
            commitEditing()
            if dirty {
                saveTask?.cancel(); saveTask = nil; sourceConflict = true
                status = L10n.tr("原文件已改变，已保留当前编辑；请另存修改或重新载入。")
                return
            }
            await reloadSourceDiscardingEdits(protectConcurrentEdits: true)
        } catch { status = L10n.tr("原文件暂时无法读取：") + error.localizedDescription }
    }

    /// 用户确认后重新加载原文件；可校验期间是否发生并发编辑。
    func reloadSourceDiscardingEdits(protectConcurrentEdits: Bool = false) async {
        guard let id = book?.id else { return }
        saveTask?.cancel(); saveTask = nil
        do {
            let previousText = editorText
            guard let update = try await repository.localFileUpdate(id), book?.id == id else { return }
            commitEditing()
            // 大文件读取/解码在 actor 上进行；期间若用户继续输入，候选内容不能覆盖新输入。
            if protectConcurrentEdits && (dirty || editorText != previousText) {
                saveTask?.cancel(); saveTask = nil; sourceConflict = true
                status = L10n.tr("原文件已改变，已保留当前编辑；请另存修改或重新载入。")
                return
            }
            let loaded = update.document
            savedBaseline = loaded
            stopOwnedSpeech(); book = loaded; editorText = loaded.content
            textLength = loaded.content.utf16.count; dirty = false; sourceConflict = false
            editorPosition = min(editorPosition, textLength); editorNavigationID = UUID()
            try await repository.acceptLocalFileUpdate(update)
            await reparse(); await observeSource(); await refresh()
            status = L10n.tr("已更新原文件的最新内容")
        } catch { self.error = error.localizedDescription }
    }

    #endif

    /// 取得另存为时的正文快照及版本，不改变原文件关联。
    func snapshotForSaveAs() -> Manuscript? {
        commitEditing(); saveTask?.cancel(); saveTask = nil
        guard var copy = book else { return nil }
        copy.edit(content: editorText)
        return copy
    }

    /// 完成目标文件写入及来源关联，保留并发编辑产生的新修改。
    func finishSaveAs(_ url: URL, snapshot: Manuscript) async throws {
        guard book?.id == snapshot.id else { return }
        if manualSaving { _ = try? await workingSaveTask?.value; savingFormal = true }
        defer { savingFormal = false }
        var saved = snapshot
        try saved.configure(fileName: url.lastPathComponent, highlightOverride: snapshot.highlightOverride)
        // 另存不能先写旧原文件，也不能让旧文件的冲突阻止保存新副本。
        try await repository.save(saved)
        book = saved
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await repository.attachSource(url, to: saved.id)
        sourcePath = url.path
        #if os(macOS)
        sourceConflict = false; await observeSource()
        #endif
        if manualSaving { savedBaseline = saved; isNewDraft = false; reportedWorkspaceSourceConflict = false; try await repository.removeWorkingDraft(saved.id) }
        dirty = editorText != saved.content
        await reparse(); await refresh(); noteExport(url.lastPathComponent)
    }

    #if os(macOS)
    /// 生成当前 HTML 预览；保留未保存编辑而不强制写回原文件。
    func previewHTML() async {
        guard let current = book, TextFormat.detect(current.fileName) == .html else { return }
        do {
            // 正常保存流程包含原文件并发修改检查，预览不能绕过检查覆盖外部修改。
            commitEditing(); try await save()
            guard let saved = book, saved.id == current.id else { return }
            let source: URL?
            if manualSaving && dirty { source = nil }
            else { source = try await repository.sourceURL(saved.id) }
            try DocumentActions.previewHTML(saved, source: source) { [weak self] error in
                if let error { self?.error = error.localizedDescription }
            }
            exportStatus = L10n.tr("已发送到默认浏览器 · ") + saved.fileName
        } catch { self.error = error.localizedDescription }
    }
    #endif

    /// 更新文稿文件名和高亮设置，再同步解析及界面状态。
    func configure(fileName: String, highlight: TextFormat?) async {
        do {
            commitEditing(); try await save()
            guard var current = book else { return }
            try current.configure(fileName: fileName, highlightOverride: highlight)
            book = current; dirty = true; try await save(); await reparse()
        } catch { self.error = error.localizedDescription }
    }

    /// 切换手动语法覆盖；nil 表示根据文件名自动识别，不修改正文。
    func chooseSyntax(_ format: TextFormat?) async {
        do {
            commitEditing(); try await save()
            guard var current = book, current.highlightOverride != format else { return }
            current.advanceRevision(); current.highlightOverride = format
            book = current; dirty = true; try await save(); await reparse()
        } catch { self.error = error.localizedDescription }
    }

    var needsFileName: Bool {
        guard let book else { return false }
        #if os(macOS)
        return sourcePath == nil
        #else
        return book.sourceName == nil && book.title == "未命名文稿" && !preferences.bool(forKey: "namedDocument:" + book.id.uuidString)
        #endif
    }
    /// 设置文稿文件名并校验合法性，不隐式更换保存位置。
    func nameDocument(_ fileName: String) async {
        guard let book else { return }
        await configure(fileName: fileName, highlight: book.highlightOverride)
        if error == nil { preferences.set(true, forKey: "namedDocument:" + book.id.uuidString) }
    }

    var activeBookmarks: [ReadingBookmark] { book?.bookmarks.filter { $0.deletedAt == nil } ?? [] }
    /// 在当前正文位置添加有名称的书签。
    func addBookmark(name: String) async {
        guard !editing else { return }
        do {
            commitEditing(); try await save(); guard var current = book else { return }
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            current.advanceRevision(); current.bookmarks.append(ReadingBookmark(name: clean, offset: editing ? editorPosition : current.cursor, content: current.content))
            book = current; dirty = true; try await save()
        } catch { self.error = error.localizedDescription }
    }
    /// 重命名或软删除指定书签，保留版本与同步所需元数据。
    func changeBookmark(_ id: UUID, name: String? = nil, delete: Bool = false) async {
        do {
            try await save(); guard var current = book, let index = current.bookmarks.firstIndex(where: { $0.id == id }) else { return }
            if let name {
                let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)); guard !clean.isEmpty else { return }
                current.bookmarks[index].name = clean
            }
            current.bookmarks[index].updatedAt = Date()
            if delete { current.bookmarks[index].deletedAt = Date() }
            current.advanceRevision(); book = current; dirty = true; try await save()
        } catch { self.error = error.localizedDescription }
    }

    /// 提交当前原生编辑器的输入法组合文本；不把面板文本框当成正文编辑器。
    func commitEditing() {
        if let workspace {
            if let id = book?.id { workspace.commitNativeDocument(id) }
            return
        }
        #if os(macOS)
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.identifier?.rawValue == "manuscriptEditor", (editor as? FocusTextView)?.documentID == book?.id {
            editor.unmarkText(); textChanged(editor.string); editorPosition = editor.selectedRange().location
        }
        if acceptsActions { NSApp.keyWindow?.makeFirstResponder(nil) }
        #else
        func sourceEditor(in view: UIView) -> UITextView? {
            if let editor = view as? UITextView, editor.isFirstResponder, editor.accessibilityIdentifier == "manuscriptEditor", (editor as? ColumnTextView)?.documentID == book?.id { return editor }
            for child in view.subviews { if let editor = sourceEditor(in: child) { return editor } }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let editor = sourceEditor(in: window) {
                    editor.unmarkText(); textChanged(editor.text); editorPosition = editor.selectedRange.location
                    editor.resignFirstResponder()
                }
            }
        }
        #endif
    }

    /// 编辑与阅读之间切换前提交当前修改，再准备目标视图所需的解析状态。
    func switchMode() async {
        guard !modeChanging, !opening else { return }
        navigationGeneration = UUID()
        modeChanging = true
        defer { modeChanging = false }
        do {
            commitEditing()
            try await save(); stopOwnedSpeech()
            if editing { await reparse() }
            editing.toggle()
            if editing { editorPosition = book?.cursor ?? 0; editorNavigationID = UUID() }
            if let book, !parsed.segments.isEmpty { scrollTarget = parsed.segmentIndex(at: book.cursor) }
        } catch { self.error = error.localizedDescription }
    }

    /// 后台解析正文；按文稿 ID、版本及代次丢弃过期结果，避免切换文稿后串内容。
    func reparse() async {
        guard let current = book else { return }
        let generation = UUID(); parseGeneration = generation
        let result = await Task.detached(priority: .userInitiated) { TextParser.parse(current.content, format: current.format) }.value
        guard parseGeneration == generation, book?.id == current.id, book?.revision == current.revision else { return }
        parsed = result
        if manualSaving && !ownsSpeech { return }
        speech.load(result, title: current.title, documentID: current.id, revision: current.revision)
        speech.seek(toSourceOffset: current.cursor, notifyPosition: false)
    }

    /// 更新 UTF-16 阅读位置并合并延迟落盘；语音推进只改变所属文稿的位置。
    func setPosition(_ offset: Int, fromSpeech: Bool = false) {
        guard var current = book else { return }
        current.cursor = min(max(0, offset), textLength); book = current
        if fromSpeech, !parsed.segments.isEmpty { scrollTarget = parsed.segmentIndex(at: current.cursor) }
        guard positionTask == nil else { return }
        positionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.positionTask = nil
            do {
                if self.dirty { try await self.save() }
                else if let current = self.book { try await self.repository.savePosition(id: current.id, revision: current.revision, cursor: current.cursor) }
            } catch { self.error = error.localizedDescription }
        }
    }

    /// 跳转正文位置并同步编辑器、阅读器与当前朗读游标。
    func jump(_ offset: Int) {
        if ownsSpeech { speech.seek(toSourceOffset: offset, notifyPosition: false) }
        setPosition(offset)
        editorPosition = offset; editorNavigationID = UUID()
        if !parsed.segments.isEmpty { scrollTarget = parsed.segmentIndex(at: offset) }
    }

    /// 从指定可见行朗读；已暂停时换行仍保持暂停，避免意外发声。
    func readFromLine(_ offset: Int) {
        if manualSaving && !ownsSpeech {
            jump(offset)
            Task { speech.stop(); await activateSpeech(); guard ownsSpeech else { return }; speech.play(from: parsed.segmentIndex(at: offset)) }
            return
        }
        let wasPlaying = speech.playing
        jump(offset)
        // 暂停时也允许点选另一行；改变位置后仍保持暂停，避免意外发声。
        if !wasPlaying { speech.play(from: parsed.segmentIndex(at: offset)) }
    }

    /// 后台搜索并只提交仍匹配当前查询及正文的结果。
    func search() async {
        let query = searchQuery, text = editorText, options = findOptions
        do {
            let results = try await Task.detached { try FindReplace.matches(query, in: text, options: options) }.value
            guard query == searchQuery, text == editorText, options == findOptions else { return }
            searchResults = results; searchMessage = results.count >= 2000 ? L10n.tr("显示前 2000 处匹配") : L10n.tr("找到 \(results.count) 处匹配")
        } catch { searchResults = []; searchMessage = L10n.tr("表达式无效：") + error.localizedDescription }
    }

    /// 替换当前或全部匹配项；校验查询与正文未变后提交原生可撤销编辑。
    func replace(all: Bool, range: NSRange? = nil) async {
        guard editing, !documentReadOnly else { return }
        let old = editorText, query = searchQuery, value = replacementQuery, options = findOptions
        do {
            let result = try await Task.detached { try FindReplace.replacing(query, with: value, in: old, options: options, range: all ? nil : range) }.value
            guard editing, old == editorText, query == searchQuery, value == replacementQuery, options == findOptions else { return }
            guard result.text.utf8.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
            if result.count > 0 { editorMutation = EditorMutation(text: result.text); textChanged(result.text) }
            await search(); searchMessage = L10n.tr("已替换 \(result.count) 处")
        } catch { searchMessage = error.localizedDescription }
    }
    /// 永久移除指定书签及历史摘录，并刷新当前文稿。
    func purgeBookmarks(_ ids: Set<UUID>) async {
        do {
            try await save(); stopOwnedSpeech(); try await repository.deleteBookmarks(ids)
            if let current = book { book = try await repository.load(current.id); await reparse() }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    #if os(iOS)
    /// 明确删除本机文件或目录，清理相关同步入口和音频缓存。
    func deleteLocalEntry(_ entry: RecentEntry) async {
        do {
            commitEditing(); try await save(); await historyWriteTask?.value
            let deleted = try await repository.deleteLocalEntry(entry)
            if let current = book, deleted.contains(current.id) {
                navigationGeneration = UUID(); stopOwnedSpeech(); book = nil; editorText = ""; textLength = 0; dirty = false; editing = false
                parsed = ParsedText(segments: [], chapters: []); scrollTarget = nil; searchResults = []; sourcePath = nil
            }
            if let last = preferences.string(forKey: "lastBook").flatMap(UUID.init(uuidString:)), deleted.contains(last) { preferences.removeObject(forKey: "lastBook") }
            if let receipt = receivedSync, receipt.entry.id == entry.id || deleted.contains(receipt.entry.id) { receivedSync = nil; preferences.removeObject(forKey: "receivedSync") }
            do { try speech.clearAudioCache(documentIDs: deleted) } catch { self.error = L10n.tr("文稿已删除，但部分朗读缓存清理失败：") + error.localizedDescription }
            await refresh(); status = entry.isFolder ? L10n.tr("已删除本机目录及其文稿") : L10n.tr("已删除本机文稿")
        } catch { self.error = error.localizedDescription }
    }

    #endif

    /// 根据持久化文稿 ID 继续阅读，不依赖摘要列表是否已加载完成。
    func resumeLast() async {
        // 启动时摘要列表可能仍在后台加载，继续阅读直接读取已保存的文稿，避免点击无反应。
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { print("INK_RESUME_LAST id=\(preferences.string(forKey: "lastBook") ?? "none") opening=\(opening)") }
        #endif
        if let raw = preferences.string(forKey: "lastBook"), let id = UUID(uuidString: raw) { await open(id, reading: true) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { print("INK_RESUME_RESULT document=\(book?.id.uuidString ?? "none") busy=\(busy) error=\(error ?? "none")") }
        #endif
    }

    /// 准备同步快照，包含工作区未保存内容，不暴露本机文件授权。
    func prepareTransfer(_ entry: RecentEntry) async throws -> PreparedTransfer {
        commitEditing(); try await save()
        return try await repository.prepareTransfer(id: entry.id, isFolder: entry.isFolder, overrides: workspace?.workingSnapshots ?? [:])
    }
    /// 设置待发送入口并展示附近设备面板；尚未确认时不发送正文。
    func chooseSync(_ entry: RecentEntry) {
        pendingSync = entry; showNearby = true
        nearby.start()
    }
    /// 用户确认后发送待同步内容；未连接或已有传输时不重复启动。
    func confirmSync() async {
        guard let entry = pendingSync, nearby.ready, !nearby.transferring else { return }
        pendingSync = nil
        do { let transfer = try await prepareTransfer(entry); try await nearby.push(transfer) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    /// 接收系统接续活动中的文稿标识并准备打开，不把系统活动当成无条件覆盖许可。
    func handoff(_ activity: NSUserActivity) {
        if let raw = activity.userInfo?["documentID"] as? String { pendingHandoff = UUID(uuidString: raw) }
        showNearby = true
        status = L10n.tr("接力入口已打开，请连接源设备以获取最新正文和位置。")
    }
}

#if DEBUG && targetEnvironment(simulator)
// 显式启用的双模拟器传输测试。样本存入独立运行目录，
// 接收、打开和保存仍经过真实 AppModel 路径，不改动正常资料库。
@MainActor private extension AppModel {
    /// 仅双模拟器隔离集成测试使用：读取工作区当前会话，不能把书库模型当作当前编辑器。
    var integrationDocument: AppModel { workspace?.focusedModel ?? self }

    /// 仅双模拟器隔离集成测试使用：经过真实会话编辑和正式保存，连同原文件一起写回。
    /// 避免探针只修改缓存、随后又被正式源文件扫描还原，误报同步冲突丢失。
    /// - Parameters:
    ///   - id: 隔离测试库中的目标文稿标识。
    ///   - text: 本轮应正式保存的测试正文。
    ///   - cursor: 随正文保存的 UTF-16 阅读位置。
    func integrationEditAndSave(_ id: UUID, text: String, cursor: Int) async throws {
        await open(id, reading: false)
        let document = integrationDocument
        guard document.book?.id == id else { throw InkError.invalidDocument }
        document.editorMutation = EditorMutation(text: text)
        document.textChanged(text)
        document.editorPosition = cursor
        document.setPosition(cursor)
        try await document.save(formal: true)
    }

    /// 仅双模拟器隔离集成测试使用：通过正常工作区逻辑关闭当前测试会话。
    func integrationCloseDocument() async {
        if let workspace, let id = integrationDocument.book?.id { await workspace.closeDocument(id) }
        else { await closeDocument() }
    }
    /// 仅集成测试使用：在隔离目录中验证批量同步、冲突和取消流程。
    func runBatchIntegration(runID: UUID) async {
        let role = ProcessInfo.processInfo.environment["INK_NEARBY_ROLE"] ?? ""
        let port = UInt16(ProcessInfo.processInfo.environment["INK_NEARBY_PORT"] ?? "") ?? 49322
        let root = await repository.root, output = root.deletingLastPathComponent().appendingPathComponent("result.json")
        var first = Manuscript(id: UUID(uuidString: "632FCB78-BC1F-4C7B-B750-F65969423601")!, title: "第1章", format: .txt, content: "第一章原文😀", cursor: 2)
        first.revision = UUID(uuidString: "632FCB78-BC1F-4C7B-B750-F65969423604")!
        let second = Manuscript(id: UUID(uuidString: "632FCB78-BC1F-4C7B-B750-F65969423602")!, title: "第2章", format: .markdown, content: "# 第二章\n\n" + String(repeating: "连续阅读的第二章。", count: 3000))
        let folder = NovelCollection(id: UUID(uuidString: "632FCB78-BC1F-4C7B-B750-F65969423603")!, alias: "整部小说同步测试", entries: [.init(documentID: first.id, relativePath: first.fileName), .init(documentID: second.id, relativePath: "正文/" + second.fileName)])
        var checks: [String] = [], codes: [String] = [], committed = 0
        func report(_ state: String, _ detail: String = "") {
            let value: [String: Any] = ["state": state, "role": role, "runID": runID.uuidString, "checks": checks, "pairingCodes": codes, "detail": detail, "originalRevision": first.revision.uuidString, "path": "Production encrypted TCP, manifest, staging, atomic repository commit"]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "InkBatchIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks.append(message); report("running")
        }
        func wait(_ name: String, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(35)
            while !condition() {
                if let error = nearby.error { throw NSError(domain: "InkBatchIntegration", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
                if Date() > deadline { throw NSError(domain: "InkBatchIntegration", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timeout: \(name); \(nearby.status)"]) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let observation = nearby.$pairingCode.sink { code in if let code { codes.append(code); report("running") } }
        let automaticConfirmation = Task { @MainActor in
            while !Task.isCancelled {
                if nearby.pairingCode != nil { nearby.confirm(remember: false) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { observation.cancel(); automaticConfirmation.cancel(); nearby.stop() }
        do {
            report("starting")
            if role == "sender" {
                try await repository.save(first); try await repository.save(second); try await repository.saveCollection(folder)
                try nearby.integrationListen(port: port)
                try await wait("listener") { nearby.status == "integration-listening" }; report("listening")
                try await wait("paired") { nearby.ready }
                // 已配对和发现只建立连接，不主动读取或发送文稿。
                try await Task.sleep(for: .milliseconds(500))
                try require(!nearby.transferring, "discovery and pairing never auto-send documents")
                pendingSync = .init(id: first.id)
                await confirmSync(); try require(error == nil && pendingSync == nil && nearby.completedFiles == 1, "manual file push received commit receipt")
                try await integrationEditAndSave(first.id, text: "电脑修改第一章", cursor: first.cursor)
                pendingSync = .init(id: folder.id, isFolder: true)
                await confirmSync(); try require(error == nil && pendingSync == nil && nearby.completedFiles == 2, "directory push received complete commit receipt")
                let ghostA = Manuscript(title: "未完成甲", content: "未提交"), ghostB = Manuscript(title: "未完成乙", content: "未提交")
                try await repository.save(ghostA); try await repository.save(ghostB)
                let partialFolder = NovelCollection(alias: "未完成目录", entries: [.init(documentID: ghostA.id, relativePath: ghostA.fileName), .init(documentID: ghostB.id, relativePath: ghostB.fileName)])
                try await repository.saveCollection(partialFolder)
                let partial = try await repository.prepareTransfer(id: partialFolder.id, isFolder: true)
                try await nearby.integrationCancelStaged(partial)
                try await wait("receiver reconnected") { nearby.ready }
                let final = Manuscript(title: "取消后重连", content: "重连后的正文")
                try await repository.save(final)
                let finalTransfer = try await repository.prepareTransfer(id: final.id, isFolder: false)
                try await nearby.push(finalTransfer)
                try require(nearby.completedFiles == 1, "reconnect after cancelled directory can synchronize again")
                nearby.cancel(); report("passed")
            } else {
                let receive = nearby.receiveTransfer!
                nearby.receiveTransfer = { transfer in
                    let note = try await receive(transfer); committed += 1
                    if committed == 1 {
                        let book = try await self.repository.load(first.id)
                        try require(book.content == first.content && book.cursor == 2 && book.revision == first.revision, "file content and position persisted exactly")
                        try require(self.availableReceivedSync?.entry.id == first.id && self.history.entries.contains(where: { $0.id == first.id }), "received file exposes direct-open receipt and history entry")
                        try await self.integrationEditAndSave(first.id, text: "平板离线修改第一章", cursor: book.cursor)
                    } else if committed == 2 {
                        let books = try await self.repository.list(), collections = try await self.repository.collections()
                        let local = try await self.repository.load(first.id)
                        try require(books.count == 3 && local.content == "平板离线修改第一章", "directory conflict preserves local chapter and creates separate copy")
                        try require(collections.count == 1 && collections[0].entries.count == 3 && collections[0].entries.contains(where: { $0.relativePath == "正文/" + second.fileName }), "directory alias nested paths and conflict chapter retained")
                        try require(self.availableReceivedSync?.entry.id == folder.id && self.availableReceivedSync?.count == 2 && self.history.entries.first?.id == folder.id, "received directory exposes alias and one top history entry")
                    } else {
                        let books = try await self.repository.list(), collections = try await self.repository.collections()
                        try require(committed == 3 && books.count == 4 && collections.count == 1, "cancelled staged directory created no files or history entry")
                        try require(books.contains(where: { $0.title == "取消后重连" }), "reconnected file is readable offline")
                    }
                    return note
                }
                nearby.integrationConnect(port: port)
                try await wait("first paired connection") { nearby.ready }
                try await wait("directory committed") { committed == 2 }
                try await wait("partial cancellation disconnect") { !nearby.integrationConnected }
                let saved = try await repository.list(), folders = try await repository.collections()
                try require(saved.count == 3 && folders.count == 1, "disconnect before directory commit leaves library unchanged")
                nearby.integrationConnect(port: port)
                try await wait("final commit") { committed == 3 }
                try await wait("final disconnect") { !nearby.integrationConnected }
                report("passed")
            }
        } catch { report("failed", error.localizedDescription + " | " + (nearby.error ?? nearby.status)) }
    }
    /// 仅集成测试使用：记录加密传输与接收结果，不代表真实局域网或系统接续验收。
    func runNearbyIntegration(runID: UUID) async {
        let role = ProcessInfo.processInfo.environment["INK_NEARBY_ROLE"] ?? ""
        let port = UInt16(ProcessInfo.processInfo.environment["INK_NEARBY_PORT"] ?? "") ?? 49321
        let base = Manuscript(id: UUID(uuidString: "27A8E27C-2A11-42FC-BF76-C119AE7CFAE9")!, title: "接力网络测试", format: .markdown,
                              content: "# 接力章节\n\n" + String(repeating: "中文小说正文与 emoji😀，加密传输后应完全一致。\n\n", count: 6000), cursor: 1337)
        let offlineText = base.content + "接收端离线修改。\n"
        let senderText = offlineText + "发送端独立修改。\n"
        let receiverText = offlineText + "接收端独立修改。\n"
        var checks: [String] = [], codes: [String] = [], receivedRevision = ""
        let root = await repository.root
        let output = root.deletingLastPathComponent().appendingPathComponent("result.json")
        func report(_ state: String, _ detail: String = "") {
            let value: [String: Any] = ["state": state, "role": role, "runID": runID.uuidString, "checks": checks, "pairingCodes": codes,
                                        "detail": detail, "contentBytes": base.content.utf8.count, "originalRevision": role == "sender" ? base.revision.uuidString : receivedRevision, "path": "Network.framework TCP 127.0.0.1; production NearbyService; injected temporary confirmation"]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
        }
        func require(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "InkNetworkIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks.append(name); report("running")
        }
        func wait(_ name: String, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                if Date() > deadline { throw NSError(domain: "InkNetworkIntegration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout: \(name); \(nearby.error ?? nearby.status)"]) }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        // 被拒绝的握手可能在轮询前清掉配对码；订阅每一次真实发布，
        // 以覆盖拒绝场景，不改变用户确认或传输逻辑。
        let pairingObservation = nearby.$pairingCode.sink { code in
            if let code { codes.append(code); report("running") }
        }
        defer { pairingObservation.cancel() }
        func connect() async throws {
            nearby.integrationConnect(port: port)
            try await wait("pairing code") { nearby.pairingCode != nil }
            nearby.confirm(remember: false)
            try await wait("paired") { nearby.ready }
        }
        do {
            report("starting")
            if role == "sender" {
                try await repository.save(base); await refresh(); await open(base.id, reading: true)
                var requests = 0, received = 0, denied = false
                let provide = nearby.currentDocument!, receive = nearby.receiveDocument!
                nearby.currentDocument = { id in requests += 1; return try await provide(id) }
                nearby.receiveDocument = { document, checksum in
                    let note = try await receive(document, checksum)
                    received += 1
                    if received == 1 {
                        try require(document.id == base.id && document.content == offlineText && document.cursor == 2456, "reconnected offline edit received exactly")
                        try await self.integrationEditAndSave(base.id, text: senderText, cursor: 3001)
                    } else {
                        let original = try await self.repository.load(base.id)
                        let copies = try await self.repository.list()
                        let copy = try await self.repository.load(copies.first(where: { $0.id != base.id })!.id)
                        try require(original.content == senderText && copy.content == receiverText && copy.conflictOf == base.id, "sender preserved both conflicting versions")
                    }
                    return note
                }
                try nearby.integrationListen(port: port)
                try await wait("listener") { nearby.status == "integration-listening" }
                report("listening")
                let deadline = Date().addingTimeInterval(95)
                while Date() < deadline {
                    if nearby.pairingCode != nil {
                        nearby.confirm(remember: false); report("running")
                    }
                    if !denied && nearby.error == InkError.unpaired.localizedDescription {
                        try require(requests == 0 && received == 0, "unpaired encrypted request denied before library access")
                        denied = true; nearby.error = nil
                    }
                    if denied && received == 2 && codes.count >= 4 && !nearby.integrationConnected {
                        let saved = try await repository.list()
                        try require(saved.count == 2, "partial encrypted frame cancellation created no document")
                        nearby.stop(); report("passed"); return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw NSError(domain: "InkNetworkIntegration", code: 3, userInfo: [NSLocalizedDescriptionKey: "Sender completion timeout; requests=\(requests), received=\(received), sessions=\(codes.count)"])
            } else if role == "receiver" {
                nearby.integrationConnect(port: port)
                try await wait("unpaired handshake") { nearby.pairingCode != nil }
                try nearby.integrationUnpairedRequest()
                try await wait("unpaired rejection disconnect") { !nearby.integrationConnected }
                try require(try await repository.list().isEmpty, "unpaired receiver has no document")
                try await connect()
                nearby.requestCurrent()
                try await wait("first offline copy") { integrationDocument.book?.id == base.id && !nearby.transferring }
                let reopened = try LibraryRepository(root: root)
                let exact = try await reopened.load(base.id)
                receivedRevision = exact.revision.uuidString
                try require(exact.content == base.content && exact.checksum == base.checksum && exact.revision == integrationDocument.book?.revision && exact.cursor == 1337, "full body stable ID revision checksum and UTF16 position persisted")
                await integrationCloseDocument(); await open(base.id, reading: true)
                try require(integrationDocument.book?.cursor == 1337 && !integrationDocument.editing, "received copy opens in reader at original position")
                nearby.disconnect()
                try await integrationEditAndSave(base.id, text: offlineText, cursor: 2456)
                let offline = try await reopened.load(base.id)
                try require(offline.content == offlineText && offline.cursor == 2456, "disconnected offline edit and position saved")
                try await connect()
                try await nearby.integrationSendCurrent()
                try await wait("offline edit receipt") { !nearby.transferring }
                try await integrationEditAndSave(base.id, text: receiverText, cursor: 3333)
                nearby.requestCurrent()
                try await wait("conflict offline copy") { integrationDocument.book?.conflictOf == base.id && !nearby.transferring }
                let local = try await reopened.load(base.id), conflict = try await reopened.load(integrationDocument.book!.id)
                try require(local.content == receiverText && local.cursor == 3333 && conflict.content == senderText && conflict.cursor == 3001 && conflict.id != base.id, "receiver preserved both conflicting bodies and positions")
                await open(base.id, reading: true)
                try await nearby.integrationSendCurrent()
                try await wait("conflict receipt") { !nearby.transferring }
                let count = try await repository.list().count
                let cancelled = Manuscript(title: "未完成传输不得落盘", content: String(repeating: "取消中的正文😀", count: 20000))
                try await nearby.integrationInterrupt(cancelled)
                try require(try await repository.list().count == count, "cancellation preserves existing offline documents")
                try await connect(); nearby.cancel()
                await integrationCloseDocument(); await open(base.id, reading: true)
                try require(integrationDocument.book?.content == receiverText && integrationDocument.book?.cursor == 3333 && !integrationDocument.editing, "conflict original reopens offline at edited position")
                try require(nearby.trustedNames.isEmpty, "temporary pairing stores no persistent peer trust")
                report("passed")
            } else { throw InkError.invalidDocument }
        } catch {
            nearby.stop(); report("failed", error.localizedDescription)
        }
    }
}
#endif
