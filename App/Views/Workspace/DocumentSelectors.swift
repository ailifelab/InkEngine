import SwiftUI
import InkCore

// 编辑、阅读共用同一组选择器，避免主题和语法菜单在两种模式中漂移。
struct DocumentThemeMenu: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var model: AppModel
    var body: some View {
        Menu {
            Picker(L10n.tr("界面主题"), selection: $model.readingTheme) {
                ForEach(ReadingTheme.allCases) { theme in Text(theme.label).tag(theme).accessibilityIdentifier("theme-" + theme.rawValue) }
            }.pickerStyle(.inline)
        } label: { Image(systemName: "paintpalette").frame(width: 14) }
            .menuStyle(.button).buttonStyle(WorkspaceControlStyle()).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("appearanceMenu").accessibilityLabel(L10n.tr("界面主题")).accessibilityValue(model.readingTheme.rawValue)
    }
}

struct DocumentSyntaxMenu: View {
    @Environment(\.locale) private var appLocale
    @ObservedObject var model: AppModel
    let book: Manuscript
    var body: some View {
        Menu {
            Picker(L10n.tr("语法高亮"), selection: Binding<TextFormat?>(get: { model.book?.highlightOverride }, set: { format in Task { await model.chooseSyntax(format) } })) {
                Text(L10n.tr("自动识别 · ") + TextFormat.detect(book.fileName).label).tag(Optional<TextFormat>.none).accessibilityIdentifier("syntax-auto")
                ForEach(TextFormat.allCases, id: \.self) { format in
                    Text(format.label).tag(Optional(format)).accessibilityIdentifier("syntax-" + format.rawValue)
                }
            }.pickerStyle(.inline)
        } label: { HStack(spacing: 4) { Text(book.highlightFormat.label).accessibilityIdentifier("documentFormat"); Image(systemName: "chevron.down").font(.system(size: 8)) } }
            .menuStyle(.button).buttonStyle(WorkspaceControlStyle()).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("syntaxMenu").accessibilityLabel(L10n.tr("语法高亮")).accessibilityValue(book.highlightFormat.label)
    }
}
