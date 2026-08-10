import AppKit
import OSLog

@MainActor
protocol ApplicationExitPreparing: AnyObject {
    func prepareForApplicationExit() async -> Bool
}

extension DocumentWorkflowModel: ApplicationExitPreparing {}

struct VideoExitContext: Equatable {
    let phase: VideoRecordingPhase
}

@MainActor
protocol ActiveVideoExitPreparing: AnyObject {
    var exitContext: VideoExitContext? { get }
    func prepareRecordingForApplicationExit() async -> Bool
}

extension VideoWorkflowModel: ActiveVideoExitPreparing {
    var exitContext: VideoExitContext? {
        recordingLifecycle.blocksNewCapture
            ? VideoExitContext(phase: recordingLifecycle.phase)
            : nil
    }
}

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
    /usr/bin/open "$app_path"
    """

    struct QuitConfirmationResult: Equatable {
        var shouldQuit: Bool
        var suppressFutureConfirmations: Bool
    }

    enum ExitPurpose: Equatable {
        case quit
        case restart
    }

    enum ActiveGuideDecision: Equatable {
        case finalizeAndExit
        case keepRecordingInBackground
        case openAndStay
        case discardAndExit
        case cancel
    }

    enum ActiveVideoDecision: Equatable {
        case finalizeAndExit
        case keepRecordingInBackground
        case cancel
    }

    typealias QuitConfirmationHandler = @MainActor (AppLifecycleModel?) -> QuitConfirmationResult
    typealias BackgroundHandler = @MainActor () -> Void
    typealias TerminationHandler = @MainActor () -> Void
    typealias RelaunchHandler = @MainActor () -> Void
    typealias ActiveGuideDecisionHandler = @MainActor (GuideExitContext, ExitPurpose) -> ActiveGuideDecision
    typealias ActiveVideoDecisionHandler = @MainActor (VideoExitContext, ExitPurpose) -> ActiveVideoDecision

    private weak var lifecycle: AppLifecycleModel?
    private weak var guide: GuideWorkflowModel?
    private weak var video: (any ActiveVideoExitPreparing)?
    private weak var documents: (any ApplicationExitPreparing)?
    private let confirmationHandler: QuitConfirmationHandler
    private let backgroundHandler: BackgroundHandler
    private let terminationHandler: TerminationHandler
    private let relaunchHandler: RelaunchHandler
    private let activeGuideDecisionHandler: ActiveGuideDecisionHandler
    private let activeVideoDecisionHandler: ActiveVideoDecisionHandler
    private var isPresentingQuitConfirmation = false
    private var isFinalizingForTermination = false
    private var isPerformingConfirmedTermination = false

    init(
        confirmationHandler: @escaping QuitConfirmationHandler = AppTerminationController.presentQuitConfirmation,
        backgroundHandler: @escaping BackgroundHandler = AppTerminationController.runApplicationInBackground,
        terminationHandler: @escaping TerminationHandler = AppTerminationController.terminateApplication,
        relaunchHandler: @escaping RelaunchHandler = AppTerminationController.relaunchApplication,
        activeGuideDecisionHandler: @escaping ActiveGuideDecisionHandler = AppTerminationController.presentActiveGuideDecision,
        activeVideoDecisionHandler: @escaping ActiveVideoDecisionHandler = AppTerminationController.presentActiveVideoDecision
    ) {
        self.confirmationHandler = confirmationHandler
        self.backgroundHandler = backgroundHandler
        self.terminationHandler = terminationHandler
        self.relaunchHandler = relaunchHandler
        self.activeGuideDecisionHandler = activeGuideDecisionHandler
        self.activeVideoDecisionHandler = activeVideoDecisionHandler
    }

    func configure(
        lifecycle: AppLifecycleModel,
        video: (any ActiveVideoExitPreparing)? = nil,
        guide: GuideWorkflowModel? = nil,
        documents: (any ApplicationExitPreparing)? = nil
    ) {
        self.lifecycle = lifecycle
        self.video = video
        self.guide = guide
        self.documents = documents
    }

    func requestQuit() {
        guard !isPresentingQuitConfirmation, !isFinalizingForTermination else {
            return
        }

        if let context = video?.exitContext {
            handleActiveVideoRequest(context: context, purpose: .quit)
            return
        }

        if let context = guide?.exitContext {
            handleActiveGuideRequest(context: context, purpose: .quit)
            return
        }

        guard shouldQuitAfterConfirmation() else {
            runInBackground()
            return
        }

        prepareDocumentsThen { controller in
            controller.performConfirmedTermination()
        }
    }

    func requestRestartWithoutConfirmation() {
        guard !isPresentingQuitConfirmation, !isFinalizingForTermination else {
            Self.logger.info("Restart request ignored because quit confirmation is already visible")
            return
        }

        Self.logger.info("Restart without confirmation requested")
        if let context = video?.exitContext {
            handleActiveVideoRequest(context: context, purpose: .restart)
        } else if let context = guide?.exitContext {
            handleActiveGuideRequest(context: context, purpose: .restart)
        } else {
            prepareDocumentsThen { controller in
                controller.relaunchHandler()
                controller.performConfirmedTermination()
            }
        }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard !isPerformingConfirmedTermination else {
            isPerformingConfirmedTermination = false
            return .terminateNow
        }

        guard !isFinalizingForTermination else {
            return .terminateLater
        }

        guard !isPresentingQuitConfirmation else {
            return .terminateCancel
        }

        if let context = video?.exitContext {
            let decision = decideActiveVideo(context: context, purpose: .quit)
            switch decision {
            case .cancel:
                return .terminateCancel
            case .keepRecordingInBackground:
                runInBackground()
                return .terminateCancel
            case .finalizeAndExit:
                isFinalizingForTermination = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let didFinalize = await video?.prepareRecordingForApplicationExit() ?? true
                    let didPrepareDocuments = didFinalize
                        ? await documents?.prepareForApplicationExit() ?? true
                        : false
                    isFinalizingForTermination = false
                    NSApp.reply(toApplicationShouldTerminate: didPrepareDocuments)
                }
                return .terminateLater
            }
        }

        if let context = guide?.exitContext {
            let decision = decideActiveGuide(context: context, purpose: .quit)
            switch decision {
            case .cancel:
                return .terminateCancel
            case .keepRecordingInBackground:
                runInBackground()
                return .terminateCancel
            case .openAndStay:
                isFinalizingForTermination = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await guide?.prepareForApplicationExit(.openAndStay)
                    isFinalizingForTermination = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                return .terminateLater
            case .finalizeAndExit, .discardAndExit:
                break
            }
            isFinalizingForTermination = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let action: GuideExitAction = decision == .discardAndExit ? .discard : .finalizeForRecovery
                let result = await guide?.prepareForApplicationExit(action) ?? .readyToExit
                let didPrepareDocuments = result == .readyToExit
                    ? await documents?.prepareForApplicationExit() ?? true
                    : false
                isFinalizingForTermination = false
                NSApp.reply(toApplicationShouldTerminate: didPrepareDocuments)
            }
            return .terminateLater
        }

        guard shouldQuitAfterConfirmation() else {
            runInBackground()
            return .terminateCancel
        }

        guard documents != nil else {
            return .terminateNow
        }

        isFinalizingForTermination = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didPrepare = await documents?.prepareForApplicationExit() ?? true
            isFinalizingForTermination = false
            NSApp.reply(toApplicationShouldTerminate: didPrepare)
        }
        return .terminateLater
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

    private func handleActiveGuideRequest(context: GuideExitContext, purpose: ExitPurpose) {
        let decision = decideActiveGuide(context: context, purpose: purpose)
        switch decision {
        case .cancel:
            return
        case .keepRecordingInBackground:
            runInBackground()
        case .openAndStay:
            isFinalizingForTermination = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await guide?.prepareForApplicationExit(.openAndStay)
                isFinalizingForTermination = false
            }
        case .finalizeAndExit, .discardAndExit:
            isFinalizingForTermination = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let action: GuideExitAction = decision == .discardAndExit ? .discard : .finalizeForRecovery
                let result = await guide?.prepareForApplicationExit(action) ?? .readyToExit
                guard result == .readyToExit,
                      await documents?.prepareForApplicationExit() != false else {
                    isFinalizingForTermination = false
                    return
                }
                isFinalizingForTermination = false
                if purpose == .restart { relaunchHandler() }
                performConfirmedTermination()
            }
        }
    }

    private func handleActiveVideoRequest(context: VideoExitContext, purpose: ExitPurpose) {
        let decision = decideActiveVideo(context: context, purpose: purpose)
        switch decision {
        case .cancel:
            return
        case .keepRecordingInBackground:
            runInBackground()
        case .finalizeAndExit:
            isFinalizingForTermination = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard await video?.prepareRecordingForApplicationExit() != false,
                      await documents?.prepareForApplicationExit() != false else {
                    isFinalizingForTermination = false
                    return
                }
                isFinalizingForTermination = false
                if purpose == .restart { relaunchHandler() }
                performConfirmedTermination()
            }
        }
    }

    private func prepareDocumentsThen(
        completion: @escaping @MainActor (AppTerminationController) -> Void
    ) {
        guard documents != nil else {
            completion(self)
            return
        }

        isFinalizingForTermination = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didPrepare = await documents?.prepareForApplicationExit() ?? true
            isFinalizingForTermination = false
            guard didPrepare else { return }
            completion(self)
        }
    }

    private func decideActiveGuide(context: GuideExitContext, purpose: ExitPurpose) -> ActiveGuideDecision {
        isPresentingQuitConfirmation = true
        defer { isPresentingQuitConfirmation = false }
        return activeGuideDecisionHandler(context, purpose)
    }

    private func decideActiveVideo(context: VideoExitContext, purpose: ExitPurpose) -> ActiveVideoDecision {
        isPresentingQuitConfirmation = true
        defer { isPresentingQuitConfirmation = false }
        return activeVideoDecisionHandler(context, purpose)
    }

    static func makeActiveVideoAlert(context: VideoExitContext, purpose: ExitPurpose) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = purpose == .restart ? "Stop Video and restart?" : "Stop Video and quit?"
        alert.informativeText = context.phase == .preparing
            ? "The pending recording will be canceled before the app exits."
            : "The recording will be finalized and saved for recovery before the app exits."
        alert.addButton(withTitle: purpose == .restart ? "Stop & Restart" : "Stop & Quit")
        if purpose == .quit {
            alert.addButton(withTitle: "Keep Recording in Background")
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    private static func presentActiveVideoDecision(
        context: VideoExitContext,
        purpose: ExitPurpose
    ) -> ActiveVideoDecision {
        let response = makeActiveVideoAlert(context: context, purpose: purpose).runModal()
        if response == .alertFirstButtonReturn { return .finalizeAndExit }
        if purpose == .quit, response == .alertSecondButtonReturn { return .keepRecordingInBackground }
        return .cancel
    }

    static func makeActiveGuideAlert(context: GuideExitContext, purpose: ExitPurpose) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if context.isPrivate {
            alert.messageText = purpose == .restart ? "This private Guide cannot be recovered after restart" : "This private Guide cannot be recovered after quitting"
            alert.informativeText = context.hasSteps
                ? "Open the Guide to save or export it, or discard it and continue."
                : "The private capture has no completed steps and can be discarded."
            alert.addButton(withTitle: "Open Guide & Stay")
            alert.addButton(withTitle: purpose == .restart ? "Discard & Restart" : "Discard & Quit")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.messageText = purpose == .restart ? "Stop Guide and restart?" : "Stop Guide and quit?"
            alert.informativeText = "Completed steps and finalized source media will be saved for recovery first."
            alert.addButton(withTitle: purpose == .restart ? "Stop & Restart" : "Stop & Quit")
            if purpose == .quit {
                alert.addButton(withTitle: "Keep Capturing in Background")
            }
            alert.addButton(withTitle: "Cancel")
        }
        return alert
    }

    private static func presentActiveGuideDecision(context: GuideExitContext, purpose: ExitPurpose) -> ActiveGuideDecision {
        let alert = makeActiveGuideAlert(context: context, purpose: purpose)
        let response = alert.runModal()
        if context.isPrivate {
            switch response {
            case .alertFirstButtonReturn: return .openAndStay
            case .alertSecondButtonReturn: return .discardAndExit
            default: return .cancel
            }
        }
        if response == .alertFirstButtonReturn { return .finalizeAndExit }
        if purpose == .quit, response == .alertSecondButtonReturn { return .keepRecordingInBackground }
        return .cancel
    }

    static func makeQuitConfirmationAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit \(AppBranding.displayName)?"
        alert.informativeText = "To keep capture shortcuts, clipboard history, and the menu bar icon ready, let \(AppBranding.displayName) run in the background."
        alert.addButton(withTitle: "Run in Background")
        alert.addButton(withTitle: "Quit")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        alert.buttons.first?.keyEquivalentModifierMask = []

        return alert
    }

    private static func presentQuitConfirmation(_: AppLifecycleModel?) -> QuitConfirmationResult {
        let alert = makeQuitConfirmationAlert()
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
        let appPath = Bundle.main.bundleURL.path
        let processID = getpid()

        if launchRestartHelper(
            executableURL: URL(fileURLWithPath: "/usr/bin/nohup"),
            arguments: restartLauncherArguments(appPath: appPath, processID: processID)
        ) {
            logger.info(
                "Restart helper launched appPath=\(appPath, privacy: .public) currentPID=\(processID, privacy: .public)"
            )
            return
        }

        if launchRestartHelper(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: restartFallbackLauncherArguments(appPath: appPath, processID: processID)
        ) {
            logger.info(
                "Restart fallback launched appPath=\(appPath, privacy: .public) currentPID=\(processID, privacy: .public)"
            )
            return
        }

        logger.error("Failed to launch restart helper or fallback appPath=\(appPath, privacy: .public)")
    }

    @discardableResult
    private static func launchRestartHelper(executableURL: URL, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            logger.error(
                "Failed to launch restart helper executable=\(executableURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
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

    nonisolated static func restartFallbackLauncherArguments(appPath: String, processID: pid_t) -> [String] {
        [
            "-c",
            restartLauncherScript,
            "restart",
            appPath,
            String(processID)
        ]
    }
}
