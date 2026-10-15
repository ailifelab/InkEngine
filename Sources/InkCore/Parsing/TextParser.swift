import Foundation

public struct TextSegment: Identifiable, Sendable, Equatable {
    public let id: Int
    public let sourceRange: NSRange
    public let text: String
    public let sourceOffsets: [Int] // One entry for each UTF-16 code unit in spoken/display text.
    public let isCode: Bool
    public let isHeading: Bool
    public let table: MarkdownTableRow?

    public init(id: Int, sourceRange: NSRange, text: String, sourceOffsets: [Int], isCode: Bool, isHeading: Bool, table: MarkdownTableRow? = nil) {
        self.id = id; self.sourceRange = sourceRange; self.text = text; self.sourceOffsets = sourceOffsets
        self.isCode = isCode; self.isHeading = isHeading; self.table = table
    }

    public func sourceRange(forSpoken range: NSRange) -> NSRange? {
        guard range.location >= 0, range.length > 0, range.location < sourceOffsets.count else { return nil }
        let end = min(sourceOffsets.count - 1, range.location + range.length - 1)
        return NSRange(location: sourceOffsets[range.location], length: sourceOffsets[end] - sourceOffsets[range.location] + 1)
    }
}

public struct Chapter: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let sourceOffset: Int
}

