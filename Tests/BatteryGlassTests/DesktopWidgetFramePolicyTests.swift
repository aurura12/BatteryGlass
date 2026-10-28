import AppKit
import XCTest
@testable import BatteryGlass

final class DesktopWidgetFramePolicyTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)

    func testRestoredFrameRequiresVisibleScreenIntersection() {
        let rect = NSRect(x: 100, y: 100, width: 236, height: 132)

        XCTAssertEqual(
            DesktopWidgetFramePolicy.restoredFrame(saved: NSStringFromRect(rect), screenFrames: [screen]),
            rect
        )
        XCTAssertNil(
            DesktopWidgetFramePolicy.restoredFrame(
                saved: NSStringFromRect(NSRect(x: 3_000, y: 3_000, width: 236, height: 132)),
                screenFrames: [screen]
            ),
            "落在屏幕外的旧位置不应恢复"
        )
        XCTAssertNil(DesktopWidgetFramePolicy.restoredFrame(saved: "", screenFrames: [screen]))
        XCTAssertNil(DesktopWidgetFramePolicy.restoredFrame(saved: "not a rect", screenFrames: [screen]))
    }

    func testDefaultFrameAnchorsToTopRightOfVisibleArea() {
        let frame = DesktopWidgetFramePolicy.defaultFrame(
            size: CGSize(width: 236, height: 132),
            visibleFrame: screen
        )

        XCTAssertEqual(frame.maxX, screen.maxX - 24)
        XCTAssertEqual(frame.maxY, screen.maxY - 72)
        XCTAssertEqual(frame.size, CGSize(width: 236, height: 132))
    }
}
