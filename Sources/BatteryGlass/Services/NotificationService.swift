import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
}
