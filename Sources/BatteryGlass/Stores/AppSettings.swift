import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    var lowBatteryNotificationsEnabled: Bool {
        didSet { defaults.set(lowBatteryNotificationsEnabled, forKey: Self.notificationsEnabledKey) }
    }

    var lowBatteryThreshold: Double {
        didSet { defaults.set(lowBatteryThreshold, forKey: Self.thresholdKey) }
    }

    var animationIntensity: Double {
        didSet { defaults.set(animationIntensity, forKey: Self.intensityKey) }
    }

    var animationSpeed: Double {
        didSet { defaults.set(animationSpeed, forKey: Self.speedKey) }
    }

    var recordHistory: Bool {
        didSet { defaults.set(recordHistory, forKey: Self.recordHistoryKey) }
    }

    var desktopWidgetEnabled: Bool {
        didSet { defaults.set(desktopWidgetEnabled, forKey: Self.desktopWidgetKey) }
    }

    var desktopWidgetFrameString: String {
        didSet { defaults.set(desktopWidgetFrameString, forKey: Self.desktopWidgetFrameKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lowBatteryNotificationsEnabled = defaults.bool(forKey: Self.notificationsEnabledKey)

        if defaults.object(forKey: Self.thresholdKey) != nil {
            lowBatteryThreshold = defaults.double(forKey: Self.thresholdKey)
        } else {
            lowBatteryThreshold = 20
        }
        animationIntensity = defaults.object(forKey: Self.intensityKey) as? Double ?? 0.75
        animationSpeed = defaults.object(forKey: Self.speedKey) as? Double ?? 1.0
        recordHistory = defaults.object(forKey: Self.recordHistoryKey) as? Bool ?? true
        desktopWidgetEnabled = defaults.object(forKey: Self.desktopWidgetKey) as? Bool ?? true
        desktopWidgetFrameString = defaults.string(forKey: Self.desktopWidgetFrameKey) ?? ""
    }

    private static let notificationsEnabledKey = "notificationsEnabled"
    private static let thresholdKey = "lowBatteryThreshold"
    private static let intensityKey = "animationIntensity"
    private static let speedKey = "animationSpeed"
    private static let recordHistoryKey = "recordHistory"
    private static let desktopWidgetKey = "desktopWidgetEnabled"
    private static let desktopWidgetFrameKey = "desktopWidgetFrameString"
}
