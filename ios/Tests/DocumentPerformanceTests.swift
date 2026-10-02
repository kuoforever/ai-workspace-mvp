import XCTest
@testable import AIWorkspace

final class DocumentPerformanceTests: XCTestCase {
    private var consumed = 0
    private var design: String {
        String(repeating: "订单使用唯一请求键，失败后查询状态。\n", count: 500).prefix(7950).description
            + String(repeating: "x", count: 50)
    }
    private func snapshot(_ id: String) -> ReviewSnapshot {
        ReviewSnapshot(id: id, revision: 3, status: "completed",
            input: ReviewInput(title: "Performance " + id, design: design),
            sources: ["input": Source(title: "Design", text: design, path: "input.md", sha256: "fixture")],
            questions: [], answers: [:],
            report: Report(summary: "Recorded fixture", findings: [
                Finding(checkID: "CON-01", verdict: "risk", explanation: "reason", recommendation: "advice",
                    citations: [Citation(sourceID: "input", quote: String(repeating: "x", count: 50))])
            ]), error: nil)
    }
    private var options: XCTMeasureOptions {
        let value = XCTMeasureOptions()
        value.iterationCount = 10
        return value
    }

    func testEightThousandCharacterImportQuoteAndExport() throws {
        let input = design
        XCTAssertEqual(input.unicodeScalars.count, 8000)
        let data = Data(input.utf8), report = snapshot("pipeline")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do {
                let imported = try DocumentImport.parse(name: "design.md", data: data)
                let excerpt = sourceExcerpt(imported.text, quote: String(repeating: "x", count: 50))
                consumed = report.markdown.utf8.count + (excerpt?.firstLine ?? 0)
            } catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertGreaterThan(consumed, 8000)
    }

    func testTwentyFullReportCacheReloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeviceStore(root: root)
        for number in 0..<20 { try store.saveReview(snapshot(String(number))) }
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            do { consumed = try DeviceStore(root: root).savedReviews().count }
            catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertEqual(consumed, 20)
    }
}
