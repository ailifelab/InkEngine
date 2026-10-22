import SwiftUI
import InkCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 展开竖屏仅在顶部两行按系统遮挡横向避让，不把整条状态栏高度留空。
private struct WorkspaceTopChromeLayout {
    var docked = false
    var toolbarLeading: CGFloat = 0
    var toolbarTrailing: CGFloat = 0
    var tabsLeading: CGFloat = 0
    var tabsTrailing: CGFloat = 0
}
private struct WorkspaceTopChromeKey: EnvironmentKey { static let defaultValue = WorkspaceTopChromeLayout() }
private struct WorkspaceTopTabInsets: ViewModifier {
    @Environment(\.workspaceTopChromeLayout) private var layout
    func body(content: Content) -> some View {
        content.padding(.leading, layout.tabsLeading).padding(.trailing, layout.tabsTrailing)
    }
}
private struct WorkspaceSidebarOnlyKey: EnvironmentKey { static let defaultValue = false }
private struct WorkspaceHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 1000 }
private struct WorkspaceWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct WorkspaceWindowKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct WorkspacePaneKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct WorkspaceSidebarKey: EnvironmentKey { static let defaultValue = false }
private struct WorkspaceSplitKey: EnvironmentKey { static let defaultValue = false }
private struct WorkspaceDocumentActiveKey: EnvironmentKey { static let defaultValue = true }
private struct WorkspaceTabletopPlaybackKey: EnvironmentKey { static let defaultValue = false }
private struct WorkspaceExpandedPortraitKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workspaceExpandedPortrait: Bool { get { self[WorkspaceExpandedPortraitKey.self] } set { self[WorkspaceExpandedPortraitKey.self] = newValue } }
    fileprivate var workspaceTopChromeLayout: WorkspaceTopChromeLayout { get { self[WorkspaceTopChromeKey.self] } set { self[WorkspaceTopChromeKey.self] = newValue } }
    var workspaceSidebarOnly: Bool { get { self[WorkspaceSidebarOnlyKey.self] } set { self[WorkspaceSidebarOnlyKey.self] = newValue } }
    var workspaceHeight: CGFloat { get { self[WorkspaceHeightKey.self] } set { self[WorkspaceHeightKey.self] = newValue } }
    var workspaceWidth: CGFloat { get { self[WorkspaceWidthKey.self] } set { self[WorkspaceWidthKey.self] = newValue } }
    var workspaceWindowID: UUID? { get { self[WorkspaceWindowKey.self] } set { self[WorkspaceWindowKey.self] = newValue } }
    var workspacePaneID: UUID? { get { self[WorkspacePaneKey.self] } set { self[WorkspacePaneKey.self] = newValue } }
    var workspaceSidebarVisible: Bool { get { self[WorkspaceSidebarKey.self] } set { self[WorkspaceSidebarKey.self] = newValue } }
    var workspaceSplit: Bool { get { self[WorkspaceSplitKey.self] } set { self[WorkspaceSplitKey.self] = newValue } }
    var workspaceDocumentActive: Bool { get { self[WorkspaceDocumentActiveKey.self] } set { self[WorkspaceDocumentActiveKey.self] = newValue } }
    var workspaceTabletopPlayback: Bool { get { self[WorkspaceTabletopPlaybackKey.self] } set { self[WorkspaceTabletopPlaybackKey.self] = newValue } }
}

