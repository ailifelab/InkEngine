import Foundation

public struct ReadingBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var offset: Int
    public var context: String
    public var updatedAt: Date
    public var deletedAt: Date?
    public init(name: String, offset: Int, content: String) {
        id = UUID(); self.name = String(name.prefix(200)); self.offset = min(max(0, offset), content.utf16.count)
        context = Self.context(in: content, at: self.offset); updatedAt = Date()
    }
    public static func context(in content: String, at offset: Int) -> String {
        let text = content as NSString
        let start = min(max(0, offset), text.length)
        // 两端原生编辑器都使用 UTF-16 位置，NSString 保持同一坐标体系。
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(60, text.length - start)))
        return text.substring(with: range)
    }
}

/// 用共同前后缀定位未改动区；改动区内优先查找原上下文，否则退回改动开始处。
/// 编辑光标、阅读位置和书签分别映射，不把编辑选择当作朗读进度。
public struct AnchorRelocation: Sendable {
    private let newText: String
    private let prefix: Int
    private let oldEnd: Int
    private let newEnd: Int
    private let newLength: Int
    public init(old: String, new: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var head = 0
        while head < min(a.count, b.count), a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        prefix = head; oldEnd = a.count - tail; newEnd = b.count - tail; newLength = b.count; newText = new
    }
    public func map(_ offset: Int, context: String = "") -> Int {
        let result: Int
        if offset < prefix { result = offset }
        else if offset >= oldEnd { result = offset + newEnd - oldEnd }
        else if !context.isEmpty {
            let text = newText as NSString
            let range = text.range(of: context, options: [], range: NSRange(location: 0, length: text.length))
            result = range.location == NSNotFound ? prefix : range.location
        } else { result = prefix }
        return min(max(0, result), newLength)
    }
}
