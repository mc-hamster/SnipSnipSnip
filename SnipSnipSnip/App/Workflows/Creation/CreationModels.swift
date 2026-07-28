import Foundation

/// The plain-language outcome selected before acquisition begins.
///
/// This is intentionally separate from `CaptureIntent`, which answers where
/// pixels should be installed. A creation goal answers why the user is
/// acquiring them and therefore which focused workflow should open afterward.
nonisolated enum CreationGoal: Equatable, Sendable {
    case screenshot
    case comparison
    case instructions(InstructionCreationMethod)
    case combineImages

    var documentPurpose: ScreenshotDocumentPurpose? {
        switch self {
        case .screenshot:
            return .screenshot
        case .comparison:
            return .comparison
        case .instructions(.addCaptures):
            return .steps
        case .instructions(.recordAsIWork):
            return nil
        case .combineImages:
            return .collection
        }
    }

    var captureCompletionRole: CaptureCompletionRole? {
        switch self {
        case .screenshot:
            return .standalone
        case .comparison:
            return .comparisonBefore
        case .instructions(.addCaptures):
            return .step
        case .instructions(.recordAsIWork):
            return nil
        case .combineImages:
            return .collectionItem
        }
    }
}

nonisolated enum InstructionCreationMethod: String, CaseIterable, Equatable,
    Identifiable, Sendable
{
    case recordAsIWork
    case addCaptures

    var id: String { rawValue }
}

/// A source choice in the intent-driven setup. Exact window, device, history,
/// or archive selection remains deferred until the plan starts.
nonisolated enum CreationSource: Equatable, Sendable {
    case region
    case window
    case screen
    case existing(CreationExistingSource)
    case scrolling
    case connectedDevice
    case screenInspector

    var supportsCaptureDelay: Bool {
        switch self {
        case .region, .window, .screen, .scrolling:
            return true
        case .existing, .connectedDevice, .screenInspector:
            return false
        }
    }

    var supportsPointerCapture: Bool {
        switch self {
        case .region, .window, .screen:
            return true
        case .existing, .scrolling, .connectedDevice, .screenInspector:
            return false
        }
    }
}

nonisolated enum CreationExistingSource: String, CaseIterable, Equatable,
    Identifiable, Sendable
{
    case files
    case clipboard
    case recentSnips
    case captureHistory
    case archive

    var id: String { rawValue }
}

