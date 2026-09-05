import Foundation
import XCTest
@testable import BatteryGlass

/// TimeRemainingEstimator 纯函数的分支防御顺序测试。
///
/// 关键回归：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值，
/// 若被误当作 mAh 传入兜底公式会产出十几秒的荒谬「充满还需」。估算器只接受
/// SmartBattery 侧真 mAh，并对结果域做 [60s, 48h] 钳制。
final class TimeRemainingEstimatorTests: XCTestCase {
    private func input(
        state: PowerState = .unknown,
        percent: Double = 50,
        isCharged: Bool = false,
        currentCapacityMAh: Double = 0,
        fullChargeCapacityMAh: Double = 0,
        currentA: Double = 0,
        systemTimeToEmpty: TimeInterval? = nil,
        systemTimeToFull: TimeInterval? = nil,
        systemEstimateSeconds: TimeInterval? = nil,
        chargePercentPerSecond: Double? = nil
    ) -> TimeRemainingEstimator.Input {
        var i = TimeRemainingEstimator.Input()
        i.state = state
        i.percent = percent
        i.isCharged = isCharged
        i.currentCapacityMAh = currentCapacityMAh
        i.fullChargeCapacityMAh = fullChargeCapacityMAh
        i.currentA = currentA
        i.systemTimeToEmpty = systemTimeToEmpty
        i.systemTimeToFull = systemTimeToFull
        i.systemEstimateSeconds = systemEstimateSeconds
        i.chargePercentPerSecond = chargePercentPerSecond
        return i
    }

    // MARK: - 充电分支

    func testChargingPrefersSystemTimeToFull() {
        let i = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 6000, fullChargeCapacityMAh: 8000, currentA: 1.2,
            systemTimeToFull: 1800, chargePercentPerSecond: 0.01
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(i) ?? 0, 1800)
    }

    func testChargingUsesPercentSlopeWhenSystemMissing() {
        let i = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 6000, fullChargeCapacityMAh: 8000, currentA: 1.2,
            chargePercentPerSecond: 0.01
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(i) ?? 0, 5000, accuracy: 0.001)
    }

    func testChargingFallsBackToTrueCapacityWhenSlopeMissing() {
        let i = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 6000, fullChargeCapacityMAh: 8000, currentA: 1.2
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(i) ?? 0, 6000, accuracy: 0.001)
    }

    func testChargingPercentNearFullReturnsNil() {
        // 即便系统估计/斜率/电流齐全，接近满或已满也不报「充满还需」。
        let nearFull = input(
            state: .charging, percent: 99.7, isCharged: false,
            currentCapacityMAh: 6700, fullChargeCapacityMAh: 8000, currentA: 1.2,
            systemTimeToFull: 120
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(nearFull))

        let full = input(
            state: .charging, percent: 100, isCharged: false,
            currentCapacityMAh: 8000, fullChargeCapacityMAh: 8000, currentA: 1.2,
            systemTimeToFull: 120
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(full))
    }

    func testChargingStopsWhenMarkedCharged() {
        // isCharged（FullyCharged）为真即使 percent 尚低也不外推，等待状态翻转。
        let i = input(
            state: .charging, percent: 88, isCharged: true,
            currentCapacityMAh: 7000, fullChargeCapacityMAh: 8000, currentA: 1.2,
            systemTimeToFull: 300
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(i))
    }

    func testChargingRejectsNonPositiveCurrentFallback() {
        // 刚插电的电流符号错位（充电态但电流为负/零）不产出估算。
        let zero = input(state: .charging, percent: 50)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(zero))

        let negative = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 6000, fullChargeCapacityMAh: 8000, currentA: -1.2
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(negative))
    }

    func testChargingFallbackNeedsFullChargeCapacity() {
        let noFull = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 6000, fullChargeCapacityMAh: 0, currentA: 1.2
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(noFull))

        // 满充容量低于当前容量（读错/状态错位）时不外推。
        let overCurrent = input(
            state: .charging, percent: 50,
            currentCapacityMAh: 8000, fullChargeCapacityMAh: 6000, currentA: 1.2
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(overCurrent))
    }

    func testNormalizedPercentCapacityNoLongerYieldsAbsurdResult() {
        // 回归：AS 上 IOPS 归一化污染值（full=100, cap=88）若误当 mAh 使用，
        // 会算出 ≈36 秒的荒谬结果，被 <60s 下界拦截为 nil。
        let normalized = input(
            state: .charging, percent: 88,
            currentCapacityMAh: 88, fullChargeCapacityMAh: 100, currentA: 1.2
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(normalized))

        // 传真 mAh（RemainingCapacity≈6726 / FccComp2≈7678）→ 缺额 952 mAh ≈ 47.6 分钟。
        let real = input(
            state: .charging, percent: 88,
            currentCapacityMAh: 6726, fullChargeCapacityMAh: 7678, currentA: 1.2
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(real) ?? 0, 2856, accuracy: 1)
    }

    // MARK: - 放电分支

    func testDischargePrefersSystemTimeToEmpty() {
        let i = input(
            state: .discharging, percent: 50,
            currentCapacityMAh: 6000, currentA: -2,
            systemTimeToEmpty: 7200, systemEstimateSeconds: 600
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(i) ?? 0, 7200)
    }

    func testDischargeUsesGlobalEstimateWhenTimeToEmptyMissing() {
        let i = input(
            state: .discharging, percent: 50,
            currentCapacityMAh: 6000, currentA: -2,
            systemEstimateSeconds: 3600
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(i) ?? 0, 3600)
    }

    func testDischargeRequiresNegativeCurrentForFallback() {
        let i = input(state: .discharging, percent: 50, currentCapacityMAh: 6000)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(i))

        let chargingCurrent = input(
            state: .discharging, percent: 50, currentCapacityMAh: 6000, currentA: 1.2
        )
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(chargingCurrent))
    }

    func testDischargeFallbackUsesTrueRemainingCapacity() {
        // 传真 mAh（RemainingCapacity）@ -0.5A → ≈ 13.45 小时。
        let real = input(
            state: .discharging, percent: 50, currentCapacityMAh: 6726, currentA: -0.5
        )
        XCTAssertEqual(TimeRemainingEstimator.estimateSeconds(real) ?? 0, 48_427.2, accuracy: 1)
    }

    // MARK: - 其它状态与防御

    func testPluggedInAndUnknownReturnNil() {
        let plugged = input(state: .pluggedIn, percent: 100, systemTimeToFull: 1800)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(plugged))

        let unknown = input(state: .unknown, percent: 0)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(unknown))
    }

    func testNonFiniteOrNonPositiveSystemEstimatesIgnored() {
        // NaN/∞/负值系统估计视为缺失，继续走真 mAh 兜底。
        for bad in [Double.nan, Double.infinity, -1, 0] {
            let i = input(
                state: .charging, percent: 50,
                currentCapacityMAh: 6000, fullChargeCapacityMAh: 8000, currentA: 1.2,
                systemTimeToFull: bad
            )
            XCTAssertEqual(
                TimeRemainingEstimator.estimateSeconds(i) ?? 0, 6000, accuracy: 0.001,
                "系统估计 \(bad) 应被视为缺失并回退到 mAh 兜底"
            )
        }
    }

    func testNonPositiveSlopeIgnored() {
        let zeroRate = input(state: .charging, percent: 50, chargePercentPerSecond: 0)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(zeroRate))

        let negativeRate = input(state: .charging, percent: 50, chargePercentPerSecond: -0.01)
        XCTAssertNil(TimeRemainingEstimator.estimateSeconds(negativeRate))
    }
}
