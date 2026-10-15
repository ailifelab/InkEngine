import Foundation

public struct SpeechVoiceOption: Sendable {
    public let id: String
    public let language: String
    public let quality: Int
    public let name: String
    public init(id: String, language: String, quality: Int, name: String = "") {
        self.id = id; self.language = language; self.quality = quality; self.name = name
    }
}

public enum MandarinVoicePolicy {
    public static func supports(_ language: String) -> Bool {
        let locale = language.lowercased().replacingOccurrences(of: "_", with: "-")
        return locale == "zh" || ["zh-cn", "zh-hans", "zh-sg", "zh-tw", "zh-hant"].contains(where: { locale == $0 || locale.hasPrefix($0 + "-") })
    }
    public static func choose(from voices: [SpeechVoiceOption], savedID: String) -> String? {
        let mandarin = voices.filter { supports($0.language) }
        if mandarin.contains(where: { $0.id == savedID }) { return savedID }
        func rank(_ language: String) -> Int {
            let locale = language.lowercased().replacingOccurrences(of: "_", with: "-")
            return locale.hasPrefix("zh-cn") || locale.hasPrefix("zh-hans") ? 0 : locale.hasPrefix("zh-sg") ? 1 : 2
        }
        return mandarin.sorted {
            if rank($0.language) != rank($1.language) { return rank($0.language) < rank($1.language) }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            // 同质量优先常规普通话朗读音色；用户明确保存的有效音色在排序前返回。
            let narrationNames = ["tingting", "tian-tian", "lili", "meijia", "婷婷", "天天", "丽丽", "美佳"]
            let first = narrationNames.contains($0.name.lowercased()), second = narrationNames.contains($1.name.lowercased())
            if first != second { return first }
            return $0.id < $1.id
        }.first?.id
    }
}
