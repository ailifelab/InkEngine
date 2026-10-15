import SwiftUI
import InkCore

struct CacheManager: View {
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
                Picker("管理范围", selection: $scope) {
                    Text("全部文件").tag("all")
                    Section("目录") { ForEach(model.novels) { Text($0.alias).tag("folder:" + $0.id.uuidString) } }
                    Section("文件") { ForEach(model.books.filter { $0.trashedAt == nil }) { Text($0.fileName).tag($0.id.uuidString) } }
                }.accessibilityIdentifier("cacheScope")
                HStack {
                    Text("朗读缓存 \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    Spacer()
                    Button("清理朗读缓存") { working = true; do { try speech.clearAudioCache(documentIDs: documentIDs); message = "已清理所选范围的朗读缓存" } catch { message = error.localizedDescription }; working = false; reload() }
                        .disabled(working).accessibilityIdentifier("clearAudioCache")
                }
                Text("清理音频会停止所选文件的当前朗读，正文和阅读位置会保留。离线音色是应用资源，不属于可清理缓存。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("旧版本缓存 \(ByteCountFormatter.string(fromByteCount: Int64(snapshotBytes), countStyle: .file))"); Spacer()
                    Button("清理旧版本缓存") { working = true; Task { do { try await model.repository.clearSnapshotCache(documentIDs: documentIDs); message = "已清理旧版本缓存，当前正文与书签保留" } catch { message = error.localizedDescription }; working = false; reload() } }.disabled(working)
                }
                HStack {
                    Text("书签 · \(filtered.count) 条").font(.headline)
                    Spacer()
                    Button(selection.isSuperset(of: Set(filtered.map(\.id))) && !filtered.isEmpty ? "取消全选" : "全选当前范围") {
                        let ids = Set(filtered.map(\.id)); if selection.isSuperset(of: ids) { selection.subtract(ids) } else { selection.formUnion(ids) }
                    }.disabled(filtered.isEmpty)
                    Button("删除所选 \(selection.count) 条", role: .destructive) {
                        working = true; let ids = selection
                        Task { await model.purgeBookmarks(ids); selection = []; working = false; reload() }
                    }.disabled(selection.isEmpty || working).accessibilityIdentifier("deleteSelectedBookmarks")
                }
                List(filtered) { record in
                    Toggle(isOn: Binding(get: { selection.contains(record.id) }, set: { if $0 { selection.insert(record.id) } else { selection.remove(record.id) } })) {
                        VStack(alignment: .leading) { Text(record.bookmark.name); Text(record.fileName + (record.bookmark.deletedAt == nil ? "" : " · 已删除残留，可清理")).font(.caption).foregroundStyle(.secondary) }
                    }.listRowBackground(model.readingTheme.sidebar)
                }.scrollContentBackground(.hidden)
                HStack { Text(message).font(.caption).foregroundStyle(.secondary); Spacer(); Button("清理分享临时文件") { do { try DocumentActions.clearTemporaryExports(); message = "已清理分享临时文件" } catch { message = error.localizedDescription } } }
            }.padding(18).background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
                .navigationTitle("缓存与书签管理")
                .toolbar { Button("完成") { dismiss() } }
                #if os(iOS)
                .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                #endif
        }.frame(minWidth: 320, idealWidth: 680, minHeight: 400, idealHeight: 560).onAppear { reload() }
            .onChange(of: scope) { _, _ in selection = []; reload() }
    }
    private func reload() {
        bytes = speech.audioCacheBytes(documentIDs: documentIDs)
        Task { do { bookmarks = try await model.repository.allBookmarks(includeDeleted: true); snapshotBytes = await model.repository.snapshotCacheBytes(documentIDs: documentIDs) } catch { message = error.localizedDescription } }
    }
}
