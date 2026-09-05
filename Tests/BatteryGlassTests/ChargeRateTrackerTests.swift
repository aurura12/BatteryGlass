import Foundation
import XCTest
@testable import BatteryGlass

/// ChargeRateTracker：充电速率滚动追踪（仅充电态记录爬升点 → 首尾斜率）。
///
/// 关键设计：percent 是 0-100 离散阶跃值，用「滑窗 + 首尾斜率」而非最小二乘，
/// 并要求首尾跨距与斜率上限过滤 1% 单步噪声/唤醒补跳。
final class ChargeRateTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - 记录规则

    func testRecordsOnlyClimbingPercentsWhileCharging() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 50, at: date(30), isCharging: true)   // 相等 → 跳过
        tracker.record(percent: 51, at: date(120), isCharging: true)   // 爬升 → 记录

        XCTAssertEqual(tracker.samples.count, 2)
        XCTAssertEqual(tracker.samples.first?.percent, 50)
        XCTAssertEqual(tracker.samples.last?.percent, 51)
    }

    func testResetsWhenNotCharging() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 52, at: date(120), isCharging: true)

        tracker.record(percent: 51, at: date(130), isCharging: false)
        XCTAssertTrue(tracker.samples.isEmpty)
    }

    func testResetsWhenPercentDrops() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 52, at: date(120), isCharging: true)

        // 明显回退（>= 0.5）说明充电被打断，重新积累。
        tracker.record(percent: 50, at: date(130), isCharging: true)
        XCTAssertTrue(tracker.samples.isEmpty)
    }

    func testTopOfChargeStopsTracking() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 80, at: date(200), isCharging: true)

        // 收尾涓流（>=99.5）无外推意义，清空窗口。
        tracker.record(percent: 99.8, at: date(300), isCharging: true)
        XCTAssertTrue(tracker.samples.isEmpty)
    }

    // MARK: - 斜率

    func testSlopeUsesFirstLastWithinWindow() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 53, at: date(120), isCharging: true)

        let slope = tracker.slopePercentPerSecond(now: date(120))
        XCTAssertEqual(slope ?? 0, 3.0 / 120.0, accuracy: 0.000001)
    }

    func testSlopeUnavailableWhenSpanTooShort() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 51, at: date(10), isCharging: true)   // 跨距 10s < 90s

        XCTAssertNil(tracker.slopePercentPerSecond(now: date(10)))
    }

    func testSlopeExpiresAfterStall() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 52, at: date(550), isCharging: true)

        // 停滞超过滑窗（now=1000，窗口起点 400）：首点过期只剩一点 → 不可用。
        XCTAssertNil(tracker.slopePercentPerSecond(now: date(1000)))
    }

    func testRejectsImplausiblyHighSlope() {
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 60, at: date(100), isCharging: true)  // 10%/100s = 0.1 %/s

        XCTAssertNil(tracker.slopePercentPerSecond(now: date(100)))
    }

    func testRejectsWindowContainingWakeCatchUpJump() {
        // 回归：整体斜率落在限内（(61-50)/220 = 0.05 %/s 恰为边界）但末段
        // 10%/100s = 0.1 %/s 穿透限速（唤醒补跳），必须整窗拒绝。
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 51, at: date(120), isCharging: true)
        tracker.record(percent: 61, at: date(220), isCharging: true)

        XCTAssertNil(tracker.slopePercentPerSecond(now: date(220)))
    }

    func testAcceptsMultiStepNormalClimb() {
        // 多段正常爬升（每段都不超过限速）不应被相邻校验误伤。
        var tracker = ChargeRateTracker()
        tracker.record(percent: 50, at: date(0), isCharging: true)
        tracker.record(percent: 52, at: date(120), isCharging: true)
        tracker.record(percent: 54, at: date(240), isCharging: true)

        let slope = tracker.slopePercentPerSecond(now: date(240))
        XCTAssertEqual(slope ?? 0, 4.0 / 240.0, accuracy: 0.000001)
    }
}
