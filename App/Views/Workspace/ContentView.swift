import SwiftUI
import InkCore
import UniformTypeIdentifiers

struct ContentView: View {
    #if os(macOS)
    @State private var confirmSourceReload = false
    #endif
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    @State private var folderSelection = false
    @State private var pendingFolder: URL?
    @State private var namingNovel = false
    @State private var renamingNovel: NovelCollection?
    @State private var novelAlias = ""
    @State private var collapsedNovels: Set<UUID> = []
    @State private var sidebarVisible = true
    #if os(iOS)
    @State private var localDeletion: RecentEntry?
    #endif
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var mobileWidth: CGFloat = 0
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        workspace
        #if DEBUG && os(iOS)
        // 真机探针独占隔离样本，防止触摸编辑改变修订号而破坏样本续读检查。
        .allowsHitTesting(!(ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--speech-device-probe")))
        #endif
        .buttonStyle(KeycapButtonStyle())
        .background(workspaceTheme.background)
        .tint(workspaceTheme.highlight)
        .preferredColorScheme(documentIsDark ? .dark : .light)
        #if os(macOS)
        .background(WindowPaperBridge(theme: workspaceTheme))
        .onChange(of: model.book?.fileName) { _, name in NSApp.keyWindow?.title = name ?? "墨语引擎" }
        #endif
        .onChange(of: model.detailRequest) { _, _ in compactColumn = .detail }
        .onChange(of: model.libraryRequest) { _, _ in
            sidebarVisible = true; compactColumn = .sidebar
            if let entry = model.requestedHistoryEntry, entry.isFolder { collapsedNovels.remove(entry.id) }
        }
        .onChange(of: model.book?.id) { _, id in if id == nil { compactColumn = .sidebar } }
        #if os(iOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: folderSelection ? [.folder] : [.data], allowsMultipleSelection: !folderSelection) { result in
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
            }
        }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showSettings) { SpeechSettings(speech: model.speech, model: model).buttonStyle(KeycapButtonStyle()) }
        .sheet(isPresented: $showSearch) { SearchReplacePanel(model: model, replacing: replaceTab).buttonStyle(KeycapButtonStyle()) }
        .sheet(isPresented: $showBookmarks) { BookmarksView(model: model).buttonStyle(KeycapButtonStyle()) }
        .sheet(isPresented: $showCache) { CacheManager(model: model, speech: model.speech).buttonStyle(KeycapButtonStyle()) }
        #if os(iOS)
        .sheet(isPresented: $model.showLocalDocuments) { LocalDocumentsView(model: model, onClose: { model.showLocalDocuments = false }).buttonStyle(KeycapButtonStyle()) }
        .fullScreenCover(isPresented: $showOutline) { OutlineView(model: model).buttonStyle(KeycapButtonStyle()) }
        .sheet(isPresented: $showFileName, onDismiss: {
            // 命名面板退出后才打开系统保存面板，避免两次呈现互相覆盖成白屏。
            if let file = pendingExport { pendingExport = nil; exportFile = file }
        }) {
            DocumentFileName(fileName: model.book?.fileName ?? "文稿.txt") { name in
                guard let book = model.book else { showFileName = false; return }
                do {
                    var copy = book
                    try copy.configure(fileName: name, highlightOverride: book.highlightOverride)
                    pendingExport = try DocumentActions.prepare(copy)
                    showFileName = false
                } catch { model.error = error.localizedDescription }
            }.buttonStyle(KeycapButtonStyle())
        }
        #else
        .sheet(isPresented: $showOutline) { OutlineView(model: model).buttonStyle(KeycapButtonStyle()) }
        #endif
        .sheet(isPresented: $model.showNearby, onDismiss: { model.pendingSync = nil }) { NearbyView(service: model.nearby, model: model).buttonStyle(KeycapButtonStyle()) }
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
        .alert("重新载入原文件？", isPresented: $confirmSourceReload) {
            Button("取消", role: .cancel) { }
            Button("放弃当前修改并载入", role: .destructive) { Task { await model.reloadSourceDiscardingEdits() } }
        } message: { Text("当前未保存的修改将被磁盘上的最新内容替换。可先另存修改。") }
        #endif
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        #if os(iOS)
        .modifier(LocalDocumentDeletion(model: model, entry: $localDeletion))
        #endif
        .onChange(of: scenePhase) { _, phase in
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
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InkSaveAs"))) { _ in saveAs() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("InkDocumentAction"))) { note in
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
            case "history": returnToLibrary()
            default: break
            }
        }
        .onContinueUserActivity("org.ailifelab.inkengine.read", perform: model.handoff)
        .onOpenURL { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                pendingFolder = url; novelAlias = url.lastPathComponent; namingNovel = true
            } else { Task { await model.importFiles([url]) } }
        }
        .environment(\.paperTheme, workspaceTheme)
    }

    private var workspaceTheme: ReadingTheme { model.readingTheme }
    private var documentIsDark: Bool { workspaceTheme == .dark }

    @ViewBuilder private var workspace: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 76, height: 1)
                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .accessibilityIdentifier("toggleChapterSidebar").accessibilityLabel("历史记录与章节")
                libraryActions.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                Text(model.book?.fileName ?? "墨语引擎").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if model.book != nil { documentActions }
            }.buttonStyle(KeycapButtonStyle(compact: true))
                .padding(.horizontal, 12).frame(height: 54)
                .background { WindowDragRegion() }
            Divider().opacity(0.35)
            HSplitView {
                if sidebarVisible { sidebar.frame(minWidth: 240, idealWidth: 288, maxWidth: 360) }
                document.frame(minWidth: 550, maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(workspaceTheme.background).ignoresSafeArea(edges: .top)
        #else
        GeometryReader { geometry in
            // 宽屏并排，窄屏单页切换；显式管理历史入口，避免系统再插入一个边栏按钮。
            if geometry.size.width >= 1000 {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        NavigationStack { sidebar.toolbar(.hidden, for: .navigationBar) }
                            .frame(width: 288)
                        Divider().opacity(0.35)
                    }
                    NavigationStack { document.toolbar(.visible, for: .navigationBar) }
                }
            } else {
                NavigationStack {
                    if compactColumn == .sidebar {
                        sidebar.toolbar(.hidden, for: .navigationBar)
                    } else { document.toolbar(.visible, for: .navigationBar) }
                }
            }
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
                .onAppear { mobileWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in mobileWidth = width }
        }
        .toolbarBackground(workspaceTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
    }

    private var sidebar: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if model.editing || model.book == nil {
                    Image("BrandLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading) {
                        Text("历史记录").font(.headline).lineLimit(2)
                        Text("本地文件与目录").font(.caption2).tracking(2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    #if os(iOS)
                    if model.book != nil && mobileWidth < 1000 {
                        Button { compactColumn = .detail } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("返回当前文稿").accessibilityIdentifier("returnToDocument")
                    }
                    #endif
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20)
                #if os(iOS)
                // 历史页始终提供文件入口。已有文稿、清空历史或竖屏折叠都不能隐藏打开和新建。
                InkGlassContainer {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    Button { Task { await model.create() } } label: { Label("新建文稿", systemImage: "plus").frame(maxWidth: .infinity) }.accessibilityIdentifier("newBook")
                    Button { chooseImport() } label: { Label("打开文件", systemImage: "folder").frame(maxWidth: .infinity) }.accessibilityIdentifier("importBook")
                    Button { Task { await model.resumeLast() } } label: { Label("继续上次阅读", systemImage: "bookmark").frame(maxWidth: .infinity) }.accessibilityIdentifier("resumeLast")
                    Button { model.showNearby = true } label: { Label("附近设备", systemImage: "laptopcomputer.and.iphone").frame(maxWidth: .infinity) }.accessibilityIdentifier("nearbyDevices")
                }.buttonStyle(KeycapButtonStyle(compact: horizontalSizeClass == .regular))
                    .lineLimit(1).minimumScaleFactor(0.85).padding(.horizontal, 14).padding(.bottom, 16)
                }
                Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy").padding(.horizontal, 14).padding(.bottom, 12)
                Button { chooseImport(folder: true) } label: { Label("添加小说目录", systemImage: "folder.badge.plus").frame(maxWidth: .infinity) }
                    .accessibilityIdentifier("importNovel").padding(.horizontal, 14).padding(.bottom, 12)
                #endif
                List {
                        let pinned = model.history.ordered.filter { model.history.pinned.contains($0.id) }
                        if !pinned.isEmpty {
                            Section("已固定 · 可拖拽排序") {
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
                        Section("最近打开 · 最多 100 条") {
                            ForEach(model.history.ordered.filter { !model.history.pinned.contains($0.id) }) { entry in
                                historyRow(entry).modifier(HistorySwipeActions(model: model, entry: entry))
                            }
                        }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .accessibilityIdentifier("libraryList")
                HStack(spacing: 12) {
                    #if os(iOS)
                    Button { model.showLocalDocuments = true } label: { Label("本机文稿", systemImage: "folder").frame(maxWidth: .infinity) }.accessibilityIdentifier("localDocuments")
                    #endif
                    Button { model.commitEditing(); showCache = true } label: { Label("缓存管理", systemImage: "externaldrive").frame(maxWidth: .infinity) }.accessibilityIdentifier("cacheManager").accessibilityLabel("缓存与书签管理")
                }.buttonStyle(KeycapButtonStyle(compact: true)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(workspaceTheme.sidebar)
            .foregroundStyle(workspaceTheme.foreground)
            #if os(iOS)
            .navigationTitle("历史记录")
            #endif
    }

    private func historyLabel(_ entry: RecentEntry) -> String {
        entry.isFolder ? model.novels.first(where: { $0.id == entry.id })?.alias ?? "目录" : model.books.first(where: { $0.id == entry.id })?.title ?? "文稿"
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
                Button("修改目录别名") { pendingFolder = nil; renamingNovel = novel; novelAlias = novel.alias; namingNovel = true }
                Button("新建章节") { Task { await model.createChapter(in: novel) } }
                Button("移除历史记录") { Task { await model.removeRecent(entry.id) } }
                #if os(iOS)
                Button("删除本机目录…", role: .destructive) { localDeletion = entry }
                #endif
            }.listRowBackground(Color.clear)
        } else if let book = model.books.first(where: { $0.id == entry.id && $0.trashedAt == nil }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { selectBook(book.id) } label: { bookLabel(book).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityIdentifier("book-" + book.title)
                    .contextMenu {
                        pinAction(entry)
                        transferActions(entry)
                        Button("移除历史记录") { Task { await model.removeRecent(entry.id) } }
                        #if os(iOS)
                        Button("删除本机文稿…", role: .destructive) { localDeletion = .init(id: book.id) }
                        #endif
                    }
                if model.book?.id == book.id { headingRows }
            }.listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
    }
    @ViewBuilder private func transferActions(_ entry: RecentEntry) -> some View {
        Button(entry.isFolder ? "分享目录…" : "分享文件…", systemImage: "square.and.arrow.up") { share(entry) }
            .accessibilityIdentifier("shareHistory-" + entry.id.uuidString)
        Button("同步数据到设备…", systemImage: "arrow.triangle.2.circlepath") { model.chooseSync(entry) }
            .accessibilityIdentifier("syncHistory-" + entry.id.uuidString)
        Divider()
    }
    private func pinAction(_ entry: RecentEntry) -> some View {
        Button(model.history.pinned.contains(entry.id) ? "取消固定" : "固定到顶部", systemImage: model.history.pinned.contains(entry.id) ? "pin.slash" : "pin") { Task { await model.pin(entry) } }
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
                    Button(novel.entries.first(where: { $0.documentID == book.id })?.includedInReading == true ? "作为资料，不参与连续朗读" : "参与连续朗读") { Task { await model.toggleChapterReading(novel, id: book.id) } }
                    transferActions(.init(id: book.id))
                    Button("固定此文件", systemImage: "pin") { Task { await model.pin(.init(id: book.id)) } }
                    #if os(iOS)
                    Button("删除本机文稿…", role: .destructive) { localDeletion = .init(id: book.id) }
                    #endif
                }
            if model.book?.id == book.id { headingRows }
        }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
    }

    private var headingRows: some View {
        ForEach(model.parsed.chapters) { chapter in
            Button { model.jump(chapter.sourceOffset); compactColumn = .detail } label: {
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
                        #if os(iOS)
                        if model.editing { documentHeading(book) }
                        #endif
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
                                Text("原文件已改变，当前修改已保留").font(.caption)
                                Spacer()
                                Button("另存修改…") { saveAs() }
                                Button("重新载入…") { confirmSourceReload = true }
                            }.padding(8).background(workspaceTheme.sidebar)
                                .accessibilityIdentifier("sourceConflict")
                        }
                        #endif
                        if model.busy { ProgressView().padding(4) }
                        if model.editing {
                            NativeEditor(text: model.editorText, position: model.editorPosition, navigationID: model.editorNavigationID, fontSize: model.fontSize, format: book.highlightFormat, wrapsLines: model.wrapsLines && !model.columnMode, theme: model.readingTheme, columnMode: model.columnMode, mutation: model.editorMutation, onChange: model.textChanged, onPosition: { model.editorPosition = $0 }).id(book.id)
                        } else { ReaderView(model: model, speech: model.speech, showSettings: $showSettings).id(book.id) }
                        if model.editing { documentStatus(book) }
                    }
                    .background(workspaceTheme.background)
                }
                .background(workspaceTheme.background.ignoresSafeArea())
                #if os(iOS)
                .navigationTitle(book.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
                .toolbarColorScheme(documentIsDark ? .dark : .light, for: .navigationBar)
                #endif
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ModeTabs(editing: model.editing, busy: model.busy) { Task { await model.switchMode() } }
                    }
                    mobileToolbarActions
                }
                #endif
                .userActivity("org.ailifelab.inkengine.read", isActive: true) { activity in
                    activity.title = book.title; activity.isEligibleForHandoff = true
                    activity.isEligibleForSearch = false; activity.isEligibleForPublicIndexing = false
                    activity.userInfo = ["documentID": book.id.uuidString, "cursor": book.cursor, "revision": book.revision.uuidString]
                    activity.requiredUserInfoKeys = ["documentID"]
                }
            } else {
                ContentUnavailableView { Label("让文字被听见", systemImage: "book") }
                description: { Text("从历史记录选择文稿，或使用历史记录顶部的新建与打开。文稿和阅读位置保存在你的设备上。") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(workspaceTheme.background)
            }
    }

    private func documentHeading(_ book: Manuscript) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.editing ? "doc.text" : "book.closed")
                .font(.system(size: 18, weight: .light)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(book.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: model.editing ? "pencil" : "headphones")
                .font(.system(size: 14)).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
        .foregroundStyle(model.editing ? Color.primary : model.readingTheme.foreground)
    }

    private func documentStatus(_ book: Manuscript) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text("编辑模式").accessibilityIdentifier("currentMode").accessibilityValue(book.fileName)
                Text(model.dirty ? "未保存" : "已保存").foregroundStyle(model.dirty ? .orange : workspaceTheme.highlight)
                Spacer(minLength: 4)
                Text("\(model.textLength.formatted()) 字符").foregroundStyle(.secondary)
                if model.columnMode { Text("列模式 · 跨行选择后同时编辑").foregroundStyle(.secondary) }
                syntaxMenu(book)
            }.font(.caption)
            if let status = model.exportStatus { Text(status).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("exportStatus") }
        }.padding(.horizontal, 14).padding(.vertical, 6)
        .foregroundStyle(model.readingTheme.foreground)
    }

    private var wrapButton: some View {
        Button { model.wrapsLines.toggle() } label: { Image(systemName: "arrow.turn.down.left").frame(width: 14) }
            .buttonStyle(KeycapButtonStyle(selected: model.wrapsLines, compact: true))
            .accessibilityIdentifier("wrapToggle").accessibilityLabel("自动换行")
            .accessibilityValue(model.wrapsLines ? "开启" : "关闭").help(model.wrapsLines ? "关闭自动换行" : "开启自动换行")
    }

    private func syntaxMenu(_ book: Manuscript) -> some View {
        DocumentSyntaxMenu(model: model, book: book)
    }

    #if os(iOS)
    @ToolbarContentBuilder private var mobileToolbarActions: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { libraryBackButton }.sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) { mobileActionButtons }.sharedBackgroundVisibility(.hidden)
    }

    private var libraryBackButton: some View {
        Button {
            if mobileWidth >= 1000 { withAnimation { sidebarVisible.toggle() } }
            else { compactColumn = .sidebar }
        } label: { Image(systemName: "sidebar.left").frame(width: 14) }
            .buttonStyle(KeycapButtonStyle()).accessibilityLabel("历史记录与章节").accessibilityIdentifier("showChapterSidebar")
    }

    @ViewBuilder private var mobileActionButtons: some View {
        // 小屏优先保留模式切换、保存、搜索；换行选项收进菜单，避免系统挤掉中间的阅读入口。
        if model.editing && mobileWidth >= 400 { wrapButton }
        if model.editing { Button { save() } label: { Image(systemName: "square.and.arrow.down").frame(width: 14) }.accessibilityLabel("保存").accessibilityIdentifier("saveDocument") }
        Button { model.commitEditing(); replaceTab = false; showSearch = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel(model.editing ? "搜索与替换" : "搜索正文").accessibilityIdentifier("outlineButton")
        Menu {
            if model.editing && mobileWidth < 400 { Toggle("自动换行", isOn: $model.wrapsLines).accessibilityIdentifier("wrapToggle") }
            if model.editing { Toggle("列模式", isOn: $model.columnMode).accessibilityIdentifier("columnModeToggle") }
            Button("章节目录", systemImage: "list.bullet") { model.commitEditing(); showOutline = true }
            if !model.editing { Button("阅读书签", systemImage: "bookmark") { showBookmarks = true }.accessibilityIdentifier("readingBookmarks") }
            themePicker
            Button("缓存与书签管理", systemImage: "externaldrive") { model.commitEditing(); showCache = true }.accessibilityIdentifier("cacheManager")
            Divider()
            Button("另存为…", systemImage: "doc.badge.plus") { saveAs() }.accessibilityIdentifier("saveAs")
            Button("分享…", systemImage: "square.and.arrow.up") { share() }.accessibilityIdentifier("shareDocument")
            Button("同步数据到设备…", systemImage: "arrow.triangle.2.circlepath") { if let book = model.book { model.chooseSync(.init(id: book.id)) } }.accessibilityIdentifier("syncDocument")
            Divider()
            Button("字号与朗读设置", systemImage: "textformat.size") { model.commitEditing(); showSettings = true }.accessibilityIdentifier("speechSettings")
            Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy")
            Button("返回历史记录", systemImage: "books.vertical") { returnToLibrary() }.accessibilityIdentifier("returnLibrary")
        } label: { Image(systemName: "ellipsis").frame(width: 18) }.menuStyle(.button).buttonStyle(KeycapButtonStyle()).accessibilityIdentifier("documentMenu")
    }
    #endif

    private var themeMenu: some View {
        DocumentThemeMenu(model: model)
    }
    private var themePicker: some View {
        Picker("界面主题", selection: $model.readingTheme) {
            ForEach(ReadingTheme.allCases) { theme in Text(theme.label).tag(theme).accessibilityIdentifier("theme-" + theme.rawValue) }
        }.pickerStyle(.inline)
    }

    #if os(macOS)
    @ViewBuilder private var libraryActions: some View {
        if model.book != nil && !model.editing {
            Menu {
                Button("新建文稿", systemImage: "plus") { Task { await model.create() } }
                Button("打开本地文件…", systemImage: "folder") { chooseImport() }
                Button("添加小说目录…", systemImage: "folder.badge.plus") { chooseImport(folder: true) }.accessibilityIdentifier("importNovel")
                Button("继续上次阅读", systemImage: "bookmark") { Task { await model.resumeLast() } }
                Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy")
                Button("附近设备", systemImage: "laptopcomputer.and.iphone") { model.showNearby = true }
            } label: { Label("历史记录", systemImage: "books.vertical") }
                .menuStyle(.button).buttonStyle(KeycapButtonStyle(compact: true)).menuIndicator(.hidden)
                .accessibilityIdentifier("libraryMenu")
        } else {
        HStack(spacing: 8) {
            Button("新建", systemImage: "plus") { Task { await model.create() } }.accessibilityIdentifier("newBook").help("新建文稿 ⌘N")
            Button("打开", systemImage: "folder") { chooseImport() }.accessibilityIdentifier("importBook").help("打开本地文件 ⌘O")
            Spacer(minLength: 0)
            Menu {
                Button("添加小说目录…", systemImage: "folder.badge.plus") { chooseImport(folder: true) }.accessibilityIdentifier("importNovel")
                Button("继续上次阅读", systemImage: "bookmark") { Task { await model.resumeLast() } }.accessibilityIdentifier("resumeLast")
                Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy")
                Button("附近设备", systemImage: "laptopcomputer.and.iphone") { model.showNearby = true }.accessibilityIdentifier("nearbyDevices")
                Divider()
            } label: { Image(systemName: "ellipsis").frame(width: 14) }
                .menuStyle(.button).buttonStyle(KeycapButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("libraryMenu").help("历史记录与设备")
        }.buttonStyle(KeycapButtonStyle(compact: true)).fixedSize(horizontal: true, vertical: false)
        }
    }

    private var documentActions: some View {
        InkGlassContainer {
        HStack(spacing: 10) {
            ModeTabs(editing: model.editing, busy: model.busy) { Task { await model.switchMode() } }
            if let book = model.book, TextFormat.detect(book.fileName) == .html {
                Button { Task { await model.previewHTML() } } label: { Image(systemName: "globe").frame(width: 14) }
                    .accessibilityIdentifier("previewHTML").accessibilityLabel("浏览器预览")
                    .help("在默认浏览器中预览 HTML")
            }
            if model.editing {
            Button { save() } label: { Image(systemName: "square.and.arrow.down").frame(width: 14) }
                .accessibilityIdentifier("saveDocument").accessibilityLabel("保存").help("保存文稿 ⌘S")
            }
            Button { model.commitEditing(); replaceTab = false; showSearch = true } label: { Image(systemName: "magnifyingglass").frame(width: 14) }
                .accessibilityIdentifier("outlineButton").accessibilityLabel(model.editing ? "搜索与替换" : "搜索正文").help("搜索 ⌘F")
            if model.editing { wrapButton }
            if model.editing { themeMenu }
            Menu {
                if model.editing { Toggle("列模式", isOn: $model.columnMode).accessibilityIdentifier("columnModeToggle") }
                Button("章节目录", systemImage: "list.bullet") { model.commitEditing(); showOutline = true }
                if !model.editing { Button("阅读书签", systemImage: "bookmark") { showBookmarks = true }.accessibilityIdentifier("readingBookmarks") }
                Button("缓存与书签管理", systemImage: "externaldrive") { model.commitEditing(); showCache = true }.accessibilityIdentifier("cacheManager")
                Divider()
                Button("另存为…", systemImage: "doc.badge.plus") { saveAs() }.accessibilityIdentifier("saveAs")
                Button("分享…", systemImage: "square.and.arrow.up") { share() }.accessibilityIdentifier("shareDocument")
            Button("同步数据到设备…", systemImage: "arrow.triangle.2.circlepath") { if let book = model.book { model.chooseSync(.init(id: book.id)) } }.accessibilityIdentifier("syncDocument")
                Divider()
                Button("字号与朗读设置", systemImage: "slider.horizontal.3") { model.commitEditing(); showSettings = true }.accessibilityIdentifier("speechSettings")
                Divider()
                Button("隐私与使用说明", systemImage: "hand.raised") { showPrivacy = true }.accessibilityIdentifier("privacyPolicy")
                Button("返回历史记录", systemImage: "books.vertical") { returnToLibrary() }
            } label: { Image(systemName: "ellipsis").frame(width: 14) }
                .menuStyle(.button).buttonStyle(KeycapButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("documentMenu").help("当前文稿选项")
        }.buttonStyle(KeycapButtonStyle(compact: true))
            .fixedSize(horizontal: true, vertical: false)
        }
    }
    #endif

    private func chooseImport(folder: Bool = false) {
        #if os(macOS)
        model.commitEditing()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = !folder; panel.canCreateDirectories = false
        panel.prompt = folder ? "选择目录" : "打开"
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
        if model.book?.id == id { compactColumn = .detail }
        else { Task { await model.open(id, reading: reading) } }
    }

    private func returnToLibrary() {
        #if os(macOS)
        Task { await model.closeDocument() }
        #else
        Task {
            await model.closeDocument()
            if model.book == nil { compactColumn = .sidebar }
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
        guard model.book != nil else { return }
        if model.needsFileName { saveAs() } else { persist() }
    }
    private func saveAs() {
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
                if book.conflictOf != nil { Text("冲突已保留").foregroundStyle(.orange).font(.caption2) }
                Spacer()
                Text(book.updatedAt, style: .date).font(.caption2)
            }.foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 10).padding(.vertical, 14)
            .background(model.book?.id == book.id ? workspaceTheme.highlight.opacity(documentIsDark ? 0.22 : 0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

