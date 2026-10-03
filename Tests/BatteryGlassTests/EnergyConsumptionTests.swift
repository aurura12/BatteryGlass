import Foundation
import XCTest
@testable import BatteryGlass

final class EnergyConsumptionTests: XCTestCase {
    func testAdapterPowerUsesTotalAdapterInput() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 96
        snapshot.systemPowerW = 70

        XCTAssertEqual(snapshot.consumptionPowerW, 96)
    }

    func testConfirmedPluggedDischargeAddsBothSourceContributions() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 80
        snapshot.voltage = 12
        snapshot.current = -2
        snapshot.batteryDischargingWhilePlugged = true

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 104, accuracy: 0.000001)
    }

    func testUnconfirmedPluggedNegativeReadingUsesAdapterOnly() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 80
        snapshot.voltage = 12
        snapshot.current = -2

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 80, accuracy: 0.000001)
    }

    func testChargingIgnoresUnconfirmedNegativeBatteryReading() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 80
        snapshot.voltage = 12
        snapshot.current = -2

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 80, accuracy: 0.000001)
    }

    func testConfirmedPluggedDischargeFallsBackToBatteryWithoutAdapterInput() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.voltage = 12
        snapshot.current = -2
        snapshot.batteryDischargingWhilePlugged = true

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 24, accuracy: 0.000001)
    }

    func testAdapterSplitUsesMeasuredInputWithoutDoubleCountingCharge() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 82
        snapshot.systemPowerW = 92
        snapshot.voltage = 12.6
        snapshot.current = 4.5

        XCTAssertEqual(snapshot.chargingPowerW ?? 0, 56.7, accuracy: 0.000001)
        XCTAssertEqual(snapshot.directSupplyPowerW ?? 0, 25.3, accuracy: 0.000001)
        XCTAssertEqual(snapshot.adapterOutputPowerW ?? 0, 82, accuracy: 0.000001)
    }

    func testAdapterSplitIsUnavailableWithoutMeasuredInput() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = true
        snapshot.systemPowerW = 92
        snapshot.voltage = 12.6
        snapshot.current = 4.5

        XCTAssertNil(snapshot.directSupplyPowerW)
        XCTAssertNil(snapshot.adapterOutputPowerW)
    }

    func testAdapterPowerIsUnavailableWithoutInputTelemetry() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.systemPowerW = 70

        XCTAssertNil(snapshot.consumptionPowerW)
    }

    func testBatteryPowerUsesPositiveDischargeMagnitude() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.voltage = 12
        snapshot.current = -2

        XCTAssertEqual(snapshot.consumptionPowerW, 24)
    }

    func testBatteryPowerWinsWhenAdapterIsConnectedButNotSupplying() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 0.27
        snapshot.voltage = 11.82
        snapshot.current = -2.781

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 11.82 * 2.781, accuracy: 0.000001)
    }

    func testSystemPowerFallsBackToElectricalDischargeWhenTelemetryIsMissing() {
        XCTAssertEqual(
            BatteryMonitor.dischargingSystemPowerW(
                telemetryBatteryPowerMW: 0,
                electricalPowerW: -24
            ) ?? 0,
            24,
            accuracy: 0.000001
        )
    }

    func testPowerSampleUsesUnifiedConsumptionPower() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true
        snapshot.adapterInputPowerW = 96
        snapshot.systemPowerW = 70

        XCTAssertEqual(PowerSample(snapshot: snapshot)?.power, 96)
    }

    func testPowerSampleIsUnavailableWithoutConsumptionSource() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true

        XCTAssertNil(PowerSample(snapshot: snapshot))
    }

    func testDailyEnergyIntegratesPowerOverTime() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 100),
            sample(at: start.addingTimeInterval(10), power: 100)
        ]

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar
        )

        XCTAssertEqual(energy[dayKey(for: start, calendar: calendar)] ?? 0, 100 * 10 / 3_600_000, accuracy: 0.000000001)
    }

    func testDailyEnergySplitsPowerAtMidnight() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 23:59:59")
        let next = date("2026-08-28 00:00:01")
        let samples = [
            sample(at: start, power: 100),
            sample(at: next, power: 100)
        ]

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar
        )

        let oneSecond = 100.0 / 3_600_000
        XCTAssertEqual(energy[dayKey(for: start, calendar: calendar)] ?? 0, oneSecond, accuracy: 0.000000001)
        XCTAssertEqual(energy[dayKey(for: next, calendar: calendar)] ?? 0, oneSecond, accuracy: 0.000000001)
    }

    func testDailyEnergyIgnoresLargeSamplingGaps() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 100),
            sample(at: start.addingTimeInterval(3600), power: 100)
        ]

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar,
            maximumGap: 60
        )

        XCTAssertTrue(energy.isEmpty)
    }

    func testDailyEnergySkipsPairCrossingShortSleepInterval() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 100),
            sample(at: start.addingTimeInterval(30), power: 100)
        ]
        let interval = SleepInterval(
            start: start.addingTimeInterval(1),
            end: start.addingTimeInterval(29)
        )

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar,
            excludedIntervals: [interval]
        )

        XCTAssertTrue(energy.isEmpty)
    }

    func testDailyEnergySkipsExactlySixtySecondSleepInterval() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 100),
            sample(at: start.addingTimeInterval(60), power: 100)
        ]
        let interval = SleepInterval(start: start, end: start.addingTimeInterval(60))

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar,
            excludedIntervals: [interval]
        )

        XCTAssertTrue(energy.isEmpty)
    }

    func testDailyEnergyKeepsPairsTouchingSleepIntervalBoundaries() {
        let calendar = utcCalendar()
        let start = date("2026-08-27 10:00:00")
        let samples = [
            sample(at: start, power: 100),
            sample(at: start.addingTimeInterval(10), power: 100),
            sample(at: start.addingTimeInterval(20), power: 100),
            sample(at: start.addingTimeInterval(30), power: 100)
        ]
        let interval = SleepInterval(
            start: start.addingTimeInterval(10),
            end: start.addingTimeInterval(20)
        )

        let energy = EnergyCalculator.dailyEnergyKWh(
            samples: samples,
            calendar: calendar,
            excludedIntervals: [interval]
        )

        let expected = 2.0 * 100 * 10 / 3_600_000
        XCTAssertEqual(energy[dayKey(for: start, calendar: calendar)] ?? 0, expected, accuracy: 0.000000001)
    }

    func testDisplayPowerPrefersAdapterInputWhenPluggedIn() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterInputPowerW = 82
        snapshot.systemPowerW = 36
        snapshot.voltage = 12.6
        snapshot.current = 3.6

        XCTAssertEqual(snapshot.displayPower, 82, accuracy: 0.0001)
        XCTAssertTrue(snapshot.displayPowerText.hasPrefix("82"))
        XCTAssertFalse(snapshot.displayPowerText.contains("+"))
        XCTAssertTrue(snapshot.displayPowerText.hasSuffix("W"))
    }

    func testDisplayPowerFallsBackToSystemPowerWithoutAdapterInput() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterInputPowerW = nil
        snapshot.systemPowerW = 36
        snapshot.voltage = 12.6
        snapshot.current = 3.6

        XCTAssertEqual(snapshot.displayPower, 36, accuracy: 0.0001)
    }

    func testDisplayPowerUsesBatteryPowerWhenDischarging() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterInputPowerW = 82
        snapshot.voltage = 12
        snapshot.current = -2

        XCTAssertEqual(snapshot.displayPower, -24, accuracy: 0.0001)
        XCTAssertTrue(snapshot.displayPowerText.hasPrefix("-24"))
    }

    func testDisplayPowerFollowsConsumptionFallbackWhenGaugeFreezes() {
        // 面板必须与能耗计量一致：电量计冻结读 0 时显示系统侧回退值而不是 0.0 W。
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = false
        snapshot.voltage = 12
        snapshot.current = 0
        snapshot.systemPowerW = 26.57

        XCTAssertEqual(snapshot.displayPower, -26.57, accuracy: 0.0001)
        XCTAssertTrue(snapshot.displayPowerText.hasPrefix("-26.6"))
    }

    func testDisplayPowerKeepsRawReadingWhenEveryFallbackIsInvalid() {
        // 所有回退都失效时保持原始读数，不回退成 0。
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = false
        snapshot.voltage = 12
        snapshot.current = 8.85 / 12
        snapshot.systemPowerW = -8.85

        XCTAssertEqual(snapshot.displayPower, 8.85, accuracy: 0.0001)
    }

    // MARK: - consumptionPowerW（能耗计量口径的回退）

    func testConsumptionPowerFallsBackToSystemLoadWhenGaugeFreezesAtZero() {
        // 拔电瞬间电量计冻结读 0，但 SystemLoad 仍有效（实测 26.57 W 与拔电前一致）。
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = false
        snapshot.voltage = 12
        snapshot.current = 0
        snapshot.systemPowerW = 26.57

        XCTAssertNil(snapshot.batteryDischargePowerW)
        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 26.57, accuracy: 0.0001)
    }

    func testConsumptionPowerPrefersBatteryReadingOverSystemLoad() {
        // 电量计有效时仍以电池侧读数为准，SystemLoad 只作回退。
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.voltage = 12
        snapshot.current = -2
        snapshot.systemPowerW = 100

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 24, accuracy: 0.0001)
    }

    func testConsumptionPowerStaysNilWhenEveryReadingIsInvalid() {
        // 拔电时若电量计残留充电值、SystemLoad 也已翻负，则没有任何可信读数，
        // 必须保持 nil 让上层标记为读数缺失，不能用估计值填补。
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = false
        snapshot.voltage = 12
        snapshot.current = 8.85 / 12
        snapshot.systemPowerW = -8.85

        XCTAssertNil(snapshot.batteryDischargePowerW)
        XCTAssertNil(snapshot.consumptionPowerW)
    }

    func testConsumptionPowerCountsDischargeDuringStaleStateTransition() {
        // 适配器已拔但状态尚未切到放电（拔插瞬态）：电池读数明确指向放电时仍应计量。
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = false
        snapshot.voltage = 12
        snapshot.current = -35.23 / 12

        XCTAssertEqual(snapshot.consumptionPowerW ?? 0, 35.23, accuracy: 0.01)
    }

    func testConsumptionPowerStaysNilWhenBatteryAbsent() {
        // 状态未知且未接入适配器时不应凭空产生功率。
        var snapshot = BatterySnapshot()
        snapshot.state = .unknown
        snapshot.adapterConnected = false

        XCTAssertNil(snapshot.consumptionPowerW)
    }

    func testHistorySampleDecodesWithoutEnergyField() throws {
        let data = #"{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"power":-20,"percent":50,"cycleCount":1,"healthPercent":100}"#.data(using: .utf8)!

        let sample = try JSONDecoder().decode(HistorySample.self, from: data)

        XCTAssertNil(sample.consumptionPowerW)
    }

    // MARK: - resolvedSystemPowerW（系统功耗取值）

    func testSystemPowerIsNotAdapterInputWhileDischarging() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: true,
            state: .discharging,
            systemPowerInMW: 80_000,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -24_000,
            electricalPowerW: -24,
            previous: 80,
            previousAdapterConnected: true
        )

        // 放电时适配器输入只覆盖适配器这一路（电池补充的部分不在其中），
        // 因此不能用它覆盖系统功耗，应回退到电池放电功率。
        XCTAssertEqual(result.systemPowerW ?? 0, 24, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 80, accuracy: 0.0001)
    }

    func testSystemLoadIsPreferredWhenDischargingWhilePlugged() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 36_000,
            adapterConnected: true,
            state: .discharging,
            systemPowerInMW: 80_000,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -24_000,
            electricalPowerW: -24,
            previous: 50,
            previousAdapterConnected: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 36, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 80, accuracy: 0.0001)
    }

    func testSystemLoadIsPreferredDuringPlugInTransitionWithStaleNegativeBatteryPower() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 36_000,
            adapterConnected: true,
            state: .pluggedIn,
            systemPowerInMW: 80_000,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -24_000,
            electricalPowerW: -24,
            previous: 50,
            previousAdapterConnected: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 36, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 80, accuracy: 0.0001)
    }

    func testConfirmedHybridUsesSourceSumEvenWhenSystemLoadIsAvailable() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 28_519,
            adapterConnected: true,
            state: .charging,
            systemPowerInMW: 28_770,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -240,
            electricalPowerW: -0.24,
            previous: 28.77,
            previousAdapterConnected: true,
            batteryDischargingWhilePlugged: true
        )

        // 已确认混合供电时必须用「适配器输入 + 电池放电」（与 consumptionPowerW 同口径），
        // 不能退回 SystemLoad——它不是本应用的主指标。
        XCTAssertEqual(result.systemPowerW ?? 0, 29.01, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 28.77, accuracy: 0.0001)
    }

    func testConfirmedHybridFallsBackToSourceSumWithoutSystemLoad() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: true,
            state: .pluggedIn,
            systemPowerInMW: 28_770,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -180,
            electricalPowerW: -0.18,
            previous: 28.77,
            previousAdapterConnected: true,
            batteryDischargingWhilePlugged: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 28.95, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 28.77, accuracy: 0.0001)
    }

    func testConfirmedHybridWithoutAdapterInputUsesBatteryDischargeOnly() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: true,
            state: .charging,
            systemPowerInMW: 0,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: 0,
            electricalPowerW: -12,
            previous: 12,
            previousAdapterConnected: true,
            batteryDischargingWhilePlugged: true
        )

        // 没有适配器输入可加，只能保留可观测的电池放电，不能凭空放大。
        XCTAssertEqual(result.systemPowerW ?? 0, 12, accuracy: 0.0001)
        XCTAssertNil(result.adapterInputPowerW)
    }

    func testSystemPowerUsesAdapterInputMinusChargeWhenPlugged() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: true,
            state: .charging,
            systemPowerInMW: 80_000,
            chargingPowerW: 30,
            telemetryBatteryPowerMW: 30_000,
            electricalPowerW: 30,
            previous: 50,
            previousAdapterConnected: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 80, accuracy: 0.0001)
    }

    func testChargingElectricalPowerWinsOverConflictingNegativeTelemetry() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 83_715,
            adapterConnected: true,
            state: .charging,
            systemPowerInMW: 69_034,
            chargingPowerW: 50.809,
            telemetryBatteryPowerMW: -14_681,
            electricalPowerW: 50.809,
            previous: 50,
            previousAdapterConnected: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 18.225, accuracy: 0.0001)
        XCTAssertEqual(result.adapterInputPowerW ?? 0, 69.034, accuracy: 0.0001)
    }

    func testSystemPowerDoesNotRetainAdapterValueAfterUnplugging() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: false,
            state: .discharging,
            systemPowerInMW: 0,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: 0,
            electricalPowerW: 0,
            previous: 40,
            previousAdapterConnected: true
        )

        // 供电方式变化后不沿用旧的适配器功耗。
        XCTAssertNil(result.systemPowerW)
        XCTAssertNil(result.adapterInputPowerW)
    }

    func testSystemPowerRetainsLastValueWhenStillOnBatteryWithoutData() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: 0,
            adapterConnected: false,
            state: .discharging,
            systemPowerInMW: 0,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: 0,
            electricalPowerW: 0,
            previous: 12,
            previousAdapterConnected: false
        )

        // 供电方式未变化时允许平滑沿用上次值。
        XCTAssertEqual(result.systemPowerW ?? 0, 12, accuracy: 0.0001)
        XCTAssertNil(result.adapterInputPowerW)
    }

    func testNonFiniteSystemTelemetryIsIgnored() {
        let result = BatteryMonitor.resolvedSystemPowerW(
            systemLoadMW: .infinity,
            adapterConnected: true,
            state: .charging,
            systemPowerInMW: .nan,
            chargingPowerW: nil,
            telemetryBatteryPowerMW: -12_000,
            electricalPowerW: -12,
            previous: 9,
            previousAdapterConnected: true
        )

        XCTAssertEqual(result.systemPowerW ?? 0, 12, accuracy: 0.0001)
        XCTAssertNil(result.adapterInputPowerW)
    }

    func testDisplayPowerTextShowsDashWhenNoBatteryDetected() {
        var snapshot = BatterySnapshot()
        snapshot.state = .unknown
        snapshot.isPresent = false

        XCTAssertEqual(snapshot.displayPowerText, "--")
    }

    func testUnknownBatteryPercentTextShowsDash() {
        var snapshot = BatterySnapshot()
        snapshot.state = .unknown
        snapshot.isPresent = false

        XCTAssertEqual(snapshot.percentText, "--")
    }

    private func sample(at timestamp: Date, power: Double) -> HistorySample {
        HistorySample(
            timestamp: timestamp,
            power: 0,
            consumptionPowerW: power,
            percent: 50,
            cycleCount: 1,
            healthPercent: 100
        )
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)!
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
