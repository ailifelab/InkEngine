import Foundation
import NaturalLanguage

public struct SpeechCursor: Sendable, Equatable, Codable {
    public let segment: Int
    public let offset: Int
    public init(segment: Int, offset: Int = 0) { self.segment = segment; self.offset = offset }
}

public struct NeuralSpeechChunk: Sendable, Equatable {
    public let text: String
    public let cursor: SpeechCursor
    public let next: SpeechCursor
    public let spokenRange: NSRange
    public let sourceOffset: Int
}

extension ParsedText {
    /// 按需规划一句：优先完整句末，长句退到分句标点，保留标点和闭引号。
    /// 限长按 UTF-16 计数，边界按组合字符裁切，避免拆开 emoji 或代理对。
    public func neuralChunk(from cursor: SpeechCursor, skipCode: Bool, limit: Int = 96, maxSentences: Int = 1) -> NeuralSpeechChunk? {
        var index = max(0, cursor.segment), offset = max(0, cursor.offset)
        while index < segments.count {
            let segment = segments[index]
            let ns = segment.text as NSString
            if (skipCode && segment.isCode) || offset >= ns.length { index += 1; offset = 0; continue }
            let startRange = ns.rangeOfComposedCharacterSequence(at: offset)
            offset = startRange.location
            var boundaries: [(end: Int, sentence: Bool, clause: Bool)] = []
            var end = offset
            var sentenceCount = 0
            while end < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: end)
                let character = ns.substring(with: range)
                if range.location + range.length - offset > max(8, limit), !boundaries.isEmpty { break }
                end = NSMaxRange(range)
                let sentenceEnd = "。！？!?\n".contains(character) || (character == "." && (end == ns.length || " \t\n”\"".contains(ns.substring(with: ns.rangeOfComposedCharacterSequence(at: end)))))
                boundaries.append((end, sentenceEnd, "，,:：、；;".contains(character)))
                if sentenceEnd {
                    // 闭引号与前一句一起合成，不人为插入停顿。
                    while end < ns.length {
                        let closing = ns.rangeOfComposedCharacterSequence(at: end)
                        guard "”’\"'」』）》】".contains(ns.substring(with: closing)) else { break }
                        end = NSMaxRange(closing)
                    }
                    boundaries[boundaries.count - 1].end = end
                    sentenceCount += 1
                    if sentenceCount >= max(1, maxSentences) { break }
                }
                if end - offset >= max(8, limit) { break }
            }
            if end < ns.length && boundaries.last?.sentence != true {
                let preferred = boundaries.last(where: { $0.sentence && $0.end - offset >= min(36, limit / 3) })
                    ?? boundaries.last(where: { $0.clause && $0.end - offset >= min(8, max(2, limit / 8)) })
                if let preferred { end = preferred.end }
                else {
                    // 没有标点时，退到词边界，不能为了凑字数把“盗墓”等词拆成两次合成。
                    let tokenizer = NLTokenizer(unit: .word); tokenizer.string = segment.text
                    let boundary = String.Index(utf16Offset: end, in: segment.text)
                    let word = tokenizer.tokenRange(at: boundary)
                    let start = word.lowerBound.utf16Offset(in: segment.text)
                    if start > offset && start < end { end = start }
                }
            }
            let range = NSRange(location: offset, length: end - offset)
            let next = end == ns.length ? SpeechCursor(segment: index + 1) : SpeechCursor(segment: index, offset: end)
            return NeuralSpeechChunk(text: ns.substring(with: range), cursor: SpeechCursor(segment: index, offset: offset), next: next,
                                     spokenRange: range, sourceOffset: segment.sourceRange(forSpoken: range)?.location ?? segment.sourceRange.location)
        }
        return nil
    }
    /// 连续句子共享同一合成上下文，减少句句重新起腔。预算、分块不随倍率或音色改变，
    /// 暂停缓存及故障切换始终使用同一个原文游标；只读取当前位置所在段落。
    public func continuousSpeechChunk(from cursor: SpeechCursor, skipCode: Bool) -> NeuralSpeechChunk? {
        neuralChunk(from: cursor, skipCode: skipCode, limit: 180, maxSentences: 3)
    }
    /// Core ML exports have bounded frame/cache capacities. Use the same source
    /// cursor and punctuation/word boundaries while respecting those capacities.
    public func speechChunk(from cursor: SpeechCursor, skipCode: Bool, renderer: String) -> NeuralSpeechChunk? {
        if renderer == "zipvoice" || renderer == "zipvoice-male" || renderer == "qwen" {
            return neuralChunk(from: cursor, skipCode: skipCode, limit: 24, maxSentences: 2)
        }
        return continuousSpeechChunk(from: cursor, skipCode: skipCode)
    }
    public func speechCursor(at sourceOffset: Int) -> SpeechCursor {
        guard !segments.isEmpty else { return SpeechCursor(segment: 0) }
        let index = segmentIndex(at: sourceOffset)
        let segment = segments[index]
        let offset = segment.sourceOffsets.firstIndex(where: { $0 >= sourceOffset }) ?? segment.text.utf16.count
        return SpeechCursor(segment: index, offset: offset)
    }
    public func adjacentParagraph(from index: Int, forward: Bool) -> Int? {
        guard !segments.isEmpty else { return nil }
        var start = min(max(0, index), segments.count - 1)
        while start > 0 && NSMaxRange(segments[start - 1].sourceRange) == segments[start].sourceRange.location { start -= 1 }
        if forward {
            var next = start + 1
            while next < segments.count && NSMaxRange(segments[next - 1].sourceRange) == segments[next].sourceRange.location { next += 1 }
            return next < segments.count ? next : nil
        }
        guard start > 0 else { return nil }
        start -= 1
        while start > 0 && NSMaxRange(segments[start - 1].sourceRange) == segments[start].sourceRange.location { start -= 1 }
        return start
    }
}

/// 账本只随实际播放的样本推进，预合成不会改变阅读位置。
/// 暂停冻结账本，跳转更换代次，旧音频回调不能覆盖新的位置。
public struct SpeechPlaybackLedger: Sendable {
    public struct Entry: Sendable {
        public let chunk: NeuralSpeechChunk
        public let start: Int64
        public let end: Int64
    }
    public private(set) var generation = UUID()
    public private(set) var entries: [Entry] = []
    public private(set) var scheduledFrames: Int64 = 0
    public private(set) var renderedFrames: Int64 = 0
    public private(set) var frozen = false
    public init() {}
    public mutating func reset() { generation = UUID(); entries = []; scheduledFrames = 0; renderedFrames = 0; frozen = false }
    @discardableResult public mutating func append(_ chunk: NeuralSpeechChunk, frames: Int64, generation: UUID) -> Bool {
        guard generation == self.generation, frames > 0 else { return false }
        entries.append(Entry(chunk: chunk, start: scheduledFrames, end: scheduledFrames + frames))
        scheduledFrames += frames; return true
    }
    public mutating func render(to frame: Int64, generation: UUID) {
        guard generation == self.generation, !frozen else { return }
        renderedFrames = min(scheduledFrames, max(renderedFrames, frame))
        // 仅保留当前句和预存句，长篇小说不会累积已播条目。
        while entries.count > 1 && entries[1].start <= renderedFrames { entries.removeFirst() }
    }
    public mutating func pause() { frozen = true }
    public mutating func resume() { frozen = false }
    public var current: Entry? { entries.first(where: { renderedFrames >= $0.start && renderedFrames < $0.end }) }
}
