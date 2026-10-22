import SwiftUI
import InkCore

struct ReaderView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.workspaceEditorState) private var workspaceEditorState
    @Environment(\.workspaceWindowID) private var workspaceWindowID
    @Environment(\.workspacePaneID) private var workspacePaneID
    @Environment(\.workspaceDocumentActive) private var documentActive
    @Environment(\.workspaceTabletopPlayback) private var tabletopPlayback
    @Environment(\.workspaceExpandedPortrait) private var expandedPortrait
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechEngine
    @Binding var showSettings: Bool
    @State private var layout: ReadingLayout?
    @State private var history: [Int] = []
    @State private var request = UUID()
    @State private var loading = false
    @State private var paginationTask: Task<Void, Never>?
    @State private var pendingNavigationOffset: Int?
    @State private var returningFromTranscript = false
    private var viewOffset: Int {
        if let pendingNavigationOffset { return pendingNavigationOffset }
        if model.manualSaving { return layout?.startOffset ?? workspaceEditorState?.readerOffset ?? model.book?.cursor ?? 0 }
        return model.book?.cursor ?? 0
    }
    private var receivesNavigation: Bool {
        guard let workspace = model.workspace else { return true }
        return workspace.focusedWindow == workspaceWindowID && workspace.window(workspaceWindowID ?? UUID())?.focusedPane == workspacePaneID
    }
    private var highlight: NSRange? {
        guard model.ownsSpeech, speech.playing, !speech.auditioning, model.parsed.segments.indices.contains(speech.segmentIndex), let range = speech.spokenRange else { return nil }
        return model.parsed.segments[speech.segmentIndex].sourceRange(forSpoken: range)
    }
    var body: some View {
        Group {
            if tabletopPlayback { speechTranscript }
            else { pagedBody }
        }
    }

    private var speechTranscript: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.parsed.segments.indices, id: \.self) { index in
                            let segment = model.parsed.segments[index]
                            let current = segment.id == speech.segmentIndex
                            Button { model.readFromLine(segment.sourceRange.location) } label: {
                                Text(segment.text)
                                    .font(.system(size: CGFloat(model.fontSize), weight: current ? .semibold : .regular))
                                    .lineSpacing(7).multilineTextAlignment(.leading)
                                    .foregroundStyle(current ? model.readingTheme.highlight : model.readingTheme.foreground.opacity(0.55))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).id(segment.id)
                                .accessibilityIdentifier("speechTranscript-\(segment.id)")
                                .accessibilityAddTraits(current ? .isSelected : [])
                        }
                    }.padding(.horizontal, 28).padding(.vertical, max(24, geometry.size.height * 0.35))
                }.onAppear { proxy.scrollTo(speech.segmentIndex, anchor: .center) }
                    .onChange(of: speech.segmentIndex) { _, index in
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
                    }
            }
        }.background(model.readingTheme.background).accessibilityIdentifier("tabletopSpeechTranscript")
            .onAppear { returningFromTranscript = true }
    }

    private var pagedBody: some View {
        GeometryReader { geometry in
            // 听书时为大播放控件单独预留高度，分页正文同步缩短；停止后恢复纯阅读空间。
            let activeSpeech = model.ownsSpeech && speech.playing
            let bottomClearance: CGFloat = expandedPortrait ? 12 : 0
            let footerHeight: CGFloat = activeSpeech ? 140 : 36
            let size = CGSize(width: max(80, min(740, geometry.size.width - 44)), height: max(80, geometry.size.height - footerHeight - 12 - bottomClearance))
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
                                        .accessibilityIdentifier("readingLine-\(line.id)").accessibilityHint(L10n.tr("从这一行开始朗读"))
                                        .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing") ? String(line.sourceOffset) : "")
                                }
                                Button(L10n.tr("点击左下翻到上一页")) { turn(-1, size: size) }
                                    .frame(width: size.width * 0.28, height: size.height * 0.24).position(x: size.width * 0.14, y: size.height * 0.88)
                                    .accessibilityIdentifier("pageTapPrevious")
                                Button(L10n.tr("点击右下翻到下一页")) { turn(1, size: size) }
                                    .frame(width: size.width * 0.28, height: size.height * 0.24).position(x: size.width * 0.86, y: size.height * 0.88)
                                    .accessibilityIdentifier("pageTapNext")
                            }.buttonStyle(.plain).frame(width: size.width, height: size.height)
                                .accessibilityElement(children: .contain).accessibilityIdentifier("readerPaper")
                        }
                    readerFooter(layout: layout, size: size).frame(height: footerHeight)
                } else if loading { ProgressView(L10n.tr("正在准备这一页")).frame(maxHeight: .infinity) }
                else { Text(L10n.tr("文稿还没有正文，点击编辑开始写作。")).frame(maxHeight: .infinity) }
            }.padding(.top, 12).padding(.bottom, bottomClearance).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain).accessibilityIdentifier("reader")
                .overlay(alignment: .topLeading) {
                    #if DEBUG
                    // 仅隔离 UI 验收读取分页可用尺寸；透明叠层不占正文高度或拦截触摸。
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                        Text(verbatim: "\(size.width)|\(size.height)|\(geometry.size.height)|\(bottomClearance)")
                            .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                            .accessibilityIdentifier("readerPageGeometry").allowsHitTesting(false)
                    }
                    #endif
                }
                .onAppear {
                    let offset = returningFromTranscript ? (model.book?.cursor ?? viewOffset) : viewOffset
                    returningFromTranscript = false
                    paginate(size, offset: offset)
                }
                .onChange(of: size) { _, value in paginate(value, offset: viewOffset, coalesce: true) }
                .onChange(of: documentActive) { _, active in
                    if active { paginate(size, offset: viewOffset) }
                    else { cancelPagination() }
                }
                .onDisappear { cancelPagination() }
                .onChange(of: model.fontSize) { _, _ in paginate(size, offset: viewOffset) }
                .onChange(of: model.readingTheme) { _, _ in paginate(size, offset: layout?.startOffset ?? model.book?.cursor ?? 0) }
                .onChange(of: model.parsed.segments) { _, _ in history = []; paginate(size, offset: viewOffset) }
                .onChange(of: model.book?.cursor) { _, offset in
                    guard receivesNavigation, let offset else { return }
                    if pendingNavigationOffset == offset { return }
                    if pendingNavigationOffset != nil {
                        // A later seek or speech callback owns the cursor, even on this visible page.
                        pendingNavigationOffset = nil
                        cancelPagination()
                    }
                    if let layout, layout.containsSource(offset) { return }
                    history = []; paginate(size, offset: offset)
                }
        }
        // Duo 展开竖屏把原先整条底部安全区用于正文与翻页栏，仅在控件下保留紧凑间距。
        // 直接扩展分页容器的可用高度，字号、翻页命中区和阅读位置仍按新的真实尺寸计算。
        .ignoresSafeArea(.container, edges: expandedPortrait ? .bottom : [])
        .background(model.readingTheme.background.ignoresSafeArea()).foregroundStyle(model.readingTheme.foreground)
    }
    private func pageNavigation(_ layout: ReadingLayout, size: CGSize) -> some View {
        HStack(spacing: 8) {
            Button { turn(-1, size: size) } label: { Image(systemName: "chevron.left").frame(width: 14) }
                .disabled((layout.startOffset == 0 && model.adjacentNovelChapter(forward: false) == nil) || loading).accessibilityLabel(L10n.tr("上一页")).accessibilityIdentifier("previousPage")
                Text(String(format: "%.2f%%", Double(layout.startOffset) / Double(max(1, model.textLength)) * 100))
                .monospacedDigit().font(.caption).frame(minWidth: 54).accessibilityIdentifier("pageNumber").accessibilityValue(loading ? "loading" : "ready")
                .accessibilityLabel(L10n.tr("已读 ") + String(format: "%.2f%%", Double(layout.startOffset) / Double(max(1, model.textLength)) * 100))
            Button { turn(1, size: size) } label: { Image(systemName: "chevron.right").frame(width: 14) }
                .disabled((layout.nextOffset >= model.textLength && model.adjacentNovelChapter(forward: true) == nil) || loading).accessibilityLabel(L10n.tr("下一页")).accessibilityIdentifier("nextPage")
        }.buttonStyle(WorkspaceControlStyle()).fixedSize()
    }
    @ViewBuilder private var selectors: some View {
        DocumentThemeMenu(model: model)
        if let book = model.book { DocumentSyntaxMenu(model: model, book: book) }
    }
    private func readerFooter(layout: ReadingLayout, size: CGSize) -> some View {
        VStack(spacing: 0) {
            pageNavigation(layout, size: size).frame(maxWidth: .infinity).frame(height: 36)
            if model.ownsSpeech && speech.playing {
                SpeechBar(speech: speech, model: model, showSettings: $showSettings, compact: true)
                    .frame(maxWidth: .infinity).frame(height: 104)
            }
        }.padding(.horizontal, 12).frame(maxWidth: .infinity).background(model.readingTheme.background)
            .accessibilityElement(children: .contain).accessibilityIdentifier("readerFooter")
            // 诊断文字只进入无障碍树，不再额外占用读者的正文高度。
            .overlay(alignment: .bottomLeading) {
                Text(L10n.tr("阅读模式 · 只读")).font(.system(size: 1)).lineLimit(1).fixedSize().foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier("currentMode").accessibilityValue(model.book?.fileName ?? "")
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") || ProcessInfo.processInfo.arguments.contains("--playback-diagnostics") {
                    Text(L10n.tr("阅读位置 \(model.book?.cursor ?? 0)")).font(.system(size: 1)).lineLimit(1).fixedSize().foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier("readingPosition").accessibilityValue(String(model.book?.cursor ?? 0))
                }
            }
            .overlay(alignment: .top) {
                if model.ownsSpeech, let error = speech.error { Text(error).font(.caption).padding(8).background(model.readingTheme.sidebar, in: RoundedRectangle(cornerRadius: 8)).offset(y: -44).accessibilityIdentifier("speechError") }
                else if let status = model.exportStatus { Text(status).font(.caption).padding(8).background(model.readingTheme.sidebar, in: RoundedRectangle(cornerRadius: 8)).offset(y: -44).accessibilityIdentifier("exportStatus") }
            }
    }
    private func cancelPagination() {
        request = UUID()
        paginationTask?.cancel(); paginationTask = nil
        loading = false
    }
    private func paginate(_ size: CGSize, offset: Int, updatePosition: Bool = false, coalesce: Bool = false) {
        guard documentActive else { return }
        if updatePosition {
            // Commit the requested source anchor before a resize can supersede this page turn.
            pendingNavigationOffset = offset
            workspaceEditorState?.readerOffset = offset
            model.setPosition(offset)
        }
        paginationTask?.cancel()
        let token = UUID(); request = token; loading = true
        let anchor = pendingNavigationOffset ?? offset
        let parsed = model.parsed, fontSize = model.fontSize, theme = model.readingTheme
        let started = Date()
        paginationTask = Task {
            if coalesce {
                do { try await Task.sleep(for: .milliseconds(60)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            let job = Task.detached(priority: .userInitiated) {
                ReadingLayout(parsed: parsed, fontSize: fontSize, size: size, theme: theme, startOffset: anchor)
            }
            let next = await withTaskCancellationHandler {
                await job.value
            } onCancel: {
                job.cancel()
            }
            guard !Task.isCancelled, request == token else { return }
            layout = next; loading = false; paginationTask = nil
            workspaceEditorState?.readerOffset = next.startOffset
            if let pending = pendingNavigationOffset {
                pendingNavigationOffset = nil
                // Never overwrite a seek/speech position delivered while Core Text was preparing.
                if model.book?.cursor == pending, pending != next.startOffset { model.setPosition(next.startOffset) }
            }
            #if DEBUG
            model.onPagePrepared?(next.startOffset, Date().timeIntervalSince(started), next.text.length, parsed.segments.materializedSegmentCount)
            #endif
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

