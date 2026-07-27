import Foundation

@MainActor
extension DocumentWorkflowModel {
    var automationCurrentEditorController: EditorController? {
        editorController
    }

    var automationCompositionSummary: AutomationCompositionSummary? {
        guard let editorController else {
            return nil
        }
        return EditorCompositionAutomationExecutor.summary(for: editorController)
    }

    var automationImageExportOptions: ImageExportOptions {
        screenshotImageExportOptions
    }

    func applyAutomationComposition(
        _ command: CompositionAutomationCommand
    ) throws -> AutomationCompositionSummary {
        guard let editorController else {
            throw AutomationExecutionError(
                code: .noActiveComposition,
                message: "Open or create a composition before changing its layout."
            )
        }
        return try EditorCompositionAutomationExecutor().apply(
            command,
            to: editorController
        )
    }

    func openAutomationDocument(
        _ command: OpenDocumentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }

        automationCoordinator.openDocument(command.url)
        return await automationCoordinator.automationResultAfterCurrentEditorOutput(request, "openDocument", command.url.lastPathComponent)
    }

    func exportCurrentAutomationDocument(
        _ command: ExportCurrentAutomationCommand,
        request: AutomationRequest
    ) async -> AutomationResultEnvelope {
        guard let automationCoordinator else {
            return .failure(requestID: request.id, code: .internalError, message: "Automation workflow is not available.")
        }

        var exportRequest = request
        if case .appDefault = exportRequest.output {
            let file = AutomationFileOutput(url: nil, format: command.format)
            exportRequest.output = command.format == .sss
                ? .saveEditableDocument(file)
                : .saveFile(file)
        } else if case .saveFile(let file) = exportRequest.output,
                  command.format == .sss {
            var editableFile = file
            editableFile.format = .sss
            exportRequest.output = .saveEditableDocument(editableFile)
        }
        return await automationCoordinator.automationResultAfterCurrentEditorOutput(exportRequest, "exportCurrent", automationCurrentEditorController?.capture.sourceName)
    }

    func requestAutomationEditorPresentation() {
        dependencies.lifecycle.requestMainWindowPresentation()
    }

    func saveAutomationDocument(_ controller: EditorController, to url: URL) async -> Bool {
        await automationCoordinator?.saveDocument(controller, to: url) ?? false
    }

    func floatAutomationReference() {
        automationCoordinator?.floatCurrentEditorReference()
    }
}

