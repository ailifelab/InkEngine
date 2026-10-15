import SwiftUI
import InkCore

struct BookmarksView: View {
    @ObservedObject var model: AppModel
    @State private var bookmarkName = ""
    @State private var bookmarkToRename: UUID?
    @State private var bookmarkPrompt = false
    @State private var savingBookmark = false
    @FocusState private var bookmarkFocused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("命名书签 · 与上次阅读位置分别保存") {
                    Button("在当前位置添加书签", systemImage: "bookmark.badge.plus") { bookmarkName = "书签 \(model.activeBookmarks.count + 1)"; bookmarkToRename = nil; bookmarkPrompt = true }.accessibilityIdentifier("addBookmark")
                    ForEach(model.activeBookmarks) { bookmark in
                        HStack {
                            Button(bookmark.name) { model.jump(bookmark.offset); dismiss() }.accessibilityIdentifier("bookmark-" + bookmark.name)
                            Spacer()
                            Button { bookmarkName = bookmark.name; bookmarkToRename = bookmark.id; bookmarkPrompt = true } label: { Image(systemName: "pencil") }.accessibilityLabel("重命名书签 " + bookmark.name)
                            Button(role: .destructive) { Task { await model.changeBookmark(bookmark.id, delete: true) } } label: { Image(systemName: "trash") }.accessibilityLabel("删除书签 " + bookmark.name)
                        }.buttonStyle(KeycapButtonStyle(compact: true))
                    }
                }.listRowBackground(model.readingTheme.sidebar)
            }.scrollContentBackground(.hidden).background(model.readingTheme.background.ignoresSafeArea())
            .listRowBackground(model.readingTheme.sidebar)
            .navigationTitle("阅读书签")
            #if os(iOS)
            .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar { Button("完成") { dismiss() } }
            .sheet(isPresented: $bookmarkPrompt) {
                NavigationStack {
                    Form {
                        TextField("书签名称", text: $bookmarkName).focused($bookmarkFocused).accessibilityIdentifier("bookmarkNameField")
                            .listRowBackground(model.readingTheme.sidebar)
                        Button("保存书签") {
                            guard !savingBookmark else { return }
                            let name = bookmarkName, id = bookmarkToRename
                            savingBookmark = true; bookmarkFocused = false
                            Task {
                                if let id { await model.changeBookmark(id, name: name) }
                                else { await model.addBookmark(name: name) }
                                savingBookmark = false; bookmarkPrompt = false
                            }
                        }.disabled(savingBookmark || bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("saveBookmark")
                            .listRowBackground(model.readingTheme.sidebar)
                    }.scrollContentBackground(.hidden).listRowBackground(model.readingTheme.sidebar)
                        .background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
                    .navigationTitle(bookmarkToRename == nil ? "添加书签" : "重命名书签")
                    .toolbar { Button("取消", role: .cancel) { bookmarkPrompt = false }.disabled(savingBookmark) }
                    .onAppear { bookmarkFocused = true }
                }.frame(minWidth: 300, idealWidth: 420, minHeight: 240)
            }
        }.frame(minWidth: 300, idealWidth: 450, minHeight: 360)
        .task { do { try await model.save(); if model.editing { await model.reparse() } } catch { model.error = error.localizedDescription } }
    }
}

