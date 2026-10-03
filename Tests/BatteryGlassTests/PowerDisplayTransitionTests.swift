import Foundation
import XCTest
@testable import BatteryGlass

final class PowerDisplayTransitionTests: XCTestCase {
    private func sample(
        at seconds: TimeInterval,
        connected: Bool,
        state: PowerState,
        powerW: Double,
        inputW: Double? = nil
    ) -> BatterySnapshot {
        var snapshot = BatterySnapshot(timestamp: Date(timeIntervalSince1970: seconds))
        snapshot.isPresent = true
        snapshot.adapterConnected = connected
        snapshot.state = state
        snapshot.voltage = 12
        snapshot.current = powerW / 12
        snapshot.adapterInputPowerW = inputW
        return snapshot
    }

    func testInsertionKeepsRepeatedCachedDischargeReadingsHiddenUntilChargeArrives() {
        var transition = PowerDisplayTransition()
        let before = sample(at: 0, connected: false, state: .discharging, powerW: -23.1)
        XCTAssertEqual(transition.update(snapshot: before, batteryUpdateTime: 100), .ready)

        // 回放本机诊断中的插电窗口：-14.9 W 重复近 60 秒，充电与输入读数随后一起到达。
        for second in 1...60 {
            var plugged = sample(at: Double(second), connected: true, state: .pluggedIn, powerW: -14.9)
            plugged.isCharged = true
            plugged.batteryDischargingWhilePlugged = second > 1
            plugged.powerDisplayStatus = transition.update(snapshot: plugged, batteryUpdateTime: 101)
            XCTAssertEqual(plugged.powerDisplayStatus, .updating)
            XCTAssertEqual(plugged.displayState, .pluggedIn)
            XCTAssertEqual(plugged.displayStatusText, "已接通电源 · 功率更新中")
            XCTAssertEqual(plugged.displayPowerText, "更新中")
        }

        var charging = sample(at: 61, connected: true, state: .charging, powerW: 18.6, inputW: 36.5)
        charging.powerDisplayStatus = transition.update(snapshot: charging, batteryUpdateTime: 161)
        XCTAssertEqual(charging.powerDisplayStatus, .ready)
        XCTAssertEqual(charging.displayStatusText, "正在充电")
        XCTAssertEqual(charging.displayPowerText, "36.5 W")
    }

    func testChargingFlagAloneDoesNotExposeOldNegativeBatteryReading() {
        var transition = PowerDisplayTransition()
        let plugged = sample(at: 0, connected: true, state: .pluggedIn, powerW: -14.9)
        XCTAssertEqual(transition.update(snapshot: plugged, batteryUpdateTime: 100), .updating)

        let charging = sample(at: 1, connected: true, state: .charging, powerW: -14.9)
        XCTAssertEqual(transition.update(snapshot: charging, batteryUpdateTime: 100), .updating)
    }

    func testAdapterInputAloneWaitsForBatteryUpdateWhenUpdateTimeIsAvailable() {
        var transition = PowerDisplayTransition()
        let plugged = sample(at: 0, connected: true, state: .pluggedIn, powerW: -14.9)
        _ = transition.update(snapshot: plugged, batteryUpdateTime: 100)

        let partial = sample(at: 1, connected: true, state: .pluggedIn, powerW: -14.9, inputW: 40)
        XCTAssertEqual(transition.update(snapshot: partial, batteryUpdateTime: 100), .updating)
        XCTAssertEqual(transition.update(snapshot: partial, batteryUpdateTime: 101), .ready)
    }

    func testFreshNegativeReadingRestoresRealMixedSupply() {
        var transition = PowerDisplayTransition()
        let before = sample(at: 0, connected: false, state: .discharging, powerW: -20)
        _ = transition.update(snapshot: before, batteryUpdateTime: 100)

        let mixed = sample(at: 1, connected: true, state: .pluggedIn, powerW: -5, inputW: 30)
        XCTAssertEqual(transition.update(snapshot: mixed, batteryUpdateTime: 101), .updating)
        // 数值完全相同但电量计已实际更新，也是真实且稳定的混合供电读数。
        XCTAssertEqual(transition.update(snapshot: mixed, batteryUpdateTime: 102), .ready)
    }

    func testFullBatteryStopsUpdatingWithoutBeingForcedIntoChargingState() {
        var transition = PowerDisplayTransition()
        let plugged = sample(at: 0, connected: true, state: .pluggedIn, powerW: -14.9)
        _ = transition.update(snapshot: plugged, batteryUpdateTime: 100)

        var full = sample(at: 1, connected: true, state: .pluggedIn, powerW: 0, inputW: 16)
        full.isCharged = true
        full.powerDisplayStatus = transition.update(snapshot: full, batteryUpdateTime: 101)
        XCTAssertEqual(full.powerDisplayStatus, .ready)
        XCTAssertEqual(full.displayState, .pluggedIn)
        XCTAssertEqual(full.displayStatusText, "已接通电源 · 电池已充满")
    }

