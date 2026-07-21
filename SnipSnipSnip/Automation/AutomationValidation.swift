import CoreGraphics
import Foundation

nonisolated enum AutomationValidation {
    static func validate(_ request: AutomationRequest) -> AutomationError? {
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
                if rect.isNull || rect.width < RegionPrecisionGeometry.minimumDimension || rect.height < RegionPrecisionGeometry.minimumDimension {
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
            if command.format == .sss {
                return AutomationError(code: .invalidRequest, message: "Export current screenshot supports PNG, JPEG, and PDF. Use save editable document output for .sss.")
            }
            return validate(output: request.output)
        case .guide:
            return validate(output: request.output)
        }
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
                return AutomationError(code: .invalidRequest, message: "Rendered file output supports PNG, JPEG, and PDF. Use editable document output for .sss.")
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