struct TabbedWorkspace: View {
    @ObservedObject var workspace: DocumentWorkspace
    let requestedID: UUID?
    @State private var windowID: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.scenePhase) private var scenePhase
    @State private var renamedFile = ""
    @State private var workspaceWidth: CGFloat = 1000
    @State private var workspaceHeight: CGFloat = 1000
    @SceneStorage("workspace-window") private var restoredWindow = ""
    @SceneStorage("workspace-duo-capable") private var duoCapable = false

    var body: some View {
        Group {
            if let id = windowID, let layout = workspace.window(id) {
                platformContents(layout)
                    .environment(\.workspaceWindowID, id)
                    #if os(macOS)
                    .background(WorkspaceWindowBridge(workspace: workspace, id: id))
                    #else
                    .background(WorkspaceSceneBridge(workspace: workspace, id: id))
                    #endif
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .sheet(isPresented: Binding(get: { windowID != nil && workspace.tabManagerWindow == windowID }, set: { if !$0 { workspace.tabManagerWindow = nil } })) {
            if let id = windowID, let layout = workspace.window(id) {
                WorkspaceTabManager(workspace: workspace, window: id, initialPane: layout.focusedPane).appLocalized()
            }
        }
        .task {
            await workspace.restore()
            while !workspace.library.initialized { await Task.yield() }
            let reset = ProcessInfo.processInfo.arguments.contains("--reset-ui-testing")
            let candidate = requestedID ?? UUID(uuidString: restoredWindow)
            let requested = reset && candidate.flatMap({ workspace.window($0) }) == nil ? DocumentWorkspace.defaultWindowID : candidate
            let id = workspace.ensureWindow(requested)
            windowID = id; restoredWindow = id.uuidString
            await workspace.focus(window: id)
            if supportsMultipleWindows && id == workspace.windows.first?.id { for other in workspace.restoredWindowIDs() { openWindow(id: "workspace", value: other) } }
            if !ProcessInfo.processInfo.arguments.contains("--ui-testing"), workspace.sessions.isEmpty && workspace.library.books.isEmpty { await workspace.create(in: id) }
        }
        .onOpenURL { url in Task {
            if let id = windowID { await workspace.focus(window: id) }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { await workspace.library.importFolder(url, alias: url.lastPathComponent) }
            else { await workspace.importFiles([url]) }
        } }
        #if os(iOS)
        .overlay { if let id = windowID { keyboardActions(window: id).frame(width: 0, height: 0).clipped().accessibilityHidden(true) } }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await workspace.checkpoint() } }
            else if let id = windowID { Task {
                await workspace.focus(window: id)
                await workspace.library.refresh()
            } }
        }
        .alert(L10n.tr("保存修改？"), isPresented: Binding(get: { workspace.closeQuestion?.window == windowID && workspace.closeQuestion != nil }, set: { _ in })) {
            Button(L10n.tr("是")) { workspace.answerClose(.save) }.accessibilityIdentifier("closeSaveYes")
            Button(L10n.tr("否"), role: .destructive) { workspace.answerClose(.discard) }.accessibilityIdentifier("closeSaveNo")
            Button(L10n.tr("取消"), role: .cancel) { workspace.answerClose(.cancel) }.accessibilityIdentifier("closeSaveCancel")
        } message: {
            if let question = workspace.closeQuestion {
                Text(L10n.tr("是否保存对“\(question.name)”的修改？选择“否”将放弃未保存的修改。\n\(question.index) / \(question.count)"))
            }
        }
        .alert(L10n.tr("操作未完成"), isPresented: Binding(get: { workspace.failure != nil && workspace.focusedWindow == windowID }, set: { if !$0 { workspace.failure = nil } })) {
            Button(L10n.tr("知道了")) { workspace.failure = nil }
        } message: { Text(workspace.failure ?? "") }
        .alert(L10n.tr("重命名文件"), isPresented: operationBinding(.rename)) {
            TextField(L10n.tr("文件名"), text: $renamedFile)
            Button(L10n.tr("取消"), role: .cancel) { workspace.fileOperation = nil }
            Button(L10n.tr("重命名")) { if let operation = workspace.fileOperation { workspace.fileOperation = nil; Task { await workspace.rename(operation.document, name: renamedFile) } } }
        }
        .alert(L10n.tr("删除文件？"), isPresented: operationBinding(.delete)) {
            Button(L10n.tr("取消"), role: .cancel) { workspace.fileOperation = nil }
            Button(L10n.tr("删除"), role: .destructive) { if let operation = workspace.fileOperation { workspace.fileOperation = nil; Task { await workspace.deleteFile(operation.document, window: operation.window) } } }
        } message: {
            #if os(macOS)
            Text(L10n.tr("此操作将原文件移入废纸篓。关闭标签不会删除文件。"))
            #else
            Text(L10n.tr("此操作删除应用内的本机文稿，外部原文件不会删除。"))
            #endif
        }
        .alert(L10n.tr("重新载入原文件？"), isPresented: operationBinding(.reload)) {
            Button(L10n.tr("取消"), role: .cancel) { workspace.fileOperation = nil }
            Button(L10n.tr("重新载入"), role: .destructive) { if let operation = workspace.fileOperation { workspace.fileOperation = nil; Task { await workspace.reload(operation.document) } } }
        } message: { Text(L10n.tr("当前未保存的修改将被磁盘上的最新内容替换。可先另存修改。")) }
        .onChange(of: workspace.fileOperation?.id) { _, _ in
            if let operation = workspace.fileOperation, operation.window == windowID { renamedFile = workspace.sessions[operation.document]?.book?.fileName ?? "" }
        }
        #if os(iOS)
        .sheet(isPresented: Binding(get: { workspace.folderWindow != nil && workspace.folderWindow == windowID }, set: { _ in })) {
            WorkspaceFolderPicker(directoryURL: workspace.folderInitialURL) { folder in
                workspace.folderWindow = nil
                if let folder { Task { await workspace.library.importFolder(folder, alias: folder.lastPathComponent) } }
            }
        }
        .sheet(item: Binding(get: { workspace.exportWindow == windowID ? workspace.exportSnapshot : nil }, set: { _ in })) { snapshot in
            WorkspaceSaveSheet(workspace: workspace, snapshot: snapshot).appLocalized()
        }
        #endif
    }

    #if os(iOS)
    /// iPad 外接键盘的命令桥接；只承接系统快捷键，不展示按钮或占用正文空间。
    private func keyboardActions(window: UUID) -> some View {
        let model = workspace.model(window)
        return Group {
            Button(L10n.tr("新建文稿")) { Task { await workspace.create(in: window) } }.keyboardShortcut("n")
            Button(L10n.tr("保存")) { if let id = model.book?.id { Task { _ = await workspace.saveDocument(id, window: window) } } }.keyboardShortcut("s")
            Button(L10n.tr("另存为…")) { if let id = model.book?.id { Task { _ = await workspace.saveDocument(id, window: window, saveAs: true) } } }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button(L10n.tr("保存全部")) { Task { await workspace.saveAll(window: window) } }.keyboardShortcut("s", modifiers: [.command, .option])
            Button(L10n.tr("关闭")) { Task { await model.closeDocument() } }.keyboardShortcut("w")
            Button(L10n.tr("撤销")) { workspace.performUndo() }.keyboardShortcut("z")
            Button(L10n.tr("重做")) { workspace.performUndo(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
            if workspace.multipleDocumentsAllowed(window: window) {
                Button(L10n.tr("下一个标签")) { Task { await workspace.selectRelative(1, window: window) } }.keyboardShortcut(.tab, modifiers: [.control])
                Button(L10n.tr("上一个标签")) { Task { await workspace.selectRelative(-1, window: window) } }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button(L10n.tr("标签左移")) { if let pane = workspace.window(window)?.focusedPane, let id = model.book?.id { workspace.shiftTab(id, direction: -1, window: window, pane: pane) } }.keyboardShortcut(.pageUp, modifiers: [.control, .shift])
                Button(L10n.tr("标签右移")) { if let pane = workspace.window(window)?.focusedPane, let id = model.book?.id { workspace.shiftTab(id, direction: 1, window: window, pane: pane) } }.keyboardShortcut(.pageDown, modifiers: [.control, .shift])
                Button(L10n.tr("重新打开关闭的标签")) { Task { await workspace.reopenClosedTab(in: window) } }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button(L10n.tr("管理标签…")) { workspace.tabManagerWindow = window }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            if supportsMultipleWindows {
                Button(L10n.tr("新建窗口")) { openWindow(id: "workspace", value: workspace.newWindow(document: nil)) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }.opacity(0)
    }
    #endif

    private func newTab(window: UUID, pane: UUID) {
        Task { await workspace.create(in: window, pane: pane) }
    }

    private func tabDrop(_ providers: [NSItemProvider], window: UUID, pane: UUID, before target: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(WorkspaceTabTransfer.type.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: WorkspaceTabTransfer.type.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(WorkspaceTabTransfer.self, from: data) else { return }
            Task { @MainActor in
                await workspace.moveTab(item.document, from: item.window, pane: item.pane, to: window, pane: pane, before: target)
            }
        }
        return true
    }

    private func emptyTabArea(pane: WorkspacePane, window: UUID) -> some View {
        Color.clear.frame(minWidth: 44, maxWidth: .infinity, minHeight: 30)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { newTab(window: window, pane: pane.id) }
            .accessibilityIdentifier("emptyTabArea-" + pane.id.uuidString)
            .accessibilityLabel(L10n.tr("双击空白处新建文稿"))
            .accessibilityAction(named: Text(L10n.tr("新建文稿"))) { newTab(window: window, pane: pane.id) }
            .help(L10n.tr("双击空白处新建文稿"))
            .contextMenu {
                Button(L10n.tr("新建文稿")) { newTab(window: window, pane: pane.id) }
                Button(L10n.tr("重新打开关闭的标签")) { Task { await workspace.reopenClosedTab(in: window, pane: pane.id) } }.disabled(workspace.recentlyClosedTabs.isEmpty)
                Button(L10n.tr("管理标签…")) { workspace.tabManagerWindow = window }
            }
            .onDrop(of: [WorkspaceTabTransfer.type], isTargeted: nil) { tabDrop($0, window: window, pane: pane.id, before: nil) }
    }

    private func operationBinding(_ kind: DocumentWorkspace.FileOperation.Kind) -> Binding<Bool> {
        Binding(get: { workspace.fileOperation?.window == windowID && workspace.fileOperation?.kind == kind }, set: { _ in })
    }

    private var multipleDocumentUI: Bool {
        #if os(macOS)
        true
        #else
        supportsMultipleWindows || duoCapable
        #endif
    }

    @ViewBuilder private func platformContents(_ layout: WorkspaceWindow) -> some View {
        #if os(macOS)
        windowContents(layout, showHorizontalTabs: true)
        #else
        Group {
            if #available(iOS 27.1, *) {
                DuoWorkspaceChrome(detected: $duoCapable, model: workspace.model(layout.id), speech: workspace.library.speech,
                                   showRail: !workspace.focusModeWindows.contains(layout.id), allowsTabletop: layout.panes.count == 1) { verticalRail, tabletopPlayback in
                    windowContents(layout, showHorizontalTabs: (supportsMultipleWindows || duoCapable) && !verticalRail)
                        .environment(\.workspaceTabletopPlayback, tabletopPlayback)
                } rail: {
                    verticalTabRail(layout)
                } controls: {
                    let model = workspace.model(layout.id)
                    TabletopSpeechControls(model: model, speech: model.speech)
                } requestKeyboard: {
                    guard let document = workspace.model(layout.id).book?.id else { return }
                    let state = workspace.editorState(document: document, pane: layout.focusedPane)
                    if let editor = state.host?.editor, !editor.isFirstResponder { _ = editor.becomeFirstResponder() }
                }
            } else {
                windowContents(layout, showHorizontalTabs: supportsMultipleWindows)
            }
        }
        .onAppear { workspace.setMultipleDocumentsAllowed(supportsMultipleWindows || duoCapable, window: layout.id) }
        .onChange(of: duoCapable) { _, capable in workspace.setMultipleDocumentsAllowed(supportsMultipleWindows || capable, window: layout.id) }
        .onChange(of: supportsMultipleWindows) { _, supported in workspace.setMultipleDocumentsAllowed(supported || duoCapable, window: layout.id) }
        #endif
    }

    private func windowContents(_ layout: WorkspaceWindow, showHorizontalTabs: Bool) -> some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900
            let focused = workspace.focusModeWindows.contains(layout.id)
            let visible = !focused && (layout.sidebarVisible ?? (wide || workspace.model(layout.id).book == nil))
            VStack(spacing: 0) {
                WorkspaceToolbar(workspace: workspace, model: workspace.model(layout.id), window: layout.id, wide: wide, sidebarVisible: visible)
                windowBody(layout, wide: wide, visible: visible, splitVisible: geometry.size.width >= 700 && multipleDocumentUI, showHorizontalTabs: showHorizontalTabs)
                .overlay(alignment: .leading) {
                    if !wide && visible {
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture { workspace.setWindowSidebarVisible(false, window: layout.id) }
                            windowSidebar(layout).frame(width: min(300, geometry.size.width - 40))
                                .background(workspace.model(layout.id).readingTheme.sidebar)
                                .shadow(color: .black.opacity(0.12), radius: 12, x: 5)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear { workspaceWidth = geometry.size.width; workspaceHeight = geometry.size.height }
            .onChange(of: geometry.size.width) { _, width in workspaceWidth = width }
            .onChange(of: geometry.size.height) { _, height in workspaceHeight = height }
            .environment(\.workspaceHeight, geometry.size.height)
            .environment(\.workspaceWidth, geometry.size.width)
            .background(workspace.model(layout.id).readingTheme.background)
            .tint(workspace.model(layout.id).readingTheme.highlight)
            .environment(\.paperTheme, workspace.model(layout.id).readingTheme)
            .preferredColorScheme(workspace.model(layout.id).readingTheme == .dark ? .dark : .light)
            #if os(macOS)
            .ignoresSafeArea(edges: .top)
            #endif
        }
    }

    @ViewBuilder private func windowBody(_ layout: WorkspaceWindow, wide: Bool, visible: Bool, splitVisible: Bool, showHorizontalTabs: Bool) -> some View {
        #if os(macOS)
        HSplitView {
            if wide && visible { windowSidebar(layout).frame(minWidth: 180, idealWidth: 220, maxWidth: 320) }
            paneLayout(layout, wide: splitVisible, showHorizontalTabs: showHorizontalTabs)
        }
        #else
        HStack(spacing: 0) {
            if wide && visible { windowSidebar(layout).frame(width: 240); Divider() }
            paneLayout(layout, wide: splitVisible, showHorizontalTabs: showHorizontalTabs)
        }
        #endif
    }

    private func windowSidebar(_ layout: WorkspaceWindow) -> some View {
        ContentView().environmentObject(workspace.model(layout.id))
            .environment(\.workspaceSidebarOnly, true)
            .environment(\.workspacePaneID, layout.focusedPane)
            .accessibilityIdentifier("workspaceNavigation")
    }

    @ViewBuilder private func paneLayout(_ layout: WorkspaceWindow, wide: Bool, showHorizontalTabs: Bool) -> some View {
        #if os(macOS)
        HSplitView { ForEach(layout.panes) { pane in paneContents(pane, window: layout.id, showHorizontalTabs: showHorizontalTabs) } }
        #else
        HStack(spacing: 0) {
            ForEach(layout.panes.filter { wide || $0.id == layout.focusedPane }) { pane in
                if wide && pane.id != layout.panes.first?.id { Divider() }
                paneContents(pane, window: layout.id, showHorizontalTabs: showHorizontalTabs).frame(maxWidth: .infinity)
            }
        }
        #endif
    }

    private func paneContents(_ pane: WorkspacePane, window: UUID, showHorizontalTabs: Bool) -> some View {
        VStack(spacing: 0) {
            if showHorizontalTabs && !workspace.focusModeWindows.contains(window) {
            HStack(spacing: 4) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 2) {
                                ForEach(pane.tabs.filter { workspaceWidth >= 600 || $0.id == pane.selected }) { tab in
                                    tabView(tab, pane: pane, window: window).id(tab.id)
                                }
                                emptyTabArea(pane: pane, window: window)
                            }.frame(minWidth: geometry.size.width, alignment: .leading)
                        }.scrollIndicators(.hidden)
                            .onAppear { if let selected = pane.selected { proxy.scrollTo(selected) } }
                            .onChange(of: pane.selected) { _, selected in if let selected { proxy.scrollTo(selected) } }
                            .onChange(of: pane.tabs.map(\.id)) { _, _ in if let selected = pane.selected { proxy.scrollTo(selected) } }
                    }
                }
                Button { newTab(window: window, pane: pane.id) } label: { Image(systemName: "plus") }
                    .buttonStyle(WorkspaceControlStyle())
                    .accessibilityLabel(L10n.tr("新建标签")).accessibilityIdentifier("newWorkspaceTab")
                Menu {
                    ForEach(pane.tabs) { tab in
                        Button(workspace.sessions[tab.id]?.book?.fileName ?? tab.id.uuidString) { Task { await workspace.focus(window: window, pane: pane.id, document: tab.id) } }
                    }
                    Divider()
                    Button(L10n.tr("管理标签…")) { workspace.tabManagerWindow = window }.accessibilityIdentifier("manageWorkspaceTabs")
                    Button(L10n.tr("重新打开关闭的标签")) { Task { await workspace.reopenClosedTab(in: window, pane: pane.id) } }.disabled(workspace.recentlyClosedTabs.isEmpty)
                    #if os(iOS)
                    Button(L10n.tr("新建文稿")) { newTab(window: window, pane: pane.id) }
                    Button(L10n.tr("保存全部")) { Task { await workspace.saveAll(window: window) } }
                    Button(L10n.tr("关闭全部标签")) { Task { await workspace.closeAll(in: window) } }
                    if supportsMultipleWindows {
                        Button(L10n.tr("新建窗口")) { openWindow(id: "workspace", value: workspace.newWindow(document: nil)) }
                        Button(L10n.tr("关闭窗口")) { Task { if await workspace.closeWindow(window) { workspace.dismissSystemWindow(window) } } }
                    }
                    if workspaceWidth >= 700, let selected = pane.selected {
                        Button(L10n.tr("克隆到另一视图")) { Task { await workspace.split(selected, window: window, pane: pane.id, clone: true) } }
                    }
                    if let layout = workspace.window(window), layout.panes.count > 1 {
                        Button(L10n.tr("关闭此视图")) { Task { await workspace.closePane(pane.id, window: window) } }
                    }
                    #endif
                } label: { HStack(spacing: 3) { Text(String(pane.tabs.count)); Image(systemName: "chevron.down") } }.menuStyle(.button).accessibilityLabel(L10n.tr("打开的标签")).menuIndicator(.hidden).accessibilityIdentifier("openWorkspaceTabs").accessibilityValue(String(pane.tabs.count))
            }
            .buttonStyle(.borderless).padding(.horizontal, 8)
            .modifier(WorkspaceTopTabInsets()).frame(height: tabBarHeight)
            // 标签行进入顶部安全区后，背景不能自动向上延伸并盖住前一行操作按钮。
            .background(workspace.model(window).readingTheme.sidebar, ignoresSafeAreaEdges: [])
            .accessibilityElement(children: .contain).accessibilityIdentifier("workspaceTabBar")
            Divider()
            }
            ZStack {
                if pane.tabs.isEmpty { ContentView().environmentObject(workspace.library).environment(\.workspacePaneID, pane.id) }
                ForEach(pane.tabs) { tab in
                    if let model = workspace.sessions[tab.id] {
                        ContentView().environmentObject(model)
                            .environment(\.workspacePaneID, pane.id)
                            .environment(\.workspaceSidebarVisible, pane.sidebarVisible ?? false)
                            .environment(\.workspaceSplit, workspace.window(window)?.panes.count == 2)
                            .environment(\.workspaceDocumentActive, pane.selected == tab.id)
                            .environment(\.workspaceEditorState, workspace.editorState(document: tab.id, pane: pane.id))
                            .opacity(pane.selected == tab.id ? 1 : 0)
                            .allowsHitTesting(pane.selected == tab.id)
                            .accessibilityHidden(pane.selected != tab.id)
                            .zIndex(pane.selected == tab.id ? 1 : 0)
                    } else if pane.selected == tab.id {
                        ContentUnavailableView(L10n.tr("文件暂不可用"), systemImage: "doc.badge.ellipsis")
                    }
                }
            }
            .onDrop(of: [WorkspaceTabTransfer.type], isTargeted: nil) { tabDrop($0, window: window, pane: pane.id, before: nil) }

        }
        #if os(macOS)
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .disabled(workspace.closing || workspace.maintenance)
            .overlay(alignment: .bottomLeading) {
                #if DEBUG
                WorkspaceDiagnostics(workspace: workspace, window: window, pane: pane)
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    Text(pane.tabs.compactMap { workspace.sessions[$0.id]?.book?.fileName }.joined(separator: "|"))
                        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier("workspaceTabNames")
                        .accessibilityValue(pane.tabs.compactMap { workspace.sessions[$0.id]?.book?.fileName }.joined(separator: "|"))
                    Text(String(workspace.recentlyClosedTabs.count))
                        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier("recentlyClosedTabCount").accessibilityValue(String(workspace.recentlyClosedTabs.count))
                }
                #endif
            }
    }

    private func tabView(_ tab: WorkspaceTab, pane: WorkspacePane, window: UUID) -> some View {
        let model = workspace.sessions[tab.id]
        return HStack(spacing: 7) {
            if workspace.speechDocument == tab.id, workspace.library.speech.playing, !workspace.library.speech.paused, !workspace.library.speech.auditioning {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                    .accessibilityLabel(L10n.tr("正在朗读"))
                    .accessibilityIdentifier("playingTab-" + tab.id.uuidString)
            }
            if tab.pinned { Image(systemName: "pin.fill").font(.caption2) }
            if model?.documentReadOnly == true { Image(systemName: "lock.fill").font(.caption2) }
            if model?.dirty == true { Circle().fill(.orange).frame(width: 6, height: 6).accessibilityLabel(L10n.tr("未保存")) }
            Button { Task { await workspace.focus(window: window, pane: pane.id, document: tab.id) } } label: {
                Text(model?.book?.fileName ?? L10n.tr("文件暂不可用")).lineLimit(1).frame(minWidth: 64, maxWidth: 180)
            }.accessibilityIdentifier("documentTab-" + tab.id.uuidString)
                #if os(iOS)
                .contextMenu { tabMenu(tab, pane: pane, window: window) }
                #endif
            Button { Task { _ = await workspace.close([tab.id], window: window, pane: pane.id) } } label: { Image(systemName: "xmark").font(.caption2).padding(4) }
                .accessibilityLabel(L10n.tr("关闭标签"))
                .accessibilityIdentifier("closeTab-" + tab.id.uuidString)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(pane.selected == tab.id ? workspace.model(window).readingTheme.highlight.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .bottom) { if let color = tab.color { tabColor(color).frame(height: 3) } }
        .help(model?.sourcePath ?? model?.book?.fileName ?? "")
        #if os(macOS)
        .overlay {
            MacTabContextMenu(commands: { workspace.tabCommands(tab, pane: pane, window: window, allowsSplit: workspaceWidth >= 700, supportsMultipleWindows: supportsMultipleWindows) { openWindow(id: "workspace", value: $0) } },
                middleClick: { Task { _ = await workspace.close([tab.id], window: window, pane: pane.id) } })
                .accessibilityHidden(true)
        }
        #else
        .contextMenu { tabMenu(tab, pane: pane, window: window) }
        #endif
        .onDrag {
            let provider = NSItemProvider()
            let item = WorkspaceTabTransfer(document: tab.id, window: window, pane: pane.id)
            provider.registerDataRepresentation(forTypeIdentifier: WorkspaceTabTransfer.type.identifier, visibility: .ownProcess) { completion in
                completion(try? JSONEncoder().encode(item), nil); return nil
            }
            return provider
        }
        .onDrop(of: [WorkspaceTabTransfer.type], isTargeted: nil) { tabDrop($0, window: window, pane: pane.id, before: tab.id) }

    }

    #if os(iOS)
    @ViewBuilder private func verticalTabRail(_ layout: WorkspaceWindow) -> some View {
        if let pane = layout.panes.first(where: { $0.id == layout.focusedPane }) ?? layout.panes.first {
            VStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(pane.tabs) { tab in
                                verticalTab(tab, pane: pane, window: layout.id).id(tab.id)
                            }
                        }.padding(.horizontal, 3)
                    }.scrollIndicators(.hidden)
                        .onAppear { if let selected = pane.selected { proxy.scrollTo(selected) } }
                        .onChange(of: pane.selected) { _, selected in if let selected { proxy.scrollTo(selected) } }
                        .onChange(of: pane.tabs.map(\.id)) { _, _ in if let selected = pane.selected { proxy.scrollTo(selected) } }
                }
                Button { newTab(window: layout.id, pane: pane.id) } label: {
                    Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel(L10n.tr("新建文稿")).accessibilityIdentifier("newWorkspaceTab")
                Menu {
                    Button(L10n.tr("管理标签…")) { workspace.tabManagerWindow = layout.id }.accessibilityIdentifier("manageWorkspaceTabs")
                    Button(L10n.tr("重新打开关闭的标签")) { Task { await workspace.reopenClosedTab(in: layout.id, pane: pane.id) } }.disabled(workspace.recentlyClosedTabs.isEmpty)
                    Button(L10n.tr("保存全部")) { Task { await workspace.saveAll(window: layout.id) } }
                    if let selected = pane.selected {
                        Button(L10n.tr("关闭标签")) { Task { _ = await workspace.close([selected], window: layout.id, pane: pane.id) } }
                    }
                } label: { Image(systemName: "ellipsis").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel(L10n.tr("打开的标签")).accessibilityIdentifier("openWorkspaceTabs").accessibilityValue(String(pane.tabs.count))
            }
            .buttonStyle(.plain).padding(.vertical, 4)
            .background(workspace.model(layout.id).readingTheme.sidebar)
            .foregroundStyle(workspace.model(layout.id).readingTheme.foreground)
            .accessibilityElement(children: .contain).accessibilityIdentifier("workspaceVerticalTabBar")
            .disabled(workspace.closing || workspace.maintenance)
        }
    }

    private func verticalTab(_ tab: WorkspaceTab, pane: WorkspacePane, window: UUID) -> some View {
        let model = workspace.sessions[tab.id]
        return Button { Task { await workspace.focus(window: window, pane: pane.id, document: tab.id) } } label: {
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    if model?.dirty == true { Circle().fill(.orange).frame(width: 5, height: 5).accessibilityLabel(L10n.tr("未保存")) }
                    Image(systemName: tab.pinned ? "pin.fill" : model?.documentReadOnly == true ? "lock.fill" : "doc.text").font(.caption)
                    if workspace.speechDocument == tab.id, workspace.library.speech.playing {
                        Image(systemName: workspace.library.speech.paused ? "pause.fill" : "speaker.wave.2.fill").font(.system(size: 9))
                    }
                }
                Text(model?.book?.fileName ?? L10n.tr("文件暂不可用"))
                    .font(.system(size: 11, weight: pane.selected == tab.id ? .semibold : .regular))
                    .lineLimit(3).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }.padding(.horizontal, 2).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 60)
                .background(pane.selected == tab.id ? (model?.readingTheme ?? .white).highlight.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .bottom) { if let color = tab.color { tabColor(color).frame(height: 2) } }
                .contentShape(Rectangle())
        }.accessibilityIdentifier("documentTab-" + tab.id.uuidString)
            .accessibilityValue(model?.dirty == true ? L10n.tr("未保存") : "")
            .contextMenu { tabMenu(tab, pane: pane, window: window) }
            .onDrop(of: [WorkspaceTabTransfer.type], isTargeted: nil) { tabDrop($0, window: window, pane: pane.id, before: tab.id) }
    }
    #endif

    private var tabBarHeight: CGFloat {
        #if os(macOS)
        38
        #else
        44
        #endif
    }

    private func tabMenu(_ tab: WorkspaceTab, pane: WorkspacePane, window: UUID) -> some View {
        WorkspaceCommandMenu(commands: workspace.tabCommands(tab, pane: pane, window: window, allowsSplit: workspaceWidth >= 700, supportsMultipleWindows: supportsMultipleWindows) { openWindow(id: "workspace", value: $0) })
    }
    private func tabColor(_ index: Int) -> Color { [Color.red, .orange, .green, .blue, .purple][min(4, max(0, index))] }
}

