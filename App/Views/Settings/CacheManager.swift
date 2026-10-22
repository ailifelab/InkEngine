import SwiftUI
import InkCore

struct CacheManager: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechEngine
    @State private var bookmarks: [BookmarkRecord] = []
    @State private var selection: Set<UUID> = []
    @State private var scope = "all"
    @State private var bytes = 0
    @State private var snapshotBytes = 0
    @State private var message = ""
    @State private var working = false
    @Environment(\.dismiss) private var dismiss
    private var filtered: [BookmarkRecord] {
        if scope.hasPrefix("folder:"), let id = UUID(uuidString: String(scope.dropFirst(7))) { return bookmarks.filter { $0.folderID == id } }
        if let id = UUID(uuidString: scope) { return bookmarks.filter { $0.documentID == id } }
        return bookmarks
    }
    private var documentIDs: Set<UUID>? {
        if scope == "all" { return nil }
        if scope.hasPrefix("folder:"), let id = UUID(uuidString: String(scope.dropFirst(7))) { return Set(model.novels.first { $0.id == id }?.entries.map(\.documentID) ?? []) }
        return UUID(uuidString: scope).map { Set([$0]) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker(L10n.tr("管理范围"), selection: $scope) {
                    Text(L10n.tr("全部文件")).tag("all")
                    Section(L10n.tr("目录")) { ForEach(model.novels) { Text($0.alias).tag("folder:" + $0.id.uuidString) } }
                    Section(L10n.tr("文件")) { ForEach(model.books.filter { $0.trashedAt == nil }) { Text($0.fileName).tag($0.id.uuidString) } }
                }.disabled(working).accessibilityIdentifier("cacheScope")
                HStack {
                    Text(L10n.tr("朗读缓存 \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"))
                        .accessibilityIdentifier("audioCacheSize").accessibilityValue(String(bytes))
                    Spacer()
                    Button(L10n.tr("清理朗读缓存")) { clear(.audio, message: L10n.tr("已清理所选范围的朗读缓存")) }
                        .disabled(working).accessibilityIdentifier("clearAudioCache")
                }
                Text(L10n.tr("清理音频会停止所选文件的当前朗读，仍在使用的正文和阅读位置会保留。离线音色是应用资源，不属于可清理缓存。"))
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                Text(L10n.tr("清理缓存时，会一并永久删除所选范围内已移出历史的未保存草稿及其书签。当前打开的文稿、目录中的章节和已保存文件会保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                HStack {
                    Text(L10n.tr("旧版本缓存 \(ByteCountFormatter.string(fromByteCount: Int64(snapshotBytes), countStyle: .file))")); Spacer()
                    Button(L10n.tr("清理旧版本缓存")) { clear(.snapshots, message: L10n.tr("已清理旧版本缓存，当前正文与书签保留")) }.disabled(working).accessibilityIdentifier("clearSnapshotCache")
                }
                HStack {
                    Text(L10n.tr("书签 · \(filtered.count) 条")).font(.headline)
                    Spacer()
                    Button(selection.isSuperset(of: Set(filtered.map(\.id))) && !filtered.isEmpty ? L10n.tr("取消全选") : L10n.tr("全选当前范围")) {
                        let ids = Set(filtered.map(\.id)); if selection.isSuperset(of: ids) { selection.subtract(ids) } else { selection.formUnion(ids) }
                    }.disabled(filtered.isEmpty)
                    Button(L10n.tr("删除所选 \(selection.count) 条"), role: .destructive) {
                        working = true; let ids = selection
                        Task { await model.purgeBookmarks(ids); selection = []; working = false; reload() }
                    }.disabled(selection.isEmpty || working).accessibilityIdentifier("deleteSelectedBookmarks")
                }
                List(filtered) { record in
                    Toggle(isOn: Binding(get: { selection.contains(record.id) }, set: { if $0 { selection.insert(record.id) } else { selection.remove(record.id) } })) {
                        VStack(alignment: .leading) { Text(record.bookmark.name); Text(record.fileName + (record.bookmark.deletedAt == nil ? "" : L10n.tr(" · 已删除残留，可清理"))).font(.caption).foregroundStyle(.secondary) }
                    }.listRowBackground(model.readingTheme.sidebar)
                }.scrollContentBackground(.hidden)
                HStack { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("cacheCleanupResult"); Spacer(); Button(L10n.tr("清理分享临时文件")) { clear(.temporaryExports, message: L10n.tr("已清理分享临时文件")) }.disabled(working).accessibilityIdentifier("clearTemporaryExports") }
            }.padding(18).background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
                .navigationTitle(L10n.tr("缓存与书签管理"))
                .toolbar { InkPanelDoneToolbar { dismiss() } }
        }.frame(minWidth: 320, idealWidth: 680, minHeight: 400, idealHeight: 560).onAppear { reload() }
            .onChange(of: scope) { _, _ in selection = []; reload() }
    }
    private func clear(_ kind: AppModel.CacheCleanup, message success: String) {
        working = true
        let ids = documentIDs
        Task {
            do {
                let count = try await model.clearCaches(kind, documentIDs: ids)
                message = success + (count > 0 ? L10n.tr("；已永久删除 \(count) 份已移出历史的草稿") : "")
                if let id = UUID(uuidString: scope), !model.books.contains(where: { $0.id == id }) { scope = "all" }
                selection = []
            } catch { message = error.localizedDescription }
            working = false; reload()
        }
    }
    private func reload() {
        bytes = speech.audioCacheBytes(documentIDs: documentIDs)
        Task { do { bookmarks = try await model.repository.allBookmarks(includeDeleted: true); snapshotBytes = await model.repository.snapshotCacheBytes(documentIDs: documentIDs) } catch { message = error.localizedDescription } }
    }
}
