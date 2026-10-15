import SwiftUI
import InkCore

struct OutlineView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.parsed.chapters) { chapter in Button(chapter.title) { model.jump(chapter.sourceOffset); dismiss() }.listRowBackground(model.readingTheme.sidebar) }
                if model.parsed.chapters.isEmpty { Text("使用 Markdown 标题或‘第一章’这样的章节名。").font(.caption).foregroundStyle(.secondary) }
            }.scrollContentBackground(.hidden).background(model.readingTheme.background.ignoresSafeArea())
                .foregroundStyle(model.readingTheme.foreground).navigationTitle("章节目录")
                .toolbar { Button("完成") { dismiss() } }
                #if os(iOS)
                .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                #endif
        }.frame(minWidth: 300, idealWidth: 450, minHeight: 360)
            .task { if model.editing { await model.reparse() } }
    }
}
