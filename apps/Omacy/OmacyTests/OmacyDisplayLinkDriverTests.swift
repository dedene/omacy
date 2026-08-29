import XCTest
@testable import Omacy

@MainActor
final class OmacyDisplayLinkDriverTests: XCTestCase {
    func testRetargetBeforeStartRemainsStopped() {
        let driver = OmacyDisplayLinkDriver()
        driver.retarget(for: NSView(frame: .zero), limitsFrameRate: false)
        XCTAssertFalse(driver.isRunning)
    }

    func testStopIsIdempotent() {
        let driver = OmacyDisplayLinkDriver()
        driver.stop()
        driver.stop()
        XCTAssertFalse(driver.isRunning)
    }

    func testStartAndRetargetRecreateLinkAndPreserveFrameRateMode() {
        let driver = OmacyDisplayLinkDriver()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        driver.start(for: view, limitsFrameRate: true, tick: { _ in }, stop: {})
        let firstGeneration = driver.generation
        XCTAssertTrue(driver.isRunning)
        XCTAssertTrue(driver.limitsFrameRate)

        driver.retarget(for: view, limitsFrameRate: false)
        XCTAssertGreaterThan(driver.generation, firstGeneration)
        XCTAssertTrue(driver.isRunning)
        XCTAssertFalse(driver.limitsFrameRate)
        driver.stop()
    }

    func testWillStopNotificationForwardsToStopHandler() {
        let driver = OmacyDisplayLinkDriver()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var stopped = false
        driver.start(for: view, limitsFrameRate: false, tick: { _ in }, stop: { stopped = true })

        NotificationCenter.default.post(name: Notification.Name("com.apple.screensaver.willstop"), object: nil)

        XCTAssertTrue(stopped)
        driver.stop()
    }
}
