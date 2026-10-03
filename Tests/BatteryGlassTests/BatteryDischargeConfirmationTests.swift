import Foundation
import XCTest
@testable import BatteryGlass

/// 插电同时放电的确认规则：进入门槛/样本数、滞回维持、状态切换重置。
final class BatteryDischargeConfirmationTests: XCTestCase {
    private func feed(
        _ confirmation: inout BatteryDischargeConfirmation,
        state: PowerState,
        powerW: Double,
        samples: Int
    ) -> Bool {
        var result = false
        for _ in 0..<samples {
            result = confirmation.update(
                adapterConnected: true,
                state: state,
                batteryPowerW: powerW
            )
        }
        return result
    }

    func testPluggedInConfirmsAfterTwoSamples() {
        var confirmation = BatteryDischargeConfirmation()

        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: -5, samples: 1))
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -5, samples: 1))
    }

    func testChargingRequiresSixSamples() {
        var confirmation = BatteryDischargeConfirmation()

        XCTAssertFalse(feed(&confirmation, state: .charging, powerW: -5, samples: 5))
        XCTAssertTrue(feed(&confirmation, state: .charging, powerW: -5, samples: 1))
    }

    func testReadingBetweenNoiseFloorAndEnterThresholdNeverConfirms() {
        var confirmation = BatteryDischargeConfirmation()

        // -0.05 W 高于噪声下限但不到进入门槛（0.1 W），只算噪声，长期维持也不确认。
        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: -0.05, samples: 20))
    }

    func testNoiseLevelReadingNeverConfirms() {
        var confirmation = BatteryDischargeConfirmation()

        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: -0.005, samples: 20))
    }

    func testConfirmedFlagHoldsWhileReadingStaysDischarging() {
        var confirmation = BatteryDischargeConfirmation()
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -2, samples: 2))

        // 滞回：确认后读数回落到噪声下限之上仍维持，避免面板在「电池放电 / 给电池 0.0 W」
        // 之间抖动，也避免能耗里反复摘掉电池贡献。
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -0.05, samples: 5))
    }

    func testConfirmedFlagClearsWhenBatteryStopsDischarging() {
        var confirmation = BatteryDischargeConfirmation()
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -2, samples: 2))

        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: 0, samples: 1))
        // 清零后必须重新累计两次，不能沿用旧计数。
        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: -2, samples: 1))
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -2, samples: 1))
    }

    func testStateChangeResetsConsecutiveSamples() {
        var confirmation = BatteryDischargeConfirmation()

        // 充电中攒到 5 个（差 1 个才够），此时状态切到已接通电源：
        // 已接通电源只需 2 个样本，但计数必须重置，否则会立刻确认。
        XCTAssertFalse(feed(&confirmation, state: .charging, powerW: -5, samples: 5))
        XCTAssertFalse(feed(&confirmation, state: .pluggedIn, powerW: -5, samples: 1))
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -5, samples: 1))
    }

    func testUnpluggingClearsConfirmation() {
        var confirmation = BatteryDischargeConfirmation()
        XCTAssertTrue(feed(&confirmation, state: .charging, powerW: -5, samples: 6))

        XCTAssertFalse(
            confirmation.update(adapterConnected: false, state: .discharging, batteryPowerW: -20)
        )
        XCTAssertFalse(
            confirmation.update(adapterConnected: true, state: .charging, batteryPowerW: -5)
        )
    }

    func testDischargingStateIsNotPluggedDischarge() {
        var confirmation = BatteryDischargeConfirmation()

        // 状态本来就是电池供电时不算「插电同时放电」，能耗走上「仅电池放电」那一支。
        XCTAssertFalse(feed(&confirmation, state: .discharging, powerW: -20, samples: 10))
    }

    func testNonFiniteReadingResetsConfirmation() {
        var confirmation = BatteryDischargeConfirmation()
        XCTAssertTrue(feed(&confirmation, state: .pluggedIn, powerW: -2, samples: 2))

        XCTAssertFalse(
            confirmation.update(adapterConnected: true, state: .pluggedIn, batteryPowerW: .nan)
        )
    }
}
