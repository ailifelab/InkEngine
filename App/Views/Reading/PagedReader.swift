import SwiftUI
import CoreText
import InkCore
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ReadingLineTarget: Identifiable {
    let id: Int
    let text: String
    let sourceOffset: Int
    let rect: CGRect
}
struct ReadingTableDecoration {
    let rect: CGRect // Core Text coordinates, with the origin at the bottom.
    let columns: Int
    let isHeader: Bool
}
private struct TableRowSpan {
    let range: NSRange
    let columns: Int
    let isHeader: Bool
}

/// Core Text 用同一组行测量和绘制，尺寸变化不裁掉行或丢失页间字符；位置仍对应原文。
// Core Text 与不可变 NSAttributedString 可跨线程读取；构造期间的可变对象
// 在初始化结束前全部冻结，之后没有任何共享写入。系统类型没有声明 Sendable，
// 因此仅对这个只读排版快照手工声明，不把可变编辑器跨执行域传递。
struct ReadingLayout: @unchecked Sendable {
    let text: NSAttributedString
    let sourceOffsets: [Int]
    let pages: [NSRange]
    let size: CGSize
    let nextOffset: Int
    let startOffset: Int
    private let tableRows: [TableRowSpan]
    init(parsed: ParsedText, fontSize: CGFloat, size: CGSize, theme: ReadingTheme, startOffset: Int = 0) {
        let output = NSMutableAttributedString(string: "")
        let startOffset = parsed.readingStart(at: startOffset)
        var offsets: [Int] = []
        let first = parsed.segmentIndex(at: startOffset)
        var shown: [TextSegment] = []
        var tables: [TableRowSpan] = []
        for index in first..<parsed.segments.count {
            if Task.isCancelled { break }
            if output.length >= 7000 { break }
            let segment = parsed.segments[index]
            if let table = segment.table {
                let row = table.attributedRow(fontSize: fontSize, width: size.width, foreground: theme.nativeForeground)
                // 单元格可跨页；从所在视觉行继续，同时保留同一行的其他单元格。
                let rowString = row.text.string as NSString
                var trim = 0
                if index == first, startOffset > segment.sourceRange.location,
                   let position = row.offsets.firstIndex(of: startOffset) {
                    trim = position
                    while trim > 0 && rowString.character(at: trim - 1) != 10 { trim -= 1 }
                }
                let start = output.length
                let portion = NSRange(location: trim, length: row.text.length - trim)
                output.append(row.text.attributedSubstring(from: portion)); offsets += row.offsets.dropFirst(trim)
                let range = NSRange(location: start, length: portion.length)
                shown.append(segment)
                tables.append(TableRowSpan(range: range, columns: table.cells.count, isHeader: table.isHeader))
                continue
            }
            let trim = index == first ? (segment.sourceOffsets.firstIndex(where: { $0 >= startOffset }) ?? segment.text.utf16.count) : 0
            let portion = (segment.text as NSString).substring(from: trim)
            if portion.isEmpty { continue }
            let font = CTFontCreateWithName((segment.isCode ? "Menlo" : "SongtiSC-Regular") as CFString, fontSize * (segment.isHeading ? 1.2 : segment.isCode ? 0.83 : 1), nil)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 7; style.paragraphSpacing = fontSize * 0.65
            style.lineBreakMode = .byWordWrapping
            let continues = index + 1 < parsed.segments.count && NSMaxRange(segment.sourceRange) == parsed.segments[index + 1].sourceRange.location
            let ending = continues ? "" : "\n"
            let item = NSAttributedString(string: portion + ending, attributes: [.font: font, .paragraphStyle: style.copy() as! NSParagraphStyle, .foregroundColor: theme.nativeForeground])
            output.append(item)
            offsets += Array(segment.sourceOffsets.dropFirst(trim)) + (continues ? [] : [NSMaxRange(segment.sourceRange)])
            shown.append(segment)
        }
        self.text = NSAttributedString(attributedString: output); self.sourceOffsets = offsets; self.size = size; self.tableRows = tables
        let setter = CTFramesetterCreateWithAttributedString(output)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var ranges: [NSRange] = [], start = 0
        while start < output.length {
            if Task.isCancelled { break }
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            var length = visible.length
            if let row = tables.first(where: { $0.range.location > start && $0.range.location < start + length && NSMaxRange($0.range) > start + length }) {
                length = row.range.location - start // Move the complete row onto the next page.
            }
            ranges.append(NSRange(location: start, length: length))
            start += length
        }
        self.pages = ranges
        let firstEnd = ranges.first.map(NSMaxRange) ?? offsets.count
        self.nextOffset = firstEnd < offsets.count ? offsets[firstEnd] : (shown.last?.id == parsed.segments.count - 1 ? Int.max : shown.last.map { NSMaxRange($0.sourceRange) } ?? startOffset)
        // 隐藏的 Markdown 前缀不能让首页被误判为后续页，或阻止回到上一章。
        self.startOffset = min(startOffset, offsets.first ?? startOffset)
    }
    func frame(at page: Int, highlight: NSRange? = nil, theme: ReadingTheme) -> CTFrame? {
        guard pages.indices.contains(page) else { return nil }
        let range = pages[page]
        let portion = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        // 朗读高亮只重绘当前可见页，避免整份排版随每一句重复计算。
        if let highlight {
            for index in 0..<range.length where NSLocationInRange(sourceOffsets[range.location + index], highlight) {
                portion.addAttribute(.foregroundColor, value: theme.nativeHighlight, range: NSRange(location: index, length: 1))
            }
        }
        return CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(portion), CFRange(location: 0, length: portion.length), CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
    }