#if os(iOS)
/// 按真实铰链、系统分屏和安全区布局；完全展开的竖屏使用顶部文件标签，不沿用侧边标签轨。
@available(iOS 27.1, *)
private struct DuoWorkspaceChrome<Content: View, Rail: View, Controls: View>: View {
    @Environment(\.toolbarVerticalEdge) private var toolbarEdge
    @Environment(\.layoutDirection) private var layoutDirection
    @Binding var detected: Bool
    @ObservedObject var model: AppModel
    let speech: SpeechEngine
    let showRail: Bool
    let allowsTabletop: Bool
    @ViewBuilder let content: (Bool, Bool) -> Content
    @ViewBuilder let rail: () -> Rail
    @ViewBuilder let controls: () -> Controls
    let requestKeyboard: () -> Void
    @State private var hinge = WorkspaceHingeSnapshot()

    var body: some View {
        GeometryReader { safeGeometry in
            let divisions = safeGeometry.reservedRegions(kind: .division, options: .includeInactive, layoutDirectionBehavior: .fixed)
            let capable = toolbarEdge != nil || !divisions.isEmpty || !hinge.divisions.isEmpty || hinge.status != UIHinge.Status.unknown.rawValue
            let width = toolbarEdge == .leading ? safeGeometry.safeAreaInsets.leading : safeGeometry.safeAreaInsets.trailing
            let expandedPortrait = hinge.status == UIHinge.Status.fullyOpen.rawValue && hinge.fullScreen &&
                hinge.windowBounds.height > hinge.windowBounds.width
            // 真正的左右系统分屏按窗口所在侧镜像标签轨，不能只依赖系统为右窗提供的状态栏保留区。
            let sideBySide = capable && !hinge.fullScreen && hinge.windowFrame.width > 0 &&
                hinge.windowFrame.width < hinge.screenFrame.width - 1 &&
                abs(hinge.windowFrame.height - hinge.screenFrame.height) < 1
            let physicalLeft = hinge.windowFrame.midX < hinge.screenFrame.midX
            let boundary = hinge.divisions.first { region in
                region.frame.height > region.frame.width && region.frame.height >= hinge.windowBounds.height - 1 &&
                    (region.frame.minX <= 1 || region.frame.maxX >= hinge.windowBounds.width - 1)
            }
            // 分屏窗口内的铰链边界提供稳定的左右信息，不依赖场景到屏幕的全局原点。
            let boundaryOuterIsLeft = boundary.map { $0.frame.midX > hinge.windowBounds.midX }
            let boundaryEdge: HorizontalEdge = ((boundaryOuterIsLeft ?? physicalLeft) == (layoutDirection == .leftToRight)) ? .leading : .trailing
            // UIKit 在部分等宽跨侧切换中仍返回场景本地原点；系统实际保留的侧边条优先决定标签方向。
            // 没有系统侧边条的左窗才使用窗口方向补一条内部标签轨，避免右窗重复预留或放到内侧。
            let splitEdge = width > 0 ? (toolbarEdge ?? boundaryEdge) : boundaryEdge
            let edge = sideBySide ? splitEdge : toolbarEdge
            let nativeRail = edge == toolbarEdge && width > 0
            let railWidth: CGFloat = sideBySide ? 84 : width
            let visible = showRail && edge != nil && railWidth > 0 && !expandedPortrait
            let internalRail = visible && !nativeRail
            let contentWidth = max(0, safeGeometry.size.width - (internalRail ? railWidth : 0))
            // Duo 分屏切换可能留下 SwiftUI 的旧键盘安全区。统一从当前关键窗口的原生键盘布局导轨计算。
            let keyboardTop = model.editing && hinge.keyWindow && hinge.keyboardVisible ? hinge.keyboardFrame.minY + hinge.viewFrame.minY - safeGeometry.frame(in: .global).minY : safeGeometry.size.height
            let contentHeight = min(safeGeometry.size.height, max(0, keyboardTop))
            let division = tabletopDivision()
            let editing = division != nil && model.editing
            let playback = division != nil && !model.editing && model.ownsSpeech && (speech.playing || speech.scrubbing) && !speech.auditioning
            let upperHeight = (editing || playback) ? min(contentHeight, max(0, division?.minY ?? contentHeight)) : contentHeight
            content(visible, playback)
                .environment(\.workspaceExpandedPortrait, expandedPortrait)
                .environment(\.workspaceTopChromeLayout, expandedPortrait ? topChromeLayout(width: safeGeometry.size.width) : WorkspaceTopChromeLayout())
                // 外层忽略键盘安全区以读取完整窗口，正文必须服从原生键盘计算出的可用高度。
                // 此处再忽略键盘会把内部布局撑回窗口全高，导致状态栏和换行按钮落在键盘后方。
                .frame(width: contentWidth, height: upperHeight, alignment: .top)
                .offset(x: internalRail && ((edge == .leading) == (layoutDirection == .leftToRight)) ? railWidth : 0)
                .frame(width: safeGeometry.size.width, height: safeGeometry.size.height, alignment: .topLeading)
                .background(model.readingTheme.background.ignoresSafeArea(.container))
                .overlay(alignment: .topLeading) {
                    if playback, let division {
                        let height = max(0, safeGeometry.size.height - division.maxY)
                        if height > 0 {
                            controls().frame(width: safeGeometry.size.width, height: height)
                                .offset(y: division.maxY)
                        }
                    }
                }
                .overlay {
                    if visible, let edge {
                        GeometryReader { geometry in
                            let rect = availableRailRect(in: geometry, width: railWidth, edge: edge)
                            if rect.height > 0 {
                                rail().frame(width: rect.width, height: rect.height).clipped()
                                    .position(x: rect.midX, y: rect.midY)
                                    .overlay(alignment: .bottomLeading) {
                                        #if DEBUG
                                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                                            Text(verbatim: "rail=\(rect.minX),\(rect.minY),\(rect.width),\(rect.height);strip=\(width);insets=\(safeGeometry.safeAreaInsets.leading),\(safeGeometry.safeAreaInsets.trailing)")
                                                .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                                                .accessibilityIdentifier("workspaceVerticalTabGeometry")
                                        }
                                        #endif
                                    }
                            }
                        }.ignoresSafeArea(.container, edges: nativeRail ? (edge == .leading ? .leading : .trailing) : [])
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                        VStack(spacing: 0) {
                            Text(verbatim: "division=\(divisions.count);vertical=\(toolbarEdge != nil);detected=\(detected)")
                                .accessibilityIdentifier("workspaceDeviceCapabilities")
                            Text(verbatim: "status=\(hinge.status);angle=\(hinge.angle);full=\(hinge.fullScreen);view=\(hinge.viewFrame);window=\(hinge.windowFrame);scene=\(hinge.sceneFrame);screen=\(hinge.screenFrame);keyboard=\(hinge.keyboardFrame);key=\(hinge.keyWindow);occlusions=\(hinge.occlusions);keyboardVisible=\(hinge.keyboardVisible);divisions=\(hinge.divisions);safe=\(safeGeometry.size);insets=\(safeGeometry.safeAreaInsets);tabletop=\(division != nil);editing=\(editing);playback=\(playback);documentEditing=\(model.editing);contentHeight=\(contentHeight);upperHeight=\(upperHeight)")
                                .accessibilityIdentifier("workspaceHingeGeometry")
                        }.font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    }
                    #endif
                }
                .onAppear { if capable { detected = true } }
                .onChange(of: capable) { _, value in if value { detected = true } }
                .onChange(of: editing) { _, value in
                    if value { DispatchQueue.main.async { requestKeyboard() } }
                }
                // 桥接视图跟随 GeometryReader 的安全区更新，保证跨侧移动时重新采集本地保留区。
                // 部分系统场景的屏幕转换原点仍为本地零点，标签方向另由侧边保留区和铰链边界决定。
                .background(WorkspaceHingeBridge { snapshot in if hinge != snapshot { hinge = snapshot } })
        }
        .ignoresSafeArea(detected ? .keyboard : [], edges: .bottom)
        .ignoresSafeArea(.container, edges: hinge.fullScreen && hinge.status == UIHinge.Status.fullyOpen.rawValue && hinge.windowBounds.height > hinge.windowBounds.width ? .top : [])
    }

    /// 在每一行内找连续可用空间，避开时钟、信号和系统多任务入口的真实遮挡矩形。
    /// 只改变顶部控件的横向范围，文稿正文继续使用完整窗口宽度。
    private func topChromeLayout(width: CGFloat) -> WorkspaceTopChromeLayout {
        func insets(y: CGFloat, height: CGFloat) -> (CGFloat, CGFloat) {
            let band = CGRect(x: 0, y: y, width: width, height: height)
            let blocked = hinge.occlusions.map { $0.intersection(band) }.filter { !$0.isNull && !$0.isEmpty }.sorted { $0.minX < $1.minX }
            var start: CGFloat = 0
            var spans: [CGRect] = []
            for rect in blocked {
                if rect.minX > start { spans.append(CGRect(x: start, y: y, width: rect.minX - start, height: height)) }
                start = max(start, rect.maxX)
            }
            if start < width { spans.append(CGRect(x: start, y: y, width: width - start, height: height)) }
            guard let span = spans.max(by: { $0.width < $1.width }) else { return (0, 0) }
            let left = span.minX, right = max(0, width - span.maxX)
            return layoutDirection == .leftToRight ? (left, right) : (right, left)
        }
        let toolbar = insets(y: 0, height: 52)
        let tabs = insets(y: 52, height: 44)
        return WorkspaceTopChromeLayout(docked: true, toolbarLeading: toolbar.0, toolbarTrailing: toolbar.1, tabsLeading: tabs.0, tabsTrailing: tabs.1)
    }

    private func tabletopDivision() -> CGRect? {
        guard allowsTabletop, hinge.status == UIHinge.Status.partiallyOpen.rawValue, hinge.fullScreen else { return nil }
        // 使用窗口坐标中的铰链保留区，不能依赖被系统键盘压缩后的 SwiftUI 可见范围。
        // 仅全屏、半开、横向铰链生效；系统分屏不进入桌面听书或上下分区编辑。
        // 否则键盘出现会让铰链暂时不可见，造成反复切换布局和重复请求键盘。
        return hinge.divisions.first(where: { region in
            let frame = region.frame
            return region.active && frame.width > frame.height && frame.minX <= 0 && frame.maxX >= hinge.viewFrame.width &&
                frame.minY + hinge.viewFrame.minY > hinge.windowBounds.minY && frame.maxY + hinge.viewFrame.minY < hinge.windowBounds.maxY
        })?.frame
    }

    private func availableRailRect(in geometry: GeometryProxy, width: CGFloat, edge: HorizontalEdge) -> CGRect {
        let isLeft = (edge == .leading) == (layoutDirection == .leftToRight)
        let strip = CGRect(x: isLeft ? 0 : geometry.size.width - width, y: 0, width: width, height: geometry.size.height)
        let blocked = geometry.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed).filter(\.isActive).compactMap { region -> CGRect? in
            let clipped = strip.intersection(region.frame)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
        let start = max(strip.minY, blocked.map(\.maxY).max() ?? strip.minY)
        return CGRect(x: strip.minX, y: start, width: strip.width, height: max(0, strip.maxY - start))
    }
}

