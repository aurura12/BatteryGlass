import XCTest
@testable import BatteryGlass

final class AxisTickScaleTests: XCTestCase {
    func testNarrowDecimalDomainKeepsLabelsDistinct() {
        let scale = EnergyAxisScale.ticks(in: 12.667...12.703)

        XCTAssertEqual(scale.fractionDigits, 2)
        XCTAssertEqual(scale.labels, ["12.67", "12.68", "12.69", "12.70"])
    }

    func testWideDomainUsesNiceStep() {
        let scale = EnergyAxisScale.ticks(in: 18...42)

        XCTAssertEqual(scale.fractionDigits, 0)
        XCTAssertEqual(scale.labels, ["20", "25", "30", "35", "40"])
    }

    func testEnergyScaleLabelsAreDistinct() {
        let scale = EnergyAxisScale.ticks(in: 0...0.088)

        XCTAssertEqual(scale.fractionDigits, 2)
        XCTAssertEqual(scale.labels, ["0.00", "0.02", "0.04", "0.06", "0.08"])
    }

    func testTicksStayInsideDomainAndAscending() {
        let domains: [ClosedRange<Double>] = [
            0...1, 18...42, 12.667...12.703, 0...0.088, 0...3.7
        ]

        for domain in domains {
            let scale = EnergyAxisScale.ticks(in: domain)
            XCTAssertTrue((3...5).contains(scale.values.count), "域 \(domain) 刻度数量异常")
            XCTAssertEqual(scale.values, scale.values.sorted(), "域 \(domain) 刻度未升序")
            for value in scale.values {
                XCTAssertTrue(domain.contains(value), "域 \(domain) 的刻度 \(value) 越界")
            }
            XCTAssertEqual(
                Set(scale.labels).count,
                scale.values.count,
                "域 \(domain) 出现重复刻度标签 \(scale.labels)"
            )
        }
    }

    func testFractionDigitsFollowsStep() {
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 0.005), 3)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 0.01), 2)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 0.05), 2)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 0.2), 1)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 0.5), 1)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 1), 0)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 5), 0)
        XCTAssertEqual(EnergyAxisScale.fractionDigits(forStep: 10), 0)
    }

    func testDegenerateDomainDoesNotCrash() {
        let empty = EnergyAxisScale.ticks(in: 5...5)
        XCTAssertTrue(empty.values.isEmpty)
        XCTAssertEqual(empty.domain, 5...5)
    }
}
