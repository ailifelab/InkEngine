import SwiftUI
import InkCore
#if DEBUG
/// 大文件专项计时仅在隔离测试参数下启用；不改变正文、输入法或排版行为。
@MainActor enum EditorPerformanceTrace {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--editor-performance-ui-testing")
    private static var counts: [String: Int] = [:]
    private static let outputQueue = DispatchQueue(label: "InkEngine.EditorPerformanceTrace", qos: .utility)
    private static let outputURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-performance.log")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }()
    static func start() -> TimeInterval? { enabled ? ProcessInfo.processInfo.systemUptime : nil }
    static func finish(_ phase: String, _ start: TimeInterval?, units: Int = 0) {
        guard let start else { return }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        counts[phase, default: 0] += 1
        let count = counts[phase, default: 0]
        guard count <= 12 || milliseconds >= 16 else { return }
        let line = "EDITOR_PERF phase=\(phase) ms=\(milliseconds) units=\(units) count=\(count)\n"
        write(line)
    }
    /// 仅专项调试记录原生状态，不记录正文；用于核对真机输入法、撤销与光标变化。
    static func state(_ phase: String, length: Int, selection: NSRange, marked: Bool, canUndo: Bool, canRedo: Bool) {
        guard enabled else { return }
        let key = "state-" + phase
        counts[key, default: 0] += 1
        guard counts[key, default: 0] <= 200 else { return }
        write("EDITOR_STATE phase=\(phase) length=\(length) selection=\(selection.location),\(selection.length) marked=\(marked) canUndo=\(canUndo) canRedo=\(canRedo)\n")
    }
    /// 将计时和状态异步写入同一日志，调用线程不等待磁盘操作。
    private static func write(_ line: String) {
        FileHandle.standardOutput.write(Data(line.utf8))
        let url = outputURL, data = Data(line.utf8)
        // 异步记录到隔离容器，真机与模拟器均可取回；计时线程不等待磁盘写入。
        outputQueue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
}
#endif
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
        let value = columnRuler ? L10n.tr("第 \(firstColumn) 列起") : L10n.tr("\(lineCount) 行，可见：\(visible)")
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
    private var indexedSource = ""
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
        gutter.setAccessibilityIdentifier("editorLineNumbers"); gutter.setAccessibilityLabel(L10n.tr("行号"))
        ruler.setAccessibilityIdentifier("editorColumnRuler"); ruler.setAccessibilityLabel(L10n.tr("列标尺"))
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
    func updateSource(_ text: String) { guard indexedSource != text else { return }; indexedSource = text; index = SourceLineIndex(text); needsLayout = true; refreshMargins() }
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
/// 原生单次编辑的 UTF-16 元数据；组合输入或批量修改无法精确对应时使用完整刷新。
struct EditorTextChange {
    let range: NSRange
    let replacementLength: Int
    let previousLength: Int
}
/// 使用 UITextView 保留原生选区、输入法组合文本、撤销和双向滚动。
final class SourceTextView: ColumnTextView {
    var appliedTheme: ReadingTheme?
    var wrapsLines = false { didSet { if oldValue != wrapsLines { resumeCaretTracking() } } }
    var refreshingSize = false
    private var sourceWidth: CGFloat = 0
    private let lineWidthCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>(); cache.countLimit = 4096; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var extentNeedsMeasurement = true
    private var extentColumnMode = false
    private var extentFont: UIFont?
    private var extentTabInterval: CGFloat = 0
    private var naturalLineWidth: CGFloat = 0
    private var measuredLineWidths: [CGFloat] = []
    private var pendingLineUpdate: SourceLineIndex.Update?
    private var laidOutSize = CGSize.zero
    private var laidOutSelection = NSRange(location: NSNotFound, length: 0)
    private var laidOutTextLength = -1
    private(set) var maintainingViewport = false
    private var userScrolled = false
    private var userViewport = CGPoint.zero
    #if DEBUG
    private var viewportRestoreCount = 0
    /// 隔离 UI 验证只读手势目标与重排恢复次数，不参与生产布局。
    var viewportDiagnostics: String { "userScrolled=\(userScrolled);userViewport=\(userViewport);viewportRestores=\(viewportRestoreCount);viewportTracking=\(isTracking),\(isDragging),\(isDecelerating);layoutSignature=\(laidOutSize),\(laidOutSelection),\(laidOutTextLength)" }
    #endif
    override var contentSize: CGSize {
        get { super.contentSize }
        set { super.contentSize = CGSize(width: max(bounds.width, sourceWidth), height: newValue.height) }
    }
    override func layoutSubviews() {
        // TextKit 在重算内容尺寸时会恢复旧的插入点滚动位置，即使用户刚手动翻到别处。
        // 只有用户主动拖动过、且视口尺寸、选区和正文长度均未改变时才保留当前位置；输入、跳转和
        // 键盘缩放仍交给 UITextView 原生处理，不能阻止它显露新的插入点。
        let unchanged = bounds.size == laidOutSize && selectedRange == laidOutSelection && textStorage.length == laidOutTextLength
        if !unchanged { userScrolled = false }
        let preserve = userScrolled && unchanged
        maintainingViewport = preserve
        defer { maintainingViewport = false }
        super.layoutSubviews()
        refreshTextSize()
        // 原生控件可能在进入本次 layout 前就改过 offset，因此使用手势实际记录的位置，
        // 不能把本次 layout 入口的旧位置误当成用户目标。
        if preserve && contentOffset != userViewport {
            #if DEBUG
            viewportRestoreCount += 1
            #endif
            setContentOffset(userViewport, animated: false)
        }
        laidOutSize = bounds.size; laidOutSelection = selectedRange; laidOutTextLength = textStorage.length
    }
    /// 只保护用户主动拖动后的视口，不拦截输入后由系统延迟执行的插入点显露。
    func beginUserScrolling() {
        userScrolled = true; userViewport = contentOffset
        laidOutSize = bounds.size; laidOutSelection = selectedRange; laidOutTextLength = textStorage.length
    }
    /// 只记录真实拖动和惯性滚动，排除布局恢复产生的内部偏移，避免覆盖用户目标。
    func recordUserScrolling() {
        guard userScrolled, !maintainingViewport, isTracking || isDragging || isDecelerating else { return }
        userViewport = contentOffset
    }
    /// 只让真实手势请求新可见区的着色；内部恢复旧位置不能再触发着色和重排循环。
    var shouldHighlightScrolledViewport: Bool {
        !maintainingViewport && (!userScrolled || isTracking || isDragging || isDecelerating)
    }
    /// 新的正文输入重新把滚动控制交还系统，保证文尾打字仍能看到光标。
    func resumeCaretTracking() { userScrolled = false; navigationHost?.requestHorizontalCaretReveal() }
    /// 横向由宿主滚动；UITextView 自身只接受纵向拖动，避免两个滚动器争抢手势。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
    /// 正文变化后失效横向尺寸；着色和滚动不重新测量整篇文稿。
    func invalidateTextExtent(_ update: SourceLineIndex.Update? = nil) {
        pendingLineUpdate = extentNeedsMeasurement ? nil : update
        extentNeedsMeasurement = true
    }
    /// 按逻辑行的实际字体与制表位测宽。缓存未修改的行，避免每次输入重复进行字体排版。
    private func unwrappedLineWidth() -> CGFloat {
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("lineWidth", performanceStart) }
        #endif
        let currentFont = font ?? UIFont.monospacedSystemFont(ofSize: 21, weight: .regular)
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        if extentFont != currentFont || extentTabInterval != paragraph.defaultTabInterval || extentColumnMode != columnMode {
            lineWidthCache.removeAllObjects(); measuredLineWidths.removeAll(); pendingLineUpdate = nil; extentNeedsMeasurement = true
        }
        guard extentNeedsMeasurement else { return naturalLineWidth }
        let attributes: [NSAttributedString.Key: Any] = [.font: currentFont, .paragraphStyle: paragraph]
        let source = textStorage.mutableString
        let lines = navigationHost?.index ?? SourceLineIndex(source as String)
        func measure(_ row: Int) -> CGFloat {
            let start = lines.starts[row]
            var end = row + 1 < lines.starts.count ? lines.starts[row + 1] : lines.length
            while end > start, [10, 13, 0x85, 0x2028, 0x2029].contains(Int(source.character(at: end - 1))) { end -= 1 }
            let key = source.substring(with: NSRange(location: start, length: end - start)) as NSString
            let width: CGFloat
            if let cached = self.lineWidthCache.object(forKey: key) { width = CGFloat(cached.doubleValue) }
            else {
                if self.columnMode {
                    let cells = (key as String).reduce(0) { $0 + ColumnSelection.displayWidth(of: $1, column: $0) }
                    width = CGFloat(cells) * (" " as NSString).size(withAttributes: [.font: currentFont, .kern: 0, .ligature: 0]).width
                } else { width = key.size(withAttributes: attributes).width }
                self.lineWidthCache.setObject(NSNumber(value: Double(width)), forKey: key, cost: key.length * 2)
            }
            return width
        }
        let longest: CGFloat
        if lines.starts.count > 512 * 1024 {
            // 每行宽度缓存最多约 4 MiB；极端多空行文档退回流式测量，不额外分配与全文同量级的缓存。
            measuredLineWidths.removeAll()
            longest = lines.starts.indices.lazy.map(measure).max() ?? 0
        } else if let update = pendingLineUpdate, measuredLineWidths.count == update.previousLineCount,
           update.index.length == source.length {
            // 只重新测量受编辑影响的相邻逻辑行；删除最长行时也重新计算全局最大值，避免横向范围残留。
            measuredLineWidths.replaceSubrange(update.replacedLines, with: update.insertedLines.map(measure))
            longest = measuredLineWidths.max() ?? 0
        } else {
            measuredLineWidths = lines.starts.indices.map(measure)
            longest = measuredLineWidths.max() ?? 0
        }
        pendingLineUpdate = nil
        naturalLineWidth = ceil(longest); extentFont = currentFont; extentColumnMode = columnMode
        extentTabInterval = paragraph.defaultTabInterval; extentNeedsMeasurement = false
        return naturalLineWidth
    }
    /// 真实编辑视图与横向内容共用同一有限宽度，系统绘制画布才能覆盖完整长行。
    func contentWidth(for viewportWidth: CGFloat) -> CGFloat {
        guard !wrapsLines else { return viewportWidth }
        return max(viewportWidth, unwrappedLineWidth() + textContainer.lineFragmentPadding * 2 + 1 + textContainerInset.left + textContainerInset.right)
    }
    func refreshTextSize() {
        guard !refreshingSize, bounds.width > 0 else { return }
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("layout", performanceStart) }
        #endif
        refreshingSize = true
        defer { refreshingSize = false }
        textContainer.widthTracksTextView = false
        let viewportWidth = navigationHost?.horizontalScroll.bounds.width ?? bounds.width
        let available = max(1, viewportWidth - textContainerInset.left - textContainerInset.right)
        // iOS 不能用十亿点宽的容器模拟“不换行”：原生文字画布会丢失右侧字形并反复重排。
        // 使用有限的真实最长行宽，并在整个横向滚动期间保持同一宽度，不依赖可见区 usedRect。
        let width = wrapsLines ? available : max(available, unwrappedLineWidth() + textContainer.lineFragmentPadding * 2 + 1)
        sourceWidth = wrapsLines ? bounds.width : width + textContainerInset.left + textContainerInset.right
        if textContainer.size.width != width { textContainer.size = CGSize(width: width, height: editorExtent) }
        layoutManager.ensureLayout(forBoundingRect: CGRect(origin: contentOffset, size: bounds.size), in: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let desired = CGSize(width: sourceWidth,
                             height: max(bounds.height, super.contentSize.height, ceil(used.maxY + textContainerInset.top + textContainerInset.bottom)))
        if contentSize != desired { contentSize = desired }
        showsHorizontalScrollIndicator = false
        if contentOffset.x != 0 { contentOffset.x = 0 }
    }
}
/// 横向手势交给外层，纵向手势由 UITextView 处理；不接触 UIKit 的私有绘制子视图。
final class EditorHorizontalViewport: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) >= abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
final class EditorHost: UIView, UIScrollViewDelegate {
    let editor: SourceTextView
    let horizontalScroll = EditorHorizontalViewport()
    var onViewportScroll: (() -> Void)?
    private var editorWidth: NSLayoutConstraint!
    private var pendingCaretReveal = true
    private var observedSelection = NSRange(location: NSNotFound, length: 0)
    let gutter = EditorMarginView(), ruler = EditorMarginView()
    var index = SourceLineIndex("")
    private var indexedSource: NSString = ""
    private var gutterWidth: NSLayoutConstraint!
    private var previousViewportSize = CGSize.zero
    var wrapsLines = false { didSet { editor.wrapsLines = wrapsLines } }
    override convenience init(frame: CGRect) { self.init(frame: frame, storage: nil) }
    /// 在 UITextView 初始化前建立完整的 TextKit 链路，确保编辑、着色与排版使用同一存储。
    init(frame: CGRect, storage: NSTextStorage?) {
        if let storage {
            let manager = NSLayoutManager()
            manager.allowsNonContiguousLayout = true
            let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            editor = SourceTextView(frame: .zero, textContainer: container)
        } else { editor = SourceTextView() }
        super.init(frame: frame)
        backgroundColor = rulerPaper
        ruler.columnRuler = true
        for view in [gutter, ruler] { view.isAccessibilityElement = true; view.isUserInteractionEnabled = false }
        gutter.accessibilityIdentifier = "editorLineNumbers"; gutter.accessibilityLabel = L10n.tr("行号")
        ruler.accessibilityIdentifier = "editorColumnRuler"; ruler.accessibilityLabel = L10n.tr("列标尺")
        addSubview(horizontalScroll); horizontalScroll.addSubview(editor); addSubview(gutter); addSubview(ruler)
        horizontalScroll.delegate = self
        horizontalScroll.accessibilityIdentifier = "manuscriptHorizontalViewport"
        horizontalScroll.isDirectionalLockEnabled = true; horizontalScroll.alwaysBounceVertical = false
        horizontalScroll.showsVerticalScrollIndicator = false; horizontalScroll.contentInsetAdjustmentBehavior = .never
        editor.isDirectionalLockEnabled = true; editor.contentInsetAdjustmentBehavior = .never
        // 外层横向视口避让键盘，同时不越过文稿宿主；内层原生编辑器保持同高以处理纵向滚动。
        keyboardLayoutGuide.usesBottomSafeArea = false
        for view in [horizontalScroll, editor, gutter, ruler] { view.translatesAutoresizingMaskIntoConstraints = false }
        gutterWidth = gutter.widthAnchor.constraint(equalToConstant: 40)
        editorWidth = editor.widthAnchor.constraint(equalToConstant: 1)
        let bottom = horizontalScroll.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            gutterWidth, gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: horizontalScroll.topAnchor), gutter.bottomAnchor.constraint(equalTo: horizontalScroll.bottomAnchor),
            ruler.topAnchor.constraint(equalTo: topAnchor), ruler.heightAnchor.constraint(equalToConstant: 24),
            ruler.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            horizontalScroll.topAnchor.constraint(equalTo: ruler.bottomAnchor), horizontalScroll.leadingAnchor.constraint(equalTo: ruler.leadingAnchor),
            horizontalScroll.trailingAnchor.constraint(equalTo: trailingAnchor), horizontalScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            horizontalScroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor), bottom,
            editorWidth, editor.leadingAnchor.constraint(equalTo: horizontalScroll.contentLayoutGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: horizontalScroll.contentLayoutGuide.trailingAnchor),
            editor.topAnchor.constraint(equalTo: horizontalScroll.contentLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: horizontalScroll.contentLayoutGuide.bottomAnchor),
            editor.heightAnchor.constraint(equalTo: horizontalScroll.frameLayoutGuide.heightAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = horizontalScroll.bounds.size
        let shrank = previousViewportSize.height > viewport.height && viewport.height > 0
        previousViewportSize = viewport
        resizeText()
        // 仅在视口缩小时显露插入点；普通拖动和键盘收起不抢回用户正在阅读的位置。
        if shrank && editor.isFirstResponder && !editor.isDragging && !editor.isDecelerating {
            editor.scrollRangeToVisible(editor.selectedRange)
        }
        refreshMargins()
    }
    func updateSource(_ text: String, edit: EditorTextChange? = nil) {
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("lineIndex", performanceStart) }
        #endif
        guard !indexedSource.isEqual(to: text) else { return }
        let source = text as NSString
        let update = edit.flatMap { change in
            change.previousLength == index.length ? index.applyingEdit(in: change.range, replacementLength: change.replacementLength, updatedText: source) : nil
        }
        indexedSource = source; index = update?.index ?? SourceLineIndex(text)
        editor.invalidateTextExtent(update)
        gutterWidth.constant = max(40, CGFloat(String(index.starts.count).count) * 8 + 18)
        setNeedsLayout(); refreshMargins()
    }
    func resizeText() {
        guard horizontalScroll.bounds.width > 0 else { return }
        let width = editor.contentWidth(for: horizontalScroll.bounds.width)
        if editorWidth.constant != width { editorWidth.constant = width; horizontalScroll.setNeedsLayout(); horizontalScroll.layoutIfNeeded() }
        editor.refreshTextSize()
        horizontalScroll.showsHorizontalScrollIndicator = !wrapsLines
        if wrapsLines && horizontalScroll.contentOffset.x != 0 { horizontalScroll.setContentOffset(.zero, animated: false) }
        revealHorizontalCaretIfNeeded()
    }
    /// 只在真正输入或选区跳转后显露横向插入点，手动浏览长行不抢回光标。
    func requestHorizontalCaretReveal() { pendingCaretReveal = true; setNeedsLayout() }
    func selectionDidChange() {
        if !editor.selectingColumnsByTouch && observedSelection != editor.selectedRange { requestHorizontalCaretReveal() }
        observedSelection = editor.selectedRange
    }
    private func revealHorizontalCaretIfNeeded() {
        guard pendingCaretReveal, !horizontalScroll.isDragging, !horizontalScroll.isDecelerating,
              abs(editor.bounds.width - editorWidth.constant) < 1, let end = editor.selectedTextRange?.end else { return }
        pendingCaretReveal = false
        let caret = editor.caretRect(for: end)
        horizontalScroll.scrollRectToVisible(CGRect(x: max(0, caret.minX - 12), y: 0, width: caret.width + 24, height: 1), animated: false)
    }
    /// 同时恢复外层横向位置与内层纵向位置，兼容工作区已有的 x/y 快照。
    func restoreScrollPosition(_ point: CGPoint) {
        pendingCaretReveal = false; observedSelection = editor.selectedRange
        editor.setContentOffset(CGPoint(x: 0, y: max(0, point.y)), animated: false)
        horizontalScroll.setContentOffset(CGPoint(x: max(0, point.x), y: 0), animated: false)
        refreshMargins()
    }
    var visibleTextRect: CGRect {
        CGRect(x: horizontalScroll.contentOffset.x, y: editor.contentOffset.y, width: horizontalScroll.bounds.width, height: editor.bounds.height)
    }
    /// 手动列视口移动不显露旧插入点；纵向锚点由正文控件统一保存。
    func beginManualViewportScroll() { pendingCaretReveal = false; editor.beginUserScrolling() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { pendingCaretReveal = false }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { refreshMargins(); onViewportScroll?() }
    func refreshMargins() {
        let viewport = visibleTextRect
        #if DEBUG
        let performanceStart = EditorPerformanceTrace.start()
        defer { EditorPerformanceTrace.finish("margins", performanceStart) }
        #endif
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
        if editor.backgroundColor != surface { editor.backgroundColor = surface }
        #if os(iOS)
        if editor.appliedTheme != theme {
            editor.appliedTheme = theme
            // UITextView 的 textColor 不一定覆盖已有富文本的显式前景属性。
            // 换主题时同步正文和后续输入的基础色，并让保留的字形缓存重新绘制。
            // 只在主题改变时处理全篇，避免每次输入或滚动都重设颜色。
            editor.textColor = ink; editor.tintColor = UIColor(theme.highlight)
            editor.textStorage.addAttribute(.foregroundColor, value: ink, range: NSRange(location: 0, length: editor.textStorage.length))
            var attributes = editor.typingAttributes
            attributes[.foregroundColor] = ink; editor.typingAttributes = attributes
            editor.layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: editor.textStorage.length))
            editor.setNeedsDisplay()
        }
        #else
        if editor.textColor != ink { editor.textColor = ink }
        #endif
        for view in [gutter, ruler] { view.paperColor = margin; view.inkColor = ink.withAlphaComponent(0.6); view.refresh() }
    }
}
