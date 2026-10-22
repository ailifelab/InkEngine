import SwiftUI
import InkCore

/// Native sheets keep their own environment; observe the saved language there too.
private struct LocalizedPresentation<Content: View>: View {
    @AppStorage(AppLanguage.preferenceKey, store: L10n.preferences) private var language = AppLanguage.system.rawValue
    let content: Content
    var body: some View {
        content.environment(\.locale, (AppLanguage(rawValue: language) ?? .system).locale)
    }
}

extension View {
    func appLocalized() -> some View { LocalizedPresentation(content: self) }
}