/// Fully local setup state. It is never persisted and hidden choices are
/// normalized before a plan can leave the setup workflow.
nonisolated struct CreationDraft: Equatable, Sendable {
    var goal: CreationGoal
    var source: CreationSource
    var captureDelay: CaptureDelay
    var includesCursor: Bool
    var privateCapture: Bool
    var windowUIMapEnabled: Bool

    init(
        goal: CreationGoal = .screenshot,
        source: CreationSource = .region,
        captureDelay: CaptureDelay = .immediate,
        includesCursor: Bool = false,
        privateCapture: Bool = false,
        windowUIMapEnabled: Bool = false
    ) {
        self.goal = goal
        self.source = source
        self.captureDelay = captureDelay
        self.includesCursor = includesCursor
        self.privateCapture = privateCapture
        self.windowUIMapEnabled = windowUIMapEnabled
    }

    static let `default` = CreationDraft()

    func normalized(
        for capabilities: AppCapabilitySnapshot
    ) -> CreationDraft {
        var normalized = self

        if goal == .instructions(.recordAsIWork),
           !capabilities.isEnabled(.guideCapture) {
            normalized.goal = .instructions(.addCaptures)
        }

        switch source {
        case .region:
            if !capabilities.isEnabled(.regionCapture) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .window:
            if !capabilities.isEnabled(.windowCapture) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .screen:
            if !capabilities.isEnabled(.fullscreenCapture) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .existing(let existing):
            if !Self.isAvailable(
                existing,
                capabilities: capabilities
            ) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .scrolling:
            if !capabilities.isEnabled(.scrollingCapture) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .connectedDevice:
            if !capabilities.isEnabled(.connectedDeviceCapture) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        case .screenInspector:
            if !capabilities.isEnabled(.screenInspector) {
                normalized.source = fallbackCaptureSource(
                    capabilities: capabilities
                )
            }
        }

        // Guide owns its target selection. A stale source choice from another
        // goal must never leak into the Guide quick start.
        if normalized.goal == .instructions(.recordAsIWork) {
            normalized.source = .region
        }
        if !capabilities.isEnabled(.privateCapture) {
            normalized.privateCapture = false
        }
        switch normalized.source {
        case .scrolling:
            // Scrolling capture deliberately excludes a transient pointer
            // from the stitched document.
            normalized.includesCursor = false
        case .existing:
            // Existing pixels do not run a capture countdown or synthesize a
            // desktop pointer. Clear stale choices before they reach import
            // and history workflows.
            normalized.captureDelay = .immediate
            normalized.includesCursor = false
        case .connectedDevice, .screenInspector:
            // These sources capture from an already-live preview/tool and do
            // not support the desktop countdown or pointer overlay.
            normalized.captureDelay = .immediate
            normalized.includesCursor = false
        case .region, .window, .screen:
            break
        }
        if !capabilities.isEnabled(.uiMap)
            || normalized.source != .window {
            normalized.windowUIMapEnabled = false
        }

        return normalized
    }

    func plan(
        for capabilities: AppCapabilitySnapshot
    ) -> CreationPlan {
        let normalized = normalized(for: capabilities)
        return CreationPlan(
            goal: normalized.goal,
            source: normalized.source,
            captureOptions: CaptureOneShotOptions(
                captureDelay: normalized.captureDelay,
                includesCursor: normalized.includesCursor,
                privateCapture: normalized.privateCapture,
                windowUIMapEnabled: normalized.windowUIMapEnabled
            )
        )
    }

    private func fallbackCaptureSource(
        capabilities: AppCapabilitySnapshot
    ) -> CreationSource {
        if capabilities.isEnabled(.regionCapture) {
            return .region
        }
        if capabilities.isEnabled(.windowCapture) {
            return .window
        }
        if capabilities.isEnabled(.fullscreenCapture) {
            return .screen
        }
        return .existing(.files)
    }

    private static func isAvailable(
        _ source: CreationExistingSource,
        capabilities: AppCapabilitySnapshot
    ) -> Bool {
        switch source {
        case .files, .clipboard:
            return capabilities.isEnabled(.editor)
        case .recentSnips, .captureHistory:
            return capabilities.isEnabled(.recovery)
        case .archive:
            return capabilities.isEnabled(.archive)
        }
    }
}

nonisolated struct CreationPlan: Equatable, Sendable {
    let goal: CreationGoal
    let source: CreationSource
    let captureOptions: CaptureOneShotOptions

    var documentPurpose: ScreenshotDocumentPurpose? {
        goal.documentPurpose
    }

    var captureCompletionRole: CaptureCompletionRole? {
        goal.captureCompletionRole
    }

    var primaryActionTitle: String {
        switch goal {
        case .screenshot:
            switch source {
            case .existing(.files):
                return String(localized: "Import Image")
            case .existing(.clipboard):
                return String(localized: "Paste Image")
            case .existing:
                return String(localized: "Choose Image")
            default:
                return String(localized: "Capture Screenshot")
            }
        case .comparison:
            switch source {
            case .existing(.files):
                return String(localized: "Import Before")
            case .existing(.clipboard):
                return String(localized: "Paste Before")
            case .existing:
                return String(localized: "Choose Before")
            default:
                return String(localized: "Capture Before")
            }
        case .instructions(.recordAsIWork):
            return String(localized: "Continue to Guide")
        case .instructions(.addCaptures):
            switch source {
            case .existing(.files):
                return String(localized: "Import First Step")
            case .existing(.clipboard):
                return String(localized: "Paste First Step")
            case .existing:
                return String(localized: "Choose First Step")
            default:
                return String(localized: "Capture First Step")
            }
        case .combineImages:
            switch source {
            case .existing(.files):
                return String(localized: "Import Images")
            case .existing(.clipboard):
                return String(localized: "Paste First Image")
            case .existing:
                return String(localized: "Choose First Image")
            default:
                return String(localized: "Capture First Image")
            }
        }
    }

    var summary: String {
        switch goal {
        case .screenshot:
            return String(
                localized:
                    "Start with one image, then annotate or polish it."
            )
        case .comparison:
            return String(
                localized:
                    "Start with Before, then add After and review what changed."
            )
        case .instructions(.recordAsIWork):
            return String(
                localized:
                    "Record a Guide; it will build editable steps from your workflow."
            )
        case .instructions(.addCaptures):
            return String(
                localized:
                    "Build Steps manually, then caption and number them."
            )
        case .combineImages:
            return String(
                localized:
                    "Collect captures and images, then arrange them together."
            )
        }
    }
}
