import Foundation
import IOKit.ps
import XCTest
@testable import BatteryGlass

@MainActor
final class BatteryMonitorIOPSParsingTests: XCTestCase {
    // MARK: - Power Source State → externalConnected

    func testACPowerStateMarksExternalConnected() {
        let description: [String: Any] = [
            kIOPSIsPresentKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSCurrentCapacityKey: 4200,
            kIOPSMaxCapacityKey: 5000,
        ]

        let data = BatteryMonitor.parsePowerSourceDescription(description)

        XCTAssertTrue(data.isPresent)
        XCTAssertTrue(data.externalConnected)
        XCTAssertEqual(data.percent, 84, accuracy: 0.0001)
    }

    func testBatteryPowerStateKeepsExternalDisconnected() {
        let description: [String: Any] = [
            kIOPSIsPresentKey: true,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        ]

        let data = BatteryMonitor.parsePowerSourceDescription(description)

        XCTAssertTrue(data.isPresent)
        XCTAssertFalse(data.externalConnected)
    }

    func testMissingPowerSourceStateKeepsExternalDisconnected() {
        let description: [String: Any] = [
            kIOPSIsPresentKey: true,
        ]

        let data = BatteryMonitor.parsePowerSourceDescription(description)

        XCTAssertTrue(data.isPresent)
        XCTAssertFalse(data.externalConnected)
    }

    // MARK: - 单位换算（电压 mV、电流 mA → V/A）

    func testElectricalValuesAreConvertedToVoltAndAmpere() {
        let description: [String: Any] = [
            kIOPSIsPresentKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSVoltageKey: 12600,
            kIOPSCurrentKey: -2300,
        ]

        let data = BatteryMonitor.parsePowerSourceDescription(description)

        XCTAssertEqual(data.voltage, 12.6, accuracy: 0.0001)
        XCTAssertEqual(data.current, -2.3, accuracy: 0.0001)
    }

    func testTimeRemainingKeysConvertMinutesToSeconds() {
        let description: [String: Any] = [
            kIOPSIsPresentKey: true,
            kIOPSTimeToEmptyKey: 120,
            kIOPSTimeToFullChargeKey: 45
        ]

        let data = BatteryMonitor.parsePowerSourceDescription(description)

        XCTAssertEqual(data.timeToEmpty ?? 0, 7_200, accuracy: 0.0001)
        XCTAssertEqual(data.timeToFull ?? 0, 2_700, accuracy: 0.0001)
    }

    // MARK: - IOPSPowerSourceState（供电来源枚举）

    func testACProvidingStateIsExternalPower() {
        let state = BatteryMonitor.IOPSPowerSourceState(rawIOPSValue: kIOPMACPowerKey)

        XCTAssertEqual(state, .ac)
        XCTAssertTrue(state?.isExternalPower == true)
    }

    func testUPSProvidingStateIsExternalPower() {
        let state = BatteryMonitor.IOPSPowerSourceState(rawIOPSValue: kIOPMUPSPowerKey)

        XCTAssertEqual(state, .ups)
        XCTAssertTrue(state?.isExternalPower == true)
    }

    func testBatteryProvidingStateIsNotExternalPower() {
        let state = BatteryMonitor.IOPSPowerSourceState(rawIOPSValue: kIOPMBatteryPowerKey)

        XCTAssertEqual(state, .battery)
        XCTAssertTrue(state?.isExternalPower == false)
    }

    func testUnknownProvidingStateIsNil() {
        let state = BatteryMonitor.IOPSPowerSourceState(rawIOPSValue: "Off Line")

        XCTAssertNil(state)
    }

    // MARK: - AdapterDetails → adapterCurrent

    func testAdapterCurrentIsConvertedFromMAToA() {
        let adapter: [String: Any] = [
            kIOPSPowerAdapterWattsKey: 96,
            kIOPSPowerAdapterCurrentKey: 4000,
        ]

        let data = BatteryMonitor.applyAdapterDetails(adapter)

        XCTAssertEqual(data.adapterWatts ?? 0, 96, accuracy: 0.0001)
        XCTAssertEqual(data.adapterCurrent ?? 0, 4.0, accuracy: 0.0001)
    }

