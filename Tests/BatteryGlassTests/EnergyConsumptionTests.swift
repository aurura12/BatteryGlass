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

    func testHistorySampleDecodesWithoutEnergyField() throws {
        let data = #"{"id":"00000000-0000-0000-0000-000000000001","timestamp":0,"power":-20,"percent":50,"cycleCount":1,"healthPercent":100}"#.data(using: .utf8)!

        let sample = try JSONDecoder().decode(HistorySample.self, from: data)

        XCTAssertNil(sample.consumptionPowerW)
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
