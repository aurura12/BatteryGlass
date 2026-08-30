import Foundation
import OSLog
import ServiceManagement

/// 开机自启动（登录项）的系统状态。
enum LoginItemState: Equatable {
    /// 已注册为登录项，登录后自动启动。
    case enabled
    /// 尚未注册，可以注册。
    case notRegistered
    /// 已发起注册但需用户在系统设置中批准（常见于从互联网下载的应用）。
    case requiresApproval
    /// 无法获取或操作登录项（如未通过 .app 包运行），此时应禁用开关。
    case unavailable

    init(status: SMAppService.Status) {
        switch status {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notRegistered:
            self = .notRegistered
        case .notFound:
            // 未从 .app 包运行（如直接运行可执行文件），系统不认为存在可注册的 App。
            self = .unavailable
        @unknown default:
            self = .unavailable
        }
    }
}

/// 根据期望状态应执行的操作。
enum LoginItemAction: Equatable {
    case register
    case unregister
    case none
}

/// 执行注册/注销后的结果。
enum LoginItemApplyResult: Equatable {
    /// 已按期望状态生效（含本就无需变更的情况）。
    case applied
    /// 注册已发起，但需用户在系统设置中批准。
    case needsApproval
    /// 无法操作登录项（未从 .app 包运行）。
    case unavailable
    /// 系统调用失败。
    case failed
}

/// 开机自启动设置：封装 `SMAppService.mainApp` 的状态查询与注册/注销。
enum LoginItemService {
    private static let logger = Logger(subsystem: "com.batteryglass.app", category: "LoginItem")

    static var currentState: LoginItemState {
        LoginItemState(status: SMAppService.mainApp.status)
    }

    /// 系统当前是否处于"登录后自动启动"状态。
    /// 返回 nil 表示无法判断（未从 .app 包运行）。
    static func systemLaunchAtLoginEnabled() -> Bool? {
        switch currentState {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered:
            return false
        case .unavailable:
            return nil
        }
    }

    /// 根据当前系统状态与期望状态，决定是否需要调用注册/注销。
    /// 提取为纯函数便于单元测试。
    static func desiredAction(current state: LoginItemState, desiredEnabled: Bool) -> LoginItemAction {
        switch state {
        case .enabled:
            return desiredEnabled ? .none : .unregister
        case .notRegistered:
            return desiredEnabled ? .register : .none
        case .requiresApproval:
            // 开启时等待用户在系统设置中批准，无需重复注册；
            // 关闭时移除待批准项。
            return desiredEnabled ? .none : .unregister
        case .unavailable:
            return .none
        }
    }

    /// 执行设置：根据期望状态注册/注销登录项，返回结果。
    @discardableResult
    static func apply(desiredEnabled: Bool) -> LoginItemApplyResult {
        switch desiredAction(current: currentState, desiredEnabled: desiredEnabled) {
        case .none:
            return .applied
        case .register:
            do {
                try SMAppService.mainApp.register()
                return .applied
            } catch {
                // 需要批准时 register() 会抛错且状态变为 requiresApproval。
                if SMAppService.mainApp.status == .requiresApproval {
                    logger.notice("开机自启动待用户批准")
                    return .needsApproval
                }
                logger.error("注册登录项失败: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        case .unregister:
            do {
                try SMAppService.mainApp.unregister()
                return .applied
            } catch {
                logger.error("注销登录项失败: \(error.localizedDescription, privacy: .public)")
                return .failed
            }
        }
    }
}
