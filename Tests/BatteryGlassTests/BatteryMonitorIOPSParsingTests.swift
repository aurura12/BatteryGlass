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
}
