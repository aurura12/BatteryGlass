import Foundation
import XCTest
@testable import BatteryGlass

/// 验证 AppleSmartBattery 容量键解析（Intel / Apple Silicon 键位差异）。
/// 背景：Intel 在 BatteryData 内有 DesignCapacity / FullChargeCapacity；
/// Apple Silicon 缺 FullChargeCapacity，设计容量在顶层 DesignCapacity /
/// NominalChargeCapacity，满充容量在 BatteryData["FccComp2"] / 顶层
/// AppleRawMaxCapacity。解析失败会让 healthPercent 恒为 nil，
/// 导致「电池健康趋势」图表长期无数据。
@MainActor
final class BatteryMonitorSmartBatteryTests: XCTestCase {
    // MARK: - 设计容量解析

    func testDesignCapacityPrefersBatteryDataKey() {
        XCTAssertEqual(
            BatteryMonitor.resolvedDesignCapacityMAh(
                batteryDesignCapacity: 8694,
                topLevelDesignCapacity: 0,
                nominalChargeCapacity: 0
            ),
            8694
        )
    }

    func testDesignCapacityFallsBackToTopLevelKey() {
        XCTAssertEqual(
            BatteryMonitor.resolvedDesignCapacityMAh(
                batteryDesignCapacity: 0,
                topLevelDesignCapacity: 8694,
                nominalChargeCapacity: 7788
            ),
            8694
        )
    }

    func testDesignCapacityFallsBackToNominalChargeCapacity() {
        XCTAssertEqual(
            BatteryMonitor.resolvedDesignCapacityMAh(
                batteryDesignCapacity: 0,
                topLevelDesignCapacity: 0,
                nominalChargeCapacity: 7788
            ),
            7788
        )
    }

    func testDesignCapacityAllZeroReturnsZero() {
        XCTAssertEqual(
            BatteryMonitor.resolvedDesignCapacityMAh(
                batteryDesignCapacity: 0,
                topLevelDesignCapacity: 0,
                nominalChargeCapacity: 0
            ),
            0
        )
    }

    // MARK: - 满充容量解析

    func testFullChargePrefersBatteryDataKey() {
        XCTAssertEqual(
            BatteryMonitor.resolvedFullChargeCapacityMAh(
                batteryFullChargeCapacity: 7500,
                batteryFccComp2: 0,
                topLevelAppleRawMaxCapacity: 0
            ),
            7500
        )
    }

    func testFullChargeFallsBackToFccComp2() {
        XCTAssertEqual(
            BatteryMonitor.resolvedFullChargeCapacityMAh(
                batteryFullChargeCapacity: 0,
                batteryFccComp2: 7544,
                topLevelAppleRawMaxCapacity: 0
            ),
            7544
        )
    }

    func testFullChargeFallsBackToAppleRawMaxCapacity() {
        XCTAssertEqual(
            BatteryMonitor.resolvedFullChargeCapacityMAh(
                batteryFullChargeCapacity: 0,
                batteryFccComp2: 0,
                topLevelAppleRawMaxCapacity: 7544
            ),
            7544
        )
    }

    func testFullChargeAllZeroReturnsZero() {
        XCTAssertEqual(
            BatteryMonitor.resolvedFullChargeCapacityMAh(
                batteryFullChargeCapacity: 0,
                batteryFccComp2: 0,
                topLevelAppleRawMaxCapacity: 0
            ),
            0
        )
    }

    // MARK: - 真实机型集成验证（Apple Silicon 实测键位）

    func testAppleSiliconRealRegistryValuesYieldReasonableHealth() {
        // 实测 ioreg 输出：顶层 AppleRawMaxCapacity=7544、DesignCapacity=8694、
        // NominalChargeCapacity=7788；BatteryData 有 FccComp2=7544、无 FullChargeCapacity。
        let design = BatteryMonitor.resolvedDesignCapacityMAh(
            batteryDesignCapacity: 8694,
            topLevelDesignCapacity: 8694,
            nominalChargeCapacity: 7788
        )
        let fullCharge = BatteryMonitor.resolvedFullChargeCapacityMAh(
            batteryFullChargeCapacity: 0,
            batteryFccComp2: 7544,
            topLevelAppleRawMaxCapacity: 7544
        )

        XCTAssertEqual(design, 8694)
        XCTAssertEqual(fullCharge, 7544)
        XCTAssertEqual(fullCharge / design * 100, 86.77, accuracy: 0.01)
    }
}
