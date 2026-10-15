import SwiftUI
import InkCore
#if os(macOS)
import AppKit
typealias ChromeView = NSView
private typealias ChromeFont = NSFont
typealias ChromeColor = NSColor
#else
import UIKit
typealias ChromeView = UIView
private typealias ChromeFont = UIFont
typealias ChromeColor = UIColor
#endif

private let paper = ChromeColor(red: 0.99, green: 0.987, blue: 0.975, alpha: 1)
private let rulerPaper = ChromeColor(red: 0.955, green: 0.951, blue: 0.933, alpha: 1)
private let rulerInk = ChromeColor(white: 0.40, alpha: 1)
private let editorExtent: CGFloat = 1_000_000_000

struct EditorLineLabel { var number: Int; var y: CGFloat; var height: CGFloat }

/// 依据 TextKit 的实际行片段，仅绘制可见区的逻辑行号。
private func visibleLabels(manager: NSLayoutManager, container: NSTextContainer, index: SourceLineIndex,
                           viewport: CGRect, inset: CGPoint) -> [EditorLineLabel] {
    let textRect = viewport.offsetBy(dx: -inset.x, dy: -inset.y)
    let glyphs = manager.glyphRange(forBoundingRect: textRect, in: container)
    var labels: [EditorLineLabel] = []
    manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
        guard range.length > 0 else { return }
        let offset = manager.characterIndexForGlyph(at: range.location)
        let line = index.line(at: offset)
        guard offset == index.starts[line] else { return }
        labels.append(EditorLineLabel(number: line + 1, y: rect.minY + inset.y - viewport.minY, height: rect.height))
    }
    let visibleCharacters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    let firstUnlaid = manager.firstUnlaidCharacterIndex()
    let finalLineVisible = NSMaxRange(visibleCharacters) >= index.length
        || (firstUnlaid >= index.length && manager.extraLineFragmentRect.offsetBy(dx: inset.x, dy: inset.y).intersects(viewport))
    if index.length == 0 || (index.starts.last == index.length && finalLineVisible) {
        // 宽度改变时 TextKit 可能保留旧的额外行片段；末尾空行按真实换行符的下一行绘制。
        // 只在文末可见时查询最后一个字形，避免首页行号触发整本文稿的排版。
        let rect: CGRect
        if index.length > 0 {
            let glyph = manager.glyphIndexForCharacter(at: index.length - 1)
            let previous = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            rect = CGRect(x: 0, y: previous.maxY, width: 0, height: previous.height)
        } else { rect = CGRect(x: 0, y: 0, width: 0, height: manager.extraLineFragmentRect.height) }
        let y = rect.minY + inset.y - viewport.minY
        if y >= -40 && y < viewport.height { labels.append(EditorLineLabel(number: index.starts.count, y: y, height: rect.height)) }
    }
    return labels
}

final class EditorMarginView: ChromeView {
    var paperColor = rulerPaper
    var inkColor = rulerInk
    var columnRuler = false
    var labels: [EditorLineLabel] = []
    var fontSize: CGFloat = 21
    var textOrigin: CGFloat = 0
    var lineCount = 1
    var firstColumn = 1
    #if os(macOS)
    override var isFlipped: Bool { true }
    #endif
    func refresh() {
        let visible = labels.prefix(60).map { String($0.number) }.joined(separator: "、")
        let value = columnRuler ? "第 \(firstColumn) 列起" : "\(lineCount) 行，可见：\(visible)"
        #if os(macOS)
        needsDisplay = true
        setAccessibilityValue(value)
        #else
        setNeedsDisplay()
        accessibilityValue = value
        #endif
    }
    override func draw(_ rect: CGRect) {
        #if os(macOS)
        paperColor.setFill(); bounds.fill()
        #else
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(paperColor.cgColor); context.fill(bounds)
        #endif
        let font = ChromeFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inkColor]
        if columnRuler {
            let advance = ("0" as NSString).size(withAttributes: [.font: ChromeFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]).width
            guard advance > 0 else { return }
            let first = max(0, Int(floor(-textOrigin / advance)))
            let last = max(first, Int(ceil((bounds.width - textOrigin) / advance)))
            for cell in first...last {
                let x = textOrigin + CGFloat(cell) * advance
                let major = cell == 0 || (cell + 1).isMultiple(of: 10)
                if major { (String(cell + 1) as NSString).draw(at: CGPoint(x: x, y: 1), withAttributes: attributes) }
                let tick = CGRect(x: x, y: bounds.height - (major ? 7 : 3), width: 0.5, height: major ? 7 : 3)
                #if os(macOS)
                inkColor.withAlphaComponent(0.35).setFill(); tick.fill()
                #else
                context.setFillColor(inkColor.withAlphaComponent(0.35).cgColor); context.fill(tick)
                #endif
            }
        } else {
            for label in labels {
                let text = String(label.number) as NSString, size = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: bounds.width - 9 - size.width, y: label.y + max(0, (label.height - size.height) / 2)), withAttributes: attributes)
            }
        }
    }
}

