import CoreGraphics
import Foundation

nonisolated enum AutomationValidation {
    private static let maximumGridColumns = 200
    private static let maximumCanvasDimension = 16_384.0
    private static let maximumAspectRatio = 1_000.0
    private static let maximumStepStartIndex = 1_000_000
    private static let minimumBlinkInterval = 0.05
    private static let maximumBlinkInterval = 60.0
    private static let maximumLabelLength = 1_000
    private static let maximumTemplateSelectorLength = 256

    static func validate(_ request: AutomationRequest) -> AutomationError? {
        if let error = validateCaptureDestination(request) {
            return error
        }

        switch request.command {
        case .status, .listPresets, .repeatLastCapture:
            return validate(output: request.output)
        case .runPreset(let command):
            if command.id == nil && (command.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                return AutomationError(code: .invalidRequest, message: "Run preset requires an id or name.")
            }
            return validate(output: request.output)
        case .capture(let command):
            if let error = validate(command.options.delay) {
                return error
            }
            switch command.target {
            case .region(let selector):
                let rect = selector.rect.gscIntegralStandardized
                if rect.isNull
                    || ![rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                    || rect.width < RegionPrecisionGeometry.minimumDimension
                    || rect.height < RegionPrecisionGeometry.minimumDimension {
                    return AutomationError(code: .invalidRequest, message: "Region capture requires a valid x,y,width,height rectangle.")
                }
            case .interactiveRegion, .interactiveWindow:
                if request.interactionPolicy == .never {
                    return AutomationError(code: .invalidRequest, message: "Interactive capture requires an interactive automation policy.")
                }
            case .fullscreen, .frontmostWindow:
                break
            }
            return validate(output: request.output)
        case .openDocument(let command):
            if !command.url.isFileURL {
                return AutomationError(code: .invalidRequest, message: "Open document requires a file URL.")
            }
            return validate(output: request.output)
        case .exportCurrent(let command):
            _ = command
            return validate(output: request.output)
        case .composition(let command):
            if let error = validate(command) {
                return error
            }
            return validate(output: request.output)
        case .guide:
            return validate(output: request.output)
        }
    }

    private static func validate(_ command: CompositionAutomationCommand) -> AutomationError? {
        switch command {
        case .setLayout(let layout):
            if let gridColumns = layout.gridColumns,
               !(1 ... maximumGridColumns).contains(gridColumns) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Grid columns must be between 1 and \(maximumGridColumns)."
                )
            }
            if let targetAspectRatio = layout.targetAspectRatio,
               !isFinite(targetAspectRatio, in: Double.leastNonzeroMagnitude ... maximumAspectRatio) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Target aspect ratio must be finite, greater than zero, and no more than \(Int(maximumAspectRatio))."
                )
            }
            if (layout.freeformCanvasWidth == nil) != (layout.freeformCanvasHeight == nil) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Freeform canvas width and height must be provided together."
                )
            }
            if let width = layout.freeformCanvasWidth,
               !isFinite(width, in: Double.leastNonzeroMagnitude ... maximumCanvasDimension) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Freeform canvas width must be finite, greater than zero, and no more than \(Int(maximumCanvasDimension))."
                )
            }
            if let height = layout.freeformCanvasHeight,
               !isFinite(height, in: Double.leastNonzeroMagnitude ... maximumCanvasDimension) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Freeform canvas height must be finite, greater than zero, and no more than \(Int(maximumCanvasDimension))."
                )
            }
            if let stepStartIndex = layout.stepStartIndex,
               !(0 ... maximumStepStartIndex).contains(stepStartIndex) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Step start index must be between 0 and \(maximumStepStartIndex)."
                )
            }
            return nil
        case .setCompareMode(let compare):
            return validate(compare)
        case .applyTemplate(let template):
            let id = normalized(template.id)
            let name = normalized(template.name)
            guard id != nil || name != nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Composition template requires an id or name."
                )
            }
            if let id, id.count > maximumTemplateSelectorLength {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Composition template id is too long."
                )
            }
            if let name, name.count > maximumTemplateSelectorLength {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Composition template name is too long."
                )
            }
            return nil
        }
    }

    private static func validate(_ compare: AutomationCompositionCompareCommand) -> AutomationError? {
        if (compare.firstItemID == nil) != (compare.secondItemID == nil) {
            return AutomationError(
                code: .invalidRequest,
                message: "Composition comparison item ids must be provided together."
            )
        }
        if let firstItemID = compare.firstItemID, firstItemID == compare.secondItemID {
            return AutomationError(
                code: .invalidRequest,
                message: "Composition comparison requires two different item ids."
            )
        }
        for (value, label) in [
            (compare.wipePosition, "Wipe position"),
            (compare.overlayOpacity, "Overlay opacity"),
            (compare.differenceIntensity, "Difference intensity"),
            (compare.changeHighlightThreshold, "Change-highlight threshold"),
        ] {
            if let value, !isFinite(value, in: 0 ... 1) {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) must be finite and between 0 and 1."
                )
            }
        }
        if let blinkInterval = compare.blinkInterval,
           !isFinite(blinkInterval, in: minimumBlinkInterval ... maximumBlinkInterval) {
            return AutomationError(
                code: .invalidRequest,
                message: "Blink interval must be finite and between \(minimumBlinkInterval) and \(Int(maximumBlinkInterval)) seconds."
            )
        }
        if let color = compare.changeHighlightColorHex,
           !isValidHexColor(color) {
            return AutomationError(
                code: .invalidRequest,
                message: "Change-highlight color must be #RRGGBB or #RRGGBBAA."
            )
        }
        for (value, label) in [
            (compare.primaryLabel, "Primary label"),
            (compare.secondaryLabel, "Secondary label"),
        ] {
            if let value, value.count > maximumLabelLength {
                return AutomationError(
                    code: .invalidRequest,
                    message: "\(label) is too long."
                )
            }
        }
        return nil
    }

    private static func isFinite(
        _ value: Double,
        in range: ClosedRange<Double>
    ) -> Bool {
        value.isFinite && range.contains(value)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#", [7, 9].contains(trimmed.count) else {
            return false
        }
        return trimmed.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func validateCaptureDestination(_ request: AutomationRequest) -> AutomationError? {
        let isCaptureCommand: Bool
        switch request.command {
        case .runPreset, .capture, .repeatLastCapture:
            isCaptureCommand = true
        case .status, .listPresets, .openDocument, .exportCurrent, .composition, .guide:
            isCaptureCommand = false
        }

        if !isCaptureCommand, request.captureDestination != .new {
            return AutomationError(
                code: .invalidRequest,
                message: "Capture destination is only valid for capture, preset, and repeat-last commands."
            )
        }

        switch request.captureDestination {
        case .new:
            guard request.replaceCompositionItemID == nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "A replacement item id is only valid when capture destination is replace."
                )
            }
            guard request.appendAfterCompositionItemID == nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "An append-after item id is only valid when capture destination is append."
                )
            }
        case .append:
            guard request.replaceCompositionItemID == nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "A replacement item id is only valid when capture destination is replace."
                )
            }
        case .replace:
            guard request.appendAfterCompositionItemID == nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "An append-after item id is only valid when capture destination is append."
                )
            }
            guard request.replaceCompositionItemID != nil else {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Replace capture destination requires a composition item id."
                )
            }
        }
        return nil
    }

    private static func validate(_ delay: AutomationCaptureDelay) -> AutomationError? {
        switch delay {
        case .appDefault, .immediate:
            return nil
        case .seconds(let seconds):
            guard [0, 3, 5, 10].contains(seconds) else {
                return AutomationError(code: .invalidRequest, message: "Custom capture delays are not supported yet. Use 0, 3, 5, or 10 seconds.")
            }
            return nil
        }
    }

    private static func validate(output: AutomationOutput) -> AutomationError? {
        switch output {
        case .saveFile(let file), .saveEditableDocument(let file):
            guard let url = file.url, url.isFileURL else {
                return AutomationError(code: .invalidRequest, message: "File output requires a file URL.")
            }
            if case .saveFile = output, file.format == .sss {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Rendered file output supports PNG, JPEG, PDF, GIF, APNG, MP4, and HTML. Use editable document output for .sss."
                )
            }
            if case .saveEditableDocument = output, file.format != .sss {
                return AutomationError(
                    code: .invalidRequest,
                    message: "Editable document output only supports .sss."
                )
            }
            return nil
        case .appDefault, .openEditor, .copyRenderedImage, .floatReference, .none:
            return nil
        }
    }
}

extension AutomationRequest {
    nonisolated var validationError: AutomationError? {
        AutomationValidation.validate(self)
    }
}
