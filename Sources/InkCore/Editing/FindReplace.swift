import Foundation

public struct FindOptions: Sendable, Equatable {
    public var regularExpression = false
    public var caseSensitive = false
    public var escapes = false
    public init(regularExpression: Bool = false, caseSensitive: Bool = false, escapes: Bool = false) {
        self.regularExpression = regularExpression; self.caseSensitive = caseSensitive; self.escapes = escapes
    }
}
public enum FindReplace {
    public static func unescape(_ value: String) -> String {
        var output = "", iterator = value.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let next = iterator.next() else { output.append(c); continue }
            switch next {
            case "n": output.append("\n")
            case "r": output.append("\r")
            case "t": output.append("\t")
            case "\\": output.append("\\")
            default: output.append("\\"); output.append(next)
            }
        }
        return output
    }
    private static func expression(_ query: String, options: FindOptions) throws -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        let text = options.escapes && !options.regularExpression ? unescape(query) : query
        let pattern = options.regularExpression ? text : NSRegularExpression.escapedPattern(for: text)
        return try NSRegularExpression(pattern: pattern, options: options.caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive])
    }
    public static func matches(_ query: String, in text: String, options: FindOptions, limit: Int = 2000) throws -> [NSRange] {
        guard limit > 0, let regex = try expression(query, options: options) else { return [] }
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: text.utf16.count)) { result, _, stop in
            if let result { ranges.append(result.range) }
            if ranges.count >= limit { stop.pointee = true }
        }
        return ranges
    }
    public static func replacing(_ query: String, with replacement: String, in text: String, options: FindOptions, range: NSRange? = nil) throws -> (text: String, count: Int) {
        guard let regex = try expression(query, options: options) else { return (text, 0) }
        let searchRange = range ?? NSRange(location: 0, length: text.utf16.count)
        guard searchRange.location >= 0, NSMaxRange(searchRange) <= text.utf16.count else { return (text, 0) }
        let value = options.escapes ? unescape(replacement) : replacement
        // 原生替换避免为数百万处匹配保留对象数组，尤其是零长度正则。
        let count = regex.numberOfMatches(in: text, range: searchRange)
        let template = options.regularExpression ? value : NSRegularExpression.escapedTemplate(for: value)
        return (regex.stringByReplacingMatches(in: text, range: searchRange, withTemplate: template), count)
    }
}
