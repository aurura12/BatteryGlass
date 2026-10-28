import SwiftUI
import XCTest
@testable import BatteryGlass

final class PanelLayoutPolicyTests: XCTestCase {
    func testScrollFallbackAppliesAboveDefaultSize() {
        XCTAssertFalse(PanelLayoutPolicy.usesScrollFallback(for: .xSmall))
        XCTAssertFalse(PanelLayoutPolicy.usesScrollFallback(for: .medium))
        XCTAssertFalse(PanelLayoutPolicy.usesScrollFallback(for: .large))
        XCTAssertTrue(PanelLayoutPolicy.usesScrollFallback(for: .xLarge))
        XCTAssertTrue(PanelLayoutPolicy.usesScrollFallback(for: .xxxLarge))
    }

    func testSupportedRangeStopsBeforeAccessibilitySizes() {
        let range = PanelLayoutPolicy.supportedDynamicTypeSizes
        XCTAssertEqual(range.lowerBound, .xSmall)
        XCTAssertEqual(range.upperBound, .xxxLarge)
        XCTAssertFalse(range.contains(.accessibility1))
    }
}