@available(iOS 27.1, *)
private struct WorkspaceHingeSnapshot: Equatable {
    /// frame 转换到桥接视图坐标；active 区分当前有效铰链与系统保留的非活动区域。
    struct Division: Equatable {
        var frame: CGRect
        var active: Bool
    }
    var status = UIHinge.Status.unknown.rawValue
    var angle: CGFloat = 0
    var fullScreen = false
    var viewFrame = CGRect.zero
    var windowBounds = CGRect.zero
    var windowFrame = CGRect.zero
    var sceneFrame = CGRect.zero
    var screenFrame = CGRect.zero
    var divisions: [Division] = []
    var occlusions: [CGRect] = []
    var keyboardFrame = CGRect.zero
    var keyboardVisible = false
    var keyWindow = false
}

@available(iOS 27.1, *)
private struct WorkspaceHingeBridge: UIViewRepresentable {
    /// 统一收集系统铰链与窗口几何，按完整快照去重；异步通知避免布局期间发布状态。
    let changed: (WorkspaceHingeSnapshot) -> Void
    func makeUIView(context: Context) -> HingeView {
        let view = HingeView(); view.changed = changed
        return view
    }
    func updateUIView(_ view: HingeView, context: Context) {
        view.changed = changed
        view.refreshGeometry()
    }
    final class HingeView: UIView {
        var changed: ((WorkspaceHingeSnapshot) -> Void)?
        private var status = UIHinge.Status.unknown.rawValue
        private var angle: CGFloat = 0
        private var last: WorkspaceHingeSnapshot?
        private var pending: WorkspaceHingeSnapshot?
        private var scheduled = false
        private var keyboardScreenFrame: CGRect?
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                         UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardGeometryChanged(_:)), name: name, object: nil)
            }
            addInteraction(UIHingeInteraction { [weak self] _, update in
                self?.status = update.hinge?.status.rawValue ?? UIHinge.Status.unknown.rawValue
                self?.angle = update.hinge?.angle ?? 0
                self?.refreshGeometry()
            })
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { NotificationCenter.default.removeObserver(self) }
        /// 原生导轨首次布局可能仍为零；缓存系统键盘通知的最终屏幕坐标作为回退，不沿用 SwiftUI 旧安全区。
        @objc private func keyboardGeometryChanged(_ notification: Notification) {
            if notification.name == UIResponder.keyboardWillHideNotification || notification.name == UIResponder.keyboardDidHideNotification {
                keyboardScreenFrame = .zero
            } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardScreenFrame = frame
            }
            refreshGeometry()
        }
        override func didMoveToWindow() { super.didMoveToWindow(); refreshGeometry() }
        override func layoutSubviews() { super.layoutSubviews(); refreshGeometry() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); refreshGeometry() }
        func refreshGeometry() {
            guard let window, let scene = window.windowScene else { return }
            let screen = scene.screen.coordinateSpace
            let windowFrame = window.convert(window.bounds, to: screen)
            let sceneSpace = scene.effectiveGeometry.coordinateSpace
            let sceneFrame = sceneSpace.convert(sceneSpace.bounds, to: screen)
            let screenFrame = screen.bounds
            let tolerance = 1 / max(1, traitCollection.displayScale)
            func coversScreen(_ frame: CGRect) -> Bool {
                abs(frame.minX - screenFrame.minX) <= tolerance && abs(frame.minY - screenFrame.minY) <= tolerance &&
                abs(frame.width - screenFrame.width) <= tolerance && abs(frame.height - screenFrame.height) <= tolerance
            }
            let divisions = window.reservedRegions(kind: .division, options: .includeInactive).map {
                WorkspaceHingeSnapshot.Division(frame: convert($0.frame, from: window), active: $0.isActive)
            }
            let guide = window.keyboardLayoutGuide.layoutFrame
            let keyboardInWindow = keyboardScreenFrame.map { window.convert($0, from: screen) } ?? guide
            let keyboardIntersection = keyboardInWindow.intersection(window.bounds)
            let keyboardVisible = !keyboardIntersection.isNull && keyboardIntersection.height > window.safeAreaInsets.bottom + 1
            let snapshot = WorkspaceHingeSnapshot(status: status, angle: angle, fullScreen: coversScreen(windowFrame) && coversScreen(sceneFrame),
                viewFrame: convert(bounds, to: window), windowBounds: window.bounds, windowFrame: windowFrame, sceneFrame: sceneFrame, screenFrame: screenFrame, divisions: divisions,
                occlusions: window.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame),
                keyboardFrame: convert(keyboardInWindow, from: window),
                keyboardVisible: keyboardVisible,
                keyWindow: window.isKeyWindow)
            guard snapshot != last else { return }
            last = snapshot; pending = snapshot
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let pending = self.pending else { return }
                self.scheduled = false; self.pending = nil; self.changed?(pending)
            }
        }
    }
}
#endif

