import AppKit
import CoreGraphics
import Foundation

nonisolated struct PresentationPreviewRenderInput: @unchecked Sendable {
    let contentImage: CGImage
    let presentation: ScreenshotPresentation
    let contentRevision: Int
}

extension EditorController {
    func presentationPreviewImage(
        presentation: ScreenshotPresentation? = nil,
        maxPixelDimension: CGFloat? = nil,
        context: String = "previewImage"
    ) -> CGImage? {
        presentationPreviewRender(
            presentation: presentation,
            maxPixelDimension: maxPixelDimension,
            context: context
        )?.image
    }

    func presentationPreviewRender(
        presentation: ScreenshotPresentation? = nil,
        maxPixelDimension: CGFloat? = nil,
        context: String = "previewRender"
    ) -> ScreenshotPresentationRenderResult? {
        guard let input = presentationPreviewRenderInput(presentation: presentation, context: context) else {
            return nil
        }

        return PresentationPerformanceMetrics.measure(
            "controller.presentationWrapper",
            context: "source=\(context) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) \(PresentationPerformanceMetrics.presentationSummary(input.presentation, maxPixelDimension: maxPixelDimension))",
            warnAfterMS: maxPixelDimension == nil ? 90 : 45
        ) {
            ScreenshotPresentationRenderer.renderWithLayout(
                contentImage: input.contentImage,
                presentation: input.presentation,
                maxPixelDimension: maxPixelDimension
            )
        }
    }

    func presentationPreviewRenderInput(
        presentation: ScreenshotPresentation? = nil,
        context: String = "previewRenderInput"
    ) -> PresentationPreviewRenderInput? {
        let effectivePresentation = presentation ?? snapshot.presentation
        guard let contentImage = presentationContentImage(context: context) else {
            return nil
        }

        PresentationPerformanceMetrics.logEvent(
            "controller.presentationInput.ready",
            context: "source=\(context) revision=\(presentationContentRevision) content=\(contentImage.width)x\(contentImage.height) \(PresentationPerformanceMetrics.presentationSummary(effectivePresentation))"
        )

        return PresentationPreviewRenderInput(
            contentImage: contentImage,
            presentation: effectivePresentation,
            contentRevision: presentationContentRevision
        )
    }

    func setWorkspaceMode(_ mode: EditorWorkspaceMode) {
        guard mode != .presentation || FeatureFlags.presentationStylingEnabled else {
            workspaceMode = .edit
            return
        }

        PresentationPerformanceMetrics.logEvent(
            "controller.workspaceMode.set",
            context: "from=\(workspaceMode.rawValue) to=\(mode.rawValue) contentRevision=\(presentationContentRevision) canvasRevision=\(canvasRevision) persistenceRevision=\(persistenceRevision)"
        )
        workspaceMode = mode
    }

