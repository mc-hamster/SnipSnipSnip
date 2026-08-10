import Combine
import Foundation

enum VideoRecordingPhase: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case finishing
}

@MainActor
final class VideoRecordingLifecycleCoordinator: ObservableObject {
    @Published private(set) var phase: VideoRecordingPhase = .idle
    @Published private(set) var isCommandInFlight = false

    private(set) var generation: UUID?

    var blocksNewCapture: Bool {
        phase != .idle
    }

    func reserveStart() -> UUID? {
        guard phase == .idle else { return nil }
        let generation = UUID()
        self.generation = generation
        phase = .preparing
        return generation
    }

    @discardableResult
    func transition(to nextPhase: VideoRecordingPhase, generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        let isAllowed = switch (phase, nextPhase) {
        case (.preparing, .recording),
             (.recording, .paused),
             (.paused, .recording),
             (.recording, .finishing),
             (.paused, .finishing):
            true
        default:
            false
        }
        guard isAllowed else { return false }
        phase = nextPhase
        return true
    }

    func setCommandInFlight(_ value: Bool, generation: UUID) {
        guard self.generation == generation else { return }
        isCommandInFlight = value
    }

    func reset(generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        phase = .idle
        isCommandInFlight = false
    }
}
