import SwiftUI
import InkCore
#if os(iOS)
import UIKit
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    weak var workspace: DocumentWorkspace?
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["INK_LAYOUT_MENU_REPORT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.exportLayoutMenuReport() }
        }
        #endif
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }),
                  let item = NSApp.mainMenu?.items.compactMap({ $0.submenu?.item(withTitle: L10n.tr("显示主窗口")) }).first,
                  let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
    #if DEBUG
    /// Inspect the real system menu without macOS UI automation permissions.
    private func exportLayoutMenuReport() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              let path = ProcessInfo.processInfo.environment["INK_LAYOUT_MENU_REPORT"] else { return }
        func items(_ menu: NSMenu) -> [[String: Any]] {
            menu.items.filter { !$0.isSeparatorItem }.map { item in
                var value: [String: Any] = ["title": item.title]
                if let submenu = item.submenu { value["items"] = items(submenu) }
                return value
            }
        }
        if let menu = NSApp.mainMenu, let data = try? JSONSerialization.data(withJSONObject: items(menu), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        if let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })?.contentView,
           let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path + ".png"))
            }
        }
        exit(0)
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let workspace {
            Task { @MainActor in sender.reply(toApplicationShouldTerminate: await workspace.closeApplication()) }
            return .terminateLater
        }
        guard let model else { return .terminateNow }
        Task { @MainActor in
            do { try await model.save(); sender.reply(toApplicationShouldTerminate: true) }
            catch { model.error = error.localizedDescription; sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}
#endif

@main struct InkEngineApp: App {
    @StateObject private var workspace: DocumentWorkspace
    private var model: AppModel { workspace.library }
    @AppStorage(AppLanguage.preferenceKey, store: L10n.preferences) private var language = AppLanguage.system.rawValue
    init() {
        // Keep construction inside StateObject's autoclosure: App values may be recreated by SwiftUI.
        _workspace = StateObject(wrappedValue: DocumentWorkspace())
        #if os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // 仅在界面测试时稳定弹层空闲检测，不改变系统设置或正常使用的动画。
            UIView.setAnimationsEnabled(false)
        }
        #endif
    }
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    var body: some Scene {
        #if os(macOS)
        WindowGroup(L10n.tr("墨语引擎"), id: "workspace", for: UUID.self) { value in
            TabbedWorkspace(workspace: workspace, requestedID: value.wrappedValue)
                .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
                .frame(minWidth: 850, minHeight: 560)
                .onAppear { delegate.workspace = workspace; delegate.model = model }
        } defaultValue: { DocumentWorkspace.defaultWindowID }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { DocumentCommands(workspace: workspace, speech: model.speech) }
        #else
        WindowGroup(L10n.tr("墨语引擎"), id: "workspace", for: UUID.self) { value in
            if DocumentWorkspace.supported {
                TabbedWorkspace(workspace: workspace, requestedID: value.wrappedValue)
                    .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
            } else { workspaceContent }
        } defaultValue: { DocumentWorkspace.defaultWindowID }
        #endif
    }
    private var workspaceContent: some View {
        ContentView().environmentObject(model)
            .environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
            #if os(macOS)
            .frame(minWidth: 850, minHeight: 560)
            .onAppear { delegate.model = model }
            #endif
    }
}