public struct ParsedText: Sendable {
    public let segments: TextSegmentCollection
    public let chapters: [Chapter]
    public init(segments: [TextSegment], chapters: [Chapter]) { self.segments = TextSegmentCollection(segments); self.chapters = chapters }
    init(segments: TextSegmentCollection, chapters: [Chapter]) { self.segments = segments; self.chapters = chapters }
    public func segmentIndex(at sourceOffset: Int) -> Int {
        guard !segments.isEmpty else { return 0 }
        var low = 0, high = segments.count
        while low < high {
            let middle = (low + high) / 2
            if segments.sourceRange(at: middle).location <= sourceOffset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
    /// 文件末尾、尾部空行也可能是合法的保存位置。显示时回到最后一段，
    /// 不能把“该位置之后没有字符”误判成整份文稿没有正文。
    public func readingStart(at sourceOffset: Int) -> Int {
        let requested = max(0, sourceOffset)
        guard let last = segments.last else { return requested }
        if requested > (last.sourceOffsets.max() ?? last.sourceRange.location) { return last.sourceRange.location }
        return requested
    }
}

public enum TextParser {
    private static let heading = try! NSRegularExpression(pattern: "^(?:#{1,6}\\s+|第[零〇一二三四五六七八九十百千万0-9]+[章回节卷部])")
    private static let patterns = [
        "!\\[[^\\]]*\\]\\([^)]*\\)", // Images have no spoken payload.
        "(?<=\\])\\([^)]*\\)", // Keep a link label; drop its URL.
        "^\\s{0,3}(?:#{1,6}\\s+|>\\s*|[-+*]\\s+|[0-9]+[.)]\\s+)",
        "[*_`~]+", "\\[|\\]", "<[^>]+>", "\\\\(?=[\\p{P}|])"
    ].map { try! NSRegularExpression(pattern: $0) }

    // 全文扫描一次建立范围索引，每段最多 800 个 UTF-16 单元；显示和朗读时才展开。
    public static func parse(_ source: String, format: TextFormat) -> ParsedText {
        let units = Array(source.utf16)
        let sourceString = source as NSString
        var spans: [TextSegmentCollection.Span] = [], chapters: [Chapter] = []
        var start = 0, code = false, fence: UInt16? = nil
        var tableColumns: [MarkdownTableAlignment]?, tableDelimiter = false
        while start < units.count {
            var end = start
            while end < units.count && units[end] != 10 && units[end] != 13 { end += 1 }
            let line = String(decoding: units[start..<end], as: UTF16.self)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var nextStart = end
            if nextStart < units.count && units[nextStart] == 13 { nextStart += 1 }
            if nextStart < units.count && units[nextStart] == 10 { nextStart += 1 }
            let isFence = format == .markdown && (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~"))
            if trimmed.isEmpty || isFence { tableColumns = nil; tableDelimiter = false }
            if format == .markdown && !code && !isFence && !trimmed.isEmpty {
                if tableDelimiter { tableDelimiter = false; start = nextStart; continue }
                var header = false
                let cellRanges = MarkdownTableSyntax.cells(line, base: start)
                if tableColumns != nil && (!line.contains("|") || cellRanges.isEmpty) { tableColumns = nil }
                if tableColumns == nil && line.contains("|") {
                    var followingEnd = nextStart
                    while followingEnd < units.count && units[followingEnd] != 10 && units[followingEnd] != 13 { followingEnd += 1 }
                    let following = String(decoding: units[nextStart..<followingEnd], as: UTF16.self)
                    if let columns = MarkdownTableSyntax.alignments(following), columns.count == cellRanges.count {
                        tableColumns = columns; tableDelimiter = true; header = true
                    }
                }
                if let columns = tableColumns {
                    spans.append(.init(range: NSRange(location: start, length: end - start), isCode: false, isHeading: false, tableColumns: columns, isTableHeader: header))
                    start = nextStart; continue
                }
            }
            if isFence {
                let marker: UInt16 = trimmed.hasPrefix("```") ? 96 : 126
                if !code { code = true; fence = marker } else if marker == fence { code = false; fence = nil }
            } else if !trimmed.isEmpty {
                let isHeading = !code && heading.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil
                let firstIndex = spans.count
                var chunkStart = start
                while chunkStart < end {
                    var chunkEnd = min(end, chunkStart + 800)
                    // UTF-16 截断点不能落在代理对中间，避免损坏 emoji 等字符。
                    if chunkEnd < end && (0xDC00...0xDFFF).contains(units[chunkEnd]) { chunkEnd -= 1 }
                    if chunkEnd < end {
                        let floor = max(chunkStart + 200, chunkEnd - 250)
                        if let boundary = (floor..<chunkEnd).reversed().first(where: { [UInt16(32), 12290, 65281, 65311, 46, 33, 63, 65307].contains(units[$0]) }) { chunkEnd = boundary + 1 }
                        let composed = sourceString.rangeOfComposedCharacterSequence(at: chunkEnd)
                        if composed.location < chunkEnd {
                            chunkEnd = composed.location > chunkStart ? composed.location : min(end, NSMaxRange(composed))
                        }
                    }
                    let range = NSRange(location: chunkStart, length: chunkEnd - chunkStart)
                    let hasText: Bool
                    if format == .markdown && !code {
                        hasText = !materialize(source: sourceString, format: format, id: spans.count, range: range, isCode: code, isHeading: isHeading).text.trimmingCharacters(in: .whitespaces).isEmpty
                    } else { hasText = !sourceString.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty }
                    if hasText { spans.append(.init(range: range, isCode: code, isHeading: isHeading)) }
                    chunkStart = chunkEnd
                }
                if isHeading, firstIndex < spans.count {
                    let span = spans[firstIndex]
                    let title = materialize(source: sourceString, format: format, id: firstIndex, range: span.range, isCode: false, isHeading: true).text
                    chapters.append(Chapter(id: firstIndex, title: title, sourceOffset: start))
                }
            }
            start = end
            if start < units.count && units[start] == 13 { start += 1 }
            if start < units.count && units[start] == 10 { start += 1 }
        }
        return ParsedText(segments: TextSegmentCollection(source: source, format: format, spans: spans), chapters: chapters)
    }

    static func materialize(source: NSString, format: TextFormat, id: Int, range: NSRange, isCode: Bool, isHeading: Bool, tableColumns: [MarkdownTableAlignment]? = nil, isTableHeader: Bool = false) -> TextSegment {
        if let columns = tableColumns {
            let ranges = MarkdownTableSyntax.cells(source.substring(with: range), base: range.location)
            var cells: [MarkdownTableCell] = [], text = "", offsets: [Int] = []
            for index in columns.indices {
                let cellRange = ranges.indices.contains(index) ? ranges[index] : NSRange(location: NSMaxRange(range), length: 0)
                let cell = materialize(source: source, format: format, id: id, range: cellRange, isCode: false, isHeading: false)
                if index > 0 { text += "\t"; offsets.append(NSMaxRange(cells[index - 1].sourceRange)) }
                text += cell.text; offsets += cell.sourceOffsets
                cells.append(MarkdownTableCell(text: cell.text, sourceRange: cellRange, sourceOffsets: cell.sourceOffsets))
            }
            return TextSegment(id: id, sourceRange: range, text: text, sourceOffsets: offsets, isCode: false, isHeading: false, table: MarkdownTableRow(cells: cells, alignments: columns, isHeader: isTableHeader))
        }
        var text = source.substring(with: range)
        var offsets = Array(range.location..<NSMaxRange(range))
        if format == .markdown && !isCode {
            for regex in patterns {
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
                var current = Array(text.utf16)
                for match in matches.reversed() {
                    current.removeSubrange(match.range.location..<NSMaxRange(match.range))
                    offsets.removeSubrange(match.range.location..<NSMaxRange(match.range))
                }
                text = String(decoding: current, as: UTF16.self)
            }
        }
        return TextSegment(id: id, sourceRange: range, text: text, sourceOffsets: offsets, isCode: isCode, isHeading: isHeading)
    }

    public static func search(_ query: String, in source: String, limit: Int = 200) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = source as NSString
        var result: [NSRange] = [], start = 0
        while start < string.length && result.count < limit {
            let range = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
            if range.location == NSNotFound { break }
            result.append(range); start = NSMaxRange(range)
        }
        return result
    }
}
