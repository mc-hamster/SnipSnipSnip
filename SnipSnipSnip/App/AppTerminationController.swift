import AppKit
import OSLog

@MainActor
final class AppTerminationController {
    static let shared = AppTerminationController()
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SnipSnipSnip",
        category: "AppTermination"
    )
    nonisolated private static let restartLauncherScript = """
    app_path=$1
    parent_pid=$2
    while kill -0 "$parent_pid" 2>/dev/null; do
      sleep 0.1
    done
    /usr/bin/open -n "$app_path"
    """

    struct QuitConfirmationResult: Equatable {
        var shouldQuit: Bool
        var suppressFutureConfirmations: Bool
    }

    typealias QuitConfirmationHandler = @MainActor (AppLifecycleModel?) -> QuitConfirmationResult
    typealias BackgroundHandler = @MainActor () -> Void
    typealias TerminationHandler = @MainActor () -> Void
    typealias RelaunchHandler = @MainActor () -> Void

    private weak var lifecycle: AppLifecycleModel?
    private let confirmationHandler: QuitConfirmationHandler
    private let backgroundHandler: BackgroundHandler
    private let terminationHandler: TerminationHandler
    private let relaunchHandler: RelaunchHandler
    private var isPresentingQuitConfirmation = false
    private var isPerformingConfirmedTermination = false

    init(
        confirmationHandler: @escaping QuitConfirmationHandler = AppTerminationController.presentQuitConfirmation,
        backgroundHandler: @escaping BackgroundHandler = AppTerminationController.runApplicationInBackground,
        terminationHandler: @escaping TerminationHandler = AppTerminationController.terminateApplication,
        relaunchHandler: @escaping RelaunchHandler = AppTerminationController.relaunchApplication
    ) {
        self.confirmationHandler = confirmationHandler
        self.backgroundHandler = backgroundHandler
        self.terminationHandler = terminationHandler
        self.relaunchHandler = relaunchHandler
    }

    func configure(lifecycle: AppLifecycleModel) {
        self.lifecycle = lifecycle
    }

    func requestQuit() {
        guard !isPresentingQuitConfirmation else {
            return
        }

        guard shouldQuitAfterConfirmation() else {
            runInBackground()
            return
        }

        performConfirmedTermination()
    }

    func requestRestartWithoutConfirmation() {
        guard !isPresentingQuitConfirmation else {
            Self.logger.info("Restart request ignored because quit confirmation is already visible")
            return
        }

        Self.logger.info("Restart without confirmation requested")
        relaunchHandler()
        performConfirmedTermination()
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard !isPerformingConfirmedTermination else {
            isPerformingConfirmedTermination = false
            return .terminateNow
        }

        guard !isPresentingQuitConfirmation else {
            return .terminateCancel
        }

        guard shouldQuitAfterConfirmation() else {
            runInBackground()
            return .terminateCancel
        }

        return .terminateNow
    }

    private func shouldQuitAfterConfirmation() -> Bool {
        guard lifecycle?.confirmsBeforeQuitting ?? true else {
            return true
        }

        isPresentingQuitConfirmation = true
        defer { isPresentingQuitConfirmation = false }

        let result = confirmationHandler(lifecycle)
        guard result.shouldQuit else {
            return false
        }

        if result.suppressFutureConfirmations {
            lifecycle?.confirmsBeforeQuitting = false
        }

        return true
    }

    private static func presentQuitConfirmation(_: AppLifecycleModel?) -> QuitConfirmationResult {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(AppBranding.displayName)?"
        alert.informativeText = "To keep capture shortcuts, clipboard history, and the menu bar icon ready, let \(AppBranding.displayName) run in the background."
        alert.addButton(withTitle: "Run in Background")
        alert.addButton(withTitle: "Quit")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else {
            return QuitConfirmationResult(shouldQuit: false, suppressFutureConfirmations: false)
        }

        return QuitConfirmationResult(
            shouldQuit: true,
            suppressFutureConfirmations: alert.suppressionButton?.state == .on
        )
    }

    private func runInBackground() {
        backgroundHandler()
    }

    private static func runApplicationInBackground() {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            window.performMiniaturize(nil)
        } else {
            NSApp.hide(nil)
        }
    }

    private func performConfirmedTermination() {
        isPerformingConfirmedTermination = true
        terminationHandler()
    }

    private static func terminateApplication() {
        NSApp.terminate(nil)
    }

    private static func relaunchApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = restartLauncherArguments(
            appPath: Bundle.main.bundleURL.path,
            processID: getpid()
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            logger.info(
                "Restart helper launched appPath=\(Bundle.main.bundleURL.path, privacy: .public) currentPID=\(getpid(), privacy: .public)"
            )
            return
        } catch {
            logger.error("Failed to launch restart helper: \(error.localizedDescription, privacy: .public)")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        )
        logger.info("Restart fallback requested through NSWorkspace appPath=\(Bundle.main.bundleURL.path, privacy: .public)")
    }

    nonisolated static func restartLauncherArguments(appPath: String, processID: pid_t) -> [String] {
        [
            "/bin/sh",
            "-c",
            restartLauncherScript,
            "restart",
            appPath,
            String(processID)
        ]
    }
}
