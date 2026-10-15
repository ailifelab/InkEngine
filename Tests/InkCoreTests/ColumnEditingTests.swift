import XCTest
@testable import InkCore

final class ColumnEditingTests: XCTestCase {
    func testKeyboardMovesEachCaretByWordAndKeepsOtherRows() {
        let text = "one two,three\na b;c\n"
        let initial = ColumnSelection.targets(in: text, from: .init(row: 0, column: 0), to: .init(row: 2, column: 0))
        let words = ColumnSelection.move(in: text, targets: initial, direction: 1, byWord: true)
        XCTAssertEqual(words.map(\.headColumn), [3, 1, 0])
        let starts = ColumnSelection.move(in: text, targets: words, direction: 1, byWord: true)
        XCTAssertEqual(starts.map(\.headColumn), [4, 2, 0])
        XCTAssertEqual(ColumnSelection.edit(text, targets: starts, command: .insert("X")).text, "one Xtwo,three\na Xb;c\nX")
    }
    func testShiftReversesSelectionAndCommandShiftSelectsWords() {
        let text = "one two\none two"
        let initial = ColumnSelection.targets(in: text, from: .init(row: 0, column: 4), to: .init(row: 1, column: 4))
        let word = ColumnSelection.move(in: text, targets: initial, direction: 1, byWord: true, extending: true)
        XCTAssertEqual(word.map(\.range.length), [3, 3])
        XCTAssertEqual(ColumnSelection.edit(text, targets: word, command: .insert("X")).text, "one X\none X")
        let left = ColumnSelection.move(in: text, targets: initial, direction: -1, extending: true)
        XCTAssertEqual(left.map(\.range.length), [1, 1])
        let collapsed = ColumnSelection.move(in: text, targets: left, direction: 1, extending: true)
        XCTAssertTrue(collapsed.allSatisfy { $0.range.length == 0 })
        let right = ColumnSelection.move(in: text, targets: collapsed, direction: 1, extending: true)
        XCTAssertEqual(right.map(\.range.length), [1, 1])
    }
    func testKeyboardVirtualColumnsRowExtensionAndUnicodeStayAligned() {
        let text = "abcd\n甲😀乙\na"
        let initial = ColumnSelection.targets(in: text, from: .init(row: 0, column: 4), to: .init(row: 1, column: 4))
        let extended = ColumnSelection.extendingRows(in: text, targets: initial, direction: 1)
        XCTAssertEqual(extended.count, 3); XCTAssertEqual(extended.last?.virtualSpaces, 3)
        let left = ColumnSelection.move(in: text, targets: extended, direction: -1, extending: true)
        XCTAssertEqual(left[1].range.length, 2, "Emoji stays whole")
        XCTAssertEqual(ColumnSelection.edit(text, targets: left, command: .insert("X")).text, "abcX\n甲X乙\na  X")
        XCTAssertEqual(ColumnSelection.extendingRows(in: text, targets: extended, direction: 1), extended)
    }
    func testTenCaretsSurviveRepeatedInputAndUndoStateCanBeRestored() {
        let text = Array(repeating: "abc", count: 10).joined(separator: "\n")
        let targets = ColumnSelection.targets(in: text, from: .init(row: 0, column: 1), to: .init(row: 9, column: 1))
        let first = ColumnSelection.edit(text, targets: targets, command: .insert("中"))
        let second = ColumnSelection.edit(first.text, targets: first.targets, command: .insert("😀"))
        XCTAssertEqual(second.text, Array(repeating: "a中😀bc", count: 10).joined(separator: "\n"))
        XCTAssertEqual(second.targets.count, 10)
        let deleted = ColumnSelection.edit(second.text, targets: second.targets, command: .backspace)
        XCTAssertEqual(deleted.text, first.text)
    }
    func testVirtualSpaceIsOnlyMaterializedOnInput() {
        let text = "abcdef\na\n"
        let targets = ColumnSelection.targets(in: text, from: .init(row: 0, column: 4), to: .init(row: 2, column: 4))
        XCTAssertEqual(targets.map(\.virtualSpaces), [0, 3, 4])
        let result = ColumnSelection.edit(text, targets: targets, command: .insert("X"))
        XCTAssertEqual(result.text, "abcdXef\na   X\n    X")
        let deletion = ColumnSelection.edit(text, targets: targets, command: .backspace)
        XCTAssertEqual(deletion.text, "abcef\na\n")
        XCTAssertEqual(deletion.targets.map(\.virtualSpaces), [0, 2, 3])
    }
    func testThreeClipboardRowsOnlyReplaceFirstThreeOfTen() {
        let text = Array(repeating: "abc", count: 10).joined(separator: "\n")
        let targets = ColumnSelection.targets(in: text, from: .init(row: 0, column: 1), to: .init(row: 9, column: 2))
        let result = ColumnSelection.edit(text, targets: targets, command: .paste("1\r\n2\r\n3"))
        XCTAssertEqual(result.text.components(separatedBy: "\n"), ["a1c", "a2c", "a3c"] + Array(repeating: "abc", count: 7))
        XCTAssertEqual(result.targets.dropFirst(3).map(\.range.length), Array(repeating: 1, count: 7))
        let single = ColumnSelection.edit(result.text, targets: result.targets, command: .paste("X"))
        XCTAssertEqual(single.text.components(separatedBy: "\n"), ["a1Xc", "a2Xc", "a3Xc"] + Array(repeating: "aXc", count: 7))
    }
    func testUnassignedShortRowsAreNotPadded() {
        let targets = ColumnSelection.targets(in: "ab\n\n\n", from: .init(row: 0, column: 4), to: .init(row: 3, column: 4))
        let result = ColumnSelection.edit("ab\n\n\n", targets: targets, command: .paste("X\nY"))
        XCTAssertEqual(result.text, "ab  X\n    Y\n\n")
        XCTAssertEqual(result.targets.suffix(2).map(\.virtualSpaces), [4, 4])
    }
    func testDeleteNeverJoinsSeparateRows() {
        let text = "😀a\n中文\n"
        let start = ColumnSelection.targets(in: text, from: .init(row: 0, column: 0), to: .init(row: 2, column: 0))
        XCTAssertEqual(ColumnSelection.edit(text, targets: start, command: .backspace).text, text)
        XCTAssertEqual(ColumnSelection.edit(text, targets: start, command: .deleteForward).text, "a\n文\n")
    }
    func testChineseEmojiAndTabUseVisualColumns() {
        let text = "abcdef\n甲乙丙\n😀ab\n\tx"
        let targets = ColumnSelection.targets(in: text, from: .init(row: 0, column: 4), to: .init(row: 3, column: 4))
        XCTAssertEqual(ColumnSelection.edit(text, targets: targets, command: .insert("X")).text, "abcdXef\n甲乙X丙\n😀abX\n\tXx")
    }
    func testExtraClipboardRowsExtendDownInsteadOfLosingText() {
        let text = "ab\ncd"
        let targets = ColumnSelection.targets(in: text, from: .init(row: 0, column: 1), to: .init(row: 1, column: 1))
        XCTAssertEqual(ColumnSelection.edit(text, targets: targets, command: .paste("1\n2\n3\n4")).text, "a1b\nc2d\n 3\n 4")
    }
}
