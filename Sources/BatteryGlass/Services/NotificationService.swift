import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    /// 请求通知权限（仅当状态为「尚未决定」时发起），返回最终是否已授权。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let finalSettings = await center.notificationSettings()
        return finalSettings.authorizationStatus == .authorized
            || finalSettings.authorizationStatus == .provisional
    }

    func sendLowBattery(percent: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "电池电量偏低"
        content.body = String(format: "当前电量 %.0f%%，已低于 %.0f%% 的提醒阈值。", percent, threshold)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "batteryglass.low-battery",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendAdapterChange(connected: Bool, percent: Double) {
        let content = UNMutableNotificationContent()
        content.title = connected ? "电源适配器已接入" : "电源适配器已断开"
        content.body = connected
            ? String(format: "已接入充电，当前电量 %.0f%%。", percent)
            : String(format: "当前电量 %.0f%%，正在使用电池供电。", percent)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "batteryglass.adapter-change",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
