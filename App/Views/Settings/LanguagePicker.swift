import SwiftUI
import InkCore

struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey, store: L10n.preferences) private var selection = AppLanguage.system.rawValue
    @Environment(\.locale) private var locale
    var body: some View {
        Picker(L10n.tr("界面语言"), selection: $selection) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.nativeName).tag(language.rawValue).accessibilityIdentifier("language-" + language.rawValue)
            }
        }.accessibilityIdentifier("appLanguagePicker")
    }
}

struct LanguageMenu: View {
    @AppStorage(AppLanguage.preferenceKey, store: L10n.preferences) private var selection = AppLanguage.system.rawValue
    @Environment(\.locale) private var locale
    var body: some View {
        Menu {
            Picker(L10n.tr("界面语言"), selection: $selection) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(language.rawValue)
                        .accessibilityIdentifier("language-" + language.rawValue)
                }
            }.pickerStyle(.inline)
        } label: {
            Label(L10n.tr("语言"), systemImage: "globe")
        }
        .menuStyle(.button).buttonStyle(KeycapButtonStyle(compact: true))
        .accessibilityLabel(L10n.tr("界面语言"))
        .accessibilityIdentifier("languageMenu")
        .accessibilityValue(selection)
        .help(L10n.tr("切换界面语言"))
    }
}
