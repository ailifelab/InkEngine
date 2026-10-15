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
