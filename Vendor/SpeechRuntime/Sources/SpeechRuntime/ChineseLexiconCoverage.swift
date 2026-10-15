import Foundation

/// 部分中文前端会跳过词典外汉字，即使返回非空音频也不能说明正文完整。
/// 在合成前保守检查汉字覆盖；遇到不支持的汉字抛错，由播放器从同一原文游标切换系统音色。
struct ChineseLexiconCoverage {
    private let characters: Set<Unicode.Scalar>
    init(lexicon: String) {
        // 单字条目才保证任意上下文可识别；仅出现在某个长词中的字保守交给系统。
        characters = Set(lexicon.split(separator: "\n").compactMap { line in
            guard let key = line.split(whereSeparator: \.isWhitespace).first,
                  key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
                  Self.isChinese(scalar) else { return nil }
            return scalar
        })
    }
    func validate(_ text: String, chineseOnly: Bool = false) throws {
        // Piper 中文词典无法完整处理英文词汇：整段交给系统，禁止逐字母猜读或静默丢词。
        if chineseOnly && text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && !Self.isChinese($0) }) {
            throw SpeechFailure.unsupportedText
        }
        guard !text.unicodeScalars.contains(where: { Self.isChinese($0) && !characters.contains($0) }) else {
            throw SpeechFailure.unsupportedText
        }
    }
    private static func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
    }
}