@MainActor
struct EditorCompositionAutomationExecutor {
    func apply(
        _ command: CompositionAutomationCommand,
        to controller: EditorController
    ) throws -> AutomationCompositionSummary {
        guard let composition = controller.composition else {
            throw AutomationExecutionError(
                code: .noActiveComposition,
                message: "Open or create a screenshot before changing its layout."
            )
        }

        let includedItems = composition.items.filter(\.isIncluded)
        guard !includedItems.isEmpty else {
            throw AutomationExecutionError(
                code: .incompatibleCompositionItems,
                message: "The composition has no included images."
            )
        }

        var layout = composition.layout
        var comparison = composition.comparison
        var steps = composition.steps

        switch command {
        case .setLayout(let requested):
            try apply(
                requested,
                includedItemCount: includedItems.count,
                layout: &layout,
                comparison: &comparison,
                steps: &steps
            )
        case .setCompareMode(let requested):
            try apply(
                requested,
                composition: composition,
                includedItems: includedItems,
                layout: &layout,
                comparison: &comparison
            )
        case .applyTemplate(let requested):
            let normalizedID = requested.id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = requested.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let template = normalizedID.flatMap { id in
                controller.compositionTemplates.first { $0.id == id }
            } ?? normalizedName.flatMap { name in
                controller.compositionTemplates.first {
                    $0.name.compare(
                        name,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                }
            }
            guard let template else {
                throw AutomationExecutionError(
                    code: .targetUnavailable,
                    message: "Composition template was not found."
                )
            }
            guard template.isCompatible(itemCount: composition.items.count) else {
                throw AutomationExecutionError(
                    code: .incompatibleCompositionItems,
                    message: "The composition template is not compatible with the current item count."
                )
            }
            do {
                try CompositionTemplateStore.validate(template)
            } catch {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
            controller.beginCoalescedEditorGesture()
            controller.applyCompositionTemplate(id: template.id)
            controller.setDocumentPurpose(
                template.layout.mode.automationDocumentPurpose
            )
            controller.endCoalescedEditorGesture()
            guard let summary = Self.summary(for: controller) else {
                throw AutomationExecutionError(
                    code: .internalError,
                    message: "The composition template could not be applied."
                )
            }
            return summary
        }

        controller.execute(
            SetCompositionAutomationStateCommand(
                layout: layout,
                comparison: comparison,
                steps: steps,
                documentPurpose: layout.mode.automationDocumentPurpose
            )
        )

        guard let summary = Self.summary(for: controller) else {
            throw AutomationExecutionError(
                code: .internalError,
                message: "The composition could not be updated."
            )
        }
        return summary
    }

    static func summary(
        for controller: EditorController
    ) -> AutomationCompositionSummary? {
        guard let composition = controller.composition else {
            return nil
        }
        return AutomationCompositionSummary(
            documentID: controller.documentGenerationID,
            itemCount: composition.items.count,
            layout: composition.layout.mode.automationLayout,
            compareMode: composition.layout.mode == .compare
                ? composition.comparison.mode.automationCompareMode
                : nil,
            selectedItemID: composition.selectedItemIDs.last,
            isPrivate: controller.isPrivateDocument
        )
    }

    private func apply(
        _ requested: AutomationCompositionLayoutCommand,
        includedItemCount: Int,
        layout: inout CompositionLayoutConfiguration,
        comparison: inout CompositionComparisonSettings,
        steps: inout CompositionStepsSettings
    ) throws {
        if requested.layout == .compare, includedItemCount < 2 {
            throw AutomationExecutionError(
                code: .compositionRequiresMultipleItems,
                message: "Comparison layouts require at least two included images."
            )
        }

        layout.mode = requested.layout.compositionLayout
        if let gridColumns = requested.gridColumns {
            guard gridColumns >= 1 else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Grid columns must be at least 1."
                )
            }
            layout.gridColumns = gridColumns
        }
        if let targetAspectRatio = requested.targetAspectRatio {
            guard targetAspectRatio > 0 else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Target aspect ratio must be greater than zero."
                )
            }
            layout.targetAspectRatio = CGFloat(targetAspectRatio)
        }
        if let width = requested.freeformCanvasWidth,
           let height = requested.freeformCanvasHeight {
            guard width > 0, height > 0 else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Freeform canvas dimensions must be greater than zero."
                )
            }
            layout.freeformCanvasSize = CGSize(width: width, height: height)
        } else if requested.freeformCanvasWidth != nil
                    || requested.freeformCanvasHeight != nil {
            throw AutomationExecutionError(
                code: .invalidRequest,
                message: "Freeform canvas width and height must be provided together."
            )
        }

        if let axis = requested.axis {
            switch requested.layout {
            case .compare:
                comparison.axis = axis.compositionAxis
            case .steps:
                steps.axis = axis.compositionAxis
            case .auto, .row, .column, .grid, .freeform:
                break
            }
        }
        if let numberingStyle = requested.stepNumberingStyle {
            steps.numberingStyle = numberingStyle.compositionNumberingStyle
        }
        if let startIndex = requested.stepStartIndex {
            guard startIndex >= 0 else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Step start index cannot be negative."
                )
            }
            steps.startIndex = startIndex
        }
        if let showsCaptions = requested.stepShowsCaptions {
            steps.showsCaptions = showsCaptions
        }
        if let connectorStyle = requested.stepConnectorStyle {
            steps.connectorStyle = connectorStyle.compositionConnectorStyle
        }
    }

    private func apply(
        _ requested: AutomationCompositionCompareCommand,
        composition: CompositionSnapshot,
        includedItems: [CompositionItem],
        layout: inout CompositionLayoutConfiguration,
        comparison: inout CompositionComparisonSettings
    ) throws {
        guard includedItems.count >= 2 else {
            throw AutomationExecutionError(
                code: .compositionRequiresMultipleItems,
                message: "Comparison requires at least two included images."
            )
        }

        let includedIDs = Set(includedItems.map(\.id))
        if let firstItemID = requested.firstItemID,
           let secondItemID = requested.secondItemID {
            guard composition.items.contains(where: { $0.id == firstItemID }) else {
                throw compositionItemNotFound(firstItemID)
            }
            guard composition.items.contains(where: { $0.id == secondItemID }) else {
                throw compositionItemNotFound(secondItemID)
            }
            guard includedIDs.contains(firstItemID),
                  includedIDs.contains(secondItemID) else {
                throw AutomationExecutionError(
                    code: .incompatibleCompositionItems,
                    message: "Comparison items must both be included in the composition."
                )
            }
            guard firstItemID != secondItemID else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Comparison requires two different item ids."
                )
            }
            comparison.primaryItemID = firstItemID
            comparison.secondaryItemID = secondItemID
        } else if requested.firstItemID != nil || requested.secondItemID != nil {
            throw AutomationExecutionError(
                code: .invalidRequest,
                message: "Composition comparison item ids must be provided together."
            )
        } else {
            let primaryID = comparison.primaryItemID.flatMap {
                includedIDs.contains($0) ? $0 : nil
            } ?? includedItems[0].id
            let secondaryID = comparison.secondaryItemID.flatMap {
                includedIDs.contains($0) && $0 != primaryID ? $0 : nil
            } ?? includedItems.first(where: { $0.id != primaryID })!.id
            comparison.primaryItemID = primaryID
            comparison.secondaryItemID = secondaryID
        }

        layout.mode = .compare
        comparison.mode = requested.mode.compositionCompareMode
        if let axis = requested.axis {
            comparison.axis = axis.compositionAxis
        }
        if let wipePosition = requested.wipePosition {
            try validateUnitInterval(wipePosition, label: "Wipe position")
            comparison.wipePosition = CGFloat(wipePosition)
        }
        if let overlayOpacity = requested.overlayOpacity {
            try validateUnitInterval(overlayOpacity, label: "Overlay opacity")
            comparison.overlayOpacity = CGFloat(overlayOpacity)
        }
        if let blinkInterval = requested.blinkInterval {
            guard blinkInterval > 0 else {
                throw AutomationExecutionError(
                    code: .invalidRequest,
                    message: "Blink interval must be greater than zero."
                )
            }
            comparison.blinkInterval = blinkInterval
        }
        if let differenceIntensity = requested.differenceIntensity {
            try validateUnitInterval(
                differenceIntensity,
                label: "Difference intensity"
            )
            comparison.differenceIntensity = CGFloat(differenceIntensity)
        }
        if let colorHex = requested.changeHighlightColorHex {
            comparison.changeHighlightColor = try rgbaColor(hex: colorHex)
        }
        if let threshold = requested.changeHighlightThreshold {
            try validateUnitInterval(
                threshold,
                label: "Change-highlight threshold"
            )
            comparison.changeThreshold = CGFloat(threshold)
        }
        if let primaryLabel = requested.primaryLabel {
            comparison.primaryLabel = primaryLabel
        }
        if let secondaryLabel = requested.secondaryLabel {
            comparison.secondaryLabel = secondaryLabel
        }
    }

    private func compositionItemNotFound(_ id: UUID) -> AutomationExecutionError {
        AutomationExecutionError(
            code: .compositionItemNotFound,
            message: "Composition item \(id.uuidString) was not found."
        )
    }

    private func validateUnitInterval(
        _ value: Double,
        label: String
    ) throws {
        guard (0 ... 1).contains(value) else {
            throw AutomationExecutionError(
                code: .invalidRequest,
                message: "\(label) must be between 0 and 1."
            )
        }
    }

    private func rgbaColor(hex: String) throws -> RGBAColor {
        let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [6, 8].contains(digits.count),
              let value = UInt64(digits, radix: 16) else {
            throw AutomationExecutionError(
                code: .invalidRequest,
                message: "Change-highlight color must be #RRGGBB or #RRGGBBAA."
            )
        }

        let hasAlpha = digits.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        return RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private nonisolated struct SetCompositionAutomationStateCommand: DocumentCommand {
    let layout: CompositionLayoutConfiguration
    let comparison: CompositionComparisonSettings
    let steps: CompositionStepsSettings
    let documentPurpose: ScreenshotDocumentPurpose

    var label: String {
        "Update Composition"
    }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        composition.layout = layout
        composition.comparison = comparison
        composition.steps = steps
        switch documentPurpose {
        case .screenshot:
            composition.isActivated = false
        case .comparison:
            composition.isActivated =
                composition.items.filter(\.isIncluded).count >= 2
        case .steps, .collection:
            composition.isActivated = true
        }
        composition.repairComparisonSelection()
        var updated = snapshot
        updated.composition = composition
        updated.documentPurpose = documentPurpose
        return updated
    }
}

