import Foundation

nonisolated enum PermissionRestartVideoSource: String, Codable {
    case screen, region, window
}

/// Only fresh, non-private acquisition can be resumed after process exit.
/// Editor-generation-specific append/replace requests remain in memory; replaying
/// their identities against a recovered editor would target a different session.
nonisolated enum PermissionRestartAction: Codable {
    case screenshot(PendingCapturePermissionCommand, CaptureOneShotOptions)
    case video(PermissionRestartVideoSource, VideoRecordingPreferences)
    case guide(GuideCaptureSetupDraft)

    var requirements: [CapturePermissionRequirement] {
        switch self {
        case .screenshot(let command, let options):
            return command == .scrollingCapture || (options.windowUIMapEnabled && (command == .frontmostWindow || command == .windowPicker))
                ? [.screenRecording, .accessibility] : [.screenRecording]
        case .video: return [.screenRecording]
        case .guide: return [.screenRecording, .accessibility]
        }
    }

    var featureName: String {
        switch self {
        case .screenshot: "Capture"
        case .video: "Video"
        case .guide: "Guide"
        }
    }
}

@MainActor
struct PermissionRestartStore {
    private struct Checkpoint: Codable { let action: PermissionRestartAction; let expiresAt: Date }
    static let key = "permissions.pendingRestartAction.v1"
    let defaults: UserDefaults

    func save(_ action: PermissionRestartAction?, now: Date = Date()) {
        if case .screenshot(_, let options) = action, options.privateCapture {
            defaults.removeObject(forKey: Self.key)
            return
        }
        guard let action,
              let data = try? JSONEncoder().encode(Checkpoint(action: action, expiresAt: now.addingTimeInterval(30 * 60))) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    func load(now: Date = Date()) -> PermissionRestartAction? {
        guard let data = defaults.data(forKey: Self.key),
              let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: data),
              checkpoint.expiresAt > now, checkpoint.expiresAt <= now.addingTimeInterval(30 * 60) else {
            save(nil)
            return nil
        }
        return checkpoint.action
    }
}

@MainActor
enum PermissionRestartCoordinator {
    static func restore(permissions: PermissionWorkflowModel, capture: CaptureWorkflowModel, video: VideoWorkflowModel, guide: GuideWorkflowModel) {
        guard let action = permissions.dependencies.restartStore?.load() else { return }
        guard action.requirements.allSatisfy(permissions.dependencies.permissions.canRequest) else {
            permissions.dependencies.restartStore?.save(nil)
            return
        }
        permissions.permissionContinuation = PermissionOperationContinuation(
            requirements: action.requirements, featureName: action.featureName,
            resume: { [weak capture, weak video, weak guide] in
                switch action {
                case .screenshot(let command, var options):
                    guard let capture else { return }
                    options.privateCapture = options.privateCapture || capture.privateCaptureEnabled
                    switch command {
                    case .currentDisplay: capture.captureCurrentDisplay(intent: .newDocument, oneShotOptions: options)
                    case .region: capture.captureRegion(intent: .newDocument, oneShotOptions: options)
                    case .frontmostWindow, .windowPicker: capture.presentWindowPicker(intent: .newDocument, oneShotOptions: options)
                    case .scrollingCapture: capture.captureScrollingArea(intent: .newDocument, oneShotOptions: options)
                    case .textCapture: capture.captureText()
                    }
                case .video(let source, let preferences):
                    video?.resumeRecordingAfterPermissionRestart(source: source, preferences: preferences)
                case .guide(let draft):
                    guide?.resumeSetupAfterPermissionRestart(draft)
                }
            }
        )
        if case .screenshot(let command, let options) = action,
           options.windowUIMapEnabled,
           command == .frontmostWindow || command == .windowPicker {
            permissions.offerPermissionAlternative(title: String(localized: "Capture Without UI Map")) { [weak permissions, weak capture] in
                guard let permissions, let capture else { return }
                var visualOnlyOptions = options
                visualOnlyOptions.windowUIMapEnabled = false
                visualOnlyOptions.privateCapture = options.privateCapture || capture.privateCaptureEnabled
                permissions.dismissPermissionSetupGuide()
                capture.presentWindowPicker(intent: .newDocument, oneShotOptions: visualOnlyOptions)
            }
        }
        permissions.updateContinuationGuide()
    }
}
