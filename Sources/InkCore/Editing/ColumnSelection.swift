import Foundation
import NaturalLanguage

/// 按完整字符计算列，矩形选择不会切开 emoji 或 UTF-16 代理对。
public enum ColumnSelection {
    public struct Point: Equatable, Sendable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }
    /// 短行末尾后的虚拟空格只保存在光标里；真正输入时才补齐，选中或删除不会改写正文。
    public struct Target: Equatable, Sendable {
        public var range: NSRange
        public var virtualSpaces: Int
        public var anchorColumn: Int?
        public var headColumn: Int?
        public init(range: NSRange, virtualSpaces: Int = 0, anchorColumn: Int? = nil, headColumn: Int? = nil) {
            self.range = range; self.virtualSpaces = max(0, virtualSpaces)
            self.anchorColumn = anchorColumn; self.headColumn = headColumn
        }
    }
    public enum Command { case insert(String), paste(String), backspace, deleteForward, cut }
    public struct Result { public var text: String; public var targets: [Target] }

    // 等宽编辑器中汉字和 emoji 占两格，Tab 到下一个四格制表位；整个字符始终作为一个单位。
    public static func displayWidth(of character: Character, column: Int) -> Int {
        if character == "\t" { return 4 - column % 4 }
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let value = scalar.value
        let wide = (0x1100...0x115f).contains(value) || (0x2e80...0xa4cf).contains(value) || (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value) || (0xfe10...0xfe6f).contains(value) || (0xff01...0xff60).contains(value) || (0x20000...0x3fffd).contains(value)
        return wide || scalar.properties.isEmojiPresentation || character.unicodeScalars.contains(where: { $0.value == 0xfe0f }) ? 2 : 1
    }
    private static func columns(_ text: String) -> Int { text.reduce(0) { $0 + displayWidth(of: $1, column: $0) } }
    public static func point(in text: String, at offset: Int, lineIndex: SourceLineIndex? = nil) -> Point {
        let source = text as NSString, lines = lineIndex.flatMap { $0.length == source.length ? $0 : nil } ?? SourceLineIndex(text)
        let offset = min(max(0, offset), source.length), row = lines.line(at: offset)
        return Point(row: row, column: columns(source.substring(with: NSRange(location: lines.starts[row], length: offset - lines.starts[row]))))
    }
    /// 全选覆盖所有行的最大标尺宽度，不能因末行较短而漏掉前面长行的尾部；选中不写入虚拟空格。
    public static func allTargets(in text: String, lineIndex: SourceLineIndex? = nil) -> [Target] {
        let lines = lineIndex.flatMap { $0.length == text.utf16.count ? $0 : nil } ?? SourceLineIndex(text)
        var column = 0, maximum = 0
        for character in text {
            if character.isNewline { maximum = max(maximum, column); column = 0 }
            else { column += displayWidth(of: character, column: column) }
        }
        maximum = max(maximum, column)
        return targets(in: text, from: Point(row: 0, column: 0), to: Point(row: lines.starts.count - 1, column: maximum), lineIndex: lines)
    }
    public static func targets(in text: String, from a: Point, to b: Point, lineIndex: SourceLineIndex? = nil) -> [Target] {
        let source = text as NSString, lines = lineIndex.flatMap { $0.length == source.length ? $0 : nil } ?? SourceLineIndex(text)
        let left = max(0, min(a.column, b.column)), right = max(left, max(a.column, b.column))
        let first = min(max(0, min(a.row, b.row)), lines.starts.count - 1)
        let last = min(max(first, max(a.row, b.row)), lines.starts.count - 1)
        return (first...last).map { row in
            let start = lines.starts[row], end = row + 1 < lines.starts.count ? lines.starts[row + 1] : source.length
            let line = source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines)
            func boundary(_ desired: Int) -> String.Index {
                var index = line.startIndex, column = 0
                while index < line.endIndex && column < desired { column += displayWidth(of: line[index], column: column); index = line.index(after: index) }
                return index
            }
            let lo = boundary(left), hi = boundary(right)
            return Target(range: NSRange(location: start + line[..<lo].utf16.count, length: line[lo..<hi].utf16.count), virtualSpaces: max(0, left - columns(line)), anchorColumn: max(0, a.column), headColumn: max(0, b.column))
        }
    }
    /// 每行保留各自的锚点和活动端：反向 Shift 选择先收缩，再越过锚点；短行只移动虚拟光标。
    public static func move(in text: String, targets: [Target], direction: Int, byWord: Bool = false, extending: Bool = false, lineIndex: SourceLineIndex? = nil) -> [Target] {
        let source = text as NSString, lines = lineIndex.flatMap { $0.length == source.length ? $0 : nil } ?? SourceLineIndex(text)
        return targets.map { target in
            let position = point(in: text, at: target.range.location, lineIndex: lines)
            let row = position.row, start = lines.starts[row], end = row + 1 < lines.starts.count ? lines.starts[row + 1] : source.length
            let line = source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines)
            let anchor = target.anchorColumn ?? (position.column + target.virtualSpaces)
            let head = target.headColumn ?? (point(in: text, at: NSMaxRange(target.range), lineIndex: lines).column + target.virtualSpaces)
            var stops = [0], column = 0, category: Int?
            var wordStops = Set([0])
            var characterColumns: [String.Index: Int] = [:]
            func kind(_ c: Character) -> Int {
                if c.isWhitespace { return 0 }
                if c.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) { return 1 }
                return 2
            }
            for index in line.indices {
                let character = line[index]; characterColumns[index] = column
                let next = kind(character)
                if next != category { wordStops.insert(column) }
                category = next; column += displayWidth(of: character, column: column); stops.append(column)
            }
            // 只分词当前选中的行，汉语按词跳转；不会为一次按键扫描整本长文。
            if byWord {
                let tokenizer = NLTokenizer(unit: .word); tokenizer.string = line
                tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                    if let start = characterColumns[range.lowerBound] { wordStops.insert(start) }; return true
                }
                wordStops.insert(column); stops = wordStops.sorted()
            }
            let forward = direction > 0
            let next: Int
            if !extending && !byWord && anchor != head { next = forward ? max(anchor, head) : min(anchor, head) }
            else if forward { next = stops.first(where: { $0 > head }) ?? min(1_000_000, head + (byWord ? 0 : 1)) }
            else { next = head > column ? (byWord ? column : head - 1) : (stops.last(where: { $0 < head }) ?? 0) }
            return self.targets(in: text, from: Point(row: row, column: extending ? anchor : next), to: Point(row: row, column: next), lineIndex: lines)[0]
        }
    }
    /// Command＋Shift 上下键扩展矩形的行数，保留边缘行的选择方向和虚拟列。
    public static func extendingRows(in text: String, targets: [Target], direction: Int, lineIndex: SourceLineIndex? = nil) -> [Target] {
        guard !targets.isEmpty else { return targets }
        let lines = lineIndex.flatMap { $0.length == text.utf16.count ? $0 : nil } ?? SourceLineIndex(text)
        let sorted = targets.sorted { $0.range.location < $1.range.location }
        let edge = direction > 0 ? sorted.last! : sorted.first!
        let p = point(in: text, at: edge.range.location, lineIndex: lines), row = p.row + (direction > 0 ? 1 : -1)
        guard row >= 0 && row < lines.starts.count else { return targets }
        let a = edge.anchorColumn ?? (p.column + edge.virtualSpaces)
        let b = edge.headColumn ?? (point(in: text, at: NSMaxRange(edge.range), lineIndex: lines).column + edge.virtualSpaces)
        let added = self.targets(in: text, from: Point(row: row, column: a), to: Point(row: row, column: b), lineIndex: lines)
        return direction > 0 ? sorted + added : added + sorted
    }
    public static func edit(_ text: String, targets: [Target], command: Command) -> Result {
        let source = text as NSString
        var targets = targets.sorted { $0.range.location < $1.range.location }
        guard !targets.isEmpty, targets.allSatisfy({ $0.range.location >= 0 && $0.range.length >= 0 && $0.range.location <= source.length && $0.range.length <= source.length - $0.range.location && $0.virtualSpaces <= 1_000_000 }),
              zip(targets, targets.dropFirst()).allSatisfy({ NSMaxRange($0.0.range) <= $0.1.range.location }) else { return Result(text: text, targets: []) }
        var input = text
        var values: [String] = [], affected = targets.count
        switch command {
        case .insert(let value): values = Array(repeating: value, count: targets.count)
        case .paste(let value):
            let rows = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            if rows.count == 1 { values = Array(repeating: rows[0], count: targets.count) }
            else {
                // 多行剪贴板逐行分配，未分配的光标和正文原样保留；多出的行向下延伸，避免丢失内容。
                if rows.count > targets.count, let last = targets.last {
                    let position = point(in: input, at: last.range.location)
                    let column = position.column + last.virtualSpaces
                    let needed = position.row + rows.count - targets.count
                    let count = SourceLineIndex(input).starts.count
                    if needed >= count { input += String(repeating: "\n", count: needed - count + 1) }
                    let right = max(column, point(in: input, at: NSMaxRange(last.range)).column)
                    targets += self.targets(in: input, from: Point(row: position.row + 1, column: column), to: Point(row: needed, column: right))
                }
                values = rows; affected = min(rows.count, targets.count)
            }
        case .backspace, .deleteForward, .cut: values = Array(repeating: "", count: targets.count)
        }
        let working = input as NSString, output = NSMutableString(string: input)
        var edits: [(NSRange, String)] = [], result: [Target] = [], delta = 0
        for (index, target) in targets.enumerated() {
            var range = target.range, value = index < affected ? values[index] : "", virtual = target.virtualSpaces
            let changes = index < affected
            if changes {
                switch command {
                case .insert, .paste:
                    if !value.isEmpty { value = String(repeating: " ", count: virtual) + value; virtual = 0 }
                case .backspace:
                    if range.length == 0 {
                        if virtual > 0 { virtual -= 1 }
                        else if range.location > 0 {
                            let previous = working.rangeOfComposedCharacterSequence(at: range.location - 1)
                            if !working.substring(with: previous).contains(where: { $0.isNewline }) { range = previous }
                        }
                    }
                case .deleteForward:
                    if range.length == 0 && virtual == 0 && range.location < working.length {
                        let next = working.rangeOfComposedCharacterSequence(at: range.location)
                        if !working.substring(with: next).contains(where: { $0.isNewline }) { range = next }
                    }
                case .cut: break
                }
                edits.append((range, value))
                result.append(Target(range: NSRange(location: range.location + delta + value.utf16.count, length: 0), virtualSpaces: virtual))
                delta += value.utf16.count - range.length
            } else {
                var unchanged = target; unchanged.range.location += delta; result.append(unchanged)
            }
        }
        for (range, value) in edits.reversed() { output.replaceCharacters(in: range, with: value) }
        return Result(text: output as String, targets: result)
    }
    public static func ranges(in text: String, from anchor: Int, to end: Int, lineIndex: SourceLineIndex? = nil) -> [NSRange] {
        let source = text as NSString
        // 编辑器已经维护行索引，拖选时复用它，避免每次移动光标都扫描整份长文。
        let lines = lineIndex.flatMap { $0.length == source.length ? $0 : nil } ?? SourceLineIndex(text)
        let a = min(max(0, anchor), source.length), b = min(max(0, end), source.length)
        let rowA = lines.line(at: a), rowB = lines.line(at: b)
        func column(_ row: Int, _ offset: Int) -> Int { source.substring(with: NSRange(location: lines.starts[row], length: offset - lines.starts[row])).count }
        let left = min(column(rowA, a), column(rowB, b)), right = max(column(rowA, a), column(rowB, b))
        return (min(rowA, rowB)...max(rowA, rowB)).map { row in
            let start = lines.starts[row]
            let next = row + 1 < lines.starts.count ? lines.starts[row + 1] : source.length
            let line = source.substring(with: NSRange(location: start, length: next - start)).trimmingCharacters(in: .newlines)
            let first = line.index(line.startIndex, offsetBy: min(left, line.count))
            let last = line.index(line.startIndex, offsetBy: min(right, line.count))
            return NSRange(location: start + line[..<first].utf16.count, length: line[first..<last].utf16.count)
        }
    }
    public static func replacing(_ text: String, ranges: [NSRange], with replacement: String) -> (text: String, carets: [NSRange]) {
        let source = text as NSString
        let sorted = ranges.sorted { $0.location < $1.location }
        guard sorted.allSatisfy({ $0.location >= 0 && $0.length >= 0 && $0.location <= source.length && $0.length <= source.length - $0.location }), zip(sorted, sorted.dropFirst()).allSatisfy({ NSMaxRange($0.0) <= $0.1.location }) else { return (text, []) }
        let result = edit(text, targets: sorted.map { Target(range: $0) }, command: .paste(replacement))
        return (result.text, result.targets.map(\.range))
    }
}
