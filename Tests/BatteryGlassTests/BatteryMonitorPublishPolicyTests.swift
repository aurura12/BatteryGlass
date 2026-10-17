import XCTest
@testable import BatteryGlass

/// 界面发布节流策略：离屏面板不应跟着每拍采样重算视图图。
final class BatteryMonitorPublishPolicyTests: XCTestCase {
    private func snapshot(
        percent: Double = 80,
        state: PowerState = .discharging,
        adapterConnected: Bool = false,
        isPresent: Bool = true,
        isCharged: Bool = false,
        powerDisplayStatus: PowerDisplayStatus = .ready,
        timeRemaining: TimeInterval? = nil
    ) -> BatterySnapshot {
        var s = BatterySnapshot()
        s.percent = percent
        s.state = state
        s.adapterConnected = adapterConnected
        s.isPresent = isPresent
        s.isCharged = isCharged
        s.powerDisplayStatus = powerDisplayStatus
        s.timeRemaining = timeRemaining
        return s
    }

    func testVisiblePublishesEveryTick() {
        let previous = snapshot(percent: 80)
        let next = snapshot(percent: 80)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .live,
                menuBarMode: .percent,
                secondsSinceLastPublish: 0
            )
        )
    }

    func testHiddenSkipsPowerJitterThatDoesNotChangeMenuBar() {
        var previous = snapshot(percent: 80)
        var next = snapshot(percent: 80)
        previous.current = -1.02
        next.current = -1.06

        XCTAssertFalse(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .percent,
                secondsSinceLastPublish: 1
            )
        )
    }

    func testHiddenPublishesWhenRoundedPercentChanges() {
        let previous = snapshot(percent: 79.4)
        let next = snapshot(percent: 79.6)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .percent,
                secondsSinceLastPublish: 1
            )
        )
    }

    func testHiddenPublishesAdapterTransition() {
        let previous = snapshot(percent: 80, state: .discharging)
        let next = snapshot(percent: 80, state: .pluggedIn, adapterConnected: true)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .percent,
                secondsSinceLastPublish: 1
            )
        )
    }

    func testHiddenPublishesPowerDisplayStatusChange() {
        let previous = snapshot(percent: 80)
        let next = snapshot(percent: 80, powerDisplayStatus: .updating)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .percent,
                secondsSinceLastPublish: 1
            )
        )
    }

    /// 剩余时间只在「分钟数字变了」时发布——平滑器每拍都在改秒值。
    func testHiddenTimeRemainingModeOnlyPublishesOnMinuteChange() {
        let previous = snapshot(percent: 80, timeRemaining: 7200)
        let sameMinute = snapshot(percent: 80, timeRemaining: 7230)
        let nextMinute = snapshot(percent: 80, timeRemaining: 7265)

        XCTAssertFalse(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: sameMinute,
                mode: .background,
                menuBarMode: .timeRemaining,
                secondsSinceLastPublish: 1
            )
        )
        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: nextMinute,
                mode: .background,
                menuBarMode: .timeRemaining,
                secondsSinceLastPublish: 1
            )
        )
    }

    /// 菜单栏只显示百分比时，剩余时间的分钟变化不应触发重绘。
    func testHiddenPercentModeIgnoresTimeRemainingChange() {
        let previous = snapshot(percent: 80, timeRemaining: 7200)
        let next = snapshot(percent: 80, timeRemaining: 7265)

        XCTAssertFalse(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .percent,
                secondsSinceLastPublish: 1
            )
        )
    }

    func testHiddenHeartbeatPublishes() {
        let previous = snapshot(percent: 80)
        let next = snapshot(percent: 80)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .background,
                menuBarMode: .none,
                secondsSinceLastPublish: BatteryMonitor.hiddenPublishHeartbeat
            )
        )
    }

    /// 只有小组件在屏幕上时按秒发布，不再跟 2 Hz 采样。
    func testWidgetModePublishesAtMostOncePerSecond() {
        let previous = snapshot(percent: 80)
        let next = snapshot(percent: 80)

        XCTAssertFalse(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .widget,
                menuBarMode: .percent,
                secondsSinceLastPublish: 0.5
            )
        )
        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .widget,
                menuBarMode: .percent,
                secondsSinceLastPublish: BatteryMonitor.widgetRefreshInterval
            )
        )
    }

    /// 不足一秒但百分比跳变（例如充满后回落）时，小组件仍应立即跟上。
    func testWidgetModePublishesImmediatelyOnPercentChange() {
        let previous = snapshot(percent: 80)
        let next = snapshot(percent: 81)

        XCTAssertTrue(
            BatteryMonitor.shouldPublish(
                previous: previous,
                next: next,
                mode: .widget,
                menuBarMode: .percent,
                secondsSinceLastPublish: 0.2
            )
        )
    }
}
