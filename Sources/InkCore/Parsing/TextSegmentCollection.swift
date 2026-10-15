import Foundation

/// 索引只保存段落范围，不为整本小说创建逐字映射。
/// 阅读与合成按需展开段落，缓存最多 64 段；共享缓存的读写由锁保护。
public struct TextSegmentCollection: RandomAccessCollection, Sendable, Equatable {
    public typealias Index = Int
    public typealias Element = TextSegment
    struct Span: Sendable {
        let range: NSRange; let isCode: Bool; let isHeading: Bool
        var tableColumns: [MarkdownTableAlignment]? = nil
        var isTableHeader = false
    }
    final class Storage: @unchecked Sendable {
        let id = UUID()
        let source: NSString
        let format: TextFormat
        let spans: [Span]
        let fixed: [TextSegment]?
        private let lock = NSLock()
        private var cache: [Int: TextSegment] = [:]
        private var order: [Int] = []
        init(source: String, format: TextFormat, spans: [Span]) { self.source = source as NSString; self.format = format; self.spans = spans; fixed = nil }
        init(fixed: [TextSegment]) { self.fixed = fixed; source = ""; format = .txt; spans = [] }
        var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
        func segment(_ index: Int) -> TextSegment {
            if let fixed { return fixed[index] }
            lock.lock(); let found = cache[index]; lock.unlock()
            if let found { return found }
            let span = spans[index]
            let value = TextParser.materialize(source: source, format: format, id: index, range: span.range, isCode: span.isCode, isHeading: span.isHeading, tableColumns: span.tableColumns, isTableHeader: span.isTableHeader)
            lock.lock(); defer { lock.unlock() }
            if cache[index] == nil {
                if order.count >= 64 { cache.removeValue(forKey: order.removeFirst()) }
                cache[index] = value; order.append(index)
            }
            return value
        }
    }
    private let storage: Storage
    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.fixed?.count ?? storage.spans.count }
    public subscript(position: Int) -> TextSegment { storage.segment(position) }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.id == rhs.storage.id }
    public func sourceRange(at index: Int) -> NSRange { storage.fixed?[index].sourceRange ?? storage.spans[index].range }
    public var materializedSegmentCount: Int { storage.fixed?.count ?? storage.cachedCount }
    init(source: String, format: TextFormat, spans: [Span]) { storage = Storage(source: source, format: format, spans: spans) }
    init(_ segments: [TextSegment]) { storage = Storage(fixed: segments) }
}
