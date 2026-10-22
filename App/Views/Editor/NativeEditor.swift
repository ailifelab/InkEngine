import SwiftUI
import InkCore
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformColor = UIColor
#endif

/// 让 TextKit 的字形前进量与逻辑列共用同一规则；只调整显示属性，不改正文或撤销记录。
private enum EditorColumnGrid {
    #if os(macOS)
    typealias Font = NSFont
    #else
    typealias Font = UIFont
    #endif
    static func apply(to storage: NSTextStorage, font: Font, enabled: Bool) {
        let entire = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        guard enabled else {
            storage.removeAttribute(.kern, range: entire)
            storage.removeAttribute(.ligature, range: entire)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .ligature: 0, .kern: 0]
        let cell = max(1, (" " as NSString).size(withAttributes: attributes).width)
        storage.addAttribute(.ligature, value: 0, range: entire)
        var widths: [Character: CGFloat] = [:], offset = 0, column = 0
        var runStart = 0, runWidth: CGFloat?, runLength = 0
        func flush() {
            if let value = runWidth, runLength > 0 {
                storage.addAttribute(.kern, value: value, range: NSRange(location: runStart, length: runLength))
            }
        }
        for character in storage.string {
            let part = String(character), length = part.utf16.count
            let cells = ColumnSelection.displayWidth(of: character, column: column)
            var adjustment: CGFloat = 0
            if !character.isNewline && character != "\t" {
                // 必须显式用 kern=0 测量，中文标点的默认上下文压缩会使单字测量失真。
                let natural = widths[character] ?? (part as NSString).size(withAttributes: attributes).width
                widths[character] = natural
                adjustment = CGFloat(cells) * cell - natural
            }
            if runWidth != adjustment { flush(); runStart = offset; runLength = 0; runWidth = adjustment }
            runLength += length; offset += length
            column = character.isNewline ? 0 : column + cells
        }
        flush()
    }
}

private func syntaxColor(_ kind: SyntaxKind, dark: Bool = false) -> PlatformColor {
    if dark {
        switch kind {
        case .keyword: return PlatformColor(red: 0.79, green: 0.65, blue: 0.95, alpha: 1)
        case .string: return PlatformColor(red: 0.98, green: 0.65, blue: 0.64, alpha: 1)
        case .comment: return PlatformColor(red: 0.59, green: 0.79, blue: 0.61, alpha: 1)
        case .number: return PlatformColor(red: 0.96, green: 0.78, blue: 0.52, alpha: 1)
        case .heading: return PlatformColor(red: 0.54, green: 0.87, blue: 0.92, alpha: 1)
        case .markup, .punctuation: return PlatformColor(red: 0.65, green: 0.76, blue: 0.99, alpha: 1)
        }
    }
    switch kind {
    case .keyword: return PlatformColor(red: 0.42, green: 0.20, blue: 0.62, alpha: 1)
    case .string: return PlatformColor(red: 0.65, green: 0.15, blue: 0.22, alpha: 1)
    case .comment: return PlatformColor(red: 0.19, green: 0.38, blue: 0.25, alpha: 1)
    case .number: return PlatformColor(red: 0.60, green: 0.29, blue: 0.07, alpha: 1)
    case .heading: return PlatformColor(red: 0.08, green: 0.35, blue: 0.43, alpha: 1)
    case .markup: return PlatformColor(red: 0.13, green: 0.32, blue: 0.59, alpha: 1)
    case .punctuation: return PlatformColor(red: 0.27, green: 0.27, blue: 0.51, alpha: 1)
    }
}

