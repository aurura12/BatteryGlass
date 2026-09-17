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

    func testChargingBoltIsCutOutOfAppearanceAdaptiveTemplate() {
        var withoutBolt = BatterySnapshot()
        withoutBolt.state = .discharging
        withoutBolt.percent = 50

        var withBolt = withoutBolt
        withBolt.adapterConnected = true

        let regularImage = MenuBarIconRenderer.image(for: withoutBolt)
        let chargingImage = MenuBarIconRenderer.image(for: withBolt)
        XCTAssertTrue(regularImage.isTemplate)
        XCTAssertTrue(chargingImage.isTemplate)

        guard let regularData = regularImage.tiffRepresentation,
              let regularBitmap = NSBitmapImageRep(data: regularData),
              let chargingData = chargingImage.tiffRepresentation,
              let chargingBitmap = NSBitmapImageRep(data: chargingData) else {
            XCTFail("Unable to inspect battery icon mask")
            return
        }

        var transparentBoltPixels = 0
        for y in 0..<min(regularBitmap.pixelsHigh, chargingBitmap.pixelsHigh) {
            for x in 0..<min(regularBitmap.pixelsWide, chargingBitmap.pixelsWide) {
                guard let regularColor = regularBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let chargingColor = chargingBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if regularColor.alphaComponent - chargingColor.alphaComponent > 0.1 {
                    transparentBoltPixels += 1
                }
            }
        }

        XCTAssertGreaterThan(transparentBoltPixels, 10)
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

    func testBatteryIconUsesLowerMaskOpacityForEmptyTrackNearFull() {
        var snapshot = BatterySnapshot()
        snapshot.state = .discharging
        snapshot.percent = 87

        let image = MenuBarIconRenderer.image(for: snapshot)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            XCTFail("Unable to inspect battery icon pixels")
            return
        }

        let pixelsPerPointX = CGFloat(bitmap.pixelsWide) / image.size.width
        let pixelsPerPointY = CGFloat(bitmap.pixelsHigh) / image.size.height
        let sampleY = Int(8 * pixelsPerPointY)
        let filledX = Int(10 * pixelsPerPointX)
        let emptyX = Int(18 * pixelsPerPointX)
        guard let filledColor = bitmap.colorAt(x: filledX, y: sampleY)?.usingColorSpace(.deviceRGB),
              let emptyColor = bitmap.colorAt(x: emptyX, y: sampleY)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Unable to inspect battery icon mask samples")
            return
        }

        XCTAssertGreaterThan(
            filledColor.alphaComponent - emptyColor.alphaComponent,
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
