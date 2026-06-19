import Foundation

nonisolated struct AutomationPresetResolver {
    private let presets: [CapturePreset]

    init(presets: [CapturePreset]) {
        self.presets = presets
    }

    func resolve(_ command: RunPresetAutomationCommand) -> CapturePreset? {
        if let id = command.id,
           let preset = presets.first(where: { $0.id == id }) {
            return preset
        }

        guard let name = command.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }

        return presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