#if os(macOS)
final class FocusTextView: NSTextView {
    var documentID: UUID?
    var sessionUndo: UndoManager?
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override var undoManager: UndoManager? { sessionUndo ?? super.undoManager }
    weak var navigationHost: EditorHost?
    var focusOnArrival = true
    var columnMode = false {
        didSet { if oldValue != columnMode { alignColumnTabs() } }
    }
    var columnTargets: [ColumnSelection.Target] = []
    var columnRanges: [NSRange] {
        get { columnTargets.map(\.range) }
        set { columnTargets = newValue.map { .init(range: $0) }; needsDisplay = true }
    }
    var applyingColumn = false
    func alignColumnTabs() {
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []; paragraph.defaultTabInterval = cellWidth * 4
        defaultParagraphStyle = paragraph; typingAttributes[.paragraphStyle] = paragraph
        textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (string as NSString).length))
        if let storage = textStorage { EditorColumnGrid.apply(to: storage, font: font ?? .monospacedSystemFont(ofSize: 21, weight: .regular), enabled: columnMode) }
    }
    private var columnComposition: (String, [ColumnSelection.Target])?
    private var columnCompositionUndo: UndoManager?
    private var columnMarkedRange = NSRange(location: NSNotFound, length: 0)
    private var columnAnchor: ColumnSelection.Point?
    private var columnLineIndex: SourceLineIndex?
    private var columnActive: Bool { !columnTargets.isEmpty }
    private var cellWidth: CGFloat { max(1, (" " as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 21, weight: .regular)]).width) }
    func applyEdit(_ value: String, targets: [ColumnSelection.Target] = []) {
        guard isEditable else { return }
        let old = string, oldRange = selectedRange(), oldTargets = columnTargets
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyEdit(old, targets: oldTargets)
            if oldTargets.isEmpty { target.setSelectedRange(oldRange) }
        }
        applyingColumn = true
        string = value; columnTargets = targets; alignColumnTabs()
        if let first = targets.first { setSelectedRange(first.range) }
        didChangeText(); applyingColumn = false; needsDisplay = true
    }
    private func editColumns(_ command: ColumnSelection.Command) {
        guard isEditable else { return }
        let result = ColumnSelection.edit(string, targets: columnTargets, command: command)
        guard !result.targets.isEmpty, result.text != string || result.targets != columnTargets else { return }
        applyEdit(result.text, targets: result.targets)
    }
    /// 中文输入法只在主光标显示组合文本；确定候选字后，整组光标一次性提交，撤销也只记一次。
    override func hasMarkedText() -> Bool { columnMarkedRange.location != NSNotFound || super.hasMarkedText() }
    override func markedRange() -> NSRange { columnMarkedRange.location != NSNotFound ? columnMarkedRange : super.markedRange() }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard columnActive || columnComposition != nil else { super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange); return }
        if columnActive && columnComposition == nil {
            breakUndoCoalescing()
            columnComposition = (self.string, columnTargets)
            if let manager = undoManager, manager.isUndoRegistrationEnabled { manager.disableUndoRegistration(); columnCompositionUndo = manager }
        }
        guard let first = columnComposition?.1.first else { return }
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let replaced = columnMarkedRange.location == NSNotFound ? first.range : columnMarkedRange
        // NSTextView 的默认组合输入会留下主光标自己的拼音撤销记录；列模式自行维护组合区，最终只注册整组编辑。
        columnMarkedRange = NSRange(location: replaced.location, length: value.utf16.count)
        applyingColumn = true; textStorage?.replaceCharacters(in: replaced, with: value)
        if columnMarkedRange.length > 0 { textStorage?.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: columnMarkedRange) }
        let location = min(selectedRange.location, value.utf16.count)
        setSelectedRange(NSRange(location: replaced.location + location, length: min(selectedRange.length, value.utf16.count - location)))
        didChangeText(); applyingColumn = false; needsDisplay = true
    }
    private func finishColumnComposition(_ value: String) {
        guard let (original, targets) = columnComposition else { return }
        columnComposition = nil; columnMarkedRange = NSRange(location: NSNotFound, length: 0)
        applyingColumn = true; string = original; columnTargets = targets; applyingColumn = false
        columnCompositionUndo?.enableUndoRegistration(); columnCompositionUndo = nil
        breakUndoCoalescing()
        editColumns(.insert(value))
    }
    override func unmarkText() {
        if columnComposition != nil {
            let range = markedRange()
            let value = range.location == NSNotFound ? "" : (string as NSString).substring(with: range)
            finishColumnComposition(value)
        } else { super.unmarkText() }
    }
    override func cancelOperation(_ sender: Any?) {
        if let (original, targets) = columnComposition {
            columnComposition = nil; columnMarkedRange = NSRange(location: NSNotFound, length: 0)
            applyingColumn = true; string = original; columnTargets = targets
            if let first = targets.first { setSelectedRange(first.range) }
            columnCompositionUndo?.enableUndoRegistration(); columnCompositionUndo = nil
            didChangeText(); applyingColumn = false; needsDisplay = true
        } else { super.cancelOperation(sender) }
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if columnComposition != nil { finishColumnComposition(text); return }
        guard columnActive, !hasMarkedText() else { super.insertText(insertString, replacementRange: replacementRange); return }
        editColumns(.insert(text))
    }
    override func deleteBackward(_ sender: Any?) {
        guard columnActive, !hasMarkedText() else { super.deleteBackward(sender); return }
        editColumns(.backspace)
    }
    override func deleteForward(_ sender: Any?) {
        guard columnActive, !hasMarkedText() else { super.deleteForward(sender); return }
        editColumns(.deleteForward)
    }
    override func copy(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard columnActive else { super.copy(sender); return }
        guard columnRanges.contains(where: { $0.length > 0 }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(columnRanges.map { (string as NSString).substring(with: $0) }.joined(separator: "\n"), forType: .string)
    }
    override func cut(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard columnActive else { super.cut(sender); return }
        copy(sender); editColumns(.cut)
    }
    override func paste(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard columnActive, let value = NSPasteboard.general.string(forType: .string) else { super.paste(sender); return }
        editColumns(.paste(value))
    }
    /// 拖选期间复用行索引。虚拟列通过文字末端到鼠标的距离计算，不要求短行真的存在那个字符。
    private func columnPoint(_ event: NSEvent) -> ColumnSelection.Point {
        let location = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: location)
        let lines = columnLineIndex ?? SourceLineIndex(string)
        var point = ColumnSelection.point(in: string, at: offset, lineIndex: lines)
        let range = NSRange(location: lines.starts[point.row], length: 0)
        let screen = firstRect(forCharacterRange: range, actualRange: nil)
        if let window, screen.width.isFinite {
            let insertion = convert(window.convertFromScreen(screen).origin, from: nil)
            point.column = min(1_000_000, max(0, Int(((location.x - insertion.x) / cellWidth).rounded())))
        }
        return point
    }
    private func selectColumns(to event: NSEvent) {
        guard let anchor = columnAnchor else { return }
        let endpoint = columnPoint(event)
        columnTargets = ColumnSelection.targets(in: string, from: anchor, to: endpoint, lineIndex: columnLineIndex)
        applyingColumn = true
        if let first = columnTargets.first { setSelectedRange(first.range) }
        applyingColumn = false; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            window?.makeFirstResponder(self)
            columnLineIndex = SourceLineIndex(string); columnAnchor = columnPoint(event)
            selectColumns(to: event)
        } else {
            columnTargets = []; columnAnchor = nil; columnLineIndex = nil; needsDisplay = true
            super.mouseDown(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if columnAnchor != nil { autoscroll(with: event); selectColumns(to: event) }
        else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if columnAnchor != nil { selectColumns(to: event); columnAnchor = nil; columnLineIndex = nil }
        else { super.mouseUp(with: event) }
    }
    override func selectAll(_ sender: Any?) {
        guard columnMode, !hasMarkedText() else { super.selectAll(sender); return }
        columnTargets = ColumnSelection.allTargets(in: string, lineIndex: navigationHost?.index)
        applyingColumn = true
        if let first = columnTargets.first { setSelectedRange(first.range) }
        applyingColumn = false; needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if columnActive && !hasMarkedText() {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if [123, 124].contains(event.keyCode) && !flags.contains(.control) && !flags.contains(.option) {
                moveColumns(direction: event.keyCode == 124 ? 1 : -1, byWord: flags.contains(.command), extending: flags.contains(.shift)); return
            }
            if [125, 126].contains(event.keyCode) && flags.contains(.shift) && !flags.contains(.option) {
                moveColumns(direction: event.keyCode == 125 ? 1 : -1, rows: true); return
            }
        }
        if [123, 124, 125, 126, 53].contains(event.keyCode), !hasMarkedText() { columnTargets = []; needsDisplay = true }
        super.keyDown(with: event)
    }
    private func moveColumns(direction: Int, byWord: Bool = false, extending: Bool = false, rows: Bool = false) {
        let lines = navigationHost?.index ?? SourceLineIndex(string)
        columnTargets = rows ? ColumnSelection.extendingRows(in: string, targets: columnTargets, direction: direction, lineIndex: lines) : ColumnSelection.move(in: string, targets: columnTargets, direction: direction, byWord: byWord, extending: extending, lineIndex: lines)
        applyingColumn = true
        if let first = columnTargets.first { setSelectedRange(first.range); scrollRangeToVisible(first.range) }
        applyingColumn = false; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard columnActive, let manager = layoutManager, let container = textContainer else { return }
        let visible = manager.characterRange(forGlyphRange: manager.glyphRange(forBoundingRect: visibleRect, in: container), actualGlyphRange: nil)
        for target in columnTargets where target.range.location >= visible.location && target.range.location <= NSMaxRange(visible) {
            let range = target.range
            if range.length > 0 {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.3).setFill(); rect.fill()
            } else {
                let screen = firstRect(forCharacterRange: range, actualRange: nil)
                if let window {
                    var rect = convert(window.convertFromScreen(screen), from: nil)
                    rect.origin.x += CGFloat(target.virtualSpaces) * cellWidth; rect.size.width = 1.5
                    insertionPointColor.setFill(); rect.fill()
                }
            }
        }
    }
    override func accessibilityFrame() -> NSRect {
        guard let scroll = enclosingScrollView, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusOnArrival, let window { focusOnArrival = false; window.makeFirstResponder(self) }
    }
}
struct NativeEditor: NSViewRepresentable {
    @Environment(\.locale) private var appLocale
    var text: String
    var position: Int
    var navigationID: UUID
    var fontSize: Double
    var format: TextFormat
    var wrapsLines: Bool
    var theme: ReadingTheme
    var columnMode: Bool
    var mutation: EditorMutation?
    var onChange: (String) -> Void
    var onPosition: (Int) -> Void
    var documentID: UUID? = nil
    var viewState: EditorViewState? = nil
    var readOnly = false
    var active = true
    var navigationEnabled = true
    var onFocus: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 500)
    }
    func makeNSView(context: Context) -> EditorHost {
        // 创建、复用和同步原生视图时，系统可能同步回调选区或结束编辑；
        // 此时不能反向发布 SwiftUI 状态，只有用户操作才回写模型。
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if let host = viewState?.host {
            let editor = host.editor as! FocusTextView
            editor.delegate = context.coordinator; editor.onFocus = onFocus
            context.coordinator.editor = editor; context.coordinator.host = host
            context.coordinator.navigationID = navigationID
            if viewState != nil { context.coordinator.mutationID = mutation?.id }
            editor.focusOnArrival = viewState?.active ?? true
            DispatchQueue.main.async { [weak editor, weak state = viewState] in if let editor, state?.active != false { editor.window?.makeFirstResponder(editor) } }
            context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: host.scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
                MainActor.assumeIsolated { coordinator?.host?.refreshMargins(); coordinator?.highlight() }
            }
            return host
        }
        let host = EditorHost(); let scroll = host.scroll
        viewState?.host = host
        host.wrapsLines = wrapsLines
        let editor = FocusTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        editor.navigationHost = host
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.documentID = documentID; editor.onFocus = onFocus
        if let viewState { editor.layoutManager?.replaceTextStorage(viewState.storage) }
        editor.focusOnArrival = viewState?.active ?? true
        editor.isEditable = !readOnly; editor.isSelectable = true; editor.allowsUndo = true
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.textContainerInset = NSSize(width: 12, height: 18)
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.backgroundColor = NSColor(red: 0.99, green: 0.987, blue: 0.975, alpha: 1); editor.textColor = .textColor
        scroll.backgroundColor = editor.backgroundColor
        editor.setAccessibilityIdentifier("manuscriptEditor")
        editor.identifier = NSUserInterfaceItemIdentifier("manuscriptEditor")
        if editor.string != text { editor.string = text }
        editor.sessionUndo = viewState?.undo
        editor.alignColumnTabs()
        editor.setSelectedRange(NSRange(location: min(position, text.utf16.count), length: 0))
        scroll.documentView = editor
        context.coordinator.editor = editor; context.coordinator.host = host; context.coordinator.navigationID = navigationID
        if viewState != nil { context.coordinator.mutationID = mutation?.id }
        // 初次设置选区属于视图初始化；随后才挂代理，避免初始化期间反向修改 SwiftUI 状态。
        editor.delegate = context.coordinator
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.host?.refreshMargins(); coordinator?.highlight() }
        }
        context.coordinator.highlight()
        host.updateSource(text); host.applyTheme(theme)
        editor.columnMode = columnMode
        if let position = viewState?.restoredPosition {
            viewState?.restoredPosition = nil
            let location = min(max(0, position.cursor), text.utf16.count)
            editor.setSelectedRange(NSRange(location: location, length: min(max(0, position.selectionLength), text.utf16.count - location)))
            DispatchQueue.main.async { [weak host] in
                host?.scroll.contentView.scroll(to: NSPoint(x: max(0, position.x), y: max(0, position.y)))
                if let host { host.scroll.reflectScrolledClipView(host.scroll.contentView) }
            }
        }
        return host
    }
    func updateNSView(_ host: EditorHost, context: Context) {
        // 创建、复用和同步原生视图时，系统可能同步回调选区或结束编辑；
        // 此时不能反向发布 SwiftUI 状态，只有用户操作才回写模型。
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if viewState != nil {
            let showing = host.isHidden && active
            host.isHidden = !active
            host.editor.setAccessibilityIdentifier(active ? "manuscriptEditor" : "inactiveManuscriptEditor")
            if showing { DispatchQueue.main.async { [weak host] in if let host, !host.isHidden { host.editor.window?.makeFirstResponder(host.editor) } } }
        }
        host.gutter.setAccessibilityLabel(L10n.tr("行号"))
        host.ruler.setAccessibilityLabel(L10n.tr("列标尺"))
        let c = context.coordinator; let previous = c.parent; c.parent = self
        let editor = host.editor as! FocusTextView
        guard !editor.hasMarkedText() else { return }
        editor.isEditable = !readOnly; editor.onFocus = onFocus
        editor.columnMode = columnMode
        if previous.columnMode != columnMode { editor.columnRanges = []; if columnMode { host.wrapsLines = false } }
        // 新的可撤销编辑优先于本轮 SwiftUI 文本快照；快照可能仍是替换前的正文，
        // 不能在 applyEdit 后立即用旧 text 覆盖它，否则面板显示成功、关闭后正文却回退。
        if let mutation, c.mutationID != mutation.id { c.mutationID = mutation.id; editor.applyEdit(mutation.text) }
        else if editor.string != text {
            let manager = editor.undoManager, registered = editor.undoManager?.isUndoRegistrationEnabled == true
            if registered { manager?.disableUndoRegistration() }
            if viewState != nil { editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: editor.string.utf16.count), with: text) }
            else { editor.string = text }
            if registered { manager?.enableUndoRegistration() }
            editor.alignColumnTabs(); host.updateSource(text); c.highlight()
        }
        if previous.text != text { host.updateSource(text); c.highlight() }
        if editor.font?.pointSize != CGFloat(fontSize) {
            editor.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular); editor.alignColumnTabs()
            host.resizeText(); host.refreshMargins(); c.highlight()
        }
        // 仅显式定位请求修改选区，普通视图刷新不能移动光标或打断中文输入法的组合文本。
        if c.navigationID != navigationID && !navigationEnabled { c.navigationID = navigationID }
        if c.navigationID != navigationID {
            c.navigationID = navigationID
            let range = NSRange(location: min(max(0, position), editor.string.utf16.count), length: 0)
            editor.columnTargets = []; editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
            editor.window?.makeFirstResponder(editor)
        }
        if host.wrapsLines != wrapsLines {
            host.wrapsLines = wrapsLines; host.resizeText(); editor.scrollRangeToVisible(editor.selectedRange()); host.refreshMargins()
        }
        if previous.format != format || previous.theme != theme { c.highlight() }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeEditor
        weak var editor: FocusTextView?
        weak var host: EditorHost?
        var navigationID: UUID?
        var mutationID: UUID?
        var updating = false
        var observer: NSObjectProtocol?
        var work: Task<Void, Never>?
        init(_ parent: NativeEditor) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; work?.cancel() }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor, !editor.hasMarkedText() else { return }
            if editor.columnMode && !editor.applyingColumn { editor.alignColumnTabs() }
            host?.updateSource(editor.string); host?.resizeText()
            parent.onChange(editor.string); parent.onPosition(editor.selectedRange().location); highlight()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor, !editor.hasMarkedText() else { return }
            if editor.columnMode && !editor.applyingColumn && (editor.columnTargets.isEmpty || editor.selectedRange() != editor.columnTargets[0].range) {
                let range = editor.selectedRange()
                editor.columnTargets = ColumnSelection.targets(in: editor.string, from: ColumnSelection.point(in: editor.string, at: range.location, lineIndex: host?.index), to: ColumnSelection.point(in: editor.string, at: NSMaxRange(range), lineIndex: host?.index), lineIndex: host?.index)
                editor.needsDisplay = true
            }
            if !editor.columnMode && !editor.applyingColumn && !editor.columnTargets.isEmpty && editor.selectedRange() != editor.columnTargets[0].range {
                editor.columnTargets = []; editor.needsDisplay = true
            }
            parent.onPosition(editor.selectedRange().location)
        }
        func highlight() {
            work?.cancel()
            work = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, let editor = self.editor, !editor.hasMarkedText(), let storage = editor.textStorage else { return }
                let source = editor.string as NSString
                let visible = editor.layoutManager.map { manager in manager.characterRange(forGlyphRange: manager.glyphRange(forBoundingRect: editor.visibleRect, in: editor.textContainer!), actualGlyphRange: nil) } ?? editor.selectedRange()
                let start = min(source.length, max(0, visible.location - 2000))
                let range = NSRange(location: start, length: min(24_000, source.length - start))
                let slice = source.substring(with: range), format = self.parent.format
                let tokens = await Task.detached { SyntaxHighlighter.tokens(in: slice, format: format, baseOffset: range.location) }.value
                guard !Task.isCancelled, editor.delegate === self, !editor.hasMarkedText(), editor.string == source as String else { return }
                self.updating = true
                storage.beginEditing(); storage.addAttribute(.foregroundColor, value: NSColor(self.parent.theme.foreground), range: range)
                for token in tokens { storage.addAttribute(.foregroundColor, value: syntaxColor(token.kind, dark: self.parent.theme == .dark), range: token.range) }
                storage.endEditing(); self.updating = false; self.host?.refreshMargins()
            }
        }
    }
}
#else
/// 保留真正按下的位置；UIPan 到达识别阈值后的 location 已经移动，不能作为矩形起点。
private final class ColumnRectanglePan: UIPanGestureRecognizer {
    var initialLocation = CGPoint.zero
    private var stationaryTimer: Timer?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { initialLocation = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
        stationaryTimer?.invalidate()
        // 快拖优先形成矩形；静止长按则退出竞争，让系统继续显示复制、粘贴等编辑菜单。
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            if self?.state == .possible { self?.state = .failed }
        }
        stationaryTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func reset() {
        stationaryTimer?.invalidate(); stationaryTimer = nil
        super.reset()
    }
    deinit { stationaryTimer?.invalidate() }
}
/// 矩形选择独立决定是否识别，不借用滚动器对横向可滚范围的判断。
/// 同编辑区的原生选区手势等待它失败：快拖先选择；双指或静止长按失败后交还系统。
private final class ColumnRectanglePanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var editor: ColumnTextView?
    init(editor: ColumnTextView) { self.editor = editor }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        editor?.columnMode == true && editor?.markedTextRange == nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let editor, editor.columnMode, !editor.isColumnGesture(otherGestureRecognizer) else { return false }
        // 双指视口手势仅在两指真正到齐时参与竞争，不阻塞单指长按菜单。
        if editor.isColumnViewportGesture(gestureRecognizer), gestureRecognizer.numberOfTouches < 2 { return false }
        return otherGestureRecognizer === editor.navigationHost?.horizontalScroll.panGestureRecognizer
            || otherGestureRecognizer.view === editor
            || otherGestureRecognizer.view?.isDescendant(of: editor) == true
    }
}
class ColumnTextView: UITextView {
    func applyBaseFont(_ value: UIFont) {
        if font != value { font = value }
        textStorage.addAttribute(.font, value: value, range: NSRange(location: 0, length: textStorage.length))
        var attributes = typingAttributes
        attributes[.font] = value
        typingAttributes = attributes
    }
    #if DEBUG
    var changeDiagnostics = "callbacks=0"
    /// 专项性能测量不经 AX 序列化全文富文本；普通测试及正式版本的辅助功能行为保持系统默认。
    override var accessibilityValue: String? {
        get { EditorPerformanceTrace.enabled ? "nativeLength=\(textStorage.length)" : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
    override var accessibilityAttributedValue: NSAttributedString? {
        get { EditorPerformanceTrace.enabled ? NSAttributedString(string: "nativeLength=\(textStorage.length)") : super.accessibilityAttributedValue }
        set { super.accessibilityAttributedValue = newValue }
    }
    override var accessibilityLabel: String? {
        get {
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return super.accessibilityLabel }
            if EditorPerformanceTrace.enabled {
                // 大文件测试只读取光标附近的有界摘要，避免通过无障碍接口反复传输全文干扰计时。
                let location = min(textStorage.length, max(0, selectedRange.location))
                let start = max(0, location - 40)
                let range = NSRange(location: start, length: min(80, textStorage.length - start))
                let nearby = textStorage.mutableString.substring(with: range).data(using: .utf8)?.base64EncodedString() ?? ""
                return "nativeLength=\(textStorage.length);selection=\(selectedRange.location),\(selectedRange.length);nearCaretBase64=\(nearby);marked=\(markedTextRange != nil);nativeWrapping=\((self as? SourceTextView)?.wrapsLines ?? false);columnMode=\(columnMode);undoEnabled=\(undoManager?.isUndoRegistrationEnabled == true);canUndo=\(undoManager?.canUndo == true);canRedo=\(undoManager?.canRedo == true);scrollY=\(contentOffset.y);viewportHeight=\(bounds.height)"
            }
            let first = textStorage.length > 0 ? (textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize : nil
            let last = textStorage.length > 0 ? (textStorage.attribute(.font, at: textStorage.length - 1, effectiveRange: nil) as? UIFont)?.pointSize : nil
            let firstInk = textStorage.length > 0 ? String(describing: textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil)) : "empty"
            let lastInk = textStorage.length > 0 ? String(describing: textStorage.attribute(.foregroundColor, at: textStorage.length - 1, effectiveRange: nil)) : "empty"
            let theme = (self as? SourceTextView)?.appliedTheme?.rawValue ?? "none"
            let layoutInk = layoutManager.textStorage.flatMap { $0.length > 0 ? $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) : nil }
            let canvases = subviews.map { "\(type(of: $0))=\($0.frame)" }.joined(separator: "/")
            let targets = columnTargets.map { "\($0.range.location):\($0.range.length):\($0.virtualSpaces)" }.joined(separator: "|")
            let probe4 = position(from: beginningOfDocument, offset: min(4, textStorage.length)).map { caretRect(for: $0) } ?? .zero
            let probe34 = position(from: beginningOfDocument, offset: min(34, textStorage.length)).map { caretRect(for: $0) } ?? .zero
            let selectionCaret = position(from: beginningOfDocument, offset: min(selectedRange.location, textStorage.length)).map { caretRect(for: $0) } ?? .zero
            return "delegate=\(delegate.map { String(describing: type(of: $0)) } ?? "nil");marked=\(markedTextRange != nil);undoEnabled=\(undoManager?.isUndoRegistrationEnabled == true);sessionUndo=\(undoManager === sessionUndo);nativeUndo=\(super.undoManager?.canUndo == true);sameNative=\(super.undoManager === sessionUndo);firstFont=\(first ?? 0);lastFont=\(last ?? 0);selection=\(selectedRange.location),\(selectedRange.length);firstResponder=\(isFirstResponder);storageSame=\(layoutManager.textStorage === textStorage);layoutInk=\(String(describing: layoutInk));appliedTheme=\(theme);textInk=\(String(describing: textColor));firstInk=\(firstInk);lastInk=\(lastInk);bounds=\(bounds);contentSize=\(contentSize);textContainerSize=\(textContainer.size);outerOffset=\(navigationHost?.horizontalScroll.contentOffset ?? .zero);outerBounds=\(navigationHost?.horizontalScroll.bounds ?? .zero);outerContentSize=\(navigationHost?.horizontalScroll.contentSize ?? .zero);canvasViews=\(canvases);contentOffset=\(contentOffset);contentInset=\(contentInset);adjustedInset=\(adjustedContentInset);keyboardGuide=\(keyboardLayoutGuide.layoutFrame);nativeWrapping=\((self as? SourceTextView)?.wrapsLines ?? false);columnPanTrace=\(columnPanTrace);columnMode=\(columnMode);columnTargets=\(columnTargets.count);columnRanges=\(targets);caretProbe4=\(probe4);caretProbe34=\(probe34);selectionCaret=\(selectionCaret);documentID=\(documentID?.uuidString ?? "none");\((self as? SourceTextView)?.viewportDiagnostics ?? "");\(changeDiagnostics)"
        }
        set { super.accessibilityLabel = newValue }
    }
    #endif
    var documentID: UUID?
    var sessionUndo: UndoManager?
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override var undoManager: UndoManager? { sessionUndo ?? super.undoManager }
    weak var navigationHost: EditorHost?
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        if let textContainer { super.init(frame: frame, textContainer: textContainer) }
        else {
            // 行号和列标尺依赖 TextKit 1 的字形坐标。初始化时明确采用它，
            // 避免 UIKit 在滚动过程中从 TextKit 2 切换并整篇重新排版。
            let storage = NSTextStorage(), manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            manager.allowsNonContiguousLayout = true
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            super.init(frame: frame, textContainer: container)
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    /// 列模式把单指交给矩形选择，正文滚动改用双指；退出后恢复系统单指滚动。
    var columnMode = false {
        didSet {
            guard oldValue != columnMode else { return }
            alignColumnTabs()
            columnPan.isEnabled = columnMode
            columnViewportPan.isEnabled = columnMode
            panGestureRecognizer.minimumNumberOfTouches = columnMode ? 2 : 1
            navigationHost?.horizontalScroll.panGestureRecognizer.minimumNumberOfTouches = columnMode ? 2 : 1
            if !columnMode { stopColumnEdgeScroll(); columnAnchor = nil; columnViewportOrigin = nil; columnTargets = []; drawColumnSelection() }
        }
    }
    private lazy var columnPanDelegate = ColumnRectanglePanDelegate(editor: self)
    private lazy var columnPan: ColumnRectanglePan = {
        let recognizer = ColumnRectanglePan(target: self, action: #selector(selectColumnRectangle(_:)))
        recognizer.minimumNumberOfTouches = 1; recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = columnPanDelegate
        recognizer.isEnabled = false
        addGestureRecognizer(recognizer)
        return recognizer
    }()
    private lazy var columnViewportPan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(scrollColumnViewport(_:)))
        recognizer.minimumNumberOfTouches = 2; recognizer.maximumNumberOfTouches = 2
        recognizer.delegate = columnPanDelegate; recognizer.isEnabled = false
        addGestureRecognizer(recognizer)
        return recognizer
    }()
    fileprivate func isColumnGesture(_ gesture: UIGestureRecognizer) -> Bool { gesture === columnPan || gesture === columnViewportPan }
    fileprivate func isColumnViewportGesture(_ gesture: UIGestureRecognizer) -> Bool { gesture === columnViewportPan }
    private var columnViewportOrigin: CGPoint?
    /// 双指只移动视口，原生的双指选词不会改写已经建立的矩形范围。
    /// 位移以不滚动的宿主为参照，避免内容 offset 反过来影响 translation 造成跳动。
    @objc private func scrollColumnViewport(_ recognizer: UIPanGestureRecognizer) {
        guard columnMode, markedTextRange == nil, let host = navigationHost else { columnViewportOrigin = nil; return }
        if recognizer.state == .began {
            stopColumnEdgeScroll(); columnAnchor = nil
            host.beginManualViewportScroll()
            columnViewportOrigin = CGPoint(x: host.horizontalScroll.contentOffset.x, y: contentOffset.y)
            host.horizontalScroll.flashScrollIndicators(); flashScrollIndicators()
        }
        guard let origin = columnViewportOrigin else { return }
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            let movement = recognizer.translation(in: host)
            let outer = host.horizontalScroll
            let previous = CGPoint(x: outer.contentOffset.x, y: contentOffset.y)
            outer.contentOffset.x = min(max(0, origin.x - movement.x), max(0, outer.contentSize.width - outer.bounds.width))
            let nextY = min(max(0, origin.y - movement.y), max(0, contentSize.height - bounds.height))
            beginColumnVerticalScroll(nextY - contentOffset.y)
            // 横向回调已经请求可见区着色；纯纵向移动才需要在这里补一次。
            if outer.contentOffset.x == previous.x && contentOffset.y != previous.y { host.onViewportScroll?() }
        }
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed { columnViewportOrigin = nil }
    }
    #if DEBUG
    // 仅测试读取手势轨迹，区分识别失败和原生选区回调覆盖；不修改识别策略。
    private var columnPanTrace = "events0"
    private var columnPanEventCount = 0
    private var columnPanBeginTrace = "none"
    #endif
    private var columnAnchor: ColumnSelection.Point?
    var selectingColumnsByTouch: Bool { columnAnchor != nil }
    private var columnScrollTimer: Timer?
    deinit { columnScrollTimer?.invalidate() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopColumnEdgeScroll(); columnAnchor = nil; columnViewportOrigin = nil }
    }
    private var columnDragInViewport = CGPoint.zero
    /// 边缘拖选按屏幕坐标保存活动端，正文滚动后重新换算逻辑行；不改动正文或撤销栈。
    @objc private func extendColumnAtEdge() {
        guard columnMode, markedTextRange == nil, columnAnchor != nil,
              columnPan.state == .began || columnPan.state == .changed,
              let host = navigationHost else { stopColumnEdgeScroll(); columnAnchor = nil; return }
        let viewport = host.horizontalScroll
        let edge: CGFloat = 32
        let point = columnDragInViewport
        let dx: CGFloat = point.x < edge ? -10 : (point.x > viewport.bounds.width - edge ? 10 : 0)
        let dy: CGFloat = point.y < edge ? -10 : (point.y > viewport.bounds.height - edge ? 10 : 0)
        if dx != 0 {
            viewport.contentOffset.x = min(max(0, viewport.contentOffset.x + dx), max(0, viewport.contentSize.width - viewport.bounds.width))
        }
        if dy != 0 {
            beginColumnVerticalScroll(dy)
        }
        if dx != 0 || dy != 0 {
            let contentPoint = CGPoint(x: point.x + viewport.contentOffset.x, y: point.y + contentOffset.y)
            updateColumnRectangle(to: columnPoint(at: contentPoint))
        }
    }
    private func beginColumnVerticalScroll(_ delta: CGFloat) {
        (self as? SourceTextView)?.beginUserScrolling()
        contentOffset.y = min(max(0, contentOffset.y + delta), max(0, contentSize.height - bounds.height))
        (self as? SourceTextView)?.beginUserScrolling()
    }
    private func stopColumnEdgeScroll() { columnScrollTimer?.invalidate(); columnScrollTimer = nil }
    private func updateColumnRectangle(to point: ColumnSelection.Point) {
        guard let anchor = columnAnchor else { return }
        columnTargets = ColumnSelection.targets(in: text ?? "", from: anchor, to: point, lineIndex: navigationHost?.index)
        applyingColumn = true
        if let first = columnTargets.first { selectedRange = first.range }
        applyingColumn = false; drawColumnSelection()
    }
    /// 将触点换算为逻辑行和标尺列；短行右侧保留虚拟列，输入时才补空格。
    private func columnPoint(at point: CGPoint) -> ColumnSelection.Point {
        let source = text ?? "", lines = navigationHost?.index ?? SourceLineIndex(source)
        let cell = max(1, (" " as NSString).size(withAttributes: [.font: font ?? UIFont.monospacedSystemFont(ofSize: 21, weight: .regular)]).width)
        let location = CGPoint(x: max(0, point.x - textContainerInset.left), y: max(0, point.y - textContainerInset.top))
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        let offset = glyph < layoutManager.numberOfGlyphs ? layoutManager.characterIndexForGlyph(at: glyph) : source.utf16.count
        return .init(row: lines.line(at: min(offset, source.utf16.count)), column: max(0, Int(((point.x - textContainerInset.left - textContainer.lineFragmentPadding) / cell).rounded())))
    }
    @objc private func selectColumnRectangle(_ recognizer: UIPanGestureRecognizer) {
        // 输入法接管或手势取消时也必须清理边缘滚动，避免抬手后计时器继续工作。
        guard columnMode, markedTextRange == nil else { stopColumnEdgeScroll(); columnAnchor = nil; return }
        let location = recognizer.location(in: self)
        let point = columnPoint(at: location)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            columnPanEventCount += 1
            let event = "state\(recognizer.state.rawValue),initial\(columnPan.initialLocation),location\(location),point\(point)"
            if recognizer.state == .began { columnPanBeginTrace = event }
            columnPanTrace = "events\(columnPanEventCount),began[\(columnPanBeginTrace)],last[\(event)]"
        }
        #endif
        if let viewport = navigationHost?.horizontalScroll {
            let converted = convert(location, to: viewport)
            columnDragInViewport = CGPoint(x: converted.x - viewport.bounds.minX, y: converted.y - viewport.bounds.minY)
        }
        switch recognizer.state {
        case .began:
            columnAnchor = columnPoint(at: columnPan.initialLocation)
            // 先保存逻辑起点，再弹键盘；键盘引发的视口缩小不会改变起点。
            _ = becomeFirstResponder()
            stopColumnEdgeScroll()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.extendColumnAtEdge() }
            columnScrollTimer = timer; RunLoop.main.add(timer, forMode: .common)
        case .changed, .ended: break
        case .cancelled, .failed: stopColumnEdgeScroll(); columnAnchor = nil; return
        default: return
        }
        updateColumnRectangle(to: point)
        if recognizer.state == .ended { stopColumnEdgeScroll(); columnAnchor = nil }
    }
    var columnTargets: [ColumnSelection.Target] = []
    var columnRanges: [NSRange] {
        get { columnTargets.map(\.range) }
        set { columnTargets = newValue.map { .init(range: $0) } }
    }
    private var columnComposition: (String, [ColumnSelection.Target])?
    private var columnCompositionUndo: UndoManager?
    private var updatingMarkedText = false
    var applyingColumn = false
    func alignColumnTabs() {
        let font = font ?? UIFont.monospacedSystemFont(ofSize: 21, weight: .regular)
        let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
        paragraph.defaultTabInterval = max(1, (" " as NSString).size(withAttributes: [.font: font]).width) * 4
        typingAttributes[.paragraphStyle] = paragraph
        textStorage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (text as NSString).length))
        EditorColumnGrid.apply(to: textStorage, font: font, enabled: columnMode)
    }
    private var columnOverlays: [UIView] = []
    override var keyCommands: [UIKeyCommand]? {
        guard !columnTargets.isEmpty, markedTextRange == nil else { return super.keyCommands }
        let horizontal = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].flatMap { input in
            [UIKeyModifierFlags(), .shift, .command, [.command, .shift]].map { flags in
                UIKeyCommand(input: input, modifierFlags: flags, action: #selector(navigateColumns(_:)))
            }
        }
        let vertical = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow].flatMap { input in
            [UIKeyModifierFlags.shift, [.command, .shift]].map { UIKeyCommand(input: input, modifierFlags: $0, action: #selector(navigateColumns(_:))) }
        }
        let commands = horizontal + vertical
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands + (super.keyCommands ?? [])
    }
    @objc private func navigateColumns(_ command: UIKeyCommand) {
        let forward = command.input == UIKeyCommand.inputRightArrow || command.input == UIKeyCommand.inputDownArrow
        let rows = command.input == UIKeyCommand.inputUpArrow || command.input == UIKeyCommand.inputDownArrow
        let lines = navigationHost?.index ?? SourceLineIndex(text)
        columnTargets = rows ? ColumnSelection.extendingRows(in: text, targets: columnTargets, direction: forward ? 1 : -1, lineIndex: lines) : ColumnSelection.move(in: text, targets: columnTargets, direction: forward ? 1 : -1, byWord: command.modifierFlags.contains(.command), extending: command.modifierFlags.contains(.shift), lineIndex: lines)
        applyingColumn = true
        if let first = columnTargets.first { selectedRange = first.range; scrollRangeToVisible(first.range) }
        applyingColumn = false; drawColumnSelection()
    }
    func drawColumnSelection() {
        columnOverlays.forEach { $0.removeFromSuperview() }; columnOverlays = []
        guard !columnTargets.isEmpty else { return }
        let width = max(1, (" " as NSString).size(withAttributes: [.font: font ?? UIFont.monospacedSystemFont(ofSize: 21, weight: .regular)]).width)
        for target in columnTargets {
            let range = target.range
            guard let start = position(from: beginningOfDocument, offset: range.location) else { continue }
            let rects: [CGRect]
            if range.length == 0 {
                var rect = caretRect(for: start); rect.origin.x += CGFloat(target.virtualSpaces) * width; rect.size.width = 1.5
                rects = [rect]
            } else if let end = position(from: start, offset: range.length), let selection = textRange(from: start, to: end) {
                rects = selectionRects(for: selection).map(\.rect)
            } else { continue }
            for rect in rects where !rect.isEmpty && rect.intersects(bounds) {
                let overlay = UIView(frame: rect); overlay.backgroundColor = tintColor.withAlphaComponent(range.length == 0 ? 1 : 0.2); overlay.isUserInteractionEnabled = false
                addSubview(overlay); columnOverlays.append(overlay)
            }
        }
    }
    func applyEdit(_ value: String, targets: [ColumnSelection.Target] = []) {
        guard isEditable else { return }
        let old = text ?? "", oldRange = selectedRange, oldTargets = columnTargets
        applyingColumn = true
        if targets.isEmpty && oldTargets.isEmpty {
            // 普通全文替换交给 UITextInput 同步显示和登记系统撤销。
            // UIKit 可能延后登记；再手动登记一次会让重做变成原文到原文的空操作。
            if let range = textRange(from: beginningOfDocument, to: endOfDocument) {
                replace(range, withText: value)
            }
        } else {
            // 列编辑还需要恢复每行选区与虚拟空格，使用单一自定义撤销记录。
            undoManager?.registerUndo(withTarget: self) { target in
                target.applyEdit(old, targets: oldTargets)
                if oldTargets.isEmpty { target.selectedRange = oldRange }
            }
            inputDelegate?.textWillChange(self)
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: value)
            inputDelegate?.textDidChange(self)
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
        columnTargets = targets; alignColumnTabs()
        if let first = targets.first { selectedRange = first.range }
        delegate?.textViewDidChange?(self); drawColumnSelection(); applyingColumn = false
    }
    private func editColumns(_ command: ColumnSelection.Command) {
        guard isEditable else { return }
        let result = ColumnSelection.edit(text, targets: columnTargets, command: command)
        guard !result.targets.isEmpty, result.text != text || result.targets != columnTargets else { return }
        applyEdit(result.text, targets: result.targets)
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if !columnTargets.isEmpty && columnComposition == nil {
            columnComposition = (text, columnTargets)
            if let manager = undoManager, manager.isUndoRegistrationEnabled { manager.disableUndoRegistration(); columnCompositionUndo = manager }
        }
        updatingMarkedText = true; applyingColumn = true; super.setMarkedText(markedText, selectedRange: selectedRange); applyingColumn = false; updatingMarkedText = false
    }
    private func finishColumnComposition(_ value: String) {
        guard let (original, targets) = columnComposition else { return }
        columnComposition = nil; super.unmarkText()
        applyingColumn = true
        textStorage.replaceCharacters(in: NSRange(location: 0, length: text.utf16.count), with: original)
        columnTargets = targets; alignColumnTabs(); applyingColumn = false
        columnCompositionUndo?.enableUndoRegistration(); columnCompositionUndo = nil
        editColumns(.insert(value))
    }
    override func unmarkText() {
        if updatingMarkedText { super.unmarkText(); return }
        if columnComposition != nil { finishColumnComposition(markedTextRange.flatMap { text(in: $0) } ?? "") }
        else { super.unmarkText() }
    }
    override func insertText(_ inserted: String) {
        if updatingMarkedText { super.insertText(inserted); return }
        if columnComposition != nil { finishColumnComposition(inserted); return }
        guard !columnTargets.isEmpty, markedTextRange == nil else { super.insertText(inserted); return }
        editColumns(.insert(inserted))
    }
    override func deleteBackward() {
        guard !columnTargets.isEmpty, markedTextRange == nil else { super.deleteBackward(); return }
        editColumns(.backspace)
    }
    override func selectAll(_ sender: Any?) {
        guard columnMode, markedTextRange == nil else {
            columnTargets = []; drawColumnSelection(); super.selectAll(sender); return
        }
        columnTargets = ColumnSelection.allTargets(in: text ?? "", lineIndex: navigationHost?.index)
        applyingColumn = true
        if let first = columnTargets.first { selectedRange = first.range }
        applyingColumn = false; drawColumnSelection()
    }
    override func copy(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard !columnTargets.isEmpty else { super.copy(sender); return }
        guard columnRanges.contains(where: { $0.length > 0 }) else { return }
        UIPasteboard.general.string = columnRanges.map { (text as NSString).substring(with: $0) }.joined(separator: "\n")
    }
    override func cut(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard !columnTargets.isEmpty else { super.cut(sender); return }
        copy(sender); editColumns(.cut)
    }
    override func paste(_ sender: Any?) {
        if columnComposition != nil { unmarkText() }
        guard !columnTargets.isEmpty, let value = UIPasteboard.general.string else { super.paste(sender); return }
        editColumns(.paste(value))
    }

}
struct NativeEditor: UIViewRepresentable {
    @Environment(\.locale) private var appLocale
    var text: String
    var position: Int
    var navigationID: UUID
    var fontSize: Double
    var format: TextFormat
    var wrapsLines: Bool
    var theme: ReadingTheme
    var columnMode: Bool
    var mutation: EditorMutation?
    var onChange: (String) -> Void
    var onPosition: (Int) -> Void
    var documentID: UUID? = nil
    var viewState: EditorViewState? = nil
    var readOnly = false
    var active = true
    var navigationEnabled = true
    var onFocus: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 500)
    }
    func makeUIView(context: Context) -> EditorHost {
        // 创建、复用和同步原生视图时，系统可能同步回调选区或结束编辑；
        // 此时不能反向发布 SwiftUI 状态，只有用户操作才回写模型。
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if let host = viewState?.host {
            host.editor.delegate = context.coordinator; host.editor.onFocus = onFocus
            context.coordinator.editor = host.editor; context.coordinator.host = host
            host.onViewportScroll = { [weak coordinator = context.coordinator] in coordinator?.highlight() }
            context.coordinator.navigationID = navigationID
            if viewState != nil { context.coordinator.mutationID = mutation?.id }
            DispatchQueue.main.async { [weak editor = host.editor, weak state = viewState] in if state?.active != false { _ = editor?.becomeFirstResponder() } }
            // 旧异步任务不再拥有该视图；由新代理按当前主题重新高亮。
            context.coordinator.highlight()
            return host
        }
        // 不能先创建 UITextView 再把它的 layoutManager 挪到另一存储；
        // UIKit 会保留原 textStorage，导致属性已更新而实际排版仍使用旧数据。
        let host = EditorHost(frame: .zero, storage: viewState?.storage); let editor = host.editor
        viewState?.host = host
        editor.documentID = documentID; editor.onFocus = onFocus
        editor.navigationHost = host
        host.wrapsLines = wrapsLines
        editor.isEditable = !readOnly; editor.isSelectable = true
        editor.backgroundColor = UIColor(red: 0.99, green: 0.987, blue: 0.975, alpha: 1)
        if editor.text != text { editor.text = text }
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular); editor.alignColumnTabs()
        editor.textContainerInset = UIEdgeInsets(top: 18, left: 12, bottom: 32, right: 12)
        editor.autocorrectionType = .no; editor.smartQuotesType = .no; editor.smartDashesType = .no
        editor.alwaysBounceVertical = true; editor.keyboardDismissMode = .interactive
        editor.accessibilityIdentifier = "manuscriptEditor"
        editor.selectedRange = NSRange(location: min(position, text.utf16.count), length: 0)
        context.coordinator.editor = editor; context.coordinator.host = host; context.coordinator.navigationID = navigationID
        host.onViewportScroll = { [weak coordinator = context.coordinator] in coordinator?.highlight() }
        if viewState != nil { context.coordinator.mutationID = mutation?.id }
        // 初始选区设置完成后才挂代理，避免 makeUIView 期间发布状态。
        editor.delegate = context.coordinator
        DispatchQueue.main.async { [weak editor, weak state = viewState] in if state?.active != false { _ = editor?.becomeFirstResponder() } }
        context.coordinator.highlight()
        host.updateSource(text); host.applyTheme(theme)
        editor.applyBaseFont(.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        editor.columnMode = columnMode
        if let position = viewState?.restoredPosition {
            viewState?.restoredPosition = nil
            let location = min(max(0, position.cursor), text.utf16.count)
            editor.selectedRange = NSRange(location: location, length: min(max(0, position.selectionLength), text.utf16.count - location))
            DispatchQueue.main.async { [weak host] in host?.restoreScrollPosition(CGPoint(x: position.x, y: position.y)) }
        }
        return host
    }
    func updateUIView(_ host: EditorHost, context: Context) {
        // 创建、复用和同步原生视图时，系统可能同步回调选区或结束编辑；
        // 此时不能反向发布 SwiftUI 状态，只有用户操作才回写模型。
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        if viewState != nil {
            let showing = host.isHidden && active
            host.isHidden = !active; host.accessibilityElementsHidden = !active
            host.editor.isAccessibilityElement = active
            host.editor.accessibilityIdentifier = active ? "manuscriptEditor" : "inactiveManuscriptEditor"
            if showing { DispatchQueue.main.async { [weak host] in if let host, !host.isHidden { _ = host.editor.becomeFirstResponder() } } }
        }
        host.gutter.accessibilityLabel = L10n.tr("行号")
        host.ruler.accessibilityLabel = L10n.tr("列标尺")
        let c = context.coordinator; let previous = c.parent; c.parent = self
        let editor = host.editor
        // 输入法组合期间不替换正文，但显示主题仍须即时同步，避免黑底保留黑字。
        host.applyTheme(theme)
        guard editor.markedTextRange == nil else { return }
        editor.isEditable = !readOnly; editor.onFocus = onFocus
        editor.columnMode = columnMode
        if previous.columnMode != columnMode { editor.columnRanges = []; editor.drawColumnSelection(); if columnMode { host.wrapsLines = false } }
        // 新的可撤销编辑优先于本轮 SwiftUI 文本快照；快照可能仍是替换前的正文，
        // 不能在 applyEdit 后立即用旧 text 覆盖它，否则面板显示成功、关闭后正文却回退。
        if let mutation, c.mutationID != mutation.id { c.mutationID = mutation.id; editor.applyEdit(mutation.text) }
        else if !editor.textStorage.mutableString.isEqual(to: text) {
            c.textGeneration &+= 1
            let manager = editor.undoManager, registered = editor.undoManager?.isUndoRegistrationEnabled == true
            if registered { manager?.disableUndoRegistration() }
            // 保留工作区共享的文本存储，同时通知 UIKit 更新可见正文与输入缓存。
            if viewState != nil, let range = editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument) {
                editor.replace(range, withText: text)
            } else { editor.text = text }
            if registered { manager?.enableUndoRegistration() }
            editor.alignColumnTabs(); host.updateSource(text); c.highlight()
        }
        if !(previous.text as NSString).isEqual(to: text) {
            // 共享文本存储可能已由另一个原生编辑入口更新，同步发布时仍须使着色缓存失效。
            c.textGeneration &+= 1
            host.updateSource(text); c.highlight()
        }
        host.applyTheme(theme)
        if editor.font?.pointSize != CGFloat(fontSize) {
            editor.applyBaseFont(.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)); editor.alignColumnTabs()
            host.resizeText(); host.refreshMargins(); c.highlight()
        }
        if c.navigationID != navigationID && !navigationEnabled { c.navigationID = navigationID }
        if c.navigationID != navigationID {
            c.navigationID = navigationID
            editor.selectedRange = NSRange(location: min(max(0, position), text.utf16.count), length: 0); editor.scrollRangeToVisible(editor.selectedRange)
            host.requestHorizontalCaretReveal()
            _ = editor.becomeFirstResponder()
        }
        if host.wrapsLines != wrapsLines {
            host.wrapsLines = wrapsLines; host.resizeText(); editor.scrollRangeToVisible(editor.selectedRange); host.refreshMargins()
        }
        if previous.format != format || previous.theme != theme { c.highlight() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeEditor
        weak var editor: ColumnTextView?
        weak var host: EditorHost?
        var textGeneration: UInt64 = 0
        /// 着色仅随正文版本、格式、主题或未覆盖的可见区变化，避免颜色更新触发滚动后反复重涂。
        private var lastHighlight: (generation: UInt64, range: NSRange, format: TextFormat, theme: ReadingTheme)?
        private var pendingTextChange: EditorTextChange?
        private var requiresFullIndexRefresh = false
        var navigationID: UUID?
        var mutationID: UUID?
        var updating = false
        var work: Task<Void, Never>?
        #if DEBUG
        private var lastScrollY: CGFloat = 0
        private var scrollStackCount = 0
        #endif
        init(_ parent: NativeEditor) { self.parent = parent }
        deinit { work?.cancel() }
        /// 只记录 UIKit 即将执行的编辑，不自行改写文本，保留系统输入法、选区和撤销行为。
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if pendingTextChange != nil { requiresFullIndexRefresh = true }
            pendingTextChange = EditorTextChange(range: range, replacementLength: text.utf16.count, previousLength: textView.textStorage.length)
            return true
        }
        func textViewDidChange(_ editor: UITextView) {
            textGeneration &+= 1
            let change = requiresFullIndexRefresh ? nil : pendingTextChange
            pendingTextChange = nil
            #if DEBUG
            let performanceStart = EditorPerformanceTrace.start()
            defer { EditorPerformanceTrace.finish("inputCallback", performanceStart, units: editor.textStorage.length) }
            traceState("input", editor)
            #endif
            #if DEBUG
            (editor as? ColumnTextView)?.changeDiagnostics = "callback=true;updating=\(updating);marked=\(editor.markedTextRange != nil);currentDelegate=\(editor.delegate === self);callbackUndo=\(editor.undoManager?.canUndo == true)"
            #endif
            guard !updating else { return }
            guard editor.markedTextRange == nil else { requiresFullIndexRefresh = true; return }
            requiresFullIndexRefresh = false
            let value = editor.text ?? ""
            if !(value as NSString).isEqual(to: parent.text) {
                (editor as? SourceTextView)?.resumeCaretTracking()
                if let column = editor as? ColumnTextView, column.columnMode && !column.applyingColumn { column.alignColumnTabs() }
            }
            host?.updateSource(value, edit: change); host?.resizeText()
            parent.onChange(value); parent.onPosition(editor.selectedRange.location); highlight()
        }
        func textViewDidChangeSelection(_ editor: UITextView) {
            #if DEBUG
            traceState("selection", editor)
            #endif
            guard !updating, editor.markedTextRange == nil else { return }
            host?.selectionDidChange()
            if let columnEditor = editor as? ColumnTextView, columnEditor.columnMode && !columnEditor.applyingColumn {
                if !columnEditor.columnTargets.isEmpty && editor.selectedRange == columnEditor.columnTargets[0].range { return }
                let range = editor.selectedRange
                columnEditor.columnTargets = ColumnSelection.targets(in: editor.text, from: ColumnSelection.point(in: editor.text, at: range.location, lineIndex: host?.index), to: ColumnSelection.point(in: editor.text, at: NSMaxRange(range), lineIndex: host?.index), lineIndex: host?.index)
                columnEditor.drawColumnSelection()
            }
            parent.onPosition(editor.selectedRange.location)
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? SourceTextView)?.beginUserScrolling()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            #if DEBUG
            let y = scrollView.contentOffset.y
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), y - lastScrollY > 300, scrollView.bounds.height < 500,
               !scrollView.isDragging, !scrollView.isDecelerating, scrollStackCount < 2 {
                scrollStackCount += 1
                NSLog("INK_EDITOR_SCROLL event=%d y=%@ old=%@ bounds=%@", scrollStackCount, String(describing: y), String(describing: lastScrollY), String(describing: scrollView.bounds))
                for (index, frame) in Thread.callStackSymbols.prefix(35).enumerated() {
                    NSLog("INK_EDITOR_SCROLL_FRAME event=%d index=%d %@", scrollStackCount, index, frame)
                }
            }
            lastScrollY = y
            #endif
            (scrollView as? SourceTextView)?.recordUserScrolling()
            (scrollView as? ColumnTextView)?.drawColumnSelection(); host?.refreshMargins()
            if !updating && (scrollView as? SourceTextView)?.shouldHighlightScrolledViewport != false { highlight() }
        }
        func textViewDidEndEditing(_ editor: UITextView) {
            guard !updating, editor.markedTextRange == nil else { return }
            parent.onChange(editor.text); parent.onPosition(editor.selectedRange.location)
        }
        #if DEBUG
        /// 读取系统编辑器的真实状态，不改写组合文本、选区或撤销栈。
        private func traceState(_ phase: String, _ editor: UITextView) {
            guard EditorPerformanceTrace.enabled else { return }
            EditorPerformanceTrace.state(phase, length: editor.textStorage.length, selection: editor.selectedRange,
                                         marked: editor.markedTextRange != nil,
                                         canUndo: editor.undoManager?.canUndo == true, canRedo: editor.undoManager?.canRedo == true)
        }
        #endif
        func highlight() {
            work?.cancel()
            let generation = textGeneration
            work = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, let editor = self.editor, self.textGeneration == generation, editor.markedTextRange == nil else { return }
                // 直接读取原生存储的有界片段，不为每次可见区刷新桥接整篇大文档。
                let source = editor.textStorage.mutableString
                #if DEBUG
                let performanceStart = EditorPerformanceTrace.start()
                defer { EditorPerformanceTrace.finish("highlight", performanceStart, units: source.length) }
                #endif
                let visible = editor.layoutManager.characterRange(forGlyphRange: editor.layoutManager.glyphRange(forBoundingRect: self.host?.visibleTextRect ?? CGRect(origin: editor.contentOffset, size: editor.bounds.size), in: editor.textContainer), actualGlyphRange: nil)
                guard visible.location != NSNotFound else { return }
                if let applied = self.lastHighlight, applied.generation == generation,
                   applied.format == self.parent.format, applied.theme == self.parent.theme,
                   visible.location >= applied.range.location, NSMaxRange(visible) <= NSMaxRange(applied.range) {
                    return
                }
                let start = min(source.length, max(0, visible.location - 2000))
                let range = NSRange(location: start, length: min(24_000, source.length - start))
                let slice = source.substring(with: range), format = self.parent.format
                let tokens = await Task.detached { SyntaxHighlighter.tokens(in: slice, format: format, baseOffset: range.location) }.value
                // 以原生编辑版本验证异步结果，避免为几万字的局部着色比较几百万字的全文。
                guard !Task.isCancelled, editor.delegate === self, self.textGeneration == generation, editor.markedTextRange == nil else { return }
                #if DEBUG
                let applyStart = EditorPerformanceTrace.start()
                #endif
                self.updating = true
                // 这里只更新颜色；重排期间的可视位置由 SourceTextView 统一维护。
                editor.textStorage.beginEditing(); editor.textStorage.addAttribute(.foregroundColor, value: UIColor(self.parent.theme.foreground), range: range)
                for token in tokens { editor.textStorage.addAttribute(.foregroundColor, value: syntaxColor(token.kind, dark: self.parent.theme == .dark), range: token.range) }
                editor.textStorage.endEditing()
                self.lastHighlight = (generation, range, format, self.parent.theme)
                self.host?.refreshMargins(); self.updating = false
                #if DEBUG
                EditorPerformanceTrace.finish("highlightApply", applyStart, units: range.length)
                #endif
            }
        }
    }
}
#endif

struct EditorMutation { let id = UUID(); let text: String }
