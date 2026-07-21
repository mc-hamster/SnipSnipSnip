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

/// The plain-language choices made in Guide setup. Technical capture preferences
/// remain the persisted source of truth; this value translates intent into them.
nonisolated struct GuideCaptureSetupIntent: Equatable, Sendable {
    var output: GuideOutputIntent
    var audio: GuideAudioIntent

    init(output: GuideOutputIntent, audio: GuideAudioIntent) {
        self.output = output
        self.audio = audio
    }

    init(preferences: GuideCapturePreferences) {
        output = preferences.sourceVideoEnabled ? .stepsAndVideo : .stepsOnly

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
