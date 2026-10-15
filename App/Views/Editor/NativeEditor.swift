import SwiftUI
import InkCore
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
#else
import UIKit
private typealias PlatformColor = UIColor
#endif

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
    weak var navigationHost: EditorHost?
    var focusOnArrival = true
    var columnMode = false
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
    }
    private var columnComposition: (String, [ColumnSelection.Target])?
    private var columnCompositionUndo: UndoManager?
    private var columnMarkedRange = NSRange(location: NSNotFound, length: 0)
    private var columnAnchor: ColumnSelection.Point?
    private var columnLineIndex: SourceLineIndex?
    private var columnActive: Bool { !columnTargets.isEmpty }
    private var cellWidth: CGFloat { max(1, (" " as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 21, weight: .regular)]).width) }
    func applyEdit(_ value: String, targets: [ColumnSelection.Target] = []) {
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 500)
    }
    func makeNSView(context: Context) -> EditorHost {
        let host = EditorHost(); let scroll = host.scroll
        host.wrapsLines = wrapsLines
        let editor = FocusTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        editor.navigationHost = host
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true
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
        editor.string = text; editor.alignColumnTabs()
        editor.setSelectedRange(NSRange(location: min(position, text.utf16.count), length: 0))
        scroll.documentView = editor
        context.coordinator.editor = editor; context.coordinator.host = host; context.coordinator.navigationID = navigationID
        // 初次设置选区属于视图初始化；随后才挂代理，避免初始化期间反向修改 SwiftUI 状态。
        editor.delegate = context.coordinator
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.host?.refreshMargins(); coordinator?.highlight() }
        }
        context.coordinator.highlight()
        host.updateSource(text); host.applyTheme(theme)
        editor.columnMode = columnMode
        return host
    }
    func updateNSView(_ host: EditorHost, context: Context) {
        let c = context.coordinator; let previous = c.parent; c.parent = self
        let editor = host.editor as! FocusTextView
        guard !editor.hasMarkedText() else { return }
        c.updating = true
        defer { c.updating = false }
        editor.columnMode = columnMode
        if previous.columnMode != columnMode { editor.columnRanges = []; if columnMode { host.wrapsLines = false } }
        if let mutation, c.mutationID != mutation.id { c.mutationID = mutation.id; editor.applyEdit(mutation.text) }
        if editor.string != text { editor.string = text; editor.alignColumnTabs(); host.updateSource(text); c.highlight() }
        host.applyTheme(theme)
        if editor.font?.pointSize != CGFloat(fontSize) {
            editor.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular); editor.alignColumnTabs()
            host.resizeText(); host.refreshMargins(); c.highlight()
        }
        // 仅显式定位请求修改选区，普通视图刷新不能移动光标或打断中文输入法的组合文本。
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
                guard !Task.isCancelled, !editor.hasMarkedText(), editor.string == source as String else { return }
                self.updating = true
                storage.beginEditing(); storage.addAttribute(.foregroundColor, value: NSColor(self.parent.theme.foreground), range: range)
                for token in tokens { storage.addAttribute(.foregroundColor, value: syntaxColor(token.kind, dark: self.parent.theme == .dark), range: token.range) }
                storage.endEditing(); self.updating = false; self.host?.refreshMargins()
            }
        }
    }
}
#else
class ColumnTextView: UITextView {
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
    var columnMode = false
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
        let old = text ?? "", oldRange = selectedRange, oldTargets = columnTargets
        undoManager?.registerUndo(withTarget: self) { target in
            target.applyEdit(old, targets: oldTargets)
            if oldTargets.isEmpty { target.selectedRange = oldRange }
        }
        applyingColumn = true; text = value; columnTargets = targets; alignColumnTabs()
        if let first = targets.first { selectedRange = first.range }
        delegate?.textViewDidChange?(self); drawColumnSelection(); applyingColumn = false
    }
    private func editColumns(_ command: ColumnSelection.Command) {
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
        applyingColumn = true; text = original; columnTargets = targets; alignColumnTabs(); applyingColumn = false
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
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: EditorHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 500)
    }
    func makeUIView(context: Context) -> EditorHost {
        let host = EditorHost(); let editor = host.editor
        editor.navigationHost = host
        host.wrapsLines = wrapsLines
        editor.isEditable = true; editor.isSelectable = true
        editor.backgroundColor = UIColor(red: 0.99, green: 0.987, blue: 0.975, alpha: 1)
        editor.text = text; editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular); editor.alignColumnTabs()
        editor.textContainerInset = UIEdgeInsets(top: 18, left: 12, bottom: 32, right: 12)
        editor.autocorrectionType = .no; editor.smartQuotesType = .no; editor.smartDashesType = .no
        editor.alwaysBounceVertical = true; editor.keyboardDismissMode = .interactive
        editor.accessibilityIdentifier = "manuscriptEditor"
        editor.selectedRange = NSRange(location: min(position, text.utf16.count), length: 0)
        context.coordinator.editor = editor; context.coordinator.host = host; context.coordinator.navigationID = navigationID
        // 初始选区设置完成后才挂代理，避免 makeUIView 期间发布状态。
        editor.delegate = context.coordinator
        DispatchQueue.main.async { [weak editor] in editor?.becomeFirstResponder() }
        context.coordinator.highlight()
        host.updateSource(text); host.applyTheme(theme)
        editor.columnMode = columnMode
        return host
    }
    func updateUIView(_ host: EditorHost, context: Context) {
        let c = context.coordinator; let previous = c.parent; c.parent = self
        let editor = host.editor
        guard editor.markedTextRange == nil else { return }
        c.updating = true
        defer { c.updating = false }
        editor.columnMode = columnMode
        if previous.columnMode != columnMode { editor.columnRanges = []; editor.drawColumnSelection(); if columnMode { host.wrapsLines = false } }
        if let mutation, c.mutationID != mutation.id { c.mutationID = mutation.id; editor.applyEdit(mutation.text) }
        if editor.text != text { editor.text = text; editor.alignColumnTabs(); host.updateSource(text); c.highlight() }
        host.applyTheme(theme)
        if editor.font?.pointSize != CGFloat(fontSize) {
            editor.font = .monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular); editor.alignColumnTabs()
            host.resizeText(); host.refreshMargins(); c.highlight()
        }
        if c.navigationID != navigationID {
            c.navigationID = navigationID
            editor.selectedRange = NSRange(location: min(max(0, position), text.utf16.count), length: 0); editor.scrollRangeToVisible(editor.selectedRange)
            editor.becomeFirstResponder()
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
        var navigationID: UUID?
        var mutationID: UUID?
        var updating = false
        var work: Task<Void, Never>?
        init(_ parent: NativeEditor) { self.parent = parent }
        deinit { work?.cancel() }
        func textViewDidChange(_ editor: UITextView) {
            guard !updating, editor.markedTextRange == nil else { return }
            host?.updateSource(editor.text); host?.resizeText()
            parent.onChange(editor.text); parent.onPosition(editor.selectedRange.location); highlight()
        }
        func textViewDidChangeSelection(_ editor: UITextView) {
            guard !updating, editor.markedTextRange == nil else { return }
            if let columnEditor = editor as? ColumnTextView, columnEditor.columnMode && !columnEditor.applyingColumn {
                if !columnEditor.columnTargets.isEmpty && editor.selectedRange == columnEditor.columnTargets[0].range { return }
                let range = editor.selectedRange
                columnEditor.columnTargets = ColumnSelection.targets(in: editor.text, from: ColumnSelection.point(in: editor.text, at: range.location, lineIndex: host?.index), to: ColumnSelection.point(in: editor.text, at: NSMaxRange(range), lineIndex: host?.index), lineIndex: host?.index)
                columnEditor.drawColumnSelection()
            }
            parent.onPosition(editor.selectedRange.location)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { (scrollView as? ColumnTextView)?.drawColumnSelection(); host?.refreshMargins(); highlight() }
        func textViewDidEndEditing(_ editor: UITextView) { parent.onChange(editor.text); parent.onPosition(editor.selectedRange.location) }
        func highlight() {
            work?.cancel()
            work = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, let editor = self.editor, editor.markedTextRange == nil else { return }
                let source = (editor.text ?? "") as NSString
                let visible = editor.layoutManager.characterRange(forGlyphRange: editor.layoutManager.glyphRange(forBoundingRect: CGRect(origin: editor.contentOffset, size: editor.bounds.size), in: editor.textContainer), actualGlyphRange: nil)
                let start = min(source.length, max(0, visible.location - 2000))
                let range = NSRange(location: start, length: min(24_000, source.length - start))
                let slice = source.substring(with: range), format = self.parent.format
                let tokens = await Task.detached { SyntaxHighlighter.tokens(in: slice, format: format, baseOffset: range.location) }.value
                guard !Task.isCancelled, editor.markedTextRange == nil, editor.text == source as String else { return }
                self.updating = true
                editor.textStorage.beginEditing(); editor.textStorage.addAttribute(.foregroundColor, value: UIColor(self.parent.theme.foreground), range: range)
                for token in tokens { editor.textStorage.addAttribute(.foregroundColor, value: syntaxColor(token.kind, dark: self.parent.theme == .dark), range: token.range) }
                editor.textStorage.endEditing(); self.updating = false; self.host?.refreshMargins()
            }
        }
    }
}
#endif

struct EditorMutation { let id = UUID(); let text: String }
