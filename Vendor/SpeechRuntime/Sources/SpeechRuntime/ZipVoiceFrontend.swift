import Foundation

/// Read the model's own Mandarin lexicon. Unknown spoken characters fail the
/// entire request; they must never be silently skipped by the neural backend.
struct ZipVoiceFrontend {
    private let phones: [String: Int32]
    private let lexicon: [String: [Int32]]
    private let maxWordLength: Int
    init(tokens: String, lexicon text: String) throws {
        var phones: [String: Int32] = [:]
        for line in tokens.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let split = line.lastIndex(of: "\t"), let id = Int32(line[line.index(after: split)...]) else { continue }
            phones[String(line[..<split])] = id
        }
        guard phones["_"] == 0 else { throw SpeechFailure.initialization }
        self.phones = phones
        var lexicon: [String: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first, parts.count > 1 else { continue }
            let ids = parts.dropFirst().compactMap { phones[String($0)] }
            guard ids.count == parts.count - 1 else { continue }
            lexicon[String(first)] = ids
        }
        self.lexicon = lexicon
        maxWordLength = min(32, lexicon.keys.map(\.count).max() ?? 1)
    }
    func encode(_ text: String) throws -> [Int32] {
        let punctuation: [Character: String] = ["，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":", "、": ",", "—": "-", "…": "."]
        // Keep every ASCII digit audible, including years, identifiers and
        // leading zeroes; the model lexicon contains the Mandarin digit names.
        let digits = Array("零一二三四五六七八九")
        let original = Array(text)
        let characters = original.indices.map { i -> Character in
            if let ascii = original[i].asciiValue, (48...57).contains(ascii) { return digits[Int(ascii - 48)] }
            if original[i] == ".", i > 0, i + 1 < original.count, original[i-1].isNumber, original[i+1].isNumber { return "点" }
            return original[i]
        }
        var index = 0, output: [Int32] = []
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { if let space = phones[" "] { output.append(space) }; index += 1; continue }
            // Quotes have no spoken content; the adjacent sentence punctuation remains.
            if "“”‘’\"「」『』（）()【】[]".contains(c) { index += 1; continue }
            if let p = phones[punctuation[c] ?? String(c)], !c.isLetter && !c.isNumber { output.append(p); index += 1; continue }
            var found = false
            for count in stride(from: min(maxWordLength, characters.count - index), through: 1, by: -1) {
                if let ids = lexicon[String(characters[index..<(index + count)])] {
                    output.append(contentsOf: ids); index += count; found = true; break
                }
            }
            guard found else { throw SpeechFailure.unsupportedText }
        }
        guard !output.isEmpty else { throw SpeechFailure.unsupportedText }
        return output
    }
}