#if os(macOS)
private struct WorkspaceWindowBridge: NSViewRepresentable {
    let workspace: DocumentWorkspace
    let id: UUID
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, id: id) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            guard let window = view.window, let coordinator else { return }
            coordinator.window = window; window.delegate = coordinator
            window.title = workspace.model(id).book?.fileName ?? L10n.tr("墨语引擎")
            window.isDocumentEdited = workspace.window(id)?.panes.flatMap({ $0.tabs }).contains(where: { workspace.sessions[$0.id]?.dirty == true }) ?? false
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var workspace: DocumentWorkspace?
        weak var window: NSWindow?
        let id: UUID
        var approved = false
        init(workspace: DocumentWorkspace, id: UUID) { self.workspace = workspace; self.id = id }
        func windowDidBecomeKey(_ notification: Notification) { Task { await workspace?.focus(window: id) } }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if approved { return true }
            if let event = NSApp.currentEvent, event.type == .keyDown,
               event.charactersIgnoringModifiers?.lowercased() == "w", !event.modifierFlags.contains(.shift) {
                Task { await workspace?.model(id).closeDocument() }
                return false
            }
            Task { @MainActor in
                if await workspace?.closeWindow(id) == true { approved = true; sender.close() }
            }
            return false
        }
    }
}
#endif

