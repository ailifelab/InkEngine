import SwiftUI
import InkCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.locale) private var appLocale
    #if os(macOS)
    @State private var confirmSourceReload = false
    #endif
    @EnvironmentObject var model: AppModel
    @Environment(\.workspaceEditorState) private var workspaceEditorState
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    @Environment(\.workspacePaneID) private var workspacePaneID
    @Environment(\.workspaceDocumentActive) private var workspaceDocumentActive
    private var multipleDocumentSelectionAllowed: Bool {
        guard let workspace = model.workspace, let window = workspaceWindowID else { return true }
        return workspace.multipleDocumentsAllowed(window: window)
    }
    private var handlesDocumentActions: Bool {
        guard let workspace = model.workspace else { return true }
        return !workspaceSidebarOnly && workspaceDocumentActive && model.acceptsActions && workspace.focusedWindow == workspaceWindowID && workspace.window(workspaceWindowID ?? UUID())?.focusedPane == workspacePaneID
    }
    @State private var importing = false
    @State private var folderSelection = false
    @State private var pendingFolder: URL?
    @State private var namingNovel = false
    @State private var renamingNovel: NovelCollection?
    @State private var novelAlias = ""
    @State private var collapsedNovels: Set<UUID> = []
    @Environment(\.workspaceSidebarOnly) private var workspaceSidebarOnly
    @State private var navigationSection = "files"
    #if os(iOS)
    @State private var localDeletion: RecentEntry?
    #endif
    @Environment(\.workspaceHeight) private var workspaceHeight
    @Environment(\.workspaceWidth) private var workspaceWidth
    @State private var showSettings = false
    @State private var showPrivacy = false
    @State private var showOutline = false
    @State private var showSearch = false
    @State private var replaceTab = false
    @State private var showBookmarks = false
    @State private var showCache = false
    @State private var showFileName = false
    @State private var pendingExport: PreparedFile?
    @State private var exportFile: PreparedFile?
    @State private var shareFile: PreparedFile?
    @Environment(\.scenePhase) private var scenePhase

    private var decoratedWorkspace: some View {
        workspace
        #if DEBUG && os(iOS)
        // 真机探针独占隔离样本，防止触摸编辑改变修订号而破坏样本续读检查。
        .allowsHitTesting(!(ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--speech-device-probe")))
        #endif
        .simultaneousGesture(TapGesture().onEnded {
            if let workspace = model.workspace, let window = workspaceWindowID, let pane = workspacePaneID {
                Task { await workspace.focus(window: window, pane: pane) }
            }
        }, including: model.manualSaving ? .all : .none)
        .buttonStyle(KeycapButtonStyle())
        .background(workspaceTheme.background)
        .tint(workspaceTheme.highlight)
        .preferredColorScheme(documentIsDark ? .dark : .light)
        #if os(macOS)
        .background(WindowPaperBridge(theme: workspaceTheme))
        .onChange(of: model.book?.fileName) { _, name in if !model.manualSaving && handlesDocumentActions { NSApp.keyWindow?.title = name ?? L10n.tr("墨语引擎") } }
        #endif
        .onChange(of: model.detailRequest) { _, _ in
            if workspaceSidebarOnly { revealDocument() }
        }
        .onChange(of: model.libraryRequest) { _, _ in
            if let workspace = model.workspace, let window = workspaceWindowID { workspace.setWindowSidebarVisible(true, window: window) }
            if let entry = model.requestedHistoryEntry, entry.isFolder { collapsedNovels.remove(entry.id) }
        }
        #if os(iOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: folderSelection ? [.folder] : [.data], allowsMultipleSelection: !folderSelection && multipleDocumentSelectionAllowed) { result in
            switch result {
            case .success(let urls):
                if folderSelection, let url = urls.first { pendingFolder = url; novelAlias = url.lastPathComponent; namingNovel = true }
                else { Task { await model.importFiles(urls) } }
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { model.error = error.localizedDescription }
            }
        }
        #endif
        .sheet(isPresented: $namingNovel) {
            NovelAliasForm(name: $novelAlias, importing: pendingFolder != nil) {
                let folder = pendingFolder, novel = renamingNovel, alias = novelAlias
                namingNovel = false; pendingFolder = nil; renamingNovel = nil
                Task {
                    if let folder { await model.importFolder(folder, alias: alias) }
                    else if let novel { await model.renameNovel(novel, alias: alias) }
                }
            }.appLocalized()
        }
    }

    private var presentedWorkspace: some View {
        decoratedWorkspace
        .sheet(isPresented: $showPrivacy) { PrivacyView().appLocalized() }
        .sheet(isPresented: $showSettings) { SpeechSettings(speech: model.speech, model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
        .sheet(isPresented: $showSearch) { SearchReplacePanel(model: model, replacing: replaceTab).buttonStyle(KeycapButtonStyle()).appLocalized() }
        .sheet(isPresented: $showBookmarks) { BookmarksView(model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
        .sheet(isPresented: $showCache) { CacheManager(model: model, speech: model.speech).buttonStyle(KeycapButtonStyle()).appLocalized() }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { workspaceSidebarOnly && model.showLocalDocuments }, set: { model.showLocalDocuments = $0 })) { LocalDocumentsView(model: model, onClose: { model.showLocalDocuments = false }).buttonStyle(KeycapButtonStyle()).appLocalized() }
        .fullScreenCover(isPresented: $showOutline) { OutlineView(model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
        .sheet(isPresented: $showFileName, onDismiss: {
            // 命名面板退出后才打开系统保存面板，避免两次呈现互相覆盖成白屏。
            if let file = pendingExport { pendingExport = nil; exportFile = file }
        }) {
            DocumentFileName(fileName: model.book?.fileName ?? L10n.tr("文稿.txt")) { name in
                guard let book = model.book else { showFileName = false; return }
                do {
                    var copy = book
                    try copy.configure(fileName: name, highlightOverride: book.highlightOverride)
                    pendingExport = try DocumentActions.prepare(copy)
                    showFileName = false
                } catch { model.error = error.localizedDescription }
            }.buttonStyle(KeycapButtonStyle()).appLocalized()
        }
        #else
        .sheet(isPresented: $showOutline) { OutlineView(model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
        #endif
        .sheet(isPresented: Binding(get: { handlesDocumentActions && model.showNearby }, set: { model.showNearby = $0 }), onDismiss: { model.pendingSync = nil }) { NearbyView(service: model.nearby, model: model).buttonStyle(KeycapButtonStyle()).appLocalized() }
        #if os(iOS)
        .fullScreenCover(item: $exportFile) { file in
            SystemExporter(file: file) { url in
                exportFile = nil
                if let url {
                    Task {
                        await model.nameDocument(url.lastPathComponent); await model.attachSavedFile(url)
                        model.noteExport(url.lastPathComponent)
                    }
                }
            }
        }
        .sheet(item: $shareFile) { SystemShare(file: $0) { shareFile = nil } }
        #endif
        #if os(macOS)
        .alert(L10n.tr("重新载入原文件？"), isPresented: $confirmSourceReload) {
            Button(L10n.tr("取消"), role: .cancel) { }
            Button(L10n.tr("放弃当前修改并载入"), role: .destructive) { Task { await model.reloadSourceDiscardingEdits() } }
        } message: { Text(L10n.tr("当前未保存的修改将被磁盘上的最新内容替换。可先另存修改。")) }
        #endif
        .alert(L10n.tr("操作未完成"), isPresented: Binding(get: { handlesDocumentActions && model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(L10n.tr("知道了")) { model.error = nil } } message: { Text(model.error ?? "") }
        #if os(iOS)
        .modifier(LocalDocumentDeletion(model: model, entry: $localDeletion))
        #endif
    }

    var body: some View {
        presentedWorkspace
        .onChange(of: scenePhase) { _, phase in
            guard !model.manualSaving else { return }
            if phase != .active { persist() }
            else {
                model.nearby.discoverRememberedDevices()
                Task {
                    await model.refresh()
                    #if os(macOS)
                    await model.checkSourceChanges()
                    #endif
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InkSaveAs"))) { _ in if handlesDocumentActions { saveAs() } }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InkDocumentAction"))) { note in
            guard handlesDocumentActions else { return }
            switch note.object as? String {
            case "open": chooseImport()
            case "folder": chooseImport(folder: true)
            case "share": share()
            case "sync": if let book = model.book { model.chooseSync(.init(id: book.id)) }
            case "outline": model.commitEditing(); showOutline = true
            case "find": model.commitEditing(); replaceTab = false; showSearch = true
            case "replace": if model.editing { model.commitEditing(); replaceTab = true; showSearch = true }
            case "bookmarks": if !model.editing { model.commitEditing(); showBookmarks = true }
            case "cache": model.commitEditing(); showCache = true
            case "save": save()
            case "privacy": showPrivacy = true
            case "settings": model.commitEditing(); showSettings = true
            case "speech": if !model.editing { Task { await model.toggleSpeech() } }
            #if os(macOS)
            case "preview": Task { await model.previewHTML() }
            #endif
            case "history": returnToLibrary()
            default: break
            }
        }
        .onContinueUserActivity("org.ailifelab.inkengine.read") { activity in if handlesDocumentActions { model.handoff(activity) } }
        .onOpenURL { url in
            guard !model.manualSaving else { return }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                pendingFolder = url; novelAlias = url.lastPathComponent; namingNovel = true
            } else { Task { await model.importFiles([url]) } }
        }
        .environment(\.paperTheme, workspaceTheme)
    }

    private var workspaceTheme: ReadingTheme { model.readingTheme }
    private var documentIsDark: Bool { workspaceTheme == .dark }

    @ViewBuilder private var workspace: some View {
        if workspaceSidebarOnly { sidebar } else { document }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker(L10n.tr("导航"), selection: $navigationSection) {
                Text(L10n.tr("文稿")).tag("files")
                Text(L10n.tr("大纲")).tag("outline")
                Text(L10n.tr("书签")).tag("bookmarks")
            }.pickerStyle(.segmented).labelsHidden().padding(12).accessibilityIdentifier("navigationSections")
            if navigationSection == "files" {
                List {
                        let pinned = model.history.ordered.filter { model.history.pinned.contains($0.id) }
                        if !pinned.isEmpty {
                            Section(L10n.tr("已固定 · 可拖拽排序")) {
                                #if os(macOS)
                                ForEach(pinned) { entry in
                                    HStack(spacing: 6) {
                                        HistoryPinDragHandle(id: entry.id, label: model.books.first(where: { $0.id == entry.id })?.title ?? model.novels.first(where: { $0.id == entry.id })?.alias ?? entry.id.uuidString, moveTo: model.placePin).frame(width: 18, height: 40)
                                        historyRow(entry)
                                    }
                                }
                                #else
                                ForEach(pinned) { entry in
                                    HStack(spacing: 4) {
                                        MobileHistoryPinDragHandle(id: entry.id, label: historyLabel(entry), color: workspaceTheme.foreground, moveTo: model.placePin)
                                            .frame(width: 36, height: 44)
                                        historyRow(entry)
                                    }
                                    .accessibilityElement(children: .contain)
                                    .modifier(HistorySwipeActions(model: model, entry: entry))
                                }
                                #endif
                            }
                        }
                        Section(L10n.tr("最近打开 · 最多 100 条")) {
                            ForEach(model.history.ordered.filter { !model.history.pinned.contains($0.id) }) { entry in
                                historyRow(entry).modifier(HistorySwipeActions(model: model, entry: entry))
                            }
                        }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("libraryList")
            } else if navigationSection == "outline" {
                List { headingRows }.listStyle(.plain).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("documentOutlineList")
            } else {
                List {
                    ForEach(model.activeBookmarks) { bookmark in
                        Button(bookmark.name) { model.jump(bookmark.offset); revealDocument() }
                            .accessibilityIdentifier("bookmark-" + bookmark.name)
                    }
                    Button(L10n.tr("阅读书签"), systemImage: "bookmark") { showBookmarks = true }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            #if os(iOS)
            Divider()
            HStack {
                Menu {
                    Button(L10n.tr("新建文稿"), systemImage: "plus") { Task { await model.create() }; revealDocument() }.accessibilityIdentifier("newBook")
                    Button(L10n.tr("打开文件"), systemImage: "folder") { chooseImport() }.accessibilityIdentifier("importBook")
                    Button(L10n.tr("添加小说目录"), systemImage: "folder.badge.plus") { chooseImport(folder: true) }.accessibilityIdentifier("importNovel")
                    Button(L10n.tr("本机文稿"), systemImage: "doc.text") { model.showLocalDocuments = true }.accessibilityIdentifier("localDocuments")
                } label: { Label(L10n.tr("文稿"), systemImage: "plus") }
                Spacer()
                Menu {
                    Button(L10n.tr("字号与朗读设置"), systemImage: "slider.horizontal.3") { showSettings = true }.accessibilityIdentifier("speechSettings")
                    LanguageMenu()
                    Button(L10n.tr("缓存管理"), systemImage: "externaldrive") { showCache = true }.accessibilityIdentifier("cacheManager")
                    Button(L10n.tr("附近设备"), systemImage: "laptopcomputer.and.iphone") { model.showNearby = true }.accessibilityIdentifier("nearbyDevices")
                    Button(L10n.tr("隐私与使用说明"), systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy")
                } label: { Image(systemName: "gearshape") }.accessibilityLabel(L10n.tr("设置与设备"))
            }.padding(12).buttonStyle(KeycapButtonStyle(compact: true))
            #endif
        }.background(workspaceTheme.sidebar).foregroundStyle(workspaceTheme.foreground)
    }

    private func revealDocument() {
        guard let workspace = model.workspace, let window = workspaceWindowID else { return }
        #if os(iOS)
        if workspaceWidth < 900 { workspace.setWindowSidebarVisible(false, window: window) }
        #endif
    }

    private func historyLabel(_ entry: RecentEntry) -> String {
        entry.isFolder ? model.novels.first(where: { $0.id == entry.id })?.alias ?? L10n.tr("目录") : model.books.first(where: { $0.id == entry.id })?.title ?? L10n.tr("文稿")
    }
    @ViewBuilder private func historyRow(_ entry: RecentEntry) -> some View {
        if entry.isFolder, let novel = model.novels.first(where: { $0.id == entry.id }) {
            DisclosureGroup(isExpanded: Binding(get: { !collapsedNovels.contains(novel.id) }, set: { if $0 { collapsedNovels.remove(novel.id) } else { collapsedNovels.insert(novel.id) } })) {
                ForEach(novel.orderedBooks(from: model.books)) { chapterRow($0, novel: novel) }
            } label: {
                Label(novel.alias, systemImage: "folder").font(.system(size: 13, weight: .semibold)).accessibilityIdentifier("novel-" + novel.alias)
            }.contextMenu {
                pinAction(entry)
                transferActions(entry)
                Button(L10n.tr("修改目录别名")) { pendingFolder = nil; renamingNovel = novel; novelAlias = novel.alias; namingNovel = true }
                Button(L10n.tr("新建章节")) { Task { await model.createChapter(in: novel) } }
                Button(L10n.tr("移除历史记录")) { Task { await model.removeRecent(entry.id) } }
                #if os(iOS)
                Button(L10n.tr("删除本机目录…"), role: .destructive) { localDeletion = entry }
                #endif
            }.listRowBackground(Color.clear)
        } else if let book = model.books.first(where: { $0.id == entry.id && $0.trashedAt == nil }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { selectBook(book.id) } label: { bookLabel(book).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityIdentifier("book-" + book.title)
                    .contextMenu {
                        pinAction(entry)
                        transferActions(entry)
                        Button(L10n.tr("移除历史记录")) { Task { await model.removeRecent(entry.id) } }
                        #if os(iOS)
                        Button(L10n.tr("删除本机文稿…"), role: .destructive) { localDeletion = .init(id: book.id) }
                        #endif
                    }

            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
    }
    @ViewBuilder private func transferActions(_ entry: RecentEntry) -> some View {
        Button(entry.isFolder ? L10n.tr("分享目录…") : L10n.tr("分享文件…"), systemImage: "square.and.arrow.up") { share(entry) }
            .accessibilityIdentifier("shareHistory-" + entry.id.uuidString)
        Button(L10n.tr("同步数据到设备…"), systemImage: "arrow.triangle.2.circlepath") { model.chooseSync(entry) }
            .accessibilityIdentifier("syncHistory-" + entry.id.uuidString)
        Divider()
    }
    private func pinAction(_ entry: RecentEntry) -> some View {
        Button(model.history.pinned.contains(entry.id) ? L10n.tr("取消固定") : L10n.tr("固定到顶部"), systemImage: model.history.pinned.contains(entry.id) ? "pin.slash" : "pin") { Task { await model.pin(entry) } }
    }

    private func chapterRow(_ book: BookSummary, novel: NovelCollection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selectBook(book.id, reading: !model.editing) } label: {
                HStack(spacing: 6) {
                    Image(systemName: novel.entries.first(where: { $0.documentID == book.id })?.includedInReading == true ? "doc.text" : "doc.text.magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    Text(book.title).font(.system(size: 13)).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.vertical, 8).padding(.horizontal, 6)
                    .background(model.book?.id == book.id ? workspaceTheme.highlight.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("book-" + book.title)
                .contextMenu {
                    Button(novel.entries.first(where: { $0.documentID == book.id })?.includedInReading == true ? L10n.tr("作为资料，不参与连续朗读") : L10n.tr("参与连续朗读")) { Task { await model.toggleChapterReading(novel, id: book.id) } }
                    transferActions(.init(id: book.id))
                    Button(L10n.tr("固定此文件"), systemImage: "pin") { Task { await model.pin(.init(id: book.id)) } }
                    #if os(iOS)
                    Button(L10n.tr("删除本机文稿…"), role: .destructive) { localDeletion = .init(id: book.id) }
                    #endif
                }

        }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
    }

    private var headingRows: some View {
        ForEach(model.parsed.chapters) { chapter in
            Button { model.jump(chapter.sourceOffset); revealDocument() } label: {
                HStack(spacing: 6) {
                    Text("·").foregroundStyle(.secondary)
                    Text(chapter.title).font(.system(size: 12)).lineLimit(2)
                    Spacer(minLength: 0)
                }.padding(.leading, 18).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chapterHeading-\(chapter.id)")
        }
    }

    @ViewBuilder private var document: some View {
            if let book = model.book {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        #if os(macOS)
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--save-naming-ui-testing") {
                            Text("测试导出目录").font(.caption2).accessibilityIdentifier("testExportDirectory")
                                .accessibilityValue(FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineUITests/Exports").path)
                        }
                        if ProcessInfo.processInfo.arguments.contains("--source-watch-ui-testing") {
                            HStack {
                                Text("原文件测试路径").accessibilityIdentifier("testSourcePath").accessibilityValue(model.sourcePath ?? "")
                                Text("磁盘正文").accessibilityIdentifier("testDiskContent").accessibilityValue(model.testDiskContent)
                                Button("测试外部修改") { Task { await model.testWriteSource("External replacement") } }
                                Button("测试外部冲突") { Task { await model.testWriteSource("External conflict") } }
                                Button("读取磁盘内容") { Task { await model.testWriteSource() } }
                            }.font(.caption2)
                        }
                        #endif
                        if model.sourceConflict {
                            HStack {
                                Text(L10n.tr("原文件已改变，当前修改已保留")).font(.caption)
                                Spacer()
                                Button(L10n.tr("另存修改…")) { saveAs() }
                                Button(L10n.tr("重新载入…")) { confirmSourceReload = true }
                            }.padding(8).background(workspaceTheme.sidebar)
                                .accessibilityIdentifier("sourceConflict")
                        }
                        #endif
                        if model.busy { ProgressView().padding(4) }
                        if model.editing {
                            NativeEditor(text: model.editorText, position: model.editorPosition, navigationID: model.editorNavigationID, fontSize: model.fontSize, format: book.highlightFormat, wrapsLines: model.wrapsLines && !model.columnMode, theme: model.readingTheme, columnMode: model.columnMode, mutation: model.editorMutation, onChange: model.textChanged, onPosition: { if (!model.manualSaving || handlesDocumentActions) && model.editorPosition != $0 { model.editorPosition = $0 } }, documentID: book.id, viewState: workspaceEditorState, readOnly: model.documentReadOnly, active: workspaceDocumentActive, navigationEnabled: handlesDocumentActions, onFocus: {
                                if let workspace = model.workspace, let window = workspaceWindowID, let pane = workspacePaneID, workspace.window(window)?.panes.first(where: { $0.id == pane })?.selected == book.id {
                                    Task { await workspace.focus(window: window, pane: pane) }
                                }
                            }).id(book.id)
                        } else { ReaderView(model: model, speech: model.speech, showSettings: $showSettings).id(book.id) }
                        if model.editing && workspaceHeight >= 300 { documentStatus(book) }
                    }
                    .background(workspaceTheme.background)
                }
                .background(workspaceTheme.background.ignoresSafeArea())
                .userActivity("org.ailifelab.inkengine.read", isActive: !model.manualSaving || handlesDocumentActions) { activity in
                    activity.title = book.title; activity.isEligibleForHandoff = true
                    activity.isEligibleForSearch = false; activity.isEligibleForPublicIndexing = false
                    activity.userInfo = ["documentID": book.id.uuidString, "cursor": book.cursor, "revision": book.revision.uuidString]
                    activity.requiredUserInfoKeys = ["documentID"]
                }
            } else {
                ContentUnavailableView { Label(L10n.tr("让文字被听见"), systemImage: "book") }
                description: { Text(L10n.tr("从历史记录选择文稿，或使用历史记录顶部的新建与打开。文稿和阅读位置保存在你的设备上。")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(workspaceTheme.background)
            }
    }

    private func documentStatus(_ book: Manuscript) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(L10n.tr("编辑模式")).accessibilityIdentifier("currentMode").accessibilityValue(book.fileName)
                Text(model.dirty ? L10n.tr("未保存") : L10n.tr("已保存")).foregroundStyle(model.dirty ? .orange : workspaceTheme.highlight)
                Spacer(minLength: 4)
                Text(L10n.tr("\(model.textLength.formatted()) 字符")).foregroundStyle(.secondary)
                #if os(macOS)
                if model.columnMode { Text(L10n.tr("列模式 · 跨行选择后同时编辑")).foregroundStyle(.secondary) }
                #endif
                #if os(iOS)
                Toggle(L10n.tr("自动换行"), isOn: $model.lineWrappingEnabled)
                    .toggleStyle(.button).buttonStyle(WorkspaceControlStyle())
                    // 窄窗口优先保留操作名称，避免按钮被压成无法辨认的“自动…”。
                    .fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                    .background(model.lineWrappingEnabled ? workspaceTheme.highlight.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("editorWrapToggle")
                    .accessibilityValue(model.lineWrappingEnabled ? L10n.tr("开启") : L10n.tr("关闭"))
                #endif
                syntaxMenu(book)
            }.font(.caption).lineLimit(1)
            #if os(iOS)
            if model.columnMode {
                Text(L10n.tr("列模式：单指拖动选择，双指滚动"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("columnTouchHint")
            }
            #endif
            if let status = model.exportStatus { Text(status).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("exportStatus") }
        }.padding(.horizontal, 14).padding(.vertical, 6)
        .foregroundStyle(model.readingTheme.foreground)
    }

    private func syntaxMenu(_ book: Manuscript) -> some View {
        DocumentSyntaxMenu(model: model, book: book)
    }

    private func chooseImport(folder: Bool = false) {
        #if os(macOS)
        model.commitEditing()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder; panel.canCreateDirectories = false
        panel.prompt = folder ? L10n.tr("选择目录") : L10n.tr("打开")
        #if DEBUG
        if folder, let initial = ProcessInfo.processInfo.environment["INK_IMPORT_FOLDER"] { panel.directoryURL = URL(fileURLWithPath: initial, isDirectory: true) }
        #endif
        Task { @MainActor in
            let response = await withCheckedContinuation { continuation in
                if let window = NSApp.keyWindow { panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
                else { panel.begin { continuation.resume(returning: $0) } }
            }
            guard response == .OK else { return }
            if folder, let url = panel.url { pendingFolder = url; novelAlias = url.lastPathComponent; namingNovel = true }
            else { await model.importFiles(panel.urls) }
        }
        #else
        folderSelection = folder; importing = true
        #endif
    }

    private func selectBook(_ id: UUID, reading: Bool? = nil) {
        Task {
            if model.book?.id != id {
                if let workspace = model.workspace {
                    await workspace.open(id, reading: reading ?? !model.editing, in: workspaceWindowID, pane: workspacePaneID)
                } else { await model.open(id, reading: reading) }
            }
            revealDocument()
        }
    }

    private func returnToLibrary() {
        if let workspace = model.workspace, let window = workspaceWindowID { workspace.setWindowSidebarVisible(true, window: window); return }
        #if os(macOS)
        Task { await model.closeDocument() }
        #else
        Task {
            await model.closeDocument()
        }
        #endif
    }

    private func persist() {
        model.commitEditing()
        #if os(macOS)
        guard !model.sourceConflict else { return }
        #endif
        Task { do { try await model.save() } catch { model.error = error.localizedDescription } }
    }
    private func save() {
        if let workspace = model.workspace, let id = model.book?.id {
            Task { _ = await workspace.saveDocument(id, window: workspaceWindowID) }; return
        }
        guard model.book != nil else { return }
        if model.needsFileName { saveAs() } else { persist() }
    }
    private func saveAs() {
        if let workspace = model.workspace, let id = model.book?.id {
            Task { _ = await workspace.saveDocument(id, window: workspaceWindowID, saveAs: true) }; return
        }
        model.commitEditing()
        Task {
            do {
                #if os(macOS)
                guard let book = model.snapshotForSaveAs() else { return }
                if let url = try await DocumentActions.saveAs(book) {
                    try await model.finishSaveAs(url, snapshot: book)
                }
                #else
                try await model.save()
                pendingExport = nil; showFileName = true
                #endif
            } catch { model.error = error.localizedDescription }
        }
    }
    private func share() {
        if let book = model.book { share(.init(id: book.id)) }
    }
    private func share(_ entry: RecentEntry) {
        Task {
            do {
                let transfer = try await model.prepareTransfer(entry)
                let file = try await DocumentActions.prepare(transfer)
                #if os(macOS)
                DocumentActions.share(file)
                #else
                shareFile = file
                #endif
            } catch { model.error = error.localizedDescription }
        }
    }

    private func bookLabel(_ book: BookSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
                .frame(width: 30, height: 38)
            VStack(alignment: .leading, spacing: 7) {
            Text(book.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
            HStack {
                Text((book.fileName as NSString).pathExtension.uppercased()).font(.caption2).fontWeight(.medium)
                if book.conflictOf != nil { Text(L10n.tr("冲突已保留")).foregroundStyle(.orange).font(.caption2) }
                Spacer()
                Text(book.updatedAt, style: .date).font(.caption2)
            }.foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 10).padding(.vertical, 14)
            .background(model.book?.id == book.id ? workspaceTheme.highlight.opacity(documentIsDark ? 0.22 : 0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

