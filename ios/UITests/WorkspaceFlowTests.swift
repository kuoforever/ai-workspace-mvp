import XCTest

private final class FixtureResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Data?, Error?) = (nil, nil)
    func set(_ data: Data?, _ error: Error?) { lock.lock(); defer { lock.unlock() }; value = (data, error) }
    func get() -> (Data?, Error?) { lock.lock(); defer { lock.unlock() }; return value }
}

final class WorkspaceFlowTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["new-review"].waitForExistence(timeout: 30))
    }
    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }
    private func waitLabel(_ field: XCUIElement, _ value: String) {
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: 30)
    }
    private func waitStatus(_ value: String) {
        waitLabel(app.staticTexts["review-status"], value)
    }
    private func scrollPage(up: Bool) {
        // Drag the page gutter so a multiline editor cannot consume a gesture
        // intended to reveal the next form section.
        let form = app.descendants(matching: .any).matching(identifier: "create-form").firstMatch
        let scroll = form.exists ? form : app.scrollViews.firstMatch
        var frame = scroll.exists ? scroll.frame.intersection(app.frame) : app.frame
        if frame.width < 40 || frame.height < 40 { frame = app.frame }
        let navigation = app.navigationBars.firstMatch
        let top = max(frame.minY, navigation.exists ? navigation.frame.maxY : frame.minY)
        var bottom = frame.maxY
        let submit = app.buttons["submit"]
        if submit.exists && submit.frame.minY > top { bottom = min(bottom, submit.frame.minY) }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        let height = bottom - top
        guard height > 40 else { if up { app.swipeUp() } else { app.swipeDown() }; return }
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let x = frame.maxX - 5 - app.frame.minX
        let high = top + height * 0.15 - app.frame.minY
        let low = bottom - height * 0.15 - app.frame.minY
        let start = origin.withOffset(CGVector(dx: x, dy: up ? low : high))
        let end = origin.withOffset(CGVector(dx: x, dy: up ? high : low))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func tap(_ element: XCUIElement) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { break }
            scrollPage(up: false)
        }
        for _ in 0..<16 {
            if element.exists && element.isHittable { break }
            scrollPage(up: true)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 15), "Missing control: \(element.identifier)")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        for _ in 0..<8 {
            if element.isHittable { break }
            scrollPage(up: true)
        }
        XCTAssertTrue(element.isHittable, "Control is not reachable: \(element.identifier)")
        element.tap()
    }
    private func dismissKeyboard() {
        let button = app.buttons["keyboard-dismiss"]
        if button.waitForExistence(timeout: 2), button.isHittable { button.tap() }
    }
    private func waitSaved() {
        let label = app.staticTexts["save-state"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", "输入已保存"), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed,
            "Restart only after the latest input has been acknowledged as saved")
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func request(_ path: String, body: [String: Any]? = nil, key: String = UUID().uuidString) throws -> Any {
        var req = URLRequest(url: URL(string: "http://localhost:8765/api" + path)!)
        req.timeoutInterval = 15
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        let done = expectation(description: "HTTP fixture")
        let result = FixtureResponse()
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                result.set(nil, NSError(domain: "FixtureHTTP", code: response.statusCode))
            } else { result.set(data, error) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        let (payload, failure) = result.get()
        if let failure { throw failure }
        return try JSONSerialization.jsonObject(with: XCTUnwrap(payload))
    }
    private func object(_ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        try XCTUnwrap(request(path, body: body) as? [String: Any])
    }
    func testSystemDocumentPickerCancellationPreservesDraft() throws {
        tap(app.buttons["new-review"])
        let field = app.textViews["design"]
        tap(field)
        field.typeText("保留这份订单设计，超时后先查询状态。")
        dismissKeyboard()
        let original = field.value as? String
        tap(app.buttons["import-document"])
        if app.buttons["选择文件"].waitForExistence(timeout: 2) { tap(app.buttons["选择文件"]) }
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "The native document picker must be presented")
        let cancel = picker.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "取消", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20))
        shot("documents-system-picker")
        cancel.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, original)
        shot("documents-picker-cancel")
    }

    func testSavedReportAndCitationCanBeReadAndExportedAfterRelaunch() throws {
        let title = "Offline " + String(UUID().uuidString.prefix(8))
        let created = try object("/reviews", body: [
            "mode": "scripted", "title": title, "design": String(repeating: "超时后先查询状态，再决定是否重试。", count: 12),
            "check_ids": ["CON-01"], "workbench_record_id": "ios-offline-ui"
        ])
        let id = try XCTUnwrap(created["id"] as? String)
        tap(app.buttons["refresh"])
        tap(app.buttons["review:" + id])
        waitStatus("已完成")
        app.terminate()
        app.launch()
        tap(app.buttons["saved-library"])
        tap(app.buttons["review:" + id])
        waitStatus("已完成")
        XCTAssertTrue(app.staticTexts["缓存快照 · 刷新以核对最新状态"].exists)
        tap(app.buttons["source:CON-01:0"])
        XCTAssertTrue(app.staticTexts["source-location"].waitForExistence(timeout: 10))
        shot("documents-offline-source")
        tap(app.buttons["back"])
        tap(app.buttons["export"])
        XCTAssertTrue(app.staticTexts["export-title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["share-report"].exists)
        shot("documents-offline-export")
    }

    func testLayoutKeepsDraftAndSubmitReachableAfterRotation() throws {
        let title = "Layout " + String(UUID().uuidString.prefix(8))
        let designText = "Order API checks payment status before retrying a failed request."
        tap(app.buttons["new-review"])
        let titleField = app.textFields["review-title"]
        tap(titleField); titleField.typeText(title)
        let design = app.textViews["design"]
        tap(design); design.typeText(designText)
        shot("06-layout-keyboard")
        dismissKeyboard()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.frame.width > self.app.frame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 15), .completed)
        tap(titleField)
        XCTAssertEqual(titleField.value as? String, title)
        dismissKeyboard()
        tap(design)
        XCTAssertEqual(design.value as? String, designText)
        dismissKeyboard()
        tap(app.buttons["submit"])
        waitStatus("等待助手")
        shot("07-layout-landscape")
        let rows = try XCTUnwrap(request("/reviews") as? [[String: Any]])
        XCTAssertEqual(rows.filter { $0["title"] as? String == title }.count, 1)
        let form = app.scrollViews["detail-scroll"]
        if app.frame.width > 900 {
            XCTAssertTrue(form.frame.width <= 841, "Tablet reports must retain a readable content width")
        }
    }
    func testNativeCreateRestoreClarifyReadSourceAndExport() throws {
        let title = "iOS UI " + String(UUID().uuidString.prefix(8))
        tap(app.buttons["new-review"])
        let titleField = app.textFields["review-title"]
        titleField.tap(); titleField.typeText(title)
        let design = app.textViews["design"]
        design.tap(); design.typeText("Order API retries payment on timeout without checking payment status.")
        dismissKeyboard()
        waitSaved()
        app.terminate(); app.launch()
        tap(app.buttons["new-review"])
        XCTAssertEqual(app.textFields["review-title"].value as? String, title)
        tap(app.buttons["离线模拟"])
        dismissKeyboard()
        tap(app.buttons["submit"])
        waitStatus("等待补充")
        shot("01-clarification")
        let rows = try XCTUnwrap(request("/reviews") as? [[String: Any]])
        let matches = rows.filter { $0["title"] as? String == title }
        XCTAssertEqual(matches.count, 1)
        let id = try XCTUnwrap(matches.first?["id"] as? String)
        let answer = "Query payment status before retrying a confirmed failure."
        let input = app.textViews["answer:q1"]
        tap(input); input.typeText(answer)
        dismissKeyboard()
        waitSaved()
        app.terminate(); app.launch()
        tap(app.buttons["review:" + id])
        XCTAssertTrue(app.textViews["answer:q1"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textViews["answer:q1"].value as? String, answer)
        tap(app.buttons["answer-submit"])
        waitStatus("已完成")
        shot("02-report")
        tap(app.buttons["source:CON-01:0"])
        XCTAssertTrue(app.staticTexts["source-title"].waitForExistence(timeout: 15))
        shot("03-source")
        tap(app.buttons["back"])
        tap(app.buttons["export"])
        XCTAssertTrue(app.staticTexts["export-title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["share-report"].exists)
        shot("04-export")
        let saved = try object("/reviews/" + id)
        XCTAssertEqual(saved["status"] as? String, "completed")
        XCTAssertEqual((saved["answers"] as? [String: String])?["q1"], answer)
    }
    func testRecordedModelReviewContinuesOnPhone() throws {
        tap(app.buttons["check-connection"])
        // XCTest idling does not wait for the asynchronous configuration request.
        waitLabel(app.staticTexts["connection-status"], "工作台已连接")
        XCTAssertEqual(app.staticTexts["connection-status"].label, "工作台已连接")
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mobile-review", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let title = "iOS model replay " + String(UUID().uuidString.prefix(8))
        let created = try object("/reviews", body: ["title": title,
            "design": try XCTUnwrap(fixture["design"]), "mode": "mcp",
            "check_ids": try XCTUnwrap(fixture["check_ids"]), "workbench_record_id": "recorded-model-fixture"])
        let id = try XCTUnwrap(created["id"] as? String)
        func submitRecorded(_ name: String) throws {
            let context = try object("/reviews/" + id + "/context")
            _ = try object("/reviews/" + id + "/model-output", body: [
                "revision": try XCTUnwrap(context["revision"]), "input_sha256": try XCTUnwrap(context["input_sha256"]),
                "output": try XCTUnwrap(fixture[name])])
        }
        try submitRecorded("questions")
        tap(app.buttons["refresh"])
        tap(app.buttons["review:" + id])
        let answers = try XCTUnwrap(fixture["answers"] as? [String: String])
        for key in answers.keys.sorted() {
            let input = app.textViews["answer:" + key]
            tap(input); input.typeText(try XCTUnwrap(answers[key]))
            dismissKeyboard()
        }
        tap(app.buttons["answer-submit"])
        waitStatus("等待助手")
        tap(app.buttons["copy-assistant-prompt"])
        XCTAssertTrue(app.buttons["copy-assistant-prompt"].label.contains("指令已复制"))
        let latest = try object("/reviews/" + id)
        XCTAssertEqual(latest["answers"] as? [String: String], answers)
        try submitRecorded("report")
        waitStatus("已完成")
        let report = try XCTUnwrap(fixture["report"] as? [String: Any])
        XCTAssertEqual(app.staticTexts["report-summary"].label, report["summary"] as? String)
        shot("05-cross-device")
        tap(app.buttons["export"])
        XCTAssertTrue(app.staticTexts["export-title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["share-report"].exists)
    }
}
