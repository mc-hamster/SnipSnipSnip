import CoreGraphics
import Foundation

@MainActor
extension CaptureWorkflowModel {
    var canSaveLastCaptureAsPreset: Bool {
        capturePresetDraftForLastCapture() != nil
    }

    func beginSavingLastCaptureAsPreset() {
        guard let draft = capturePresetDraftForLastCapture() else {
            dependencies.lifecycle.presentError("There is no recent screenshot capture that can be saved as a preset.")
            dependencies.lifecycle.requestMainWindowPresentation()
            return
        }

        pendingCapturePresetDraft = draft
        capturePresetNameDraft = draft.name
        isShowingCapturePresetNamingSheet = true
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func cancelSavingCapturePreset() {
        pendingCapturePresetDraft = nil
        capturePresetNameDraft = ""
        isShowingCapturePresetNamingSheet = false
    }

    func commitCapturePresetName() {
        guard var draft = pendingCapturePresetDraft else {
            cancelSavingCapturePreset()
            return
        }

        let fallbackName = draft.name
        draft.name = uniqueCapturePresetName(capturePresetNameDraft, fallback: fallbackName)
        draft.updatedAt = dependencies.systemServices.clock.now()
        capturePresets.append(draft)
        cancelSavingCapturePreset()
    }

    func renameCapturePreset(id: CapturePreset.ID, to proposedName: String) {
        guard let index = capturePresets.firstIndex(where: { $0.id == id }) else {
            return
        }

        var preset = capturePresets[index]
        preset.name = uniqueCapturePresetName(proposedName, fallback: preset.targetLabel, replacing: id)
        preset.updatedAt = dependencies.systemServices.clock.now()
        capturePresets[index] = preset
    }

    func deleteCapturePreset(id: CapturePreset.ID) {
        capturePresets.removeAll { $0.id == id }
    }

    func moveCapturePreset(id: CapturePreset.ID, offset: Int) {
        guard let sourceIndex = capturePresets.firstIndex(where: { $0.id == id }) else {
            return
        }

        let destinationIndex = min(max(sourceIndex + offset, 0), capturePresets.count - 1)
        guard sourceIndex != destinationIndex else {
            return
        }

        let preset = capturePresets.remove(at: sourceIndex)
        capturePresets.insert(preset, at: destinationIndex)
    }

    func savedCaptureRegion(for rect: CGRect) -> SavedCaptureRegion {
        let display = displayInfo(containingMostOf: rect)
        return SavedCaptureRegion(
            rect: rect,
            displayID: display?.id,
            displayName: display?.name
        )
    }

    func uniqueCapturePresetName(
        _ proposedName: String,
        fallback: String,
        replacing replacedID: CapturePreset.ID? = nil
    ) -> String {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? (fallbackTrimmed.isEmpty ? "Capture Preset" : fallbackTrimmed) : trimmed
        let existingNames = Set(capturePresets.compactMap { preset -> String? in
            if preset.id == replacedID {
                return nil
            }

            return preset.name.lowercased()
        })

        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }

        var suffix = 2
        while existingNames.contains("\(baseName) \(suffix)".lowercased()) {
            suffix += 1
        }

        return "\(baseName) \(suffix)"
    }

    private func capturePresetDraftForLastCapture() -> CapturePreset? {
        guard let lastCaptureRequest,
              let options = lastCaptureRunOptions else {
            return nil
        }

        let target: CapturePresetTarget
        let suggestedName: String

        switch lastCaptureRequest {
        case .region(let rect):
            let savedRegion = savedCaptureRegion(for: rect)
            target = .region(savedRegion)
            suggestedName = "Region \(Int(savedRegion.rect.width.rounded())) x \(Int(savedRegion.rect.height.rounded()))"
        case .window(let window):
            target = .window(SavedWindowTarget(window: window))
            suggestedName = "Window - \(window.ownerName)"
        case .frontmostWindow:
            target = .frontmostWindow
            suggestedName = "Frontmost Window"
        case .fullscreen:
            target = .fullscreen
            suggestedName = fullscreenPresetName(for: options)
        case .scrolling, .connectedDevice:
            return nil
        }

        return CapturePreset(
            name: uniqueCapturePresetName(suggestedName, fallback: suggestedName),
            target: target,
            options: options
        )
    }

    private func displayInfo(containingMostOf rect: CGRect) -> (id: CGDirectDisplayID, name: String)? {
        dependencies.systemServices.screens.screens
            .compactMap { screen -> (id: CGDirectDisplayID, name: String, area: CGFloat)? in
                let displayID = screen.displayID
                let displayFrame = CGDisplayBounds(displayID)
                let intersection = displayFrame.intersection(rect.gscIntegralStandardized)
                return (displayID, screen.name, rectArea(intersection))
            }
            .filter { $0.area > 0 }
            .max { $0.area < $1.area }
            .map { ($0.id, $0.name) }
    }

    private func fullscreenPresetName(for options: CaptureRunOptions) -> String {
        switch options.fullscreenDisplayMode {
        case .currentDisplay:
            return "Fullscreen - Current Display"
        case .selectedDisplay:
            if let selectedID = options.selectedFullscreenDisplayID,
               let screen = dependencies.systemServices.screens.screen(withDisplayID: selectedID) {
                return "Fullscreen - \(screen.name)"
            }

            return "Fullscreen - Selected Display"
        case .allDisplays:
            return "Fullscreen - All Displays"
        }
    }

    private func rectArea(_ rect: CGRect) -> CGFloat {
        let standardized = rect.gscIntegralStandardized
        guard !standardized.isNull else {
            return 0
        }

        return max(standardized.width, 0) * max(standardized.height, 0)
    }
}