#if os(iOS)
/// 自定义工具栏需主动避开 iPad 窗口按钮；几何回报延后到布局结束，避免更新视图时发布状态。
private struct WorkspaceWindowControlsProbe: UIViewRepresentable {
    var changed: (CGFloat) -> Void
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.changed = changed; return view }
    func updateUIView(_ view: Probe, context: Context) { view.changed = changed; view.refresh() }
    final class Probe: UIView {
        var changed: ((CGFloat) -> Void)?
        private var last: CGFloat = -1
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
        override func layoutSubviews() { super.layoutSubviews(); refresh() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); refresh() }
        /// 27.1 优先读取系统遮挡区；26/27.0 按真实窗口与屏幕坐标识别窗口化场景。
        func refresh() {
            var leading: CGFloat = 0
            if #available(iOS 26.0, *), traitCollection.userInterfaceIdiom == .pad,
               let window, let scene = window.windowScene, bounds.width > 0 {
                let toolbar = convert(bounds, to: window)
                if #available(iOS 27.1, *) {
                    for region in window.reservedRegions(kind: .occlusion) where region.isActive {
                        if region.frame.intersects(toolbar), region.frame.minX < toolbar.midX {
                            leading = max(leading, region.frame.maxX - toolbar.minX)
                        }
                    }
                }
                let screen = scene.screen.coordinateSpace
                let frame = window.convert(window.bounds, to: screen)
                let fullScreen = abs(frame.width - screen.bounds.width) < 1 && abs(frame.height - screen.bounds.height) < 1
                // 旧系统未提供遮挡区。仅窗口化且工具栏仍在顶部时，给左上系统控件预留横向空间。
                if !fullScreen && toolbar.minY < 80 { leading = max(leading, 64) }
            }
            guard abs(leading - last) > 0.5 else { return }
            let inset = leading
            last = inset
            DispatchQueue.main.async { [weak self] in
                guard let self, self.last == inset else { return }
                self.changed?(inset)
            }
        }
    }
}
#endif

