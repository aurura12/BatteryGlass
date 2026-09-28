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
        // 前后都没插电：不是低估值，也没有边界电源变化。
        XCTAssertFalse(segment.hasUnobservedSource)
        XCTAssertNil(segment.boundaryPowerChange)
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
            maintenanceDirectPowerW: 2.0,
            maintenanceAdapterInputPowerW: 70
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
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: 1.5
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
        // 睡前插电（睡眠期间充电）、唤醒时拔电：边界电源变化，只取可观测的积分量。
        // 能量 = 睡眠期间充入电量；唤醒后已拔电，取不到直供样本也不外推
        // （插电占睡眠的比例未知）。
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

        // 充入：3000 mAh × 12.5 V = 37500 mWh = 0.0375 kWh
        XCTAssertEqual(segment.energyKWh, 0.0375, accuracy: 0.0000001)
        XCTAssertEqual(segment.averagePowerW ?? 0, 18.75, accuracy: 0.0001)
        XCTAssertEqual(segment.mode, .charging)
        XCTAssertEqual(segment.measurementMethod, .fallbackEstimate)
        XCTAssertTrue(segment.hasUnobservedSource)
        XCTAssertEqual(segment.boundaryPowerChange, .adapterToBattery)
    }

    func testSleepDischargingThenPluggedInAtWakeCountsObservableSource() throws {
        // 睡前未插电、唤醒时已插电：容量净增说明睡眠期间充过电，这段充电就是真实的
        // 插座消耗，不能丢弃。但插电占睡眠的比例未知，所以不把唤醒后的直供功率
        // （2.0 W）外推到整段，只取可观测的充入能量作为下界。
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

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 充入：1000 mAh × 12.2 V = 12200 mWh = 0.0122 kWh（不含唤醒后功率外推）
        XCTAssertEqual(segment.energyKWh, 0.0122, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .charging)
        XCTAssertEqual(segment.measurementMethod, .fallbackEstimate)
        XCTAssertTrue(segment.hasUnobservedSource)
        XCTAssertEqual(segment.boundaryPowerChange, .batteryToAdapter)
    }

    func testSourceChangedUsesWallCounterForPluggedPortion() throws {
        // 睡前未插电、唤醒时已插电，且墙上计数器可用：计数器直接测到插座侧输入。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 4000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 2.0,
            wallEnergyCounterBefore: 1_000_000,
            wallEnergyCounterAfter: 1_250_000
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        XCTAssertEqual(segment.energyKWh, 0.25, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .charging)
        XCTAssertEqual(segment.measurementMethod, .telemetryCounter)
        XCTAssertTrue(segment.hasUnobservedSource)
        XCTAssertEqual(segment.boundaryPowerChange, .batteryToAdapter)
    }

    func testSourceChangedWallCounterAlsoAddsBatteryDischarge() throws {
        // 睡前未插电、唤醒时已插电，但整段电量净降：电池净释放是独立于墙侧的另一来源，
        // 必须一并累加。注意 batteryDischargingBefore 在睡前未插电时恒为 false，
        // 若用它门控就会退化成"只记墙侧"，少记电池那部分。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: nil,
            wallEnergyCounterBefore: 1_000_000,
            wallEnergyCounterAfter: 1_250_000
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 墙上 0.25 kWh + 电池补充 1000 mAh × 12 V = 0.012 kWh
        XCTAssertEqual(segment.energyKWh, 0.262, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .discharging)
        XCTAssertEqual(segment.measurementMethod, .telemetryCounter)
        XCTAssertTrue(segment.hasUnobservedSource)
    }

    func testMirrorSleepUnpluggedAtWakeFallsBackToBatteryDischarge() throws {
        // 镜像：睡前插电、唤醒时已拔电，整段电量净降且无计数器。以前会因取不到
        // 唤醒后的直供样本而整段丢弃，现在退回到可观测的电池净放电量。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: false,
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: nil
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 1000 mAh × 12 V = 0.012 kWh
        XCTAssertEqual(segment.energyKWh, 0.012, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .discharging)
        XCTAssertEqual(segment.measurementMethod, .fallbackEstimate)
        XCTAssertTrue(segment.hasUnobservedSource)
        XCTAssertEqual(segment.boundaryPowerChange, .adapterToBattery)
    }

    func testSourceChangedDoesNotExtrapolateWakePowerAcrossSleep() throws {
        // 睡前未插电、唤醒时已插电、电量净降：插电占睡眠的比例未知，唤醒后采到的
        // 适配器输入（70 W）绝不能外推到整段睡眠，否则 1 小时就会凭空多出 0.07 kWh。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4200,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 30,
            maintenanceAdapterInputPowerW: 70
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 只取 800 mAh × 12 V = 0.0096 kWh，不含 70 W / 30 W 的任何外推。
        XCTAssertEqual(segment.energyKWh, 0.0096, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .discharging)
        XCTAssertEqual(segment.measurementMethod, .fallbackEstimate)
        XCTAssertTrue(segment.hasUnobservedSource)
    }

    func testSourceChangedWithoutObservableEnergyYieldsNil() {
        // 边界电源变化但没有可观测的积分量（电量无净变化、无计数器）时仍不生成区间，
        // 不伪造一个零功耗段。
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: false,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 2.0,
            maintenanceAdapterInputPowerW: 70
        )

        XCTAssertNil(SleepEnergyCalculator.segment(from: input))
    }

    func testPluggedDischargingSleepAddsBatteryDropToWallEnergyCounter() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: 30,
            batteryDischargingBefore: true,
            wallEnergyCounterBefore: 1_000_000,
            wallEnergyCounterAfter: 1_250_000
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        // 墙上输入 0.25 kWh + 电池补充 1000 mAh × 12 V = 0.012 kWh。
        XCTAssertEqual(segment.energyKWh, 0.262, accuracy: 0.0000001)
        XCTAssertEqual(segment.measurementMethod, .telemetryCounter)
    }

    func testPluggedDischargingSleepFallsBackToBatteryDropPlusMaintenance() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: 2,
            maintenanceAdapterInputPowerW: 30,
            batteryDischargingBefore: true
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        XCTAssertEqual(segment.energyKWh, 0.042, accuracy: 0.0000001)
        XCTAssertEqual(segment.measurementMethod, .fallbackEstimate)
    }

    func testPluggedChargeFallbackPreservesChargeGainWhenDirectSampleIsMissing() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 3000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 4000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: nil
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        XCTAssertEqual(segment.energyKWh, 0.012, accuracy: 0.0000001)
        XCTAssertEqual(segment.mode, .charging)
    }

    func testPluggedIdleWithoutAdapterSampleIsUnknown() {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: nil
        )

        XCTAssertNil(SleepEnergyCalculator.segment(from: input))
    }

    func testCalibratedCounterSegmentReportsCalibrationStatus() throws {
        let input = SleepEnergyCalculator.Input(
            sleepStart: date("2026-08-27 10:00:00"),
            capacityBeforeMAh: 5000,
            voltageBeforeV: 12,
            adapterConnectedBefore: true,
            wakeTime: date("2026-08-27 11:00:00"),
            capacityAfterMAh: 5000,
            voltageAfterV: 12,
            adapterConnectedAfter: true,
            maintenanceDirectPowerW: nil,
            maintenanceAdapterInputPowerW: nil,
            wallEnergyCalibrationFactor: 0.8,
            wallEnergyIsCalibrated: true,
            wallEnergyCounterBefore: 1_000_000,
            wallEnergyCounterAfter: 1_250_000
        )

        let segment = try XCTUnwrap(SleepEnergyCalculator.segment(from: input))

        XCTAssertEqual(segment.energyKWh, 0.2, accuracy: 0.0000001)
        XCTAssertTrue(segment.isCalibrated)
        XCTAssertFalse(segment.hasUnobservedSource)
        XCTAssertNil(segment.boundaryPowerChange)
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
