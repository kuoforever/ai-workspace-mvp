import XCTest

final class WorkspaceFlowTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["new-review"].waitForExistence(timeout: 30))
    }
    private func waitStatus(_ value: String) {
        let field = app.staticTexts["review-status"]
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        expectation(for: predicate, evaluatedWith: field)
        waitForExpectations(timeout: 30)
    }
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        for _ in 0..<8 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
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
    func testDesktopCreatedMCPReviewContinuesOnPhone() throws {
        tap(app.buttons["check-connection"])
        XCTAssertEqual(app.staticTexts["connection-status"].label, "工作台已连接")
        let title = "iOS cross-device " + String(UUID().uuidString.prefix(8))
        let created = try object("/reviews", body: ["title": title,
            "design": "订单使用请求键去重，但保留时间尚未明确。", "mode": "mcp",
            "check_ids": ["CON-01"], "workbench_record_id": "ios-desktop-fixture"])
        let id = try XCTUnwrap(created["id"] as? String)
        let context = try object("/reviews/" + id + "/context")
        _ = try object("/reviews/" + id + "/model-output", body: [
            "revision": try XCTUnwrap(created["revision"]), "input_sha256": try XCTUnwrap(context["input_sha256"]),
            "output": ["kind": "questions", "summary": "协议夹具，未调用模型", "findings": [],
                "questions": [["id": "cross-device", "check_id": "CON-01", "text": "幂等键保留多久？"]]]])
        tap(app.buttons["refresh"])
        tap(app.buttons["review:" + id])
        let input = app.textViews["answer:cross-device"]
        tap(input); input.typeText("Seven days, then verify the business intent again.")
        dismissKeyboard()
        tap(app.buttons["answer-submit"])
        waitStatus("等待助手")
        tap(app.buttons["copy-assistant-prompt"])
        XCTAssertTrue(app.buttons["copy-assistant-prompt"].label.contains("指令已复制"))
        let latest = try object("/reviews/" + id)
        XCTAssertEqual((latest["answers"] as? [String: String])?["cross-device"], "Seven days, then verify the business intent again.")
        let updatedContext = try object("/reviews/" + id + "/context")
        let sources = try XCTUnwrap(latest["sources"] as? [String: [String: Any]])
        let quote = try XCTUnwrap(sources["CON-01"]?["text"] as? String).components(separatedBy: "\n")[0]
        _ = try object("/reviews/" + id + "/model-output", body: [
            "revision": try XCTUnwrap(latest["revision"]), "input_sha256": try XCTUnwrap(updatedContext["input_sha256"]),
            "output": ["kind": "report", "summary": "跨端协议夹具已完成；本测试未调用模型。", "questions": [],
                "findings": [["check_id": "CON-01", "verdict": "unknown", "explanation": "测试仅验证跨端状态接续。",
                    "recommendation": "真实设计仍需独立评审。", "citations": [["source_id": "CON-01", "quote": quote]]]]]])
        waitStatus("已完成")
        XCTAssertTrue(app.staticTexts["report-summary"].label.contains("跨端协议夹具已完成"))
        shot("05-cross-device")
    }
}
