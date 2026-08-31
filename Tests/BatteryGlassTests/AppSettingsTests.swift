import Foundation
import XCTest
@testable import BatteryGlass

@MainActor
final class AppSettingsTests: XCTestCase {
    func testThresholdIsClampedToSliderRangeWhenLoadingStoredValue() {
        let suiteName = "BatteryGlassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(5, forKey: "lowBatteryThreshold")
        XCTAssertEqual(AppSettings(defaults: defaults).lowBatteryThreshold, 10)

        defaults.set(80, forKey: "lowBatteryThreshold")
        XCTAssertEqual(AppSettings(defaults: defaults).lowBatteryThreshold, 50)

        defaults.set(30, forKey: "lowBatteryThreshold")
        XCTAssertEqual(AppSettings(defaults: defaults).lowBatteryThreshold, 30)
    }

    func testDeniedNotificationPermissionDisablesSetting() {
        XCTAssertFalse(
            NotificationPermissionPolicy.settingValue(afterAuthorization: false)
        )
        XCTAssertTrue(
            NotificationPermissionPolicy.settingValue(afterAuthorization: true)
        )
    }
}
