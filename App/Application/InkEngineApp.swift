import SwiftUI
#if os(iOS)
import UIKit
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 沿用 Cmd-0 的 SwiftUI 窗口入口，保证关闭窗口后再次启动也能显示主窗口。
        // Window 场景会复用已有窗口，因此不会像 WindowGroup 一样重复创建文稿界面。
        DispatchQueue.main.async {
            guard let item = NSApp.mainMenu?.items.compactMap({ $0.submenu?.item(withTitle: "显示主窗口") }).first,
                  let action = item.action else { return }
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
    @StateObject private var model = AppModel()
    #if os(iOS)
    init() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // 仅在界面测试时稳定弹层空闲检测，不改变系统设置或正常使用的动画。
            UIView.setAnimationsEnabled(false)
        }
    }
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    #endif
    var body: some Scene {
        #if os(macOS)
        // 模型管理单个当前文稿，主窗口也只保留一个；重新打开时聚焦已有窗口。
        Window("墨语引擎", id: "workspace") { workspaceContent }
            .defaultSize(width: 1180, height: 780)
            .windowStyle(.hiddenTitleBar)
            .commands { DocumentCommands(model: model, speech: model.speech) }
        #else
        WindowGroup("墨语引擎", id: "workspace") { workspaceContent }
        #endif
    }
    private var workspaceContent: some View {
        ContentView().environmentObject(model)
            #if os(macOS)
            .frame(minWidth: 850, minHeight: 560)
            .onAppear { delegate.model = model }
            #endif
    }
}

#if os(macOS)
private struct DocumentCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechEngine
    var body: some Commands {
            CommandGroup(after: .appInfo) {
                Button("隐私与使用说明…") { action("privacy") }
            }
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") { openWindow(id: "workspace") }.keyboardShortcut("0", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("新建文稿") { Task { await model.create() } }.keyboardShortcut("n")
                Button("打开本地文件…") { action("open") }.keyboardShortcut("o", modifiers: [.command])
                Button("添加小说目录…") { action("folder") }
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存文稿") { action("save") }.keyboardShortcut("s").disabled(model.book == nil)
                Button("另存为…") { NotificationCenter.default.post(name: Notification.Name("InkSaveAs"), object: nil) }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.book == nil)
                Button("分享…") { action("share") }.disabled(model.book == nil)
                Button("同步数据到设备…") { action("sync") }.disabled(model.book == nil)
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("搜索…") { action("find") }.keyboardShortcut("f", modifiers: [.command]).disabled(model.book == nil)
                Button("替换…") { action("replace") }.keyboardShortcut("f", modifiers: [.command, .option]).disabled(model.book == nil || !model.editing)
                Toggle("列模式", isOn: $model.columnMode).disabled(model.book == nil || !model.editing)
                Toggle("自动换行", isOn: $model.wrapsLines).disabled(model.book == nil || !model.editing)
            }
            CommandMenu("阅读") {
                Button("章节目录…") { action("outline") }.disabled(model.book == nil)
                Button("阅读书签…") { action("bookmarks") }.disabled(model.book == nil || model.editing)
                Button("缓存与书签管理…") { action("cache") }
                Button("编辑 / 阅读模式") { Task { await model.switchMode() } }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.book == nil)
                Button("继续上次阅读") { Task { await model.resumeLast() } }
                Button("字号与朗读设置…") { action("settings") }
                Divider()
                Button(speech.playing && !speech.paused ? "暂停朗读" : "开始朗读") {
                    if speech.playing { speech.paused ? speech.resume() : speech.pause() }
                    else { speech.play(from: model.parsed.segmentIndex(at: model.book?.cursor ?? 0)) }
                }.disabled(model.book == nil || model.editing)
                Button("停止朗读") { speech.stop() }
            }
            CommandGroup(after: .sidebar) {
                Button("历史记录") { action("history") }
                Button("附近设备…") { model.showNearby = true }
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