private nonisolated extension CompositionLayoutMode {
    var automationDocumentPurpose: ScreenshotDocumentPurpose {
        switch self {
        case .compare:
            return .comparison
        case .steps:
            return .steps
        case .auto, .row, .column, .grid, .freeform:
            return .collection
        }
    }
}

private nonisolated extension AutomationCompositionLayout {
    var compositionLayout: CompositionLayoutMode {
        switch self {
        case .auto: .auto
        case .compare: .compare
        case .steps: .steps
        case .row: .row
        case .column: .column
        case .grid: .grid
        case .freeform: .freeform
        }
    }
}

private nonisolated extension CompositionLayoutMode {
    var automationLayout: AutomationCompositionLayout {
        switch self {
        case .auto: .auto
        case .compare: .compare
        case .steps: .steps
        case .row: .row
        case .column: .column
        case .grid: .grid
        case .freeform: .freeform
        }
    }
}

private nonisolated extension AutomationCompositionCompareMode {
    var compositionCompareMode: CompositionComparisonMode {
        switch self {
        case .sideBySide: .sideBySide
        case .overlay: .overlay
        case .wipe: .wipe
        case .blink: .blink
        case .difference: .difference
        case .changeHighlight: .changeHighlight
        }
    }
}

private nonisolated extension CompositionComparisonMode {
    var automationCompareMode: AutomationCompositionCompareMode {
        switch self {
        case .sideBySide: .sideBySide
        case .overlay: .overlay
        case .wipe: .wipe
        case .blink: .blink
        case .difference: .difference
        case .changeHighlight: .changeHighlight
        }
    }
}

private nonisolated extension AutomationCompositionAxis {
    var compositionAxis: CompositionAxis {
        switch self {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }
}

private nonisolated extension AutomationCompositionStepNumberingStyle {
    var compositionNumberingStyle: CompositionStepNumberingStyle {
        switch self {
        case .none: .none
        case .decimal: .decimal
        case .uppercaseLetters: .uppercaseLetters
        case .lowercaseLetters: .lowercaseLetters
        case .uppercaseRoman: .uppercaseRoman
        case .lowercaseRoman: .lowercaseRoman
        }
    }
}

private nonisolated extension AutomationCompositionStepConnectorStyle {
    var compositionConnectorStyle: CompositionStepConnectorStyle {
        switch self {
        case .none: .none
        case .line: .line
        case .arrow: .arrow
        }
    }
}
