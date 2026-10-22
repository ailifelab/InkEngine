import SwiftUI
import InkCore
#if os(macOS)
import AppKit
#endif

struct WorkspaceMenuCommand: Identifiable {
    let id = UUID()
    var title: String
    var enabled = true
    var checked = false
    var children: [WorkspaceMenuCommand] = []
    var action: (@MainActor () -> Void)?
    static var separator: Self { .init(title: "") }
}

@MainActor extension DocumentWorkspace {
    func tabCommands(_ tab: WorkspaceTab, pane: WorkspacePane, window: UUID, allowsSplit: Bool, supportsMultipleWindows: Bool, openWindow: @escaping (UUID) -> Void) -> [WorkspaceMenuCommand] {
        let id = tab.id, model = sessions[id]
        let index = pane.tabs.firstIndex(where: { $0.id == id }) ?? 0
        func item(_ title: String, enabled: Bool = true, checked: Bool = false, _ action: @escaping @MainActor () -> Void) -> WorkspaceMenuCommand {
            .init(title: title, enabled: enabled, checked: checked, action: action)
        }
        func closeItem(_ title: String, ids: [UUID]) -> WorkspaceMenuCommand {
            item(title, enabled: !ids.isEmpty) { Task { _ = await self.close(ids, window: window, pane: pane.id) } }
        }
        var opening: [WorkspaceMenuCommand] = []
        #if os(macOS)
        opening += [item(L10n.tr("在 Finder 中显示")) { Task { await self.reveal(id) } },
                    item(L10n.tr("在终端打开所在目录")) { Task { await self.openTerminal(id) } }]
        #endif
        opening += [item(L10n.tr("用默认应用打开")) { Task { await self.openExternally(id) } },
                    item(L10n.tr("打开所在目录为工作区")) { Task { await self.openContainingFolder(id, window: window) } }]
        let colors = (0..<5).map { color in
            item(L10n.tr("颜色 \(color + 1)"), checked: tab.color == color) { self.updateTab(id, window: window, pane: pane.id) { $0.color = color } }
        } + [item(L10n.tr("清除颜色")) { self.updateTab(id, window: window, pane: pane.id) { $0.color = nil } }]
        return [
            item(L10n.tr("新建文稿")) { Task { await self.create(in: window, pane: pane.id) } },
            closeItem(L10n.tr("关闭当前标签"), ids: [id]),
            item(L10n.tr("重新打开关闭的标签"), enabled: !recentlyClosedTabs.isEmpty) { Task { await self.reopenClosedTab(in: window, pane: pane.id) } },
            .init(title: L10n.tr("关闭多个标签"), children: [
                closeItem(L10n.tr("关闭其他标签"), ids: pane.tabs.filter { $0.id != id }.map(\.id)),
                item(L10n.tr("关闭全部标签")) { Task { await self.closeAll(in: window) } },
                closeItem(L10n.tr("关闭所有未固定标签"), ids: pane.tabs.filter { !$0.pinned }.map(\.id)),
                closeItem(L10n.tr("关闭左侧标签"), ids: pane.tabs.prefix(index).map(\.id)),
                closeItem(L10n.tr("关闭右侧标签"), ids: pane.tabs.dropFirst(index + 1).map(\.id)),
                closeItem(L10n.tr("关闭所有未修改标签"), ids: pane.tabs.filter { self.sessions[$0.id]?.dirty == false }.map(\.id))
            ]),
            item(tab.pinned ? L10n.tr("取消固定标签") : L10n.tr("固定标签"), checked: tab.pinned) { self.updateTab(id, window: window, pane: pane.id) { $0.pinned.toggle() } },
            .separator,
            item(L10n.tr("保存"), enabled: model?.dirty == true || model?.isNewDraft == true) { Task { _ = await self.saveDocument(id, window: window) } },
            item(L10n.tr("另存为…"), enabled: model != nil) { Task { _ = await self.saveDocument(id, window: window, saveAs: true) } },
            .init(title: L10n.tr("打开位置"), enabled: model?.sourcePath != nil, children: opening),
            item(L10n.tr("重命名"), enabled: model != nil) { self.fileOperation = .init(document: id, window: window, kind: .rename) },
            item(L10n.tr("删除文件…"), enabled: model?.sourcePath != nil) { self.fileOperation = .init(document: id, window: window, kind: .delete) },
            item(L10n.tr("重新载入"), enabled: model?.sourcePath != nil) {
                if model?.dirty == true { self.fileOperation = .init(document: id, window: window, kind: .reload) }
                else { Task { await self.reload(id) } }
            },
            item(L10n.tr("打印…"), enabled: model != nil) { self.printDocument(id) },
            item(L10n.tr("文稿只读"), enabled: model != nil, checked: model?.documentReadOnly == true) { model?.documentReadOnly.toggle() },
            .init(title: L10n.tr("复制到剪贴板"), children: [
                item(L10n.tr("复制文件名")) { self.copy(model?.book?.fileName ?? "") },
                item(L10n.tr("复制完整路径"), enabled: model?.sourcePath != nil) { self.copy(model?.sourcePath ?? "") },
                item(L10n.tr("复制所在目录路径"), enabled: model?.sourcePath != nil) { self.copy(model?.sourcePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "") }
            ]),
            .init(title: L10n.tr("移动文稿"), children: [
                item(L10n.tr("标签左移"), enabled: index > 0 && pane.tabs[index - 1].pinned == tab.pinned) { self.shiftTab(id, direction: -1, window: window, pane: pane.id) },
                item(L10n.tr("标签右移"), enabled: index + 1 < pane.tabs.count && pane.tabs[index + 1].pinned == tab.pinned) { self.shiftTab(id, direction: 1, window: window, pane: pane.id) },
                item(L10n.tr("移到最前")) { self.reorder(id, before: pane.tabs.first?.id, window: window, pane: pane.id) },
                item(L10n.tr("移到最后")) { self.reorder(id, before: nil, window: window, pane: pane.id) },
                item(L10n.tr("移到另一视图"), enabled: allowsSplit) { Task { await self.split(id, window: window, pane: pane.id, clone: false) } },
                item(L10n.tr("克隆到另一视图"), enabled: allowsSplit) { Task { await self.split(id, window: window, pane: pane.id, clone: true) } },
                item(L10n.tr("移到新窗口"), enabled: supportsMultipleWindows) { openWindow(self.newWindow(document: id, movingFrom: window, pane: pane.id)) },
                item(L10n.tr("在新窗口打开"), enabled: supportsMultipleWindows) { openWindow(self.newWindow(document: id)) }
            ]),
            .init(title: L10n.tr("标签颜色"), children: colors),
            .separator,
            item(L10n.tr("管理标签…")) { self.tabManagerWindow = window }
        ]
    }
}

