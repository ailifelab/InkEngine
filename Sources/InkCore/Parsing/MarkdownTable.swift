import Foundation

public enum MarkdownTableAlignment: Sendable, Equatable { case left, center, right }
public struct MarkdownTableCell: Sendable, Equatable {
    public let text: String
    public let sourceRange: NSRange
    public let sourceOffsets: [Int]
}
public struct MarkdownTableRow: Sendable, Equatable {
    public let cells: [MarkdownTableCell]
    public let alignments: [MarkdownTableAlignment]
    public let isHeader: Bool
}

enum MarkdownTableSyntax {
    static func cells(_ line: String, base: Int = 0) -> [NSRange] {
        let units = Array(line.utf16)
        var pipes: [Int] = [], escaped = false, code = false
        for (index, unit) in units.enumerated() {
            if escaped { escaped = false; continue }
            if unit == 92 { escaped = true; continue }
            if unit == 96 { code.toggle() }
            if unit == 124 && !code { pipes.append(index) }
        }
        let text = line as NSString
        var ranges: [NSRange] = [], start = 0
        for end in pipes + [units.count] {
            let part = text.substring(with: NSRange(location: start, length: end - start))
            if !(ranges.isEmpty && start == 0 && end == pipes.first && part.trimmingCharacters(in: .whitespaces).isEmpty) &&
               !(end == units.count && pipes.last == start - 1 && part.trimmingCharacters(in: .whitespaces).isEmpty) {
                var lo = start, hi = end
                while lo < hi && [UInt16(32), 9].contains(units[lo]) { lo += 1 }
                while hi > lo && [UInt16(32), 9].contains(units[hi - 1]) { hi -= 1 }
                ranges.append(NSRange(location: base + lo, length: hi - lo))
            }
            start = end + 1
        }
        return ranges
    }
    static func alignments(_ line: String) -> [MarkdownTableAlignment]? {
        let text = line as NSString, ranges = cells(line)
        guard !ranges.isEmpty else { return nil }
        var result: [MarkdownTableAlignment] = []
        for range in ranges {
            let cell = text.substring(with: range)
            guard cell.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil else { return nil }
            result.append(cell.hasPrefix(":") && cell.hasSuffix(":") ? .center : cell.hasSuffix(":") ? .right : .left)
        }
        return result
    }
}
