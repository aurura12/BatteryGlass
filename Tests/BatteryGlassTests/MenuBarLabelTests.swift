import AppKit
import XCTest
@testable import BatteryGlass

final class MenuBarLabelTests: XCTestCase {
    func testBatteryIconUsesShorterMenuBarHeight() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 50

        let image = MenuBarIconRenderer.image(for: snapshot)

        XCTAssertEqual(image.size.height, 15, accuracy: 0.001)
    }

    func testBatteryIconContentStaysInsideCanvasEdges() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 50

        let image = MenuBarIconRenderer.image(for: snapshot)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            XCTFail("Unable to inspect battery icon pixels")
            return
        }

        let topRowHasInk = (0..<bitmap.pixelsWide).contains { x in
            guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1),
                  let rgbColor = color.usingColorSpace(.deviceRGB) else {
                return false
            }
            return rgbColor.alphaComponent > 0.05
        }
        let bottomRowHasInk = (0..<bitmap.pixelsWide).contains { x in
            guard let color = bitmap.colorAt(x: x, y: 0),
                  let rgbColor = color.usingColorSpace(.deviceRGB) else {
                return false
            }
            return rgbColor.alphaComponent > 0.05
        }

        XCTAssertFalse(topRowHasInk)
        XCTAssertFalse(bottomRowHasInk)
    }

    func testBatteryIconFillTracksActualPercentage() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 74

        XCTAssertEqual(
            MenuBarBatteryFill.fraction(for: snapshot),
            0.74,
            accuracy: 0.0001
        )

        snapshot.percent = 74.9
        XCTAssertEqual(
            MenuBarBatteryFill.fraction(for: snapshot),
            0.749,
            accuracy: 0.0001
        )
    }

    func testBatteryIconFillClampsAndHidesWhenUnavailable() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 120
        XCTAssertEqual(MenuBarBatteryFill.fraction(for: snapshot), 1)

        snapshot.percent = -20
        XCTAssertEqual(MenuBarBatteryFill.fraction(for: snapshot), 0)

        snapshot.state = .unknown
        snapshot.percent = 80
        XCTAssertEqual(MenuBarBatteryFill.fraction(for: snapshot), 0)
    }

    func testPowerIndicatorShowsWhenAdapterIsConnectedButNotCharging() {
        var snapshot = BatterySnapshot()
        snapshot.state = .pluggedIn
        snapshot.adapterConnected = true

        XCTAssertTrue(MenuBarPowerIndicator.shouldShow(for: snapshot))
    }

    func testPowerIndicatorHidesWhenAdapterIsDisconnected() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.adapterConnected = false

        XCTAssertFalse(MenuBarPowerIndicator.shouldShow(for: snapshot))
    }

    func testPowerIndicatorUsesBoltBadgeWhenAdapterIsConnected() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = true

        XCTAssertEqual(
            MenuBarPowerIndicator.badgeSymbolName(for: snapshot),
            "bolt.fill"
        )
    }

    func testPowerIndicatorUsesSlightlyWiderBatteryIcon() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.adapterConnected = true

        XCTAssertEqual(MenuBarPowerIndicator.iconWidth(for: snapshot), 23)
    }

    func testBatteryIconKeepsEmptyTrackVisibleNearFull() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 87

        let image = MenuBarIconRenderer.image(for: snapshot)
        let preview = NSImage(size: image.size)
        preview.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        preview.unlockFocus()

        guard let tiff = preview.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let filledColor = bitmap.colorAt(x: 20, y: 16)?.usingColorSpace(.deviceRGB),
              let emptyColor = bitmap.colorAt(x: 36, y: 16)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Unable to inspect battery icon pixels")
            return
        }

        XCTAssertGreaterThan(
            emptyColor.redComponent - filledColor.redComponent,
            0.1
        )
    }

    func testAccessibilityLabelAnnouncesChargingState() {
        var snapshot = BatterySnapshot()
        snapshot.state = .charging
        snapshot.percent = 40

        let label = MenuBarAccessibility.label(for: snapshot)
        XCTAssertTrue(label.contains("40%"))
        XCTAssertTrue(label.contains("正在充电"))
    }

    func testAccessibilityLabelDescribesDischargingAndUnknown() {
        var discharging = BatterySnapshot()
        discharging.state = .discharging
        discharging.percent = 55
        XCTAssertTrue(MenuBarAccessibility.label(for: discharging).contains("电池供电"))

        var unknown = BatterySnapshot()
        unknown.state = .unknown
        XCTAssertEqual(MenuBarAccessibility.label(for: unknown), "BatteryGlass，未检测到电池")
    }
}
