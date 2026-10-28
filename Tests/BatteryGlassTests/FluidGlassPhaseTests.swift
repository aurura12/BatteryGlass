import Foundation
import XCTest
@testable import BatteryGlass

/// 流体光晕相位：只验证连续性（速度变化不能让光斑瞬移）。
final class FluidGlassPhaseTests: XCTestCase {
    func testPhaseAdvancesByElapsedTimeTimesSpeed() {
        let epoch = Date(timeIntervalSinceReferenceDate: 1_000)
        let phase = FluidGlassPhase(epoch: epoch)

        XCTAssertEqual(phase.phase(at: epoch, speed: 2), 0, accuracy: 1e-9)
        XCTAssertEqual(
            phase.phase(at: epoch.addingTimeInterval(3), speed: 2),
            6,
            accuracy: 1e-9
        )
    }

    func testSpeedChangeKeepsPhaseContinuous() {
        let epoch = Date(timeIntervalSinceReferenceDate: 1_000)
        let initial = FluidGlassPhase(epoch: epoch)
        let changeAt = epoch.addingTimeInterval(10)
        let before = initial.phase(at: changeAt, speed: 1)
        XCTAssertEqual(before, 10, accuracy: 1e-9)

        let rebased = initial.rebased(at: changeAt, from: 1)
        XCTAssertEqual(rebased.phase(at: changeAt, speed: 2), before, accuracy: 1e-9)
        XCTAssertEqual(
            rebased.phase(at: changeAt.addingTimeInterval(5), speed: 2),
            before + 10,
            accuracy: 1e-9
        )
    }

    func testRepeatedSpeedChangesStayContinuous() {
        let epoch = Date(timeIntervalSinceReferenceDate: 1_000)
        var phase = FluidGlassPhase(epoch: epoch)
        var time = epoch
        var speed = 1.0

        for nextSpeed in [1.8, 0.4, 2.0, 0.3] {
            time = time.addingTimeInterval(7)
            let before = phase.phase(at: time, speed: speed)
            phase = phase.rebased(at: time, from: speed)
            XCTAssertEqual(phase.phase(at: time, speed: nextSpeed), before, accuracy: 1e-9)
            speed = nextSpeed
        }
    }
}