/// 窗口统一管理操作按钮；各面板只管理与文稿绑定的标签和正文。
private struct WorkspaceToolbar: View {
    @ObservedObject var workspace: DocumentWorkspace
    @ObservedObject var model: AppModel
    let window: UUID
    let wide: Bool
    let sidebarVisible: Bool
    @State private var appearance = false
    #if os(iOS)
    @State private var windowControlsLeading: CGFloat = 0
    #endif
    @Environment(\.locale) private var locale
    @Environment(\.workspaceTabletopPlayback) private var tabletopPlayback
    @Environment(\.workspaceTopChromeLayout) private var topChromeLayout
    private var focused: Bool { workspace.focusModeWindows.contains(window) }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            toolbarButtons(compactMode: topChromeLayout.docked)
            #if os(iOS)
            toolbarButtons(compactMode: true)
            // 极窄系统窗口把显示入口和阅读时的保存留在现有菜单中，避免避让后右侧按钮溢出。
            toolbarButtons(compactMode: true, minimalChrome: true)
            #endif
        }
        .buttonStyle(WorkspaceControlStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        .padding(.horizontal, 8)
        .padding(.leading, max(topChromeLayout.toolbarLeading, windowControlsLeading))
        #else
        .padding(.horizontal, 12)
        .padding(.leading, topChromeLayout.toolbarLeading)
        #endif
        .padding(.trailing, topChromeLayout.toolbarTrailing)
        .frame(height: 52)
        .background(model.readingTheme.sidebar)
        #if os(macOS)
        .background { WindowDragRegion() }
        #else
        .background { WorkspaceWindowControlsProbe { windowControlsLeading = $0 } }
        #endif
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain).accessibilityIdentifier("workspaceToolbar")
        .popover(isPresented: $appearance) { appearancePanel }
        .disabled(workspace.closing || workspace.maintenance)
    }

    /// 系统分屏使正文变窄时，仍保证所有操作都有可达的入口。
    private func toolbarButtons(compactMode: Bool, minimalChrome: Bool = false) -> some View {
        HStack(spacing: wide ? 10 : (compactMode ? 1 : 6)) {
            #if os(macOS)
            Color.clear.frame(width: 70, height: 1)
            #endif
            Button { workspace.setWindowSidebarVisible(!sidebarVisible, window: window) } label: { Image(systemName: "sidebar.left") }
                .accessibilityIdentifier("toggleChapterSidebar").accessibilityLabel(L10n.tr("历史记录与章节"))
            #if os(iOS)
            Button { newDocument() } label: { Image(systemName: "doc.badge.plus") }
                .accessibilityIdentifier("toolbarNewDocument").accessibilityLabel(L10n.tr("新建文稿"))
            #endif
            Button { action("open") } label: { Image(systemName: "folder") }
                .accessibilityIdentifier("toolbarOpenDocument").accessibilityLabel(L10n.tr("打开文件"))
                .help(L10n.tr("打开文件") + " (⌘O)")
            if !minimalChrome || model.editing {
                Button { action("save") } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityIdentifier("toolbarSaveDocument").accessibilityLabel(L10n.tr("保存"))
                    .help(L10n.tr("保存") + " (⌘S)").disabled(model.book == nil)
            }
            #if os(macOS)
            Button { action("saveAs") } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .accessibilityIdentifier("toolbarSaveAs").accessibilityLabel(L10n.tr("另存为…"))
                .help(L10n.tr("另存为…") + " (⇧⌘S)").disabled(model.book == nil)
            #endif
            // 展开竖屏把常用操作紧凑靠左，避开中央临时多视图入口；其他布局维持两端分组。
            if !topChromeLayout.docked { Spacer(minLength: 0) }
            if model.book != nil {
                if compactMode {
                    Button { Task { await workspace.focus(window: window); await model.switchMode() } } label: {
                        Image(systemName: model.editing ? "book" : "square.and.pencil")
                    }.disabled(model.busy)
                        .accessibilityIdentifier("modeToggle")
                        .accessibilityLabel(model.editing ? L10n.tr("阅读") : L10n.tr("编辑"))
                } else {
                    ModeTabs(editing: model.editing, busy: model.busy) { Task { await workspace.focus(window: window); await model.switchMode() } }
                }
                if wide {
                    Button { action("find") } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityIdentifier("outlineButton").accessibilityLabel(L10n.tr("搜索正文"))
                }
                // 皮肤与字号属于常用显示设置，窄屏也保留可见入口，不能只藏在更多菜单。
                if !minimalChrome { appearanceButton }
                if !model.editing && !tabletopPlayback {
                    WorkspaceSpeechButton(speech: model.speech, model: model) {
                        Task { await workspace.focus(window: window); await model.toggleSpeech() }
                    }
                }
                if wide {
                    Button { workspace.toggleFocusMode(window: window) } label: { Image(systemName: focused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                        .accessibilityIdentifier("focusMode").accessibilityLabel(focused ? L10n.tr("退出专注") : L10n.tr("专注模式"))
                }
            }
            #if os(iOS)
            mobileMenu
            #endif
        }
    }

    private var appearanceButton: some View {
        Button { appearance = true } label: { Image(systemName: "paintpalette") }
            .accessibilityLabel(L10n.tr("正文显示")).accessibilityIdentifier("appearanceMenu")
    }

    private var appearancePanel: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                Section(L10n.tr("字号")) {
                    HStack(spacing: 12) {
                        Slider(value: $model.fontSize, in: 14...36, step: 1) { Text(L10n.tr("字号")) }
                            .accessibilityIdentifier("workspaceFontSize")
                        Text("\(Int(model.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                }.listRowBackground(model.readingTheme.sidebar)
                Section(L10n.tr("界面主题")) {
                    Picker(L10n.tr("界面主题"), selection: $model.readingTheme) {
                        ForEach(ReadingTheme.allCases) { theme in
                            HStack(spacing: 12) {
                                Circle().fill(theme.background).overlay { Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1) }
                                    .frame(width: 24, height: 24).accessibilityHidden(true)
                                Text(theme.label)
                            }.tag(theme).accessibilityIdentifier("theme-" + theme.rawValue)
                        }
                    }.pickerStyle(.inline).labelsHidden()
                }.listRowBackground(model.readingTheme.sidebar)
                if model.editing {
                    Section { Toggle(L10n.tr("自动换行"), isOn: $model.lineWrappingEnabled) }
                        .listRowBackground(model.readingTheme.sidebar)
                }
            }
            .scrollContentBackground(.hidden)
            .background(model.readingTheme.background)
            .navigationTitle(L10n.tr("正文显示"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { InkPanelDoneToolbar { appearance = false } }
        }
        // 手机将 popover 转为原生半屏表单；不继承工具栏的按钮样式或固定窄宽。
        // 平板仍使用锚定工具栏的 popover，并允许较大字号时滚动内容。
        .buttonStyle(.automatic).tint(model.readingTheme.highlight)
        .preferredColorScheme(model.readingTheme == .dark ? .dark : .light)
        .frame(idealWidth: 360, idealHeight: 500)
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .appLocalized()
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("正文显示")).font(.headline)
            Slider(value: $model.fontSize, in: 14...36, step: 1) { Text(L10n.tr("字号")) }
                .accessibilityIdentifier("workspaceFontSize")
            Text("\(Int(model.fontSize)) pt").monospacedDigit()
            Picker(L10n.tr("界面主题"), selection: $model.readingTheme) {
                ForEach(ReadingTheme.allCases) { theme in Text(theme.label).tag(theme).accessibilityIdentifier("theme-" + theme.rawValue) }
            }
            if model.editing { Toggle(L10n.tr("自动换行"), isOn: $model.lineWrappingEnabled) }
            Button(L10n.tr("完成")) { appearance = false }
        }.padding(20).frame(width: 290).background(model.readingTheme.background)
            .foregroundStyle(model.readingTheme.foreground).appLocalized()
        #endif
    }

    #if os(iOS)
    private var mobileMenu: some View {
        Menu {
            Section(L10n.tr("文稿")) {
                Button(L10n.tr("新建文稿"), systemImage: "plus") { newDocument() }.accessibilityIdentifier("newBook")
                Button(L10n.tr("打开文件"), systemImage: "folder") { action("open") }.accessibilityIdentifier("importBook")
                Button(L10n.tr("添加小说目录"), systemImage: "folder.badge.plus") { action("folder") }.accessibilityIdentifier("importNovel")
                Button(L10n.tr("继续上次阅读"), systemImage: "bookmark") { Task { await workspace.focus(window: window); await model.resumeLast(); workspace.setWindowSidebarVisible(false, window: window) } }
            }
            if model.book != nil {
                Section(L10n.tr("当前文稿")) {
                    if model.editing {
                        // 触屏也提供原生撤销入口，不要求外接键盘或隐藏的系统手势。
                        Button(L10n.tr("撤销"), systemImage: "arrow.uturn.backward") {
                            Task { await workspace.focus(window: window); workspace.performUndo() }
                        }.disabled(!workspace.canUndo).accessibilityIdentifier("undoDocument")
                        Button(L10n.tr("重做"), systemImage: "arrow.uturn.forward") {
                            Task { await workspace.focus(window: window); workspace.performUndo(redo: true) }
                        }.disabled(!workspace.canRedo).accessibilityIdentifier("redoDocument")
                    }
                    Button(L10n.tr("保存"), systemImage: "square.and.arrow.down") { action("save") }.accessibilityIdentifier("saveDocument")
                    Button(L10n.tr("另存为…")) { action("saveAs") }.accessibilityIdentifier("saveAs")
                    Button(L10n.tr("分享…"), systemImage: "square.and.arrow.up") { action("share") }.accessibilityIdentifier("shareDocument")
                    Button(L10n.tr("同步数据到设备…")) { action("sync") }.accessibilityIdentifier("syncDocument")
                }
                Section(L10n.tr("显示")) {
                    if !wide {
                        Button(L10n.tr("正文显示"), systemImage: "textformat.size") { appearance = true }
                        Button(L10n.tr("搜索正文"), systemImage: "magnifyingglass") { action("find") }.accessibilityIdentifier("outlineButton")
                    }
                    Button(focused ? L10n.tr("退出专注") : L10n.tr("专注模式")) { workspace.toggleFocusMode(window: window) }
                    if model.editing {
                        Toggle(L10n.tr("自动换行"), isOn: $model.lineWrappingEnabled).accessibilityIdentifier("wrapToggle")
                        Toggle(L10n.tr("列模式"), isOn: $model.columnMode)
                    }
                    Button(L10n.tr("阅读书签"), systemImage: "bookmark") { action("bookmarks") }.disabled(model.editing)
                }
            }
            Section(L10n.tr("设置与设备")) {
                Button(L10n.tr("字号与朗读设置"), systemImage: "slider.horizontal.3") { action("settings") }.accessibilityIdentifier("speechSettings")
                LanguageMenu()
                Button(L10n.tr("缓存管理")) { action("cache") }.accessibilityIdentifier("cacheManager")
                Button(L10n.tr("附近设备")) { model.showNearby = true }
                Button(L10n.tr("隐私与使用说明")) { action("privacy") }
            }
        } label: { Image(systemName: "ellipsis") }
            .accessibilityIdentifier("documentMenu").accessibilityLabel(L10n.tr("更多操作"))

    }
    #endif

    /// 两个新建入口共用同一单文稿替换流程，先保留当前输入，再打开新草稿。
    private func newDocument() {
        Task { await workspace.focus(window: window); await workspace.create(in: window); workspace.setWindowSidebarVisible(false, window: window) }
    }

    private func action(_ name: String) {
        Task {
            await workspace.focus(window: window)
            if name == "saveAs" { NotificationCenter.default.post(name: Notification.Name("InkSaveAs"), object: nil) }
            else { NotificationCenter.default.post(name: Notification.Name("InkDocumentAction"), object: name) }
        }
    }
}

