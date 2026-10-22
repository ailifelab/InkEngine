import SwiftUI
import InkCore

/// 滑动操作只影响历史/固定入口；永久删除正文必须进入长按菜单并确认。
struct HistorySwipeActions: ViewModifier {
    @Environment(\.locale) private var appLocale
    @ObservedObject var model: AppModel
    let entry: RecentEntry
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { Task { await model.pin(entry) } } label: {
                    Label(model.history.pinned.contains(entry.id) ? L10n.tr("取消固定") : L10n.tr("固定到顶部"), systemImage: model.history.pinned.contains(entry.id) ? "pin.slash" : "pin")
                }.buttonStyle(.automatic).tint(model.readingTheme.highlight)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                // 历史异步写盘：用数据变化驱动删行，避免系统破坏性滑动的预删动画重复删除同一行。
                Button { Task { await model.removeRecent(entry.id) } } label: { Label(L10n.tr("删除"), systemImage: "trash") }
                    .buttonStyle(.automatic).tint(.red)
                    .accessibilityLabel(L10n.tr("删除历史记录"))
            }
        #else
        content
        #endif
    }
}