#if os(macOS)
final class EditorHost: NSView {
    let scroll = NSScrollView()
    let gutter = EditorMarginView(), ruler = EditorMarginView()
    var index = SourceLineIndex("")
    var wrapsLines = false
    var editor: NSTextView { scroll.documentView as! NSTextView }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.backgroundColor = paper
        ruler.columnRuler = true
        for view in [gutter, ruler] {
            view.setAccessibilityElement(true); view.setAccessibilityRole(.staticText)
        }
        gutter.setAccessibilityIdentifier("editorLineNumbers"); gutter.setAccessibilityLabel("行号")
        ruler.setAccessibilityIdentifier("editorColumnRuler"); ruler.setAccessibilityLabel("列标尺")
        addSubview(scroll); addSubview(gutter); addSubview(ruler)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        guard scroll.documentView != nil else { return }
        let width = max(40, CGFloat(String(index.starts.count).count) * 8 + 18)
        gutter.frame = CGRect(x: 0, y: 24, width: width, height: max(0, bounds.height - 24))
        ruler.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: 24)
        scroll.frame = CGRect(x: width, y: 24, width: ruler.frame.width, height: gutter.frame.height)
        resizeText(); refreshMargins()
    }
    func updateSource(_ text: String) { index = SourceLineIndex(text); needsLayout = true; refreshMargins() }
    func resizeText() {
        let size = scroll.contentSize
        guard size.width > 0, let container = editor.textContainer else { return }
        scroll.hasHorizontalScroller = !wrapsLines
        editor.isHorizontallyResizable = !wrapsLines
        editor.autoresizingMask = wrapsLines ? [.width] : []
        editor.minSize = CGSize(width: size.width, height: size.height)
        container.widthTracksTextView = wrapsLines
        let width = wrapsLines ? max(1, size.width - editor.textContainerInset.width * 2) : editorExtent
        if container.containerSize.width != width { container.containerSize = CGSize(width: width, height: editorExtent) }
        if wrapsLines { editor.setFrameSize(CGSize(width: size.width, height: max(size.height, editor.frame.height))) }
        let origin = scroll.contentView.bounds.origin
        if let manager = editor.layoutManager {
            // 只排版可见区域。强制整个容器会让数百万字的文稿在每次输入时重排。
            manager.ensureLayout(forBoundingRect: editor.visibleRect, in: container)
            let used = manager.usedRect(for: container)
            let width = wrapsLines ? size.width : max(size.width, ceil(used.maxX + editor.textContainerInset.width * 2))
            let lineHeight = editor.font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 26
            let estimatedHeight = wrapsLines ? editor.frame.height : CGFloat(index.starts.count) * lineHeight + editor.textContainerInset.height * 2
            let height = max(size.height, estimatedHeight, ceil(max(used.maxY, manager.extraLineFragmentRect.maxY) + editor.textContainerInset.height * 2))
            editor.setFrameSize(CGSize(width: width, height: height))
        }
        scroll.contentView.scroll(to: CGPoint(x: wrapsLines ? 0 : min(origin.x, max(0, editor.frame.width - size.width)),
                                             y: min(origin.y, max(0, editor.frame.height - size.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func refreshMargins() {
        guard let manager = editor.layoutManager, let container = editor.textContainer else { return }
        let viewport = scroll.contentView.bounds
        gutter.labels = visibleLabels(manager: manager, container: container, index: index, viewport: viewport, inset: editor.textContainerOrigin)
        gutter.lineCount = index.starts.count
        ruler.fontSize = editor.font?.pointSize ?? 21
        ruler.textOrigin = editor.textContainerOrigin.x + container.lineFragmentPadding - viewport.minX
        let advance = ("0" as NSString).size(withAttributes: [.font: ChromeFont.monospacedSystemFont(ofSize: ruler.fontSize, weight: .regular)]).width
        ruler.firstColumn = max(1, Int(floor(-ruler.textOrigin / max(1, advance))) + 1)
        gutter.refresh(); ruler.refresh()
    }
}
#else
/// 使用 UITextView 保留原生选区、输入法组合文本、撤销和双向滚动。
final class SourceTextView: ColumnTextView {
    var wrapsLines = false
    var refreshingSize = false
    private var sourceWidth: CGFloat = 0
    override var contentSize: CGSize {
        get { super.contentSize }
        set { super.contentSize = CGSize(width: max(bounds.width, sourceWidth), height: newValue.height) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        refreshTextSize()
    }
    func refreshTextSize() {
        guard !refreshingSize, bounds.width > 0 else { return }
        refreshingSize = true
        defer { refreshingSize = false }
        textContainer.widthTracksTextView = false
        let width = wrapsLines ? max(1, bounds.width - textContainerInset.left - textContainerInset.right) : editorExtent
        if textContainer.size.width != width { textContainer.size = CGSize(width: width, height: editorExtent) }
        layoutManager.ensureLayout(forBoundingRect: CGRect(origin: contentOffset, size: bounds.size), in: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let desired = CGSize(width: wrapsLines ? bounds.width : max(bounds.width, ceil(used.maxX + textContainerInset.left + textContainerInset.right)),
                             height: max(bounds.height, super.contentSize.height, ceil(used.maxY + textContainerInset.top + textContainerInset.bottom)))
        sourceWidth = desired.width
        if contentSize != desired { contentSize = desired }
        showsHorizontalScrollIndicator = !wrapsLines
        if wrapsLines && contentOffset.x != 0 { contentOffset.x = 0 }
    }
}
final class EditorHost: UIView {
    let editor = SourceTextView()
    let gutter = EditorMarginView(), ruler = EditorMarginView()
    var index = SourceLineIndex("")
    var wrapsLines = false { didSet { editor.wrapsLines = wrapsLines } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = rulerPaper
        ruler.columnRuler = true
        for view in [gutter, ruler] { view.isAccessibilityElement = true; view.isUserInteractionEnabled = false }
        gutter.accessibilityIdentifier = "editorLineNumbers"; gutter.accessibilityLabel = "行号"
        ruler.accessibilityIdentifier = "editorColumnRuler"; ruler.accessibilityLabel = "列标尺"
        addSubview(editor); addSubview(gutter); addSubview(ruler)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(40, CGFloat(String(index.starts.count).count) * 8 + 18)
        gutter.frame = CGRect(x: 0, y: 24, width: width, height: max(0, bounds.height - 24))
        ruler.frame = CGRect(x: width, y: 0, width: max(0, bounds.width - width), height: 24)
        editor.frame = CGRect(x: width, y: 24, width: ruler.frame.width, height: gutter.frame.height)
        resizeText(); refreshMargins()
    }
    func updateSource(_ text: String) { index = SourceLineIndex(text); setNeedsLayout(); refreshMargins() }
    func resizeText() { editor.refreshTextSize() }
    func refreshMargins() {
        let viewport = CGRect(origin: editor.contentOffset, size: editor.bounds.size)
        let inset = CGPoint(x: editor.textContainerInset.left, y: editor.textContainerInset.top)
        gutter.labels = visibleLabels(manager: editor.layoutManager, container: editor.textContainer, index: index, viewport: viewport, inset: inset)
        gutter.lineCount = index.starts.count
        ruler.fontSize = editor.font?.pointSize ?? 21
        ruler.textOrigin = inset.x + editor.textContainer.lineFragmentPadding - viewport.minX
        let advance = ("0" as NSString).size(withAttributes: [.font: ChromeFont.monospacedSystemFont(ofSize: ruler.fontSize, weight: .regular)]).width
        ruler.firstColumn = max(1, Int(floor(-ruler.textOrigin / max(1, advance))) + 1)
        gutter.refresh(); ruler.refresh()
    }
}
#endif


extension EditorHost {
    func applyTheme(_ theme: ReadingTheme) {
        #if os(macOS)
        let surface = NSColor(theme.background), margin = NSColor(theme.sidebar), ink = NSColor(theme.foreground)
        wantsLayer = true; layer?.backgroundColor = surface.cgColor
        scroll.backgroundColor = surface
        #else
        let surface = UIColor(theme.background), margin = UIColor(theme.sidebar), ink = UIColor(theme.foreground)
        backgroundColor = surface
        #endif
        editor.backgroundColor = surface; editor.textColor = ink
        for view in [gutter, ruler] { view.paperColor = margin; view.inkColor = ink.withAlphaComponent(0.6); view.refresh() }
    }
}
