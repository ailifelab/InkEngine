import XCTest
#if os(macOS)
import AppKit
import Carbon
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
            app.menuBarItems["Window"].press(); app.menuItems["显示主窗口"].press()
        }
        #endif
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
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in let fields = (play.value as? String ?? "").components(separatedBy: "|"); return fields.count > 15 && fields[15] == "matcha" && (Int64(fields[2]) ?? 0) > 4800 }, object: nil)], timeout: 30), .completed)
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
    func testOpenSourceTimeoutRecoveryAndLightweightPCM() throws {
        try checkTimeoutRecoveryAndRestart(flags: ["--light-speech-ui-testing"])
    }
    func testPiperTimeoutRecoveryKeepsPCMOnRestart() throws { throw XCTSkip("Piper voice retired") }
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
        throw XCTSkip("Piper voice retired")
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
    func testMatchaMissingWordTXTUsesFullRateWaveform() throws { try checkMatchaMissingWord(markdown: false) }
    func testLongPauseReleasesModelAndResumesRetainedPCM() throws {
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
    func testMatchaMissingWordMarkdownUsesFullRateWaveform() throws { try checkMatchaMissingWord(markdown: true) }
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
    func testMatchaActualPCMPauseSeekAndResume() throws {
        try checkOfflinePCMPauseSeekAndResume(renderer: "matcha", flag: "--light-speech-ui-testing")
    }
    func testPiperMaleActualPCMPauseSeekAndResume() throws { throw XCTSkip("Piper voice retired") }
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
        app.buttons["Matcha"].firstMatch.press()
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
        app.buttons["speechSpeed"].press(); app.buttons["speechSpeedPreset-1.25"].press(); app.buttons["closeSpeechSpeed"].press()
        let play = app.buttons["playPause"]; play.press()
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
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
        // 阅读位置按延迟写入合并保存；等待落盘后再模拟进程退出，不把强杀当作正常退出。
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        app.terminate(); app.launchArguments = ["--ui-testing", flag]; launch(app)
        #if os(iOS)
        libraryAction("resumeLast", app: app).press()
        #else
        app.buttons["modeToggle"].press()
        #endif
        let restoredPlay = app.buttons["playPause"]; restoredPlay.press()
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
        themeOption("green", app: app).press()
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
        let wrap = app.buttons["wrapToggle"]
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
        editor.swipeLeft()
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
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "开启"), object: wrap)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed)
        #if os(macOS)
        wrap.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        wrap.press()
        #endif
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "关闭"), object: wrap)
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
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.press()
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
        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15)); play.press()
        func evidence() -> [String] { (play.value as? String ?? "").components(separatedBy: "|") }
        func frame() -> Int64 { let values = evidence(); return values.count > 2 ? Int64(values[2]) ?? 0 : 0 }
        let started = NSPredicate { _, _ in frame() > 4800 && evidence().count > 6 && evidence()[6] == "0" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: started, object: nil)], timeout: 45), .completed, "Real speech PCM must reach the audio player")
        XCTAssertEqual(evidence().first, "Speech")
        let live = evidence()
        app.buttons["speechSpeed"].press()
        XCTAssertTrue(app.buttons["speechSpeedPreset-1.50"].waitForExistence(timeout: 10))
        app.buttons["speechSpeedPreset-1.50"].press()
        XCTAssertEqual(evidence()[5], "playing", "Live speed adjustment must keep the player running")
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
        assertEffectiveRate(evidence(), expected: 2)
        app.buttons["speechSpeedPreset-0.50"].press()
        assertEffectiveRate(evidence(), expected: 0.5)
        app.buttons["speechSpeedPreset-1.25"].press()
        assertEffectiveRate(evidence(), expected: 1.25)
        snapshot(app, "语速-滑块与常用倍率")
        app.buttons["closeSpeechSpeed"].press()
        XCTAssertEqual(evidence()[1], frozen[1], "Changing speed cannot replace the queued waveform")
        XCTAssertEqual(evidence()[2], frozen[2], "Changing speed cannot move the paused sample")
        XCTAssertEqual(evidence()[8], frozen[8])
        play.press()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in frame() > (Int64(frozen[2]) ?? 0) + 2400 }, object: nil)], timeout: 15), .completed)
        play.press()
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
        XCTAssertTrue(app.buttons["book-校稿测试"].waitForExistence(timeout: 15)); app.buttons["book-校稿测试"].press()
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
        assertEffectiveRate(evidence(), expected: 1.25)
        XCTAssertEqual(app.buttons["speechSpeed"].value as? String, "1.25")
        app.buttons["stopSpeech"].press()
        XCTAssertEqual(evidence()[5], "stopped")
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
        #endif
        let title = ["white": "白色", "warm": "暖黄", "green": "柔绿", "dark": "黑色"][theme]!
        #if os(macOS)
        return app.menuItems[title]
        #else
        return app.buttons[title]
        #endif
    }
    private func openBook(_ name: String, app: XCUIApplication) {
        let book = app.buttons["book-" + name].firstMatch
        #if os(iOS)
        let list = app.descendants(matching: .any)["libraryList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<20 { if book.exists && book.isHittable { break }; list.swipeUp() }
        #else
        let list = app.descendants(matching: .any)["libraryList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let scrollView = app.scrollViews.containing(.outline, identifier: "libraryList").firstMatch
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
        if app.buttons["selectedMode"].label == "编辑" { app.buttons["modeToggle"].press() }
        #endif
        let reading = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "阅读"), object: app.buttons["selectedMode"])
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 30), .completed)
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
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.press()
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
