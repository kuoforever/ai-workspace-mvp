import XCTest

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
    private func waitStatus(_ value: String) {
        let field = app.staticTexts["review-status"]
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: 30)
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
        if submit.exists { bottom = min(bottom, submit.frame.minY) }
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
        var payload: Data?
        var failure: Error?
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                failure = NSError(domain: "FixtureHTTP", code: response.statusCode)
            } else { payload = data; failure = error }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        if let failure { throw failure }
        return try JSONSerialization.jsonObject(with: XCTUnwrap(payload))
    }
    private func object(_ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        try XCTUnwrap(request(path, body: body) as? [String: Any])
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