struct WorkspaceCommandMenu: View {
    let commands: [WorkspaceMenuCommand]
    var body: some View {
        ForEach(commands) { command in
            if command.title.isEmpty { Divider() }
            else if !command.children.isEmpty {
                Menu(command.title) { WorkspaceCommandMenu(commands: command.children) }.disabled(!command.enabled)
            } else {
                Button { command.action?() } label: {
                    if command.checked { Label(command.title, systemImage: "checkmark") }
                    else { Text(command.title) }
                }.disabled(!command.enabled)
            }
        }
    }
}

#if os(macOS)
struct MacTabContextMenu: NSViewRepresentable {
    let commands: @MainActor () -> [WorkspaceMenuCommand]
    var middleClick: (@MainActor () -> Void)?
    func makeNSView(context: Context) -> ContextView { ContextView() }
    func updateNSView(_ view: ContextView, context: Context) { view.commands = commands; view.middleClick = middleClick }
    final class ContextView: NSView {
        var commands: (@MainActor () -> [WorkspaceMenuCommand])?
        var middleClick: (@MainActor () -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let right = [.rightMouseDown, .rightMouseUp, .rightMouseDragged].contains(event.type)
            let middle = event.buttonNumber == 2 && [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type)
            guard right || middle else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { middleClick?() }
        }
        override func otherMouseDown(with event: NSEvent) { }
        override func rightMouseDown(with event: NSEvent) {
            NSMenu.popUpContextMenu(makeMenu(commands?() ?? []), with: event, for: self)
        }
        private func makeMenu(_ commands: [WorkspaceMenuCommand]) -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            for command in commands {
                if command.title.isEmpty { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: "")
                item.isEnabled = command.enabled; item.state = command.checked ? .on : .off
                if !command.children.isEmpty { item.submenu = makeMenu(command.children) }
                else {
                    let target = ActionTarget(action: command.action)
                    item.representedObject = target; item.target = target; item.action = #selector(ActionTarget.invoke(_:))
                }
                menu.addItem(item)
            }
            return menu
        }
    }
    @MainActor final class ActionTarget: NSObject {
        let action: (@MainActor () -> Void)?
        init(action: (@MainActor () -> Void)?) { self.action = action }
        @objc func invoke(_ sender: Any?) { action?() }
    }
}
#endif