    func lines(at page: Int = 0) -> [ReadingLineTarget] {
        guard pages.indices.contains(page), let frame = frame(at: page, theme: .white) else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let pageRange = pages[page], portion = text.attributedSubstring(from: pageRange).string as NSString
        var targets: [ReadingLineTarget] = []
        for (index, line) in lines.enumerated() {
            let cf = CTLineGetStringRange(line), range = NSRange(location: cf.location, length: cf.length)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let y = size.height - origins[index].y - ascent
            let table = tableRows.first { NSLocationInRange(pageRange.location + range.location, $0.range) }
            let lineText = portion.substring(with: range) as NSString
            var start = 0, column = 0
            let units = Array((lineText as String).utf16)
            for end in table == nil ? [units.count] : (units.indices.filter { units[$0] == 9 } + [units.count]) {
                let part = NSRange(location: start, length: end - start)
                let label = lineText.substring(with: part).trimmingCharacters(in: .whitespacesAndNewlines)
                let position = pageRange.location + range.location + start
                if !label.isEmpty, sourceOffsets.indices.contains(position) {
                    let width = table.map { size.width / CGFloat($0.columns) } ?? size.width
                    let x = table == nil ? 0 : CGFloat(max(0, column - 1)) * width
                    targets.append(ReadingLineTarget(id: targets.count, text: label, sourceOffset: sourceOffsets[position], rect: CGRect(x: x, y: y - 2, width: width, height: ascent + descent + 4)))
                }
                start = end + 1; column += 1
            }
        }
        return targets
    }

    func sourceOffsetForLine(at point: CGPoint) -> Int? {
        lines().first(where: { $0.rect.contains(point) })?.sourceOffset
    }

    func containsSource(_ offset: Int) -> Bool {
        if offset >= startOffset && offset < nextOffset { return true }
        guard let page = pages.first else { return false }
        return sourceOffsets[page.location..<NSMaxRange(page)].contains(offset)
    }

    func tableDecorations(at page: Int = 0) -> [ReadingTableDecoration] {
        guard pages.indices.contains(page), let frame = frame(at: page, theme: .white) else { return [] }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return tableRows.compactMap { row in
            var rect: CGRect?
            for (index, line) in lines.enumerated() {
                let range = CTLineGetStringRange(line)
                guard NSLocationInRange(pages[page].location + range.location, row.range) else { continue }
                var ascent: CGFloat = 0, descent: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let bounds = CGRect(x: 0, y: origins[index].y - descent - 2, width: size.width, height: ascent + descent + 4)
                rect = rect.map { $0.union(bounds) } ?? bounds
            }
            return rect.map { ReadingTableDecoration(rect: $0, columns: row.columns, isHeader: row.isHeader) }
        }
    }
}

