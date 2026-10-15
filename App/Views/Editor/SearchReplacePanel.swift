import SwiftUI
import InkCore

struct SearchReplacePanel: View {
    @ObservedObject var model: AppModel
    @State var replacing = false
    @State private var selected: NSRange?
    @State private var working = false
    @State private var lineIndex = SourceLineIndex("")
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if model.editing {
                    Picker("操作", selection: $replacing) { Text("搜索").tag(false); Text("替换").tag(true) }
                        .pickerStyle(.segmented).accessibilityIdentifier("searchReplaceTabs")
                }
                HStack {
                    TextField("查找内容", text: $model.searchQuery).onSubmit { search() }.accessibilityIdentifier("searchField")
                    Button("搜索") { search() }.disabled(working).accessibilityIdentifier("searchSubmit")
                }
                HStack {
                    Toggle("区分大小写", isOn: $model.findOptions.caseSensitive)
                    Toggle("正则表达式", isOn: $model.findOptions.regularExpression)
                    Toggle("转义字符", isOn: $model.findOptions.escapes)
                }.font(.caption).toggleStyle(.checkboxOnMac)
                if replacing && model.editing {
                    TextField("替换为", text: $model.replacementQuery).accessibilityIdentifier("replacementField")
                    HStack {
                        Text("\\n 换行 · \\t 制表符 · 正则分组 $1、$2").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("替换此处") { replace(all: false) }.disabled(working || selected == nil).accessibilityIdentifier("replaceOne")
                        Button("全部替换") { replace(all: true) }.disabled(working || model.searchQuery.isEmpty).accessibilityIdentifier("replaceAll")
                    }
                }
                Text(model.searchMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("searchMessage")
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") && model.editing { Text(model.editorText).font(.caption2).lineLimit(2).accessibilityIdentifier("replaceEvidence") }
                #endif
                List(Array(model.searchResults.enumerated()), id: \.offset) { index, range in
                    Button {
                        selected = range; model.jump(range.location)
                    } label: {
                        HStack { Text("\(index + 1) · 第 \(lineIndex.line(at: range.location) + 1) 行"); Spacer(); if selected == range { Image(systemName: "checkmark") } }.contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowBackground(model.readingTheme.sidebar)
                }.scrollContentBackground(.hidden)
            }.textFieldStyle(.roundedBorder).autocorrectionDisabled().padding(18)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .background(model.readingTheme.background.ignoresSafeArea())
                .foregroundStyle(model.readingTheme.foreground)
                .navigationTitle(model.editing ? "搜索与替换" : "搜索正文")
                .toolbar { Button("完成") { dismiss() } }
                #if os(iOS)
                .toolbarBackground(model.readingTheme.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                #endif
        }.frame(minWidth: 320, idealWidth: 650, minHeight: 400, idealHeight: 560)
            .task { let text = model.editorText; lineIndex = await Task.detached { SourceLineIndex(text) }.value }
            .onChange(of: model.searchQuery) { _, _ in selected = nil; model.searchResults = [] }
            .onChange(of: model.findOptions.regularExpression) { _, _ in selected = nil }
            .onChange(of: model.findOptions.caseSensitive) { _, _ in selected = nil }
            .onChange(of: model.findOptions.escapes) { _, _ in selected = nil }
    }
    private func search() { working = true; selected = nil; Task { let text = model.editorText; lineIndex = await Task.detached { SourceLineIndex(text) }.value; await model.search(); selected = model.searchResults.first; working = false } }
    private func replace(all: Bool) { working = true; Task { await model.replace(all: all, range: selected); let text = model.editorText; lineIndex = await Task.detached { SourceLineIndex(text) }.value; selected = nil; working = false } }
}

private struct FindToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        #else
        Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.button)
        #endif
    }
}
private extension ToggleStyle where Self == FindToggleStyle { static var checkboxOnMac: FindToggleStyle { FindToggleStyle() } }