#if os(macOS)
private struct DocumentCommands: Commands {
    @AppStorage(AppLanguage.preferenceKey, store: L10n.preferences) private var language = AppLanguage.system.rawValue
    @Environment(\.locale) private var appLocale
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var workspace: DocumentWorkspace
    private var model: AppModel { workspace.focusedModel ?? workspace.library }
    @ObservedObject var speech: SpeechEngine
    private var window: UUID? { workspace.focusedWindow }
    private var pane: UUID? { window.flatMap { workspace.window($0)?.focusedPane } }
    var body: some Commands {
        // SwiftUI Commands populate the macOS menu bar beside the Apple menu.
        CommandGroup(replacing: .appSettings) {
            Button(L10n.tr("设置…")) { action("settings") }.keyboardShortcut(",")
            Menu(L10n.tr("语言")) {
                ForEach(AppLanguage.allCases) { choice in
                    Button(choice.nativeName) { language = choice.rawValue }.accessibilityIdentifier("language-" + choice.rawValue)
                }
            }
            Button(L10n.tr("缓存管理")) { action("cache") }.accessibilityIdentifier("cacheManager")
            Button(L10n.tr("附近设备…")) { model.showNearby = true }
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("新建文稿")) { Task { await model.create() } }.keyboardShortcut("n").accessibilityIdentifier("newBook")
            Button(L10n.tr("打开本地文件…")) { action("open") }.keyboardShortcut("o").accessibilityIdentifier("importBook")
            Button(L10n.tr("添加小说目录…")) { action("folder") }.accessibilityIdentifier("importNovel")
        }
        CommandGroup(after: .newItem) {
            Button(L10n.tr("关闭当前标签")) { Task { await model.closeDocument() } }.keyboardShortcut("w").disabled(model.book == nil)
            Button(L10n.tr("关闭窗口")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.tr("保存文稿")) { action("save") }.keyboardShortcut("s").disabled(model.book == nil)
            Button(L10n.tr("另存为…")) { NotificationCenter.default.post(name: Notification.Name("InkSaveAs"), object: nil) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.book == nil)
            Button(L10n.tr("保存全部")) { if let window { Task { await workspace.saveAll(window: window) } } }.keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button(L10n.tr("分享…")) { action("share") }.disabled(model.book == nil)
            Button(L10n.tr("同步数据到设备…")) { action("sync") }.disabled(model.book == nil)
            Menu(L10n.tr("文件操作")) {
                if let id = model.book?.id, let window {
                    Button(L10n.tr("重命名")) { workspace.fileOperation = .init(document: id, window: window, kind: .rename) }
                    Button(L10n.tr("重新载入")) { workspace.fileOperation = .init(document: id, window: window, kind: .reload) }
                    Button(L10n.tr("在 Finder 中显示")) { Task { await workspace.reveal(id) } }.disabled(model.sourcePath == nil)
                    Button(L10n.tr("在终端打开所在目录")) { Task { await workspace.openTerminal(id) } }.disabled(model.sourcePath == nil)
                    Button(L10n.tr("用默认应用打开")) { Task { await workspace.openExternally(id) } }
                    Button(L10n.tr("删除文件…"), role: .destructive) { workspace.fileOperation = .init(document: id, window: window, kind: .delete) }.disabled(model.sourcePath == nil)
                }
            }.disabled(model.book == nil)
            if model.book.map({ TextFormat.detect($0.fileName) == .html }) == true {
                Button(L10n.tr("浏览器预览")) { action("preview") }
            }
        }
        CommandGroup(replacing: .printItem) {
            Button(L10n.tr("打印…")) { if let id = model.book?.id { workspace.printDocument(id) } }.keyboardShortcut("p").disabled(model.book == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(L10n.tr("撤销")) { workspace.performUndo() }.keyboardShortcut("z").disabled(!workspace.canUndo)
            Button(L10n.tr("重做")) { workspace.performUndo(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.canRedo)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(L10n.tr("搜索…")) { action("find") }.keyboardShortcut("f").disabled(model.book == nil)
            Button(L10n.tr("替换…")) { action("replace") }.keyboardShortcut("f", modifiers: [.command, .option]).disabled(model.book == nil || !model.editing)
            Toggle(L10n.tr("列模式"), isOn: Binding(get: { model.columnMode }, set: { model.columnMode = $0 })).disabled(model.book == nil || !model.editing)
        }
        CommandGroup(after: .sidebar) {
            Button(L10n.tr("历史记录与章节")) { if let window { workspace.setWindowSidebarVisible(!(workspace.window(window)?.sidebarVisible ?? true), window: window) } }
            Button(L10n.tr("专注模式")) { if let window { workspace.toggleFocusMode(window: window) } }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(L10n.tr("字号与朗读设置")) { action("settings") }
            Menu(L10n.tr("界面主题")) {
                ForEach(ReadingTheme.allCases) { theme in Button(theme.label) { model.readingTheme = theme } }
            }
            Toggle(L10n.tr("自动换行"), isOn: Binding(get: { model.lineWrappingEnabled }, set: { model.lineWrappingEnabled = $0 })).disabled(model.book == nil || !model.editing)
            if model.book != nil {
                Menu(L10n.tr("语法高亮")) {
                    Picker(L10n.tr("语法高亮"), selection: Binding<TextFormat?>(get: { model.book?.highlightOverride }, set: { format in Task { await model.chooseSyntax(format) } })) {
                        Text(L10n.tr("自动识别 · ") + (model.book.map { TextFormat.detect($0.fileName).label } ?? "")).tag(Optional<TextFormat>.none)
                        ForEach(TextFormat.allCases, id: \.self) { format in Text(format.label).tag(Optional(format)) }
                    }
                }
            }
        }
        CommandMenu(L10n.tr("阅读")) {
            Button(L10n.tr("编辑 / 阅读模式")) { Task { await model.switchMode() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.book == nil)
            Button(L10n.tr("继续上次阅读")) { Task { await model.resumeLast() } }
            Divider()
            Button(L10n.tr("上一章")) { model.turnNovelChapter(forward: false) }.disabled(model.editing || model.adjacentNovelChapter(forward: false) == nil)
            Button(L10n.tr("下一章")) { model.turnNovelChapter(forward: true) }.disabled(model.editing || model.adjacentNovelChapter(forward: true) == nil)
            Button(L10n.tr("章节目录…")) { action("outline") }.disabled(model.book == nil)
            Button(L10n.tr("阅读书签…")) { action("bookmarks") }.disabled(model.book == nil || model.editing)
            Divider()
            Button(model.ownsSpeech && speech.playing && !speech.paused ? L10n.tr("暂停朗读") : L10n.tr("开始朗读")) { Task { await model.toggleSpeech() } }.disabled(model.book == nil || model.editing)
            Button(L10n.tr("停止朗读")) { model.stopOwnedSpeech() }.disabled(!model.ownsSpeech || !speech.playing)
            Button(L10n.tr("朗读设置")) { action("settings") }
        }
        CommandGroup(after: .windowArrangement) {
            Button(L10n.tr("新建窗口")) { openWindow(id: "workspace", value: workspace.newWindow(document: nil)) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L10n.tr("显示主窗口")) { openWindow(id: "workspace", value: workspace.windows.first?.id ?? DocumentWorkspace.defaultWindowID) }.keyboardShortcut("0")
            Divider()
            Button(L10n.tr("管理标签…")) { workspace.tabManagerWindow = window }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button(L10n.tr("重新打开关闭的标签")) { Task { await workspace.reopenClosedTab(in: window) } }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(workspace.recentlyClosedTabs.isEmpty)
            Menu(L10n.tr("最近关闭的标签")) {
                ForEach(workspace.recentlyClosedTabs) { record in
                    Button(record.fileName) { Task { await workspace.reopenClosedTab(record, in: window) } }
                }
            }.disabled(workspace.recentlyClosedTabs.isEmpty)
            Button(L10n.tr("下一个标签")) { if let window { Task { await workspace.selectRelative(1, window: window) } } }.keyboardShortcut(.tab, modifiers: [.control])
            Button(L10n.tr("上一个标签")) { if let window { Task { await workspace.selectRelative(-1, window: window) } } }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button(L10n.tr("标签左移")) { if let window, let pane, let id = model.book?.id { workspace.shiftTab(id, direction: -1, window: window, pane: pane) } }.keyboardShortcut(.pageUp, modifiers: [.control, .shift]).disabled(model.book == nil)
            Button(L10n.tr("标签右移")) { if let window, let pane, let id = model.book?.id { workspace.shiftTab(id, direction: 1, window: window, pane: pane) } }.keyboardShortcut(.pageDown, modifiers: [.control, .shift]).disabled(model.book == nil)
            Button(L10n.tr("克隆到另一视图")) { if let window, let pane, let id = model.book?.id { Task { await workspace.split(id, window: window, pane: pane, clone: true) } } }.disabled(model.book == nil)
            Button(L10n.tr("移到新窗口")) { if let window, let pane, let id = model.book?.id { openWindow(id: "workspace", value: workspace.newWindow(document: id, movingFrom: window, pane: pane)) } }.disabled(model.book == nil)
        }
        CommandGroup(replacing: .help) {
            Button(L10n.tr("隐私与使用说明…")) { action("privacy") }
        }
    }
    private func action(_ name: String) {
        NotificationCenter.default.post(name: Notification.Name("InkDocumentAction"), object: name)
    }
}
#endif

#if os(macOS)
/// 保留原生窗口控制按钮，将主题纸面延伸到标题栏下方。
struct WindowPaperBridge: NSViewRepresentable {
    @Environment(\.locale) private var appLocale
    let theme: ReadingTheme
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = NSColor(theme.background)
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    @Environment(\.locale) private var appLocale
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else { window.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
