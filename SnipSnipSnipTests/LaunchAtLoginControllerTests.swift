import XCTest
@testable import SnipSnipSnip

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testInitialStatusMapsServiceState() {
        let controller = LaunchAtLoginController(
            service: TestLaunchAtLoginService(serviceState: .requiresApproval)
        )

        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testEnableReturnsUpdatedStatusAfterSuccessfulRegistration() {
        let service = TestLaunchAtLoginService(serviceState: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        let result = controller.setEnabled(true)

        XCTAssertEqual(result, .updated(.enabled))
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testEnableReturnsRequiresApprovalWhenStatusNeedsManualFollowUp() {
        let service = TestLaunchAtLoginService(serviceState: .notRegistered)
        service.registerHandler = {
            service.serviceState = .requiresApproval
            throw TestLaunchAtLoginService.TestError.operationFailed
        }
        let controller = LaunchAtLoginController(service: service)

        let result = controller.setEnabled(true)

        XCTAssertEqual(result, .requiresApproval)
        XCTAssertEqual(controller.status, .requiresApproval)
    }

    func testDisableTreatsAlreadyDisabledStateAsSuccessAfterErrorRefresh() {
        let service = TestLaunchAtLoginService(serviceState: .enabled)
        service.unregisterHandler = {
            service.serviceState = .notRegistered
            throw TestLaunchAtLoginService.TestError.operationFailed
        }
        let controller = LaunchAtLoginController(service: service)

        let result = controller.setEnabled(false)

        XCTAssertEqual(result, .updated(.disabled))
        XCTAssertEqual(controller.status, .disabled)
    }

    func testOpenSystemSettingsForwardsToService() {
        let service = TestLaunchAtLoginService(serviceState: .enabled)
        let controller = LaunchAtLoginController(service: service)

        controller.openSystemSettings()

        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
    }
}

@MainActor
private final class TestLaunchAtLoginService: LaunchAtLoginControlling {
    enum TestError: Error {
        case operationFailed
    }

    var serviceState: LaunchAtLoginServiceState
    var registerCallCount = 0
    var unregisterCallCount = 0
    var openSystemSettingsCallCount = 0
    var registerHandler: (() throws -> Void)?
    var unregisterHandler: (() throws -> Void)?

    init(serviceState: LaunchAtLoginServiceState) {
        self.serviceState = serviceState
    }

    func register() throws {
        registerCallCount += 1

        if let registerHandler {
            try registerHandler()
            return
        }

        serviceState = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1

        if let unregisterHandler {
            try unregisterHandler()
            return
        }

        serviceState = .notRegistered
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}