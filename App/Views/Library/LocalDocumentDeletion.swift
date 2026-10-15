#if os(iOS)
import SwiftUI
import InkCore

/// 历史滑动删除不走此流程；只有长按/右键菜单发起的本机永久删除需要二次确认。
struct LocalDocumentDeletion: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var entry: RecentEntry?
    func body(content: Content) -> some View {
        content.alert(entry?.isFolder == true ? "删除本机目录？" : "删除本机文稿？", isPresented: Binding(get: { entry != nil }, set: { if !$0 { entry = nil } }), presenting: entry) { target in
            Button("取消", role: .cancel) { entry = nil }
            Button("删除本机文稿", role: .destructive) { entry = nil; Task { await model.deleteLocalEntry(target) } }
        } message: { target in
            let name = target.isFolder ? model.novels.first { $0.id == target.id }?.alias : model.books.first { $0.id == target.id }?.fileName
            Text("将永久删除“\(name ?? "文稿")”的应用内文稿、书签和缓存，包括本机文稿文件夹中的文本。\(target.isFolder ? "其他目录共用的文稿会保留。" : "")此前打开的外部原文件不会删除。此操作无法撤销。")
        }
    }
}

#endif
