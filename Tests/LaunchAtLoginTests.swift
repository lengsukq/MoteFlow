import XCTest
@testable import ATVVCore

private final class MockLaunchAtLoginService: LaunchAtLoginManaging {
    var status: LaunchAtLoginStatus
    var nextRegisterStatus: LaunchAtLoginStatus?
    var nextUnregisterStatus: LaunchAtLoginStatus?
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    var currentStatus: LaunchAtLoginStatus { status }

    func register() throws {
        registerCalls += 1
        if let nextRegisterStatus {
            status = nextRegisterStatus
        }
        if let registerError {
            throw registerError
        }
        if nextRegisterStatus == nil {
            status = .enabled
        }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let nextUnregisterStatus {
            status = nextUnregisterStatus
        }
        if let unregisterError {
            throw unregisterError
        }
        if nextUnregisterStatus == nil {
            status = .disabled
        }
    }

    func openSystemSettings() {
        openSettingsCalls += 1
    }
}

private struct StubLaunchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LaunchAtLoginTests: XCTestCase {
    func testEnableFromDisabledSucceeds() {
        let service = MockLaunchAtLoginService(status: .disabled)

        let result = LaunchAtLoginController.apply(desiredEnabled: true, service: service)

        XCTAssertEqual(result.status, .enabled)
        XCTAssertNil(result.errorMessage)
        XCTAssertFalse(result.shouldOpenSystemSettings)
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testEnableWhenAlreadyEnabledIsIdempotent() {
        let service = MockLaunchAtLoginService(status: .enabled)

        let result = LaunchAtLoginController.apply(desiredEnabled: true, service: service)

        XCTAssertEqual(result.status, .enabled)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(service.registerCalls, 0)
    }

    func testEnableWhenUnavailableFailsHonestlyWithoutRegistering() {
        let service = MockLaunchAtLoginService(status: .unavailable)

        let result = LaunchAtLoginController.apply(desiredEnabled: true, service: service)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertFalse(result.shouldOpenSystemSettings)
        XCTAssertEqual(service.registerCalls, 0)
    }

    func testEnableRequiringApprovalGuidesUserToSystemSettings() {
        let service = MockLaunchAtLoginService(status: .requiresApproval)
        service.nextRegisterStatus = .requiresApproval
        service.registerError = StubLaunchError(message: "Operation not permitted")

        let result = LaunchAtLoginController.apply(desiredEnabled: true, service: service)

        XCTAssertEqual(result.status, .requiresApproval)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(result.shouldOpenSystemSettings)
        XCTAssertEqual(service.registerCalls, 1)
    }

    func testEnableThrowingUnexpectedErrorSurfacesErrorDetails() {
        let service = MockLaunchAtLoginService(status: .disabled)
        service.nextRegisterStatus = .disabled
        service.registerError = StubLaunchError(message: "Invalid code signature")

        let result = LaunchAtLoginController.apply(desiredEnabled: true, service: service)

        XCTAssertEqual(result.status, .disabled)
        XCTAssertTrue(result.errorMessage?.contains("Invalid code signature") == true)
        XCTAssertFalse(result.shouldOpenSystemSettings)
    }

    func testDisableFromEnabledSucceeds() {
        let service = MockLaunchAtLoginService(status: .enabled)

        let result = LaunchAtLoginController.apply(desiredEnabled: false, service: service)

        XCTAssertEqual(result.status, .disabled)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testDisableWhenAlreadyDisabledIsIdempotent() {
        let service = MockLaunchAtLoginService(status: .disabled)

        let result = LaunchAtLoginController.apply(desiredEnabled: false, service: service)

        XCTAssertEqual(result.status, .disabled)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testDisableRecoversCleanlyIfAlreadyUnregisteredDespiteThrow() {
        let service = MockLaunchAtLoginService(status: .enabled)
        service.nextUnregisterStatus = .disabled
        service.unregisterError = StubLaunchError(message: "Job not found")

        let result = LaunchAtLoginController.apply(desiredEnabled: false, service: service)

        XCTAssertEqual(result.status, .disabled)
        XCTAssertNil(result.errorMessage)
    }

    func testDisableFailureWhileStillEnabledExposesError() {
        let service = MockLaunchAtLoginService(status: .enabled)
        service.nextUnregisterStatus = .enabled
        service.unregisterError = StubLaunchError(message: "Permission denied")

        let result = LaunchAtLoginController.apply(desiredEnabled: false, service: service)

        XCTAssertEqual(result.status, .enabled)
        XCTAssertTrue(result.errorMessage?.contains("Permission denied") == true)
    }

    func testStatusPresentationMetadataIsComplete() {
        let statuses: [LaunchAtLoginStatus] = [.enabled, .disabled, .requiresApproval, .unavailable]
        for status in statuses {
            XCTAssertFalse(status.badgeTitle.isEmpty)
            XCTAssertFalse(status.badgeSymbol.isEmpty)
            XCTAssertFalse(status.detailMessage.isEmpty)
        }
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.requiresApproval.isEnabled)
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.needsSystemSettingsApproval)
    }
}
