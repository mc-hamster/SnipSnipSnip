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

    func testConfirmedRequestQuitWaitsForDocumentRecoveryFlush() async {
        let lifecycle = makeLifecycle()
        let preparer = ExitPreparationStub()
        let terminationExpectation = expectation(description: "Termination after recovery flush")
        var terminationCalls = 0
        let controller = AppTerminationController(
            confirmationHandler: { _ in
                AppTerminationController.QuitConfirmationResult(
                    shouldQuit: true,
                    suppressFutureConfirmations: false
                )
            },
            backgroundHandler: {},
            terminationHandler: {
                terminationCalls += 1
                terminationExpectation.fulfill()
            }
        )
        controller.configure(lifecycle: lifecycle, documents: preparer)

        controller.requestQuit()

        XCTAssertEqual(terminationCalls, 0)
        await fulfillment(of: [terminationExpectation], timeout: 2)
        XCTAssertEqual(preparer.callCount, 1)
        XCTAssertEqual(terminationCalls, 1)
    }

    func testRestartWithoutConfirmationRelaunchesAndBypassesQuitConfirmation() {
        let lifecycle = makeLifecycle()
        let controllerBox = TerminationControllerBox()
        var confirmationCalls = 0
        var relaunchCalls = 0
        var terminationCalls = 0
        var appKitReply: NSApplication.TerminateReply?

        let controller = AppTerminationController(
            confirmationHandler: { _ in
                confirmationCalls += 1
                return AppTerminationController.QuitConfirmationResult(
                    shouldQuit: false,
                    suppressFutureConfirmations: false
                )
            },
            backgroundHandler: {
                XCTFail("Restart must not send the app to the background.")
            },
            terminationHandler: {
                terminationCalls += 1
                appKitReply = controllerBox.controller.applicationShouldTerminate()
            },
            relaunchHandler: {
                relaunchCalls += 1
            }
        )
        controllerBox.controller = controller
        controller.configure(lifecycle: lifecycle)

        controller.requestRestartWithoutConfirmation()

        XCTAssertEqual(confirmationCalls, 0)
        XCTAssertEqual(relaunchCalls, 1)
        XCTAssertEqual(terminationCalls, 1)
        XCTAssertEqual(appKitReply, .terminateNow)
    }

    func testRestartLauncherWaitsForCurrentProcessBeforeReusingTheAppInstance() {
        let arguments = AppTerminationController.restartLauncherArguments(
            appPath: "/Applications/Fixture.app",
            processID: 12345
        )

        XCTAssertEqual(arguments[0], "/bin/sh")
        XCTAssertEqual(arguments[1], "-c")
        XCTAssertTrue(arguments[2].contains("while kill -0 \"$parent_pid\""))
        XCTAssertTrue(arguments[2].contains("/usr/bin/open \"$app_path\""))
        XCTAssertFalse(arguments[2].contains("/usr/bin/open -n"))
        XCTAssertEqual(arguments[3], "restart")
        XCTAssertEqual(arguments[4], "/Applications/Fixture.app")
        XCTAssertEqual(arguments[5], "12345")
    }

    func testFallbackRestartLauncherWaitsForCurrentProcessBeforeReusingTheAppInstance() {
        let arguments = AppTerminationController.restartFallbackLauncherArguments(
            appPath: "/Applications/Fixture.app",
            processID: 12345
        )

        XCTAssertEqual(arguments[0], "-c")
        XCTAssertTrue(arguments[1].contains("while kill -0 \"$parent_pid\""))
        XCTAssertTrue(arguments[1].contains("/usr/bin/open \"$app_path\""))
        XCTAssertFalse(arguments[1].contains("/usr/bin/open -n"))
        XCTAssertEqual(arguments[2], "restart")
        XCTAssertEqual(arguments[3], "/Applications/Fixture.app")
        XCTAssertEqual(arguments[4], "12345")
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

    func testQuitConfirmationMapsEscapeToRunInBackgroundAction() {
        let alert = AppTerminationController.makeQuitConfirmationAlert()

        XCTAssertEqual(alert.buttons.first?.title, "Run in Background")
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons.first?.keyEquivalentModifierMask, [])
    }

    func testActiveRecoverableGuideQuitUsesOneTruthfulDecisionSet() {
        let alert = AppTerminationController.makeActiveGuideAlert(
            context: GuideExitContext(isPrivate: false, hasSteps: true),
            purpose: .quit
        )

        XCTAssertEqual(alert.buttons.map(\.title), ["Stop & Quit", "Keep Capturing in Background", "Cancel"])
        XCTAssertTrue(alert.informativeText.contains("saved for recovery"))
    }

    func testPrivateGuideRestartNeverClaimsRecovery() {
        let alert = AppTerminationController.makeActiveGuideAlert(
            context: GuideExitContext(isPrivate: true, hasSteps: true),
            purpose: .restart
        )

        XCTAssertEqual(alert.buttons.map(\.title), ["Open Guide & Stay", "Discard & Restart", "Cancel"])
        XCTAssertFalse(alert.informativeText.localizedCaseInsensitiveContains("recovery"))
        XCTAssertTrue(alert.messageText.localizedCaseInsensitiveContains("cannot be recovered"))
    }

    private func makeLifecycle(confirmsBeforeQuitting: Bool = true) -> AppLifecycleModel {
        let suiteName = "AppTerminationControllerTests.\(UUID().uuidString)"
        let defaults = makeDefaults(named: suiteName)
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

@MainActor
private final class ExitPreparationStub: ApplicationExitPreparing {
    private(set) var callCount = 0

    func prepareForApplicationExit() async -> Bool {
        callCount += 1
        try? await Task.sleep(nanoseconds: 80_000_000)
        return true
    }
}
