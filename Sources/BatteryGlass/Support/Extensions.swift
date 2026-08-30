import Foundation

extension Notification.Name {
    static let batterySnapshotUpdated = Notification.Name("BatteryGlass.batterySnapshotUpdated")
    static let requestDashboardWindow = Notification.Name("BatteryGlass.requestDashboardWindow")
    static let desktopWidgetVisibilityChanged = Notification.Name("BatteryGlass.desktopWidgetVisibilityChanged")
    static let resetDesktopWidgetPosition = Notification.Name("BatteryGlass.resetDesktopWidgetPosition")
    static let desktopWidgetStyleChanged = Notification.Name("BatteryGlass.desktopWidgetStyleChanged")
}

extension Double {
    var nilIfZero: Double? {
        self == 0 ? nil : self
    }
}
