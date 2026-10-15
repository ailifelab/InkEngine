import SwiftUI
import InkCore

struct ReaderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechEngine
    @Binding var showSettings: Bool
    @State private var layout: ReadingLayout?
    @State private var history: [Int] = []
    @State private var request = UUID()
    @State private var loading = false
    private var highlight: NSRange? {
        guard speech.playing, model.parsed.segments.indices.contains(speech.segmentIndex), let range = speech.spokenRange else { return nil }
        return model.parsed.segments[speech.segmentIndex].sourceRange(forSpoken: range)
    }
    var body: some View {
        GeometryReader { geometry in
            // 工具栏按实际宽度布局；窄屏两行、宽屏一行，正文不再被三组底栏挤压。
            let footerHeight: CGFloat = geometry.size.width >= 700 ? 52 : 112
            let size = CGSize(width: max(80, min(740, geometry.size.width - 44)), height: max(80, geometry.size.height - footerHeight - 12))
            VStack(spacing: 0) {
                if let layout, !layout.pages.isEmpty {
                    ZStack {
                        PaperText(frame: layout.frame(at: 0, highlight: highlight, theme: model.readingTheme), tables: layout.tableDecorations(), theme: model.readingTheme).allowsHitTesting(false)
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 28).onEnded { value in
                                if abs(value.translation.width) > abs(value.translation.height) { turn(value.translation.width < 0 ? 1 : -1, size: size) }
                            })
                            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                                guard !loading else { return }
                                if value.location.y >= size.height * 0.76 && value.location.x <= size.width * 0.28 { turn(-1, size: size) }
                                else if value.location.y >= size.height * 0.76 && value.location.x >= size.width * 0.72 { turn(1, size: size) }
                                else if let offset = layout.sourceOffsetForLine(at: value.location) { model.readFromLine(offset) }
                            })
                    }.frame(width: size.width, height: size.height)
                        .accessibilityRepresentation {
                            ZStack {
                                ForEach(layout.lines()) { line in
                                    Button(line.text) { model.readFromLine(line.sourceOffset) }
                                        .frame(width: line.rect.width, height: line.rect.height)
                                        .position(x: line.rect.midX, y: line.rect.midY)
                                        .accessibilityIdentifier("readingLine-\(line.id)").accessibilityHint("从这一行开始朗读")
                                        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing") ? String(line.sourceOffset) : "")
                                }
                                Button("点击左下翻到上一页") { turn(-1, size: size) }
                                    .frame(width: size.width * 0.28, height: size.height * 0.24).position(x: size.width * 0.14, y: size.height * 0.88)
                                    .accessibilityIdentifier("pageTapPrevious")
                                Button("点击右下翻到下一页") { turn(1, size: size) }
                                    .frame(width: size.width * 0.28, height: size.height * 0.24).position(x: size.width * 0.86, y: size.height * 0.88)
                                    .accessibilityIdentifier("pageTapNext")
                            }.buttonStyle(.plain).frame(width: size.width, height: size.height)
                                .accessibilityElement(children: .contain).accessibilityIdentifier("readerPaper")
                        }
                    readerFooter(layout: layout, size: size, wide: geometry.size.width >= 700).frame(height: footerHeight)
                } else if loading { ProgressView("正在准备这一页").frame(maxHeight: .infinity) }
                else { Text("文稿还没有正文，点击编辑开始写作。").frame(maxHeight: .infinity) }
            }.padding(.top, 12).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader")
                .onAppear { paginate(size, offset: model.book?.cursor ?? 0) }
                .onChange(of: size) { _, value in paginate(value, offset: model.book?.cursor ?? 0) }
                .onChange(of: model.fontSize) { _, _ in paginate(size, offset: model.book?.cursor ?? 0) }
                .onChange(of: model.readingTheme) { _, _ in paginate(size, offset: layout?.startOffset ?? model.book?.cursor ?? 0) }
                .onChange(of: model.parsed.segments) { _, _ in history = []; paginate(size, offset: model.book?.cursor ?? 0) }
                .onChange(of: model.book?.cursor) { _, offset in
                    guard let offset else { return }
                    if let layout, layout.containsSource(offset) { return }
                    history = []; paginate(size, offset: offset)
                }
        }.background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
    }
    private func pageNavigation(_ layout: ReadingLayout, size: CGSize) -> some View {
        HStack(spacing: 8) {
            Button { turn(-1, size: size) } label: { Image(systemName: "chevron.left").frame(width: 14) }
                .disabled((layout.startOffset == 0 && model.adjacentNovelChapter(forward: false) == nil) || loading).accessibilityLabel("上一页").accessibilityIdentifier("previousPage")
                Text(String(format: "%.2f%%", Double(layout.startOffset) / Double(max(1, model.textLength)) * 100))
                .monospacedDigit().font(.caption).frame(minWidth: 54).accessibilityIdentifier("pageNumber").accessibilityValue(loading ? "loading" : "ready")
                .accessibilityLabel("已读 " + String(format: "%.2f%%", Double(layout.startOffset) / Double(max(1, model.textLength)) * 100))
            Button { turn(1, size: size) } label: { Image(systemName: "chevron.right").frame(width: 14) }
                .disabled((layout.nextOffset >= model.textLength && model.adjacentNovelChapter(forward: true) == nil) || loading).accessibilityLabel("下一页").accessibilityIdentifier("nextPage")
        }.buttonStyle(KeycapButtonStyle(compact: true)).fixedSize()
    }
    @ViewBuilder private var selectors: some View {
        DocumentThemeMenu(model: model)
        if let book = model.book { DocumentSyntaxMenu(model: model, book: book) }
    }
    private func readerFooter(layout: ReadingLayout, size: CGSize, wide: Bool) -> some View {
        VStack(spacing: wide ? 0 : 12) {
            if wide {
                HStack(spacing: 12) {
                    pageNavigation(layout, size: size)
                    Spacer(minLength: 8)
                    SpeechBar(speech: speech, model: model, showSettings: $showSettings, compact: true)
                    Spacer(minLength: 8)
                    selectors
                }
            } else {
                HStack(spacing: 6) { pageNavigation(layout, size: size); Spacer(minLength: 4); selectors }.frame(height: 44)
                SpeechBar(speech: speech, model: model, showSettings: $showSettings, compact: true).frame(maxWidth: .infinity).frame(height: 44)
            }
        }.padding(.horizontal, 12).frame(maxWidth: .infinity).background(model.readingTheme.background)
            .accessibilityElement(children: .contain).accessibilityIdentifier("readerFooter")
            // 诊断文字只进入无障碍树，不再额外占用读者的正文高度。
            .overlay(alignment: .bottomLeading) {
                Text("阅读模式 · 只读").font(.system(size: 1)).lineLimit(1).fixedSize().foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier("currentMode").accessibilityValue(model.book?.fileName ?? "")
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") {
                    Text("阅读位置 \(model.book?.cursor ?? 0)").font(.system(size: 1)).lineLimit(1).fixedSize().foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier("readingPosition").accessibilityValue(String(model.book?.cursor ?? 0))
                }
            }
            .overlay(alignment: .top) {
                if let error = speech.error { Text(error).font(.caption).padding(8).background(model.readingTheme.sidebar, in: RoundedRectangle(cornerRadius: 8)).offset(y: -44).accessibilityIdentifier("speechError") }
                else if let status = model.exportStatus { Text(status).font(.caption).padding(8).background(model.readingTheme.sidebar, in: RoundedRectangle(cornerRadius: 8)).offset(y: -44).accessibilityIdentifier("exportStatus") }
            }
    }
    private func paginate(_ size: CGSize, offset: Int, updatePosition: Bool = false) {
        let token = UUID(); request = token; loading = true
        let parsed = model.parsed, fontSize = model.fontSize, theme = model.readingTheme
        let started = Date()
        Task {
            let next = await Task.detached(priority: .userInitiated) { ReadingLayout(parsed: parsed, fontSize: fontSize, size: size, theme: theme, startOffset: offset) }.value
            guard request == token else { return }
            layout = next; loading = false
            #if DEBUG
            model.onPagePrepared?(next.startOffset, Date().timeIntervalSince(started), next.text.length, parsed.segments.materializedSegmentCount)
            #endif
            if updatePosition { model.setPosition(next.startOffset) }
        }
    }
    private func turn(_ delta: Int, size: CGSize) {
        guard let layout, !loading else { return }
        if delta > 0 {
            guard layout.nextOffset < model.textLength else { model.turnNovelChapter(forward: true); return }
            history.append(layout.startOffset)
            paginate(size, offset: layout.nextOffset, updatePosition: true)
        } else {
            guard layout.startOffset > 0 else { model.turnNovelChapter(forward: false); return }
            if let previous = history.popLast() { paginate(size, offset: previous, updatePosition: true) }
            else { paginate(size, offset: max(0, layout.startOffset - 400), updatePosition: true) }
        }
    }
}

