import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class AppTerminationControllerTests: XCTestCase {
    func testApplicationShouldTerminateCancelsReentrantTerminationWhileConfirmationIsOpen() {
        let lifecycle = makeLifecycle()
        let controllerBox = TerminationControllerBox()
        var confirmationCalls = 0
        var backgroundCalls = 0
        var nestedReply: NSApplication.TerminateReply?

        let controller = AppTerminationController(
            confirmationHandler: { _ in
                confirmationCalls += 1
                nestedReply = controllerBox.controller.applicationShouldTerminate()
                return AppTerminationController.QuitConfirmationResult(
                    shouldQuit: false,
                    suppressFutureConfirmations: false
                )
            },
            backgroundHandler: {
                backgroundCalls += 1
            },
            terminationHandler: {
                XCTFail("Cancelling the quit confirmation must not terminate the app.")
            }
        )
        controllerBox.controller = controller
        controller.configure(lifecycle: lifecycle)

        let reply = controller.applicationShouldTerminate()

        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertEqual(nestedReply, .terminateCancel)
        XCTAssertEqual(confirmationCalls, 1)
        XCTAssertEqual(backgroundCalls, 1)
    }

    func testRequestQuitIgnoresReentrantExplicitQuitWhileConfirmationIsOpen() {
        let lifecycle = makeLifecycle()
        let controllerBox = TerminationControllerBox()
        var confirmationCalls = 0
        var backgroundCalls = 0

        let controller = AppTerminationController(
            confirmationHandler: { _ in
                confirmationCalls += 1
                controllerBox.controller.requestQuit()
                return AppTerminationController.QuitConfirmationResult(
                    shouldQuit: false,
                    suppressFutureConfirmations: false
                )
            },
            backgroundHandler: {
                backgroundCalls += 1
            },
            terminationHandler: {
                XCTFail("Cancelling the quit confirmation must not terminate the app.")
            }
        )
        controllerBox.controller = controller
        controller.configure(lifecycle: lifecycle)

        controller.requestQuit()

        XCTAssertEqual(confirmationCalls, 1)
        XCTAssertEqual(backgroundCalls, 1)
    }

    func testConfirmedRequestQuitAllowsAppKitTerminationCallbackToComplete() {
        let lifecycle = makeLifecycle()
        let controllerBox = TerminationControllerBox()
        var terminationCalls = 0
        var appKitReply: NSApplication.TerminateReply?

        let controller = AppTerminationController(
            confirmationHandler: { _ in
                AppTerminationController.QuitConfirmationResult(
                    shouldQuit: true,
                    suppressFutureConfirmations: false
                )
            },
            backgroundHandler: {
                XCTFail("Confirmed quit must not send the app to the background.")
            },
            terminationHandler: {
                terminationCalls += 1
                appKitReply = controllerBox.controller.applicationShouldTerminate()
            }
        )
        controllerBox.controller = controller
        controller.configure(lifecycle: lifecycle)

        controller.requestQuit()

        XCTAssertEqual(terminationCalls, 1)
        XCTAssertEqual(appKitReply, .terminateNow)
    }

    func testConfirmedQuitCanSuppressFutureConfirmations() {
        let lifecycle = makeLifecycle(confirmsBeforeQuitting: true)
        let controller = AppTerminationController(
            confirmationHandler: { _ in
                AppTerminationController.QuitConfirmationResult(
                    shouldQuit: true,
                    suppressFutureConfirmations: true
                )
            },
            backgroundHandler: {},
            terminationHandler: {}
        )
        controller.configure(lifecycle: lifecycle)

        _ = controller.applicationShouldTerminate()

        XCTAssertFalse(lifecycle.confirmsBeforeQuitting)
    }

    private func makeLifecycle(confirmsBeforeQuitting: Bool = true) -> AppLifecycleModel {
        let suiteName = "AppTerminationControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let environment = AppEnvironment(defaults: defaults)

        return AppLifecycleModel(
            capabilities: environment.capabilities,
            preferenceStore: environment.preferenceStores.lifecycle,
            confirmsBeforeQuitting: confirmsBeforeQuitting,
            launchAtLoginController: LaunchAtLoginController(),
            workspace: environment.systemServices.workspace,
            shouldPresentOnboardingWindowOnLaunch: false,
            shouldPresentMainWindowOnLaunch: false
        )
    }
}

@MainActor
private final class TerminationControllerBox {
    var controller: AppTerminationController!
}
