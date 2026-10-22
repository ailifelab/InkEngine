import SwiftUI
import InkCore

struct NovelAliasForm: View {
    @Environment(\.locale) private var appLocale
    @Binding var name: String
    let importing: Bool
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.paperTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(importing ? L10n.tr("添加小说目录") : L10n.tr("修改小说别名")).font(.title3.bold())
            TextField(L10n.tr("小说名称"), text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("novelAliasField")
            Text(L10n.tr("别名用于历史记录中的目录分组，章节保留原文件名。编辑会保存回对应原文件。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr("取消"), role: .cancel) { dismiss() }
                Spacer()
                Button(importing ? L10n.tr("导入小说") : L10n.tr("保存名称"), action: confirm)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 200)
                    .accessibilityIdentifier("confirmNovelAlias")
            }
        }.padding(24).frame(minWidth: 300, idealWidth: 420)
            .background(theme.background.ignoresSafeArea()).foregroundStyle(theme.foreground)
            .buttonStyle(KeycapButtonStyle(compact: true))
    }
}

