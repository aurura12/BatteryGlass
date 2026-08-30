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

        // 放电时 SystemPowerIn 含电池补充的电量，不能用它覆盖系统功耗。
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

    func testDisplayPowerTextShowsDashWhenNoBatteryDetected() {
        var snapshot = BatterySnapshot()
        snapshot.state = .unknown
        snapshot.isPresent = false

        XCTAssertEqual(snapshot.displayPowerText, "--")
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
