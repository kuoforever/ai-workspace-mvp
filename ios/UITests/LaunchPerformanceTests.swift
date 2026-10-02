import XCTest

final class LaunchPerformanceTests: XCTestCase {
    func testColdApplicationLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            app.terminate()
        }
    }
}