    func testAlreadyCoherentChargingReadingAppearsImmediatelyOnInsertion() {
        var transition = PowerDisplayTransition()
        _ = transition.update(
            snapshot: sample(at: 0, connected: false, state: .discharging, powerW: -20),
            batteryUpdateTime: nil
        )
        XCTAssertEqual(transition.update(
            snapshot: sample(at: 1, connected: true, state: .charging, powerW: 18, inputW: 36),
            batteryUpdateTime: nil
        ), .ready)
    }

    func testUnpluggingHidesOldChargeUntilDischargeReadingArrives() {
        var transition = PowerDisplayTransition()
        _ = transition.update(
            snapshot: sample(at: 0, connected: true, state: .charging, powerW: 18, inputW: 36),
            batteryUpdateTime: 100
        )
        var unplugged = sample(at: 1, connected: false, state: .discharging, powerW: 18)
        unplugged.powerDisplayStatus = transition.update(snapshot: unplugged, batteryUpdateTime: 100)
        XCTAssertEqual(unplugged.powerDisplayStatus, .updating)
        XCTAssertEqual(unplugged.displayStatusText, "电池供电 · 功率更新中")

        let fresh = sample(at: 2, connected: false, state: .discharging, powerW: -20)
        XCTAssertEqual(transition.update(snapshot: fresh, batteryUpdateTime: 101), .ready)
    }

    func testTimeoutShowsMissingDataAndStillRecoversWhenTelemetryArrives() {
        var transition = PowerDisplayTransition()
        _ = transition.update(
            snapshot: sample(at: 0, connected: true, state: .pluggedIn, powerW: -14.9),
            batteryUpdateTime: 100
        )
        var late = sample(at: 90, connected: true, state: .pluggedIn, powerW: -14.9)
        late.powerDisplayStatus = transition.update(snapshot: late, batteryUpdateTime: 100)
        XCTAssertEqual(late.powerDisplayStatus, .unavailable)
        XCTAssertEqual(late.displayPowerText, "--")
        XCTAssertEqual(late.displayStatusText, "已接通电源 · 暂无有效功率数据")

        XCTAssertEqual(transition.update(
            snapshot: sample(at: 120, connected: true, state: .charging, powerW: 18, inputW: 36),
            batteryUpdateTime: 220
        ), .ready)
    }

    func testRapidReplugStartsANewWaitWindow() {
        var transition = PowerDisplayTransition()
        _ = transition.update(
            snapshot: sample(at: 0, connected: true, state: .pluggedIn, powerW: -14.9),
            batteryUpdateTime: 100
        )
        _ = transition.update(
            snapshot: sample(at: 89, connected: false, state: .discharging, powerW: -20),
            batteryUpdateTime: 100
        )
        let replugged = sample(at: 91, connected: true, state: .pluggedIn, powerW: -20)
        XCTAssertEqual(transition.update(snapshot: replugged, batteryUpdateTime: 100), .updating)
    }

    func testFreshAdapterInputCanResolveMixedSupplyWithoutAnUpdateTimestamp() {
        var transition = PowerDisplayTransition()
        _ = transition.update(
            snapshot: sample(at: 0, connected: true, state: .pluggedIn, powerW: -5),
            batteryUpdateTime: nil
        )
        XCTAssertEqual(transition.update(
            snapshot: sample(at: 1, connected: true, state: .pluggedIn, powerW: -5, inputW: 30),
            batteryUpdateTime: nil
        ), .ready)
    }

    func testInvalidUpdateTimestampDoesNotReleaseCachedReading() {
        var transition = PowerDisplayTransition()
        let plugged = sample(at: 0, connected: true, state: .pluggedIn, powerW: -5)
        _ = transition.update(snapshot: plugged, batteryUpdateTime: nil)
        XCTAssertEqual(transition.update(snapshot: plugged, batteryUpdateTime: .nan), .updating)
        XCTAssertEqual(transition.update(snapshot: plugged, batteryUpdateTime: 0), .updating)
    }

    func testDisplayTransitionPreservesPowerAccountingAndSuppressesOldTimeEstimate() {
        var snapshot = sample(at: 0, connected: true, state: .charging, powerW: -5, inputW: 30)
        snapshot.batteryDischargingWhilePlugged = true
        snapshot.timeRemaining = 600
        let consumptionBefore = snapshot.consumptionPowerW

        snapshot.powerDisplayStatus = .updating
        XCTAssertEqual(snapshot.displayState, .pluggedIn)
        XCTAssertNil(snapshot.displayTimeRemaining)
        XCTAssertEqual(snapshot.consumptionPowerW, consumptionBefore)
        XCTAssertEqual(PowerSample(snapshot: snapshot)?.power, consumptionBefore)
        XCTAssertEqual(snapshot.power, -5)
    }
}
