import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en", traditionalChinese = "zh-Hant"

    public static let preferenceKey = "appLanguage"
    public var id: String { rawValue }
    /// Keep language names readable even when the current interface is unfamiliar.
    public var nativeName: String {
        switch self {
        case .system: return L10n.tr("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for identifier in preferredLanguages {
            let parts = identifier.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
            if parts.first == "en" { return .english }
            if parts.first == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .traditionalChinese : .simplifiedChinese
            }
        }
        return .english
    }

    public var locale: Locale { Locale(identifier: resolved().rawValue) }
}

public enum L10n {
    /// UI tests use their existing isolated preferences domain.
    public static var preferences: UserDefaults {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? UserDefaults(suiteName: "org.ailifelab.InkEngine.UITests")! : .standard
    }
    public static var language: AppLanguage {
        AppLanguage(rawValue: preferences.string(forKey: AppLanguage.preferenceKey) ?? "system") ?? .system
    }

    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        public let key: String
        public let arguments: [String]
        public init(stringLiteral value: String) { key = value; arguments = [] }
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key; arguments = stringInterpolation.arguments
        }
        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            public init(literalCapacity: Int, interpolationCount: Int) { arguments.reserveCapacity(interpolationCount) }
            public mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
            public mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
            public mutating func appendInterpolation<T: CVarArg>(_ value: T, specifier: String) {
                key += "%@"; arguments.append(String(format: specifier, locale: L10n.language.locale, value))
            }
        }
    }

    public static func tr(_ message: Message, language: AppLanguage? = nil) -> String {
        let selected = (language ?? self.language).resolved()
        #if SWIFT_PACKAGE
        let resources = Bundle.module
        #else
        let resources = Bundle.main
        #endif
        let bundle = resources.url(forResource: selected.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? resources
        let template = bundle.localizedString(forKey: message.key, value: message.key, table: "Localizable")
        guard !message.arguments.isEmpty else { return template }
        return String(format: template, locale: selected.locale, arguments: message.arguments)
    }
}