    func testAdapterCurrentZeroIsNil() {
        let adapter: [String: Any] = [
            kIOPSPowerAdapterCurrentKey: 0,
        ]

        let data = BatteryMonitor.applyAdapterDetails(adapter)

        XCTAssertNil(data.adapterCurrent)
    }

    func testAdapterDetailsMergeKeepsPowerSourceData() {
        let source: [String: Any] = [
            kIOPSIsPresentKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ]
        let adapter: [String: Any] = [
            kIOPSPowerAdapterCurrentKey: 4500,
        ]

        let data = BatteryMonitor.applyAdapterDetails(adapter, to: BatteryMonitor.parsePowerSourceDescription(source))

        XCTAssertTrue(data.isPresent)
        XCTAssertTrue(data.externalConnected)
        XCTAssertEqual(data.adapterCurrent ?? 0, 4.5, accuracy: 0.0001)
    }

    // MARK: - resolvedCapacityMAh（SmartBattery 真 mAh 优先，IOPS 量级兜底）
    //
    // 背景：Apple Silicon 上 IOPS 的 Current/Max Capacity 是 0-100 归一化值而非
    // mAh；SmartBattery（gas gauge）在 AS 与 Intel 上均为真 mAh，故优先采用。
    // IOPS 值仅当量级 > 500（真 mAh，如 Intel）且 SmartBattery 缺失时才兜底。

    func testSmartBatteryCapacityIsUsedWhenIOPSMaximumIsMissing() {
        XCTAssertEqual(
            BatteryMonitor.resolvedCapacityMAh(powerSources: 0, smartBattery: 4_321),
            4_321
        )
    }

    func testSmartBatteryCapacityTakesPriorityOverIOPS() {
        // 两者皆为真 mAh 时，取值源从 IOPS 改为 SmartBattery（与 healthPercent
        // 口径一致）。这是本次行为变化的显式回归点。
        XCTAssertEqual(
            BatteryMonitor.resolvedCapacityMAh(powerSources: 5_000, smartBattery: 4_321),
            4_321
        )
    }

    func testNormalizedIOPSRejectedWhenSmartBatteryAvailable() {
        // AS：IOPS 归一化（88/100）与 SmartBattery 真值并存 → 取 SmartBattery。
        XCTAssertEqual(
            BatteryMonitor.resolvedCapacityMAh(powerSources: 100, smartBattery: 7_544),
            7_544
        )
    }

    func testNormalizedIOPSRejectedWhenSmartBatteryMissing() {
        // AS 且 SmartBattery 侧读不到时，归一化值（≤100）不得污染字段 → 0。
        XCTAssertEqual(BatteryMonitor.resolvedCapacityMAh(powerSources: 88, smartBattery: 0), 0)
    }

    func testRealMAhIOPSUsedWhenSmartBatteryMissing() {
        // Intel：IOPS 真 mAh（>500）在 SmartBattery 缺失时兜底。
        XCTAssertEqual(BatteryMonitor.resolvedCapacityMAh(powerSources: 4_200, smartBattery: 0), 4_200)
        XCTAssertEqual(BatteryMonitor.resolvedCapacityMAh(powerSources: 5_000, smartBattery: 0), 5_000)
    }

    func testPowerTelemetryCountersPreserveRawUnsignedWallEnergy() {
        let counters = BatteryMonitor.parsePowerTelemetryCounters([
            "AccumulatedWallEnergyEstimate": NSNumber(value: UInt64(4_294_967_300))
        ])

        XCTAssertEqual(counters.accumulatedWallEnergyEstimate, 4_294_967_300)
    }

    func testPowerTelemetryCountersTreatMissingWallEnergyAsUnavailable() {
        let counters = BatteryMonitor.parsePowerTelemetryCounters([:])

        XCTAssertNil(counters.accumulatedWallEnergyEstimate)
    }
}
