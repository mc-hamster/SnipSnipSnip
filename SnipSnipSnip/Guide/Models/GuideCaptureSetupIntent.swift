import Foundation

nonisolated enum GuideOutputIntent: String, CaseIterable, Identifiable, Sendable {
    case stepsOnly
    case stepsAndVideo

    var id: String { rawValue }
}

nonisolated enum GuideAudioIntent: String, CaseIterable, Identifiable, Sendable {
    case none
    case narration
    case appAudio
    case narrationAndAppAudio

    var id: String { rawValue }
}

nonisolated enum GuideTargetPickerKind: String, Equatable, Identifiable, Sendable {
    case window
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "Choose Window"
        case .app: "Choose App"
        }
    }

    var collectionTitle: String {
        switch self {
        case .window: "Windows"
        case .app: "Apps"
        }
    }

    var onScreenDetail: String {
        switch self {
        case .window:
            "Hover a visible window to highlight it, then click to start the Guide."
        case .app:
            "Hover any visible window from the app, then click to start the Guide."
        }
    }

    func source(for window: CaptureWindowSummary) -> GuideCaptureSource {
        switch self {
        case .window:
            .window(
                id: window.id,
                ownerPID: window.ownerPID,
                name: window.displayTitle,
                frame: window.frame
            )
        case .app:
            .app(
                processID: window.ownerPID,
                bundleIdentifier: nil,
                name: window.ownerName,
                initialFrame: window.frame
            )
        }
    }
}

/// The plain-language choices made in Guide setup. Technical capture preferences
/// remain the persisted source of truth; this value translates intent into them.
nonisolated struct GuideCaptureSetupIntent: Equatable, Sendable {
    var output: GuideOutputIntent
    var audio: GuideAudioIntent
    var showsStepNumbers: Bool
    var showsActionTargets: Bool

    init(
        output: GuideOutputIntent,
        audio: GuideAudioIntent,
        showsStepNumbers: Bool = true,
        showsActionTargets: Bool = true
    ) {
        self.output = output
        self.audio = audio
        self.showsStepNumbers = showsStepNumbers
        self.showsActionTargets = showsActionTargets
    }

    init(preferences: GuideCapturePreferences) {
        output = preferences.sourceVideoEnabled ? .stepsAndVideo : .stepsOnly
        showsStepNumbers = preferences.resolvedShowsStepNumbers
        showsActionTargets = preferences.resolvedShowsActionTargets

        switch (preferences.capturesMicrophone, preferences.capturesSystemAudio) {
        case (true, true): audio = .narrationAndAppAudio
        case (true, false): audio = .narration
        case (false, true): audio = .appAudio
        case (false, false): audio = .none
        }
    }

    func applying(to preferences: GuideCapturePreferences) -> GuideCapturePreferences {
        var result = preferences
        result.sourceVideoEnabled = output == .stepsAndVideo
        result.showsStepNumbers = showsStepNumbers
        result.showsActionTargets = showsActionTargets

        guard result.sourceVideoEnabled else {
            result.capturesMicrophone = false
            result.capturesSystemAudio = false
            return result
        }

        switch audio {
        case .none:
            result.capturesMicrophone = false
            result.capturesSystemAudio = false
        case .narration:
            result.capturesMicrophone = true
            result.capturesSystemAudio = false
        case .appAudio:
            result.capturesMicrophone = false
            result.capturesSystemAudio = true
        case .narrationAndAppAudio:
            result.capturesMicrophone = true
            result.capturesSystemAudio = true
        }

        return result
    }
}