private extension MarkdownTableRow {
    func attributedRow(fontSize: CGFloat, width: CGFloat, foreground: Any) -> (text: NSAttributedString, offsets: [Int]) {
        let output = NSMutableAttributedString(string: ""), columnWidth = width / CGFloat(max(1, cells.count))
        let font = CTFontCreateWithName((isHeader ? "SongtiSC-Bold" : "SongtiSC-Regular") as CFString, fontSize * 0.8, nil)
        var wrapped: [[(String, [Int])]] = []
        for cell in cells {
            let ns = cell.text as NSString
            let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: [.font: font]))
            var fragments: [(String, [Int])] = [], offset = 0
            while offset < ns.length {
                let length = max(1, CTTypesetterSuggestClusterBreak(typesetter, offset, max(12, columnWidth - 12)))
                let count = min(length, ns.length - offset)
                fragments.append((ns.substring(with: NSRange(location: offset, length: count)), Array(cell.sourceOffsets[offset..<offset + count])))
                offset += count
            }
            wrapped.append(fragments)
        }
        let style = NSMutableParagraphStyle(); style.lineSpacing = 2; style.paragraphSpacing = 0
        style.lineBreakMode = .byClipping
        style.tabStops = alignments.enumerated().map { index, alignment in
            let location = CGFloat(index) * columnWidth + (alignment == .center ? columnWidth / 2 : alignment == .right ? columnWidth - 6 : 6)
            return NSTextTab(textAlignment: alignment == .center ? .center : alignment == .right ? .right : .left, location: location, options: [:])
        }
        style.defaultTabInterval = columnWidth
        var offsets: [Int] = []
        for line in 0..<max(1, wrapped.map(\.count).max() ?? 1) {
            var value = "", mapping: [Int] = []
            let anchor = wrapped.compactMap { $0.indices.contains(line) ? $0[line].1.first : nil }.first ?? cells.first?.sourceRange.location ?? 0
            for index in cells.indices {
                value += "\t"; mapping.append(anchor)
                if wrapped[index].indices.contains(line) { value += wrapped[index][line].0; mapping += wrapped[index][line].1 }
            }
            value += "\n"; mapping.append(anchor)
            output.append(NSAttributedString(string: value, attributes: [.font: font, .paragraphStyle: style.copy() as! NSParagraphStyle, .foregroundColor: foreground]))
            offsets += mapping
        }
        return (output, offsets)
    }
}

private func drawTables(_ tables: [ReadingTableDecoration], in context: CGContext, theme: ReadingTheme) {
    context.setStrokeColor(theme.nativeForeground.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(0.5)
    for row in tables {
        if row.isHeader { context.setFillColor(theme.nativeTableHeader.cgColor); context.fill(row.rect) }
        context.stroke(row.rect)
        for column in 1..<row.columns {
            let x = row.rect.minX + row.rect.width * CGFloat(column) / CGFloat(row.columns)
            context.move(to: CGPoint(x: x, y: row.rect.minY)); context.addLine(to: CGPoint(x: x, y: row.rect.maxY))
        }
        context.strokePath()
    }
}

extension ReadingTheme {
    #if os(iOS)
    var nativeForeground: UIColor { UIColor(foreground) }
    var nativeHighlight: UIColor { UIColor(highlight) }
    var nativeTableHeader: UIColor { UIColor(sidebar) }
    #else
    var nativeForeground: NSColor { NSColor(foreground) }
    var nativeHighlight: NSColor { NSColor(highlight) }
    var nativeTableHeader: NSColor { NSColor(sidebar) }
    #endif
}

#if os(iOS)
private final class PaperTextView: UIView {
    var tables: [ReadingTableDecoration] = []
    var theme = ReadingTheme.white
    var frameToDraw: CTFrame? { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let frameToDraw else { return }
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        drawTables(tables, in: context, theme: theme)
        CTFrameDraw(frameToDraw, context)
    }
}
struct PaperText: UIViewRepresentable {
    let frame: CTFrame?
    var tables: [ReadingTableDecoration] = []
    var theme = ReadingTheme.white
    func makeUIView(context: Context) -> UIView { let view = PaperTextView(); view.backgroundColor = .clear; view.isOpaque = false; return view }
    func updateUIView(_ uiView: UIView, context: Context) { guard let view = uiView as? PaperTextView else { return }; view.tables = tables; view.theme = theme; view.frameToDraw = frame }
}
#else
private final class PaperTextView: NSView {
    var tables: [ReadingTableDecoration] = []
    var theme = ReadingTheme.white
    var frameToDraw: CTFrame? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let frameToDraw else { return }
        context.textMatrix = .identity; drawTables(tables, in: context, theme: theme); CTFrameDraw(frameToDraw, context)
    }
}
struct PaperText: NSViewRepresentable {
    let frame: CTFrame?
    var tables: [ReadingTableDecoration] = []
    var theme = ReadingTheme.white
    func makeNSView(context: Context) -> NSView { PaperTextView() }
    func updateNSView(_ nsView: NSView, context: Context) { guard let view = nsView as? PaperTextView else { return }; view.tables = tables; view.theme = theme; view.frameToDraw = frame }
}
#endif
