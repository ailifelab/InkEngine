// 在隔离 UI 测试资料库中使用真实 Option 拖动和键盘，检查多光标、虚拟空格、列粘贴及撤销。
import AppKit
import ApplicationServices
import Carbon
let previousInput = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
defer { TISSelectInputSource(previousInput) }
let inputSources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
for source in inputSources {
    guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
    let id = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    if id == "com.apple.keylayout.ABC" { TISSelectInputSource(source); break }
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    fflush(stdout); TISSelectInputSource(previousInput); exit(1)
}
let pid = pid_t(CommandLine.arguments[1])!
let application = AXUIElementCreateApplication(pid)
func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? { var value: CFTypeRef?; AXUIElementCopyAttributeValue(e, name as CFString, &value); return value }
func find(_ e: AXUIElement, _ name: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 45 else { return nil }
    if [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (attribute(e, $0) as? String) == name }) { return e }
    for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let found = find(child, name, depth: depth + 1) { return found } }
    return nil
}
func settle(_ seconds: Double = 0.4) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func press(_ name: String) { guard let element = find(application, name) else { fail("Missing \(name)") }; AXUIElementPerformAction(element, kAXPressAction as CFString); settle() }
func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] { let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!; event.flags = flags; event.post(tap: .cghidEventTap) }; settle()
}
func mouse(_ type: CGEventType, _ point: CGPoint, flags: CGEventFlags = []) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!; event.flags = flags; event.post(tap: .cghidEventTap)
}
func paste(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); key(9, flags: .maskCommand) }
NSRunningApplication(processIdentifier: pid)?.activate(); settle()
press("book-编辑功能测试")
guard let editor = find(application, "manuscriptEditor") else { fail("Missing editor") }
AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
key(0, flags: .maskCommand)
let rows = ["abcdefghij", "a", "1234567890", "ab", "ABCDEFGHIJ", "", "12345", "xy", "abcdefghij", "xy"]
let original = rows.joined(separator: "\n")
paste(original)
func value() -> String { attribute(editor, kAXValueAttribute) as? String ?? "" }
func bounds(_ offset: Int) -> CGRect {
    var range = CFRange(location: offset, length: 1), answer: CFTypeRef?
    let parameter = AXValueCreate(.cfRange, &range)!
    let result = AXUIElementCopyParameterizedAttributeValue(editor, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &answer)
    guard result == .success, let answer else { fail("Missing glyph rectangle at \(offset)") }
    var rect = CGRect.zero; AXValueGetValue(answer as! AXValue, .cgRect, &rect); return rect
}
guard value() == original else { fail("Initial text paste failed") }
let first = bounds(4), last = bounds(original.utf16.count - 2)
let start = CGPoint(x: first.minX + 0.1, y: first.midY), end = CGPoint(x: first.minX + 0.1, y: last.midY)
mouse(.leftMouseDown, start, flags: .maskAlternate); settle(0.15)
for i in 1...20 { mouse(.leftMouseDragged, CGPoint(x: start.x, y: start.y + (end.y - start.y) * Double(i) / 20), flags: .maskAlternate); settle(0.02) }
mouse(.leftMouseUp, end, flags: .maskAlternate); settle()
paste("X")
func inserting(_ input: [String], _ text: String) -> [String] { input.map { row in var row = row; if row.count < 4 { row += String(repeating: " ", count: 4 - row.count) }; let index = row.index(row.startIndex, offsetBy: 4); row.insert(contentsOf: text, at: index); return row } }
let expected = inserting(rows, "X").joined(separator: "\n")
print("Option drag ten rows and pad short lines", value() == expected)
guard value() == expected else { fail("Actual: \(value())\nExpected: \(expected)") }
paste("A\nB\nC")
var clipboardExpected = inserting(rows, "X")
for i in 0..<3 { let index = clipboardExpected[i].index(clipboardExpected[i].startIndex, offsetBy: 5); clipboardExpected[i].insert(contentsOf: ["A", "B", "C"][i], at: index) }
print("Three clipboard rows leave last seven unchanged", value() == clipboardExpected.joined(separator: "\n"))
guard value() == clipboardExpected.joined(separator: "\n") else { fail("Clipboard distribution mismatch") }
key(6, flags: .maskCommand)
guard value() == expected else { fail("Undo must restore ten independent carets") }
key(8) // c
let typedExpected = inserting(rows, "Xc").joined(separator: "\n")
print("Typing after undo preserves ten carets", value() == typedExpected)
guard value() == typedExpected else { fail("Repeated input mismatch") }
key(51)
print("Backspace deletes from all ten rows", value() == expected)
guard value() == expected else { fail("Backspace mismatch") }
if let pinyin = inputSources.first(where: { source in
    guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
    return (Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String) == "com.apple.inputmethod.SCIM.ITABC"
}) {
    let status = TISSelectInputSource(pinyin); settle()
    print("Pinyin selection status", status, "frontmost", NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    func typePinyin() { for code in [CGKeyCode(6), 4, 31, 45, 5, 49] { key(code) } }
    typePinyin(); settle(1.2)
    print("Initial Pinyin value", value())
    if value() == inserting(rows, "Xzhong ").joined(separator: "\n") {
        for _ in 0..<6 { key(6, flags: .maskCommand) }
        guard value() == expected else { fail("Reset of input method English mode failed") }
        // 拼音输入法也有英文状态；用真实 Shift 按键切回中文，再检查候选字提交。
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down)!
            event.flags = down ? .maskShift : []; event.post(tap: .cghidEventTap)
        }
        settle(); typePinyin(); settle(1.2)
    }
    let composed = inserting(rows, "X中").joined(separator: "\n")
    print("Pinyin composition commits to all ten carets", value() == composed)
    guard value() == composed else { fail("Chinese composition mismatch: \(value())") }
    if let abc = inputSources.first(where: { source in
        guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
        return (Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String) == "com.apple.keylayout.ABC"
    }) { TISSelectInputSource(abc); settle() }
    key(6, flags: .maskCommand)
    guard value() == expected else { fail("Chinese composition undo mismatch: " + value()) }
}
print("PASS: native Option drag, virtual spaces, partial column paste, undo, typing, deletion and Chinese composition")
// 按键直接送入原生编辑器，核对每行独立光标的词跳转及正反向选择。
if let abc = inputSources.first(where: { source in
    guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
    return (Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String) == "com.apple.keylayout.ABC"
}) { TISSelectInputSource(abc); settle() }
for (code, flags, expectedRow) in [(CGKeyCode(123), CGEventFlags.maskCommand, "oneX two,three"), (124, .maskCommand, "one twoX,three"), (124, .maskShift, "one Xwo,three"), (124, [.maskCommand, .maskShift], "one X,three")] {
    key(0, flags: .maskCommand); paste(Array(repeating: "one two,three", count: 10).joined(separator: "\n"))
    let source = value(), first = bounds(4), last = bounds(source.utf16.count - 9)
    let start = CGPoint(x: first.minX + 0.1, y: first.midY), end = CGPoint(x: first.minX + 0.1, y: last.midY)
    mouse(.leftMouseDown, start, flags: .maskAlternate); settle(0.1)
    mouse(.leftMouseDragged, end, flags: .maskAlternate); settle(0.2)
    mouse(.leftMouseUp, end, flags: .maskAlternate); settle()
    key(code, flags: flags); paste("X")
    let expected = Array(repeating: expectedRow, count: 10).joined(separator: "\n")
    guard value() == expected else { fail("Column arrow keys \(flags.rawValue) produced: " + value()) }
    print("Native column arrow", code, flags.rawValue, "PASS")
}
print("PASS: Command arrows, Shift arrows and Command Shift arrows operate on all ten rows")
