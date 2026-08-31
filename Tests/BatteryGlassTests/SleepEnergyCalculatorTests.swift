import Foundation
import XCTest
@testable import BatteryGlass

final class SleepEnergyCalculatorTests: XCTestCase {
    func testDischargingSleepEnergyUsesCapacityDelta() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 11.5,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: nil
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 1000 mAh × (12 + 11.5) / 2 V = 11750 mWh = 0.01175 kWh
        XCTAssertEqual(segment.energyKWh, 0.01175, accuracy: 0.0000001)
        XCTAssertEqual(segment.averagePowerW ?? 0, 11.75, accuracy: 0.0001)
        XCTAssertEqual(segment.mode, .discharging)
    }

    func testChargingSleepEnergyAddsChargeAndMaintenance() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 3000,
            voltageBeforeV: 12.4,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 12:00:00"),
            capacityAfterMAh: 6000,
            voltageAfterV: 12.6,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 2.0
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 充入：3000 mAh × 12.5 V = 37500 mWh = 0.0375 kWh
        // 维持：2 W × 7200 s = 14400 W·s = 0.004 kWh
        XCTAssertEqual(segment.energyKWh, 0.0415, accuracy: 0.0000001)
        XCTAssertEqual(segment.averagePowerW ?? 0, 20.75, accuracy: 0.0001)
        XCTAssertEqual(segment.mode, .charging)
    }

    func testPluggedIdleSleepUsesMaintenanceOnly() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12.6,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12.6,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 1.5
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 无电量变化，仅维持功耗：1.5 W × 3600 s = 5400 W·s = 0.0015 kWh
        XCTAssertEqual(segment.energyKWh, 0.0015, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .pluggedIdle)
    }

    func testNegativeCapacityDeltaYieldsNil() {
        // 放电场景电量反而增加（读数噪声）：clamp 到 0 后无能量，不生成区间。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 4000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: nil
        )

        XCTAssertNil(SleepEnergyCalculator.segment(from: input))
    }

    func testShortSleepIsIgnored() {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 10:00:30"),
            capacityAfterMAh: 4800,
            voltageAfterV: 12,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: nil
        )

        XCTAssertNil(SleepEnergyCalculator.segment(from: input))
    }

    func testDischargingIgnoresMaintenanceSample() throws {
        // 电池供电时不插电，即使唤醒后采样到直供也不应计入。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: 30
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        XCTAssertEqual(segment.energyKWh, 1000 * 12 / 1_000_000, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .discharging)
    }

    func testSleepChargedThenUnpluggedAtWakeUsesChargingEnergy() throws {
        // 睡前插电（睡眠期间充电）、唤醒时拔电：按睡眠前供电状态归为充电待机，
        // 能量 = 睡眠期间充入电量；唤醒后已拔电，无直供样本，维持功耗按 0 计。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 3000,
            voltageBeforeV: 12.4,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 12:00:00"),
            capacityAfterMAh: 6000,
            voltageAfterV: 12.6,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: nil
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 充入：3000 mAh × 12.5 V = 37500 mWh = 0.0375 kWh；维持功耗 0
        XCTAssertEqual(segment.energyKWh, 0.0375, accuracy: 0.0000001)
        XCTAssertEqual(segment.averagePowerW ?? 0, 18.75, accuracy: 0.0001)
        XCTAssertEqual(segment.mode, .charging)
    }

    func testSleepDischargingThenPluggedInAtWakeDiscardsSegment() {
        // 睡前未插电（睡眠期间电池放电）、唤醒后插上充电：唤醒后充电使容量回升，
        // 睡眠期间的放电量被掩盖无法准确测得，钳为 0 后不生成区间（保守丢弃）。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 4000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12.4,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 2.0
        )

        XCTAssertNil(SleepEnergyCalculator.segment(from: input))
    }

    func testDailyEnergySplitAcrossMidnight() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 23:00:00")
        let end = date("2026-08-28 01:00:00")

        // 总时长 2 小时，前 1 小时在 27 日、后 1 小时在 28 日，能量按 1:1 拆分。
        let split = SleepEnergyCalculator.dailyEnergySplit(
            energyKWh: 0.02,
            from: start,
            to: end,
            calendar: calendar
        )

        XCTAssertEqual(split["2026-08-27"] ?? 0, 0.01, accuracy: 0.0000001)
        XCTAssertEqual(split["2026-08-28"] ?? 0, 0.01, accuracy: 0.0000001)
    }

    func testDailyEnergySplitWithinSingleDay() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let end = date("2026-08-27 11:00:00")

        let split = SleepEnergyCalculator.dailyEnergySplit(
            energyKWh: 0.015,
            from: start,
            to: end,
            calendar: calendar
        )

        XCTAssertEqual(split, ["2026-08-27": 0.015])
    }

    func testDailyEnergySplitIgnoresInvalidEnergy() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")

        XCTAssertTrue(
            SleepEnergyCalculator.dailyEnergySplit(energyKWh: -1, from: start, to: start.addingTimeInterval(3600), calendar: calendar).isEmpty
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }
}
