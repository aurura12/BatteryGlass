import Foundation
import XCTest
@testable import BatteryGlass

/// TimeRemainingSmoother：估算秒值的 EMA 平滑 + 状态复位 + 上下界钳制。
///
/// 首值直通避免刚插电/开机后长时间空白；状态切换即复位，绝不把充电与放电
/// 两种含义的时间估算做平滑过渡；raw 为 nil 立即清空，不挂陈旧值。
final class TimeRemainingSmootherTests: XCTestCase {
    func testFirstRawValuePassesThrough() {
        var smoother = TimeRemainingSmoother()
        XCTAssertEqual(smoother.update(raw: 1800, state: .charging), 1800)
    }

    func testEmaConvergesTowardSustainedRaw() {
        var smoother = TimeRemainingSmoother()
        var previous = smoother.update(raw: 100, state: .charging) ?? 0
        var finalValue = previous

        for _ in 0..<20 {
            let value = smoother.update(raw: 200, state: .charging) ?? 0
            XCTAssertGreaterThan(value, previous, "EMA 应向目标单调逼近")
            XCTAssertLessThanOrEqual(value, 200, "EMA 不应越过目标")
            previous = value
            finalValue = value
        }
        // 20 tick（alpha=0.15）后应收敛到 200 - 100×(0.85^20) ≈ 196。
        XCTAssertGreaterThan(finalValue, 195)
    }

    func testNilClearsValue() {
        var smoother = TimeRemainingSmoother()
        _ = smoother.update(raw: 1800, state: .charging)
        XCTAssertNil(smoother.update(raw: nil, state: .charging))

        // 清空后下一个有效值直通，而非从旧值继续平滑。
        XCTAssertEqual(smoother.update(raw: 900, state: .charging), 900)
    }

    func testStateChangeResetsSmoothing() {
        var smoother = TimeRemainingSmoother()
        _ = smoother.update(raw: 100, state: .charging)
        _ = smoother.update(raw: 100, state: .charging)
        XCTAssertEqual(smoother.value ?? 0, 100, accuracy: 0.0001)

        // 状态切换后直接采纳新值（充放电含义不同，不做渐变）。
        XCTAssertEqual(smoother.update(raw: 3600, state: .discharging), 3600)
    }

    func testClampsOutOfRange() {
        var smoother = TimeRemainingSmoother()
        XCTAssertEqual(smoother.update(raw: 30, state: .charging), 60)
        XCTAssertEqual(smoother.update(raw: 200_000, state: .discharging), 172_800)
    }
}
