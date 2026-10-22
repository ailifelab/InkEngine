#if os(iOS)
import SwiftUI
import InkCore

/// 完整文稿入口独立于最近100条历史；目录逐层展开，不把所有章节铺满首屏。
struct LocalDocumentsView: View {
    @Environment(\.locale) private var appLocale
    private struct Route: Hashable { var id: UUID; var path: String = "" }
    @ObservedObject var model: AppModel
    var folderID: UUID? = nil
    var onClose: (() -> Void)? = nil
    var onOpen: () -> Void = {}
    @State private var query = ""
    @State private var deletion: RecentEntry?
    @Environment(\.dismiss) private var dismiss
    private func closeBrowser() {
        // 由呈现方关闭自己的绑定，保证关闭后再次点击仍能产生新的呈现请求。
        if let onClose { onClose() } else { dismiss() }
    }
    private func matches(_ book: BookSummary) -> Bool { query.isEmpty || book.fileName.localizedStandardContains(query) || book.title.localizedStandardContains(query) }
    private func matchesDirectory(_ path: String, in folder: NovelCollection) -> Bool {
        query.isEmpty || path.localizedStandardContains(query) || folder.entries.contains { entry in
            entry.relativePath.hasPrefix(path + "/") && model.books.contains { $0.id == entry.documentID && matches($0) }
        }
    }
    var body: some View {
        NavigationStack {
            browser(folderID.map { Route(id: $0) })
                .navigationDestination(for: Route.self) { browser($0).onAppear { query = "" } }
        }.searchable(text: $query, prompt: L10n.tr("文件名或目录别名"))
            .frame(minWidth: 300, idealWidth: 500, minHeight: 420)
            .modifier(LocalDocumentDeletion(model: model, entry: $deletion))
            .task { await model.refresh() }
    }
    private func browser(_ route: Route?) -> some View {
        let folder = route.flatMap { route in model.novels.first { $0.id == route.id } }
        let contents = folder?.directoryContents(at: route?.path ?? "", books: model.books)
        return List {
            if let folder, let contents {
                ForEach(contents.directories.filter { matchesDirectory($0, in: folder) }, id: \.self) { path in
                    NavigationLink(value: Route(id: folder.id, path: path)) { Label((path as NSString).lastPathComponent, systemImage: "folder") }
                        .accessibilityIdentifier("local-directory-" + path)
                        .listRowBackground(model.readingTheme.sidebar)
                }
                ForEach(contents.files.filter { matches($0) }) { fileButton($0) }
                if contents.directories.isEmpty && contents.files.isEmpty { Text(L10n.tr("这个目录还没有文稿。")) }
            } else if route == nil {
                Section {
                    Text(L10n.tr("文稿按目录保存。移除历史不会删除文件；长按文稿或目录可以删除本机副本。"))
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(L10n.tr("从电脑添加文件")) {
                        #if os(iOS)
                        Text(L10n.tr("在“文件”App 的“我的 iPhone”或“我的 iPad”中打开“墨语引擎”。用数据线连接电脑，在 Finder 的“文件”标签中将 TXT、Markdown 或整个文件夹拖入墨语引擎，再回到应用刷新。"))
                        #else
                        Text(L10n.tr("点击“打开文稿文件夹”，将 TXT、Markdown 或整个文件夹拖入后刷新。"))
                        #endif
                    }.font(.caption).foregroundStyle(.secondary)
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("目录")) {
                    ForEach(model.novels.filter { query.isEmpty || $0.alias.localizedStandardContains(query) || $0.orderedBooks(from: model.books).contains(where: matches) }) { folder in
                        NavigationLink(value: Route(id: folder.id)) {
                            HStack { Label(folder.alias, systemImage: "folder"); Spacer(); Text(L10n.tr("\(folder.orderedBooks(from: model.books).count) 篇")).font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("local-folder-" + folder.alias)
                            .contextMenu { Button(L10n.tr("删除本机目录…"), role: .destructive) { deletion = .init(id: folder.id, isFolder: true) } }
                    }
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("独立文件")) { ForEach(model.standaloneBooks.filter { matches($0) }) { fileButton($0) } }.listRowBackground(model.readingTheme.sidebar)
                if model.books.allSatisfy({ $0.trashedAt != nil }) { Text(L10n.tr("还没有本机文稿，可以新建、打开文件或从电脑添加。")) }
            } else { Text(L10n.tr("目录已移除。")) }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
            .navigationTitle(route?.path.isEmpty == false ? (route!.path as NSString).lastPathComponent : folder?.alias ?? L10n.tr("本机文稿"))
            .accessibilityIdentifier("localDocumentsList")
            .refreshable { await model.refresh() }
            .toolbar {
                InkPanelDoneToolbar(identifier: "closeLocalDocuments") { closeBrowser() }
                ToolbarItemGroup(placement: .primaryAction) {
                    #if os(macOS)
                    Button(L10n.tr("打开文稿文件夹"), systemImage: "folder") { Task { if let url = await model.repository.documentsDirectory { NSWorkspace.shared.open(url) } } }
                    #endif
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 24) }
                        .buttonStyle(.automatic)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(L10n.tr("刷新本机文稿")).accessibilityIdentifier("refreshLocalDocuments")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            #endif
    }
    private func fileButton(_ book: BookSummary) -> some View {
        Button { Task { await model.open(book.id, reading: true); if model.book?.id == book.id { onOpen(); closeBrowser() } } }
        label: { Label(book.fileName, systemImage: "doc.text").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityIdentifier("local-file-" + book.title)
            .listRowBackground(model.readingTheme.sidebar)
            .contextMenu { Button(L10n.tr("删除本机文稿…"), role: .destructive) { deletion = .init(id: book.id) } }
    }
}

#endif
