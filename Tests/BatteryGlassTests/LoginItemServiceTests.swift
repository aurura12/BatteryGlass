import Foundation
import XCTest
@testable import BatteryGlass

final class LoginItemServiceTests: XCTestCase {
    // MARK: - 已注册（enabled）

    func testEnabledWithDesiredEnabledDoesNothing() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .enabled, desiredEnabled: true),
            .none
        )
    }

    func testEnabledWithDesiredDisabledUnregisters() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .enabled, desiredEnabled: false),
            .unregister
        )
    }

    // MARK: - 未注册（notRegistered）

    func testNotRegisteredWithDesiredEnabledRegisters() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .notRegistered, desiredEnabled: true),
            .register
        )
    }

    func testNotRegisteredWithDesiredDisabledDoesNothing() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .notRegistered, desiredEnabled: false),
            .none
        )
    }

    // MARK: - 待批准（requiresApproval）

    func testRequiresApprovalWithDesiredEnabledWaitsForSystemApproval() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .requiresApproval, desiredEnabled: true),
            .none
        )
    }

    func testRequiresApprovalWithDesiredDisabledUnregisters() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .requiresApproval, desiredEnabled: false),
            .unregister
        )
    }

    // MARK: - 不可用（unavailable）

    func testUnavailableNeverRegistersOrUnregisters() {
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .unavailable, desiredEnabled: true),
            .none
        )
        XCTAssertEqual(
            LoginItemService.desiredAction(current: .unavailable, desiredEnabled: false),
            .none
        )
    }
}