    func applyPresentationPreset(_ preset: ScreenshotPresentationPreset) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        execute(SetPresentationCommand(presentation: preset.settings))
    }

    func applyPresentationTemplate(id: String) {
        guard FeatureFlags.presentationStylingEnabled,
              let template = presentationTemplates.first(where: { $0.id == id }) else {
            return
        }

        execute(SetPresentationCommand(presentation: template.presentation))
    }

    func applyPresentationScene(id: String) {
        guard FeatureFlags.presentationStylingEnabled,
              let scene = presentationScenes.first(where: { $0.id == id }) else {
            return
        }

        mutatePresentation { presentation in
            presentation.scene = AppliedPresentationScene(definition: scene)
            presentation.isEnabled = true
        }
    }

    func clearPresentationScene() {
        mutatePresentation { presentation in
            presentation.scene = nil
        }
    }

    func presentationPreview(for scene: PresentationSceneDefinition) -> ScreenshotPresentation {
        var presentation = snapshot.presentation
        presentation.scene = AppliedPresentationScene(definition: scene)
        presentation.isEnabled = true
        return presentation
    }

    func updateAppliedPresentationSceneTextSlot(id: String, value: String) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.textSlotValues[id] = value
            presentation.scene = scene
        }
    }

    func updateAppliedPresentationSceneScreenshotFit(_ fit: PresentationSceneScreenshotFit) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.screenshotSlotSettings.fit = fit
            scene.screenshotSlotSettings.framingPreset = fit == .contain ? .showFull : (fit == .actualSize ? .actualSize : .fillFrame)
            scene.screenshotSlotSettings.alignment = scene.screenshotSlotSettings.framingPreset.defaultAlignment
            scene.screenshotSlotSettings.scale = 1
            scene.screenshotSlotSettings.offset = .zero
            scene.screenshotSlotSettings.hasManualAdjustment = false
            presentation.scene = scene
        }
    }

    func updateAppliedPresentationSceneFramingPreset(_ preset: PresentationSceneFramingPreset) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.screenshotSlotSettings.applyPreset(preset)
            presentation.scene = scene
        }
    }

    func updateAppliedPresentationSceneFramingAlignment(_ alignment: PresentationSubjectAlignment) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.screenshotSlotSettings.applyManualAdjustment(alignment: alignment)
            presentation.scene = scene
        }
    }

    func updateAppliedPresentationSceneFramingScale(_ scale: CGFloat) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            let slot = presentationScenePrimarySlot(for: scene)
            let clampedScale = min(max(scale, slot?.effectiveMinScale ?? 0.25), slot?.effectiveMaxScale ?? 3)
            scene.screenshotSlotSettings.applyManualAdjustment(scale: clampedScale)
            presentation.scene = scene
        }
    }

    func updateAppliedPresentationSceneFramingOffset(_ offset: CGSize) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.screenshotSlotSettings.applyManualAdjustment(offset: offset)
            presentation.scene = scene
        }
    }

    func adjustAppliedPresentationSceneFramingOffset(by delta: CGSize) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            let current = scene.screenshotSlotSettings.offset
            scene.screenshotSlotSettings.applyManualAdjustment(offset: CGSize(
                width: current.width + delta.width,
                height: current.height + delta.height
            ))
            presentation.scene = scene
        }
    }

    func scaleAppliedPresentationSceneFraming(by multiplier: CGFloat) {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            let slot = presentationScenePrimarySlot(for: scene)
            let minScale = slot?.effectiveMinScale ?? 0.25
            let maxScale = slot?.effectiveMaxScale ?? 3
            let scale = min(max(scene.screenshotSlotSettings.scale * max(multiplier, 0.05), minScale), maxScale)
            scene.screenshotSlotSettings.applyManualAdjustment(scale: scale)
            presentation.scene = scene
        }
    }

    func resetAppliedPresentationSceneFraming() {
        mutatePresentation { presentation in
            guard var scene = presentation.scene else {
                return
            }
            scene.screenshotSlotSettings.applyPreset(presentationScenePrimarySlot(for: scene)?.defaultFraming ?? .auto)
            presentation.scene = scene
        }
    }

    func presentationSceneFramingAnalysis() -> PresentationSceneFramingAnalysis? {
        guard let scene = snapshot.presentation.scene,
              let presentationContentCache,
              presentationContentCache.revision == presentationContentRevision else {
            return nil
        }

        return PresentationSceneRenderer.framingAnalysis(
            contentSize: CGSize(
                width: presentationContentCache.image.width,
                height: presentationContentCache.image.height
            ),
            scene: scene
        )
    }

    @discardableResult
    func saveCurrentPresentationAsTemplate(named requestedName: String = "Custom Style") -> String? {
        guard FeatureFlags.presentationStylingEnabled else {
            return nil
        }

        var userTemplates = PresentationTemplateStore.userTemplates(in: defaults)
        let now = Date()
        let name = PresentationTemplateStore.uniqueTemplateName(
            requestedName,
            existingNames: presentationTemplates.map(\.name)
        )
        let id = "user.\(UUID().uuidString)"
        var styleOnlyPresentation = snapshot.presentation
        styleOnlyPresentation.scene = nil
        userTemplates.append(PresentationTemplate(
            id: id,
            name: name,
            presentation: styleOnlyPresentation,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false
        ))
        PresentationTemplateStore.saveUserTemplates(userTemplates, in: defaults)
        reloadPresentationTemplateLibrary()
        return id
    }

    func renamePresentationTemplate(id: String, name requestedName: String) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        var userTemplates = PresentationTemplateStore.userTemplates(in: defaults)
        guard let index = userTemplates.firstIndex(where: { $0.id == id }) else {
            return
        }

        let existingNames = presentationTemplates
            .filter { $0.id != id }
            .map(\.name)
        userTemplates[index].name = PresentationTemplateStore.uniqueTemplateName(
            requestedName,
            existingNames: existingNames
        )
        userTemplates[index].updatedAt = Date()
        PresentationTemplateStore.saveUserTemplates(userTemplates, in: defaults)
        reloadPresentationTemplateLibrary()
    }

    @discardableResult
    func duplicatePresentationTemplate(id: String) -> String? {
        guard FeatureFlags.presentationStylingEnabled,
              let template = presentationTemplates.first(where: { $0.id == id }) else {
            return nil
        }

        var userTemplates = PresentationTemplateStore.userTemplates(in: defaults)
        let now = Date()
        let name = PresentationTemplateStore.uniqueTemplateName(
            "\(template.name) Copy",
            existingNames: presentationTemplates.map(\.name)
        )
        let copyID = "user.\(UUID().uuidString)"
        userTemplates.append(PresentationTemplate(
            id: copyID,
            name: name,
            presentation: template.presentation,
            createdAt: now,
            updatedAt: now,
            isBuiltIn: false
        ))
        PresentationTemplateStore.saveUserTemplates(userTemplates, in: defaults)
        reloadPresentationTemplateLibrary()
        return copyID
    }

    func deletePresentationTemplate(id: String) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        var userTemplates = PresentationTemplateStore.userTemplates(in: defaults)
        guard userTemplates.contains(where: { $0.id == id }) else {
            return
        }

        userTemplates.removeAll { $0.id == id }
        PresentationTemplateStore.saveUserTemplates(userTemplates, in: defaults)
        if PresentationTemplateStore.defaultTemplateID(in: defaults) == id {
            PresentationTemplateStore.setDefaultTemplateID(nil, in: defaults)
        }
        reloadPresentationTemplateLibrary()
    }

    func setDefaultPresentationTemplate(id: String?) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        PresentationTemplateStore.setDefaultTemplateID(id, in: defaults)
        reloadPresentationTemplateLibrary()
    }

    @discardableResult
    func saveCurrentPresentationToDocument(named requestedName: String = "Presentation") -> UUID? {
        guard FeatureFlags.presentationStylingEnabled else {
            return nil
        }

        let now = Date()
        let name = uniqueSavedPresentationName(
            requestedName,
            excluding: nil
        )
        let saved = SavedPresentation(
            name: name,
            presentation: snapshot.presentation,
            createdAt: now,
            updatedAt: now
        )
        savedPresentations.append(saved)
        persistenceRevision += 1
        showNotice("Saved presentation \"\(name)\" in this document.")
        return saved.id
    }

    func applySavedPresentation(id: UUID) {
        guard FeatureFlags.presentationStylingEnabled,
              let saved = savedPresentations.first(where: { $0.id == id }) else {
            return
        }

        execute(SetPresentationCommand(presentation: saved.presentation))
    }

    func renameSavedPresentation(id: UUID, name requestedName: String) {
        guard let index = savedPresentations.firstIndex(where: { $0.id == id }) else {
            return
        }

        savedPresentations[index].name = uniqueSavedPresentationName(
            requestedName,
            excluding: id
        )
        savedPresentations[index].updatedAt = Date()
        persistenceRevision += 1
    }

    func updateSavedPresentation(id: UUID) {
        guard FeatureFlags.presentationStylingEnabled,
              let index = savedPresentations.firstIndex(where: { $0.id == id }) else {
            return
        }

        savedPresentations[index].presentation = snapshot.presentation
        savedPresentations[index].updatedAt = Date()
        persistenceRevision += 1
        showNotice("Updated saved presentation \"\(savedPresentations[index].name)\".")
    }

    @discardableResult
    func duplicateSavedPresentation(id: UUID) -> UUID? {
        guard let saved = savedPresentations.first(where: { $0.id == id }) else {
            return nil
        }

        let now = Date()
        let copy = SavedPresentation(
            name: uniqueSavedPresentationName("\(saved.name) Copy", excluding: nil),
            presentation: saved.presentation,
            createdAt: now,
            updatedAt: now
        )
        savedPresentations.append(copy)
        persistenceRevision += 1
        return copy.id
    }

    func deleteSavedPresentation(id: UUID) {
        guard savedPresentations.contains(where: { $0.id == id }) else {
            return
        }

        savedPresentations.removeAll { $0.id == id }
        persistenceRevision += 1
    }

    func updatePresentationBackgroundIsTransparent(_ isTransparent: Bool) {
        mutatePresentation { presentation in
            presentation.background = isTransparent ? .transparent : .solid(presentationBackgroundColor)
        }
    }

    func updatePresentationBackgroundColor(_ color: RGBAColor) {
        mutatePresentation { presentation in
            presentation.background = .solid(color)
        }
    }

    func updatePresentationBackground(_ background: ScreenshotPresentationBackground) {
        mutatePresentation { presentation in
            presentation.background = background
        }
    }

    func updatePresentationGradientStart(_ color: RGBAColor) {
        mutatePresentation { presentation in
            let end: RGBAColor
            if case let .twoColorGradient(_, currentEnd) = presentation.background {
                end = currentEnd
            } else {
                end = RGBAColor(red: 0.08, green: 0.12, blue: 0.20, alpha: 1)
            }
            presentation.background = .twoColorGradient(start: color, end: end)
        }
    }

    func updatePresentationGradientEnd(_ color: RGBAColor) {
        mutatePresentation { presentation in
            let start: RGBAColor
            if case let .twoColorGradient(currentStart, _) = presentation.background {
                start = currentStart
            } else {
                start = RGBAColor(red: 0.32, green: 0.55, blue: 0.94, alpha: 1)
            }
            presentation.background = .twoColorGradient(start: start, end: color)
        }
    }

    func updatePresentationSpotlightBase(_ color: RGBAColor) {
        mutatePresentation { presentation in
            let spotlight: RGBAColor
            if case let .radialSpotlight(_, currentSpotlight) = presentation.background {
                spotlight = currentSpotlight
            } else {
                spotlight = RGBAColor(red: 0.75, green: 0.86, blue: 1.0, alpha: 1)
            }
            presentation.background = .radialSpotlight(base: color, spotlight: spotlight)
        }
    }

    func updatePresentationSpotlightColor(_ color: RGBAColor) {
        mutatePresentation { presentation in
            let base: RGBAColor
            if case let .radialSpotlight(currentBase, _) = presentation.background {
                base = currentBase
            } else {
                base = RGBAColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
            }
            presentation.background = .radialSpotlight(base: base, spotlight: color)
        }
    }

    func updatePresentationBlurTint(_ color: RGBAColor) {
        mutatePresentation { presentation in
            presentation.background = .blurredScreenshot(tint: color)
        }
    }

    func updatePresentationCanvas(_ canvas: PresentationCanvas) {
        mutatePresentation { presentation in
            presentation.canvas = canvas
        }
    }

    func updatePresentationCustomCanvas(width: Int, height: Int) {
        mutatePresentation { presentation in
            presentation.canvas = .custom(width: max(width, 1), height: max(height, 1))
        }
    }

    func updatePresentationSubjectFit(_ fit: PresentationSubjectFit) {
        mutatePresentation { presentation in
            presentation.subjectPlacement.fit = fit
        }
    }

    func updatePresentationSubjectAlignment(_ alignment: PresentationSubjectAlignment) {
        mutatePresentation { presentation in
            presentation.subjectPlacement.alignment = alignment
        }
    }

    func updatePresentationSubjectScale(_ scale: CGFloat) {
        mutatePresentation { presentation in
            presentation.subjectPlacement.scale = min(max(scale, 0.05), 3)
        }
    }

    func updatePresentationSubjectOffset(_ offset: CGSize) {
        mutatePresentation { presentation in
            presentation.subjectPlacement.offset = offset
        }
    }

    func resetPresentationSubjectPlacement() {
        mutatePresentation { presentation in
            presentation.subjectPlacement = .default
        }
    }

    func updatePresentationFrame(_ frame: PresentationFrame) {
        mutatePresentation { presentation in
            presentation.frame = frame
        }
    }

    func updatePresentationBrowserTitle(_ title: String) {
        mutatePresentation { presentation in
            guard case var .browser(style) = presentation.frame else {
                return
            }
            style.title = title
            presentation.frame = .browser(style)
        }
    }

    func updatePresentationBrowserAddress(_ address: String) {
        mutatePresentation { presentation in
            guard case var .browser(style) = presentation.frame else {
                return
            }
            style.address = address
            presentation.frame = .browser(style)
        }
    }

    func updatePresentationBrowserScheme(_ scheme: PresentationAppearanceScheme) {
        mutatePresentation { presentation in
            guard case var .browser(style) = presentation.frame else {
                return
            }
            style.scheme = scheme
            presentation.frame = .browser(style)
        }
    }

    func updatePresentationBrowserShowsTrafficLights(_ showsTrafficLights: Bool) {
        mutatePresentation { presentation in
            guard case var .browser(style) = presentation.frame else {
                return
            }
            style.showsTrafficLights = showsTrafficLights
            presentation.frame = .browser(style)
        }
    }

    func updatePresentationMacWindowTitle(_ title: String) {
        mutatePresentation { presentation in
            guard case var .macOSWindow(style) = presentation.frame else {
                return
            }
            style.title = title
            presentation.frame = .macOSWindow(style)
        }
    }

    func updatePresentationMacWindowScheme(_ scheme: PresentationAppearanceScheme) {
        mutatePresentation { presentation in
            guard case var .macOSWindow(style) = presentation.frame else {
                return
            }
            style.scheme = scheme
            presentation.frame = .macOSWindow(style)
        }
    }

    func updatePresentationMacWindowShowsTrafficLights(_ showsTrafficLights: Bool) {
        mutatePresentation { presentation in
            guard case var .macOSWindow(style) = presentation.frame else {
                return
            }
            style.showsTrafficLights = showsTrafficLights
            presentation.frame = .macOSWindow(style)
        }
    }

    func updatePresentationDeviceOrientation(_ orientation: PresentationDeviceOrientation) {
        mutatePresentation { presentation in
            switch presentation.frame {
            case var .phone(style):
                style.orientation = orientation
                presentation.frame = .phone(style)
            case var .tablet(style):
                style.orientation = orientation
                presentation.frame = .tablet(style)
            case .none, .browser, .macOSWindow:
                break
            }
        }
    }

    func updatePresentationDeviceBezelColor(_ color: RGBAColor) {
        mutatePresentation { presentation in
            switch presentation.frame {
            case var .phone(style):
                style.bezelColor = color
                presentation.frame = .phone(style)
            case var .tablet(style):
                style.bezelColor = color
                presentation.frame = .tablet(style)
            case .none, .browser, .macOSWindow:
                break
            }
        }
    }

    func updatePresentationDeviceScreenCornerRadius(_ radius: CGFloat) {
        mutatePresentation { presentation in
            switch presentation.frame {
            case var .phone(style):
                style.screenCornerRadius = min(max(radius, 0), 80)
                presentation.frame = .phone(style)
            case var .tablet(style):
                style.screenCornerRadius = min(max(radius, 0), 80)
                presentation.frame = .tablet(style)
            case .none, .browser, .macOSWindow:
                break
            }
        }
    }

    func updatePresentationDeviceShowsSensorHousing(_ showsSensorHousing: Bool) {
        mutatePresentation { presentation in
            switch presentation.frame {
            case var .phone(style):
                style.showsSensorHousing = showsSensorHousing
                presentation.frame = .phone(style)
            case var .tablet(style):
                style.showsSensorHousing = showsSensorHousing
                presentation.frame = .tablet(style)
            case .none, .browser, .macOSWindow:
                break
            }
        }
    }

    func updatePresentationDeviceCastsShadow(_ castsShadow: Bool) {
        mutatePresentation { presentation in
            switch presentation.frame {
            case var .phone(style):
                style.castsDeviceShadow = castsShadow
                presentation.frame = .phone(style)
            case var .tablet(style):
                style.castsDeviceShadow = castsShadow
                presentation.frame = .tablet(style)
            case .none, .browser, .macOSWindow:
                break
            }
        }
    }

    func updatePresentationPadding(_ value: CGFloat) {
        mutatePresentation { presentation in
            presentation.padding = max(0, value)
        }
    }

    func updatePresentationCornerRadius(_ value: CGFloat) {
        mutatePresentation { presentation in
            presentation.cornerRadius = min(max(0, value), 100)
        }
    }

    func updatePresentationShadow(_ shadow: ScreenshotShadowStyle) {
        mutatePresentation { presentation in
            presentation.shadow = shadow
            presentation.shadowBlurRadius = shadow.blurRadius
            presentation.shadowOffsetX = shadow.offsetX
            presentation.shadowOffsetY = shadow.offsetY
            presentation.shadowOpacity = shadow.opacity
        }
    }

    func updatePresentationShadowBlurRadius(_ value: CGFloat) {
        mutatePresentation { presentation in
            presentation.shadowBlurRadius = max(0, value)
            if presentation.shadowBlurRadius <= 0 || presentation.shadowOpacity <= 0 {
                presentation.shadow = .off
            } else if presentation.shadow == .off {
                presentation.shadow = .medium
            }
        }
    }

    func updatePresentationShadowOffsetY(_ value: CGFloat) {
        mutatePresentation { presentation in
            let direction = presentation.shadowDirection
            let sign = direction.ySign == 0 ? 1 : direction.ySign
            presentation.shadowOffsetY = sign * min(max(0, value), 72)
            if presentation.shadowBlurRadius <= 0 || presentation.shadowOpacity <= 0 {
                presentation.shadow = .off
            } else if presentation.shadow == .off {
                presentation.shadow = .medium
            }
        }
    }

    func updatePresentationShadowOffsetX(_ value: CGFloat) {
        mutatePresentation { presentation in
            let direction = presentation.shadowDirection
            let sign = direction.xSign == 0 ? 1 : direction.xSign
            presentation.shadowOffsetX = sign * min(max(0, value), 72)
            if presentation.shadowBlurRadius <= 0 || presentation.shadowOpacity <= 0 {
                presentation.shadow = .off
            } else if presentation.shadow == .off {
                presentation.shadow = .medium
            }
        }
    }

    func updatePresentationShadowDirection(_ direction: ScreenshotShadowDirection) {
        mutatePresentation { presentation in
            let fallbackX = max(abs(presentation.shadow.offsetX), 18)
            let fallbackY = max(abs(presentation.shadow.offsetY), 18)
            let currentX = abs(presentation.shadowOffsetX)
            let currentY = abs(presentation.shadowOffsetY)
            let magnitudeX = direction.xSign == 0 ? 0 : (currentX > 0 ? currentX : fallbackX)
            let magnitudeY = direction.ySign == 0 ? 0 : (currentY > 0 ? currentY : fallbackY)
            presentation.shadowOffsetX = direction.xSign * magnitudeX
            presentation.shadowOffsetY = direction.ySign * magnitudeY
            if presentation.shadowBlurRadius <= 0 || presentation.shadowOpacity <= 0 {
                presentation.shadow = .off
            } else if presentation.shadow == .off {
                presentation.shadow = .medium
            }
        }
    }

    func updatePresentationShadowOpacity(_ value: CGFloat) {
        mutatePresentation { presentation in
            presentation.shadowOpacity = min(max(value, 0), 1)
            if presentation.shadowBlurRadius <= 0 || presentation.shadowOpacity <= 0 {
                presentation.shadow = .off
            } else if presentation.shadow == .off {
                presentation.shadow = .medium
            }
        }
    }

    func mutatePresentation(_ mutation: (inout ScreenshotPresentation) -> Void) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        let before = snapshot.presentation
        var presentation = snapshot.presentation
        mutation(&presentation)
        presentation.isEnabled = presentation != .plain
        PresentationPerformanceMetrics.logEvent(
            "controller.presentation.mutate",
            context: "before=[\(PresentationPerformanceMetrics.presentationSummary(before))] after=[\(PresentationPerformanceMetrics.presentationSummary(presentation))]"
        )
        execute(SetPresentationCommand(presentation: presentation))
    }

    private func uniqueSavedPresentationName(
        _ requestedName: String,
        excluding excludedID: UUID?
    ) -> String {
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.isEmpty ? "Presentation" : trimmed
        let existingNames = Set(savedPresentations.compactMap { saved -> String? in
            saved.id == excludedID ? nil : saved.name
        })

        guard existingNames.contains(baseName) else {
            return baseName
        }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private func presentationScenePrimarySlot(for scene: AppliedPresentationScene) -> PresentationSceneSlot? {
        try? PresentationSceneValidator
            .validate(
                svgText: scene.sanitizedSVGText,
                source: scene.sceneID.hasPrefix("builtin.") ? .bundled : .user
            )
            .metadata
            .primaryScreenshotSlot
    }

    func reloadPresentationTemplateLibrary() {
        presentationTemplates = PresentationTemplateStore.allTemplates(in: defaults)
        defaultPresentationTemplateID = PresentationTemplateStore.defaultTemplateID(in: defaults)
    }

    func updatePresentationScenesRootURL(_ url: URL) {
        presentationScenesRootURL = url
        reloadPresentationScenes()
    }

    func revealPresentationScenesUserFolder() {
        let userURL = presentationScenesRootURL
            .appendingPathComponent(PresentationSceneStore.userDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: userURL, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([userURL])
        } catch {
            errorMessage = "The Presentation Scenes User folder could not be opened: \(error.localizedDescription)"
        }
    }

    func reloadPresentationScenes() {
        guard FeatureFlags.presentationStylingEnabled else {
            presentationScenes = []
            presentationSceneDiagnostics = []
            return
        }

        do {
            let result = try PresentationSceneStore(rootURL: presentationScenesRootURL).reload()
            presentationScenes = result.scenes
            presentationSceneDiagnostics = result.diagnostics
            PresentationPerformanceMetrics.logEvent(
                "sceneStore.reload",
                context: "root=\(result.rootURL.path) scenes=\(result.scenes.count) diagnostics=\(result.diagnostics.count)"
            )
        } catch {
            presentationScenes = []
            presentationSceneDiagnostics = [
                PresentationSceneDiagnostic(
                    severity: .error,
                    message: "Could not load presentation scenes: \(error.localizedDescription)",
                    fileURL: presentationScenesRootURL
                ),
            ]
        }
    }

    private func presentationContentImage(context: String) -> CGImage? {
        if let presentationContentCache,
           presentationContentCache.revision == presentationContentRevision {
            PresentationPerformanceMetrics.logEvent(
                "controller.contentCache.hit",
                context: "source=\(context) revision=\(presentationContentRevision) image=\(PresentationPerformanceMetrics.imageSize(presentationContentCache.image))"
            )
            return presentationContentCache.image
        }

        let image = PresentationPerformanceMetrics.measure(
            "controller.contentCache.miss.render",
            context: "source=\(context) revision=\(presentationContentRevision) base=\(capture.image.width)x\(capture.image.height) crop=\(PresentationPerformanceMetrics.size(snapshot.cropRect.size)) annotations=\(snapshot.annotations.count) uiMapPins=\(pinnedUIMapElements.count)",
            warnAfterMS: 60
        ) {
            EditorRenderer.render(
                baseImage: capture.image,
                snapshot: snapshot,
                pinnedUIMapElements: pinnedUIMapElements,
                uiMapOverlayOptions: uiMapOverlayOptions
            )
        }

        guard let image else {
            presentationContentCache = nil
            return nil
        }

        presentationContentCache = (presentationContentRevision, image)
        PresentationPerformanceMetrics.logEvent(
            "controller.contentCache.store",
            context: "source=\(context) revision=\(presentationContentRevision) image=\(PresentationPerformanceMetrics.imageSize(image))"
        )
        return image
    }
}
