import XCTest
@testable import BatteryGlass

final class HistoryRecordingNoticeTests: XCTestCase {
    func testNoNoticeWhenRecordingIsEnabledAndPersistenceIsHealthy() {
        XCTAssertNil(HistoryRecordingNotice.resolve(recordingEnabled: true, persistenceIssue: nil))
    }

    func testDisabledRecordingExplainsWhyNothingIsRecorded() {
        let notice = HistoryRecordingNotice.resolve(recordingEnabled: false, persistenceIssue: nil)
        XCTAssertEqual(notice, .disabled)
        XCTAssertTrue(notice?.title.contains("已关闭") == true)
        XCTAssertEqual(notice?.emptyCurveMessage, "历史记录已关闭，暂无曲线数据")
        XCTAssertEqual(notice?.emptyEnergyMessage, "历史记录已关闭，暂无能耗数据")
    }

    func testPersistenceIssueTakesPrecedenceOverDisabledRecording() {
        let notice = HistoryRecordingNotice.resolve(
            recordingEnabled: false,
            persistenceIssue: "文件无法读取"
        )
        XCTAssertEqual(notice, .paused(issue: "文件无法读取"))
        XCTAssertTrue(notice?.title.contains("已暂停") == true)
        XCTAssertEqual(notice?.emptyCurveMessage, "历史记录已暂停，暂无曲线数据")
        XCTAssertEqual(notice?.emptyEnergyMessage, "历史记录已暂停，暂无能耗数据")
    }

    func testIconsDifferByReason() {
        XCTAssertEqual(
            HistoryRecordingNotice.paused(issue: "x").icon,
            "exclamationmark.triangle.fill"
        )
        XCTAssertEqual(HistoryRecordingNotice.disabled.icon, "pause.circle")
    }
}
