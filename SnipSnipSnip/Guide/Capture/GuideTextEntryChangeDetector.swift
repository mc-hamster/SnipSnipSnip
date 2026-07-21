import CoreGraphics
import Foundation

nonisolated struct GuideTextEntryTargetIdentity: Equatable, Sendable {
    var processID: pid_t?
    var windowID: CGWindowID?
    var role: String?
    var identifier: String?
    var frame: CGRect?
}

nonisolated struct GuideTextEntryObservation: Sendable {
    var target: GuideTextEntryTargetIdentity
    var valueFingerprint: Int
    var caption: GuideCaptionResult
}

/// Detects edits without retaining the value of a text field. The first value
/// observed for each focused field is a baseline, not a user action.
nonisolated struct GuideTextEntryChangeDetector: Sendable {
    private var previous: (target: GuideTextEntryTargetIdentity, valueFingerprint: Int)?

    mutating func consume(_ observation: GuideTextEntryObservation) -> Bool {
        defer {
            previous = (observation.target, observation.valueFingerprint)
        }
        guard let previous, previous.target == observation.target else {
            return false
        }
        return previous.valueFingerprint != observation.valueFingerprint
    }

    mutating func reset() {
        previous = nil
    }
}

@MainActor
final class GuideTextEntryObserver {
    typealias Handler = @MainActor (GuideTextEntryObservation) -> Void

    private let captionGenerator: GuideCaptionGenerator
    private var detector = GuideTextEntryChangeDetector()
    private var observationTask: Task<Void, Never>?

    init(captionGenerator: GuideCaptionGenerator) {
        self.captionGenerator = captionGenerator
    }

    func start(handler: @escaping Handler) {
        stop()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let observation = self.captionGenerator.focusedTextEntryObservation(),
                   self.detector.consume(observation) {
                    handler(observation)
                }
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
        }
    }

    func establishFocusedFieldBaseline() {
        guard let observation = captionGenerator.focusedTextEntryObservation() else { return }
        _ = detector.consume(observation)
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        detector.reset()
    }
}
