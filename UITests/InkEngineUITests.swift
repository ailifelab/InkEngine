import XCTest
#if os(macOS)
import AppKit
import Carbon
import ApplicationServices
#else
import UIKit
#endif

final class InkEngineUITests: XCTestCase {
    #if os(macOS)
    private var previousInputSource: TISInputSource?
    #endif
    override func setUp() {
        super.setUp(); continueAfterFailure = false
        #if os(macOS)
        // ASCII 编辑测试使用固定键盘布局，避免 XCTest 弹出系统输入源选择框；结束后恢复。
        previousInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        if let source = sources.first(where: { source in
            guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
            return id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US"
        }) { TISSelectInputSource(source) }
        #endif
    }
    override func tearDown() {
        #if os(macOS)
        if let previousInputSource { TISSelectInputSource(previousInputSource) }
        #endif
        super.tearDown()
    }
    private func launch(_ app: XCUIApplication) {
        #if os(macOS)
        // 测试重新启动时不恢复上一次已关闭的窗口，但保留应用文稿和偏好。
        if !app.launchArguments.contains("-ApplePersistenceIgnoreState") { app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"] }
        #endif
        app.launch()
        #if os(macOS)
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Window", "窗口", "視窗"])).firstMatch.press(); app.menuItems["显示主窗口"].press()
        }
        #endif
    }
    #if os(iOS)
    /// 运行时告警专项：真实切换三轮，不以功能通过替代 xcresult 与系统日志检查。
    func testViewUpdateRuntimeWarningsDuringWorkspaceTransitions() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        app.launchEnvironment["NSUnbufferedIO"] = "YES"
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        editor.press(); app.typeText("RuntimePreserved42")
        let original = try XCTUnwrap(editor.value as? String)
        for round in 1...3 {
            print("RUNTIME_ROUND_BEGIN \(round)")
            chooseColumnTestMenu("列模式", in: app)
            XCTAssertTrue(editor.label.contains("columnMode=true;"))
            visibleEditorWrap(in: app).pressAtCenter()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.label.contains("nativeWrapping=true;") && editor.label.contains("columnMode=false;") }, object: nil)], timeout: 10), .completed)
            XCTAssertEqual(editor.value as? String, original)
            let state = XCTAttachment(string: editor.label); state.name = "Runtime-Editor-State-\(round)"; state.lifetime = .keepAlways; add(state)
            app.buttons["modeToggle"].firstMatch.pressAtCenter()
            XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.waitForExistence(timeout: 15))
            app.buttons["modeToggle"].firstMatch.pressAtCenter()
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            XCTAssertEqual(editor.value as? String, original)
            for title in ["标签甲.txt", "标签乙.txt"] {
                let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", title)).firstMatch
                if tab.exists { tab.pressAtCenter() }
                else {
                    app.buttons["toggleChapterSidebar"].firstMatch.pressAtCenter()
                    let item = app.buttons[title == "标签甲.txt" ? "book-标签甲" : "book-标签乙"].firstMatch
                    XCTAssertTrue(item.waitForExistence(timeout: 10)); item.pressAtCenter()
                }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (app.staticTexts["workspaceTabNames"].firstMatch.value as? String) == "标签乙.txt" || app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch.exists }, object: nil)], timeout: 10), .completed)
            let returnedReader = app.descendants(matching: .any)["reader"].firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.exists || returnedReader.exists }, object: nil)], timeout: 15), .completed)
            if returnedReader.exists { app.buttons["modeToggle"].firstMatch.pressAtCenter() }
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            XCTAssertEqual(editor.value as? String, original)
            snapshot(app, "Runtime-Transitions-Round-\(round)")
            print("RUNTIME_ROUND_END \(round)")
        }
    }
    func testWindowSizeChangesPreserveUnsavedTabs() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        editor.press(); editor.typeText("ResizePreservedText")
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.exists else { throw XCTSkip("Requires multi-document controls") }
        let initialNames = app.staticTexts["workspaceTabNames"].firstMatch.value as? String
        let initialTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch.identifier
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            expectation(for: NSPredicate { _, _ in
                (editor.value as? String ?? "").contains("ResizePreservedText")
            }, evaluatedWith: editor); waitForExpectations(timeout: 10)
            XCTAssertEqual(app.staticTexts["workspaceTabNames"].firstMatch.value as? String, initialNames)
            XCTAssertTrue(app.buttons[initialTab].firstMatch.exists)
            let toolbar = app.descendants(matching: .any)["workspaceToolbar"].firstMatch
            let tabs = app.descendants(matching: .any)["workspaceTabBar"].firstMatch
            if tabs.exists {
                XCTAssertLessThanOrEqual(toolbar.frame.maxY, tabs.frame.minY + 1)
                XCTAssertLessThanOrEqual(tabs.frame.maxY, editor.frame.minY + 1)
            }
        }
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["readerPaper"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains("ResizePreservedText"))
        snapshot(app, "Workspace-Resize-Preserves-Unsaved-Tabs")
    }
    func testNarrowingAndWideningRestoreBothEditorPanes() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("Needs a wide scene") }
        editor.press(); editor.typeText("SplitResizeText")
        app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter()
        let clone = app.buttons["克隆到另一视图"].firstMatch
        XCTAssertTrue(clone.waitForExistence(timeout: 5)); clone.press()
        let bars = app.descendants(matching: .any).matching(identifier: "workspaceTabBar")
        expectation(for: NSPredicate { _, _ in bars.count == 2 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCUIDevice.shared.orientation = .portrait
        if app.windows.firstMatch.frame.width < 700 {
            expectation(for: NSPredicate { _, _ in bars.count == 1 }, evaluatedWith: app); waitForExpectations(timeout: 10)
            XCTAssertTrue((editor.value as? String ?? "").contains("SplitResizeText"))
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        expectation(for: NSPredicate { _, _ in bars.count == 2 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        for view in app.textViews.matching(identifier: "manuscriptEditor").allElementsBoundByIndex {
            XCTAssertTrue((view.value as? String ?? "").contains("SplitResizeText"))
        }
        snapshot(app, "Workspace-Resize-Restores-Both-Panes")
    }
    #endif

    #if os(iOS)
    #if os(iOS)
    private func visibleEditorWrap(in app: XCUIApplication) -> XCUIElement {
        let candidates = app.descendants(matching: .any).matching(identifier: "editorWrapToggle")
        let visible = candidates.allElementsBoundByIndex.filter { $0.frame.width > 0 && $0.frame.height >= 44 && app.windows.firstMatch.frame.contains($0.frame) }
        // iPad 原生 Toggle 可能给出同框的多个 AX 节点；优先可命中节点，否则由真实点击后的状态断言验收。
        let result = visible.first(where: { $0.isHittable }) ?? candidates.firstMatch
        print("EDITOR_WRAP_AX hittable=\(result.isHittable) frame=\(result.frame)")
        return result
    }
    private func chooseColumnTestMenu(_ label: String, in app: XCUIApplication) {
        app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
        let candidates = app.buttons.matching(NSPredicate(format: "(label == %@ OR identifier == %@) AND identifier != 'assistantUndo' AND identifier != 'assistantRedo'", label, label))
        var item: XCUIElement {
            candidates.allElementsBoundByIndex.first { $0.frame.width > 0 && $0.frame.height > 0 && $0.isHittable } ?? candidates.firstMatch
        }
        func menuViewport() -> XCUIElement {
            // 原生菜单惰性创建离屏项目，先用首屏真实操作定位菜单，再滚动寻找目标。
            // 不能等待离屏目标存在，否则 Duo 矮窗口永远没有机会滚动。
            let menu = app.collectionViews.containing(.button, identifier: "新建文稿").firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "Native document menu must be open")
            let content = menu.frame
            return app.otherElements.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return abs(frame.minX - content.minX) < 2 && abs(frame.width - content.width) < 2 &&
                    frame.height >= 150 && frame.height <= content.height && app.windows.firstMatch.frame.contains(frame)
            }.min(by: { $0.frame.height < $1.frame.height }) ?? menu
        }
        // 同一原生菜单的可见容器不随内容滚动改变；只读取一次，避免逐项 AX 查询成倍拖慢真机验收。
        let viewport = menuViewport()
        let bounds = viewport.frame.intersection(app.windows.firstMatch.frame)
        for _ in 0..<4 {
            if item.exists && item.isHittable && item.frame.width > 0 && bounds.contains(item.frame) { break }
            // 与点击一样以真实菜单元素锚定显示器，避免 app 绝对坐标在内屏被再次旋转。
            viewport.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.width / 2, dy: bounds.height - 50))
                .press(forDuration: 0.1, thenDragTo: viewport.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.width / 2, dy: 70)))
        }
        XCTAssertTrue(item.exists && item.isHittable && bounds.contains(item.frame), app.debugDescription)
        print("NATIVE_DOCUMENT_MENU before label=\(label) target=\(item.frame) app=\(app.windows.firstMatch.frame) viewport=\(bounds)")
        // 交给原生 AX 解析目标屏幕的实际 hitPoint，避免 Duo 多显示器上 app 绝对坐标再次变换。
        item.tap()
        print("NATIVE_DOCUMENT_MENU after label=\(label) menuExists=\(app.collectionViews.containing(.button, identifier: label).firstMatch.exists)")
    }

    /// 真实单指矩形拖选可见三行，输入和触屏撤销重做均核对完整正文；不代表跨屏拖选验收。
    func testMobileColumnTouchRectangleEditsThreeRowsAndUndoRedo() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String ?? "") == "" }, object: nil)], timeout: 10), .completed)
        let original = "AAAA1111ZZZZ\nBBBB2222ZZZZ\nCCCC3333ZZZZ"
        editor.press(); app.typeText(original)
        XCTAssertEqual(editor.value as? String, original)
        chooseColumnTestMenu("列模式", in: app)
        XCTAssertTrue(app.staticTexts["columnTouchHint"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(editor.label.contains("columnMode=true;"))
        func probe(_ name: String) -> CGRect {
            let text = editor.label
            let regex = try! NSRegularExpression(pattern: name + "=\\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\\)")
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { XCTFail("Missing native caret geometry"); return .zero }
            let values = (1...4).map { Double(text[Range(match.range(at: $0), in: text)!])! }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        /// 系统会把长按位置吸附到文字边界；轻点真实且已稳定的插入点，不能复用长按前的固定坐标。
        func requestMenuAtCaret(_ stage: String, visible: @escaping () -> Bool) -> Bool {
            if visible() { return true }
            for attempt in 1...2 {
                var previousSelection = "", stableSince = Date()
                let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let selection = editor.label.components(separatedBy: ";").first { $0.hasPrefix("selection=") } ?? "missing"
                    if selection != previousSelection { previousSelection = selection; stableSince = Date() }
                    return selection != "missing" && Date().timeIntervalSince(stableSince) >= 0.2
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 4), .completed)
                let caret = probe("selectionCaret"), bounds = probe("bounds")
                let viewport = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch.frame
                let point = CGPoint(x: viewport.minX + caret.midX - bounds.minX, y: viewport.minY + caret.midY - bounds.minY)
                XCTAssertTrue(viewport.contains(point), "The actual insertion point must be visible before tapping it")
                print("NATIVE_MENU_CARET \(stage) attempt=\(attempt) point=\(point) before=\(editor.label)")
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
                let shown = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visible() }, object: nil)], timeout: 2) == .completed
                print("NATIVE_MENU_CARET \(stage) attempt=\(attempt) shown=\(shown) after=\(editor.label)")
                if shown { return true }
            }
            return false
        }
        let viewport = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch.frame
        let a = probe("caretProbe4"), b = probe("caretProbe34")
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + a.midX, dy: viewport.minY + a.midY))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: viewport.minX + b.midX, dy: viewport.minY + b.midY))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.label.contains("columnTargets=3;columnRanges=4:4:0|17:4:0|30:4:0;") }, object: nil)], timeout: 10), .completed, editor.label)
        print("MOBILE_COLUMN_SELECTED \(editor.label)")
        snapshot(app, "Mobile-Column-Three-Rows-Selected")
        app.typeText("Q")
        let changed = "AAAAQZZZZ\nBBBBQZZZZ\nCCCCQZZZZ"
        XCTAssertEqual(editor.value as? String, changed)
        chooseColumnTestMenu("撤销", in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String) == original }, object: nil)], timeout: 10), .completed)
        chooseColumnTestMenu("重做", in: app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String) == changed }, object: nil)], timeout: 10), .completed)
        snapshot(app, "Mobile-Column-Three-Rows-Redo")
        var columnMenuPresented: Bool?
        if app.windows.firstMatch.frame.width < 600 {
            // 列拖动优先不能挡住静止长按的系统菜单；只检查出现并取消，不读写用户剪贴板。
            let menu = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["复制", "拷贝", "Copy", "剪切", "Cut", "粘贴", "Paste", "选择", "全选", "Select", "Select All"]))
            func contextVisible() -> Bool {
                // iPad 键盘常驻的粘贴/撤销工具不是长按菜单，不能据此判断菜单仍未关闭。
                menu.allElementsBoundByIndex.contains {
                    !$0.identifier.hasPrefix("assistant") && $0.frame.width > 0 && $0.frame.height > 0 && $0.isHittable
                }
            }
            let rect = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch.frame
            let insertionPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.minX + 70, dy: rect.minY + 30))
            insertionPoint.press(forDuration: 0.8)
            print("COLUMN_LONG_PRESS_INITIAL_MENU \(contextVisible())")
            snapshot(app, "Mobile-Column-Long-Press-Caret")
            columnMenuPresented = requestMenuAtCaret("column", visible: contextVisible)
            print("COLUMN_LONG_PRESS_FINAL_MENU \(columnMenuPresented!)")
            XCTAssertEqual(editor.value as? String, changed)
            snapshot(app, "Mobile-Column-Native-Long-Press-Menu")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.maxY - 40)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !contextVisible() }, object: nil)], timeout: 5), .completed)
        }
        let wrap = visibleEditorWrap(in: app)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(wrap.frame))
        wrap.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            editor.label.contains("columnMode=false;") && editor.label.contains("columnTargets=0;") && editor.label.contains("nativeWrapping=true;") && (self.visibleEditorWrap(in: app).value as? String) == "开启"
        }, object: nil)], timeout: 10), .completed, editor.label)
        XCTAssertEqual(visibleEditorWrap(in: app).value as? String, "开启")
        print("MOBILE_COLUMN_EXIT \(editor.label)")
        XCTAssertFalse(app.staticTexts["columnTouchHint"].firstMatch.exists)
        XCTAssertEqual(editor.value as? String, changed)
        snapshot(app, "Mobile-Column-Exit-With-Wrapping")
        if app.windows.firstMatch.frame.width < 600 {
            let rect = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch.frame
            let insertionPoint = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.minX + 70, dy: rect.minY + 30))
            let menu = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["复制", "拷贝", "Copy", "剪切", "Cut", "粘贴", "Paste", "选择", "全选", "Select", "Select All"]))
            func contextVisible() -> Bool {
                // iPad 键盘常驻的粘贴/撤销工具不是长按菜单，不能据此判断菜单仍未关闭。
                menu.allElementsBoundByIndex.contains {
                    !$0.identifier.hasPrefix("assistant") && $0.frame.width > 0 && $0.frame.height > 0 && $0.isHittable
                }
            }
            insertionPoint.press(forDuration: 0.8)
            print("ORDINARY_LONG_PRESS_INITIAL_MENU \(contextVisible())")
            let ordinaryMenuPresented = requestMenuAtCaret("ordinary", visible: contextVisible)
            print("ORDINARY_LONG_PRESS_FINAL_MENU \(ordinaryMenuPresented)")
            XCTAssertTrue(ordinaryMenuPresented, "The native editing menu must genuinely appear in the control case")
            XCTAssertEqual(columnMenuPresented, ordinaryMenuPresented, "列模式不能阻挡普通编辑同一手势可唤起的系统菜单")
            XCTAssertEqual(editor.value as? String, changed)
            snapshot(app, "Mobile-Ordinary-Native-Long-Press-Menu")
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.maxY - 40)).tap()
        }
    }

    /// 跨屏矩形拖选保留正文；双指滚动由公开设备工具按日志阶段执行，退出后恢复单指滚动。
    func testMobileColumnTouchEdgeSelectionAndTwoFingerScrolling() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        let original = (1...80).map { String(format: "R%03dABCDEFGHIJKL", $0) }.joined(separator: "\n")
        editor.press(); app.typeText(original)
        XCTAssertEqual(editor.value as? String, original)
        let viewport = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch
        func number(_ key: String) -> Double {
            let label = editor.label
            let regex = try! NSRegularExpression(pattern: key + "=([-0-9.]+)")
            guard let m = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let r = Range(m.range(at: 1), in: label) else { XCTFail("Missing " + key); return 0 }
            return Double(label[r]) ?? 0
        }
        func y() -> Double {
            let label = editor.label
            let regex = try! NSRegularExpression(pattern: "contentOffset=\\(([-0-9.]+), ([-0-9.]+)\\)")
            guard let m = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let r = Range(m.range(at: 2), in: label) else { XCTFail("Missing content offset"); return 0 }
            return Double(label[r]) ?? 0
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let rect = viewport.frame
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.minX + rect.width * x, dy: rect.minY + rect.height * y))
        }
        for _ in 0..<10 { point(0.6, 0.2).press(forDuration: 0.05, thenDragTo: point(0.6, 0.75)) }
        XCTAssertLessThan(y(), 2)
        // 将插入点移到当前可见首行，避免打开列模式时显露旧文尾插入点。
        point(0.15, 0.08).tap()
        chooseColumnTestMenu("列模式", in: app)
        XCTAssertTrue(app.staticTexts["columnTouchHint"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThan(y(), 2)
        point(0.22, 0.12).press(forDuration: 0.05, thenDragTo: point(0.43, 0.98), withVelocity: .slow, thenHoldForDuration: 2)
        let targets = number("columnTargets")
        func ranges() -> String {
            editor.label.components(separatedBy: "columnRanges=").last?.components(separatedBy: ";").first ?? ""
        }
        let originalRanges = ranges()
        let offset = y()
        XCTAssertGreaterThan(targets, Double(viewport.frame.height / 25) + 3)
        XCTAssertGreaterThan(offset, 150)
        XCTAssertEqual(editor.value as? String, original)
        snapshot(app, "Mobile-Column-Edge-Crosses-Screen")
        let rect = viewport.frame
        print("COLUMN_TWO_FINGER_READY \(rect.minX) \(rect.minY) \(rect.width) \(rect.height) offset=\(offset) targets=\(targets)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in y() < offset - 60 }, object: nil)], timeout: 60), .completed)
        XCTAssertEqual(number("columnTargets"), targets)
        XCTAssertEqual(ranges(), originalRanges)
        XCTAssertEqual(editor.value as? String, original)
        snapshot(app, "Mobile-Column-Two-Finger-Scroll")
        visibleEditorWrap(in: app).pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.label.contains("columnMode=false;") }, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["columnTouchHint"].firstMatch.exists)
        let before = y()
        point(0.6, 0.75).press(forDuration: 0.05, thenDragTo: point(0.6, 0.2))
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(y(), before + 50)
        XCTAssertEqual(editor.value as? String, original)
        snapshot(app, "Mobile-Column-Exit-Single-Finger-Scroll")
    }

    /// 列模式长行用公开双指水平手势核对外层偏移，并严格保留矩形范围与正文。
    func testMobileColumnTwoFingerHorizontalScrollingPreservesSelection() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        let source = "横向列首" + String(repeating: "AB天地，。", count: 25) + "横向列尾四二"
        editor.press(); app.typeText(source)
        let viewport = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            let r = viewport.frame
            return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: r.minX + r.width * x, dy: r.minY + r.height * y))
        }
        func x() -> Double {
            let text = editor.label
            let regex = try! NSRegularExpression(pattern: "outerOffset=\\(([-0-9.]+),")
            guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) else { XCTFail("Missing outer offset"); return 0 }
            return Double(text[r]) ?? 0
        }
        func ranges() -> String { editor.label.components(separatedBy: "columnRanges=").last?.components(separatedBy: ";").first ?? "" }
        for _ in 0..<14 { point(0.2, 0.2).press(forDuration: 0.05, thenDragTo: point(0.85, 0.2)) }
        XCTAssertLessThan(x(), 2)
        var firstLineY: CGFloat { 30 / viewport.frame.height }
        point(0.2, firstLineY).tap()
        chooseColumnTestMenu("列模式", in: app)
        XCTAssertTrue(app.staticTexts["columnTouchHint"].firstMatch.waitForExistence(timeout: 10))
        let label = editor.label
        let probeRegex = try NSRegularExpression(pattern: "caretProbe4=\\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\\)")
        let match = try XCTUnwrap(probeRegex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)))
        let values = (1...4).map { Double(label[Range(match.range(at: $0), in: label)!])! }
        let frame = viewport.frame
        let startPoint = CGPoint(x: frame.minX + values[0] + values[2] / 2, y: frame.minY + values[1] + values[3] / 2)
        let endPoint = CGPoint(x: startPoint.x + 104, y: startPoint.y)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: startPoint.x, dy: startPoint.y))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: endPoint.x, dy: endPoint.y))
        XCTAssertTrue(frame.contains(start.screenPoint) && frame.contains(end.screenPoint))
        start.press(forDuration: 0.05, thenDragTo: end)
        let originalRanges = ranges(), before = x()
        print("COLUMN_HORIZONTAL_BEFORE ranges=\(originalRanges) native=\(editor.label)")
        snapshot(app, "Mobile-Column-Horizontal-Before-Two-Fingers")
        XCTAssertFalse(originalRanges.isEmpty)
        XCTAssertGreaterThan(Int(originalRanges.components(separatedBy: ":").dropFirst().first ?? "0") ?? 0, 0)
        XCTAssertEqual(originalRanges, "4:5:0", "八个显示格只选中 AB天地，；周围中文保持原样")
        XCTAssertTrue(editor.label.contains("columnTargets=1;"))
        let r = viewport.frame
        print("COLUMN_TWO_FINGER_HORIZONTAL_READY \(r.minX) \(r.minY) \(r.width) \(r.height) offset=\(before)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in x() > before + 60 }, object: nil)], timeout: 60), .completed)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertGreaterThan(x(), before + 60)
        XCTAssertEqual(ranges(), originalRanges)
        XCTAssertEqual(editor.value as? String, source)
        snapshot(app, "Mobile-Column-Two-Finger-Horizontal")
    }

    /// 普通手机长行用真实横向拖动与无辅助查询的静置截图核对首尾，不以正文值代替可见性。
    func testPhoneLongLinesRemainVisibleAfterHorizontalDragging() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        let viewport = app.descendants(matching: .any)["manuscriptHorizontalViewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let samples = [
            ("ASCII", "ASCII_START_" + String(repeating: "0123456789", count: 16) + "_ASCII_END_42"),
            ("Chinese", "中文行首" + String(repeating: "天地玄黄宇宙洪荒", count: 10) + "中文行尾四二")
        ]
        func x() -> Double {
            let label = app.textViews["manuscriptEditor"].firstMatch.label
            return Double((label.components(separatedBy: "outerOffset=(").last ?? "").components(separatedBy: ",").first ?? "") ?? -1
        }
        func containerWidth() -> Double {
            let label = app.textViews["manuscriptEditor"].firstMatch.label
            return Double((label.components(separatedBy: "textContainerSize=(").last ?? "").components(separatedBy: ",").first ?? "") ?? -1
        }
        func settle(_ stage: String) {
            let immediate = XCTAttachment(screenshot: app.screenshot()); immediate.name = "Phone-Long-Line-" + stage + "-Immediate"; immediate.lifetime = .keepAlways; add(immediate)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let settled = XCTAttachment(screenshot: app.screenshot()); settled.name = "Phone-Long-Line-" + stage + "-Settled"; settled.lifetime = .keepAlways; add(settled)
            print("PHONE_LONG_LINE \(stage) frame=\(editor.frame) viewport=\(viewport.frame) native=\(editor.label)")
            let ax = XCTAttachment(string: app.debugDescription); ax.name = "Phone-Long-Line-" + stage + "-AX"; ax.lifetime = .keepAlways; add(ax)
        }
        func visibleTextInk() -> Int {
            // 只读取截图首行正文；排除标尺、行号以及最右侧的插入点，防止空白画布也被误判为文字。
            let frame = viewport.frame
            let screen = app.windows.firstMatch.frame
            guard let image = app.screenshot().image.cgImage,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            let scale = CGFloat(image.width) / screen.width
            let rect = CGRect(x: frame.minX + 24, y: frame.minY + 12, width: max(1, frame.width - 48), height: 40)
            var dark = 0
            for y in Int(rect.minY * scale)..<min(image.height, Int(rect.maxY * scale)) {
                for x in Int(rect.minX * scale)..<min(image.width, Int(rect.maxX * scale)) {
                    let i = y * image.width * 4 + x * 4
                    if Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 300 { dark += 1 }
                }
            }
            return dark
        }
        for (name, source) in samples {
            app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String ?? "") == "" }, object: nil)], timeout: 10), .completed)
            editor.press(); app.typeText(source)
            XCTAssertEqual(editor.value as? String, source)
            settle(name + "-Typed-End")
            for _ in 0..<10 {
                viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).press(forDuration: 0.05, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)))
            }
            settle(name + "-Start")
            let start = x()
            XCTAssertEqual(start, 0, accuracy: 1, "Real dragging must reach the beginning of the line")
            for _ in 0..<10 {
                viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45)).press(forDuration: 0.05, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)))
            }
            settle(name + "-End")
            XCTAssertGreaterThan(x(), start + 100, "Actual horizontal dragging must reach later glyphs after idle")
            let ink = visibleTextInk()
            print("PHONE_LONG_LINE \(name) endGlyphPixels=\(ink)")
            XCTAssertGreaterThan(ink, 100, "The real right-hand viewport must draw text, not only retain its value or caret")
            XCTAssertEqual(editor.value as? String, source)
            XCTAssertLessThan(containerWidth(), 100_000, "A real long line must use a finite native drawing canvas")
            let wrap = visibleEditorWrap(in: app)
            XCTAssertTrue(wrap.waitForExistence(timeout: 10))
            XCTAssertTrue(app.windows.firstMatch.frame.contains(wrap.frame)); XCTAssertGreaterThanOrEqual(wrap.frame.height, 44)
            XCTAssertEqual(wrap.value as? String, "关闭")
            visibleEditorWrap(in: app).pressAtCenter()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (self.visibleEditorWrap(in: app).value as? String) == "开启" && abs(x()) < 1 && containerWidth() <= Double(viewport.frame.width + 1) }, object: nil)], timeout: 10), .completed)
            settle(name + "-Wrapped")
            XCTAssertEqual(editor.value as? String, source)
            XCTAssertGreaterThan(visibleTextInk(), 100, "Wrapping must retain real visible glyphs")
            visibleEditorWrap(in: app).pressAtCenter()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (self.visibleEditorWrap(in: app).value as? String) == "关闭" && containerWidth() > Double(viewport.frame.width) }, object: nil)], timeout: 10), .completed)
            settle(name + "-Unwrapped-Again")
            XCTAssertEqual(editor.value as? String, source)
            XCTAssertGreaterThan(visibleTextInk(), 100, "Turning wrapping off must preserve visible right-hand glyphs")
        }
        let wrap = app.descendants(matching: .any)["editorWrapToggle"].firstMatch
        print("PHONE_LONG_LINE wrapDirect=\(wrap.exists && wrap.isHittable)")
        app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "Phone-Long-Line-More-Wrap-AX"; ax.lifetime = .keepAlways; add(ax)
        snapshot(app, "Phone-Long-Line-More-Wrap")
    }

    /// 隔离普通手机长文：记录键盘出现后真实编辑视口、末尾光标和上下滚动能力。
    func testPhoneKeyboardKeepsLongEditorVisibleAndScrollable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String ?? "") == "" }, object: nil)], timeout: 10), .completed)
        let original = (1...60).map { "Row \($0)\n" }.joined()
        func offsetY() -> Double {
            let current = app.textViews.matching(identifier: "manuscriptEditor").element(boundBy: 0)
            _ = current.frame
            let label = current.label
            print("PHONE_KEYBOARD_OFFSET_READ \(label)")
            let part = label.components(separatedBy: "contentOffset=(").last ?? ""
            return Double(part.components(separatedBy: ")").first?.components(separatedBy: ", ").last ?? "") ?? -1
        }
        func report(_ stage: String) {
            print("PHONE_KEYBOARD \(stage) window=\(app.windows.firstMatch.frame) editor=\(editor.frame) keyboard=\(app.keyboards.firstMatch.exists ? String(describing: app.keyboards.firstMatch.frame) : "none") native=\(editor.label)")
            snapshot(app, "Phone-Keyboard-" + stage)
            let ax = XCTAttachment(string: app.debugDescription); ax.name = "Phone-Keyboard-" + stage + "-AX"; ax.lifetime = .keepAlways; add(ax)
        }
        report("Initial")
        editor.press(); app.typeText(original + "KeyboardEndMarker42")
        XCTAssertEqual(editor.value as? String, original + "KeyboardEndMarker42", "Real selection must reach the end before inserting the marker")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // 不只验收原生文本视口缩小；SwiftUI 底栏也必须避开键盘并可真实点击。
        let wrap = visibleEditorWrap(in: app)
        XCTAssertTrue(wrap.exists && wrap.isHittable, "The editor footer must remain reachable above the software keyboard")
        XCTAssertLessThanOrEqual(wrap.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        report("End-Typed")
        let endImmediate = XCTAttachment(screenshot: app.screenshot()); endImmediate.name = "Phone-Keyboard-NoAX-End-Immediate"; endImmediate.lifetime = .keepAlways; add(endImmediate)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let endSettled = XCTAttachment(screenshot: app.screenshot()); endSettled.name = "Phone-Keyboard-NoAX-End-Settled"; endSettled.lifetime = .keepAlways; add(endSettled)
        let endOffset = offsetY()
        XCTAssertGreaterThan(endOffset, 0, "Caret at the end must scroll the long document vertically")
        editor.swipeDown(); editor.swipeDown(); editor.swipeDown(); editor.swipeDown()
        let immediate = XCTAttachment(screenshot: app.screenshot()); immediate.name = "Phone-Keyboard-NoAX-Top-Immediate"; immediate.lifetime = .keepAlways; add(immediate)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let settled = XCTAttachment(screenshot: app.screenshot()); settled.name = "Phone-Keyboard-NoAX-Top-Settled"; settled.lifetime = .keepAlways; add(settled)
        report("Toward-Top")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        report("Toward-Top-Settled")
        let topOffset = offsetY()
        print("PHONE_KEYBOARD_OFFSETS end=\(endOffset) top=\(topOffset)")
        XCTAssertLessThan(topOffset, endOffset - 100, "Real downward gestures must reveal earlier lines")
        editor.swipeUp(); editor.swipeUp(); editor.swipeUp(); editor.swipeUp()
        let bottomImmediate = XCTAttachment(screenshot: app.screenshot()); bottomImmediate.name = "Phone-Keyboard-NoAX-Bottom-Immediate"; bottomImmediate.lifetime = .keepAlways; add(bottomImmediate)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let bottomSettled = XCTAttachment(screenshot: app.screenshot()); bottomSettled.name = "Phone-Keyboard-NoAX-Bottom-Settled"; bottomSettled.lifetime = .keepAlways; add(bottomSettled)
        report("Toward-End")
        XCTAssertGreaterThan(offsetY(), topOffset + 100, "Real upward gestures must reveal later lines")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Scrolling must work while the software keyboard remains visible")
        XCTAssertTrue((editor.value as? String ?? "").contains("KeyboardEndMarker42"))
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "Keyboard must not cover the editable viewport")
        }
        let status = app.staticTexts["currentMode"].firstMatch
        if status.exists { XCTAssertLessThanOrEqual(editor.frame.maxY, status.frame.minY + 1, "Editor must not overlap its document status") }
    }

    /// 普通手机连续新建空白文稿，直接工具栏保存后重启仍保留独立身份和正文。
    func testPhoneToolbarCreatesDistinctBlankDocumentsAndSaves() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        for id in ["toolbarNewDocument", "toolbarOpenDocument", "toolbarSaveDocument"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10)); XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        app.buttons["toolbarOpenDocument"].firstMatch.pressAtCenter()
        let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.press()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        func identity() -> String { (editor.label.components(separatedBy: "documentID=").last ?? "").components(separatedBy: ";").first ?? "" }
        let initial = identity()
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.exists && identity() != initial && (editor.value as? String ?? "") == "" }, object: nil)], timeout: 15), .completed)
        let first = identity(); XCTAssertFalse(first.isEmpty); XCTAssertNotEqual(first, "none")
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.exists && identity() != first && (editor.value as? String ?? "") == "" }, object: nil)], timeout: 15), .completed)
        let second = identity(); XCTAssertNotEqual(first, second)
        editor.press(); editor.typeText("PhoneNewDocumentSaved42")
        app.buttons["toolbarSaveDocument"].firstMatch.pressAtCenter()
        XCTAssertTrue(app.textFields["workspaceSaveName"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["workspaceSaveFolder"].firstMatch.press()
        let folderAX = XCTAttachment(string: app.debugDescription); folderAX.name = "Phone-Save-Folder-Picker-AX"; folderAX.lifetime = .keepAlways; add(folderAX)
        snapshot(app, "Phone-Save-Folder-Picker")
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["浏览", "Browse", "瀏覽"])).firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10)); browse.press()
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["我的 iPhone", "我的iPhone", "On My iPhone"])).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10)); local.press()
        let applicationFolder = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["墨语引擎", "Ink Engine", "InkEngine"])).firstMatch
        XCTAssertTrue(applicationFolder.waitForExistence(timeout: 10)); applicationFolder.press()
        let isolatedFolder = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'InkEngineUITestExports'")).firstMatch
        XCTAssertTrue(isolatedFolder.waitForExistence(timeout: 10)); isolatedFolder.press()
        let useFolder = app.buttons["DOCPicker.actionButton"].firstMatch
        XCTAssertTrue(useFolder.waitForExistence(timeout: 15)); XCTAssertTrue(useFolder.isEnabled); useFolder.press()
        XCTAssertTrue(app.textFields["workspaceSaveName"].firstMatch.waitForNonExistence(timeout: 15))
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(editor.value as? String, "PhoneNewDocumentSaved42")
        print("PHONE_NEW_DOCUMENT initial=\(initial) first=\(first) second=\(second)")
        snapshot(app, "Phone-New-Document-Saved")
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertEqual(editor.value as? String, "PhoneNewDocumentSaved42")
        XCTAssertEqual(identity(), second)
        snapshot(app, "Phone-New-Document-Relaunched")
        app.buttons["modeToggle"].firstMatch.pressAtCenter()
        XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.waitForExistence(timeout: 15))
        for id in ["toggleChapterSidebar", "toolbarNewDocument", "toolbarOpenDocument", "toolbarSaveDocument", "modeToggle", "appearanceMenu", "playPause", "documentMenu"] {
            let control = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 10)); XCTAssertTrue(control.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), "Reading toolbar must keep \(id) inside the phone window: \(control.frame)")
        }
        snapshot(app, "Phone-Reading-All-Toolbar-Actions")
    }

    /// 仅隔离测试：读取深色编辑器实际前景属性，并保存面板关闭后的正文画面。
    func testPhoneDarkEditorContrastPreservesText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]
        launch(app); openBook("编辑功能测试", app: app)
        app.buttons["modeToggle"].firstMatch.pressAtCenter()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15)); let original = editor.value as? String
        app.buttons["appearanceMenu"].firstMatch.pressAtCenter()
        let dark = app.descendants(matching: .any)["theme-dark"].firstMatch
        XCTAssertTrue(dark.waitForExistence(timeout: 10))
        for _ in 0..<2 where !app.windows.firstMatch.frame.insetBy(dx: 0, dy: 30).contains(dark.frame) { app.collectionViews.firstMatch.swipeUp() }
        dark.pressAtCenter(); app.buttons["完成"].firstMatch.pressAtCenter()
        XCTAssertEqual(editor.value as? String, original)
        snapshot(app, "Phone-Dark-Editor-Closed")
        let ax = XCTAttachment(string: app.debugDescription); ax.name = "Phone-Dark-Editor-Closed-AX"; ax.lifetime = .keepAlways; add(ax)
        print("PHONE_DARK_EDITOR \(editor.label)")
    }

    /// 隔离普通手机主题面板的实际布局，记录界面并检查文稿与阅读位置不变。
    func testPhoneThemePanelsPreserveDocumentAndReadingPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]
        launch(app); openBook("长篇甲", app: app)
        let page = app.staticTexts["pageNumber"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 15), .completed)
        let position = app.staticTexts["readingPosition"].firstMatch.value as? String
        func evidence(_ name: String) {
            snapshot(app, name)
            let ax = XCTAttachment(string: app.debugDescription); ax.name = name + "-AX"; ax.lifetime = .keepAlways; add(ax)
        }
        func palette(_ name: String) {
            app.buttons["appearanceMenu"].firstMatch.pressAtCenter()
            XCTAssertTrue(app.sliders["workspaceFontSize"].firstMatch.waitForExistence(timeout: 10))
            evidence(name)
            app.sliders["workspaceFontSize"].firstMatch.adjust(toNormalizedSliderPosition: 0.4)
            for theme in ["white", "warm", "green", "dark"] {
                let option = app.descendants(matching: .any)["theme-" + theme].firstMatch
                XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
                for _ in 0..<2 where !option.isHittable || !app.windows.firstMatch.frame.insetBy(dx: 0, dy: 30).contains(option.frame) {
                    app.collectionViews.firstMatch.swipeUp()
                }
                XCTAssertTrue(option.isHittable && app.windows.firstMatch.frame.insetBy(dx: 0, dy: 30).contains(option.frame), app.debugDescription)
                option.pressAtCenter()
                evidence(name + "-" + theme)
            }
            app.buttons["完成"].firstMatch.pressAtCenter()
        }
        palette("Phone-Reader-Appearance")
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        app.buttons["modeToggle"].firstMatch.pressAtCenter()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); let original = editor.value as? String
        palette("Phone-Editor-Appearance")
        XCTAssertEqual(editor.value as? String, original)
        chooseColumnTestMenu("字号与朗读设置", in: app)
        XCTAssertTrue(app.buttons["closeSpeechSettings"].firstMatch.waitForExistence(timeout: 10))
        evidence("Phone-Reading-Speech-Settings")
        app.buttons["closeSpeechSettings"].firstMatch.pressAtCenter()
        XCTAssertEqual(editor.value as? String, original)
    }
    #endif

    func testNativeTypingUndoRegistrationAndRedo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let marker = "NativeUndoContinuity42"
        func report(_ stage: String) {
            let undo = app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "missing"
            FileHandle.standardOutput.write(Data("NATIVE_UNDO \(stage) registry=\(undo) native=\(editor.label) text=\(editor.value as? String ?? "")\n".utf8))
        }
        report("before")
        editor.press(); editor.typeText(marker); app.typeKey(.return, modifierFlags: [])
        report("typed")
        XCTAssertTrue((editor.value as? String ?? "").contains(marker))
        var count = 0
        while (editor.value as? String ?? "").contains(marker), count < 3 {
            app.typeKey("z", modifierFlags: .command); count += 1; report("undo-" + String(count))
        }
        XCTAssertFalse((editor.value as? String ?? "").contains(marker), editor.label)
        for _ in 0..<count { app.typeKey("z", modifierFlags: [.command, .shift]) }
        report("redo")
        XCTAssertTrue((editor.value as? String ?? "").contains(marker), editor.label)
    }

    /// The companion driver uses native Home lifting and the OS divider, never window resizing.
    func testDuoOpenPortraitTabsAndContentUseWindowHeight() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        let frame = app.windows.firstMatch.frame
        XCTAssertEqual(frame.width, 669, accuracy: 1)
        XCTAssertEqual(frame.height, 951, accuracy: 1)
        func report(_ stage: String) {
            let identifiers = ["workspaceToolbar", "workspaceTabBar", "workspaceVerticalTabBar", "manuscriptEditor", "reader", "readerPaper", "readerFooter", "pageNumber", "nextPage"]
            for id in identifiers {
                let element = app.descendants(matching: .any)[id].firstMatch
                if element.exists { FileHandle.standardOutput.write(Data("DUO_PORTRAIT \(stage) \(id)=\(element.frame)\n".utf8)) }
            }
            let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch
            FileHandle.standardOutput.write(Data("DUO_PORTRAIT \(stage) keyboards=\(app.keyboards.count) firstKeyboard=\(app.keyboards.firstMatch.exists ? String(describing: app.keyboards.firstMatch.frame) : "none") geometry=\(geometry.label)\n".utf8))
            snapshot(app, "Duo-Open-Portrait-" + stage)
        }
        report("Editor")
        for id in ["toggleChapterSidebar", "toolbarNewDocument", "toolbarOpenDocument", "toolbarSaveDocument", "modeToggle", "appearanceMenu", "documentMenu"] {
            let element = app.descendants(matching: .any)[id].firstMatch
            if element.exists { FileHandle.standardOutput.write(Data("DUO_PORTRAIT BeforeAssert \(id)=\(element.frame)\n".utf8)) }
        }
        let tabs = app.otherElements["workspaceTabBar"].firstMatch
        XCTAssertTrue(tabs.exists)
        let documents = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'"))
        XCTAssertGreaterThanOrEqual(documents.count, 2)
        for tab in documents.allElementsBoundByIndex {
            FileHandle.standardOutput.write(Data("DUO_PORTRAIT ActualTab \(tab.identifier)=\(tab.frame)\n".utf8))
            XCTAssertEqual(tab.frame.midY, 74, accuracy: 2, "Actual file labels belong directly beneath the top toolbar")
        }
        for id in ["toggleChapterSidebar", "toolbarNewDocument", "toolbarOpenDocument", "toolbarSaveDocument", "modeToggle", "appearanceMenu", "documentMenu"] {
            let button = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(button.exists)
            FileHandle.standardOutput.write(Data("DUO_PORTRAIT ToolbarButton \(id)=\(button.frame)\n".utf8))
            XCTAssertLessThanOrEqual(button.frame.minY, 12, "Toolbar button must use top free area")
            XCTAssertFalse(button.frame.intersects(CGRect(x: 525, y: 0, width: 144, height: 82)), "Toolbar button must avoid the actual system status occlusion")
        }
        XCTAssertLessThan(tabs.frame.maxY, editor.frame.minY + 2)
        let editingGeometry = app.staticTexts["workspaceHingeGeometry"].firstMatch.label
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
            XCTAssertGreaterThan(editor.frame.height, 250, "Visible keyboard must leave usable editor height")
        } else {
            XCTAssertTrue(editingGeometry.contains("keyboardVisible=false"), "No native keyboard may reserve a phantom keyboard inset")
            XCTAssertGreaterThan(editor.frame.maxY, frame.maxY - 100)
        }
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(app.staticTexts["pageNumber"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: app.staticTexts["pageNumber"].firstMatch)], timeout: 20), .completed)
        let reader = app.otherElements["reader"].firstMatch
        XCTAssertGreaterThan(reader.frame.maxY, frame.maxY - 36)
        report("Reader")
        // 相同 fixture/字号下，展开竖屏回收原底部安全区中的 22pt 给正文与翻页栏。
        let paper = app.otherElements["readerPaper"].firstMatch
        let next = app.buttons["nextPage"].firstMatch
        XCTAssertEqual(next.frame.minY, 899, accuracy: 1)
        let pageGeometry = app.staticTexts["readerPageGeometry"].firstMatch
        XCTAssertTrue(pageGeometry.waitForExistence(timeout: 10))
        let pageSize = pageGeometry.label.components(separatedBy: "|")
        print("DUO_PORTRAIT Reader pageGeometry=\(pageGeometry.label)")
        XCTAssertEqual(Double(pageSize[1]) ?? 0, 772.6666666666666 + 22, accuracy: 1)
        XCTAssertLessThanOrEqual(paper.frame.maxY, next.frame.minY)
        XCTAssertLessThanOrEqual(next.frame.maxY, frame.maxY - 8)
        let originalPosition = app.staticTexts["readingPosition"].firstMatch.value as? String
        next.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: app.staticTexts["pageNumber"].firstMatch)], timeout: 20), .completed)
        XCTAssertNotEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, originalPosition)
        app.buttons["previousPage"].firstMatch.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: app.staticTexts["pageNumber"].firstMatch)], timeout: 20), .completed)
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, originalPosition)
        let position = app.staticTexts["readingPosition"].firstMatch.value as? String
        let palette = app.descendants(matching: .any)["appearanceMenu"].firstMatch
        XCTAssertTrue(palette.exists && palette.isHittable, "Palette must remain visible in the primary toolbar")
        palette.pressAtCenter()
        let font = app.sliders["workspaceFontSize"].firstMatch
        XCTAssertTrue(font.waitForExistence(timeout: 10))
        let theme = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'theme-'" )).firstMatch
        if theme.exists { theme.press() }
        else { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '界面主题'")).firstMatch.press() }
        app.buttons["暖黄"].firstMatch.press()
        snapshot(app, "Duo-Portrait-Palette-Warm-Selection")
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(font.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        snapshot(app, "Duo-Portrait-Warm-Theme-Applied")
    }

    #if os(iOS)
    /// 收起态保留标准底部安全区，不继承展开竖屏专属的紧凑间距。
    func testDuoClosedReaderKeepsStandardBottomClearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        XCTAssertTrue(app.textViews["manuscriptEditor"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["modeToggle"].firstMatch.press()
        let page = app.staticTexts["pageNumber"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 20), .completed)
        let geometry = app.staticTexts["readerPageGeometry"].firstMatch
        XCTAssertTrue(geometry.waitForExistence(timeout: 10))
        let values = geometry.label.components(separatedBy: "|")
        XCTAssertEqual(Double(values[3]) ?? -1, 0)
        let window = app.windows.firstMatch.frame, next = app.buttons["nextPage"].firstMatch.frame
        XCTAssertEqual(window.maxY - next.maxY, 30, accuracy: 2)
        print("DUO_CLOSED_BOTTOM window=\(window) next=\(next) page=\(geometry.label) hinge=\(app.staticTexts["workspaceHingeGeometry"].firstMatch.label)")
        snapshot(app, "Duo-Closed-Standard-Bottom-Clearance")
    }
    #endif

    func testDuoRealSystemSplitPreservesDraftReaderAndSpeech() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        var step = 0
        func waitValue(_ e: XCUIElement, _ predicate: @escaping (String) -> Bool) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate(e.value as? String ?? "") }, object: e)], timeout: 25), .completed)
        }
        func transition(_ action: String, half: Bool, _ stage: String) {
            step += 1
            FileHandle.standardOutput.write(Data("DUO_SPLIT_BEFORE_\(step)_\(action) \(app.windows.firstMatch.frame)\n".utf8))
            FileHandle.standardOutput.write(Data("DUO_SPLIT_STEP_\(step)_\(action)\n".utf8))
            let began = Date()
            var stableSince: Date?
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                let matches = abs(frame.width - (half ? 469 : 951)) < 0.1 && abs(frame.height - 669) < 0.1
                if matches { if stableSince == nil { stableSince = Date() } }
                else { stableSince = nil }
                return Date().timeIntervalSince(began) > (half ? 11 : 7) && (stableSince.map { Date().timeIntervalSince($0) >= 1.5 } ?? false)
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 35), .completed, "Native split transition \(action): \(app.windows.firstMatch.frame)")
            FileHandle.standardOutput.write(Data("DUO_SPLIT_GEOMETRY \(stage) \(action) \(app.windows.firstMatch.frame)\n".utf8))
            if half {
                let window = app.windows.firstMatch.frame
                let rail = app.descendants(matching: .any)["workspaceVerticalTabBar"].firstMatch
                XCTAssertTrue(rail.exists)
                XCTAssertEqual(rail.frame.width, 84, accuracy: 1)
                if window.minX < 100 { XCTAssertEqual(rail.frame.minX, window.minX, accuracy: 1) }
                else { XCTAssertEqual(rail.frame.maxX, window.maxX, accuracy: 1) }
                XCTAssertFalse(app.otherElements["workspaceTabBar"].exists)
                let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch.label
                let newTab = app.descendants(matching: .any)["newWorkspaceTab"].firstMatch
                let openTabs = app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch
                FileHandle.standardOutput.write(Data("DUO_SPLIT_CHROME \(stage) rail=\(rail.frame) newTab=\(newTab.frame) openTabs=\(openTabs.frame) keyboards=\(app.keyboards.count) geometry=\(geometry)\n".utf8))
                XCTAssertTrue(newTab.exists); XCTAssertTrue(openTabs.exists)
                XCTAssertGreaterThanOrEqual(openTabs.frame.maxY, window.maxY - 39, "Bottom rail control must reach Home-safe bottom")
                XCTAssertLessThanOrEqual(openTabs.frame.maxY, window.maxY - 33)
                XCTAssertLessThanOrEqual(openTabs.frame.minY - newTab.frame.maxY, 8, "Rail controls must remain adjacent at the bottom")
                if geometry.contains("keyboardVisible=false") {
                    let regex = try! NSRegularExpression(pattern: "safe=\\([^,]+, ([0-9.]+)\\)")
                    if let match = regex.firstMatch(in: geometry, range: NSRange(geometry.startIndex..., in: geometry)), let range = Range(match.range(at: 1), in: geometry), let height = Double(geometry[range]) {
                        XCTAssertEqual(height, 635, accuracy: 1, "No stale keyboard inset: native 669pt window minus 34pt Home area")
                    } else { XCTFail("Missing actual safe geometry") }
                }
            }
            snapshot(app, "Real-System-Split-" + stage + "-" + action)
        }
        transition("OPEN", half: false, "Initial")
        let marker = "DuoRealSystemSplitUnsaved42"
        editor.press(); editor.typeText(marker); app.typeKey(.return, modifierFlags: [])
        waitValue(editor) { $0.contains(marker) }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeSaveCancel"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["closeSaveCancel"].firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.alerts.firstMatch)], timeout: 10), .completed, "Cancel must actually dismiss the save alert")
        let names = app.staticTexts["workspaceTabNames"].firstMatch.value as? String
        for action in ["LEFT", "FULL_LEFT"] {
            transition(action, half: action == "LEFT", "Unsaved")
            waitValue(editor) { $0.contains(marker) }
            XCTAssertEqual(app.staticTexts["workspaceTabNames"].firstMatch.value as? String, names)
            XCTAssertTrue((app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "").contains(":true:"))
        }
        editor.press()
        var undoCount = 0
        while (editor.value as? String ?? "").contains(marker), undoCount < 3 { app.typeKey("z", modifierFlags: .command); undoCount += 1 }
        waitValue(editor) { !$0.contains(marker) }
        for _ in 0..<undoCount { app.typeKey("z", modifierFlags: [.command, .shift]) }
        waitValue(editor) { $0.contains(marker) }
        app.buttons["modeToggle"].firstMatch.press()
        waitForWorkspaceDiskEvidence(app)
        let disk = app.staticTexts["workspaceDiskEvidence"].firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 10)); XCTAssertFalse((disk.value as? String ?? "").contains(marker))
        let page = app.staticTexts["pageNumber"].firstMatch
        waitValue(page) { $0 == "ready" }
        app.buttons["nextPage"].firstMatch.press(); waitValue(page) { $0 == "ready" }
        let position = app.staticTexts["workspaceSourceCursor"].firstMatch
        let cursor = position.value as? String
        XCTAssertGreaterThan(Int(cursor ?? "0") ?? 0, 0)
        for action in ["LEFT", "FULL_LEFT"] {
            transition(action, half: action == "LEFT", "Reading")
            XCTAssertEqual(position.value as? String, cursor, "Split reflow must preserve source cursor")
        }
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        func fields() -> [String] { (evidence.value as? String ?? "").components(separatedBy: "|") }
        let play = app.buttons["playPause"].firstMatch
        play.press(); waitValue(evidence) { let f = $0.components(separatedBy: "|"); return f.count > 9 && f[6] == "playing" && (Int(f[3]) ?? 0) > 4800 }
        let playing = fields(); let generation = playing[2]; var frames = Int(playing[3]) ?? 0
        for action in ["LEFT", "FULL_LEFT"] {
            transition(action, half: action == "LEFT", "Playing")
            let current = fields()
            XCTAssertEqual(current[2], generation); XCTAssertEqual(current[6], "playing")
            XCTAssertGreaterThan(Int(current[3]) ?? 0, frames)
            frames = Int(current[3]) ?? 0
        }
        play.press(); waitValue(evidence) { $0.components(separatedBy: "|").contains("paused") }
        let paused = fields(); let pausedCursor = position.value as? String
        func assertPaused() {
            let current = fields(); XCTAssertGreaterThan(current.count, 9)
            for i in [0, 2, 3, 4, 5, 6, 9] { XCTAssertEqual(current[i], paused[i], "Paused speech field \(i)") }
            XCTAssertEqual(position.value as? String, pausedCursor)
        }
        for action in ["LEFT", "FULL_LEFT", "RIGHT", "FULL_RIGHT", "LEFT"] {
            transition(action, half: action == "LEFT" || action == "RIGHT", "Paused")
            assertPaused()
        }
        for action in ["PARTIAL", "ROTATE", "ROTATE_BACK", "CLOSED", "REOPEN"] {
            if action == "CLOSED", app.buttons["selectedMode"].firstMatch.exists { app.buttons["selectedMode"].firstMatch.press() }
            step += 1; FileHandle.standardOutput.write(Data("DUO_SPLIT_STEP_\(step)_\(action)\n".utf8))
            let began = Date()
            let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch
            var stableSince: Date?, stableKey = ""
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard geometry.exists else { return false }
                let text = geometry.label, frame = app.windows.firstMatch.frame
                let screenPattern = "screen=\\([^,]+, [^,]+, ([0-9.]+), ([0-9.]+)\\)"
                let regex = try! NSRegularExpression(pattern: screenPattern)
                guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let wr = Range(match.range(at: 1), in: text), let hr = Range(match.range(at: 2), in: text), let width = Double(text[wr]), let height = Double(text[hr]) else { return false }
                let ready: Bool
                switch action {
                case "PARTIAL": ready = text.contains("status=2;")
                case "ROTATE": ready = width < height
                case "ROTATE_BACK": ready = width > height
                case "CLOSED": ready = abs(frame.width - 466) < 1 && abs(frame.height - 678) < 1
                default: ready = text.contains("status=3;") && width > height
                }
                let key = "\(frame.width.rounded())|\(frame.height.rounded())|\(text.contains("full=true"))|\(text.contains("tabletop=true"))|\(ready)"
                if ready && key == stableKey { if stableSince == nil { stableSince = Date() } }
                else { stableKey = key; stableSince = ready ? Date() : nil }
                return Date().timeIntervalSince(began) >= 4 && (stableSince.map { Date().timeIntervalSince($0) >= 1.5 } ?? false)
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 25), .completed, "Native pose and layout must both settle")
            assertPaused()
            let text = geometry.label
            let frame = app.windows.firstMatch.frame
            if text.contains("full=false") {
                XCTAssertFalse(app.descendants(matching: .any)["tabletopSpeechControls"].firstMatch.exists, "A settled system split must not become tabletop")
                XCTAssertFalse(text.contains("tabletop=true"), text)
            }
            FileHandle.standardOutput.write(Data("DUO_SPLIT_POSE \(action) frame=\(frame) geometry=\(text)\n".utf8))
            snapshot(app, "Real-System-Split-Paused-" + action)
        }
        app.buttons["stopSpeech"].firstMatch.press()
        FileHandle.standardOutput.write(Data("DUO_SPLIT_COMPLETE\n".utf8))
    }

    /// Run with Scripts/verify_duo_fold.py so each marker drives the native Device Hub hinge.
    func testDuoSplitMovingWindowRefreshesRightRailGeometry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        XCTAssertTrue(app.textViews["manuscriptEditor"].firstMatch.waitForExistence(timeout: 30))
        var step = 0
        for action in ["OPEN", "LEFT", "FULL_LEFT", "RIGHT", "FULL_RIGHT"] {
            step += 1
            FileHandle.standardOutput.write(Data("DUO_SPLIT_BEFORE_\(step)_\(action) \(app.windows.firstMatch.frame)\n".utf8))
            FileHandle.standardOutput.write(Data("DUO_SPLIT_STEP_\(step)_\(action)\n".utf8))
            let half = action == "LEFT" || action == "RIGHT", began = Date()
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return Date().timeIntervalSince(began) > (half ? 11 : 7) && abs(frame.width - (half ? 469 : 951)) < 0.1 && abs(frame.height - 669) < 0.1
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 35), .completed)
            FileHandle.standardOutput.write(Data("DUO_SPLIT_GEOMETRY Layout \(action) \(app.windows.firstMatch.frame)\n".utf8))
            let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch.label
            let rail = app.descendants(matching: .any)["workspaceVerticalTabBar"].firstMatch
            FileHandle.standardOutput.write(Data("DUO_SPLIT_LAYOUT \(action) window=\(app.windows.firstMatch.frame) rail=\(rail.exists ? String(describing: rail.frame) : "none") tabs=\(app.staticTexts["workspaceTabNames"].firstMatch.value as? String ?? "missing") geometry=\(geometry)\n".utf8))
            snapshot(app, "Duo-Split-Layout-" + action)
            Thread.sleep(forTimeInterval: 2)
            if half {
                let window = app.windows.firstMatch.frame
                XCTAssertTrue(rail.exists)
                XCTAssertEqual(rail.frame.width, 84, accuracy: 1)
                if window.minX < 100 { XCTAssertEqual(rail.frame.minX, window.minX, accuracy: 1) }
                else { XCTAssertEqual(rail.frame.maxX, window.maxX, accuracy: 1) }
            }
        }
        FileHandle.standardOutput.write(Data("DUO_SPLIT_COMPLETE\n".utf8))
    }

    func testDuoRealSplitKeyboardKeepsEditorVisibleAndDraftUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        var step = 0
        func wait(_ predicate: @escaping () -> Bool, _ message: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: app)], timeout: 35), .completed, message)
        }
        func transition(_ action: String, half: Bool) {
            step += 1
            FileHandle.standardOutput.write(Data("DUO_SPLIT_BEFORE_\(step)_\(action) \(app.windows.firstMatch.frame)\n".utf8))
            FileHandle.standardOutput.write(Data("DUO_SPLIT_STEP_\(step)_\(action)\n".utf8))
            let began = Date()
            wait({ Date().timeIntervalSince(began) > (half ? 11 : 7) && (half ? app.windows.firstMatch.frame.width < 500 : abs(app.windows.firstMatch.frame.width - 951) < 1) }, "Actual OS window must settle")
            FileHandle.standardOutput.write(Data("DUO_SPLIT_GEOMETRY Keyboard \(action) \(app.windows.firstMatch.frame)\n".utf8))
        }
        transition("OPEN", half: false)
        app.buttons["modeToggle"].firstMatch.press()
        wait({ !app.keyboards.firstMatch.exists }, "Reading must dismiss the real keyboard")
        transition("LEFT", half: true)
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        wait({ app.keyboards.firstMatch.exists }, "A real system keyboard must appear inside split")
        let marker = "DuoSplitKeyboardDraft42"
        editor.typeText(marker)
        app.typeKey(.return, modifierFlags: []) // Commit the native IME/typing group before Undo.
        wait({ (editor.value as? String ?? "").contains(marker) }, "Native editing must receive the marker")
        let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch
        wait({ geometry.label.contains("keyboardVisible=true") }, "Public keyboard notification must report the visible container")
        let text = geometry.label
        func numbers(_ prefix: String) -> [Double] {
            let pattern = prefix + "=\\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
            return (1...4).compactMap { Range(match.range(at: $0), in: text).flatMap { Double(text[$0]) } }
        }
        let view = numbers("view"), keyboard = numbers("keyboard")
        FileHandle.standardOutput.write(Data("DUO_SPLIT_KEYBOARD editor=\(editor.frame) keyboardAX=\(app.keyboards.firstMatch.frame) geometry=\(text)\n".utf8))
        snapshot(app, "Duo-Split-Real-Keyboard-Editor")
        XCTAssertEqual(view.count, 4); XCTAssertEqual(keyboard.count, 4)
        if view.count == 4 && keyboard.count == 4 {
            XCTAssertLessThanOrEqual(editor.frame.maxY, view[1] + keyboard[1] + 1, "Editor must remain above the whole keyboard container, including candidate row")
        }
        XCTAssertGreaterThan(editor.frame.height, 80)
        FileHandle.standardOutput.write(Data("DUO_SPLIT_UNDO before=\(app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "missing")\n".utf8))
        var undoCount = 0
        while (editor.value as? String ?? "").contains(marker), undoCount < 3 {
            app.typeKey("z", modifierFlags: .command); undoCount += 1
            FileHandle.standardOutput.write(Data("DUO_SPLIT_UNDO count=\(undoCount) marker=\((editor.value as? String ?? "").contains(marker)) evidence=\(app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "missing")\n".utf8))
        }
        wait({ !(editor.value as? String ?? "").contains(marker) }, "Actual native Undo must remove split edit")
        for _ in 0..<undoCount { app.typeKey("z", modifierFlags: [.command, .shift]) }
        wait({ (editor.value as? String ?? "").contains(marker) }, "Actual native Redo must restore split edit")
        app.buttons["modeToggle"].firstMatch.press()
        wait({ !app.keyboards.firstMatch.exists && geometry.label.contains("keyboardVisible=false") && geometry.label.contains(", 635.0);insets=") }, "Hidden keyboard must restore all 635 usable points")
        XCTAssertTrue((app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "").contains(":true:"))
        waitForWorkspaceDiskEvidence(app)
        XCTAssertFalse((app.staticTexts["workspaceDiskEvidence"].firstMatch.value as? String ?? "").contains(marker))
        FileHandle.standardOutput.write(Data("DUO_SPLIT_KEYBOARD_HIDDEN \(geometry.label)\n".utf8))
        snapshot(app, "Duo-Split-Keyboard-Hidden-Fills-Window")
        transition("FULL_LEFT", half: false)
        FileHandle.standardOutput.write(Data("DUO_SPLIT_COMPLETE\n".utf8))
    }

    func testDuoNativeFoldPreservesDraftUndoReaderAndSpeech() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        var step = 0
        func fold(_ pose: String, wide: Bool, _ label: String) {
            step += 1
            FileHandle.standardOutput.write(Data("DUO_FOLD_STEP_\(step)_\(pose)\n".utf8))
            let status = pose == "CLOSED" ? 1 : (pose == "OPEN" ? 3 : 2)
            let hinge = app.staticTexts["workspaceHingeGeometry"].firstMatch
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return hinge.exists && hinge.label.contains("status=\(status);") &&
                    (wide ? max(frame.width, frame.height) > 800 : max(frame.width, frame.height) < 800)
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 25), .completed, "Native hinge must reach \(pose)")
            // 收起时主显示器可能自动翻转；公开旋转到竖屏后再读取触点，避免沿用内屏坐标。
            if pose == "CLOSED", app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height {
                XCUIDevice.shared.orientation = .portrait
                print("DUO_FOLD_COVER_PORTRAIT step=\(step)")
            }
            var signature = "", stableSince = Date()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                let value = "\(frame)|\(XCUIDevice.shared.orientation.rawValue)"
                if value != signature { signature = value; stableSince = Date(); return false }
                return hinge.label.contains("status=\(status);") && Date().timeIntervalSince(stableSince) >= 1
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed, "Hinge window and orientation must settle before input")
            let currentPlay = app.buttons["playPause"].firstMatch
            print("DUO_FOLD_SETTLED step=\(step) pose=\(pose) window=\(app.windows.firstMatch.frame) orientation=\(XCUIDevice.shared.orientation.rawValue) play=\(currentPlay.exists ? String(describing: currentPlay.frame) : "none") hinge=\(hinge.label)")
            snapshot(app, "Duo-\(label)-\(pose)")
        }
        func waitValue(_ element: XCUIElement, _ condition: @escaping (String) -> Bool) {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(element.value as? String ?? "") }, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed)
        }
        fold("CLOSED", wide: false, "Initial")
        let marker = "DuoDraftContinuity42"
        func diagnostics(_ stage: String) {
            let undo = app.staticTexts["workspaceUndoEvidence"].firstMatch.value as? String ?? "missing"
            let text = editor.value as? String ?? ""
            let capabilityElement = app.staticTexts["workspaceDeviceCapabilities"].firstMatch
            let capabilityValue = capabilityElement.value as? String ?? ""
            let capabilities = capabilityValue.isEmpty ? capabilityElement.label : capabilityValue
            FileHandle.standardOutput.write(Data("DUO_DIAGNOSTIC \(stage) undo=\(undo) chars=\(text.utf16.count) marker=\(text.contains(marker)) focus=\(editor.debugDescription.contains("Keyboard Focused")) capabilities=\(capabilities) native=\(editor.label)\n".utf8))
        }
        diagnostics("before-type")
        editor.press(); editor.typeText(marker); app.typeKey(.return, modifierFlags: [])
        waitValue(editor) { $0.contains(marker) }; diagnostics("after-type")
        // A real model-backed edit must be protected by Save/Discard/Cancel.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeSaveCancel"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["closeSaveCancel"].firstMatch.press(); diagnostics("after-close-cancel")
        let names = app.staticTexts["workspaceTabNames"].firstMatch.value as? String
        for (pose, wide) in [("OPEN", true), ("PARTIAL", true), ("CLOSED", false)] {
            fold(pose, wide: wide, "Unsaved")
            waitValue(editor) { $0.contains(marker) }; diagnostics("after-fold-" + pose)
            XCTAssertEqual(app.staticTexts["workspaceTabNames"].firstMatch.value as? String, names)
        }
        editor.press(); diagnostics("before-undo")
        // A committed line break may form a separate native typing undo group.
        var undoCount = 0
        while (editor.value as? String ?? "").contains(marker), undoCount < 3 {
            app.typeKey("z", modifierFlags: .command); undoCount += 1
            diagnostics("after-undo-" + String(undoCount))
        }
        waitValue(editor) { !$0.contains(marker) }
        for _ in 0..<undoCount { app.typeKey("z", modifierFlags: [.command, .shift]) }
        waitValue(editor) { $0.contains(marker) }
        app.buttons["modeToggle"].firstMatch.press()
        waitForWorkspaceDiskEvidence(app)
        let disk = app.staticTexts["workspaceDiskEvidence"].firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 10)); XCTAssertFalse((disk.value as? String ?? "").contains(marker))
        let ready = app.staticTexts["pageNumber"].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        waitValue(ready) { $0 == "ready" }
        app.buttons["nextPage"].firstMatch.press(); waitValue(ready) { $0 == "ready" }
        let position = app.staticTexts["workspaceSourceCursor"].firstMatch
        let cursor = position.value as? String
        XCTAssertGreaterThan(Int(cursor ?? "0") ?? 0, 0)
        for (pose, wide) in [("OPEN", true), ("PARTIAL", true), ("CLOSED", false)] {
            fold(pose, wide: wide, "Reading")
            XCTAssertEqual(position.value as? String, cursor, "Reflow must preserve source position")
        }
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        func fields() -> [String] { (evidence.value as? String ?? "").components(separatedBy: "|") }
        let play = app.buttons["playPause"].firstMatch
        play.press(); waitValue(evidence) { $0.components(separatedBy: "|").contains("playing") }
        let before = fields(); XCTAssertGreaterThan(before.count, 7)
        let generation = before[2]
        var frames = Int(before[3]) ?? 0
        for (pose, wide) in [("OPEN", true), ("PARTIAL", true), ("CLOSED", false)] {
            fold(pose, wide: wide, "Playing")
            FileHandle.standardOutput.write(Data("DUO_FOLD_PLAY_WAIT \(pose) baselineFrames=\(frames) evidence=\(evidence.value as? String ?? "missing") cursor=\(position.value as? String ?? "missing") engine=\(play.value as? String ?? "missing")\n".utf8))
            let progress = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let current = fields()
                return current.count > 6 && current[2] == generation && current[6] == "playing" && (Int(current[3]) ?? 0) > frames
            }, object: evidence)
            let progressResult = XCTWaiter.wait(for: [progress], timeout: 15)
            FileHandle.standardOutput.write(Data("DUO_FOLD_PLAY_RESULT \(pose) wait=\(progressResult.rawValue) evidence=\(evidence.value as? String ?? "missing") cursor=\(position.value as? String ?? "missing") engine=\(play.value as? String ?? "missing")\n".utf8))
            XCTAssertEqual(progressResult, .completed, "Playback must make real PCM progress after native hinge movement")
            let after = fields()
            XCTAssertEqual(after[2], generation); XCTAssertEqual(after[6], "playing")
            XCTAssertGreaterThan(Int(after[3]) ?? 0, frames, "Playback must continue through hinge movement")
            frames = Int(after[3]) ?? 0
        }
        play.press(); waitValue(evidence) { $0.components(separatedBy: "|").contains("paused") }
        let paused = fields()
        let pausedCursor = position.value as? String
        for (pose, wide) in [("OPEN", true), ("PARTIAL", true), ("CLOSED", false)] {
            fold(pose, wide: wide, "Paused")
            let after = fields()
            for index in [0, 2, 3, 4, 5, 6, 9] { XCTAssertEqual(after[index], paused[index], "Paused field \(index) must survive folding") }
            XCTAssertEqual(position.value as? String, pausedCursor)
        }
        app.buttons["stopSpeech"].firstMatch.press()
    }

    func testDuoNativeTabletopReadingEditingAndSpeechControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        XCTAssertTrue(app.textViews["manuscriptEditor"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["modeToggle"].firstMatch.press()
        FileHandle.standardOutput.write(Data("DUO_FOLD_STEP_1_TABLETOP\n".utf8))
        let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch
        func wait(_ condition: @escaping () -> Bool, _ message: String = "") {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, message)
        }
        func geometryText() -> String { geometry.label }
        wait({ geometry.exists && geometryText().contains("tabletop=true") && geometryText().contains("full=true") }, "Requires a real full-screen horizontal hinge division")
        FileHandle.standardOutput.write(Data("DUO_TABLETOP_GEOMETRY \(geometryText())\n".utf8))
        func numbers(_ pattern: String) -> [Double] {
            let text = geometryText()
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).flatMap { Double(text[$0]) }
            }
        }
        let numeral = "([-0-9.]+)"
        let origin = numbers("view=\\(" + numeral + ", " + numeral)
        let division = numbers("Division\\(frame: \\(" + numeral + ", " + numeral + ", " + numeral + ", " + numeral + "\\), active: true")
        XCTAssertEqual(origin.count, 2); XCTAssertEqual(division.count, 4)
        let hingeTop = origin[1] + division[1], hingeBottom = hingeTop + division[3]
        let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
        let transcript = app.descendants(matching: .any)["tabletopSpeechTranscript"].firstMatch
        let controls = app.descendants(matching: .any)["tabletopSpeechControls"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 15))
        XCTAssertFalse(transcript.exists); XCTAssertFalse(controls.exists)
        XCTAssertGreaterThan(paper.frame.maxY, hingeBottom + 150, "Pure reading should use the lower surface too")
        snapshot(app, "Duo-Tabletop-Pure-Reading-Fills-Window")
        app.buttons["modeToggle"].firstMatch.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        let keyboard = app.keyboards.firstMatch
        wait({ editor.exists && keyboard.exists }, "Tabletop editing should activate the system keyboard")
        XCTAssertLessThanOrEqual(editor.frame.maxY, hingeTop + 2)
        XCTAssertGreaterThan(keyboard.frame.height, app.windows.firstMatch.frame.height * 0.25)
        snapshot(app, "Duo-Tabletop-Editor-And-System-Keyboard")
        app.buttons["modeToggle"].firstMatch.press()
        wait({ paper.exists && !keyboard.exists })
        let play = app.buttons["playPause"].firstMatch
        play.press()
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        func fields() -> [String] {
            let stored = (evidence.value as? String ?? "").components(separatedBy: "|")
            let live = app.buttons["playPause"].firstMatch.value as? String ?? ""
            return live.hasPrefix("Speech|") ? [stored.first ?? "none"] + live.components(separatedBy: "|") : stored
        }
        wait({ fields().count > 15 && fields()[6] == "playing" && controls.exists && transcript.exists })
        XCTAssertLessThanOrEqual(transcript.frame.maxY, hingeTop + 2)
        XCTAssertGreaterThanOrEqual(controls.frame.minY, hingeBottom - 2)
        XCTAssertGreaterThanOrEqual(play.frame.width, 72); XCTAssertGreaterThanOrEqual(play.frame.height, 72)
        snapshot(app, "Duo-Tabletop-Transcript-And-Transport")
        play.press(); wait({ fields()[6] == "paused" })
        let paused = fields()
        let generation = paused[2]
        let speed = app.buttons["speechSpeed"].firstMatch
        XCTAssertTrue(speed.exists); XCTAssertGreaterThanOrEqual(speed.frame.minY, hingeBottom - 2)
        XCTAssertGreaterThanOrEqual(speed.frame.width, 76); XCTAssertGreaterThanOrEqual(speed.frame.height, 64)
        for id in ["tabletopSeekForward", "tabletopSeekBackward"] {
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.width, 80)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 80)
        }
        FileHandle.standardOutput.write(Data("LARGE_TABLETOP_CONTROLS speed=\(speed.frame) play=\(play.frame) forward=\(app.buttons["tabletopSeekForward"].frame) backward=\(app.buttons["tabletopSeekBackward"].frame) controls=\(controls.frame)\n".utf8))
        let stop = app.buttons["stopSpeech"].firstMatch
        XCTAssertGreaterThan(stop.frame.midX, controls.frame.midX)
        XCTAssertLessThan(speed.frame.midX, controls.frame.midX)
        speed.press()
        let preset = app.buttons["speechSpeedPreset-1.25"].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 10)); preset.press()
        app.buttons["closeSpeechSpeed"].firstMatch.press()
        wait({ fields()[14] == "1.25" })
        snapshot(app, "Duo-Tabletop-Large-Controls-1.25x")
        let changed = fields()
        for index in [0, 2, 3, 4, 5, 6, 9] { XCTAssertEqual(changed[index], paused[index], "Speed must preserve paused position and session") }
        play.press(); wait({ fields()[6] == "playing" })
        XCTAssertEqual(fields()[2], generation)
        let forward = app.buttons["tabletopSeekForward"].firstMatch
        let backward = app.buttons["tabletopSeekBackward"].firstMatch
        let initialSegment = Int(fields()[4]) ?? 0
        forward.press(forDuration: 1.8)
        wait({ (Int(fields()[4]) ?? 0) >= initialSegment + 3 }, "Holding forward must repeatedly seek")
        let forwardEvidence = fields()
        let updates = Int(forwardEvidence.first(where: { $0.hasPrefix("scrubUpdates=") })?.components(separatedBy: ";").first?.replacingOccurrences(of: "scrubUpdates=", with: "") ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(updates, 4); XCTAssertTrue(forwardEvidence.joined(separator: "|").contains("scrubIdle=true"), "Holding seek must not synthesize or restart playback")
        play.press(); wait({ fields()[6] == "paused" })
        let advanced = Int(fields()[4]) ?? 0
        backward.press(forDuration: 1.8)
        wait({ (Int(fields()[4]) ?? 0) <= advanced - 2 && fields()[6] == "paused" }, "Holding backward must preserve the original pause")
        XCTAssertTrue(fields().joined(separator: "|").contains("scrubIdle=true"))
        FileHandle.standardOutput.write(Data("DUO_SYSTEM_AUDIO_GRAPH \(fields().joined(separator: "|"))\n".utf8))
        stop.press()
        wait({ !controls.exists && !transcript.exists && paper.exists })
        XCTAssertGreaterThan(paper.frame.maxY, hingeBottom + 150)
        snapshot(app, "Duo-Tabletop-Stop-Restores-Full-Reader")
    }

    func testDuoTabletopZipVoiceHoldKeepsSynthesisIdleUntilRelease() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--zipvoice-tab-audio-ui-testing"]
        launch(app)
        XCTAssertTrue(app.textViews["manuscriptEditor"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["modeToggle"].firstMatch.press()
        FileHandle.standardOutput.write(Data("DUO_FOLD_STEP_1_TABLETOP\n".utf8))
        let geometry = app.staticTexts["workspaceHingeGeometry"].firstMatch
        let tabletop = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in geometry.exists && geometry.label.contains("tabletop=true") }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [tabletop], timeout: 20), .completed)
        app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
        app.buttons["字号与朗读设置"].firstMatch.press()
        let form = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        let picker = app.descendants(matching: .any)["speechRendererPicker"].firstMatch
        for _ in 0..<8 { if picker.exists && picker.isHittable { break }; form.swipeUp() }
        XCTAssertTrue(picker.exists && picker.isHittable); picker.pressAtCenter()
        let zipvoice = app.buttons["speechModel-zipvoice"].firstMatch
        XCTAssertTrue(zipvoice.waitForExistence(timeout: 10)); zipvoice.press()
        XCTAssertTrue(zipvoice.isSelected)
        app.buttons["完成"].firstMatch.press()
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        func fields() -> [String] {
            let stored = (evidence.value as? String ?? "").components(separatedBy: "|")
            let live = app.buttons["playPause"].firstMatch.value as? String ?? ""
            return live.hasPrefix("Speech|") ? [stored.first ?? "none"] + live.components(separatedBy: "|") : stored
        }
        func wait(_ predicate: @escaping ([String]) -> Bool, _ message: String) {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let value = fields(); return value.count > 21 && predicate(value)
            }, object: evidence)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, message + " " + (evidence.value as? String ?? ""))
        }
        let play = app.buttons["playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10)); play.press()
        wait({ $0[6] == "playing" && $0[16] == "zipvoice" && $0[17] == "false" && (Int($0[3]) ?? 0) > 4800 }, "Must synthesize real packaged ZipVoice PCM without a system fallback")
        let forward = app.buttons["tabletopSeekForward"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.press(forDuration: 1.8)
        wait({ value in
            let updates = Int(value.first(where: { $0.hasPrefix("scrubUpdates=") })?.components(separatedBy: ";").first?.replacingOccurrences(of: "scrubUpdates=", with: "") ?? "0") ?? 0
            return updates >= 4 && value.joined(separator: "|").contains("scrubIdle=true") && value[6] == "playing" && value[16] == "zipvoice" && value[17] == "false" && (Int(value[3]) ?? 0) > 0
        }, "ZipVoice hold must keep renderer idle and resume the chosen renderer on release")
        FileHandle.standardOutput.write(Data("DUO_ZIPVOICE_AFTER_HOLD \(fields().joined(separator: "|"))\n".utf8))
        play.press()
        wait({ $0[6] == "paused" }, "Pause before the second long hold")
        app.buttons["tabletopSeekBackward"].firstMatch.press(forDuration: 1.8)
        wait({ $0[6] == "paused" && $0.joined(separator: "|").contains("scrubIdle=true") && $0[16] == "zipvoice" && $0[17] == "false" }, "Paused ZipVoice must remain paused after a long hold")
        FileHandle.standardOutput.write(Data("DUO_ZIPVOICE_PAUSED_AUDIO_GRAPH \(fields().joined(separator: "|"))\n".utf8))
        XCTAssertEqual(app.state, .runningForeground)
        snapshot(app, "Duo-ZipVoice-Real-Synthesis-And-Cancelled-Hold")
        app.buttons["stopSpeech"].firstMatch.press()
    }

    func testDuoSpeechModelAndSystemVoiceSelectionsAreTappable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--retired-renderer-ui-testing"]
        launch(app)
        XCTAssertTrue(app.textViews["manuscriptEditor"].firstMatch.waitForExistence(timeout: 30))
        app.buttons["modeToggle"].firstMatch.press()
        let position = app.staticTexts["readingPosition"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let cursor = position.value as? String
        chooseColumnTestMenu("字号与朗读设置", in: app)
        let form = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 10))
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 {
                if element.exists && element.isHittable { break }
                form.swipeUp()
            }
            if !element.exists || !element.isHittable { snapshot(app, "Duo-Voice-Choice-Failure"); FileHandle.standardOutput.write(Data((app.debugDescription + "\n").utf8)) }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        let picker = app.descendants(matching: .any)["speechRendererPicker"].firstMatch
        reveal(picker); picker.pressAtCenter()
        let selectedVoice = app.staticTexts["selectedVoice"].firstMatch
        var models: [String] = []
        XCTAssertFalse(app.buttons["speechModel-matcha"].exists)
        XCTAssertTrue(app.buttons["speechModel-system"].firstMatch.isSelected, "Retired Matcha preference must migrate to System")
        if app.buttons["speechModel-zipvoice"].firstMatch.exists { models.append("zipvoice") }
        models.append("system")
        for id in models {
            let choice = app.buttons["speechModel-" + id].firstMatch
            reveal(choice); XCTAssertGreaterThanOrEqual(choice.frame.height, 44); choice.press()
            // 原生设置选中模型后会收起列表；重新展开读取真实勾选状态。
            picker.pressAtCenter()
            reveal(choice)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in choice.isSelected }, object: choice)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 8), .completed, "Model selection must change to " + id)
            FileHandle.standardOutput.write(Data("DUO_VOICE_MODEL \(id) selected=\(choice.isSelected) description=\(selectedVoice.exists ? selectedVoice.label : picker.label)\n".utf8))
        }
        picker.pressAtCenter() // Collapse model choices so actual system voices enter the viewport.
        let systemPicker = app.descendants(matching: .any)["systemMandarinVoicePicker"].firstMatch
        reveal(systemPicker); systemPicker.pressAtCenter()
        let voices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'systemVoice-'"))
        XCTAssertTrue(voices.firstMatch.waitForExistence(timeout: 10))
        let voice = voices.allElementsBoundByIndex.first(where: { !$0.isSelected }) ?? voices.firstMatch
        let selectedSystemVoiceID = voice.identifier.replacingOccurrences(of: "systemVoice-", with: "")
        FileHandle.standardOutput.write(Data("DUO_SYSTEM_VOICE_AVAILABLE count=\(voices.count) selectedID=\(selectedSystemVoiceID)\n".utf8))
        reveal(voice); XCTAssertGreaterThanOrEqual(voice.frame.height, 44); voice.press()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in voice.isSelected }, object: voice)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 8), .completed)
        FileHandle.standardOutput.write(Data("DUO_SYSTEM_VOICE \(voice.identifier) selected=\(voice.isSelected) description=\(selectedVoice.exists ? selectedVoice.label : picker.label)\n".utf8))
        snapshot(app, "Duo-Real-Speech-Model-And-Voice-Choices")
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(position.waitForExistence(timeout: 10)); XCTAssertEqual(position.value as? String, cursor)
        app.buttons["playPause"].firstMatch.press()
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let raw = evidence.value as? String ?? ""
            let fields = raw.components(separatedBy: "|")
            return fields.count > 17 && fields[6] == "playing" && fields[16] == "system" && fields[17] == "false" && (Int(fields[3]) ?? 0) > 4800 && raw.contains("synthesisVoice=\(selectedSystemVoiceID);") && raw.contains("scheduledVoice=\(selectedSystemVoiceID);")
        }, object: evidence)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 20), .completed)
        FileHandle.standardOutput.write(Data("DUO_SELECTED_SYSTEM_PCM \(evidence.value as? String ?? "missing")\n".utf8))
        snapshot(app, "Duo-Selected-System-Voice-Actual-PCM")
        app.buttons["stopSpeech"].firstMatch.press()
    }

    func testOrdinaryPhoneSingleDocumentReplacementPreservesAutomaticSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        XCTAssertFalse(app.descendants(matching: .any)["workspaceTabBar"].firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.exists)
        let marker = "PhoneAutomaticReplacement42"
        editor.press(); editor.typeText(marker); app.typeKey(.return, modifierFlags: [])
        app.buttons["modeToggle"].firstMatch.press()
        app.buttons["toggleChapterSidebar"].firstMatch.press()
        let alpha = app.buttons["book-标签甲"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10)); alpha.press()
        let names = app.staticTexts["workspaceTabNames"].firstMatch
        let alphaActive = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in names.exists && names.value as? String == "标签甲.txt" }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [alphaActive], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["closeSaveNo"].firstMatch.exists)
        if app.textViews["manuscriptEditor"].firstMatch.exists { app.buttons["modeToggle"].firstMatch.press() }
        waitForWorkspaceDiskEvidence(app)
        let disk = app.staticTexts["workspaceDiskEvidence"].firstMatch
        XCTAssertTrue(disk.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in
            (disk.value as? String ?? "").contains("标签乙.txt=") && (disk.value as? String ?? "").contains(marker)
        }, evaluatedWith: disk); waitForExpectations(timeout: 10)
        app.buttons["toggleChapterSidebar"].firstMatch.press()
        let beta = app.buttons["book-标签乙"].firstMatch
        XCTAssertTrue(beta.waitForExistence(timeout: 10)); beta.press()
        if app.buttons["selectedMode"].firstMatch.label == "阅读" { app.buttons["modeToggle"].firstMatch.press() }
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertTrue((editor.value as? String ?? "").contains(marker))
        XCTAssertEqual(names.value as? String, "标签乙.txt")
        XCTAssertFalse(app.descendants(matching: .any)["workspaceTabBar"].firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.exists)
        snapshot(app, "Phone-Single-Document-Automatic-Save")
    }
    #endif

    func testTabDragToBlankReordersAndMovesBetweenViews() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("Two visible panes need at least 700 points") }
        #endif
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let beta = tab("标签乙.txt"), alpha = tab("标签甲.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 25)); beta.press()
        let blank = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'emptyTabArea-' ")).firstMatch
        XCTAssertTrue(blank.waitForExistence(timeout: 10))
        #if os(macOS)
        alpha.click(forDuration: 0.8, thenDragTo: blank)
        #else
        alpha.press(forDuration: 0.8, thenDragTo: blank)
        #endif
        let names = app.staticTexts["workspaceTabNames"].firstMatch
        expectation(for: NSPredicate(format: "value == %@", "标签乙.txt|标签甲.txt"), evaluatedWith: names); waitForExpectations(timeout: 15)
        beta.press()
        #if os(macOS)
        app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Window", "窗口", "視窗"])).firstMatch.press(); app.menuItems["克隆到另一视图"].firstMatch.press()
        #else
        app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter(); app.buttons["克隆到另一视图"].firstMatch.press()
        #endif
        let blanks = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'emptyTabArea-' "))
        expectation(for: NSPredicate { _, _ in blanks.count == 2 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        let target = blanks.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }!
        #if os(macOS)
        alpha.click(forDuration: 0.8, thenDragTo: target)
        #else
        alpha.press(forDuration: 0.8, thenDragTo: target)
        #endif
        expectation(for: NSPredicate { _, _ in
            let values = app.staticTexts.matching(identifier: "workspaceTabNames").allElementsBoundByIndex.map { $0.value as? String ?? "" }
            return values.contains("标签乙.txt") && values.contains("标签乙.txt|标签甲.txt")
        }, evaluatedWith: app); waitForExpectations(timeout: 15)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签甲.txt")).count, 1)
        snapshot(app, "Tabs-Drag-Between-Views")
    }

    func testTabStripDoubleClickAndReopenPreserveSavedContent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires multi-document controls") }
        #endif
        func names() -> [String] { (app.staticTexts["workspaceTabNames"].firstMatch.value as? String ?? "").components(separatedBy: "|") }
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let beta = tab("标签乙.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 25)); beta.press()
        let betaID = beta.identifier.replacingOccurrences(of: "documentTab-", with: "")
        let initial = names().count
        #if os(macOS)
        beta.doubleClick()
        #else
        beta.doubleTap()
        #endif
        XCTAssertEqual(names().count, initial, "Double-clicking an existing tab must not create a document")
        let blank = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'emptyTabArea-' ")).firstMatch
        XCTAssertTrue(blank.waitForExistence(timeout: 10))
        #if os(macOS)
        blank.doubleClick()
        #else
        blank.doubleTap()
        #endif
        expectation(for: NSPredicate { _, _ in names().count == initial + 1 }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let created = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label BEGINSWITH '未命名'")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 10))
        let createdID = created.identifier.replacingOccurrences(of: "documentTab-", with: "")
        app.buttons["closeTab-" + createdID].firstMatch.press()
        XCTAssertTrue(created.waitForNonExistence(timeout: 10))
        beta.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("DiscardedTabText")
        app.buttons["closeTab-" + betaID].firstMatch.press()
        XCTAssertTrue(app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveNo"].firstMatch.press()
        XCTAssertTrue(beta.waitForNonExistence(timeout: 10))
        app.terminate(); app.launchArguments = ["--ui-testing", "--tabs-ui-testing"]; launch(app)
        #if os(macOS)
        app.typeKey("t", modifierFlags: [.command, .shift])
        #else
        app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter()
        app.buttons["重新打开关闭的标签"].firstMatch.press()
        #endif
        XCTAssertTrue(beta.waitForExistence(timeout: 20))
        XCTAssertEqual(beta.identifier, "documentTab-" + betaID)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Beta original", "Reopening must not resurrect discarded changes")
        XCTAssertEqual(names().count, initial)
        snapshot(app, "Tabs-Double-Click-And-Reopen")
    }

    func testTabManagerFiltersSavesAndClosesOnlySelectedFiles() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires multi-document controls") }
        #endif
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let alpha = tab("标签甲.txt"), beta = tab("标签乙.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 25))
        let alphaID: String
        #if os(iOS)
        if !alpha.exists { app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter(); app.buttons["标签甲.txt"].firstMatch.press() }
        else { alpha.press() }
        #else
        alpha.press()
        #endif
        alphaID = alpha.identifier.replacingOccurrences(of: "documentTab-", with: "")
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("ManagerSavedText")
        #if os(iOS)
        if !beta.exists { app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter(); app.buttons["标签乙.txt"].firstMatch.press() }
        else { beta.press() }
        #else
        beta.press()
        #endif
        editor.press(); editor.typeText("OtherUnsavedText")
        let betaID = beta.identifier.replacingOccurrences(of: "documentTab-", with: "")
        func manager() {
            #if os(macOS)
            app.typeKey("o", modifierFlags: [.command, .shift])
            #else
            app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch.pressAtCenter()
            let candidates = app.buttons.matching(NSPredicate(format: "label == '管理标签…'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                candidates.allElementsBoundByIndex.contains { $0.isHittable && $0.frame.width > 0 && $0.frame.height > 0 }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            guard let manage = candidates.allElementsBoundByIndex.first(where: { $0.isHittable && $0.frame.width > 0 && $0.frame.height > 0 }) else { XCTFail(app.debugDescription); return }
            manage.pressAtCenter()
            #endif
            XCTAssertTrue(app.textFields["tabManagerSearch"].firstMatch.waitForExistence(timeout: 10))
        }
        manager()
        app.buttons["sortWorkspaceTabs"].firstMatch.press()
        let search = app.textFields["tabManagerSearch"].firstMatch
        search.press(); search.typeText("标签甲")
        XCTAssertTrue(app.buttons["activateManagedTab-" + alphaID].firstMatch.exists)
        XCTAssertFalse(app.buttons["activateManagedTab-" + betaID].firstMatch.exists)
        app.buttons["selectAllWorkspaceTabs"].firstMatch.press()
        app.buttons["saveSelectedWorkspaceTabs"].firstMatch.pressAtCenter()
        XCTAssertTrue(search.waitForNonExistence(timeout: 10))
        waitForWorkspaceDiskEvidence(app)
        let evidence = app.staticTexts["workspaceDiskEvidence"].firstMatch
        expectation(for: NSPredicate { _, _ in
            let value = evidence.value as? String ?? ""
            return value.contains("ManagerSavedText") && !value.contains("OtherUnsavedText")
        }, evaluatedWith: evidence); waitForExpectations(timeout: 10)
        manager()
        app.textFields["tabManagerSearch"].firstMatch.press(); app.textFields["tabManagerSearch"].firstMatch.typeText("标签甲")
        app.buttons["selectAllWorkspaceTabs"].firstMatch.press()
        let closeSelected = app.buttons["closeSelectedWorkspaceTabs"].firstMatch
        XCTAssertTrue(closeSelected.isEnabled && closeSelected.isHittable)
        print("TAB_MANAGER_BEFORE_CLOSE close=\(closeSelected.frame) window=\(app.windows.firstMatch.frame)")
        snapshot(app, "Tab-Manager-Before-Close-Selected")
        #if os(iOS)
        let closeFrame = closeSelected.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: closeFrame.midX, dy: closeFrame.midY)).tap()
        #else
        closeSelected.pressAtCenter()
        #endif
        expectation(for: NSPredicate { _, _ in
            let names = app.staticTexts["workspaceTabNames"].firstMatch.value as? String ?? ""
            return !names.contains("标签甲.txt") && names.contains("标签乙.txt")
        }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertTrue((editor.value as? String ?? "").contains("OtherUnsavedText"))
        snapshot(app, "Tabs-Manager-Selected-Only")
    }

    func testWorkspaceLayoutAndReadingTabReuse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--novel-ui-testing"]
        launch(app)
        let navigation = app.buttons["toggleChapterSidebar"].firstMatch
        XCTAssertTrue(navigation.waitForExistence(timeout: 30))
        func selectChapter(_ title: String) {
            let button = app.buttons["book-" + title].firstMatch
            if !button.exists || !button.isHittable { navigation.press() }
            XCTAssertTrue(button.waitForExistence(timeout: 15)); button.press()
        }
        func tab(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch
        }
        func count() -> Int { (app.staticTexts["workspaceTabNames"].firstMatch.value as? String ?? "").components(separatedBy: "|").count }
        func containsTab(_ name: String) -> Bool {
            (app.staticTexts["workspaceTabNames"].firstMatch.value as? String ?? "").components(separatedBy: "|").contains(name)
        }
        selectChapter("第1章")
        guard tab("第1章.md").waitForExistence(timeout: 5) else { throw XCTSkip("Requires multi-document controls") }
        if app.textViews["manuscriptEditor"].firstMatch.exists { app.buttons["modeToggle"].firstMatch.press() }
        let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
        XCTAssertTrue(paper.waitForExistence(timeout: 20))
        let initialCount = count()
        let toolbar = app.descendants(matching: .any)["workspaceToolbar"].firstMatch
        if app.descendants(matching: .any)["workspaceTabBar"].firstMatch.exists {
            XCTAssertLessThanOrEqual(toolbar.frame.maxY, tab("第1章.md").frame.minY + 1)
            XCTAssertLessThanOrEqual(tab("第1章.md").frame.maxY, paper.frame.minY + 1)
        }
        app.buttons["nextPage"].firstMatch.press()
        XCTAssertTrue(tab("第2章.md").waitForExistence(timeout: 20))
        XCTAssertFalse(containsTab("第1章.md"))
        XCTAssertEqual(count(), initialCount, "Reading chapter selection must reuse the original tab")
        XCTAssertEqual(app.staticTexts["recentlyClosedTabCount"].firstMatch.value as? String, "0", "Automatic chapter changes must not populate recently closed tabs")
        snapshot(app, "Layout-Reading-Reuses-Tab")
        app.buttons["modeToggle"].firstMatch.press()
        selectChapter("第10章")
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue(containsTab("第2章.md"))
        XCTAssertEqual(count(), initialCount + 1, "Editing chapter selection keeps the earlier tab")
        editor.press(); editor.typeText("LayoutUnsavedText")
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(paper.waitForExistence(timeout: 20))
        selectChapter("第1章")
        XCTAssertTrue(tab("第1章.md").waitForExistence(timeout: 20))
        XCTAssertTrue(containsTab("第10章.md"), "A reading jump must preserve the unsaved editor tab")
        if tab("第10章.md").exists { tab("第10章.md").press() }
        else {
            let menu = app.descendants(matching: .any)["openWorkspaceTabs"].firstMatch
            if !menu.exists { print("LAYOUT HIERARCHY: " + app.debugDescription) }
            menu.press(); app.buttons["第10章.md"].firstMatch.press()
        }
        app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String ?? "").contains("LayoutUnsavedText"))
        snapshot(app, "Layout-Editing-Preserves-Unsaved-Tab")
        #if os(macOS)
        app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["File", "文件", "檔案"])).firstMatch.press()
        XCTAssertTrue(app.menuItems["添加小说目录…"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBarItems["显示"].firstMatch.press()
        XCTAssertTrue(app.menuItems["专注模式"].firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
        #endif
    }

    func testWorkspaceAppearanceAndFocusKeepReadingPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let beta = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch
        XCTAssertTrue(beta.waitForExistence(timeout: 20)); beta.press()
        let mode = app.buttons["modeToggle"].firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 20))
        if mode.label == "阅读" { mode.press() }
        XCTAssertTrue(app.descendants(matching: .any)["readerPaper"].firstMatch.waitForExistence(timeout: 20))
        let position = app.staticTexts["readingPosition"].firstMatch.value as? String
        #if os(macOS)
        app.buttons["appearanceMenu"].firstMatch.press()
        #else
        if app.buttons["appearanceMenu"].firstMatch.exists { app.buttons["appearanceMenu"].firstMatch.press() }
        else { app.buttons["documentMenu"].firstMatch.pressAtCenter(); app.buttons["正文显示"].firstMatch.press() }
        #endif
        let slider = app.sliders["workspaceFontSize"].firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10)); slider.adjust(toNormalizedSliderPosition: 0.6)
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        #if os(macOS)
        app.buttons["focusMode"].firstMatch.press()
        #else
        if app.buttons["focusMode"].firstMatch.exists { app.buttons["focusMode"].firstMatch.press() }
        else { app.buttons["documentMenu"].firstMatch.pressAtCenter(); app.buttons["专注模式"].firstMatch.press() }
        #endif
        let tabs = app.descendants(matching: .any)["workspaceTabBar"].firstMatch
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 10))
        #if os(macOS)
        app.buttons["focusMode"].firstMatch.press()
        #else
        if app.buttons["focusMode"].firstMatch.exists { app.buttons["focusMode"].firstMatch.press() }
        else { app.buttons["documentMenu"].firstMatch.pressAtCenter(); app.buttons["退出专注"].firstMatch.press() }
        #endif
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        snapshot(app, "Layout-Appearance-And-Focus")
    }

    func testTabAudioKeepsPlayingOnSwitchAndAnotherDocumentTakesOver() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--tab-audio-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires visible multi-document controls") }
        #endif
        let alpha = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签甲.txt")).firstMatch
        let beta = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 20)); XCTAssertTrue(beta.exists)
        let a = alpha.identifier.replacingOccurrences(of: "documentTab-", with: "")
        let b = beta.identifier.replacingOccurrences(of: "documentTab-", with: "")
        let evidence = app.staticTexts["workspaceSpeechEvidence"].firstMatch
        func waitFor(_ id: String, state: String) {
            expectation(for: NSPredicate { _, _ in
                let value = evidence.value as? String ?? ""
                return value.hasPrefix(id + "|") && value.components(separatedBy: "|").contains(state)
            }, evaluatedWith: evidence)
            waitForExpectations(timeout: 15)
        }
        alpha.press(); app.buttons["modeToggle"].firstMatch.press()
        let play = app.buttons["playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10)); play.press(); waitFor(a, state: "playing")
        let generation = (evidence.value as? String ?? "").components(separatedBy: "|")[2]
        XCTAssertTrue(app.images["playingTab-" + a].firstMatch.exists)
        beta.press()
        XCTAssertTrue(app.images["playingTab-" + a].firstMatch.exists)
        XCTAssertEqual((evidence.value as? String ?? "").components(separatedBy: "|")[2], generation)
        // Editing and switching the other document to reading must not stop Alpha.
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("otherDocumentEdit")
        app.buttons["modeToggle"].firstMatch.press(); waitFor(a, state: "playing")
        XCTAssertEqual(play.label, "开始朗读")
        play.press(); waitFor(b, state: "playing")
        XCTAssertFalse(app.images["playingTab-" + a].firstMatch.exists)
        XCTAssertTrue(app.images["playingTab-" + b].firstMatch.exists)
        XCTAssertNotEqual((evidence.value as? String ?? "").components(separatedBy: "|")[2], generation)
        alpha.press(); waitFor(b, state: "playing")
        XCTAssertEqual(play.label, "开始朗读")
        beta.press(); play.press(); waitFor(b, state: "paused")
        XCTAssertFalse(app.images["playingTab-" + b].firstMatch.exists)
        play.press(); waitFor(b, state: "playing")
        app.buttons["stopSpeech"].firstMatch.press(); waitFor(b, state: "stopped")
        XCTAssertFalse(app.images["playingTab-" + b].firstMatch.exists)
        play.press(); waitFor(b, state: "playing")
        app.buttons["closeTab-" + b].firstMatch.press()
        XCTAssertTrue(app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["closeSaveNo"].firstMatch.press()
        waitFor(a, state: "stopped")
        XCTAssertFalse(app.images["playingTab-" + b].firstMatch.exists)
    }

    func testTabbedManualSaveDiscardAndRecovery() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires visible multi-document controls") }
        #endif
        func tab(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch
        }
        let alpha = tab("标签甲.txt"), beta = tab("标签乙.txt")
        XCTAssertTrue(alpha.waitForExistence(timeout: 20)); XCTAssertTrue(beta.waitForExistence(timeout: 20))
        alpha.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("alphaDraft")
        beta.press(); XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("betaDraft")
        waitForWorkspaceDiskEvidence(app)
        let evidence = app.staticTexts["workspaceDiskEvidence"].firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
        XCTAssertEqual(evidence.value as? String, "标签乙.txt=Beta original|标签甲.txt=Alpha original")
        alpha.press()
        XCTAssertTrue((editor.value as? String ?? "").contains("alphaDraft"))
        let closeAlpha = app.buttons[alpha.identifier.replacingOccurrences(of: "documentTab-", with: "closeTab-")].firstMatch
        closeAlpha.press()
        XCTAssertTrue(app.buttons["closeSaveCancel"].firstMatch.waitForExistence(timeout: 10), app.staticTexts["workspaceCloseEvidence"].firstMatch.value as? String ?? "no close trace"); app.buttons["closeSaveCancel"].firstMatch.press()
        XCTAssertTrue(alpha.exists); XCTAssertTrue((editor.value as? String ?? "").contains("alphaDraft"))
        closeAlpha.press(); XCTAssertTrue(app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveNo"].firstMatch.press()
        XCTAssertTrue(alpha.waitForNonExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("betaDraft"))
        // Termination is intentionally abrupt: automatic recovery must have flushed independently.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--tabs-ui-testing"]
        launch(app)
        XCTAssertTrue(beta.waitForExistence(timeout: 20)); XCTAssertFalse(alpha.exists)
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertTrue((editor.value as? String ?? "").contains("betaDraft"))
        #if os(macOS)
        app.typeKey("s", modifierFlags: .command)
        #else
        app.buttons["documentMenu"].firstMatch.press(); app.buttons["保存"].firstMatch.press()
        #endif
        waitForWorkspaceDiskEvidence(app)
        expectation(for: NSPredicate { _, _ in (evidence.value as? String ?? "").contains("betaDraft") }, evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
        snapshot(app, "多标签-保存放弃与恢复")
    }

    func testClonedViewsShareBodyAndKeepEditingWhenOneTabCloses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires visible multi-document controls") }
        #endif
        let beta = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch
        XCTAssertTrue(beta.waitForExistence(timeout: 20)); beta.press()
        #if os(macOS)
        app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Window", "窗口", "視窗"])).firstMatch.press()
        app.menuItems["克隆到另一视图"].firstMatch.press()
        #else
        app.descendants(matching: .any).matching(identifier: "openWorkspaceTabs").firstMatch.press()
        app.buttons["克隆到另一视图"].firstMatch.press()
        #endif
        let editors = app.textViews.matching(identifier: "manuscriptEditor")
        expectation(for: NSPredicate { _, _ in editors.count == 2 }, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        let first = editors.element(boundBy: 0), second = editors.element(boundBy: 1)
        first.press(); first.typeText("sharedDraft")
        expectation(for: NSPredicate { _, _ in (second.value as? String ?? "").contains("sharedDraft") }, evaluatedWith: second)
        waitForExpectations(timeout: 10)
        #if os(macOS)
        second.press(); app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse((first.value as? String ?? "").contains("sharedDraft"))
        XCTAssertFalse((second.value as? String ?? "").contains("sharedDraft"))
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue((first.value as? String ?? "").contains("sharedDraft"))
        XCTAssertTrue((second.value as? String ?? "").contains("sharedDraft"))
        #endif
        let closes = app.buttons.matching(identifier: beta.identifier.replacingOccurrences(of: "documentTab-", with: "closeTab-"))
        closes.firstMatch.press()
        XCTAssertFalse(app.buttons["closeSaveNo"].firstMatch.exists)
        XCTAssertTrue(editors.allElementsBoundByIndex.contains { ($0.value as? String ?? "").contains("sharedDraft") })
        snapshot(app, "多标签-克隆共享正文")
    }

    func testBatchCloseCancelKeepsEveryDraftAndSavedChoicesAreDurable() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]; launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires visible multi-document controls") }
        #endif
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let alpha = tab("标签甲.txt"), beta = tab("标签乙.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 20))
        alpha.press(); app.textViews["manuscriptEditor"].firstMatch.press(); app.textViews["manuscriptEditor"].firstMatch.typeText("alphaBatch")
        beta.press(); app.textViews["manuscriptEditor"].firstMatch.press(); app.textViews["manuscriptEditor"].firstMatch.typeText("betaBatch")
        func closeAll() {
            app.descendants(matching: .any).matching(identifier: "openWorkspaceTabs").firstMatch.press()
            #if os(macOS)
            app.menuItems["关闭全部标签"].firstMatch.press()
            #else
            app.buttons["关闭全部标签"].firstMatch.press()
            #endif
        }
        closeAll()
        XCTAssertTrue(app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveNo"].firstMatch.press()
        XCTAssertTrue(app.buttons["closeSaveCancel"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveCancel"].firstMatch.press()
        XCTAssertTrue(alpha.exists); XCTAssertTrue(beta.exists)
        alpha.press(); XCTAssertTrue((app.textViews["manuscriptEditor"].firstMatch.value as? String ?? "").contains("alphaBatch"))
        beta.press(); XCTAssertTrue((app.textViews["manuscriptEditor"].firstMatch.value as? String ?? "").contains("betaBatch"))
        closeAll()
        XCTAssertTrue(app.buttons["closeSaveYes"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveYes"].firstMatch.press()
        XCTAssertTrue(app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveNo"].firstMatch.press()
        XCTAssertTrue(alpha.waitForNonExistence(timeout: 10)); XCTAssertFalse(beta.exists)
        waitForWorkspaceDiskEvidence(app)
        let evidence = app.staticTexts["workspaceDiskEvidence"].firstMatch
        expectation(for: NSPredicate { _, _ in (evidence.value as? String ?? "").contains("alphaBatch") && !(evidence.value as? String ?? "").contains("betaBatch") }, evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
    }

    #if os(macOS)
    func testTabsKeepIndependentUndoAndClonedWindowSharesUnsavedText() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]; launch(app)
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let alpha = tab("标签甲.txt"), beta = tab("标签乙.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 20))
        alpha.press(); let editor = app.textViews["manuscriptEditor"].firstMatch
        editor.press(); editor.typeText("alphaUndo")
        beta.press(); editor.press(); editor.typeText("betaWindow")
        alpha.press(); editor.press()
        let undoBefore = editor.value as? String ?? ""
        print("WORKSPACE_UNDO_BEFORE", app.staticTexts["workspaceUndoEvidence"].firstMatch.value ?? "none")
        app.typeKey("z", modifierFlags: .command)
        print("WORKSPACE_UNDO_AFTER", app.staticTexts["workspaceUndoEvidence"].firstMatch.value ?? "none")
        XCTAssertNotEqual(editor.value as? String ?? "", undoBefore, "Undo must change Alpha without affecting Beta")
        beta.press(); XCTAssertTrue((editor.value as? String ?? "").contains("betaWindow"))
        beta.rightClick(); app.menuItems["移动文稿"].firstMatch.hover(); app.menuItems["在新窗口打开"].firstMatch.press()
        expectation(for: NSPredicate { _, _ in app.windows.count == 2 }, evaluatedWith: app); waitForExpectations(timeout: 15)
        let editors = app.textViews.matching(identifier: "manuscriptEditor")
        XCTAssertEqual(editors.count, 2)
        XCTAssertTrue((editors.element(boundBy: 0).value as? String ?? "").contains("betaWindow"))
        XCTAssertTrue((editors.element(boundBy: 1).value as? String ?? "").contains("betaWindow"))
        app.windows.firstMatch.buttons["_XCUI:CloseWindow"].press()
        expectation(for: NSPredicate { _, _ in app.windows.count == 1 }, evaluatedWith: app); waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["closeSaveNo"].firstMatch.exists)
        XCTAssertTrue((app.textViews["manuscriptEditor"].firstMatch.value as? String ?? "").contains("betaWindow"))
        snapshot(app, "多窗口-共享未保存正文与独立撤销")
    }
    #endif

    #if os(macOS)
    func testManualSaveInReadingModeDoesNotCommitAnotherTab() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]; launch(app)
        func tab(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", name)).firstMatch }
        let alpha = tab("标签甲.txt"), beta = tab("标签乙.txt")
        XCTAssertTrue(beta.waitForExistence(timeout: 20))
        alpha.press(); let editor = app.textViews["manuscriptEditor"].firstMatch
        editor.press(); editor.typeText("savedFromReader")
        beta.press(); editor.press(); editor.typeText("keepBetaDraft")
        alpha.press(); app.buttons["modeToggle"].firstMatch.press()
        XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey("s", modifierFlags: .command)
        waitForWorkspaceDiskEvidence(app)
        let evidence = app.staticTexts["workspaceDiskEvidence"].firstMatch
        expectation(for: NSPredicate { _, _ in (evidence.value as? String ?? "").contains("savedFromReader") && !(evidence.value as? String ?? "").contains("keepBetaDraft") }, evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
        beta.press(); XCTAssertTrue((editor.value as? String ?? "").contains("keepBetaDraft"))
    }
    #endif

    #if os(iOS)
    func testPhoneStillUsesSingleDocumentAndAutomaticSave() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone regression") }
        XCTAssertFalse(app.descendants(matching: .any)["openWorkspaceTabs"].exists)
        openBook("历史甲", app: app)
        if !app.textViews["manuscriptEditor"].firstMatch.exists { app.buttons["modeToggle"].firstMatch.press() }
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("phoneAutoSave"); app.typeKey(.return, modifierFlags: [])
        app.buttons["modeToggle"].press()
        XCTAssertFalse(app.buttons["closeSaveNo"].firstMatch.exists)
        openBook("历史乙", app: app)
        openBook("历史甲", app: app)
        if !editor.exists { app.buttons["modeToggle"].firstMatch.press() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertTrue((editor.value as? String ?? "").contains("phoneAutoSave"))
        XCTAssertFalse(app.descendants(matching: .any)["openWorkspaceTabs"].exists)
        snapshot(app, "iPhone-保留单文稿自动保存")
    }
    #endif

    func testUntitledCloseSaveAsCanBeCancelledWithoutLosingTheDraft() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--save-naming-ui-testing"]; launch(app)
        #if os(iOS)
        guard app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-'")).firstMatch.waitForExistence(timeout: 20) else { throw XCTSkip("Requires visible multi-document controls") }
        #endif
        let plus = app.buttons["新建标签"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 20)); plus.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("newDraftToSave")
        let draft = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND NOT (label IN %@)", ["标签甲.txt", "标签乙.txt"])).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let document = draft.identifier.replacingOccurrences(of: "documentTab-", with: "")
        let close = app.buttons["closeTab-" + document].firstMatch
        close.press(); XCTAssertTrue(app.buttons["closeSaveYes"].firstMatch.waitForExistence(timeout: 10)); app.buttons["closeSaveYes"].firstMatch.press()
        #if os(macOS)
        XCTAssertTrue(app.textFields["saveAsNameTextField"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        #else
        XCTAssertTrue(app.textFields["workspaceSaveName"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["workspaceSaveCancel"].firstMatch.press()
        #endif
        XCTAssertTrue(draft.exists); XCTAssertTrue((editor.value as? String ?? "").contains("newDraftToSave"))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: close); waitForExpectations(timeout: 10)
        close.press(); XCTAssertTrue(app.buttons["closeSaveYes"].firstMatch.waitForExistence(timeout: 10))
        #if os(macOS)
        app.buttons["closeSaveYes"].firstMatch.press()
        let field = app.textFields["saveAsNameTextField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.press(); field.typeKey("a", modifierFlags: .command)
        let name = "closed-draft-" + UUID().uuidString + ".txt"
        let directory = app.staticTexts["testExportDirectory"].value as? String ?? ""
        XCTAssertTrue(directory.hasPrefix("/"))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"]
        XCTAssertTrue(path.waitForExistence(timeout: 5)); path.typeKey("a", modifierFlags: .command); path.typeText(directory)
        path.typeKey(.return, modifierFlags: [])
        if path.exists { path.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(name)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["documentTab-" + document].waitForNonExistence(timeout: 10))
        waitForWorkspaceDiskEvidence(app)
        let evidence = app.staticTexts["workspaceDiskEvidence"].firstMatch
        expectation(for: NSPredicate { _, _ in (evidence.value as? String ?? "").contains(name + "=newDraftToSave") }, evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
        #else
        app.buttons["closeSaveNo"].firstMatch.press()
        XCTAssertTrue(draft.waitForNonExistence(timeout: 10))
        #endif
    }

    func testInterfaceLanguageSwitchesLiveAndPersistsWithoutLosingReadingPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]
        launch(app); openBook("长篇甲", app: app)
        let page = app.staticTexts["pageNumber"].firstMatch
        app.buttons["nextPage"].firstMatch.pressAtCenter()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 15), .completed)
        let position = app.staticTexts["readingPosition"].firstMatch.value as? String
        #if os(iOS)
        // 原生菜单的 CollectionView 内容可能超出外层裁剪区，候选项必须完整位于真实弹层内。
        func menuViewport() -> CGRect {
            let content = app.collectionViews.firstMatch.frame
            return app.otherElements.allElementsBoundByIndex.map(\.frame).filter {
                abs($0.minX - content.minX) < 2 && abs($0.width - content.width) < 2 &&
                $0.height >= 150 && $0.height <= content.height && app.windows.firstMatch.frame.contains($0)
            }.min(by: { $0.height < $1.height }) ?? content.intersection(app.windows.firstMatch.frame)
        }
        func revealMenuItem(_ item: XCUIElement) {
            for _ in 0..<4 {
                let bounds = menuViewport()
                if item.isHittable && item.frame.width > 0 && item.frame.height > 0 && bounds.contains(item.frame) { return }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.maxY - 50))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: bounds.midX, dy: bounds.minY + 70)))
            }
            XCTAssertTrue(item.isHittable && menuViewport().contains(item.frame), app.debugDescription)
        }
        #endif
        func chooseLanguage(_ name: String) {
            #if os(macOS)
            app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Ink Engine", "墨语引擎"])).firstMatch.press()
            app.menuItems.matching(NSPredicate(format: "title IN %@", ["语言", "Language", "語言"])).firstMatch.press()
            let choice = app.menuItems.matching(NSPredicate(format: "title == %@", name)).firstMatch
            XCTAssertTrue(choice.exists && choice.frame.width > 0 && choice.frame.height > 0, app.debugDescription)
            choice.pressAtCenter()
            #else
            let more = app.descendants(matching: .any)["documentMenu"].firstMatch
            XCTAssertTrue(more.exists && more.isHittable); more.pressAtCenter()
            let menu = app.buttons.matching(NSPredicate(format: "label IN %@", ["语言", "Language", "語言"])).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
            // 原生菜单克隆项不保留 SwiftUI 标识；滚动真实菜单，避免点到裁剪区域下的正文。
            revealMenuItem(menu)
            XCTAssertTrue(menu.isHittable && app.windows.firstMatch.frame.contains(menu.frame), app.debugDescription)
            snapshot(app, "Language-More-Before-Submenu"); menu.pressAtCenter()
            let code = ["简体中文": "zh-Hans", "English": "en", "繁體中文": "zh-Hant"][name]!
            let identified = app.descendants(matching: .any)["language-" + code].firstMatch
            let choice = identified.exists ? identified : app.buttons.matching(NSPredicate(format: "label == %@", name)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(choice.isHittable && choice.frame.width > 0 && choice.frame.height > 0 && app.windows.firstMatch.frame.contains(choice.frame), app.debugDescription)
            snapshot(app, "Language-Submenu-Before-Selection"); choice.pressAtCenter()
            #endif
        }
        for (name, read) in [("简体中文", "阅读"), ("English", "Read"), ("繁體中文", "閱讀"), ("简体中文", "阅读")] {
            chooseLanguage(name)
            XCTAssertEqual(app.buttons["selectedMode"].firstMatch.label, read)
            XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
            snapshot(app, "Language-Menu-" + name)
        }
        #if os(macOS)
        app.menuBarItems["显示"].firstMatch.press()
        let speechSettings = app.menuItems.matching(NSPredicate(format: "title == '字号与朗读设置'")).firstMatch
        XCTAssertTrue(speechSettings.exists && speechSettings.frame.width > 0 && speechSettings.frame.height > 0)
        speechSettings.pressAtCenter()
        #else
        app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
        let settings = app.descendants(matching: .any).matching(NSPredicate(format: "label == '字号与朗读设置'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); revealMenuItem(settings); settings.pressAtCenter()
        #endif
        let picker = app.descendants(matching: .any)["appLanguagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.pressAtCenter()
        #if os(macOS)
        let english = app.menuItems["language-en"].firstMatch
        XCTAssertTrue(english.exists && english.frame.width > 0 && english.frame.height > 0, app.debugDescription); english.pressAtCenter()
        #else
        let english = app.descendants(matching: .any)["language-en"].firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 10) && english.isHittable && app.windows.firstMatch.frame.contains(english.frame), app.debugDescription)
        english.pressAtCenter()
        #endif
        let done = app.buttons["closeSpeechSettings"].firstMatch
        XCTAssertEqual(done.label, "Done"); snapshot(app, "English-Reading-Settings"); done.pressAtCenter()
        XCTAssertEqual(app.buttons["selectedMode"].firstMatch.label, "Read")
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        if app.buttons["selectedMode"].firstMatch.label == "Edit" { app.buttons["modeToggle"].firstMatch.pressAtCenter() }
        XCTAssertEqual(app.buttons["selectedMode"].firstMatch.label, "Read")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 15), .completed)
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '长篇甲的中文正文'")).firstMatch.exists)
        chooseLanguage("简体中文")
        XCTAssertEqual(app.buttons["selectedMode"].firstMatch.label, "阅读")
    }
    func testNearbyDoneKeycapHasRoomAndClosesSheet() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--received-file-ui-testing"]; launch(app)
        let done = app.buttons["closeNearby"]
        XCTAssertTrue(done.waitForExistence(timeout: 15)); XCTAssertTrue(done.isHittable)
        XCTAssertGreaterThanOrEqual(done.frame.width, 59); XCTAssertGreaterThanOrEqual(done.frame.height, 43)
        snapshot(app, "Nearby-Single-Acrylic-Keycap")
        done.press(); XCTAssertFalse(done.waitForExistence(timeout: 2))
    }
    func testReceivedFileOpensFromReceiptAndSurvivesRestart() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--received-file-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["openReceivedSync"].waitForExistence(timeout: 20)); app.buttons["openReceivedSync"].press()
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '电脑同步来的第一章'")).firstMatch.exists)
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        if !app.buttons["nearbyDevices"].isHittable { app.buttons["showChapterSidebar"].press() }
        #else
        if !app.buttons["nearbyDevices"].isHittable { app.buttons["toggleChapterSidebar"].press() }
        #endif
        app.buttons["nearbyDevices"].firstMatch.press()
        XCTAssertTrue(app.buttons["openReceivedSync"].waitForExistence(timeout: 10))
        snapshot(app, "Received-File-Direct-Open-Persists")
    }
    func testReceivedFolderRevealsChaptersAndLocalDocumentsRecoverHiddenFile() throws {
        #if os(macOS)
        try XCTSkipIf(true, "本机文稿与历史滑动操作仅适用于移动端")
        #endif
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--received-folder-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["openReceivedSync"].waitForExistence(timeout: 20)); app.buttons["openReceivedSync"].press()
        XCTAssertTrue(app.buttons["book-同步第一章"].waitForExistence(timeout: 10)); openBook("同步第一章", app: app)
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15)); snapshot(app, "Received-Folder-Reveals-Chapters")
        app.terminate(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--hidden-local-document-ui-testing"]; launch(app)
        #if os(iOS)
        if !app.buttons["localDocuments"].isHittable { app.buttons["showChapterSidebar"].press() }
        #else
        if !app.buttons["localDocuments"].isHittable { app.buttons["toggleChapterSidebar"].press() }
        #endif
        XCTAssertFalse(app.buttons["book-无历史的同步文件"].exists)
        app.buttons["localDocuments"].press()
        XCTAssertTrue(app.buttons["local-file-无历史的同步文件"].waitForExistence(timeout: 10)); app.buttons["local-file-无历史的同步文件"].press()
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '已同步的正文仍可'")).firstMatch.exists)
        snapshot(app, "Local-Documents-Recovers-File-Without-History")
    }
    func testReceivedDirectoryOpensWhenHistoryIsMissing() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--received-folder-ui-testing", "--missing-received-history-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["openReceivedSync"].waitForExistence(timeout: 20)); app.buttons["openReceivedSync"].press()
        XCTAssertTrue(app.buttons["local-file-同步第一章"].waitForExistence(timeout: 10))
        snapshot(app, "Received-Directory-Without-History-Has-Chapters")
        app.buttons["local-file-同步第一章"].press()
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '电脑同步来的第一章'")).firstMatch.exists)
    }
    func testReadingAtEndOfDocumentStillShowsText() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--end-of-file-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15)); openBook("校稿测试", app: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '这是最后一段'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["文稿还没有正文，点击编辑开始写作。"].exists)
        snapshot(app, "Reader-End-Of-Document-Has-Text")
    }
    /// Run with Scripts/verify_duo_fold.py; record system output alongside each PLAY marker.
    func testCurrentReaderPaginationAndLineSpeechControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("长篇甲", app: app)
        let page = app.staticTexts["pageNumber"].firstMatch
        func ready() { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'ready'"), object: page)], timeout: 20), .completed) }
        ready()
        let first = page.label
        app.buttons["nextPage"].firstMatch.press(); ready(); XCTAssertNotEqual(page.label, first)
        app.buttons["previousPage"].firstMatch.press(); ready(); XCTAssertEqual(page.label, first)
        let line = app.buttons["readingLine-1"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10)); line.pressAtCenter()
        let play = app.buttons["playPause"].firstMatch
        func fields() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        func playing() {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let value = fields(); return value.count > 16 && value[5] == "playing" && value[15] == "system" && (Int64(value[2]) ?? 0) > 4800
            }, object: play)], timeout: 45), .completed)
        }
        playing(); play.press()
        let paused = fields(); XCTAssertEqual(paused[5], "paused")
        app.buttons["下一段"].firstMatch.press()
        XCTAssertNotEqual(fields()[1], paused[1]); XCTAssertEqual(fields()[5], "paused")
        play.press(); playing()
        let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
        let footer = app.descendants(matching: .any)["readerFooter"].firstMatch
        XCTAssertLessThanOrEqual(paper.frame.maxY, footer.frame.minY + 2)
        FileHandle.standardOutput.write(Data("CURRENT_READER_PCM \(play.value as? String ?? "missing")\n".utf8))
        snapshot(app, "Current-Pagination-Line-Seek-Pause-Resume")
        app.buttons["stopSpeech"].firstMatch.press()
    }
    func testDuoSearchReplacementUsesNativeTouchUndoRedo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]
        launch(app); openBook("编辑功能测试", app: app)
        app.buttons["modeToggle"].firstMatch.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        func search() {
            if app.buttons["outlineButton"].firstMatch.exists && app.buttons["outlineButton"].firstMatch.isHittable { app.buttons["outlineButton"].firstMatch.press() }
            else { app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter(); app.buttons["搜索正文"].firstMatch.press() }
        }
        search()
        XCTAssertTrue(app.textFields["searchField"].firstMatch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["替换"].firstMatch.press()
        app.textFields["searchField"].firstMatch.press(); app.textFields["searchField"].firstMatch.typeText("alpha")
        let replacement = app.textFields["replacementField"].firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 10)); replacement.pressAtCenter(); replacement.typeText("beta")
        XCTAssertEqual(app.textFields["searchField"].firstMatch.value as? String, "alpha", app.debugDescription)
        XCTAssertEqual(replacement.value as? String, "beta", app.debugDescription)
        #if os(iOS)
        // iPad 键盘出现时系统会移动 sheet；待真实完成按钮稳定后记录屏幕位置。
        var previousDoneFrame = CGRect.null
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let done = app.buttons["完成"].firstMatch
            guard done.exists && done.isHittable else { return false }
            let frame = done.frame
            defer { previousDoneFrame = frame }
            return frame == previousDoneFrame
        }, object: nil)], timeout: 10), .completed)
        #endif
        let doneBeforeReplaceFrame = app.buttons["完成"].firstMatch.frame
        print("REPLACE_BEFORE_CLICK replace=\(app.buttons["replaceAll"].firstMatch.frame) done=\(app.buttons["完成"].firstMatch.frame) window=\(app.windows.firstMatch.frame)")
        snapshot(app, "Search-Before-Replace-All")
        let beforeReplaceTree = XCTAttachment(string: app.debugDescription); beforeReplaceTree.name = "Search-Before-Replace-All"; beforeReplaceTree.lifetime = .keepAlways; add(beforeReplaceTree)
        #if os(iOS)
        let deviceCapabilities = app.staticTexts["workspaceDeviceCapabilities"].firstMatch
        let isDuoSearch = deviceCapabilities.exists && deviceCapabilities.label.contains("detected=true")
        let replaceFrame = app.buttons["replaceAll"].firstMatch.frame
        if isDuoSearch {
            // Duo 的内屏与远程宿主坐标不同；由真实元素解析命中点，避免 app 原点偏移。
            app.buttons["replaceAll"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: replaceFrame.midX, dy: replaceFrame.midY)).tap()
        }
        #else
        app.buttons["replaceAll"].firstMatch.pressAtCenter()
        #endif
        let replacementMessage = app.staticTexts["searchMessage"].firstMatch
        #if os(macOS)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            replacementMessage.exists && (replacementMessage.label + (replacementMessage.value as? String ?? "")).contains("已替换 3 处")
        }, object: nil)], timeout: 15), .completed, app.debugDescription)
        let changed = app.staticTexts["replaceEvidence"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((changed.value as? String ?? "") + changed.label).contains("beta33")
        }, object: changed)], timeout: 15), .completed)
        app.buttons["完成"].firstMatch.press()
        #else
        // 系统弹层重建后可能暂时退出 AX 树；保留真实画面，并以关闭后原生正文验证三处替换。
        snapshot(app, "Search-After-Replace-All")
        if replacementMessage.exists {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (replacementMessage.label + (replacementMessage.value as? String ?? "")).contains("已替换 3 处")
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
        }
        let currentDone = app.buttons["完成"].firstMatch
        let doneFrame = currentDone.exists && currentDone.isHittable ? currentDone.frame : doneBeforeReplaceFrame
        print("REPLACE_DONE_CLICK before=\(doneBeforeReplaceFrame) current=\(doneFrame)")
        if isDuoSearch { currentDone.tap() }
        else { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: doneFrame.midX, dy: doneFrame.midY)).tap() }
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let text = app.textViews["manuscriptEditor"].firstMatch.value as? String ?? ""
            return ["beta11", "beta22", "beta33"].allSatisfy(text.contains)
        }, object: nil)], timeout: 10), .completed, app.debugDescription)
        #if os(iOS)
        // 触屏菜单直接操作当前文稿的撤销栈，无须先唤起输入法。
        if !isDuoSearch { editor.press() }
        #else
        editor.press()
        #endif
        #if os(iOS)
        if isDuoSearch {
            app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
            let undoItems = app.buttons.matching(NSPredicate(format: "label == '撤销'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                undoItems.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            let undo = try XCTUnwrap(undoItems.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable })
            XCTAssertTrue(undo.isEnabled, app.debugDescription)
            snapshot(app, "Duo-Touch-Undo-Menu")
            undo.tap()
        }
        else { app.typeKey("z", modifierFlags: .command) }
        #else
        app.typeKey("z", modifierFlags: .command)
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["alpha11", "alpha22", "alpha33"].allSatisfy((editor.value as? String ?? "").contains)
        }, object: nil)], timeout: 20), .completed, app.debugDescription)
        #if os(iOS)
        if isDuoSearch {
            app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
            let redoItems = app.buttons.matching(NSPredicate(format: "label == '重做'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                redoItems.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            let redo = try XCTUnwrap(redoItems.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable })
            XCTAssertTrue(redo.isEnabled, app.debugDescription)
            redo.tap()
        }
        else { app.typeKey("z", modifierFlags: [.command, .shift]) }
        #else
        app.typeKey("z", modifierFlags: [.command, .shift])
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["beta11", "beta22", "beta33"].allSatisfy((editor.value as? String ?? "").contains)
        }, object: nil)], timeout: 20), .completed, app.debugDescription)
        snapshot(app, "Duo-Visible-Search-Native-Undo-Redo")
    }

    func testCurrentWorkspaceSearchReplaceUndoAndReadingSettings() throws {
        try exerciseCurrentWorkspaceSearchReplaceUndoAndReadingSettings()
    }

    func testDuoHardwareShortcutsAndFullSearchSettings() throws {
        try exerciseCurrentWorkspaceSearchReplaceUndoAndReadingSettings(duoHardware: true)
    }

    private func exerciseCurrentWorkspaceSearchReplaceUndoAndReadingSettings(duoHardware: Bool = false) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]
        launch(app); openBook("编辑功能测试", app: app)
        app.buttons["modeToggle"].firstMatch.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        func search() {
            if app.buttons["outlineButton"].firstMatch.exists && app.buttons["outlineButton"].firstMatch.isHittable { app.buttons["outlineButton"].firstMatch.press() }
            else { app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter(); app.buttons["搜索正文"].firstMatch.press() }
        }
        search()
        XCTAssertTrue(app.textFields["searchField"].firstMatch.waitForExistence(timeout: 10))
        app.descendants(matching: .any)["替换"].firstMatch.press()
        app.textFields["searchField"].firstMatch.press(); app.textFields["searchField"].firstMatch.typeText("alpha")
        let replacement = app.textFields["replacementField"].firstMatch
        XCTAssertTrue(replacement.waitForExistence(timeout: 10)); replacement.pressAtCenter(); replacement.typeText("beta")
        XCTAssertEqual(app.textFields["searchField"].firstMatch.value as? String, "alpha", app.debugDescription)
        XCTAssertEqual(replacement.value as? String, "beta", app.debugDescription)
        #if os(iOS)
        // iPad 键盘出现时系统会移动 sheet；待真实完成按钮稳定后记录屏幕位置。
        var previousDoneFrame = CGRect.null
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let done = app.buttons["完成"].firstMatch
            guard done.exists && done.isHittable else { return false }
            let frame = done.frame
            defer { previousDoneFrame = frame }
            return frame == previousDoneFrame
        }, object: nil)], timeout: 10), .completed)
        #endif
        let doneBeforeReplaceFrame = app.buttons["完成"].firstMatch.frame
        print("REPLACE_BEFORE_CLICK replace=\(app.buttons["replaceAll"].firstMatch.frame) done=\(app.buttons["完成"].firstMatch.frame) window=\(app.windows.firstMatch.frame)")
        snapshot(app, "Search-Before-Replace-All")
        let beforeReplaceTree = XCTAttachment(string: app.debugDescription); beforeReplaceTree.name = "Search-Before-Replace-All"; beforeReplaceTree.lifetime = .keepAlways; add(beforeReplaceTree)
        #if os(iOS)
        let deviceCapabilities = app.staticTexts["workspaceDeviceCapabilities"].firstMatch
        let isDuoSearch = deviceCapabilities.exists && deviceCapabilities.label.contains("detected=true")
        if duoHardware {
            XCTAssertTrue(isDuoSearch, "Hardware continuation must run on Duo")
            XCTAssertEqual(app.windows.firstMatch.frame.width, 951, accuracy: 1)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 669, accuracy: 1)
        }
        let replaceFrame = app.buttons["replaceAll"].firstMatch.frame
        if isDuoSearch {
            // Duo 的内屏与远程宿主坐标不同；由真实元素解析命中点，避免 app 原点偏移。
            app.buttons["replaceAll"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: replaceFrame.midX, dy: replaceFrame.midY)).tap()
        }
        #else
        app.buttons["replaceAll"].firstMatch.pressAtCenter()
        #endif
        let replacementMessage = app.staticTexts["searchMessage"].firstMatch
        #if os(macOS)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            replacementMessage.exists && (replacementMessage.label + (replacementMessage.value as? String ?? "")).contains("已替换 3 处")
        }, object: nil)], timeout: 15), .completed, app.debugDescription)
        let changed = app.staticTexts["replaceEvidence"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((changed.value as? String ?? "") + changed.label).contains("beta33")
        }, object: changed)], timeout: 15), .completed)
        app.buttons["完成"].firstMatch.press()
        #else
        // 系统弹层重建后可能暂时退出 AX 树；保留真实画面，并以关闭后原生正文验证三处替换。
        snapshot(app, "Search-After-Replace-All")
        if replacementMessage.exists {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (replacementMessage.label + (replacementMessage.value as? String ?? "")).contains("已替换 3 处")
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
        }
        let currentDone = app.buttons["完成"].firstMatch
        let doneFrame = currentDone.exists && currentDone.isHittable ? currentDone.frame : doneBeforeReplaceFrame
        print("REPLACE_DONE_CLICK before=\(doneBeforeReplaceFrame) current=\(doneFrame)")
        if isDuoSearch { currentDone.tap() }
        else { app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: doneFrame.midX, dy: doneFrame.midY)).tap() }
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let text = app.textViews["manuscriptEditor"].firstMatch.value as? String ?? ""
            return ["beta11", "beta22", "beta33"].allSatisfy(text.contains)
        }, object: nil)], timeout: 10), .completed, app.debugDescription)
        #if os(iOS)
        // 触屏菜单直接操作当前文稿的撤销栈，无须先唤起输入法。
        if isDuoSearch && duoHardware {
            editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: 20)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                editor.label.contains("firstResponder=true")
            }, object: nil)], timeout: 5), .completed, editor.debugDescription)
            let sourceBeforeHardware = editor.value as? String
            editor.typeKey("a", modifierFlags: .command)
            XCTAssertEqual(editor.value as? String, sourceBeforeHardware, "Command-A must select without editing")
            let selectedLength = (editor.value as? String ?? "").utf16.count
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                editor.label.contains("selection=0,\(selectedLength);")
            }, object: nil)], timeout: 5), .completed, editor.debugDescription)
            print("DUO_HARDWARE_CMD_A \(editor.label)")
            snapshot(app, "Duo-Hardware-Command-A-Selected-All")
        } else if !isDuoSearch { editor.press() }
        #else
        editor.press()
        #endif
        #if os(iOS)
        if isDuoSearch && !duoHardware {
            app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
            let undoItems = app.buttons.matching(NSPredicate(format: "label == '撤销'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                undoItems.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            let undo = try XCTUnwrap(undoItems.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable })
            XCTAssertTrue(undo.isEnabled, app.debugDescription)
            snapshot(app, "Duo-Touch-Undo-Menu")
            undo.tap()
        }
        else if duoHardware { editor.typeKey("z", modifierFlags: .command) }
        else { app.typeKey("z", modifierFlags: .command) }
        #else
        app.typeKey("z", modifierFlags: .command)
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["alpha11", "alpha22", "alpha33"].allSatisfy((editor.value as? String ?? "").contains)
        }, object: nil)], timeout: 20), .completed, app.debugDescription)
        #if os(iOS)
        if isDuoSearch && !duoHardware {
            app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter()
            let redoItems = app.buttons.matching(NSPredicate(format: "label == '重做'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                redoItems.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            let redo = try XCTUnwrap(redoItems.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable })
            XCTAssertTrue(redo.isEnabled, app.debugDescription)
            redo.tap()
        }
        else if duoHardware { editor.typeKey("z", modifierFlags: [.command, .shift]) }
        else { app.typeKey("z", modifierFlags: [.command, .shift]) }
        #else
        app.typeKey("z", modifierFlags: [.command, .shift])
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ["beta11", "beta22", "beta33"].allSatisfy((editor.value as? String ?? "").contains)
        }, object: nil)], timeout: 20), .completed, app.debugDescription)
        let sourceBeforeSyntax = editor.value as? String
        #if os(iOS)
        if isDuoSearch {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), app.debugDescription)
        } else { editor.swipeDown() }
        #endif
        let syntax = app.descendants(matching: .any)["syntaxMenu"].firstMatch
        XCTAssertTrue(syntax.waitForExistence(timeout: 10)); syntax.pressAtCenter()
        #if os(macOS)
        app.menuItems.matching(identifier: "SQL").allElementsBoundByIndex.first(where: { $0.isHittable })?.press()
        #else
        if isDuoSearch {
            snapshot(app, "Duo-Syntax-Menu-Before-SQL")
            let options = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'syntax-sql' OR label == 'SQL'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                options.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            try XCTUnwrap(options.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable }).pressAtCenter()
        } else { app.buttons["SQL"].firstMatch.pressAtCenter() }
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'SQL'"), object: syntax)], timeout: 10), .completed)
        XCTAssertEqual(editor.value as? String, sourceBeforeSyntax)
        snapshot(app, "Current-Syntax-SQL")
        syntax.pressAtCenter()
        #if os(macOS)
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH '自动识别'")).allElementsBoundByIndex.first(where: { $0.isHittable })?.press()
        #else
        if isDuoSearch {
            let options = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'syntax-auto' OR label BEGINSWITH '自动识别'"))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                options.allElementsBoundByIndex.contains { !$0.frame.isEmpty && $0.isHittable }
            }, object: nil)], timeout: 10), .completed, app.debugDescription)
            try XCTUnwrap(options.allElementsBoundByIndex.first { !$0.frame.isEmpty && $0.isHittable }).pressAtCenter()
        } else { app.buttons.matching(NSPredicate(format: "label BEGINSWITH '自动识别'")).firstMatch.pressAtCenter() }
        #endif
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'TXT'"), object: syntax)], timeout: 10), .completed)
        XCTAssertEqual(editor.value as? String, sourceBeforeSyntax)
        app.buttons["modeToggle"].firstMatch.press()
        let page = app.staticTexts["pageNumber"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'ready'"), object: page)], timeout: 20), .completed)
        let position = app.staticTexts["readingPosition"].firstMatch.value as? String
        let palette = app.descendants(matching: .any)["appearanceMenu"].firstMatch
        XCTAssertTrue(palette.waitForExistence(timeout: 10) && palette.isHittable, app.debugDescription)
        snapshot(app, "Current-Visible-Toolbar-Palette"); palette.pressAtCenter()
        let font = app.sliders["workspaceFontSize"].firstMatch
        XCTAssertTrue(font.waitForExistence(timeout: 10)); font.adjust(toNormalizedSliderPosition: 0.5)
        #if os(macOS)
        app.popUpButtons.matching(NSPredicate(format: "identifier BEGINSWITH 'theme-'")).firstMatch.press(); app.menuItems["暖黄"].firstMatch.press()
        #else
        let themePicker = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'theme-'")).firstMatch
        if themePicker.exists { themePicker.press() }
        else { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '界面主题'")).firstMatch.press() }
        app.buttons["暖黄"].firstMatch.press()
        #endif
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(font.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["readingPosition"].firstMatch.value as? String, position)
        #if os(macOS)
        app.menuBarItems["阅读"].firstMatch.press(); app.menuItems["阅读书签…"].firstMatch.press()
        #else
        app.descendants(matching: .any)["documentMenu"].firstMatch.pressAtCenter(); app.buttons["阅读书签"].firstMatch.press()
        #endif
        app.buttons["addBookmark"].firstMatch.press()
        let name = app.textFields["bookmarkNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.press(); app.typeKey("a", modifierFlags: .command); name.typeText("CurrentLayoutBookmark")
        app.buttons["saveBookmark"].firstMatch.press()
        XCTAssertTrue(app.buttons["bookmark-CurrentLayoutBookmark"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(app.descendants(matching: .any)["readerPaper"].firstMatch.exists)
        snapshot(app, "Current-Search-Undo-Reader-Theme-Bookmark")
    }
    #if os(iOS)
    func testCurrentMobileFileEntryCancellationPreservesDocument() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 20))
        let content = editor.value as? String
        for action in ["打开文件", "添加小说目录"] {
            app.buttons["documentMenu"].firstMatch.pressAtCenter()
            let entry = app.buttons[action].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.press()
            let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.press()
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertEqual(editor.value as? String, content)
        }
        snapshot(app, "Current-File-And-Folder-Cancellation")
    }
    #endif
    func testEOFPlayStartsSystemSpeechOnPhoneAndPad() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--end-of-file-ui-testing", "--system-speech-ui-testing"]
        launch(app)
        openBook("校稿测试", app: app)
        let page = app.staticTexts["pageNumber"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'ready'"), object: page)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        let play = app.buttons["playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.press()
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let fields = (play.value as? String ?? "").components(separatedBy: "|")
            return fields.count > 16 && fields[5] == "playing" && fields[15] == "system" && fields[16] == "false" && (Int64(fields[2]) ?? 0) > 4800
        }, object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 90), .completed, "EOF Play must generate system speech after an actual UI click: \(play.value as? String ?? "missing")")
        FileHandle.standardOutput.write(Data("PHONE_PAD_EOF_PLAYING \(play.value as? String ?? "missing")\n".utf8))
        snapshot(app, "Phone-Pad-EOF-System-Speech")
        app.buttons["stopSpeech"].firstMatch.press()
    }
    func testDuoEOFPlayStartsSystemSpeechInEveryPose() throws {
        try checkDuoEOFPlay(renderer: "system", flag: "--system-speech-ui-testing")
    }
    func testDuoEOFPlayStartsZipVoiceInEveryPose() throws {
        try checkDuoEOFPlay(renderer: "zipvoice", flag: "--zipvoice-ui-testing")
    }
    private func checkDuoEOFPlay(renderer: String, flag: String) throws {
        let app = XCUIApplication()
        for (index, pose) in ["OPEN", "CLOSED", "PARTIAL"].enumerated() {
            app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--end-of-file-ui-testing", flag]
            launch(app)
            XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 20))
            app.buttons["book-校稿测试"].firstMatch.press() // Compact portrait has an icon toggle; the reader-ready check below is the mode evidence.
            let page = app.staticTexts["pageNumber"].firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'ready'"), object: page)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
            FileHandle.standardOutput.write(Data("DUO_FOLD_STEP_\(index + 1)_\(pose)\n".utf8))
            let began = Date()
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                Date().timeIntervalSince(began) >= 3 && (pose == "CLOSED" ? max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) < 800 : max(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) > 800)
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 25), .completed)
            let play = app.buttons["playPause"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            FileHandle.standardOutput.write(Data("DUO_EOF_PLAY \(renderer) \(pose) before=\(play.value as? String ?? "missing")\n".utf8))
            play.press()
            let playing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let fields = (play.value as? String ?? "").components(separatedBy: "|")
                return fields.count > 16 && fields[5] == "playing" && fields[15] == renderer && fields[16] == "false" && (Int64(fields[2]) ?? 0) > 4800
            }, object: play)
            XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 90), .completed, "EOF Play must generate speech after an actual UI click: \(play.value as? String ?? "missing")")
            FileHandle.standardOutput.write(Data("DUO_EOF_PLAYING \(renderer) \(pose) \(play.value as? String ?? "missing")\n".utf8))
            snapshot(app, "Duo-EOF-Play-" + renderer + "-" + pose)
            app.buttons["stopSpeech"].firstMatch.press()
            app.terminate()
        }
    }
    func testReaderFooterKeepsSpaceAndSeparateControls() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]; launch(app); openBook("长篇甲", app: app)
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15))
        for theme in ["white", "warm", "green", "dark"] {
            themeOption(theme, app: app).press()
            let themeApplied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", theme), object: app.descendants(matching: .any)["appearanceMenu"].firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [themeApplied], timeout: 10), .completed)
            let pageReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == 'ready'"), object: app.staticTexts["pageNumber"])
            XCTAssertEqual(XCTWaiter.wait(for: [pageReady], timeout: 15), .completed)
            // 主题会触发局部分页和系统菜单关闭；在最终页面上检查实际底栏范围。
            snapshot(app, "Reader-Footer-Before-Bounds-" + theme)
            let reader = app.descendants(matching: .any)["reader"].firstMatch, paper = app.descendants(matching: .any)["readerPaper"].firstMatch
            let footer = app.descendants(matching: .any)["readerFooter"].firstMatch
            #if os(iOS)
            XCTAssertLessThanOrEqual(footer.frame.height, 114, "底栏范围：\(footer.frame)")
            if reader.frame.width < 700 { XCTAssertGreaterThanOrEqual(app.buttons["playPause"].frame.minY - app.buttons["nextPage"].frame.maxY, 8, "手机底栏两行应留出按钮和阴影间距") }
            #else
            XCTAssertLessThanOrEqual(footer.frame.height, 98, "底栏范围：\(footer.frame)")
            #endif
            XCTAssertGreaterThan(paper.frame.height, reader.frame.height * 0.70)
            let controls = [app.buttons["previousPage"], app.buttons["nextPage"], app.buttons["上一段"], app.buttons["playPause"], app.buttons["下一段"], app.buttons["stopSpeech"], app.buttons["speechSpeed"], app.descendants(matching: .any)["appearanceMenu"].firstMatch, app.descendants(matching: .any)["syntaxMenu"].firstMatch]
            XCTAssertEqual(app.buttons["playPause"].frame.midX, (app.buttons["speechSpeed"].frame.minX + app.buttons["stopSpeech"].frame.maxX) / 2, accuracy: 1, "播放应位于朗读控制中央")
            for (index, control) in controls.enumerated() {
                XCTAssertGreaterThanOrEqual(control.frame.minX, reader.frame.minX - 1)
                XCTAssertLessThanOrEqual(control.frame.maxX, reader.frame.maxX + 1)
                #if os(iOS)
                XCTAssertGreaterThanOrEqual(control.frame.height, 43)
                #endif
                for other in controls.dropFirst(index + 1) { XCTAssertFalse(control.frame.intersects(other.frame)) }
            }
            snapshot(app, "Reader-Footer-Space-" + theme)
        }
    }
    func testLocalDirectoryNavigationAndConfirmedDeletion() throws {
        #if os(macOS)
        try XCTSkipIf(true, "本机文稿与历史滑动操作仅适用于移动端")
        #endif
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--local-documents-ui-testing"]; launch(app)
        let local = app.buttons["localDocuments"]
        XCTAssertTrue(app.buttons["novel-目录浏览测试"].waitForExistence(timeout: 15))
        XCTAssertTrue(local.waitForExistence(timeout: 15)); openLocalBrowser(app); snapshot(app, "Local-Browser-Initial-Root")
        let folder = app.descendants(matching: .any)["local-folder-目录浏览测试"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription); XCTAssertFalse(app.buttons["local-file-第2章"].exists)
        assertLocalToolbar(app)
        folder.press()
        XCTAssertTrue(app.buttons["local-file-第1章"].waitForExistence(timeout: 10))
        let child = app.descendants(matching: .any)["local-directory-下篇"].firstMatch
        XCTAssertTrue(child.exists); child.press()
        let file = app.buttons["local-file-第2章"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        assertLocalToolbar(app); snapshot(app, "Local-Toolbar-Nested-Directory")
        #if os(macOS)
        file.rightClick(); app.menuItems["删除本机文稿…"].press()
        #else
        file.press(forDuration: 1); app.buttons["删除本机文稿…"].press()
        #endif
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); snapshot(app, "Local-Delete-Confirmation")
        app.alerts.buttons["取消"].press(); XCTAssertTrue(file.waitForExistence(timeout: 5))
        #if os(macOS)
        file.rightClick(); app.menuItems["删除本机文稿…"].press()
        #else
        file.press(forDuration: 1); app.buttons["删除本机文稿…"].press()
        #endif
        app.alerts.buttons["删除本机文稿"].press()
        XCTAssertTrue(file.waitForNonExistence(timeout: 10))
        app.buttons["closeLocalDocuments"].press()
        XCTAssertTrue(app.buttons["closeLocalDocuments"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: local)], timeout: 5), .completed)
        openLocalBrowser(app)
        snapshot(app, "Local-Browser-Reopened-Root")
        XCTAssertTrue(app.buttons["local-file-独立文稿"].waitForExistence(timeout: 10), app.debugDescription)
        let other = app.descendants(matching: .any)["local-folder-另一部小说"].firstMatch
        XCTAssertTrue(other.exists); snapshot(app, "Local-Directory-Root")
        #if os(macOS)
        other.rightClick(); app.menuItems["删除本机目录…"].press()
        #else
        other.press(forDuration: 1); app.buttons["删除本机目录…"].press()
        #endif
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["删除本机文稿"].press()
        XCTAssertTrue(other.waitForNonExistence(timeout: 10)); XCTAssertTrue(app.buttons["local-file-独立文稿"].exists)
        app.buttons["closeLocalDocuments"].press()
        XCTAssertFalse(app.buttons["trashToggle"].exists)
        let cache = app.buttons["cacheManager"].firstMatch
        XCTAssertEqual(local.frame.midY, cache.frame.midY, accuracy: 1); XCTAssertFalse(local.frame.intersects(cache.frame))
    }
    private func assertLocalToolbar(_ app: XCUIApplication) {
        let done = app.buttons["closeLocalDocuments"], refresh = app.buttons["refreshLocalDocuments"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(refresh.exists)
        XCTAssertEqual(done.label, "完成")
        XCTAssertGreaterThanOrEqual(done.frame.width, 59)
        XCTAssertGreaterThanOrEqual(refresh.frame.width, 43)
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(done.frame.height, 43)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 43)
        #endif
        XCTAssertFalse(done.frame.intersects(refresh.frame))
    }
    private func openLocalBrowser(_ app: XCUIApplication) {
        let button = app.buttons["localDocuments"]
        #if os(iOS)
        // 弹窗退出后按当前窗口中的可见按钮中心点击，不使用玻璃层缓存的辅助功能点击位置。
        let rect = button.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        #else
        button.press()
        #endif
        XCTAssertTrue(app.buttons["closeLocalDocuments"].waitForExistence(timeout: 10))
    }
    #if os(iOS)
    func testPhysicalComputerDirectoryArrivalAndCleanup() throws {
        guard let name = ProcessInfo.processInfo.environment["INK_USB_TEST_FOLDER"], name.hasPrefix("Ink-USB-"), name.count > 20 else { throw XCTSkip("仅验证明确指定的临时真机目录") }
        let app = XCUIApplication(); app.launchArguments = []; launch(app)
        if !app.buttons["localDocuments"].isHittable && app.buttons["showChapterSidebar"].exists { app.buttons["showChapterSidebar"].press() }
        let local = app.buttons["localDocuments"]
        XCTAssertTrue(local.waitForExistence(timeout: 20)); local.pressAtCenter()
        let folder = app.descendants(matching: .any)["local-folder-" + name].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20), app.debugDescription); snapshot(app, "Physical-USB-Directory-Arrived")
        folder.press()
        XCTAssertTrue(app.descendants(matching: .any)["local-directory-SecondPart"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["local-file-USBChapterOne"].press()
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '电脑传入的临时正文'")).firstMatch.exists)
        snapshot(app, "Physical-USB-Document-Readable")
        app.buttons["showChapterSidebar"].press(); local.pressAtCenter()
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.press(forDuration: 1)
        app.buttons["删除本机目录…"].press()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["删除本机文稿"].press()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 15)); app.buttons["closeLocalDocuments"].press()
        snapshot(app, "Physical-USB-Test-Sample-Cleaned")
    }
    #endif
    #if os(iOS)
    func testHistorySwipePinUnpinAndRemoveKeepsLocalDocument() throws {
        #if os(macOS)
        try XCTSkipIf(true, "本机文稿与历史滑动操作仅适用于移动端")
        #endif
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        let file = app.buttons["book-历史甲"]
        XCTAssertTrue(file.waitForExistence(timeout: 15)); file.swipeRight(); snapshot(app, "History-Swipe-Pin-Revealed")
        let pin = app.buttons["固定到顶部"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); pin.press()
        XCTAssertTrue(app.staticTexts["已固定 · 可拖拽排序"].waitForExistence(timeout: 5))
        file.swipeRight(); let unpin = app.buttons["取消固定"].firstMatch
        XCTAssertTrue(unpin.waitForExistence(timeout: 5)); unpin.press()
        file.swipeLeft(); let remove = app.buttons["删除历史记录"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.press()
        XCTAssertTrue(file.waitForNonExistence(timeout: 5))
        app.buttons["localDocuments"].press()
        XCTAssertTrue(app.buttons["local-file-历史甲"].waitForExistence(timeout: 10)); snapshot(app, "Swipe-Remove-Keeps-Local-File")
        app.buttons["local-file-历史甲"].press()
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 15))
    }
    #endif
    func testPronunciationCustomRulePersistsAndKeepsOriginal() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing", "--light-speech-ui-testing"]; launch(app); openBook("校稿测试", app: app)
        themeOption("green", app: app).press()
        documentAction("speechSettings", app: app).press()
        let settings = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.buttons["pronunciationSettings"].exists && app.buttons["pronunciationSettings"].isHittable { break }
            #if os(iOS)
            settings.swipeUp()
            #else
            settings.scroll(byDeltaX: 0, deltaY: -250)
            #endif
        }
        XCTAssertTrue(app.buttons["pronunciationSettings"].waitForExistence(timeout: 10)); app.buttons["pronunciationSettings"].pressAtCenter()
        let phrase = app.textFields["pronunciationPhrase"], spoken = app.textFields["pronunciationSpoken"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 10)); phrase.press(); phrase.typeText("行长")
        spoken.press(); spoken.typeText("航掌\n")
        XCTAssertEqual(spoken.value as? String, "航掌")
        XCTAssertTrue(app.buttons["savePronunciation"].isEnabled)
        app.buttons["savePronunciation"].pressAtCenter()
        revealPronunciationRule(app)
        XCTAssertTrue(app.staticTexts["行长 → 航掌"].waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press(); app.buttons["完成"].firstMatch.press()
        let play = app.buttons["playPause"]; play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let fields = (play.value as? String ?? "").components(separatedBy: "|"); return fields.count > 15 && fields[15] == "zipvoice" && (Int64(fields[2]) ?? 0) > 4800 }, object: nil)], timeout: 30), .completed)
        app.buttons["stopSpeech"].press(); app.buttons["modeToggle"].press()
        let original = app.textViews["manuscriptEditor"].value as? String ?? ""
        XCTAssertTrue(original.contains("银行")); XCTAssertTrue(original.contains("行长")); XCTAssertFalse(original.contains("航掌"))
        app.terminate(); app.launchArguments = ["--ui-testing", "--light-speech-ui-testing"]; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        documentAction("speechSettings", app: app).press()
        for _ in 0..<4 {
            if app.buttons["pronunciationSettings"].exists && app.buttons["pronunciationSettings"].isHittable { break }
            #if os(iOS)
            app.descendants(matching: .any)["speechSettingsForm"].firstMatch.swipeUp()
            #else
            app.descendants(matching: .any)["speechSettingsForm"].firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            #endif
        }
        XCTAssertTrue(app.buttons["pronunciationSettings"].waitForExistence(timeout: 10)); app.buttons["pronunciationSettings"].pressAtCenter()
        revealPronunciationRule(app)
        XCTAssertTrue(app.staticTexts["行长 → 航掌"].waitForExistence(timeout: 10)); snapshot(app, "Custom-Pronunciation-Saved-Without-Editing-Source")
    }
    private func revealPronunciationRule(_ app: XCUIApplication) {
        // 居中弹层会虚拟化屏幕外的表单行，保存后滚动到规则列表再核对。
        for _ in 0..<4 {
            if app.staticTexts["行长 → 航掌"].exists { break }
            #if os(iOS)
            app.descendants(matching: .any)["pronunciationForm"].firstMatch.swipeUp()
            #else
            app.descendants(matching: .any)["pronunciationForm"].firstMatch.scroll(byDeltaX: 0, deltaY: -250)
            #endif
        }
    }
    /// 大 TXT 基线只读有界 AX 摘要；UI 墙钟包含自动化等待，CPU 热点以应用计时为准。
    func testLargeTXTEditorPerformanceBaseline() throws {
        try exerciseLargeTXTEditorBenchmark(checkContinuity: false)
    }
    func testLargeTXTEditorPerformanceAndContinuity() throws {
        try exerciseLargeTXTEditorBenchmark(checkContinuity: true)
    }
    /// 暂存检查点计算与后续真实输入、模式切换交错，重启后必须保留较新的全部字符。
    func testLargeTXTWorkingDraftKeepsNewTypingWhenSwitchingModes() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--large-file-ui-testing", "--synthetic-large-ui-testing", "--system-speech-ui-testing", "--editor-performance-ui-testing", "--slow-working-draft-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["book-大文件分页测试"].firstMatch.waitForExistence(timeout: 120))
        openBook("大文件分页测试", app: app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        app.buttons["modeToggle"].firstMatch.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        func field(_ name: String) -> String {
            editor.label.components(separatedBy: ";").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) } ?? "missing"
        }
        func nearby() -> String { Data(base64Encoded: field("nearCaretBase64")).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let originalLength = Int(field("nativeLength")) ?? 0
        XCTAssertGreaterThan(originalLength, 4_000_000)
        editor.tap(); app.typeText("FIRST")
        RunLoop.current.run(until: Date().addingTimeInterval(0.88))
        app.typeText("SECOND")
        XCTAssertEqual(Int(field("nativeLength")), originalLength + 11)
        XCTAssertTrue(nearby().contains("FIRSTSECOND"))
        app.buttons["modeToggle"].firstMatch.tap()
        let mode = app.buttons["modeToggle"].firstMatch
        let page = app.staticTexts["pageNumber"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in mode.isEnabled && mode.label.contains("编辑") && page.value as? String == "ready" && !editor.isHittable }, object: nil)], timeout: 30), .completed)
        app.buttons["modeToggle"].firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in mode.isEnabled && mode.label.contains("阅读") && editor.exists && editor.isHittable }, object: nil)], timeout: 30), .completed)
        // 仅本例将后台计算故意延长四秒；等待旧快照被拒写并让新快照完成，性能基准不使用该标记。
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        XCTAssertEqual(Int(field("nativeLength")), originalLength + 11)
        XCTAssertTrue(nearby().contains("FIRSTSECOND"))
        print("EDITOR_DRAFT_RACE_BEFORE_RELAUNCH \(editor.label)")
        snapshot(app, "Large-TXT-Concurrent-Draft-Before-Relaunch")
        app.terminate()
        // 沿用同一隔离文库，移除所有重置及自动生成标记，验证真实持久化恢复。
        app.launchArguments = ["--ui-testing", "--large-file-ui-testing", "--system-speech-ui-testing", "--editor-performance-ui-testing"]
        app.launch()
        if !editor.waitForExistence(timeout: 5) {
            openBook("大文件分页测试", app: app)
            if !editor.exists { app.buttons["modeToggle"].firstMatch.tap() }
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 60))
        XCTAssertEqual(Int(field("nativeLength")), originalLength + 11)
        XCTAssertTrue(nearby().contains("FIRSTSECOND"))
        print("EDITOR_DRAFT_RACE_RESTORED \(editor.label)")
        snapshot(app, "Large-TXT-Concurrent-Draft-Restored")
        #endif
    }
    /// 逐个点击真实拼音软件按键及候选，区分组合态和已提交中文；不使用 setMarkedText 注入。
    func testChineseSoftwarePinyinCompositionCommitsAndUndoes() throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing", "--editor-performance-ui-testing"]
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        app.buttons["toolbarNewDocument"].firstMatch.pressAtCenter()
        func field(_ name: String) -> String {
            editor.label.components(separatedBy: ";").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) } ?? "missing"
        }
        XCTAssertEqual(field("nativeLength"), "0")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        // 真机拼音键盘可能处于英文子模式；点击公开的“拼音”模式键，才能真实创建组合态。
        let pinyinMode = app.keyboards.keys.matching(NSPredicate(format: "label IN %@", ["切换至非罗马字符键", "拼音", "Switch to Non-Roman Keyboard"])).firstMatch
        if pinyinMode.exists && pinyinMode.isHittable { pinyinMode.tap() }
        // 真机拼音键盘可能保留大写 Shift 状态；用可见系统按键恢复小写，不修改个人键盘设置。
        if !app.keyboards.keys["z"].firstMatch.exists && app.keyboards.keys["Z"].firstMatch.exists {
            let shift = app.keyboards.buttons["shift"].firstMatch
            XCTAssertTrue(shift.exists && shift.isHittable)
            shift.tap()
        }
        for key in ["z", "h", "o", "n", "g"] {
            let button = app.keyboards.keys[key].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Actual software Pinyin keys must be visible")
            button.tap()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("marked") == "true" }, object: nil)], timeout: 10), .completed)
        let composition = editor.label
        snapshot(app, "Chinese-Pinyin-Actual-Marked-Candidate")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(field("marked"), "true", "A normal render/highlight pass must preserve the input method composition")
        print("CHINESE_IME_MARKED \(composition)")
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label == '中'")).allElementsBoundByIndex.first { $0.isHittable && $0.frame.height > 0 }
        XCTAssertNotNil(candidate, "The system Pinyin candidate must be genuinely available")
        guard let candidate else { return }
        candidate.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("marked") == "false" && field("nativeLength") == "1" }, object: nil)], timeout: 10), .completed)
        func nearby() -> String { Data(base64Encoded: field("nearCaretBase64")).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        XCTAssertEqual(nearby(), "中")
        snapshot(app, "Chinese-Pinyin-Actual-Commit")
        var undoGroups = 0
        while field("nativeLength") != "0" && undoGroups < 8 {
            let before = nearby()
            chooseColumnTestMenu("撤销", in: app)
            undoGroups += 1
            print("CHINESE_IME_UNDO_IMMEDIATE group=\(undoGroups) native=\(editor.label) nearby=\(nearby())")
            snapshot(app, "Chinese-Pinyin-Undo-Group-\(undoGroups)")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in nearby() != before }, object: nil)], timeout: 10), .completed)
            print("CHINESE_IME_UNDO group=\(undoGroups) native=\(editor.label) nearby=\(nearby())")
        }
        XCTAssertEqual(field("nativeLength"), "0")
        for _ in 0..<undoGroups { chooseColumnTestMenu("重做", in: app) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("nativeLength") == "1" && nearby() == "中" }, object: nil)], timeout: 10), .completed)
        print("CHINESE_IME_COMMITTED_UNDO_REDO \(editor.label)")
        #endif
    }
    private func exerciseLargeTXTEditorBenchmark(checkContinuity: Bool) throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--large-file-ui-testing", "--synthetic-large-ui-testing", "--system-speech-ui-testing", "--editor-performance-ui-testing"]
        func timed(_ phase: String, _ operation: () -> Void) {
            let start = Date(); operation()
            print("EDITOR_UI_WALL phase=\(phase) ms=\(Date().timeIntervalSince(start) * 1000)")
        }
        timed("launch-fixture") {
            app.launch()
            XCTAssertTrue(app.buttons["book-大文件分页测试"].firstMatch.waitForExistence(timeout: 120))
        }
        timed("open-reader") { openBook("大文件分页测试", app: app) }
        let page = app.staticTexts["pageNumber"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 60), .completed)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        timed("enter-editor") {
            app.buttons["modeToggle"].firstMatch.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 120))
        }
        func field(_ name: String) -> String {
            editor.label.components(separatedBy: ";").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) } ?? "missing"
        }
        let originalLength = Int(field("nativeLength")) ?? 0
        XCTAssertGreaterThan(originalLength, 4_000_000)
        print("EDITOR_LARGE_BASELINE originalLength=\(originalLength) summary=\(editor.label)")
        timed("input-three-characters") {
            editor.tap(); app.typeText("验收A")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Int(field("nativeLength")) == originalLength + 3 }, object: nil)], timeout: 60), .completed)
        }
        let encoded = field("nearCaretBase64")
        let nearby = Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(nearby.contains("验收A"), "Actual Unicode insertion must reach native storage; this does not claim marked-text IME coverage")
        print("EDITOR_LARGE_AFTER_INPUT summary=\(editor.label)")
        let beforeWrapping = field("nativeWrapping")
        timed("toggle-wrapping") {
            let wrap = self.visibleEditorWrap(in: app)
            XCTAssertTrue(wrap.exists); XCTAssertTrue(wrap.isHittable); wrap.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("nativeWrapping") != beforeWrapping }, object: nil)], timeout: 120), .completed)
        }
        XCTAssertEqual(Int(field("nativeLength")), originalLength + 3)
        print("EDITOR_LARGE_AFTER_WRAP summary=\(editor.label)")
        snapshot(app, "Large-TXT-Baseline-Editor-Wrapped")
        if checkContinuity {
            let selectionBeforeScroll = field("selection")
            let scrollBefore = Double(field("scrollY")) ?? -1
            XCTAssertGreaterThanOrEqual(scrollBefore, 0)
            timed("large-native-scroll") {
                editor.swipeUp()
                // 静置期间不读取 AX，避免自动化快照本身影响原生视口布局。
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                snapshot(app, "Large-TXT-Scrolled-NoAX-Settled")
            }
            let scrollAfter = Double(field("scrollY")) ?? -1
            XCTAssertGreaterThan(scrollAfter, scrollBefore + 100)
            XCTAssertEqual(field("selection"), selectionBeforeScroll)
            XCTAssertEqual(Int(field("nativeLength")), originalLength + 3)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            print("EDITOR_LARGE_SCROLL before=\(scrollBefore) after=\(scrollAfter) selection=\(selectionBeforeScroll)")
            var undoCount = 0
            timed("native-undo") {
                while (Int(field("nativeLength")) ?? 0) > originalLength && undoCount < 5 {
                    let previous = Int(field("nativeLength")) ?? 0
                    self.chooseColumnTestMenu("撤销", in: app); undoCount += 1
                    print("EDITOR_LARGE_UNDO group=\(undoCount) native=\(editor.label)")
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (Int(field("nativeLength")) ?? 0) < previous }, object: nil)], timeout: 15), .completed)
                }
                XCTAssertEqual(Int(field("nativeLength")), originalLength)
            }
            timed("native-redo") {
                for _ in 0..<undoCount { self.chooseColumnTestMenu("重做", in: app) }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Int(field("nativeLength")) == originalLength + 3 }, object: nil)], timeout: 15), .completed)
            }
            let restored = Data(base64Encoded: field("nearCaretBase64")).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTAssertTrue(restored.contains("验收A"))
            timed("enter-column-mode") {
                self.chooseColumnTestMenu("列模式", in: app)
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("columnMode") == "true" }, object: nil)], timeout: 120), .completed)
            }
            timed("wrapping-exits-column-mode") {
                self.visibleEditorWrap(in: app).tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in field("columnMode") == "false" && field("nativeWrapping") == "true" }, object: nil)], timeout: 120), .completed)
            }
            XCTAssertEqual(Int(field("nativeLength")), originalLength + 3)
            timed("return-reader") {
                app.buttons["modeToggle"].firstMatch.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: page)], timeout: 60), .completed)
            }
            let position = app.staticTexts["readingPosition"].firstMatch
            let caretPosition = position.value as? String
            XCTAssertEqual(caretPosition, "3")
            app.buttons["modeToggle"].firstMatch.tap()
            XCTAssertTrue(editor.waitForExistence(timeout: 30))
            XCTAssertEqual(field("selection"), "3,0")
            app.buttons["modeToggle"].firstMatch.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String == caretPosition }, object: nil)], timeout: 30), .completed)
            // 编辑插入点可以位于页内；用户翻页的往返基准应先归一到第一页页首。
            if position.value as? String != "0" {
                let before = position.value as? String
                app.buttons["nextPage"].firstMatch.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String != before }, object: nil)], timeout: 30), .completed)
                app.buttons["previousPage"].firstMatch.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String == "0" }, object: nil)], timeout: 30), .completed)
            }
            let originalPosition = position.value as? String
            XCTAssertEqual(originalPosition, "0")
            print("EDITOR_READER_POSITION caret=\(caretPosition ?? "missing") initial=\(originalPosition ?? "missing")")
            timed("reader-three-forward-three-back") {
                for _ in 0..<3 {
                    let before = position.value as? String
                    app.buttons["nextPage"].firstMatch.tap()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String != before }, object: nil)], timeout: 30), .completed)
                    print("EDITOR_READER_POSITION forward=\(position.value as? String ?? "missing")")
                }
                for _ in 0..<3 {
                    let before = position.value as? String
                    app.buttons["previousPage"].firstMatch.tap()
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String != before }, object: nil)], timeout: 30), .completed)
                    print("EDITOR_READER_POSITION back=\(position.value as? String ?? "missing")")
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.value as? String == "ready" && position.value as? String == originalPosition }, object: nil)], timeout: 30), .completed)
            }
            print("EDITOR_LARGE_CONTINUITY position=\(originalPosition ?? "missing") undoGroups=\(undoCount)")
            snapshot(app, "Large-TXT-Undo-Wrapping-Column-Reader-Continuity")
        }
        // 运行器结束后立即归档当前容器 tmp/editor-performance.log，下一次 launch 会清空该日志。
        #endif
    }
    func testLargeGeneratedTXTLoadsAndPagesWithoutExpandingWholeBook() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--large-file-ui-testing", "--synthetic-large-ui-testing", "--system-speech-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["book-大文件分页测试"].waitForExistence(timeout: 25)); openBook("大文件分页测试", app: app)
        let number = app.staticTexts["pageNumber"]; XCTAssertTrue(number.waitForExistence(timeout: 15))
        let first = app.staticTexts["readingPosition"].value as? String
        for _ in 0..<3 { app.buttons["nextPage"].press(); XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed) }
        XCTAssertNotEqual(app.staticTexts["readingPosition"].value as? String, first)
        for _ in 0..<3 { app.buttons["previousPage"].press(); XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed) }
        XCTAssertEqual(app.staticTexts["readingPosition"].value as? String, first)
        snapshot(app, "Five-Million-Characters-Bounded-Reader")
    }
    func testWritingImmediatelySwitchesToReaderAndReopens() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15)); app.buttons["newBook"].press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.press(); editor.typeText("刚写好的中文正文。\n\n第二段也必须显示，含有 emoji😀。")
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '刚写好的中文正文'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["文稿还没有正文，点击编辑开始写作。"].exists)
        snapshot(app, "New-Text-Immediately-Readable")
        app.buttons["modeToggle"].press(); XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertTrue((editor.value as? String ?? "").contains("第二段也必须显示"))
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '刚写好的中文正文'")).firstMatch.waitForExistence(timeout: 15))
    }
    #if os(macOS)
    func testOpenEditorImmediatelyAppliesThemeChanges() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]
        launch(app)
        openBook("编辑功能测试", app: app)
        app.buttons["modeToggle"].press()
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let original = editor.value as? String
        // 检查原生文本框实际像素，不能只检查主题菜单或外层 SwiftUI 的状态。
        let themes: [(String, [CGFloat])] = [
            ("dark", [0.055, 0.075, 0.095]), ("warm", [0.95, 0.90, 0.78]),
            ("green", [0.85, 0.91, 0.84]), ("white", [0.99, 0.987, 0.975])
        ]
        for (theme, expected) in themes {
            themeOption(theme, app: app).press()
            editor.press() // 关闭外观浮层，下一轮重新打开同一个主题面板。
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let bitmap = NSBitmapImageRep(data: editor.screenshot().pngRepresentation),
                      let color = bitmap.colorAt(x: bitmap.pixelsWide * 4 / 5, y: bitmap.pixelsHigh * 4 / 5)?.usingColorSpace(.sRGB) else { return false }
                // 屏幕截图经过显示器色彩转换，保留容差但仍区分四种纸面。
                return zip([color.redComponent, color.greenComponent, color.blueComponent], expected)
                    .allSatisfy { abs($0 - $1) < 0.065 }
            }, object: editor)
            XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 10), .completed, "Editor paper must immediately use \(theme)")
            XCTAssertEqual(editor.value as? String, original)
        }
    }
    #endif

    func testEditorSearchReplaceSharedThemesAndReadonly() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["book-编辑功能测试"].waitForExistence(timeout: 15)); openBook("编辑功能测试", app: app)
        app.buttons["outlineButton"].press()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["replacementField"].exists)
        XCTAssertFalse(app.buttons["addBookmark"].exists)
        snapshot(app, "ReadOnly-Search-Without-Replace")
        app.buttons["完成"].firstMatch.press()
        themeOption("warm", app: app).press()
        app.buttons["modeToggle"].press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 10))
        snapshot(app, "Warm-Editor-Shared-Theme")
        app.buttons["outlineButton"].press()
        app.descendants(matching: .any)["替换"].firstMatch.press()
        let find = app.textFields["searchField"]; find.press(); find.typeText("alpha")
        let replacement = app.textFields["replacementField"]; XCTAssertTrue(replacement.waitForExistence(timeout: 10)); replacement.press(); replacement.typeText("beta")
        XCTAssertEqual(find.value as? String, "alpha"); XCTAssertEqual(replacement.value as? String, "beta")
        app.buttons["replaceAll"].press()
        let changed = app.staticTexts["replaceEvidence"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ((changed.value as? String ?? "") + changed.label).contains("beta33") }, object: changed)], timeout: 15), .completed)
        snapshot(app, "Warm-Search-Replace-Three-Lines")
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue((editor.value as? String ?? "").contains("beta11"))
        #if os(macOS)
        editor.press(); editor.typeKey("z", modifierFlags: .command)
        XCTAssertTrue((editor.value as? String ?? "").contains("alpha11"), "All replacements must undo atomically")
        #endif
        app.buttons["modeToggle"].press()
        XCTAssertEqual(app.descendants(matching: .any)["appearanceMenu"].firstMatch.value as? String, "warm")
        let cache = documentAction("cacheManager", app: app)
        XCTAssertTrue(cache.waitForExistence(timeout: 10)); cache.press()
        XCTAssertTrue(app.buttons["clearAudioCache"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["deleteSelectedBookmarks"].exists)
        snapshot(app, "Cache-And-Bookmark-Manager")
        app.buttons["完成"].firstMatch.press()
    }
    #if os(macOS)
    func testAudioCacheCleanupAlsoDeletesRemovedDrafts() throws { try checkRemovedDraftCleanup(button: "clearAudioCache") }
    func testSnapshotCacheCleanupAlsoDeletesRemovedDrafts() throws { try checkRemovedDraftCleanup(button: "clearSnapshotCache") }
    func testTemporaryExportCleanupAlsoDeletesRemovedDrafts() throws { try checkRemovedDraftCleanup(button: "clearTemporaryExports") }

    private func checkRemovedDraftCleanup(button: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing", "--removed-draft-cache-ui-testing"]
        launch(app)
        if !app.buttons["book-编辑功能测试"].firstMatch.exists, app.buttons["toggleChapterSidebar"].firstMatch.exists { app.buttons["toggleChapterSidebar"].firstMatch.press() }
        XCTAssertTrue(app.buttons["book-编辑功能测试"].waitForExistence(timeout: 15))
        openBook("编辑功能测试", app: app)
        // Multi-document mode retains the startup document; explicitly close it before testing abandoned-draft cleanup.
        let previousTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "历史甲.txt")).firstMatch
        if previousTab.exists {
            app.buttons[previousTab.identifier.replacingOccurrences(of: "documentTab-", with: "closeTab-")].firstMatch.press()
            if app.buttons["closeSaveNo"].firstMatch.waitForExistence(timeout: 2) { app.buttons["closeSaveNo"].firstMatch.press() }
            XCTAssertTrue(previousTab.waitForNonExistence(timeout: 10))
        }
        for title in ["历史甲", "编辑功能测试"] {
            let row = app.buttons["book-" + title].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.rightClick()
            app.menuItems["移除历史记录"].firstMatch.press()
            XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        }
        app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["Ink Engine", "墨语引擎"])).firstMatch.press()
        app.menuItems["缓存管理"].firstMatch.press()
        let clear = app.buttons[button]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        let audio = app.staticTexts["audioCacheSize"]
        let populated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '4096'"), object: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [populated], timeout: 10), .completed)
        clear.press()
        let result = app.staticTexts["cacheCleanupResult"]
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "已永久删除 1 份已移出历史的草稿"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 15), .completed, app.debugDescription)
        let emptyAudio = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: audio)
        XCTAssertEqual(XCTWaiter.wait(for: [emptyAudio], timeout: 10), .completed, "Every cache action must also remove the deleted draft's audio")
        app.popUpButtons["cacheScope"].press()
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "Cache-Scope-After-Cleanup"; tree.lifetime = .keepAlways; add(tree)
        snapshot(app, "Cache-Scope-After-Cleanup")
        XCTAssertFalse(app.menuItems["历史甲.txt"].exists)
        XCTAssertTrue(app.menuItems["编辑功能测试.txt"].exists, "The open draft must survive even after its history entry is removed")
        XCTAssertTrue(app.menuItems["历史乙.txt"].exists, "Drafts still in History must survive")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        snapshot(app, "Removed-Draft-" + button)
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue((app.descendants(matching: .any)["currentMode"].firstMatch.value as? String ?? "").hasPrefix("编辑功能测试."))
    }
    #endif
    func testOpenSourceTimeoutRecoveryAndLightweightPCM() throws {
        try checkTimeoutRecoveryAndRestart(flags: ["--light-speech-ui-testing"])
    }
    func testPiperTimeoutRecoveryKeepsPCMOnRestart() throws { try XCTSkipIf(true, "Piper voice retired") }
    private func checkTimeoutRecoveryAndRestart(flags: [String]) throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", "--speech-stall-testing"] + flags; launch(app)
        XCTAssertTrue(app.buttons["book-长篇甲"].waitForExistence(timeout: 15)); openBook("长篇甲", app: app)
        let play = app.buttons["playPause"]; play.press()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = (play.value as? String ?? "").components(separatedBy: "|")
            return parts.count > 16 && parts[15] == "system" && parts[16] == "true" && (Int64(parts[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 40), .completed)
        snapshot(app, "OpenSource-Timeout-Recovered-Actual-PCM")
        play.press(); let frozen = play.value as? String
        RunLoop.current.run(until: Date().addingTimeInterval(0.6)); XCTAssertEqual(play.value as? String, frozen)
        let saved = (frozen ?? "").components(separatedBy: "|")
        XCTAssertGreaterThan(saved.count, 16)
        app.terminate(); app.launchArguments = ["--ui-testing"] + flags; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        let resumedPlay = app.buttons["playPause"]; XCTAssertTrue(resumedPlay.waitForExistence(timeout: 10)); resumedPlay.press()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let fields = (resumedPlay.value as? String ?? "").components(separatedBy: "|")
            return fields.count > 16 && fields[15] == "system" && fields[16] == "true" && fields[11] == "true" && fields[7] == saved[8] && (Int64(fields[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 30), .completed, "Rescue audio must resume the original PCM sample after restart")
        snapshot(app, "Timeout-Rescue-Original-PCM-After-Restart")
        app.buttons["stopSpeech"].press()
    }
    func testUnsupportedPiperTextFallsBackFromSameSourceChunk() throws {
        try XCTSkipIf(true, "Piper voice retired")
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--unrecognized-speech-ui-testing", "--male-speech-ui-testing"]; launch(app)
        openBook("校稿测试", app: app)
        let play = app.buttons["playPause"]; play.press()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let fields = (play.value as? String ?? "").components(separatedBy: "|")
            return fields.count > 16 && fields[15] == "system" && fields[16] == "true" && (Int64(fields[2]) ?? 0) > 4800 && fields[3] == "0" && fields[4] == "0"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 30), .completed, "Unsupported text must recover from the original first chunk, never advance past it")
        snapshot(app, "Unknown-Character-And-English-Recovered-From-Same-Chunk")
        app.buttons["stopSpeech"].press()
    }
    func testMatchaMissingWordTXTUsesFullRateWaveform() throws { try XCTSkipIf(true, "Matcha removed pending upstream 2.0"); try checkMatchaMissingWord(markdown: false) }
    func testLongPauseReleasesModelAndResumesRetainedPCM() throws { try XCTSkipIf(true, "Matcha removed pending upstream 2.0");
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--matcha-missing-word-ui-testing", "--light-speech-ui-testing"]
        launch(app); openBook("校稿测试", app: app)
        let play = app.buttons["playPause"]
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        play.press()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return e.count > 19 && e[15] == "matcha" && (Int64(e[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 30), .completed)
        play.press(); let frozen = evidence()
        XCTAssertEqual(frozen[18], "false", "A paused reader must stop its position timer")
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return e.count > 19 && (Int(e[19]) ?? 0) > (Int(frozen[19]) ?? 0)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 35), .completed)
        XCTAssertEqual(evidence()[2], frozen[2]); XCTAssertEqual(evidence()[1], frozen[1])
        play.press()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return (Int64(e[2]) ?? 0) > (Int64(frozen[2]) ?? 0) + 2400 && e[18] == "true"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed)
        XCTAssertEqual(evidence()[1], frozen[1]); XCTAssertEqual(evidence()[6], "0")
        app.buttons["stopSpeech"].press()
    }
    func testMatchaMissingWordMarkdownUsesFullRateWaveform() throws { try XCTSkipIf(true, "Matcha removed pending upstream 2.0"); try checkMatchaMissingWord(markdown: true) }
    private func checkMatchaMissingWord(markdown: Bool) throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--matcha-missing-word-ui-testing", "--light-speech-ui-testing"] + (markdown ? ["--missing-word-markdown"] : []); launch(app)
        openBook("校稿测试", app: app)
        let play = app.buttons["playPause"]; play.press()
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        let heard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return e.count > 17 && e[15] == "matcha" && e[17] == "1.0" && (Int64(e[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [heard], timeout: 30), .completed)
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.25"].press(); app.buttons["closeSpeechSpeed"].press()
        let e = evidence(); XCTAssertEqual(e[13], "1.25"); XCTAssertEqual(e[14], "1.25"); XCTAssertEqual(e[17], "1.0")
        play.press(); let frozen = evidence(); XCTAssertEqual(frozen[5], "paused")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)); XCTAssertEqual(evidence()[2], frozen[2])
        play.press()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (Int64(evidence()[2]) ?? 0) > (Int64(frozen[2]) ?? 0) + 2400 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
        XCTAssertEqual(evidence()[6], "0")
        snapshot(app, markdown ? "Matcha-Full-Waveform-Missing-Word-Markdown" : "Matcha-Full-Waveform-Missing-Word-TXT")
        app.buttons["stopSpeech"].press()
    }
    func testMatchaActualPCMPauseSeekAndResume() throws { try XCTSkipIf(true, "Matcha removed pending upstream 2.0");
        try checkOfflinePCMPauseSeekAndResume(renderer: "matcha", flag: "--light-speech-ui-testing")
    }
    func testPiperMaleActualPCMPauseSeekAndResume() throws { try XCTSkipIf(true, "Piper voice retired") }
    func testZipVoiceCoreMLActualPCMPauseSeekAndResume() throws {
        try checkOfflinePCMPauseSeekAndResume(renderer: "zipvoice", flag: "--zipvoice-ui-testing")
    }
    func testZipVoiceModelAndVoiceSelectionRemainSeparate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing", "--zipvoice-ui-testing"]
        launch(app); openBook("校稿测试", app: app)
        documentAction("speechSettings", app: app).press()
        let voice = app.descendants(matching: .any)["zipVoicePicker"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 10)); voice.press()
        XCTAssertTrue(app.buttons["Serena · 温柔女声"].firstMatch.exists, "ZipVoice female must remain available")
        app.buttons["Dylan · 京腔男声"].firstMatch.press()
        XCTAssertTrue(app.staticTexts["selectedVoice"].label.contains("Dylan"))
        app.descendants(matching: .any)["speechRendererPicker"].firstMatch.press()
        app.buttons["speechModel-system"].firstMatch.press()
        XCTAssertFalse(voice.exists)
        app.descendants(matching: .any)["speechRendererPicker"].firstMatch.press()
        app.buttons["ZipVoice"].firstMatch.press()
        XCTAssertTrue(voice.exists)
        XCTAssertTrue(app.staticTexts["selectedVoice"].label.contains("Dylan"), "Returning to a model must retain its selected voice")
        voice.press(); app.buttons["Serena · 温柔女声"].firstMatch.press()
        XCTAssertTrue(app.staticTexts["selectedVoice"].label.contains("Serena"), "Restored female voice must be selectable")
        snapshot(app, "ZipVoice-Model-And-Voice-Pickers")
    }
    private func checkOfflinePCMPauseSeekAndResume(renderer: String, flag: String) throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", flag]; launch(app)
        XCTAssertTrue(app.buttons["book-长篇甲"].waitForExistence(timeout: 15)); openBook("长篇甲", app: app)
        let play = app.buttons["playPause"]; play.press()
        XCTAssertTrue(app.buttons["speechSpeed"].waitForExistence(timeout: 15))
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.25"].press(); app.buttons["closeSpeechSpeed"].press()
        func evidence() -> [String] { (app.buttons["playPause"].firstMatch.value as? String ?? "").components(separatedBy: "|") }
        let audible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = evidence(); return parts.count > 16 && parts[15] == renderer && parts[16] == "false" && (Int64(parts[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [audible], timeout: renderer.hasPrefix("zipvoice") || renderer == "qwen" ? 90 : 30), .completed)
        XCTAssertEqual(evidence()[17], renderer == "piper" ? "1.25" : "1.0", "Native model narration must retain complete syllables")
        XCTAssertEqual(evidence()[14], renderer == "piper" ? "1.0" : "1.25", "The playback multiplier must compensate for this backend’s native rate")
        let generation = evidence()[1]
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.50"].press(); app.buttons["closeSpeechSpeed"].press()
        XCTAssertEqual(evidence()[1], generation, "Live rate changes must retain already generated PCM")
        if renderer == "piper" {
            let adopted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let parts = evidence(); return parts.count > 17 && parts[17] == "1.5" && parts[5] == "playing"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [adopted], timeout: 45), .completed, "Newly generated faster audio must replace the older lookahead without restarting")
            XCTAssertEqual(evidence()[1], generation); XCTAssertEqual(evidence()[6], "0")
        }
        assertEffectiveRate(evidence(), expected: 1.5)
        play.press(); let frozen = play.value as? String
        RunLoop.current.run(until: Date().addingTimeInterval(0.6)); XCTAssertEqual(play.value as? String, frozen)
        let oldGeneration = evidence()[1], oldSegment = evidence()[3]
        app.buttons["下一段"].press()
        XCTAssertNotEqual(evidence()[1], oldGeneration); XCTAssertNotEqual(evidence()[3], oldSegment); XCTAssertEqual(evidence()[5], "paused")
        play.press()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = evidence(); return parts.count > 16 && parts[15] == renderer && parts[5] == "playing" && (Int64(parts[2]) ?? 0) > 4800
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 30), .completed)
        XCTAssertEqual(evidence()[17], renderer == "piper" ? "1.5" : "1.0")
        XCTAssertEqual(evidence()[14], renderer == "piper" ? "1.0" : "1.5")
        play.press(); let checkpoint = evidence()
        print("Native-rate checkpoint: \(checkpoint)")
        print("Native-rate checkpoint UI: position=\(app.staticTexts["readingPosition"].firstMatch.value ?? "nil") tabs=\(app.staticTexts["workspaceTabNames"].firstMatch.value ?? "nil") frame=\(play.frame)")
        // 阅读位置按延迟写入合并保存；等待落盘后再模拟进程退出，不把强杀当作正常退出。
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.terminate(); app.launchArguments = ["--ui-testing", flag]; launch(app)
        if app.buttons["selectedMode"].firstMatch.label == "编辑" { app.buttons["modeToggle"].firstMatch.press() }
        let restoredPlay = app.buttons["playPause"].firstMatch
        print("Native-rate before restore click: \(evidence()) position=\(app.staticTexts["readingPosition"].firstMatch.value ?? "nil") tabs=\(app.staticTexts["workspaceTabNames"].firstMatch.value ?? "nil") mode=\(app.buttons["selectedMode"].firstMatch.label) frame=\(restoredPlay.frame)")
        let restoreTree = XCTAttachment(string: app.debugDescription); restoreTree.name = "Native-Rate-Before-Restore"; restoreTree.lifetime = .keepAlways; add(restoreTree)
        restoredPlay.press()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = evidence(); return parts.count > 17 && parts[7] == checkpoint[8] && parts[11] == "true" && (Int64(parts[2]) ?? 0) > 2400
        }, object: nil)
        let restoredResult = XCTWaiter.wait(for: [restored], timeout: 30)
        print("Native-rate restored: \(evidence())")
        XCTAssertEqual(restoredResult, .completed, "Native-rate PCM must resume its exact saved sample after restart")
        XCTAssertEqual(evidence()[17], renderer == "piper" ? "1.5" : "1.0"); assertEffectiveRate(evidence(), expected: 1.5)
        snapshot(app, renderer + "-Native-Rate-PCM-Restored"); app.buttons["stopSpeech"].press()
    }
    private func assertEffectiveRate(_ evidence: [String], expected: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(evidence.count, 17, file: file, line: line)
        guard evidence.count > 17, let effect = Float(evidence[14]), let native = Float(evidence[17]) else { return }
        XCTAssertEqual(effect * native, expected, accuracy: 0.001, "Native synthesis and playback correction must apply the selected rate exactly once", file: file, line: line)
    }
    #if os(macOS)
    func testMacOriginalFileLiveReloadAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--source-watch-ui-testing"]
        launch(app); openBook("原文件测试", app: app)
        if !app.textViews["manuscriptEditor"].exists { app.buttons["modeToggle"].press() }
        XCTAssertFalse(app.buttons["localDocuments"].exists)
        let path = app.staticTexts["testSourcePath"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        let editor = app.textViews["manuscriptEditor"]
        app.buttons["测试外部修改"].press()
        let updated = NSPredicate { _, _ in (editor.value as? String) == "External replacement" }
        expectation(for: updated, evaluatedWith: editor); waitForExpectations(timeout: 10)
        editor.press(); app.typeKey("a", modifierFlags: .command); app.typeText("Saved by editor")
        app.typeKey("s", modifierFlags: .command)
        app.buttons["读取磁盘内容"].press()
        let saved = NSPredicate { _, _ in (app.staticTexts["testDiskContent"].value as? String) == "Saved by editor" }
        expectation(for: saved, evaluatedWith: editor); waitForExpectations(timeout: 10)
        XCTAssertFalse(app.descendants(matching: .any)["sourceConflict"].exists)
    }

    func testMacExternalConflictPreservesEditorAndReloadRequiresConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--source-watch-ui-testing", "--manual-save-ui-testing"]
        launch(app); openBook("原文件测试", app: app)
        if !app.textViews["manuscriptEditor"].exists { app.buttons["modeToggle"].press() }
        let editor = app.textViews["manuscriptEditor"]
        editor.press(); app.typeKey("a", modifierFlags: .command); app.typeText("Unsaved local edits")
        app.buttons["测试外部冲突"].press()
        XCTAssertTrue(app.buttons["重新载入…"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Unsaved local edits")
        XCTAssertEqual(app.staticTexts["testDiskContent"].value as? String, "External conflict")
        app.buttons["重新载入…"].press()
        XCTAssertTrue(app.windows.buttons["放弃当前修改并载入"].waitForExistence(timeout: 5))
        app.windows.buttons["取消"].press()
        XCTAssertEqual(editor.value as? String, "Unsaved local edits")
        app.buttons["重新载入…"].press(); app.windows.buttons["放弃当前修改并载入"].press()
        let updated = NSPredicate { _, _ in (editor.value as? String) == "External conflict" }
        expectation(for: updated, evaluatedWith: editor); waitForExpectations(timeout: 10)
    }

    func testHTMLPreviewUsesDefaultBrowserAndSavedSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--html-preview-ui-testing"]
        launch(app); openBook("HTML预览测试", app: app)
        if !app.textViews["manuscriptEditor"].exists { app.buttons["modeToggle"].press() }
        let preview = app.buttons["previewHTML"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let editor = app.textViews["manuscriptEditor"]
        editor.press(); app.typeKey("a", modifierFlags: .command)
        let previewText = "Preview " + UUID().uuidString
        app.typeText("<!doctype html><link href=\"style.css\"><p>" + previewText + "</p>")
        preview.press()
        let browserURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!))
        let browserID = try XCTUnwrap(Bundle(url: browserURL)?.bundleIdentifier)
        let browser = XCUIApplication(bundleIdentifier: browserID); browser.activate()
        XCTAssertTrue(browser.staticTexts[previewText].firstMatch.waitForExistence(timeout: 15))
        app.activate(); openBook("无原文件HTML", app: app)
        if !app.textViews["manuscriptEditor"].exists { app.buttons["modeToggle"].press() }
        app.buttons["previewHTML"].press()
        browser.activate()
        XCTAssertTrue(browser.staticTexts["Application document"].firstMatch.waitForExistence(timeout: 15))
        app.activate(); openBook("普通文本", app: app)
        XCTAssertFalse(app.buttons["previewHTML"].exists)
    }
    func testColumnModeActuallyEditsMultipleRows() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["book-编辑功能测试"].waitForExistence(timeout: 15)); openBook("编辑功能测试", app: app)
        app.buttons["modeToggle"].press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 15))
        app.descendants(matching: .any)["documentMenu"].firstMatch.press(); app.menuItems["列模式"].firstMatch.press()
        editor.press(); app.typeKey("a", modifierFlags: .command); app.typeText("Q")
        XCTAssertEqual(editor.value as? String, "Q\nQ\nQ")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "alpha11\nalpha22\nalpha33")
        snapshot(app, "Column-Mode-Multirow-Edit-Undo")
    }
    /// 公开原生界面核对中英、全角标点与表情的列网格；截图用于人工对照标尺，不以离线字形数据代替可见验收。
    func testMacViewUpdateRuntimeWarningsDuringWorkspaceTransitions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let acceptance = root.appendingPathComponent("build.noindex/RuntimeWarningMac/Ink Engine Runtime Acceptance.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: acceptance.path))
        let app = XCUIApplication(url: acceptance)
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        app.launchEnvironment["NSUnbufferedIO"] = "YES"
        launch(app)
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 25))
        editor.press(); app.typeText("RuntimePreserved42" + String(repeating: "LongLine42", count: 30))
        let original = try XCTUnwrap(editor.value as? String)
        func menu(_ name: String) {
            app.menuBarItems[name == "自动换行" ? "显示" : "编辑"].firstMatch.press()
            XCTAssertTrue(app.menuItems[name].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.menuItems[name].firstMatch.isHittable)
            XCTAssertGreaterThan(app.menuItems[name].firstMatch.frame.width, 0)
            app.menuItems[name].firstMatch.press()
        }
        for round in 1...3 {
            print("RUNTIME_ROUND_BEGIN \(round)")
            menu("列模式")
            let columnHint = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "跨行选择后同时编辑", "跨行选择后同时编辑")).firstMatch
            XCTAssertTrue(columnHint.waitForExistence(timeout: 5))
            menu("自动换行")
            XCTAssertTrue(columnHint.waitForNonExistence(timeout: 5))
            app.menuBarItems["显示"].firstMatch.press()
            print("RUNTIME_MAC_WRAP_MENU \(String(describing: app.menuItems["自动换行"].firstMatch.value))")
            snapshot(app, "Runtime-Mac-Wrapping-Menu-\(round)")
            app.typeKey(.escape, modifierFlags: [])
            app.menuBarItems["编辑"].firstMatch.press()
            print("RUNTIME_MAC_COLUMN_MENU \(String(describing: app.menuItems["列模式"].firstMatch.value))")
            snapshot(app, "Runtime-Mac-Column-Menu-\(round)")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertEqual(editor.value as? String, original)
            editor.press(); app.typeKey(.leftArrow, modifierFlags: [])
            let state = XCTAttachment(string: editor.debugDescription); state.name = "Runtime-Mac-Selection-\(round)"; state.lifetime = .keepAlways; add(state)
            app.buttons["modeToggle"].firstMatch.pressAtCenter()
            XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.waitForExistence(timeout: 15))
            app.buttons["modeToggle"].firstMatch.pressAtCenter()
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            for title in ["标签甲.txt", "标签乙.txt"] {
                let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", title)).firstMatch
                XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.pressAtCenter()
            }
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            XCTAssertEqual(editor.value as? String, original)
            snapshot(app, "Runtime-Mac-Transitions-Round-\(round)")
            print("RUNTIME_ROUND_END \(round)")
        }
    }
    func testMacColumnGridShowsCJKPunctuationAndRulerTogether() throws {
        // 此可视验收只启动独立身份副本，避免同 bundle ID 自动连接用户正在编辑的正式实例。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let acceptance = root.appendingPathComponent("build.noindex/MacColumnAcceptance/Ink Engine Column Acceptance.app")
        guard FileManager.default.fileExists(atPath: acceptance.path) else { throw XCTSkip("Requires isolated Mac column acceptance app") }
        let app = XCUIApplication(url: acceptance)
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]
        launch(app)
        // 从真实 UTF-8 文件加载，避免 XCTest 合成 emoji 输入附带的字体属性影响字形对照。
        let source = "0123456789012345678901234567890123456789\n中，。！：；（）【】ＡＢ😀天地玄黄\nAA中BB，CC。DD！EE：FF；GG（）HH\n甲乙\tAB\t丙丁\tCD\t😀"
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("InkEngineColumnGrid-" + UUID().uuidString + ".txt")
        try source.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        path.typeKey("a", modifierFlags: .command); path.typeText(fixture.path); path.typeKey(.return, modifierFlags: [])
        if path.exists { path.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(path.waitForNonExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        if !app.textViews["manuscriptEditor"].exists { app.buttons["modeToggle"].firstMatch.pressAtCenter() }
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (editor.value as? String) == source }, object: nil)], timeout: 15), .completed)
        func captureEmojiAttributes(_ stage: String) {
            // 仅查询验收副本的公开 AX 参数化属性；记录字体等属性，不改输入和文稿。
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "org.ailifelab.InkEngine.ColumnAcceptance").first?.processIdentifier else { return }
            let application = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            let focusResult = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
            guard focusResult == .success, let focused else { print("MAC_COLUMN_EMOJI_AX \(stage) focus=\(focusResult.rawValue)"); return }
            let nativeRange = (source as NSString).range(of: "😀")
            var range = CFRange(location: nativeRange.location, length: nativeRange.length)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return }
            var value: CFTypeRef?
            let result = AXUIElementCopyParameterizedAttributeValue(focused as! AXUIElement, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value)
            if result == .success, let attributes = value as? NSAttributedString, attributes.length > 0 {
                print("MAC_COLUMN_EMOJI_AX \(stage) attributes=\(attributes.attributes(at: 0, effectiveRange: nil))")
            } else { print("MAC_COLUMN_EMOJI_AX \(stage) result=\(result.rawValue)") }
        }
        captureEmojiAttributes("before")
        snapshot(app, "Mac-CJK-Punctuation-Before-Column-Grid")
        app.menuBarItems["编辑"].press()
        let column = app.menuItems["列模式"].firstMatch
        XCTAssertTrue(column.waitForExistence(timeout: 5)); column.press()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(editor.value as? String, source)
        captureEmojiAttributes("after")
        snapshot(app, "Mac-Column-CJK-Punctuation-Ruler")
        let ax = XCTAttachment(string: app.debugDescription)
        ax.name = "Mac-Column-CJK-Punctuation-Ruler-AX"; ax.lifetime = .keepAlways; add(ax)
        app.typeKey("a", modifierFlags: .command); app.typeText("Q")
        XCTAssertEqual(editor.value as? String, "Q\nQ\nQ\nQ")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, source)
        snapshot(app, "Mac-Column-CJK-Punctuation-Undo")
    }
    #endif
    func testHistoryFileShareAndManualSyncKeepCurrentEditor() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["book-编辑功能测试"].waitForExistence(timeout: 15)); openBook("编辑功能测试", app: app)
        let row = app.buttons["book-历史甲"]; XCTAssertTrue(row.waitForExistence(timeout: 10)); row.rightClick()
        XCTAssertTrue(app.menuItems["分享文件…"].exists); XCTAssertTrue(app.menuItems["同步数据到设备…"].exists)
        app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH 'syncHistory-'")).firstMatch.press()
        XCTAssertTrue(app.staticTexts["历史甲.txt"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["performSync"].exists, "发现和选择文件不能直接发送")
        snapshot(app, "历史文件-手动同步选择设备")
        app.buttons["完成"].firstMatch.press()
        XCTAssertTrue((app.descendants(matching: .any)["currentMode"].firstMatch.value as? String ?? "").hasPrefix("编辑功能测试."))
        app.descendants(matching: .any)["documentMenu"].firstMatch.press()
        XCTAssertTrue(app.menuItems["saveAs"].exists); XCTAssertFalse(app.menuItems["exportDocument"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
    #if os(macOS)
    func testMacReopeningRemovedFileHistoryKeepsExistingSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--tabs-ui-testing"]
        launch(app)
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20)); tab.press()
        let originalTabID = tab.identifier
        tab.rightClick(); app.menuItems["复制到剪贴板"].firstMatch.hover(); app.menuItems["复制完整路径"].firstMatch.press()
        let path = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(path.hasSuffix("标签乙.txt"))
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("HistorySessionStillOpen42")
        let row = app.buttons["book-标签乙"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.rightClick(); app.menuItems["移除历史记录"].firstMatch.press()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10))
        app.typeKey("o", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"].firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 10)); pathField.typeKey("a", modifierFlags: .command); pathField.typeText(path); pathField.typeKey(.return, modifierFlags: [])
        if pathField.exists { pathField.typeKey(.return, modifierFlags: []) }
        XCTAssertTrue(pathField.waitForNonExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(row.waitForExistence(timeout: 15)); XCTAssertTrue(app.buttons[originalTabID].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "标签乙.txt")).count, 1)
        XCTAssertTrue((editor.value as? String ?? "").contains("HistorySessionStillOpen42"))
        snapshot(app, "Mac-Removed-File-History-Reopened-Existing-Session")
    }
    func testMacRemovedFolderReimportAndIncrementalScanPreserveDraft() throws {
        let app = XCUIApplication()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryReopen-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("# 第一章\n\n原来的正文。".utf8).write(to: source.appendingPathComponent("第1章.md"))
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launchEnvironment["INK_IMPORT_FOLDER"] = source.path
        launch(app)
        func importSameFolder() {
            app.menuBarItems.matching(NSPredicate(format: "title IN %@", ["File", "文件", "檔案"])).firstMatch.press()
            app.menuItems["添加小说目录…"].firstMatch.press()
            let choose = app.buttons["选择目录"].firstMatch
            XCTAssertTrue(choose.waitForExistence(timeout: 10)); app.typeKey(.return, modifierFlags: [])
            let confirm = app.buttons["confirmNovelAlias"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.press()
        }
        importSameFolder()
        let folder = app.descendants(matching: .any)["novel-" + source.lastPathComponent].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
        let first = app.buttons["book-第1章"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let tab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "第1章.md")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let originalTabID = tab.identifier
        app.menuBarItems["阅读"].firstMatch.press(); app.menuItems["阅读书签…"].firstMatch.press()
        app.buttons["addBookmark"].firstMatch.press()
        let name = app.textFields["bookmarkNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.press(); name.typeKey("a", modifierFlags: .command); name.typeText("HistoryReopenBookmark")
        app.buttons["saveBookmark"].firstMatch.press()
        XCTAssertTrue(app.buttons["bookmark-HistoryReopenBookmark"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press()
        app.buttons["modeToggle"].firstMatch.press()
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press(); editor.typeText("UnsavedHistoryReopen42")
        folder.rightClick(); app.menuItems["移除历史记录"].firstMatch.press()
        XCTAssertTrue(folder.waitForNonExistence(timeout: 10))
        importSameFolder()
        XCTAssertTrue(folder.waitForExistence(timeout: 20)); XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[originalTabID].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'documentTab-' AND label == %@", "第1章.md")).count, 1)
        if !editor.exists { app.buttons["modeToggle"].firstMatch.press() }
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertTrue((editor.value as? String ?? "").contains("UnsavedHistoryReopen42"))
        app.buttons["modeToggle"].firstMatch.press()
        app.menuBarItems["阅读"].firstMatch.press(); app.menuItems["阅读书签…"].firstMatch.press()
        XCTAssertTrue(app.buttons["bookmark-HistoryReopenBookmark"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press()
        try Data("# 第二章\n\n新增的正文。".utf8).write(to: source.appendingPathComponent("第2章.md"))
        XCTAssertTrue(app.buttons["book-第2章"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons[originalTabID].exists)
        snapshot(app, "Mac-Removed-History-Reimport-New-Chapter")
    }
    #endif
    func testHistoryDirectoryOffersShareAndManualSync() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--novel-ui-testing"]; launch(app)
        let folder = app.descendants(matching: .any)["novel-连续朗读测试"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.rightClick()
        XCTAssertTrue(app.menuItems["分享目录…"].exists); XCTAssertTrue(app.menuItems["同步数据到设备…"].exists)
        app.menuItems.matching(NSPredicate(format: "identifier BEGINSWITH 'syncHistory-'")).firstMatch.press()
        XCTAssertTrue(app.staticTexts["连续朗读测试"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["performSync"].exists)
        snapshot(app, "历史目录-手动同步选择设备")
        app.buttons["完成"].firstMatch.press()
    }
    func testPinnedHistoryDragOrderAndRestart() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-history-ui-testing"]; launch(app)
        let a = app.buttons["book-历史甲"].firstMatch, b = app.buttons["book-历史乙"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 15)); XCTAssertTrue(b.exists)
        for element in [a, b] {
            #if os(macOS)
            element.rightClick(); app.menuItems["固定到顶部"].firstMatch.press()
            #else
            element.press(forDuration: 1); app.buttons["固定到顶部"].firstMatch.press()
            #endif
        }
        XCTAssertLessThan(a.frame.minY, b.frame.minY)
        #if os(macOS)
        // XCTest 与 Quartz 的屏幕原点并不总一致；读取原生 AX 坐标后持续发送拖动事件。
        guard CGPreflightPostEventAccess(), AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.ailifelab.InkEngine").first else {
            throw XCTSkip("测试进程没有原生鼠标或辅助功能权限；保留独立鼠标拖拽及重启验证记录。")
        }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, name as CFString, &value); return value
        }
        func find(_ element: AXUIElement, _ identifier: String, depth: Int = 0) -> AXUIElement? {
            guard depth < 45 else { return nil }
            if attribute(element, kAXIdentifierAttribute) as? String == identifier { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let match = find(child, identifier, depth: depth + 1) { return match }
            }
            return nil
        }
        func center(_ identifier: String) throws -> CGPoint {
            let element = try XCTUnwrap(find(application, identifier))
            let origin = try XCTUnwrap(attribute(element, kAXPositionAttribute)), dimensions = try XCTUnwrap(attribute(element, kAXSizeAttribute))
            var position = CGPoint.zero, size = CGSize.zero
            XCTAssertTrue(AXValueGetValue(origin as! AXValue, .cgPoint, &position))
            XCTAssertTrue(AXValueGetValue(dimensions as! AXValue, .cgSize, &size))
            return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        }
        let source = try center("pinDrag-历史乙"), target = try center("book-历史甲")
        func mouse(_ type: CGEventType, _ point: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap) }
        mouse(.leftMouseDown, source); RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        for step in 1...20 {
            let fraction = Double(step) / 20
            mouse(.leftMouseDragged, CGPoint(x: source.x + (target.x - source.x) * fraction, y: source.y + (target.y - source.y) * fraction))
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        mouse(.leftMouseUp, target)
        #else
        print("INK_PIN_AX source=\(app.images["pinDrag-历史乙"].frame) target=\(a.frame)")
        let source = app.images["pinDrag-历史乙"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        source.press(forDuration: 0.05, thenDragTo: target)
        #endif
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in b.exists && a.exists && b.frame.minY < a.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        #if os(iOS)
        // 同一条记录向下再向上拖，避免只验证“移到目标前”而漏掉反向排序。
        for upward in [false, true] {
            app.images["pinDrag-历史乙"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                a.exists && b.exists && (upward ? b.frame.minY < a.frame.minY : a.frame.minY < b.frame.minY)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 10), .completed)
        }
        #endif
        snapshot(app, "Pinned-History-Drag-Order")
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        XCTAssertTrue(a.waitForExistence(timeout: 15)); XCTAssertLessThan(b.frame.minY, a.frame.minY)
    }
    #if os(iOS)
    func testManualDeviceSyncConfirmationCanBeCancelled() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--paired-nearby-ui-testing"]; launch(app)
        libraryAction("newBook", app: app).press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.press(); editor.typeText("取消同步不会改动正文。")
        documentAction("syncDocument", app: app).press()
        XCTAssertTrue(app.buttons["confirmSyncSelection"].waitForExistence(timeout: 10)); app.buttons["confirmSyncSelection"].press()
        let confirm = app.buttons["确认同步"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); snapshot(app, "同步设备-明确确认或取消")
        app.buttons["取消"].firstMatch.press(); app.buttons["完成"].firstMatch.press()
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertEqual(editor.value as? String, "取消同步不会改动正文。")
    }
    func testMobileDirectoryShareAndManualSyncMenus() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--novel-ui-testing"]; launch(app)
        let folder = app.descendants(matching: .any)["novel-连续朗读测试"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.press(forDuration: 1.2)
        let share = app.buttons["分享目录…"]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.press()
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR label == '关闭' OR label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15)); snapshot(app, "历史目录-分享ZIP未发送"); close.press()
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.press(forDuration: 1.2)
        let sync = app.buttons["同步数据到设备…"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10)); sync.press()
        XCTAssertTrue(app.staticTexts["连续朗读测试"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["performSync"].exists)
        snapshot(app, "历史目录-等待手动选择设备"); app.buttons["完成"].firstMatch.press()
    }
    func testEmptyHistoryAndPortraitKeepFileEntrypoints() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--empty-history-ui-testing"]; launch(app)
        for id in ["newBook", "importBook", "importNovel", "nearbyDevices"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 15)); XCTAssertTrue(app.buttons[id].isHittable)
        }
        snapshot(app, "空历史记录-新建打开目录入口")
        app.buttons["newBook"].press()
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.typeText("入口测试正文。")
        for mode in 0..<2 {
            if mode == 1 { app.buttons["modeToggle"].press() }
            app.buttons["showChapterSidebar"].press()
            for id in ["newBook", "importBook", "importNovel"] { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons[id].isHittable) }
            app.buttons["importBook"].press()
            let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.press()
            XCTAssertTrue(app.buttons["returnToDocument"].waitForExistence(timeout: 10))
            snapshot(app, "已有文稿-竖屏历史入口-\(mode)")
            app.buttons["returnToDocument"].press()
        }
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '入口测试正文'")).firstMatch.exists)
    }
    #endif
    func testCreateAndRepeatedImportCancellation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        launch(app)
        let importer = app.buttons["importBook"]
        XCTAssertTrue(importer.waitForExistence(timeout: 15))
        for _ in 0..<2 {
            importer.press()
            #if os(macOS)
            let cancel = app.buttons["CancelButton"].exists ? app.buttons["CancelButton"] : app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
            #else
            let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
            #endif
            XCTAssertTrue(cancel.waitForExistence(timeout: 15)); cancel.press()
            XCTAssertTrue(importer.waitForExistence(timeout: 5))
        }
        app.buttons["newBook"].press()
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.typeText("新建中文 new-document-marker "); XCTAssertTrue((editor.value as? String ?? "").contains("新建中文 new-document-marker"), "New document must accept actual text")
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
        let menu = app.descendants(matching: .any)["documentMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "Opening the document must finish before invoking its actions")
        menu.press()
        #if os(macOS)
        XCTAssertFalse(app.menuItems["移到回收区"].exists)
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        #else
        XCTAssertFalse(app.buttons["移到回收区"].exists)
        app.tap()
        #endif
    }

    func testEditReadSpeakStopAndReopen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        launch(app)
        #if os(iOS)
        let sample = app.buttons["book-校稿测试"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15)); sample.press()
        #endif
        let mode = app.buttons["modeToggle"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        #if os(macOS)
        XCTAssertTrue(app.textViews["manuscriptEditor"].exists)
        mode.click()
        #endif
        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); play.press()
        XCTAssertTrue(app.buttons["暂停朗读"].waitForExistence(timeout: 10))
        #if os(macOS)
        app.menuBarItems["阅读"].press()
        XCTAssertTrue(app.menuItems["暂停朗读"].waitForExistence(timeout: 5), "The open menu must observe playback state")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        #endif
        play.press()
        XCTAssertTrue(app.buttons["开始朗读"].exists)
        #if os(macOS)
        app.menuBarItems["阅读"].press()
        XCTAssertTrue(app.menuItems["开始朗读"].waitForExistence(timeout: 5), "The open menu must observe pause state")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        #endif
        let position = app.staticTexts["readingPosition"]
        let pausedPosition = position.value as? String ?? position.label
        app.buttons["下一段"].press()
        XCTAssertNotEqual(position.value as? String ?? position.label, pausedPosition, "Paused navigation must move to the requested segment")
        play.press()
        XCTAssertTrue(app.buttons["暂停朗读"].exists)
        app.buttons["stopSpeech"].press()
        XCTAssertTrue(app.buttons["开始朗读"].exists)
        mode.press()
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.press()
        #if os(macOS)
        // Paste through the real editor without changing the user's active Chinese IME.
        // Preserve every clipboard item and restore immediately after insertion.
        let clipboard = NSPasteboard.general
        let previousItems = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        clipboard.clearContents(); clipboard.setString(" proofreading-marker-123 ", forType: .string)
        editor.typeKey("v", modifierFlags: [.command])
        clipboard.clearContents(); clipboard.writeObjects(previousItems)
        #else
        editor.typeText(" proofreading-marker-123 ")
        #endif
        XCTAssertTrue((editor.value as? String ?? "").contains("proofreading-marker-123"), "The edit must reach the real editor")
        mode.press()
        snapshot(app, "编辑后切回阅读")
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let snapshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); snapshot.lifetime = .keepAlways; add(snapshot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15)); app.buttons["book-校稿测试"].press()
        #else
        XCTAssertTrue(app.textViews["manuscriptEditor"].waitForExistence(timeout: 15))
        app.buttons["modeToggle"].press()
        #endif
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
        // 续读保留实际阅读位置，新增文字不一定就在重开后的当前页；从编辑器核对持久化。
        app.buttons["modeToggle"].press()
        let restoredEditor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(restoredEditor.waitForExistence(timeout: 10))
        XCTAssertTrue((restoredEditor.value as? String ?? "").contains("proofreading-marker-123"), "Saved edit must survive app restart")
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
    }
    // 测试库在标签变化和正式保存完成后自动采集原文件，界面不暴露调试按钮。
    private func waitForWorkspaceDiskEvidence(_ app: XCUIApplication) {
        let disk = app.staticTexts["workspaceDiskEvidence"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            disk.exists && (disk.value as? String ?? "").contains("=")
        }, object: nil)], timeout: 15), .completed)
        XCTAssertFalse(app.buttons["readWorkspaceOriginals"].exists)
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPaginatedReadingAndFullPaperThemes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]
        launch(app); openBook("长篇甲", app: app)
        XCTAssertTrue(app.staticTexts["pageNumber"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["wrapToggle"].exists)
        func waitPage() {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: app.staticTexts["pageNumber"])], timeout: 10), .completed)
        }
        waitPage()
        let first = app.staticTexts["pageNumber"].label
        let position = app.staticTexts["readingPosition"].value as? String
        app.buttons["nextPage"].press(); waitPage()
        XCTAssertNotEqual(app.staticTexts["pageNumber"].label, first)
        XCTAssertNotEqual(app.staticTexts["readingPosition"].value as? String, position)
        app.buttons["previousPage"].press(); waitPage()
        XCTAssertEqual(app.staticTexts["pageNumber"].label, first)
        #if os(iOS)
        let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
        let left = paper.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let right = paper.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: left)
        waitPage()
        XCTAssertNotEqual(app.staticTexts["pageNumber"].label, first)
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", first), object: app.staticTexts["pageNumber"])], timeout: 8), .completed)
        waitPage()
        #endif
        for theme in ["warm", "green", "dark", "white"] {
            themeOption(theme, app: app).press(); waitPage()
            XCTAssertEqual(app.staticTexts["pageNumber"].label, first)
            XCTAssertGreaterThanOrEqual(app.descendants(matching: .any)["syntaxMenu"].firstMatch.frame.minY, app.descendants(matching: .any)["readerPaper"].firstMatch.frame.maxY - 1)
            snapshot(app, "Paged-Reader-" + theme)
        }
        searchJump("第70段", app: app)
        XCTAssertNotEqual(app.staticTexts["pageNumber"].label, first)
        snapshot(app, "Paged-Reader-Search-70")
    }
    private func tapPageCorner(forward: Bool, app: XCUIApplication) {
        #if os(macOS)
        let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
        let point = paper.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.86 : 0.14, dy: 0.88))
        point.click()
        #else
        app.buttons[forward ? "pageTapNext" : "pageTapPrevious"].pressAtCenter()
        #endif
    }
    func testPageCornerTapsAndLineSpeechSeek() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("长篇甲", app: app)
        let number = app.staticTexts["pageNumber"]
        func ready() { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed) }
        XCTAssertTrue(number.waitForExistence(timeout: 15)); ready()
        XCTAssertTrue(app.buttons["readingLine-0"].label.contains("长篇甲"), "Verify the visible book before testing its page coordinates")
        #if os(iOS)
        XCTAssertEqual(app.buttons.matching(identifier: "showChapterSidebar").count, 1)
        XCTAssertFalse(app.buttons["Hide Sidebar"].exists); XCTAssertFalse(app.buttons["Show Sidebar"].exists)
        if app.windows.firstMatch.frame.width >= 1000 {
            let paper = app.descendants(matching: .any)["readerPaper"].firstMatch
            let originalWidth = paper.frame.width
            app.buttons["showChapterSidebar"].press()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in paper.frame.width > originalWidth + 50 }, object: nil)], timeout: 10), .completed)
            app.buttons["showChapterSidebar"].press(); ready()
        }
        #endif
        let first = number.label
        snapshot(app, "Reader-Corners-Before-Tap")
        tapPageCorner(forward: true, app: app); ready()
        XCTAssertNotEqual(number.label, first)
        tapPageCorner(forward: false, app: app); ready()
        XCTAssertEqual(number.label, first)
        let line = app.buttons["readingLine-1"]
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        let target = try XCTUnwrap(Int(line.value as? String ?? "")); XCTAssertGreaterThan(target, 0)
        line.pressAtCenter()
        let play = app.buttons["playPause"]
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = evidence(); return e.count > 6 && (Int64(e[2]) ?? 0) > 4800 }, object: nil)], timeout: 30), .completed)
        play.press()
        // The second wrapped line belongs to the same paragraph, but speech
        // must start at that visual line rather than replay its beginning.
        XCTAssertEqual(evidence()[3], "0"); XCTAssertEqual(evidence()[4], String(target))
        let generation = evidence()[1]
        let firstLine = app.buttons["readingLine-0"]
        let firstTarget = try XCTUnwrap(Int(firstLine.value as? String ?? ""))
        firstLine.pressAtCenter()
        XCTAssertEqual(evidence()[5], "paused"); XCTAssertEqual(evidence()[2], "0")
        XCTAssertNotEqual(evidence()[1], generation); XCTAssertEqual(evidence()[4], String(firstTarget))
        for theme in ["warm", "green", "dark", "white"] {
            themeOption(theme, app: app).press(); ready(); snapshot(app, "Reader-Keycap-" + theme)
        }
        app.buttons["stopSpeech"].press()
    }
    func testMarkdownTablesRenderPaginateAndSeekCells() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--markdown-table-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("表格测试", app: app)
        let number = app.staticTexts["pageNumber"]
        func ready() { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed) }
        XCTAssertTrue(number.waitForExistence(timeout: 15)); ready()
        XCTAssertFalse(app.buttons["previousPage"].isEnabled, "Markdown prefixes must not create a phantom previous page")
        for title in ["章节", "内容", "字数"] { XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists, title) }
        themeOption("warm", app: app).press(); ready(); snapshot(app, "Markdown-Table-Header")
        var chapters = Set<String>()
        for _ in 0..<20 {
            for cell in app.buttons.matching(NSPredicate(format: "label MATCHES %@", "第[0-9]+章")).allElementsBoundByIndex { chapters.insert(cell.label) }
            if !app.buttons["nextPage"].isEnabled { break }
            tapPageCorner(forward: true, app: app); ready()
        }
        XCTAssertEqual(chapters, Set((1...35).map { "第\($0)章" }), "Rows must not disappear at page boundaries")
        snapshot(app, "Markdown-Table-Last-Page")
        searchJump("第1章", app: app); ready()
        let cell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "山路")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        let source = try XCTUnwrap(Int(cell.value as? String ?? ""))
        cell.pressAtCenter()
        let play = app.buttons["playPause"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = (play.value as? String ?? "").components(separatedBy: "|"); return e.count > 2 && (Int64(e[2]) ?? 0) > 4800 }, object: nil)], timeout: 30), .completed)
        play.press()
        XCTAssertGreaterThanOrEqual(Int(app.staticTexts["readingPosition"].value as? String ?? "") ?? 0, source)
        snapshot(app, "Markdown-Table-Cell-Speech")
        app.buttons["stopSpeech"].press()
    }
    func testLongMarkdownTableCellContinuesAcrossPages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--markdown-long-row-ui-testing"]
        launch(app); openBook("跨页表格", app: app)
        let number = app.staticTexts["pageNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 15))
        var collected = "", positions = Set<String>()
        for _ in 0..<30 {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed)
            let position = number.label
            XCTAssertTrue(positions.insert(position).inserted, "Forward paging must advance inside a tall row")
            let labels = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readingLine-'"))
                .allElementsBoundByIndex.map(\.label)
            collected += labels.filter { !["章节", "长单元格", "字数", "长行", "2800", "下一行", "10"].contains($0) }.joined()
            if !app.buttons["nextPage"].isEnabled { break }
            tapPageCorner(forward: true, app: app)
        }
        XCTAssertGreaterThan(positions.count, 1)
        for index in 1...400 { XCTAssertTrue(collected.contains(String(format: "续写%04d，", index)), "Missing cell content \(index)") }
        XCTAssertTrue(collected.contains("跨页终点")); XCTAssertTrue(collected.contains("表格后续行"))
        XCTAssertTrue(collected.contains("表格结束后的正文。"))
        snapshot(app, "Markdown-Table-Tall-Row-End")
    }
    func testActualLargeTXTUsesBoundedPages() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--large-file-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("《深空彼岸》", app: app)
        let number = app.staticTexts["pageNumber"]
        XCTAssertTrue(number.waitForExistence(timeout: 20))
        let original = app.staticTexts["readingPosition"].value as? String
        for _ in 0..<3 {
            app.buttons["nextPage"].press()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed)
        }
        XCTAssertNotEqual(app.staticTexts["readingPosition"].value as? String, original)
        for _ in 0..<3 {
            app.buttons["previousPage"].press()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: number)], timeout: 10), .completed)
        }
        XCTAssertEqual(app.staticTexts["readingPosition"].value as? String, original)
        snapshot(app, "Actual-Large-TXT-Paged")
        let play = app.buttons["playPause"]
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return e.count > 14 && (Int64(e[2]) ?? 0) > 4800 && e[6] == "0"
        }, object: nil)], timeout: 30), .completed, "The actual full-size book must start rendering PCM")
        play.press(); let frozen = evidence()
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.25"].press(); app.buttons["closeSpeechSpeed"].press()
        XCTAssertEqual(evidence()[1], frozen[1]); XCTAssertEqual(evidence()[2], frozen[2])
        XCTAssertEqual(evidence()[14], "1.25")
        app.buttons["下一段"].press()
        XCTAssertEqual(evidence()[5], "paused")
        XCTAssertEqual(evidence()[2], "0")
        XCTAssertNotEqual(evidence()[1], frozen[1])
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let e = evidence(); return e.count > 14 && (Int64(e[2]) ?? 0) > 4800 && e[6] == "0" && e[14] == "1.25"
        }, object: nil)], timeout: 20), .completed)
        snapshot(app, "Actual-Large-TXT-System-Playback")
        app.buttons["stopSpeech"].press()
    }
    /// 跨模型切换必须丢弃上一音色的播放/救援缓存，并以真实请求和排队波形验证。
    func testSystemZipVoiceChangesRebuildActualPCMWithoutMovingCursor() throws {
        try exerciseSystemZipVoiceChanges()
    }
    func testZipVoiceMaleToFemaleRebuildsActualPCM() throws {
        try exerciseSystemZipVoiceChanges(genderOnly: true)
    }
    func testIPadLandscapeVoiceSettingsPreserveNonzeroReadingPosition() throws {
        try exerciseSystemZipVoiceChanges(genderOnly: true, landscape: true)
    }
    /// 原生系统窗口操作由公开设备工具完成，本例只读取实际播放证据并断言状态链。
    func testIPadNativeSystemWindowsVoiceObservation() throws {
        let app = XCUIApplication()
        XCTAssertNotEqual(app.state, .notRunning)
        app.activate()
        func evidence() -> [String]? {
            let play = app.buttons["playPause"].firstMatch
            guard play.exists else { return nil }
            let values = (play.value as? String ?? "").components(separatedBy: "|")
            return values.count > 22 ? values : nil
        }
        func wait(_ phase: String, _ predicate: @escaping ([String]) -> Bool) -> [String] {
            print("NATIVE_VOICE_WAIT \(phase)")
            var found: [String] = []
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let e = evidence(), predicate(e) else { return false }
                found = e; return true
            }, object: nil)], timeout: 180)
            XCTAssertEqual(result, .completed, "Native phase " + phase)
            print("NATIVE_VOICE_EVIDENCE \(phase) window=\(app.windows.firstMatch.frame) \(found.joined(separator: "|"))")
            snapshot(app, "Native-System-Window-" + phase)
            return found
        }
        func actual(_ e: [String], renderer: String, voice: String) -> Bool {
            e[5] == "playing" && e[15] == renderer && e[16] == "false" && (Int64(e[2]) ?? 0) > 4800 && e.last!.contains("synthesisVoice=" + voice + ";") && e.last!.contains("scheduledVoice=" + voice + ";")
        }
        for side in ["left", "right"] {
            print("NATIVE_SYSTEM_SIDE_READY \(side)")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.width >= 350 && frame.width <= 650 && (side == "left" ? frame.minX < 100 : frame.minX > 500)
            }, object: nil)], timeout: 180), .completed)
            _ = wait(side + "-male", { actual($0, renderer: "zipvoice-male", voice: "zipvoice-distill-coreml-4-dylan") })
            let paused = wait(side + "-paused", { $0[5] == "paused" })
            let cursor = Array(paused[3...4])
            XCTAssertTrue((Int(cursor[0]) ?? 0) > 0 || (Int(cursor[1]) ?? 0) > 0)
            let stopped = wait(side + "-selected-female", { $0[5] == "stopped" && $0.last!.contains("selectedRenderer=zipvoice;") && $0.last!.contains("queuedCount=0") })
            XCTAssertEqual(Array(stopped[3...4]), cursor)
            let female = wait(side + "-female", { actual($0, renderer: "zipvoice", voice: "zipvoice-distill-coreml-4") })
            XCTAssertGreaterThanOrEqual(Int(female[3]) ?? 0, Int(cursor[0]) ?? 0)
        }
    }
    /// 全程由公开 XCTest 建立真实系统双窗，布局稳定前不请求原生工具截图。
    func testIPadPairedVoiceWithoutNativeCapture() throws {
        try exerciseIPadPairedVoice(landscape: false)
    }
    func testIPadLandscapePairedVoiceWithoutNativeCapture() throws {
        try exerciseIPadPairedVoice(landscape: true)
    }
    private func exerciseIPadPairedVoice(landscape: Bool) throws {
        #if os(iOS)
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", "--system-speech-ui-testing", "--voice-selection-ui-testing"]
        app.launch(); openBook("长篇甲", app: app)
        app.buttons["nextPage"].firstMatch.pressAtCenter()
        app.buttons["nextPage"].firstMatch.pressAtCenter()
        let shell = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func tile(_ target: XCUIApplication, _ bundle: String, _ side: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in target.windows.firstMatch.exists && target.windows.firstMatch.frame.width > 350 }, object: nil)], timeout: 20), .completed)
            let frame = target.windows.firstMatch.frame
            print("SYSTEM_TILE_BEFORE bundle=\(bundle) frame=\(frame)")
            if frame.width > 650 {
                target.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: frame.maxX - 7, dy: frame.maxY - 9)).press(forDuration: 0.2, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 9)))
            }
            let controls = shell.buttons["window-controls:" + bundle].firstMatch
            XCTAssertTrue(controls.waitForExistence(timeout: 15))
            controls.press(forDuration: 0.8)
            let option = shell.buttons[side].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 10)); option.tap()
        }
        #if targetEnvironment(simulator)
        let acceptanceBundle = "org.ailifelab.InkEngine"
        #else
        let acceptanceBundle = "org.ailifelab.InkEngine.Acceptance.InkEngine"
        #endif
        tile(app, acceptanceBundle, "左")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate(); tile(settings, "com.apple.Preferences", "右")
        let left = app.windows.firstMatch.frame, right = settings.windows.firstMatch.frame
        XCTAssertLessThan(left.maxX, right.minX)
        XCTAssertGreaterThan(left.width, 350); XCTAssertGreaterThan(right.width, 350)
        print("ACTUAL_PAIRED_WINDOWS ink=\(left) settings=\(right)")
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); picture.name = "Actual-System-Paired-Stable"; picture.lifetime = .keepAlways; add(picture)
        try exerciseSystemZipVoiceChanges(genderOnly: true, landscape: landscape, attachedSide: "left", keepPlaying: true)
        func screenEvidence(_ name: String) {
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = name; capture.lifetime = .keepAlways; add(capture)
        }
        func evidence() -> [String] { (app.buttons["playPause"].firstMatch.value as? String ?? "").components(separatedBy: "|") }
        func focusRightAndReturn() {
            // 使用已观察的右窗标题坐标；不重新 activate 或点阅读行改变游标。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: right.midX - left.minX, dy: 54 - left.minY)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in settings.windows.firstMatch.frame.width > 350 && settings.windows.firstMatch.frame.minX > left.maxX }, object: nil)], timeout: 10), .completed)
            print("PAIRED_RIGHT_FOCUSED state=\(settings.state.rawValue) frame=\(settings.windows.firstMatch.frame)")
            screenEvidence("Paired-Right-Actually-Focused")
            let currentTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "documentTab-")).firstMatch
            XCTAssertTrue(currentTab.exists); currentTab.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width > 350 && app.windows.firstMatch.frame.minX < 100 }, object: nil)], timeout: 10), .completed)
        }
        screenEvidence("Paired-Serena-Actual-PCM-Full-Screen")
        let beforeFocus = evidence()
        XCTAssertGreaterThan(Int64(beforeFocus[2]) ?? 0, 4800)
        focusRightAndReturn()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = evidence()
            return current.count > 16 && current[1] == beforeFocus[1] && current[5] == "playing" && (Int64(current[2]) ?? 0) > (Int64(beforeFocus[2]) ?? 0) + 4800
        }, object: nil)], timeout: 20), .completed)
        let progressed = evidence()
        XCTAssertEqual(progressed[15], "zipvoice"); XCTAssertEqual(progressed[16], "false")
        print("PAIRED_PLAYING_FOCUS_BEFORE \(beforeFocus.joined(separator: "|"))")
        print("PAIRED_PLAYING_FOCUS_AFTER \(progressed.joined(separator: "|"))")
        app.buttons["toolbarSpeech"].firstMatch.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in evidence()[5] == "paused" }, object: nil)], timeout: 10), .completed)
        let pausedEvidence = evidence(), pausedCursor = Array(evidence()[3...4])
        let position = app.staticTexts["readingPosition"].firstMatch
        XCTAssertTrue(position.exists)
        let readingPosition = (position.value as? String) ?? position.label
        let pageLabel = app.staticTexts["pageNumber"].firstMatch.label
        XCTAssertGreaterThan(Int(readingPosition.filter(\.isNumber)) ?? 0, 0)
        print("PAIRED_READER_BEFORE position=\(readingPosition) page=\(pageLabel)")
        focusRightAndReturn()
        XCTAssertEqual((position.value as? String) ?? position.label, readingPosition)
        XCTAssertEqual(app.staticTexts["pageNumber"].firstMatch.label, pageLabel)
        print("PAIRED_READER_AFTER position=\((position.value as? String) ?? position.label) page=\(app.staticTexts["pageNumber"].firstMatch.label)")
        XCTAssertEqual(evidence()[5], "paused")
        XCTAssertEqual(Array(evidence()[3...4]), pausedCursor)
        XCTAssertEqual(evidence()[1], pausedEvidence[1])
        print("PAIRED_PAUSED_FOCUS_EXACT \(evidence().joined(separator: "|"))")
        screenEvidence("Paired-Paused-Cursor-Preserved-Full-Screen")
        app.terminate()
        #endif
    }
    func testIPadSystemLeftWindowVoiceSettingsPreservePosition() throws {
        try exerciseSystemZipVoiceChanges(genderOnly: true, landscape: true, attachedSide: "left")
    }
    func testIPadSystemRightWindowVoiceSettingsPreservePosition() throws {
        try exerciseSystemZipVoiceChanges(genderOnly: true, landscape: true, attachedSide: "right")
    }
    private func exerciseSystemZipVoiceChanges(genderOnly: Bool = false, landscape: Bool = false, attachedSide: String? = nil, keepPlaying: Bool = false) throws {
        #if os(iOS)
        if landscape { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { if landscape && attachedSide == nil { XCUIDevice.shared.orientation = .portrait } }
        #endif
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--line-tap-ui-testing", "--system-speech-ui-testing"]
        if let attachedSide {
            // 连接已在系统中平铺的隔离实例；不重新 launch/reset 破坏系统窗口位置。
            XCTAssertNotEqual(app.state, .notRunning)
            app.activate()
            print("IPAD_ATTACH_WINDOW_EXPECT_\(attachedSide.uppercased()) \(app.windows.firstMatch.frame)")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.width >= 350 && frame.width <= 650 && (attachedSide == "left" ? frame.minX < 100 : frame.minX > 500)
            }, object: nil)], timeout: 90), .completed)
            print("IPAD_SYSTEM_WINDOW_ACTUAL_\(attachedSide) \(app.windows.firstMatch.frame)")
            snapshot(app, "Ipad-System-Tile-" + attachedSide)
            let stop = app.buttons["stopSpeech"].firstMatch
            if stop.exists && stop.isHittable {
                stop.tap()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (app.buttons["playPause"].firstMatch.value as? String ?? "").contains("|stopped|") }, object: nil)], timeout: 10), .completed)
            }
        } else { launch(app); openBook("长篇甲", app: app) }
        if landscape && attachedSide == nil {
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(window.width, window.height)
            print("IPAD_SETTINGS_LANDSCAPE_WINDOW \(window)")
            XCTAssertTrue(app.staticTexts["pageNumber"].firstMatch.waitForExistence(timeout: 15))
            app.buttons["nextPage"].firstMatch.pressAtCenter()
            app.buttons["nextPage"].firstMatch.pressAtCenter()
            snapshot(app, "Ipad-Landscape-Nonzero-Reading")
        }
        func tapPlay() {
            let toolbar = app.buttons["toolbarSpeech"].firstMatch
            let button = toolbar.exists && toolbar.isHittable && app.windows.firstMatch.frame.contains(toolbar.frame) ? toolbar : app.buttons["playPause"].firstMatch
            print("VOICE_PLAY_TAP frame=\(button.frame) label=\(button.label) window=\(app.windows.firstMatch.frame)")
            button.tap()
        }
        func fields() -> [String] { (app.buttons["playPause"].firstMatch.value as? String ?? "").components(separatedBy: "|") }
        func diagnostic(_ name: String) -> String {
            fields().joined(separator: "|").components(separatedBy: "|").last?.components(separatedBy: ";").first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) } ?? "missing"
        }
        func wait(_ condition: @escaping ([String]) -> Bool, _ message: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(fields()) }, object: nil)], timeout: 100), .completed, message + " " + fields().joined(separator: "|"))
        }
        func settings() {
            #if os(iOS)
            let sidebarSettings = app.buttons.matching(NSPredicate(format: "label == %@", "设置与设备")).firstMatch
            if landscape || attachedSide != nil {
                if !sidebarSettings.exists || !sidebarSettings.isHittable { app.buttons["toggleChapterSidebar"].firstMatch.pressAtCenter() }
                XCTAssertTrue(sidebarSettings.waitForExistence(timeout: 10)); sidebarSettings.pressAtCenter()
                let entry = app.buttons["speechSettings"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10)); XCTAssertTrue(entry.isHittable); entry.pressAtCenter()
            } else {
            let speed = app.descendants(matching: .any)["speechSpeed"].firstMatch
            if speed.exists && speed.isHittable && speed.frame.width > 0 {
                speed.pressAtCenter()
                let entry = app.buttons["朗读设置"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.pressAtCenter()
            } else { chooseColumnTestMenu("字号与朗读设置", in: app) }
            }
            #else
            documentAction("speechSettings", app: app).press()
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["speechSettingsForm"].firstMatch.waitForExistence(timeout: 10))
        }
        func reveal(_ element: XCUIElement) {
            let form = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
            func viewport() -> CGRect {
                var rect = form.frame.intersection(app.windows.firstMatch.frame)
                let bar = app.navigationBars.firstMatch
                if bar.exists && bar.frame.intersects(rect) {
                    let top = max(rect.minY, bar.frame.maxY + 4)
                    rect = CGRect(x: rect.minX, y: top, width: rect.width, height: max(0, rect.maxY - top))
                }
                return rect.insetBy(dx: 1, dy: 4)
            }
            for _ in 0..<8 {
                let bounds = viewport()
                if element.exists && element.isHittable && element.frame.width > 0 && bounds.contains(element.frame) { return }
                if element.exists && element.frame.minY < bounds.minY { form.swipeDown() } else { form.swipeUp() }
            }
            XCTAssertTrue(element.exists && element.isHittable && viewport().contains(element.frame), "Actual settings row must be fully visible below the navigation bar")
        }
        func choose(model: String, voice: String? = nil) {
            settings()
            let header = app.descendants(matching: .any)["speechRendererPicker"].firstMatch
            reveal(header); header.pressAtCenter()
            let option = app.buttons["speechModel-" + model].firstMatch
            reveal(option); option.pressAtCenter()
            if let voice {
                let picker = app.descendants(matching: .any)["zipVoicePicker"].firstMatch
                reveal(picker); picker.pressAtCenter()
                let choice = app.buttons["zipVoice-" + voice].firstMatch
                reveal(choice)
                print("VOICE_VISIBLE_BEFORE_TAP id=\(choice.identifier) frame=\(choice.frame) form=\(app.descendants(matching: .any)["speechSettingsForm"].firstMatch.frame) nav=\(app.navigationBars.firstMatch.frame)")
                snapshot(app, "Visible-Voice-Before-Tap-" + voice)
                choice.pressAtCenter()
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in choice.isSelected }, object: nil)], timeout: 5), .completed, "Actual voice row must be selected")
            }
            snapshot(app, "Cross-Model-Choice-" + model + (voice ?? ""))
            app.buttons["完成"].firstMatch.pressAtCenter()
        }
        func audible(_ renderer: String) {
            wait({ e in e.count > 16 && e[5] == "playing" && e[15] == renderer && e[16] == "false" && (Int64(e[2]) ?? 0) > 4800 && diagnostic("synthesisRenderer") == renderer && diagnostic("scheduledVoice") == diagnostic("synthesisVoice") && diagnostic("scheduledVoice") != "none" }, "Actual requested and queued PCM must use " + renderer + "; fallback is not acceptance")
            print("CROSS_MODEL_ACTUAL_\(renderer) \(fields().joined(separator: "|"))")
        }
        if genderOnly {
            choose(model: "zipvoice", voice: "dylan")
            tapPlay(); audible("zipvoice-male")
            tapPlay(); wait({ $0[5] == "paused" }, "Pause male")
            let cursor = Array(fields()[3...4])
            if landscape || attachedSide != nil { XCTAssertTrue((Int(cursor[0]) ?? 0) > 0 || (Int(cursor[1]) ?? 0) > 0, "Reading must begin beyond the original first page") }
            print("VOICE_PAUSED_CURSOR \(cursor)")
            choose(model: "zipvoice", voice: "serena")
            XCTAssertEqual(fields()[5], "stopped"); XCTAssertEqual(Array(fields()[3...4]), cursor)
            tapPlay(); audible("zipvoice")
            snapshot(app, "ZipVoice-Male-To-Female-Actual-PCM")
            if !keepPlaying { app.buttons["stopSpeech"].firstMatch.pressAtCenter() }
            return
        }
        tapPlay(); audible("system")
        tapPlay(); wait({ $0[5] == "paused" }, "Pause initial system audio")
        let cursor = Array(fields()[3...4])
        choose(model: "zipvoice", voice: "serena")
        wait({ $0[5] == "stopped" && $0[16] == "false" && diagnostic("queuedCount") == "0" }, "Selection must cancel old PCM without autoplay")
        XCTAssertEqual(Array(fields()[3...4]), cursor)
        let generation = fields()[1], requestCount = diagnostic("synthesisRequests")
        choose(model: "zipvoice", voice: "serena")
        XCTAssertEqual(fields()[1], generation); XCTAssertEqual(diagnostic("synthesisRequests"), requestCount)
        tapPlay(); audible("zipvoice")
        // 正在播放时切回系统也采用明确停止语义，只有用户再次点击才合成。
        choose(model: "system")
        wait({ $0[5] == "stopped" && $0[16] == "false" && diagnostic("queuedCount") == "0" }, "Playing Zip to System must discard queue and not autoplay")
        tapPlay(); audible("system")
        app.buttons["stopSpeech"].firstMatch.pressAtCenter()
        let stoppedCursor = Array(fields()[3...4])
        choose(model: "zipvoice", voice: "dylan")
        XCTAssertEqual(fields()[5], "stopped"); XCTAssertEqual(Array(fields()[3...4]), stoppedCursor)
        tapPlay(); audible("zipvoice-male")
        tapPlay(); wait({ $0[5] == "paused" }, "Pause male")
        let maleCursor = Array(fields()[3...4])
        choose(model: "zipvoice", voice: "serena")
        XCTAssertEqual(fields()[5], "stopped"); XCTAssertEqual(Array(fields()[3...4]), maleCursor)
        tapPlay(); audible("zipvoice")
        snapshot(app, "Cross-Model-Final-Actual-PCM")
        app.buttons["stopSpeech"].firstMatch.pressAtCenter()
    }
    /// 验证已朗读过的音色切换会清理旧波形，实际合成和播放均采用新音色。
    func testSystemVoiceChangesInvalidatePreviouslyPlayedPCM() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("校稿测试", app: app)
        let play = app.buttons["playPause"].firstMatch
        func fields() -> [String] { (app.buttons["playPause"].firstMatch.value as? String ?? "").components(separatedBy: "|") }
        func wait(_ condition: @escaping ([String]) -> Bool, _ message: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(fields()) }, object: nil)], timeout: 40), .completed, message + " " + fields().joined(separator: "|"))
        }
        func settings() {
            #if os(iOS)
            let speed = app.descendants(matching: .any)["speechSpeed"].firstMatch
            if speed.exists && speed.isHittable && speed.frame.width > 0 {
                speed.pressAtCenter()
                let entry = app.buttons["朗读设置"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.pressAtCenter()
            } else { chooseColumnTestMenu("字号与朗读设置", in: app) }
            #else
            documentAction("speechSettings", app: app).press()
            #endif
            XCTAssertTrue(app.descendants(matching: .any)["speechSettingsForm"].firstMatch.waitForExistence(timeout: 10))
        }
        func reveal(_ element: XCUIElement) {
            let form = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
            for _ in 0..<6 { if element.exists && element.isHittable { return }; form.swipeUp() }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        func choose(_ id: String) {
            settings()
            let header = app.descendants(matching: .any)["systemMandarinVoicePicker"].firstMatch
            reveal(header); header.pressAtCenter()
            let voice = app.buttons[id].firstMatch
            reveal(voice); voice.pressAtCenter()
            snapshot(app, "Actual-System-Voice-Choice")
            app.buttons["完成"].firstMatch.pressAtCenter()
        }
        settings()
        let header = app.descendants(matching: .any)["systemMandarinVoicePicker"].firstMatch
        reveal(header); header.pressAtCenter()
        let ids = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'systemVoice-' ")).allElementsBoundByIndex.map(\.identifier)
        print("AVAILABLE_SYSTEM_VOICES \(ids)")
        guard ids.count >= 2 else { snapshot(app, "Insufficient-Actual-System-Voices"); app.buttons["完成"].firstMatch.pressAtCenter(); throw XCTSkip("Device has fewer than two real Mandarin system voices") }
        let a = ids[0], b = ids[1]
        reveal(app.buttons[a].firstMatch); app.buttons[a].firstMatch.pressAtCenter()
        app.buttons["完成"].firstMatch.pressAtCenter()
        let voiceA = String(a.dropFirst("systemVoice-".count)), voiceB = String(b.dropFirst("systemVoice-".count))
        func actual(_ id: String) -> Bool { fields().joined(separator: "|").contains("scheduledVoice=" + id) && fields().joined(separator: "|").contains("synthesisVoice=" + id) }
        play.pressAtCenter()
        wait({ $0.count > 16 && $0[5] == "playing" && (Int64($0[2]) ?? 0) > 4800 && actual(voiceA) }, "A must actually synthesize and schedule PCM")
        play.pressAtCenter(); wait({ $0[5] == "paused" }, "Pause A")
        let pausedCursor = Array(fields()[3...4])
        choose(b)
        wait({ $0[5] == "stopped" }, "Changing paused voice must not start playback")
        XCTAssertEqual(Array(fields()[3...4]), pausedCursor)
        let stoppedGeneration = fields()[1]
        choose(b)
        XCTAssertEqual(fields()[1], stoppedGeneration, "Selecting identical voice must not reset transport")
        play.pressAtCenter()
        wait({ $0[5] == "playing" && (Int64($0[2]) ?? 0) > 4800 && actual(voiceB) }, "Paused A to B must use new actual PCM")
        choose(a)
        wait({ $0[5] == "stopped" }, "Changing playing voice uses explicit stop semantics")
        play.pressAtCenter()
        wait({ $0[5] == "playing" && (Int64($0[2]) ?? 0) > 4800 && actual(voiceA) }, "Playing B to A must use new actual PCM")
        app.buttons["stopSpeech"].firstMatch.pressAtCenter()
        let cursor = Array(fields()[3...4])
        choose(b)
        XCTAssertEqual(fields()[5], "stopped")
        XCTAssertEqual(Array(fields()[3...4]), cursor)
        play.pressAtCenter()
        wait({ $0[5] == "playing" && (Int64($0[2]) ?? 0) > 4800 && actual(voiceB) }, "Stopped A to B must use new actual PCM")
        print("FINAL_VOICE_CHANGE_EVIDENCE \(fields().joined(separator: "|"))")
        snapshot(app, "System-Voice-Change-Actual-PCM")
        app.buttons["stopSpeech"].firstMatch.pressAtCenter()
    }
    func testSystemMandarinPCMAndSettingsPreservePlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing", "--system-speech-ui-testing"]
        launch(app); openBook("校稿测试", app: app)
        let play = app.buttons["playPause"]
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = evidence(); return e.count > 2 && (Int64(e[2]) ?? 0) > 4800 }, object: nil)], timeout: 30), .completed)
        play.press(); let frozen = evidence()
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.25"].press(); app.buttons["closeSpeechSpeed"].press()
        XCTAssertEqual(evidence()[1], frozen[1]); XCTAssertEqual(evidence()[2], frozen[2])
        XCTAssertEqual(evidence()[14], "1.25")
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = evidence(); return (Int64(e[2]) ?? 0) > (Int64(frozen[2]) ?? 0) + 2400 }, object: nil)], timeout: 15), .completed)
        let generation = evidence()[1]
        themeOption("green", app: app).press(); app.buttons["完成"].firstMatch.press()
        app.buttons["outlineButton"].press()
        XCTAssertTrue(app.textFields["searchField"].waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press()
        XCTAssertEqual(evidence()[1], generation, "Opening the outline cannot reload the reading waveform")
        app.buttons["speechSpeed"].press(); app.buttons["朗读设置"].press()
        XCTAssertTrue(app.staticTexts["selectedVoice"].waitForExistence(timeout: 10))
        snapshot(app, "System-Mandarin-Settings")
        app.buttons["完成"].firstMatch.press()
        XCTAssertEqual(evidence()[1], generation, "Closing settings cannot stop normal book playback")
        XCTAssertEqual(evidence()[5], "playing")
        print("SYSTEM_AUDIO_GRAPH \(play.value as? String ?? "missing")")
        app.buttons["stopSpeech"].press()
    }
    func testNovelChapterNavigationAndSequentialLocalPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--novel-ui-testing"]
        launch(app)
        XCTAssertTrue(app.buttons["book-第1章"].waitForExistence(timeout: 20))
        openBook("第1章", app: app)
        XCTAssertFalse(app.buttons["saveDocument"].exists)
        let syntax = app.descendants(matching: .any)["syntaxMenu"].firstMatch
        XCTAssertGreaterThanOrEqual(syntax.frame.minY, app.descendants(matching: .any)["readerPaper"].firstMatch.frame.maxY - 1)
        snapshot(app, "Novel-Chapter-1-White")
        let play = app.buttons["playPause"]
        play.press()
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "|playing|"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 45), .completed)
        play.press()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "|paused|"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
        let pausedValue = play.value as? String
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(play.value as? String, pausedValue, "Pausing must freeze the voice position")
        play.press()
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第2章.md"), object: app.staticTexts["currentMode"])
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 55), .completed, "End of chapter 1 should continue with chapter 2")
        snapshot(app, "Novel-Automatic-Chapter-2")
        let tenth = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第10章.md"), object: app.staticTexts["currentMode"])
        XCTAssertEqual(XCTWaiter.wait(for: [tenth], timeout: 45), .completed, "Numeric order is 1, 2, 10")
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "开始朗读"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 45), .completed, "The final chapter should stop rather than read the directory file")
        snapshot(app, "Novel-Final-Chapter-10")
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        openBook("第10章", app: app)
        library(app)
        #endif
        XCTAssertTrue(app.descendants(matching: .any)["novel-连续朗读测试"].firstMatch.waitForExistence(timeout: 15))
        snapshot(app, "Novel-Persisted-Collection")
    }
    func testSidebarMarkdownChapterSelectionPreservesPausedPlayback() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; launch(app)
        #if os(iOS)
        openBook("校稿测试", app: app)
        #else
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 15)); app.buttons["modeToggle"].press()
        #endif
        let play = app.buttons["playPause"]
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = evidence(); return e.count > 2 && (Int64(e[2]) ?? 0) > 2400 }, object: nil)], timeout: 45), .completed)
        play.press(); let previous = evidence()[1]
        #if os(iOS)
        app.buttons["showChapterSidebar"].press()
        #endif
        let chapter = app.buttons["chapterHeading-3"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10)); snapshot(app, "Markdown-Left-Chapter-Outline")
        chapter.press()
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(evidence()[5], "paused")
        XCTAssertEqual(evidence()[3], "3")
        XCTAssertNotEqual(evidence()[1], previous)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(evidence()[2], "0")
        snapshot(app, "Markdown-Chapter-Jump-Remains-Paused")
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let e = evidence(); return e.count > 2 && (Int64(e[2]) ?? 0) > 2400 }, object: nil)], timeout: 30), .completed)
        app.buttons["stopSpeech"].press()
    }
    #if os(macOS)
    private func paste(_ text: String, into element: XCUIElement) {
        let clipboard = NSPasteboard.general
        let old = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem(); for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }; return copy
        }
        defer { clipboard.clearContents(); if !old.isEmpty { clipboard.writeObjects(old) } }
        clipboard.clearContents(); clipboard.setString(text, forType: .string); element.typeKey("v", modifierFlags: .command)
    }
    #endif
    func testEditorRulersNoWrapAndSyntaxPlacement() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--editor-layout-testing"]
        launch(app)
        #if os(iOS)
        openBook("校稿测试", app: app); app.buttons["modeToggle"].press()
        #endif
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let ruler = app.descendants(matching: .any)["editorColumnRuler"].firstMatch
        let gutter = app.descendants(matching: .any)["editorLineNumbers"].firstMatch
        var wrap: XCUIElement {
            #if os(iOS)
            return visibleEditorWrap(in: app)
            #else
            return app.buttons["wrapToggle"]
            #endif
        }
        XCTAssertTrue(ruler.exists); XCTAssertTrue(gutter.exists)
        XCTAssertEqual(wrap.value as? String, "关闭")
        XCTAssertEqual(gutter.value as? String, "8 行，可见：1、2、3、4、5、6、7、8")
        XCTAssertLessThan(ruler.frame.maxY, editor.frame.minY + 1)
        XCTAssertLessThan(gutter.frame.maxX, editor.frame.minX + 1)
        let source = editor.value as? String ?? ""
        XCTAssertTrue(source.contains("中文 abc😀"))
        snapshot(app, "Editor-No-Wrap-Acrylic")
        #if os(macOS)
        editor.scroll(byDeltaX: -500, deltaY: 0)
        #else
        // 横向滚动由真实外层视口承载；UITextView 自身仅负责纵向滚动。
        app.scrollViews["manuscriptHorizontalViewport"].firstMatch.swipeLeft()
        #endif
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (ruler.value as? String) != "第 1 列起" }, object: ruler)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 8), .completed, "The unwrapped editor must really scroll horizontally")
        snapshot(app, "Editor-Horizontal-Ruler")
        wrap.press()
        XCTAssertEqual(wrap.value as? String, "开启")
        XCTAssertEqual(ruler.value as? String, "第 1 列起")
        XCTAssertEqual(editor.value as? String, source)
        let wrappedGutter = gutter.value as? String ?? ""
        XCTAssertTrue(wrappedGutter.hasPrefix("8 行，可见：1"), "Soft wraps must retain the logical source line count")
        XCTAssertFalse(wrappedGutter.contains("、9"), "Soft wraps cannot invent extra source lines")
        snapshot(app, "Editor-Wrapped-Logical-Lines")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in wrap.value as? String == "开启" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed)
        #if os(macOS)
        wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        wrap.press()
        #endif
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in wrap.value as? String == "关闭" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, source)
        editor.typeText("caret-marker ")
        let edited = editor.value as? String ?? ""
        XCTAssertTrue(edited.hasPrefix("caret-marker 开始："), "Wrapping and scrolling must preserve the insertion point")
        let syntax = app.descendants(matching: .any)["syntaxMenu"].firstMatch
        XCTAssertGreaterThan(syntax.frame.minY, editor.frame.maxY - 1)
        XCTAssertGreaterThan(syntax.frame.midX, ruler.frame.midX)
        chooseSyntax("sql", app: app)
        XCTAssertEqual(documentFormat(app), "SQL")
        XCTAssertEqual(editor.value as? String, edited)
        XCTAssertFalse(app.textFields["fileNameField"].exists)
        app.descendants(matching: .any)["documentMenu"].firstMatch.press()
        #if os(macOS)
        XCTAssertFalse(app.menuItems["documentConfiguration"].exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        #else
        XCTAssertFalse(app.buttons["documentConfiguration"].exists)
        editor.pressAtCenter()
        #endif
    }
    func testSaveNamingCancellationAndExactExtension() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--save-naming-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15)); app.buttons["newBook"].press()
        #if os(macOS)
        let current = app.staticTexts["currentMode"]
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "未命名文稿.txt"), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 15), .completed)
        #endif
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "", "New documents must start empty")
        editor.typeText("Save naming marker 😀\n第二行。")
        let content = editor.value as? String
        app.buttons["saveDocument"].press()
        #if os(iOS)
        XCTAssertTrue(app.textFields["fileNameField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["syntaxPicker"].exists)
        #else
        XCTAssertTrue(app.textFields["saveAsNameTextField"].waitForExistence(timeout: 10))
        #endif
        #if os(macOS)
        let cancel = app.buttons["CancelButton"]
        #else
        let cancel = app.buttons["取消"]
        #endif
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        #if os(macOS)
        cancel.click()
        #else
        cancel.press()
        #endif
        XCTAssertTrue(editor.waitForExistence(timeout: 10)); XCTAssertEqual(editor.value as? String, content)
        chooseSyntax("sql", app: app)
        saveAs("saved-" + String(UUID().uuidString.prefix(8)) + ".custom", app: app)
        XCTAssertEqual(documentFormat(app), "SQL")
        XCTAssertEqual(editor.value as? String, content)
        snapshot(app, "Save-As-Exact-Name-Syntax-Independent")
    }
    func testVisualRuntimeScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing"]
        launch(app)
        #if os(macOS)
        XCTAssertTrue(app.textViews["manuscriptEditor"].waitForExistence(timeout: 15))
        snapshot(app, "Mac-Main")
        app.buttons["modeToggle"].press()
        #else
        let sample = app.buttons["book-校稿测试"]
        XCTAssertTrue(sample.waitForExistence(timeout: 15))
        snapshot(app, "Library")
        sample.press()
        #endif
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textViews["manuscriptEditor"].exists, "Reading must remain read only")
        snapshot(app, "Reader-Warm")
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.textViews["manuscriptEditor"].waitForExistence(timeout: 15))
        snapshot(app, "Editor")
        app.buttons["saveDocument"].press()
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 15))
        snapshot(app, "Reader-After-Edit")
        for (identifier, name) in [("warm", "暖黄"), ("green", "柔绿"), ("dark", "黑色"), ("white", "白色")] {
            app.descendants(matching: .any)["appearanceMenu"].firstMatch.press()
            #if os(macOS)
            XCTAssertTrue(app.menuItems[name].waitForExistence(timeout: 5)); app.menuItems[name].press()
            #else
            app.buttons[name].press()
            #endif
            XCTAssertEqual(app.descendants(matching: .any)["appearanceMenu"].firstMatch.value as? String, identifier)
            snapshot(app, "Reader-" + identifier)
        }
        library(app)
        snapshot(app, "Library-After-Reader")
    }
    func testSpeechAudioStartsOnDevice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing"]
        launch(app)
        #if os(iOS)
        XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15))
        app.buttons["book-校稿测试"].press()
        #else
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 15))
        app.buttons["modeToggle"].press()
        #endif
        let play = app.buttons["playPause"], failure = app.staticTexts["speechError"]
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.press()
        func frame() -> Int64 {
            let values = (play.value as? String ?? "").components(separatedBy: "|")
            return values.count > 2 ? Int64(values[2]) ?? 0 : 0
        }
        let ready = NSPredicate { _, _ in failure.exists || frame() > 4800 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 60), .completed)
        if failure.exists { XCTFail("Device playback failed: \(failure.label)"); return }
        XCTAssertGreaterThan(frame(), 4800, "Native speech audio must reach the real audio player")
        snapshot(app, "Speech-设备实际播放")
        app.buttons["stopSpeech"].press()
    }
    func testSpeechPCMPlaybackPauseSeekAndContinuity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--speech-ui-testing"]
        launch(app)
        #if os(iOS)
        XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15))
        app.buttons["book-校稿测试"].press()
        #else
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 15))
        app.buttons["modeToggle"].press()
        #endif
        #if os(iOS)
        let pageGeometry = app.staticTexts["readerPageGeometry"].firstMatch
        XCTAssertTrue(pageGeometry.waitForExistence(timeout: 10))
        func pageHeight() -> Double { Double(pageGeometry.label.components(separatedBy: "|").dropFirst().first ?? "0") ?? 0 }
        let pureReadingHeight = pageHeight()
        XCTAssertGreaterThan(pureReadingHeight, 100)
        snapshot(app, "Speech-Large-Controls-Pure-Reading-Before")
        #endif
        let play = app.descendants(matching: .any).matching(identifier: "playPause").firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.press()
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        func frame() -> Int64 { let values = evidence(); return values.count > 2 ? Int64(values[2]) ?? 0 : 0 }
        func waitForEffectiveRate(_ expected: Float) {
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let fields = evidence()
                guard fields.count > 17, let requested = Float(fields[13]), let effect = Float(fields[14]), let native = Float(fields[17]) else { return false }
                return abs(requested - expected) < 0.001 && abs(effect * native - expected) < 0.001
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 5), .completed, "Wait for the actual audio graph to apply the chosen rate")
        }
        let started = NSPredicate { _, _ in frame() > 4800 && evidence().count > 6 && evidence()[6] == "0" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: started, object: nil)], timeout: 45), .completed, "Real speech PCM must reach the audio player")
        XCTAssertEqual(evidence().first, "Speech")
        #if os(iOS)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(pageHeight() - (pureReadingHeight - 104)) < 1 }, object: nil)], timeout: 10), .completed, "Listening must reserve 104pt more space than pure reading")
        #endif
        let live = evidence()
        app.buttons["speechSpeed"].press()
        XCTAssertTrue(app.buttons["speechSpeedPreset-1.50"].waitForExistence(timeout: 10))
        app.buttons["speechSpeedPreset-1.50"].press()
        XCTAssertEqual(evidence()[5], "playing", "Live speed adjustment must keep the player running")
        waitForEffectiveRate(1.5)
        assertEffectiveRate(evidence(), expected: 1.5)
        XCTAssertEqual(evidence()[1], live[1])
        app.buttons["closeSpeechSpeed"].press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in frame() > (Int64(live[2]) ?? 0) + 2400 }, object: nil)], timeout: 10), .completed)
        play.press()
        let frozen = evidence()
        XCTAssertEqual(frozen[5], "paused")
        // Keep the UI event loop running while synthesis finishes ahead of pause.
        let stable = NSPredicate { _, _ in evidence() == frozen }
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        XCTAssertTrue(stable.evaluate(with: nil), "Lookahead must not move a paused audio cursor")
        app.buttons["speechSpeed"].press()
        let speedSlider = app.sliders["speechSpeedSlider"]
        XCTAssertTrue(speedSlider.waitForExistence(timeout: 10))
        speedSlider.adjust(toNormalizedSliderPosition: 1)
        // Native macOS slider automation can stop one thumb step before the
        // endpoint. Exercise the drag, then verify exact endpoints via presets.
        XCTAssertGreaterThanOrEqual(Float(evidence()[13]) ?? 0, 1.9)
        assertEffectiveRate(evidence(), expected: Float(evidence()[13])!)
        speedSlider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThanOrEqual(Float(evidence()[13]) ?? 2, 0.6)
        app.buttons["speechSpeedPreset-2.00"].press()
        waitForEffectiveRate(2)
        assertEffectiveRate(evidence(), expected: 2)
        app.buttons["speechSpeedPreset-0.50"].press()
        waitForEffectiveRate(0.5)
        assertEffectiveRate(evidence(), expected: 0.5)
        app.buttons["speechSpeedPreset-1.25"].press()
        waitForEffectiveRate(1.25)
        assertEffectiveRate(evidence(), expected: 1.25)
        snapshot(app, "语速-滑块与常用倍率")
        app.buttons["closeSpeechSpeed"].press()
        #if os(iOS)
        let speedButton = app.buttons["speechSpeed"]
        XCTAssertEqual(speedButton.value as? String, "1.25")
        XCTAssertGreaterThanOrEqual(speedButton.frame.width, 56)
        XCTAssertGreaterThanOrEqual(speedButton.frame.height, 44)
        XCTAssertGreaterThanOrEqual(play.frame.width, 64)
        XCTAssertGreaterThanOrEqual(play.frame.height, 64)
        for id in ["speechPrevious", "speechNext", "stopSpeech"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame))
        }
        FileHandle.standardOutput.write(Data("LARGE_SPEECH_CONTROLS rate=1.25 speed=\(speedButton.frame) play=\(play.frame) previous=\(app.buttons["speechPrevious"].frame) next=\(app.buttons["speechNext"].frame) stop=\(app.buttons["stopSpeech"].frame) purePageHeight=\(pureReadingHeight) listeningPageHeight=\(pageHeight())\n".utf8))
        snapshot(app, "Speech-Large-Controls-1.25x-Single-Line")
        #endif
        XCTAssertEqual(evidence()[1], frozen[1], "Changing speed cannot replace the queued waveform")
        XCTAssertEqual(evidence()[2], frozen[2], "Changing speed cannot move the paused sample")
        XCTAssertEqual(evidence()[8], frozen[8])
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in frame() > (Int64(frozen[2]) ?? 0) + 2400 }, object: nil)], timeout: 15), .completed)
        play.press()
        FileHandle.standardOutput.write(Data("PCM_BEFORE_SEEK \(evidence())\n".utf8))
        // 短文稿在操作倍速期间仍可能推进到末段；实际点击上一段归一后验证 0→1→2。
        var previousCount = 0
        while (Int(evidence()[3]) ?? 0) > 0, previousCount < 4 {
            let beforePrevious = evidence(), segment = Int(evidence()[3])!
            app.buttons["speechPrevious"].press()
            let previous = evidence()
            XCTAssertEqual(Int(previous[3]), segment - 1)
            XCTAssertNotEqual(previous[1], beforePrevious[1])
            XCTAssertEqual(previous[5], "paused")
            previousCount += 1
        }
        XCTAssertEqual(Int(evidence()[3]), 0)
        FileHandle.standardOutput.write(Data("PCM_NORMALIZED_BEFORE_NEXT \(evidence())\n".utf8))
        let oldGeneration = evidence()[1], oldSegment = Int(evidence()[3])!
        app.buttons["下一段"].press()
        let sought = evidence()
        XCTAssertNotEqual(sought[1], oldGeneration)
        XCTAssertEqual(Int(sought[3]), oldSegment + 1)
        XCTAssertEqual(sought[5], "paused")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(frame(), 0, "A paused seek cannot start buffered old audio")
        play.press()
        let moving = NSPredicate { _, _ in frame() > 4800 && evidence()[1] == sought[1] }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moving, object: nil)], timeout: 30), .completed)
        let firstSegment = evidence()[3]
        FileHandle.standardOutput.write(Data("PCM_AUTO_CONTINUITY_START \(evidence())\n".utf8))
        let continued = NSPredicate { _, _ in let e = evidence(); return e.count > 6 && e[3] != firstSegment && e[5] == "playing" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: continued, object: nil)], timeout: 30), .completed, "The next paragraph must play automatically")
        XCTAssertEqual(evidence()[6], "0", "The native queue must bridge paragraphs without synthesis gaps")
        snapshot(app, "Speech-真实离线播放与句子高亮")
        play.press()
        let checkpoint = evidence()
        XCTAssertEqual(checkpoint[5], "paused", "The saved checkpoint must be captured while audio is paused")
        print("Saved playback evidence: \(checkpoint)")
        XCTAssertGreaterThan(Int64(checkpoint[8]) ?? 0, 0)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        // 工作区会自动恢复已打开的文稿；仅仍在资料库时才通过真实条目打开。
        let restoredMode = app.staticTexts["currentMode"].firstMatch
        if restoredMode.waitForExistence(timeout: 5) {
            XCTAssertEqual(restoredMode.value as? String, "校稿测试.md")
            XCTAssertTrue(app.descendants(matching: .any)["reader"].firstMatch.exists)
        } else {
            XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15)); app.buttons["book-校稿测试"].press()
        }
        #else
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 15)); app.buttons["modeToggle"].press()
        #endif
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.press()
        print("Restored playback evidence: \(evidence())")
        let recovered = NSPredicate { _, _ in let e = evidence(); return e.count > 8 && e[7] == checkpoint[8] && frame() > 2400 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: recovered, object: nil)], timeout: 45), .completed, "Restart must reuse the same waveform at its saved PCM sample")
        // The player may have advanced beyond a short saved sentence by the
        // time XCTest reads it. Verify the actual restored anchor separately.
        XCTAssertEqual(evidence()[9], checkpoint[3])
        XCTAssertEqual(evidence()[10], checkpoint[4])
        XCTAssertEqual(evidence()[11], "true", "The saved PCM hash must match the resumed audio, independent of model randomness")
        waitForEffectiveRate(1.25)
        assertEffectiveRate(evidence(), expected: 1.25)
        XCTAssertEqual(app.buttons["speechSpeed"].value as? String, "1.25")
        app.buttons["stopSpeech"].press()
        XCTAssertEqual(evidence()[5], "stopped")
        #if os(iOS)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(pageHeight() - pureReadingHeight) < 1 }, object: nil)], timeout: 10), .completed, "Stopping must return the reserved control height to the text")
        snapshot(app, "Speech-Large-Controls-Stopped-Reading-Restored")
        #endif
    }
    func testIndependentControlsAndDarkThemeContrast() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        launch(app)
        #if os(macOS)
        let identifiers = ["newBook", "importBook", "libraryMenu"]
        #else
        let identifiers = ["newBook", "importBook", "resumeLast", "nearbyDevices"]
        #endif
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15))
        for (index, identifier) in identifiers.enumerated() {
            let button = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(button.isHittable, identifier)
            for other in identifiers.dropFirst(index + 1) {
                XCTAssertFalse(button.frame.intersects(app.descendants(matching: .any)[other].firstMatch.frame), "Independent button hit areas must not overlap")
            }
        }
        snapshot(app, "书库与文稿-紧凑工具栏")
        #if os(iOS)
        app.buttons["book-校稿测试"].press()
        #else
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for identifier in identifiers {
            XCTAssertLessThan(app.descendants(matching: .any)[identifier].firstMatch.frame.maxX, editor.frame.minX, "Library controls belong to the left pane")
        }
        for identifier in ["saveDocument", "modeToggle", "outlineButton", "documentMenu"] {
            let control = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertLessThan(control.frame.maxY, editor.frame.minY + 1, "Document controls sit above the editor")
            XCTAssertGreaterThanOrEqual(control.frame.minX, editor.frame.minX, "Document controls belong to the right pane")
        }
        XCTAssertGreaterThan(editor.frame.height, app.windows.firstMatch.frame.height * 0.75, "The document must retain most of the window height")
        app.descendants(matching: .any)["libraryMenu"].firstMatch.press()
        XCTAssertTrue(app.menuItems["继续上次阅读"].exists)
        XCTAssertTrue(app.menuItems["附近设备"].exists)
        editor.click()
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
        snapshot(app, "文稿-紧凑阅读工具栏")
        #endif
        for (theme, title) in [("white", "白色"), ("warm", "暖黄"), ("green", "柔绿"), ("dark", "黑色")] {
            #if os(macOS)
            app.descendants(matching: .any)["appearanceMenu"].firstMatch.press()
            snapshot(app, "桌面主题菜单-" + theme)
            let control = app.menuItems[title]
            #else
            app.descendants(matching: .any)["appearanceMenu"].firstMatch.press()
            let control = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            #endif
            XCTAssertTrue(control.waitForExistence(timeout: 10)); control.press()
            XCTAssertFalse(app.buttons["saveDocument"].exists, "Reading hides editing actions")
            for identifier in ["playPause", "stopSpeech", "modeToggle", "outlineButton"] {
                XCTAssertTrue(app.buttons[identifier].isHittable, "Control must remain visible and reachable: " + identifier)
            }
            XCTAssertTrue(app.descendants(matching: .any)["appearanceMenu"].firstMatch.isHittable)
            snapshot(app, "统一亚克力-" + theme)
        }
        app.buttons["speechSpeed"].press()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10))
        app.buttons["朗读设置"].press()
        XCTAssertTrue(app.staticTexts["selectedVoice"].waitForExistence(timeout: 10))
        let selectedVoice = app.staticTexts["selectedVoice"]
        let voice = selectedVoice.label + " " + (selectedVoice.value as? String ?? "")
        snapshot(app, "普通话音色-深色设置")
        XCTAssertTrue(voice.contains("zh-") || voice.contains("未安装普通话音色"), "Chinese reading must never select an English voice: " + voice)
    }
    #if os(macOS)
    func testLibraryAndDocumentMenuContext() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        launch(app)
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 15))
        app.descendants(matching: .any)["documentMenu"].firstMatch.press()
        for identifier in ["saveAs", "shareDocument", "syncDocument", "speechSettings"] {
            XCTAssertTrue(app.menuItems[identifier].exists, "Document actions must be in the document menu: " + identifier)
        }
        XCTAssertFalse(app.menuItems["documentConfiguration"].exists)
        XCTAssertFalse(app.menuItems["resumeLast"].exists)
        XCTAssertFalse(app.menuItems["nearbyDevices"].exists)
        snapshot(app, "当前文稿菜单")
        app.menuItems["返回历史记录"].press()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["saveDocument"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["newBook"].isHittable)
        XCTAssertTrue(app.buttons["importBook"].isHittable)
        XCTAssertFalse(app.buttons["modeToggle"].exists)
        snapshot(app, "关闭文稿-保留书库入口")
        libraryAction("resumeLast", app: app).press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
    }
    #endif
    private func documentAction(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        if app.menuItems[identifier].exists { return app.menuItems[identifier] }
        #else
        if app.buttons[identifier].exists { return app.buttons[identifier] }
        #endif
        let menu = app.descendants(matching: .any)["documentMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "Opening the document must finish before invoking its actions")
        menu.press()
        #if os(macOS)
        return app.menuItems[identifier]
        #else
        return app.buttons[identifier]
        #endif
    }
    private func libraryAction(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        if app.menuItems[identifier].exists { return app.menuItems[identifier] }
        app.descendants(matching: .any)["libraryMenu"].firstMatch.press()
        return app.menuItems[identifier]
        #else
        return app.buttons[identifier]
        #endif
    }
    private func documentFormat(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["syntaxMenu"].firstMatch.value as? String ?? ""
    }
    private func chooseSyntax(_ format: String, app: XCUIApplication) {
        app.descendants(matching: .any)["syntaxMenu"].firstMatch.press()
        #if os(macOS)
        app.menuItems[["sql": "SQL", "json": "JSON", "auto": "自动识别"][format] ?? format].press()
        #else
        app.buttons[["sql": "SQL", "json": "JSON", "auto": "自动识别"][format] ?? format].press()
        #endif
    }
    private func saveAs(_ name: String, app: XCUIApplication) {
        documentAction("saveAs", app: app).press()
        #if os(macOS)
        let field = app.textFields["saveAsNameTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        if app.staticTexts["testExportDirectory"].exists {
            let directory = app.staticTexts["testExportDirectory"].value as? String ?? ""
            XCTAssertTrue(directory.hasPrefix("/"))
            app.typeKey("g", modifierFlags: [.command, .shift])
            let pathField = app.textFields["PathTextField"]
            XCTAssertTrue(pathField.waitForExistence(timeout: 5))
            pathField.typeKey("a", modifierFlags: .command); pathField.typeText(directory)
            pathField.typeKey(.return, modifierFlags: [])
            if pathField.exists { pathField.typeKey(.return, modifierFlags: []) }
            XCTAssertTrue(pathField.waitForNonExistence(timeout: 5), app.debugDescription)
        }
        field.press(); field.typeKey("a", modifierFlags: .command); field.typeText(name)
        let save = app.buttons["OKButton"]; XCTAssertTrue(save.waitForExistence(timeout: 10)); save.press()
        #else
        let field = app.textFields["fileNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.press()
        // 长文件名在手机上会横向滚动，点按后光标可能位于中间；全选再输入，不能只退格前半段。
        field.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Select All' OR label == '全选'")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5)); selectAll.press()
        field.typeText(name)
        XCTAssertEqual(field.value as? String, name)
        app.buttons["confirmFileName"].press()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15)); save.press()
        #endif
        let status = app.staticTexts["exportStatus"]
        let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            #if os(macOS)
            (status.value as? String ?? status.label) == "已另存为 " + name
            #else
            status.label == "已另存为 " + name
            #endif
        }, object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [exported], timeout: 15), .completed)
    }
    private func themeOption(_ theme: String, app: XCUIApplication) -> XCUIElement {
        let appearance = app.descendants(matching: .any)["appearanceMenu"].firstMatch
        #if os(iOS)
        // 阅读底栏直接选择主题；编辑时从文稿菜单中的同一主题选择器进入。
        if appearance.exists { appearance.press() }
        else { app.descendants(matching: .any)["documentMenu"].firstMatch.press() }
        #else
        appearance.press()
        app.popUpButtons.matching(NSPredicate(format: "identifier BEGINSWITH 'theme-'")).firstMatch.press()
        #endif
        let title = ["white": "白色", "warm": "暖黄", "green": "柔绿", "dark": "黑色"][theme]!
        #if os(macOS)
        return app.menuItems.matching(identifier: title).allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.menuItems[title].firstMatch
        #else
        return app.buttons[title]
        #endif
    }
    private func openBook(_ name: String, app: XCUIApplication) {
        let book = app.buttons["book-" + name].firstMatch
        #if os(iOS)
        if !(book.waitForExistence(timeout: 3) && book.isHittable) {
            let navigation = app.collectionViews["workspaceNavigation"].firstMatch
            let library = app.descendants(matching: .any)["libraryList"].firstMatch
            if !navigation.exists && !library.exists && app.buttons["toggleChapterSidebar"].firstMatch.exists { app.buttons["toggleChapterSidebar"].firstMatch.press() }
            let list = library.exists ? library : navigation
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            for _ in 0..<20 { if book.exists && book.isHittable { break }; list.swipeUp() }
        }
        #else
        var list = app.outlines["libraryList"].firstMatch
        if !list.exists { list = app.outlines["workspaceNavigation"].firstMatch }
        if !list.exists && app.buttons["toggleChapterSidebar"].exists { app.buttons["toggleChapterSidebar"].firstMatch.press() }
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let scrollView = app.scrollViews.containing(.outline, identifier: list.identifier).firstMatch
        var visibleBookFrame = CGRect.zero
        for _ in 0..<20 {
            let frame = book.frame, viewport = list.frame
            // 原生 List 会为尚未生成的行返回 (0,982,0,0) 占位框；它不能用来判断滚动方向。
            if !frame.isEmpty && viewport.contains(frame) { visibleBookFrame = frame; break }
            let delta: CGFloat = !frame.isEmpty && frame.midY < viewport.minY ? 250 : -250
            (scrollView.exists ? scrollView : list).scroll(byDeltaX: 0, deltaY: delta)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
        XCTAssertFalse(visibleBookFrame.isEmpty, "文稿按钮必须进入列表视口，避免点到下方的缓存管理。")
        #endif
        XCTAssertTrue(book.waitForExistence(timeout: 10), name)
        #if os(macOS)
        // 行已完整进入视口，再使用控件原生命中点，避免窗口坐标系与内容区原点不同。
        book.click()
        let selectedDocument = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.staticTexts["currentMode"].value as? String ?? "").hasPrefix(name + ".")
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedDocument], timeout: 15), .completed, "打开的文件必须与所选历史条目一致")
        #else
        book.press()
        #endif
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["modeToggle"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        #if os(macOS)
        if app.buttons["selectedMode"].label == "编辑" { app.typeKey("r", modifierFlags: [.command, .shift]) }
        #endif
        #if os(iOS)
        // 普通 iPhone 的模式按钮没有独立 selectedMode 子节点，依据真实正文视图验就绪。
        let reader = app.descendants(matching: .any)["reader"].firstMatch
        let editor = app.textViews["manuscriptEditor"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reader.exists || editor.exists }, object: nil)], timeout: 20), .completed)
        if editor.exists { app.buttons["modeToggle"].firstMatch.pressAtCenter() }
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        #else
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "阅读"), object: app.buttons["selectedMode"])
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 30), .completed)
        #endif
    }
    private func library(_ app: XCUIApplication) {
        app.descendants(matching: .any)["documentMenu"].firstMatch.press()
        #if os(macOS)
        app.menuItems["返回历史记录"].press()
        #else
        app.buttons["返回历史记录"].press()
        #endif
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["modeToggle"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed, "Return to library must close the document pane")
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 10))
    }
    private func searchJump(_ query: String, app: XCUIApplication) {
        app.buttons["outlineButton"].press()
        let field = app.textFields["searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.press()
        #if os(macOS)
        field.typeKey("a", modifierFlags: .command)
        #else
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
        #endif
        field.typeText(query)
        snapshot(app, "搜索输入-" + query)
        app.buttons["searchSubmit"].press()
        snapshot(app, "搜索提交-" + query)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '1 · 第'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.press(); app.buttons["完成"].firstMatch.press()
    }
    private func bookmark(_ name: String, app: XCUIApplication) {
        documentAction("readingBookmarks", app: app).press()
        XCTAssertTrue(app.buttons["addBookmark"].waitForExistence(timeout: 10)); app.buttons["addBookmark"].press()
        let nameField = app.textFields["bookmarkNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10)); nameField.press()
        #if os(macOS)
        nameField.typeKey("a", modifierFlags: .command)
        #else
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        #endif
        nameField.typeText(name); pressBookmarkSave(app)
        XCTAssertTrue(app.buttons["bookmark-" + name].waitForExistence(timeout: 10))
        app.buttons["完成"].firstMatch.press()
    }
    private func pressBookmarkSave(_ app: XCUIApplication) {
        let button = app.buttons["saveBookmark"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.press()
    }
    func testChineseWritingReadOnlyAndNativeShareCancel() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15)); app.buttons["newBook"].press()
        let editor = app.textViews["manuscriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        func enterText(_ text: String) {
            #if os(macOS)
            // XCTest's per-key Chinese synthesis can time out with the user's
            // active input method. Use the same fixed-text paste as the Mac
            // playback test; restore every original pasteboard representation.
            let clipboard = NSPasteboard.general
            let previousItems = (clipboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            defer { clipboard.clearContents(); if !previousItems.isEmpty { clipboard.writeObjects(previousItems) } }
            editor.press(); clipboard.clearContents(); clipboard.setString(text, forType: .string)
            editor.typeKey("v", modifierFlags: [.command])
            #else
            editor.typeText(text)
            #endif
        }
        enterText("中文输入校稿。新建可以编辑。\nSecond line 123")
        XCTAssertTrue((editor.value as? String ?? "").contains("中文输入校稿。"))
        snapshot(app, "iPhone-新建中文-键盘展开")
        let savedTitle = "中文输入校稿-" + String(UUID().uuidString.prefix(8))
        saveAs(savedTitle + ".txt", app: app)
        for cycle in 1...3 {
            app.buttons["modeToggle"].press()
            XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10)); XCTAssertFalse(editor.exists, "Reading must have no writable text view")
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readingLine-' AND label CONTAINS '中文输入校稿'")).firstMatch.waitForExistence(timeout: 10))
            snapshot(app, "只读阅读-切换\(cycle)")
            app.buttons["modeToggle"].press(); XCTAssertTrue(editor.waitForExistence(timeout: 10))
            enterText("追加\(cycle)")
            XCTAssertTrue((editor.value as? String ?? "").contains("追加\(cycle)"))
        }
        app.buttons["saveDocument"].press(); app.buttons["modeToggle"].press()
        documentAction("shareDocument", app: app).press()
        #if os(iOS)
        let close = app.buttons.matching(NSPredicate(format: "label == 'Close' OR label == '关闭' OR label == 'Cancel' OR label == '取消'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10)); snapshot(app, "系统分享面板-仅打开未发送"); close.press()
        #else
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        #endif
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10))
        for identifier in ["saveAs"] {
            #if os(macOS)
            app.typeKey("s", modifierFlags: [.command, .shift])
            snapshot(app, identifier + "-Mac系统文件面板等待")
            #else
            let action = documentAction(identifier, app: app)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: action)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed, "System panel must finish dismissing before the next operation")
            action.press()
            #endif
            #if os(macOS)
            // 同名 Cancel 还会匹配虚拟 Touch Bar；系统面板的真实按钮有固定标识。
            let cancel = app.buttons["CancelButton"]
            #else
            let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == '取消'")).firstMatch
            #endif
            #if os(iOS)
            if !cancel.waitForExistence(timeout: 3) {
                let browse = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].buttons["浏览"]
                XCTAssertTrue(browse.waitForExistence(timeout: 5)); browse.press()
            }
            #endif
            XCTAssertTrue(cancel.waitForExistence(timeout: 10)); snapshot(app, identifier + "-系统文件面板"); cancel.press()
        }
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        openBook(savedTitle, app: app)
        #else
        app.buttons["modeToggle"].press()
        #endif
        app.buttons["modeToggle"].press()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").contains("追加3"))
        app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'readingLine-'")).firstMatch.waitForExistence(timeout: 10))
    }
    func testMultipleBooksThreeResumesAndBookmarksAcrossRestart() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15))
        for name in ["长篇甲", "长篇乙"] {
            openBook(name, app: app); searchJump("第30段", app: app)
            let position = app.staticTexts["readingPosition"]
            XCTAssertTrue(position.waitForExistence(timeout: 10)); let expected = position.value as? String ?? position.label
            XCTAssertNotEqual(expected, "0")
            bookmark(name + "-中段", app: app)
            searchJump("第60段", app: app); bookmark(name + "-后段", app: app)
            let later = position.value as? String ?? position.label
            for cycle in 1...3 {
                library(app); libraryAction("resumeLast", app: app).press()
                XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10), "Repeated resume \(cycle)")
                XCTAssertEqual(position.value as? String ?? position.label, later, "Reading position survives each resume")
            }
            library(app)
        }
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        for name in ["长篇甲", "长篇乙"] {
            openBook(name, app: app); documentAction("readingBookmarks", app: app).press()
            let middle = app.buttons["bookmark-" + name + "-中段"]
            XCTAssertTrue(middle.waitForExistence(timeout: 10)); XCTAssertTrue(app.buttons["bookmark-" + name + "-后段"].exists)
            snapshot(app, name + "-双书签重启后"); middle.press()
            XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 10)); library(app)
        }
    }
    func testElevenFormatsAutomaticSyntaxCustomExtensionAndManualOverride() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15))
        for format in ["TXT", "Markdown", "SQL", "CSV", "TSV", "Java", "JavaScript", "YAML", "JSON", "XML", "HTML"] {
            openBook("格式_" + format, app: app)
            app.buttons["modeToggle"].press()
            let editor = app.textViews["manuscriptEditor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10)); editor.typeText(" format-saved-marker ")
            XCTAssertTrue((editor.value as? String ?? "").contains("format-saved-marker"))
            XCTAssertEqual(documentFormat(app), format)
            app.buttons["saveDocument"].press(); library(app)
        }
        openBook("格式_SQL", app: app)
        chooseSyntax("sql", app: app)
        let run = String(UUID().uuidString.prefix(8))
        saveAs("custom.name." + run + ".abc", app: app)
        XCTAssertEqual(documentFormat(app), "SQL")
        snapshot(app, "另存为自定义扩展名abc-右下角SQL")
        saveAs("renamed-" + run + ".json", app: app)
        XCTAssertEqual(documentFormat(app), "SQL", "Save As must preserve manual syntax")
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        openBook("renamed-" + run, app: app)
        #endif
        XCTAssertEqual(documentFormat(app), "SQL")
    }

    func testReadingThemesPersistWithoutMovingPosition() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--regression-fixtures"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15)); openBook("长篇甲", app: app)
        searchJump("第30段", app: app)
        let position = app.staticTexts["readingPosition"]
        for theme in ["warm", "green", "dark"] {
            let expected = position.value as? String ?? position.label
            let control = themeOption(theme, app: app); control.press()
            XCTAssertEqual(app.descendants(matching: .any)["appearanceMenu"].firstMatch.value as? String, theme)
            XCTAssertEqual(position.value as? String ?? position.label, expected)
            snapshot(app, "阅读主题-" + theme)
            app.buttons["playPause"].press(); XCTAssertTrue(app.buttons["暂停朗读"].waitForExistence(timeout: 10))
            snapshot(app, "朗读高亮-" + theme); app.buttons["stopSpeech"].press()
        }
        #if os(iOS)
        let beforeLibrary = position.value as? String ?? position.label
        library(app)
        snapshot(app, "黑色主题-返回历史记录")
        libraryAction("resumeLast", app: app).press()
        XCTAssertTrue(app.descendants(matching: .any)["appearanceMenu"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["appearanceMenu"].firstMatch.value as? String, "dark")
        XCTAssertEqual(position.value as? String ?? position.label, beforeLibrary)
        snapshot(app, "黑色主题-再次继续阅读")
        #endif
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        XCTAssertTrue(app.descendants(matching: .any)["appearanceMenu"].firstMatch.waitForExistence(timeout: 10)); XCTAssertEqual(app.descendants(matching: .any)["appearanceMenu"].firstMatch.value as? String, "dark")
    }

    func testBookmarkRenameDeleteAndActualCustomExtensionSaveAs() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 15)); snapshot(app, "最终书库-原生玻璃外层")
        app.buttons["newBook"].press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("自定义扩展名导出实际正文。\n第二段。")
        themeOption("warm", app: app).press()
        snapshot(app, "最终中文编辑-系统键盘与内层")
        let name = "export-" + String(UUID().uuidString.prefix(8)) + ".custom"
        saveAs(name, app: app)
        XCTAssertTrue(app.buttons["modeToggle"].waitForExistence(timeout: 10)); app.buttons["modeToggle"].press()
        bookmark("A", app: app); bookmark("B", app: app)
        documentAction("readingBookmarks", app: app).press(); app.buttons["重命名书签 A"].press()
        let nameField = app.textFields["bookmarkNameField"]; XCTAssertTrue(nameField.waitForExistence(timeout: 10)); nameField.press()
        #if os(macOS)
        nameField.typeKey("a", modifierFlags: .command)
        #else
        nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        #endif
        nameField.typeText("C"); pressBookmarkSave(app)
        XCTAssertTrue(app.buttons["bookmark-C"].waitForExistence(timeout: 10)); app.buttons["删除书签 B"].press()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["bookmark-B"])
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 10), .completed)
        app.buttons["完成"].firstMatch.press()
        documentAction("saveAs", app: app).press()
        #if os(iOS)
        XCTAssertTrue(app.textFields["fileNameField"].waitForExistence(timeout: 10))
        app.buttons["confirmFileName"].press()
        #endif
        #if os(iOS)
        let overwriteMonitor = addUIInterruptionMonitor(withDescription: "确认覆盖当前测试导出文件") { alert in
            let replace = alert.buttons.matching(NSPredicate(format: "label == '替换' OR label == 'Replace'")).firstMatch
            guard replace.exists else { return false }
            replace.tap(); return true
        }
        defer { removeUIInterruptionMonitor(overwriteMonitor) }
        let nativeSave = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(nativeSave.waitForExistence(timeout: 15)); snapshot(app, "自定义后缀-系统保存前")
        nativeSave.press()
        // 再导出到同名的测试文件，系统保存面板需要明确确认覆盖。
        let replace = app.buttons.matching(NSPredicate(format: "label == '替换' OR label == 'Replace'")).firstMatch
        if replace.waitForExistence(timeout: 3) { replace.press() }
        else {
            // 系统文件提供器的确认框不属于宿主应用的 AX 树；实际触摸触发系统中断处理。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.97)).tap()
        }
        let status = app.staticTexts["exportStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 15)); XCTAssertEqual(status.label, "已另存为 " + name, "Export must preserve the exact extension")
        #else
        let cancel = app.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        #if os(macOS)
        cancel.click()
        #else
        cancel.press()
        #endif
        #endif
        app.terminate(); app.launchArguments = ["--ui-testing"]; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        documentAction("readingBookmarks", app: app).press()
        XCTAssertTrue(app.buttons["bookmark-C"].waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["bookmark-B"].exists)
    }
    func testLongDocumentEditSaveReadAndFontControls() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--long-ui"]; launch(app)
        XCTAssertTrue(app.buttons["newBook"].waitForExistence(timeout: 20)); openBook("性能长文", app: app)
        let began = Date(); app.buttons["modeToggle"].press()
        let editor = app.textViews["manuscriptEditor"]; XCTAssertTrue(editor.waitForExistence(timeout: 20))
        editor.typeText("长文编辑回归 "); app.buttons["saveDocument"].press(); app.buttons["modeToggle"].press()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 20)); XCTAssertLessThan(Date().timeIntervalSince(began), 40)
        app.buttons["nextPage"].press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'ready'"), object: app.staticTexts["pageNumber"])], timeout: 10), .completed)
        snapshot(app, "长文-翻页后阅读")
        app.buttons["speechSpeed"].press()
        XCTAssertTrue(app.buttons["朗读设置"].waitForExistence(timeout: 10)); app.buttons["朗读设置"].press()
        let font = app.sliders["fontSizeSlider"]
        #if os(iOS)
        let settings = app.descendants(matching: .any)["speechSettingsForm"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for _ in 0..<8 { if font.exists && font.isHittable { break }; settings.swipeUp() }
        #endif
        XCTAssertTrue(font.waitForExistence(timeout: 10)); font.adjust(toNormalizedSliderPosition: 1)
        app.buttons["完成"].firstMatch.press(); snapshot(app, "长文-最大字号与工具栏")
        XCTAssertFalse(app.buttons["saveDocument"].exists); XCTAssertTrue(app.buttons["playPause"].isHittable)
        XCTAssertTrue(app.buttons["modeToggle"].isHittable)
    }

}

private extension XCUIElement {
    func pressAtCenter() {
        let center = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        #if os(macOS)
        center.click()
        #else
        center.tap()
        #endif
    }
    func press() {
        #if os(macOS)
        if identifier.hasPrefix("book-") { click() }
        else if elementType == .button || elementType == .menuButton { coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
        else { click() }
        #else
        // A List row's AX frame can exceed the custom keycap's hit area.
        // Let XCTest resolve the control's actual accessibility hit point.
        if identifier.hasPrefix("DOC") || ["Cancel", "取消", "Close", "关闭"].contains(label) {
            // Remote document-picker controls still report a doubled AX hit
            // point on iPad; their compact UIKit frame is the visible hit area.
            let visible = frame
            XCUIApplication().coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.midX, dy: visible.midY)).tap()
        } else {
            tap()
        }
        #endif
    }
}
