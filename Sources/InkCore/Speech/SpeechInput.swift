import Foundation

/// 模型通过标点决定语调和停顿；空格只用于词间分隔，不能代替句号或逗号。
/// 清理仅作用于合成副本，书页、跳读位置和恢复游标始终使用原文。
public enum SpeechInput {
    public static let cacheVersion = "continuous-prosody-4-full-waveform"
    public static func preparing(_ text: String) -> String {
        var result = ""
        var previousPause = false
        for character in text {
            let replacement: String
            switch character {
            case "。", "．", "｡", "…", "⋯": replacement = "。"
            case "，", "、", ",", "—", "–", "/", "\\", "|": replacement = "，"
            case "！", "!": replacement = "！"
            case "？", "?": replacement = "？"
            case "：", ":": replacement = "："
            case "；", ";": replacement = "；"
            case "\n", "\r": replacement = "。"
            case "“", "”", "‘", "’", "\"", "「", "」", "『", "』", "（", "）", "(", ")", "【", "】", "[", "]", "《", "》", "〈", "〉", "{", "}": continue
            case "*", "#", "`", "~", "<", ">", "=", "^", "$", "_": replacement = " "
            default: replacement = String(character)
            }
            // 省略号、连续破折号只产生一次停顿；保留小数点及英语句号。
            let pause = ["。", "，", "！", "？", "：", "；"].contains(replacement)
            if pause && previousPause { continue }
            result += replacement
            previousPause = pause
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func hasSpokenContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
}
