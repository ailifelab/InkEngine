import Foundation

/// 两种原生编辑器共用 UTF-16 逻辑行索引，CRLF 算一次换行。
/// 软换行不改变行号，文末换行保留空行；按位置查行使用二分定位。
public struct SourceLineIndex: Sendable {
    public let starts: [Int]
    public let length: Int

    public init(_ text: String) {
        var starts = [0], offset = 0, afterCR = false
        for unit in text.utf16 {
            offset += 1
            if unit == 10 && afterCR { starts[starts.count - 1] = offset }
            else if unit == 10 || unit == 13 || unit == 0x85 || unit == 0x2028 || unit == 0x2029 {
                starts.append(offset)
            }
            afterCR = unit == 13
        }
        self.starts = starts; length = offset
    }

    private init(starts: [Int], length: Int) { self.starts = starts; self.length = length }

    /// 单次原生字符编辑的索引结果；行区间供行宽缓存同步增删，均使用逻辑行而非软换行。
    public struct Update: Sendable {
        public let index: SourceLineIndex
        public let previousLineCount: Int
        public let replacedLines: Range<Int>
        public let insertedLines: Range<Int>
    }

    /// 根据编辑前 UTF-16 范围和编辑后文本增量更新索引；参数不一致时返回 nil，由调用方完整重建。
    /// 扫描范围包含相邻行，以正确处理 CR/LF 合并、拆开和文末空行；不会拆分或修改正文字符。
    public func applyingEdit(in range: NSRange, replacementLength: Int, updatedText: NSString) -> Update? {
        guard range.location >= 0, range.location <= length, range.length >= 0,
              range.length <= length - range.location, replacementLength >= 0,
              updatedText.length >= replacementLength,
              updatedText.length - replacementLength == length - range.length else { return nil }
        let first = max(0, line(at: range.location) - 1)
        let after = min(starts.count, line(at: range.location + range.length) + 2)
        let oldEnd = after < starts.count ? starts[after] : length
        let start = starts[first], delta = replacementLength - range.length
        let newEnd = oldEnd + delta
        let fragment = SourceLineIndex(updatedText.substring(with: NSRange(location: start, length: newEnd - start)))
        let middle = fragment.starts.map { start + $0 }.filter { after == starts.count || $0 < newEnd }
        var result: [Int] = []
        result.reserveCapacity(starts.count - (after - first) + middle.count)
        result.append(contentsOf: starts[..<first])
        result.append(contentsOf: middle)
        result.append(contentsOf: starts[after...].map { $0 + delta })
        return Update(index: SourceLineIndex(starts: result, length: updatedText.length),
                      previousLineCount: starts.count, replacedLines: first..<after,
                      insertedLines: first..<(first + middle.count))
    }

    public func line(at offset: Int) -> Int {
        let offset = min(length, max(0, offset))
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