private struct WorkspaceSpeechButton: View {
    @ObservedObject var speech: SpeechEngine
    @ObservedObject var model: AppModel
    let action: () -> Void
    private var active: Bool { model.ownsSpeech && speech.playing }
    var body: some View {
        Button(action: action) {
            Image(systemName: active && !speech.paused ? "pause.fill" : "headphones")
        }.accessibilityIdentifier(active ? "toolbarSpeech" : "playPause")
            .accessibilityLabel(active && !speech.paused ? L10n.tr("暂停朗读") : L10n.tr("开始朗读"))
            .accessibilityValue(speech.playbackEvidence)
    }
}

private struct WorkspaceTabTransfer: Codable {
    static let type = UTType(exportedAs: "org.ailifelab.inkengine.workspace-tab", conformingTo: .data)
    let document: UUID
    let window: UUID
    let pane: UUID
}

private struct WorkspaceTabManager: View {
    @ObservedObject var workspace: DocumentWorkspace
    let window: UUID
    @State private var paneID: UUID
    @State private var query = ""
    @State private var selection = Set<UUID>()
    @State private var field = DocumentWorkspace.TabSortField.name
    @State private var ascending = true
    @Environment(\.dismiss) private var dismiss

    init(workspace: DocumentWorkspace, window: UUID, initialPane: UUID) {
        self.workspace = workspace; self.window = window; _paneID = State(initialValue: initialPane)
    }
    private var pane: WorkspacePane? { workspace.window(window)?.panes.first { $0.id == paneID } }
    private var tabs: [WorkspaceTab] {
        (pane?.tabs ?? []).filter { tab in
            guard !query.isEmpty else { return true }
            let model = workspace.sessions[tab.id]
            return (model?.book?.fileName ?? "").localizedStandardContains(query) || (model?.sourcePath ?? "").localizedStandardContains(query)
        }
    }
    private var selected: [UUID] { tabs.map(\.id).filter { selection.contains($0) } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let layout = workspace.window(window), layout.panes.count > 1 {
                    Picker(L10n.tr("视图"), selection: $paneID) {
                        ForEach(Array(layout.panes.enumerated()), id: \.element.id) { index, pane in
                            Text(L10n.tr("视图 \(index + 1)")).tag(pane.id)
                        }
                    }.pickerStyle(.segmented)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.tr("查找标签名称或路径"), text: $query).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("tabManagerSearch")
                }
                HStack {
                    Picker(L10n.tr("排序方式"), selection: $field) {
                        ForEach(DocumentWorkspace.TabSortField.allCases) { value in Text(value.title).tag(value) }
                    }.accessibilityIdentifier("tabManagerSortField")
                    Toggle(L10n.tr("升序"), isOn: $ascending).fixedSize()
                    Button(L10n.tr("排序标签")) { workspace.sortTabs(window: window, pane: paneID, field: field, ascending: ascending) }
                        .accessibilityIdentifier("sortWorkspaceTabs")
                }
                HStack {
                    Button(L10n.tr("全选")) { selection = Set(tabs.map(\.id)) }.accessibilityIdentifier("selectAllWorkspaceTabs")
                    Button(L10n.tr("清除选择")) { selection.removeAll() }
                    Spacer()
                    Text(L10n.tr("已选择 \(selected.count) 个标签")).font(.caption).foregroundStyle(.secondary)
                }
                List {
                    ForEach(tabs) { tab in
                        HStack(spacing: 10) {
                            Button {
                                if !selection.insert(tab.id).inserted { selection.remove(tab.id) }
                            } label: { Image(systemName: selection.contains(tab.id) ? "checkmark.circle.fill" : "circle") }
                                .accessibilityIdentifier("selectManagedTab-" + tab.id.uuidString)
                                .accessibilityLabel(L10n.tr("选择标签 ") + (workspace.sessions[tab.id]?.book?.fileName ?? ""))
                            Button {
                                let id = tab.id, pane = paneID
                                leave { await workspace.focus(window: window, pane: pane, document: id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        if tab.pinned { Image(systemName: "pin.fill") }
                                        Text(workspace.sessions[tab.id]?.book?.fileName ?? L10n.tr("文件暂不可用"))
                                        if workspace.sessions[tab.id]?.dirty == true { Image(systemName: "pencil").accessibilityLabel(L10n.tr("未保存")) }
                                        if pane?.selected == tab.id { Image(systemName: "checkmark") }
                                    }
                                    Text(workspace.sessions[tab.id]?.sourcePath ?? L10n.tr("未保存到文件"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.accessibilityIdentifier("activateManagedTab-" + tab.id.uuidString)
                        }.buttonStyle(.plain).padding(.vertical, 5)
                    }
                }.listStyle(.plain).accessibilityIdentifier("managedTabList")
                HStack {
                    Button(L10n.tr("保存选中标签")) {
                        let ids = selected
                        leave {
                            for id in ids where workspace.sessions[id]?.dirty == true || workspace.sessions[id]?.isNewDraft == true {
                                if !(await workspace.saveDocument(id, window: window)) { break }
                            }
                        }
                    }.disabled(selected.isEmpty).accessibilityIdentifier("saveSelectedWorkspaceTabs")
                    Button(L10n.tr("关闭选中标签")) {
                        let ids = selected, pane = paneID
                        leave { _ = await workspace.close(ids, window: window, pane: pane) }
                    }.disabled(selected.isEmpty).accessibilityIdentifier("closeSelectedWorkspaceTabs")
                    Spacer()
                }
            }.padding(16)
            .navigationTitle(L10n.tr("管理标签"))
            .toolbar { InkPanelDoneToolbar { dismiss() } }
            .onChange(of: query) { _, _ in selection.formIntersection(Set(tabs.map(\.id))) }
            .onChange(of: paneID) { _, _ in selection.removeAll() }
            .background(workspace.model(window).readingTheme.background)
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 440)
        #endif
    }
    private func leave(_ action: @escaping @MainActor () async -> Void) {
        dismiss(); workspace.tabManagerWindow = nil
        Task { @MainActor in
            // 先完成管理面板的退场，再显示保存面板或关闭确认，避免多个模态界面相互遮挡。
            try? await Task.sleep(for: .milliseconds(350))
            await action()
        }
    }
}

#if DEBUG
/// 隔离测试的只读证据层：不占正文布局、不响应点击，不进入正式构建。
/// 原文件证据在标签变化与正式保存后自动更新，界面中不提供测试操作按钮。
private struct WorkspaceDiagnostics: View {
    @ObservedObject var workspace: DocumentWorkspace
    let window: UUID
    let pane: WorkspacePane
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--tabs-ui-testing") {
            Group {
                Text(verbatim: workspace.diskEvidence)
                    .accessibilityIdentifier("workspaceDiskEvidence").accessibilityValue(workspace.diskEvidence)
                Text(verbatim: workspace.undoEvidence)
                    .accessibilityIdentifier("workspaceUndoEvidence").accessibilityValue(workspace.undoEvidence)
                Text(verbatim: String(workspace.model(window, pane: pane.id).book?.cursor ?? 0))
                    .accessibilityIdentifier("workspaceSourceCursor")
                    .accessibilityValue(String(workspace.model(window, pane: pane.id).book?.cursor ?? 0))
                Text(verbatim: (workspace.library.speech.documentID?.uuidString ?? "none") + "|" + workspace.library.speech.playbackEvidence)
                    .accessibilityIdentifier("workspaceSpeechEvidence")
                    .accessibilityValue((workspace.library.speech.documentID?.uuidString ?? "none") + "|" + workspace.library.speech.playbackEvidence)
                Text(verbatim: workspace.closeEvidence)
                    .accessibilityIdentifier("workspaceCloseEvidence").accessibilityValue(workspace.closeEvidence)
            }.font(.system(size: 1)).frame(width: 1, height: 1).foregroundStyle(.clear)
                .allowsHitTesting(false)
                .task(id: pane.tabs.map(\.id)) { await workspace.refreshOriginalFileEvidence() }
        }
    }
}
#endif
