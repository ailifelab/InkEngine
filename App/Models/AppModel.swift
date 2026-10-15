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
    @Published var editorPosition = 0
    @Published var editorNavigationID = UUID()
    @Published var detailRequest = UUID()
    @Published var readingTheme: ReadingTheme = .white {
        didSet { preferences.set(readingTheme.rawValue, forKey: "readingTheme") }
    }
    @Published var dirty = false
    @Published var busy = false
    @Published var status = "打开本地文件；编辑保存回原文件，阅读模式只读。"
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
    let nearby = NearbyService()
    private var saveTask: Task<Void, Never>?
    #if DEBUG
    var onPagePrepared: ((Int, Double, Int, Int) -> Void)?
    #if os(macOS)
    @Published private(set) var testDiskContent = ""
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

    init() {
        let customRoot = ProcessInfo.processInfo.environment["INK_LIBRARY_PATH"]
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        preferences = testing ? UserDefaults(suiteName: "org.ailifelab.InkEngine.UITests")! : .standard
        if testing && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") { preferences.removePersistentDomain(forName: "org.ailifelab.InkEngine.UITests") }
        speech = SpeechEngine(preferences: preferences)
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
        catch { fatalError("无法创建书库：\(error.localizedDescription)") }
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
            if let id { return try await self.repository.load(id) }
            return self.book
        }
        nearby.receiveDocument = { [weak self] document, checksum in
            guard let self else { throw InkError.invalidDocument }
            try await self.save()
            let (received, decision) = try await self.repository.receive(document, checksum: checksum)
            await self.refresh()
            if decision != .keepLocal { await self.open(received.id) }
            let note: String
            switch decision {
            case .same: note = "内容相同，已恢复阅读位置。"
            case .acceptRemote: note = "文稿与位置已保存为离线副本。"
            case .keepLocal: note = "本地版本较新，保留本地。可发送回对方同步。"
            case .conflict: note = "双方有修改，已保留本地文稿与收到的冲突副本。"
            }
            self.status = note
            return note
        }
        nearby.receiveTransfer = { [weak self] transfer in
            guard let self else { throw InkError.invalidDocument }
            try await self.save()
            await self.historyWriteTask?.value
            let current = self.book?.id
            let receipt = try await self.repository.receiveTransfer(transfer)
            await self.refresh()
            if let current, transfer.manifest.items.contains(where: { $0.documentID == current }) { await self.open(current, reading: !self.editing) }
            self.history.opened(receipt.entry); await self.queueHistorySave().value
            let title = receipt.entry.isFolder ? self.novels.first(where: { $0.id == receipt.entry.id })?.alias : self.books.first(where: { $0.id == receipt.entry.id })?.fileName
            #if os(iOS)
            let note = receipt.note + "已保存到接收端的本机文稿，可从历史记录打开。"
            #else
            let note = receipt.note + "可从历史记录打开收到的副本，通过另存为选择本地保存位置。"
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
            if !testing && ProcessInfo.processInfo.arguments.contains("--clear-generated-caches") { runGeneratedCacheCleanup() }
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
            if book == nil, !creating, !opening, navigationGeneration == startupNavigation {
                if let last = preferences.string(forKey: "lastBook").flatMap(UUID.init(uuidString:)), books.contains(where: { $0.id == last && $0.trashedAt == nil }) { await open(last) }
                else if let first = books.first(where: { $0.trashedAt == nil }) { await open(first.id) }
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

    /// Explicit maintenance launch; retain library, manuscripts, history and pairing preferences.
    private func runGeneratedCacheCleanup() {
        let manager = FileManager.default
        var errors: [String] = []
        do { try speech.clearAudioCache() } catch { errors.append(error.localizedDescription) }
        let folders = [manager.urls(for: .cachesDirectory, in: .userDomainMask).first, manager.temporaryDirectory].compactMap { $0 }
        for folder in folders {
            do {
                for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { try manager.removeItem(at: file) }
            } catch { errors.append(folder.path + ": " + error.localizedDescription) }
        }
        let report: [String: Any] = ["date": Date().timeIntervalSince1970, "errors": errors,
                                   "cleared": folders.map(\.path), "audioCacheBytes": speech.audioCacheBytes()]
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkEngine")
        do {
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: support.appendingPathComponent("Cache-cleanup.json"), options: .atomic)
        } catch { NSLog("Cache cleanup report failed: %@", error.localizedDescription) }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let generation = historyGeneration
        do {
            await historyWriteTask?.value
            let changed = try await repository.reconcileDocumentsDirectory()
            books = try await repository.list(); novels = try await repository.collections()
            let saved = try await repository.recentHistory()
            if generation == historyGeneration { history = saved }
            if let current = book, changed.contains(current.id), !dirty {
                let loaded = try await repository.load(current.id)
                speech.stop(); book = loaded; editorText = loaded.content; textLength = loaded.content.utf16.count
                editorPosition = loaded.cursor; editorNavigationID = UUID(); await reparse()
                status = "已更新本机目录中的文稿"
            }
        } catch { self.error = error.localizedDescription }
    }
    var availableReceivedSync: ReceivedSync? {
        guard let receivedSync else { return nil }
        let exists = receivedSync.entry.isFolder ? novels.contains { $0.id == receivedSync.entry.id } : books.contains { $0.id == receivedSync.entry.id && $0.trashedAt == nil }
        return exists ? receivedSync : nil
    }
    func revealHistory(_ entry: RecentEntry) {
        requestedHistoryEntry = entry; libraryRequest = UUID()
    }
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

    func recordOpened(_ id: UUID) async {
        let folder = novels.first { $0.entries.contains { $0.documentID == id } }
        history.opened(.init(id: folder?.id ?? id, isFolder: folder != nil))
        await queueHistorySave().value
    }
    func pin(_ entry: RecentEntry) async {
        history.togglePin(entry)
        await queueHistorySave().value
    }
    func placePin(_ id: UUID, at target: UUID) {
        var ids = history.pinned
        guard id != target, ids.contains(id), let targetIndex = ids.firstIndex(of: target) else { return }
        // 使用移除前的目标序号：向上放在目标前，向下放在目标后，两种方向都能排序。
        ids.removeAll { $0 == id }; ids.insert(id, at: min(targetIndex, ids.count))
        history.reorderPins(ids); queueHistorySave()
    }
    func removeRecent(_ id: UUID) async {
        history.remove(id)
        await queueHistorySave().value
    }
    func noteExport(_ fileName: String) {
        let message = "已另存为 " + fileName
        status = message; exportStatus = message
        // 分享面板切回前台也会触发保存，另存为反馈需独立于自动保存状态。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            if self?.exportStatus == message { self?.exportStatus = nil }
        }
    }
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
    func adjacentNovelChapter(forward: Bool) -> BookSummary? {
        guard let novel = currentNovel, let id = book?.id else { return nil }
        let chapters = novel.orderedBooks(from: books, readingOnly: true)
        guard let index = chapters.firstIndex(where: { $0.id == id }), chapters.indices.contains(index + (forward ? 1 : -1)) else { return nil }
        return chapters[index + (forward ? 1 : -1)]
    }
    func turnNovelChapter(forward: Bool) {
        guard let next = adjacentNovelChapter(forward: forward) else { return }
        let continueAudio = speech.playing && !speech.paused
        Task {
            await open(next.id, reading: true, fromBeginning: true)
            guard book?.id == next.id, error == nil else { return }
            if !forward, let last = parsed.segments.last { jump(last.sourceRange.location) }
            if continueAudio { speech.play(from: parsed.segmentIndex(at: book?.cursor ?? 0)) }
        }
    }
    var standaloneBooks: [BookSummary] {
        let grouped = Set(novels.flatMap { $0.entries.map(\.documentID) })
        return books.filter { $0.trashedAt == nil && !grouped.contains($0.id) }
    }
    func importFolder(_ url: URL, alias: String) async {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            commitEditing(); try await save()
            busy = true
            let receipt = try await repository.importFolder(url, alias: alias, linkOriginals: true)
            await refresh()
            if let first = receipt.collection.orderedBooks(from: books, readingOnly: true).first ?? receipt.collection.orderedBooks(from: books).first { await open(first.id, reading: true) }
            status = "\(receipt.reused ? "已打开" : "已导入")《\(receipt.collection.alias)》· \(receipt.collection.entries.count) 个文件" + (receipt.skippedFiles > 0 ? " · 跳过 \(receipt.skippedFiles) 个非文本文件" : "")
        } catch { self.error = error.localizedDescription }
        busy = false
    }
    func renameNovel(_ novel: NovelCollection, alias: String) async {
        do { var updated = novel; updated.alias = alias; try await repository.saveCollection(updated); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func toggleChapterReading(_ novel: NovelCollection, id: UUID) async {
        do {
            var updated = novel
            guard let index = updated.entries.firstIndex(where: { $0.documentID == id }) else { return }
            updated.entries[index].includedInReading.toggle(); try await repository.saveCollection(updated); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func createChapter(in novel: NovelCollection) async {
        await create()
        guard let book, book.title == "未命名文稿", error == nil else { return }
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
                await open(next.id, reading: true, fromBeginning: true)
                guard book?.id == next.id, !editing, error == nil else { return }
                speech.playFromBeginning()
                status = "《\(novel.alias)》· 顺次朗读 " + next.fileName
                return
            }
            status = "《\(novel.alias)》已读完"
        } catch { self.error = error.localizedDescription }
    }

    func create() async {
        guard !opening, !creating, !modeChanging else { return }
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

    func open(_ id: UUID, reading: Bool? = nil, fromBeginning: Bool = false) async {
        guard !opening else { return }
        navigationGeneration = UUID()
        opening = true; busy = true
        defer { opening = false; busy = false }
        do {
            commitEditing(); try await save(); speech.stop()
            var loaded = try await repository.reloadLocalFile(id)
            guard loaded.trashedAt == nil else { return }
            if fromBeginning { loaded.cursor = 0; try await repository.savePosition(id: loaded.id, revision: loaded.revision, cursor: 0) }
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
            status = sourcePath == nil ? "草稿已暂存 · 保存时选择文件位置" : "原文件 · 自动保存"
            #else
            status = sourcePath == nil ? "应用文稿 · 自动保存" : "原文件 · 自动保存"
            #endif
        } catch { self.error = error.localizedDescription }
    }

    func closeDocument() async {
        navigationGeneration = UUID()
        do {
            commitEditing(); try await save(); speech.stop()
            #if os(macOS)
            sourceObserver = nil; sourceConflict = false; sourcePath = nil
            #endif
            book = nil; editorText = ""; textLength = 0; dirty = false; editing = false
            parsed = ParsedText(segments: [], chapters: []); scrollTarget = nil; searchResults = []
        } catch { self.error = error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) async {
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
            if let last { await open(last.id); status = "已打开原文件 · 编辑会保存回原文件" }
        } catch { self.error = error.localizedDescription }
    }

    func textChanged(_ value: String) {
        guard editing, value != editorText else { return }
        editorText = value; textLength = value.utf16.count; dirty = true
        speech.stop()
        saveTask?.cancel()
        #if os(macOS)
        guard !sourceConflict else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--manual-save-ui-testing") { return }
        #endif
        #endif
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            do { try await self.save() } catch { self.error = error.localizedDescription }
        }
    }

    func save() async throws {
        saveTask?.cancel(); saveTask = nil
        positionTask?.cancel(); positionTask = nil
        guard var current = book else { return }
        let changed = current.content != editorText
        current.edit(content: editorText)
        current.cursor = min(current.cursor, editorText.utf16.count)
        book = current
        if changed || dirty { try await repository.save(current, writeSource: editing) }
        else { try await repository.savePosition(id: current.id, revision: current.revision, cursor: current.cursor) }
        if book?.revision == current.revision && editorText == current.content { dirty = false }
        #if os(macOS)
        status = sourcePath == nil ? "草稿已暂存 · 保存时选择文件位置" : "已保存原文件"
        #else
        status = sourcePath == nil ? "已保存应用文稿" : "已保存原文件"
        #endif
        await refresh()
    }

    #if os(macOS)
    private func observeSource() async {
        sourceObserver = nil
        guard let id = book?.id, let url = try? await repository.sourceURL(id), book?.id == id else { return }
        sourcePath = url.path
        sourceObserver = LocalFileObserver(url: url) { [weak self] in
            Task { await self?.checkSourceChanges() }
        }
    }

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
                status = "原文件已改变，已保留当前编辑；请另存修改或重新载入。"
                return
            }
            await reloadSourceDiscardingEdits(protectConcurrentEdits: true)
        } catch { status = "原文件暂时无法读取：" + error.localizedDescription }
    }

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
                status = "原文件已改变，已保留当前编辑；请另存修改或重新载入。"
                return
            }
            let loaded = update.document
            speech.stop(); book = loaded; editorText = loaded.content
            textLength = loaded.content.utf16.count; dirty = false; sourceConflict = false
            editorPosition = min(editorPosition, textLength); editorNavigationID = UUID()
            try await repository.acceptLocalFileUpdate(update)
            await reparse(); await observeSource(); await refresh()
            status = "已更新原文件的最新内容"
        } catch { self.error = error.localizedDescription }
    }

    func snapshotForSaveAs() -> Manuscript? {
        commitEditing(); saveTask?.cancel(); saveTask = nil
        guard var copy = book else { return nil }
        copy.edit(content: editorText)
        return copy
    }

    func finishSaveAs(_ url: URL, snapshot: Manuscript) async throws {
        guard book?.id == snapshot.id else { return }
        var saved = snapshot
        try saved.configure(fileName: url.lastPathComponent, highlightOverride: snapshot.highlightOverride)
        // 另存不能先写旧原文件，也不能让旧文件的冲突阻止保存新副本。
        try await repository.save(saved)
        book = saved
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try await repository.attachSource(url, to: saved.id)
        sourcePath = url.path; sourceConflict = false; await observeSource()
        dirty = editorText != saved.content
        await reparse(); await refresh(); noteExport(url.lastPathComponent)
    }

    func previewHTML() async {
        guard let current = book, TextFormat.detect(current.fileName) == .html else { return }
        do {
            // 正常保存流程包含原文件并发修改检查，预览不能绕过检查覆盖外部修改。
            commitEditing(); try await save()
            guard let saved = book, saved.id == current.id else { return }
            let source = try await repository.sourceURL(saved.id)
            try DocumentActions.previewHTML(saved, source: source) { [weak self] error in
                if let error { self?.error = error.localizedDescription }
            }
            exportStatus = "已发送到默认浏览器 · " + saved.fileName
        } catch { self.error = error.localizedDescription }
    }
    #endif

    func configure(fileName: String, highlight: TextFormat?) async {
        do {
            commitEditing(); try await save()
            guard var current = book else { return }
            try current.configure(fileName: fileName, highlightOverride: highlight)
            book = current; dirty = true; try await save(); await reparse()
        } catch { self.error = error.localizedDescription }
    }

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
    func nameDocument(_ fileName: String) async {
        guard let book else { return }
        await configure(fileName: fileName, highlight: book.highlightOverride)
        if error == nil { preferences.set(true, forKey: "namedDocument:" + book.id.uuidString) }
    }

    var activeBookmarks: [ReadingBookmark] { book?.bookmarks.filter { $0.deletedAt == nil } ?? [] }
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

    func commitEditing() {
        #if os(macOS)
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.identifier?.rawValue == "manuscriptEditor" {
            editor.unmarkText(); textChanged(editor.string); editorPosition = editor.selectedRange().location
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        func sourceEditor(in view: UIView) -> UITextView? {
            if let editor = view as? UITextView, editor.isFirstResponder, editor.accessibilityIdentifier == "manuscriptEditor" { return editor }
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

    func switchMode() async {
        guard !modeChanging, !opening else { return }
        navigationGeneration = UUID()
        modeChanging = true
        defer { modeChanging = false }
        do {
            commitEditing()
            try await save(); speech.stop()
            if editing { await reparse() }
            editing.toggle()
            if editing { editorPosition = book?.cursor ?? 0; editorNavigationID = UUID() }
            if let book, !parsed.segments.isEmpty { scrollTarget = parsed.segmentIndex(at: book.cursor) }
        } catch { self.error = error.localizedDescription }
    }

    func reparse() async {
        guard let current = book else { return }
        let generation = UUID(); parseGeneration = generation
        let result = await Task.detached(priority: .userInitiated) { TextParser.parse(current.content, format: current.format) }.value
        guard parseGeneration == generation, book?.id == current.id, book?.revision == current.revision else { return }
        parsed = result; speech.load(result, title: current.title, documentID: current.id, revision: current.revision)
        speech.seek(toSourceOffset: current.cursor, notifyPosition: false)
    }

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

    func jump(_ offset: Int) {
        speech.seek(toSourceOffset: offset, notifyPosition: false)
        setPosition(offset)
        editorPosition = offset; editorNavigationID = UUID()
        if !parsed.segments.isEmpty { scrollTarget = parsed.segmentIndex(at: offset) }
    }

    func readFromLine(_ offset: Int) {
        let wasPlaying = speech.playing
        jump(offset)
        // 暂停时也允许点选另一行；改变位置后仍保持暂停，避免意外发声。
        if !wasPlaying { speech.play(from: parsed.segmentIndex(at: offset)) }
    }

    func search() async {
        let query = searchQuery, text = editorText, options = findOptions
        do {
            let results = try await Task.detached { try FindReplace.matches(query, in: text, options: options) }.value
            guard query == searchQuery, text == editorText, options == findOptions else { return }
            searchResults = results; searchMessage = results.count >= 2000 ? "显示前 2000 处匹配" : "找到 \(results.count) 处匹配"
        } catch { searchResults = []; searchMessage = "表达式无效：" + error.localizedDescription }
    }

    func replace(all: Bool, range: NSRange? = nil) async {
        guard editing else { return }
        let old = editorText, query = searchQuery, value = replacementQuery, options = findOptions
        do {
            let result = try await Task.detached { try FindReplace.replacing(query, with: value, in: old, options: options, range: all ? nil : range) }.value
            guard editing, old == editorText, query == searchQuery, value == replacementQuery, options == findOptions else { return }
            guard result.text.utf8.count <= Manuscript.maximumBytes else { throw InkError.tooLarge }
            if result.count > 0 { editorMutation = EditorMutation(text: result.text); textChanged(result.text) }
            await search(); searchMessage = "已替换 \(result.count) 处"
        } catch { searchMessage = error.localizedDescription }
    }
    func purgeBookmarks(_ ids: Set<UUID>) async {
        do {
            try await save(); speech.stop(); try await repository.deleteBookmarks(ids)
            if let current = book { book = try await repository.load(current.id); await reparse() }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    #if os(iOS)
    func deleteLocalEntry(_ entry: RecentEntry) async {
        do {
            commitEditing(); try await save(); await historyWriteTask?.value
            let deleted = try await repository.deleteLocalEntry(entry)
            if let current = book, deleted.contains(current.id) {
                navigationGeneration = UUID(); speech.stop(); book = nil; editorText = ""; textLength = 0; dirty = false; editing = false
                parsed = ParsedText(segments: [], chapters: []); scrollTarget = nil; searchResults = []; sourcePath = nil
            }
            if let last = preferences.string(forKey: "lastBook").flatMap(UUID.init(uuidString:)), deleted.contains(last) { preferences.removeObject(forKey: "lastBook") }
            if let receipt = receivedSync, receipt.entry.id == entry.id || deleted.contains(receipt.entry.id) { receivedSync = nil; preferences.removeObject(forKey: "receivedSync") }
            do { try speech.clearAudioCache(documentIDs: deleted) } catch { self.error = "文稿已删除，但部分朗读缓存清理失败：" + error.localizedDescription }
            await refresh(); status = entry.isFolder ? "已删除本机目录及其文稿" : "已删除本机文稿"
        } catch { self.error = error.localizedDescription }
    }

    #endif

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

    func prepareTransfer(_ entry: RecentEntry) async throws -> PreparedTransfer {
        commitEditing(); try await save()
        return try await repository.prepareTransfer(id: entry.id, isFolder: entry.isFolder)
    }
    func chooseSync(_ entry: RecentEntry) {
        pendingSync = entry; showNearby = true
        nearby.start()
    }
    func confirmSync() async {
        guard let entry = pendingSync, nearby.ready, !nearby.transferring else { return }
        pendingSync = nil
        do { let transfer = try await prepareTransfer(entry); try await nearby.push(transfer) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func handoff(_ activity: NSUserActivity) {
        if let raw = activity.userInfo?["documentID"] as? String { pendingHandoff = UUID(uuidString: raw) }
        showNearby = true
        status = "接力入口已打开，请连接源设备以获取最新正文和位置。"
    }
}

#if DEBUG && targetEnvironment(simulator)
// 显式启用的双模拟器传输测试。样本存入独立运行目录，
// 接收、打开和保存仍经过真实 AppModel 路径，不改动正常资料库。
@MainActor private extension AppModel {
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
                var changed = first; changed.edit(content: "电脑修改第一章")
                try await repository.save(changed)
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
                        var changed = book; changed.edit(content: "平板离线修改第一章"); try await self.repository.save(changed)
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
                        await self.switchMode(); self.textChanged(senderText); self.book?.cursor = 3001; try await self.save()
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
                try await wait("first offline copy") { book?.id == base.id && !nearby.transferring }
                let reopened = try LibraryRepository(root: root)
                let exact = try await reopened.load(base.id)
                receivedRevision = exact.revision.uuidString
                try require(exact.content == base.content && exact.checksum == base.checksum && exact.revision == book?.revision && exact.cursor == 1337, "full body stable ID revision checksum and UTF16 position persisted")
                await closeDocument(); await open(base.id, reading: true)
                try require(book?.cursor == 1337 && !editing, "received copy opens in reader at original position")
                nearby.disconnect()
                await switchMode(); textChanged(offlineText); book?.cursor = 2456; try await save()
                let offline = try await reopened.load(base.id)
                try require(offline.content == offlineText && offline.cursor == 2456, "disconnected offline edit and position saved")
                try await connect()
                try await nearby.integrationSendCurrent()
                try await wait("offline edit receipt") { !nearby.transferring }
                textChanged(receiverText); book?.cursor = 3333; try await save()
                nearby.requestCurrent()
                try await wait("conflict offline copy") { book?.conflictOf == base.id && !nearby.transferring }
                let local = try await reopened.load(base.id), conflict = try await reopened.load(book!.id)
                try require(local.content == receiverText && local.cursor == 3333 && conflict.content == senderText && conflict.cursor == 3001 && conflict.id != base.id, "receiver preserved both conflicting bodies and positions")
                await open(base.id, reading: true)
                try await nearby.integrationSendCurrent()
                try await wait("conflict receipt") { !nearby.transferring }
                let count = try await repository.list().count
                let cancelled = Manuscript(title: "未完成传输不得落盘", content: String(repeating: "取消中的正文😀", count: 20000))
                try await nearby.integrationInterrupt(cancelled)
                try require(try await repository.list().count == count, "cancellation preserves existing offline documents")
                try await connect(); nearby.cancel()
                await closeDocument(); await open(base.id, reading: true)
                try require(book?.content == receiverText && book?.cursor == 3333 && !editing, "conflict original reopens offline at edited position")
                try require(nearby.trustedNames.isEmpty, "temporary pairing stores no persistent peer trust")
                report("passed")
            } else { throw InkError.invalidDocument }
        } catch {
            nearby.stop(); report("failed", error.localizedDescription)
        }
    }
}
#endif
