import AppKit
import SwiftUI

nonisolated enum PresentationCanvasItemOutlineEmphasis: Equatable {
    case none
    case hover
    case selected
}

nonisolated enum PresentationCanvasAffordancePolicy {
    static func showsSubjectOutline(
        in tab: PresentationInspectorTab,
        hasCanvasManipulationFocus: Bool = true
    ) -> Bool {
        hasCanvasManipulationFocus && tab != .layout
    }

    static func itemOutlineEmphasis(
        isSelected: Bool,
        isHovered: Bool,
        hasCanvasManipulationFocus: Bool = true
    ) -> PresentationCanvasItemOutlineEmphasis {
        if isSelected, hasCanvasManipulationFocus {
            return .selected
        }
        return isHovered ? .hover : .none
    }
}

nonisolated enum PresentationCompositionOverlayGeometry {
    private static func presentationRect(
        for compositionRect: CGRect,
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout
    ) -> CGRect {
        let content = presentationLayout.contentRect
        return CGRect(
            x: content.minX
                + compositionRect.minX
                    / max(compositionLayout.canvasSize.width, 1)
                    * content.width,
            y: content.minY
                + compositionRect.minY
                    / max(compositionLayout.canvasSize.height, 1)
                    * content.height,
            width: compositionRect.width
                / max(compositionLayout.canvasSize.width, 1)
                * content.width,
            height: compositionRect.height
                / max(compositionLayout.canvasSize.height, 1)
                * content.height
        )
    }

    private static func displayRect(
        for presentationRect: CGRect,
        presentationLayout: ScreenshotPresentationRenderLayout,
        viewportRect: CGRect
    ) -> CGRect {
        let displayScale = viewportRect.width
            / max(presentationLayout.canvasSize.width, 1)
        return CGRect(
            x: viewportRect.minX + presentationRect.minX * displayScale,
            y: viewportRect.minY + presentationRect.minY * displayScale,
            width: max(presentationRect.width * displayScale, 1),
            height: max(presentationRect.height * displayScale, 1)
        )
    }

    static func visiblePresentationContentRect(
        presentationLayout: ScreenshotPresentationRenderLayout
    ) -> CGRect? {
        let canvasRect = CGRect(
            origin: .zero,
            size: presentationLayout.canvasSize
        )
        let visibleRect = presentationLayout.contentRect
            .intersection(presentationLayout.screenRect)
            .intersection(canvasRect)
        guard !visibleRect.isNull,
              visibleRect.width > 0,
              visibleRect.height > 0 else {
            return nil
        }
        return visibleRect
    }

    static func displayRect(
        for compositionRect: CGRect,
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout,
        viewportRect: CGRect
    ) -> CGRect {
        displayRect(
            for: presentationRect(
                for: compositionRect,
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout
            ),
            presentationLayout: presentationLayout,
            viewportRect: viewportRect
        )
    }

    static func visibleDisplayRect(
        for compositionRect: CGRect,
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout,
        viewportRect: CGRect
    ) -> CGRect? {
        guard let visibleContentRect = visiblePresentationContentRect(
            presentationLayout: presentationLayout
        ) else {
            return nil
        }
        let clippedRect = presentationRect(
            for: compositionRect,
            presentationLayout: presentationLayout,
            compositionLayout: compositionLayout
        ).intersection(visibleContentRect)
        guard !clippedRect.isNull,
              clippedRect.width > 0,
              clippedRect.height > 0 else {
            return nil
        }
        return displayRect(
            for: clippedRect,
            presentationLayout: presentationLayout,
            viewportRect: viewportRect
        )
    }

    static func isFullyVisible(
        compositionRect: CGRect,
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout
    ) -> Bool {
        guard let visibleContentRect = visiblePresentationContentRect(
            presentationLayout: presentationLayout
        ) else {
            return false
        }
        return visibleContentRect.contains(
            presentationRect(
                for: compositionRect,
                presentationLayout: presentationLayout,
                compositionLayout: compositionLayout
            )
        )
    }

    static func compositionPoint(
        fromDisplayPoint displayPoint: CGPoint,
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout,
        viewportRect: CGRect
    ) -> CGPoint? {
        let displayScale = viewportRect.width
            / max(presentationLayout.canvasSize.width, 1)
        guard displayScale > 0,
              viewportRect.width > 0,
              viewportRect.height > 0,
              presentationLayout.contentRect.width > 0,
              presentationLayout.contentRect.height > 0,
              let visibleContentRect = visiblePresentationContentRect(
                  presentationLayout: presentationLayout
              ) else {
            return nil
        }
        let presentationPoint = CGPoint(
            x: (displayPoint.x - viewportRect.minX) / displayScale,
            y: (displayPoint.y - viewportRect.minY) / displayScale
        )
        guard visibleContentRect.contains(presentationPoint) else {
            return nil
        }
        let contentRect = presentationLayout.contentRect
        return CGPoint(
            x: (presentationPoint.x - contentRect.minX)
                / contentRect.width
                * compositionLayout.canvasSize.width,
            y: (presentationPoint.y - contentRect.minY)
                / contentRect.height
                * compositionLayout.canvasSize.height
        )
    }

    static func comparisonVisibleRect(
        for item: CompositionItemRenderLayout,
        in layout: CompositionRenderLayout,
        comparisonPhase: CompositionComparisonPhase,
        overlayOpacity: CGFloat
    ) -> CGRect? {
        guard let comparison = layout.comparison,
              comparison.mode != .sideBySide else {
            return item.frameRect
        }

        switch comparison.mode {
        case .sideBySide:
            return item.frameRect

        case .blink:
            let visibleID = comparisonPhase == .secondary
                ? comparison.secondaryItemID
                : comparison.primaryItemID
            return item.itemID == visibleID ? item.frameRect : nil

        case .wipe:
            guard let sharedFrame = comparison.sharedFrame else {
                return item.frameRect
            }
            let isPrimary = item.itemID == comparison.primaryItemID
            let isSecondary = item.itemID == comparison.secondaryItemID
            guard isPrimary || isSecondary else {
                return item.frameRect
            }
            let secondaryIsVisible = layout
                .itemLayout(for: comparison.secondaryItemID)
                .map { $0.opacity > 0.001 } == true
            if isPrimary, !secondaryIsVisible {
                return item.frameRect.intersection(sharedFrame)
            }
            if isSecondary, !secondaryIsVisible {
                return nil
            }
            let fraction = min(max(comparison.wipePosition ?? 0.5, 0), 1)
            let revealRect: CGRect
            switch comparison.axis {
            case .horizontal:
                let splitX = sharedFrame.minX + sharedFrame.width * fraction
                revealRect = isSecondary
                    ? CGRect(
                        x: sharedFrame.minX,
                        y: sharedFrame.minY,
                        width: splitX - sharedFrame.minX,
                        height: sharedFrame.height
                    )
                    : CGRect(
                        x: splitX,
                        y: sharedFrame.minY,
                        width: sharedFrame.maxX - splitX,
                        height: sharedFrame.height
                    )
            case .vertical:
                let splitY = sharedFrame.minY + sharedFrame.height * fraction
                revealRect = isSecondary
                    ? CGRect(
                        x: sharedFrame.minX,
                        y: sharedFrame.minY,
                        width: sharedFrame.width,
                        height: splitY - sharedFrame.minY
                    )
                    : CGRect(
                        x: sharedFrame.minX,
                        y: splitY,
                        width: sharedFrame.width,
                        height: sharedFrame.maxY - splitY
                    )
            }
            let clippedRect = item.frameRect.intersection(revealRect)
            guard !clippedRect.isNull,
                  clippedRect.width > 0,
                  clippedRect.height > 0 else {
                return nil
            }
            return clippedRect

        case .overlay:
            if item.itemID == comparison.secondaryItemID,
               item.opacity * overlayOpacity <= 0.001 {
                return nil
            }
            return item.frameRect

        case .difference, .changeHighlight:
            return item.frameRect
        }
    }
}

nonisolated struct PresentationCompositionOverlayOrderEntry: Equatable {
    let itemID: UUID
    let modelIndex: Int
}

nonisolated enum PresentationCompositionOverlayOrdering {
    static func visualZIndex(
        for item: CompositionItemRenderLayout,
        modelIndex: Int
    ) -> Double {
        Double(item.zIndex) + Double(modelIndex) * 0.000_001
    }

    static func orderedItems(
        composition: CompositionSnapshot,
        layout: CompositionRenderLayout
    ) -> [PresentationCompositionOverlayOrderEntry] {
        let modelIndices = Dictionary(
            uniqueKeysWithValues: composition.items.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        let orderedLayouts: [CompositionItemRenderLayout]
        if composition.layout.mode == .freeform {
            orderedLayouts = layout.items.sorted { lhs, rhs in
                if lhs.zIndex == rhs.zIndex {
                    return (modelIndices[lhs.itemID] ?? 0)
                        > (modelIndices[rhs.itemID] ?? 0)
                }
                return lhs.zIndex > rhs.zIndex
            }
        } else {
            orderedLayouts = layout.items.sorted { lhs, rhs in
                if lhs.frameRect.minY == rhs.frameRect.minY {
                    if lhs.frameRect.minX == rhs.frameRect.minX {
                        return (modelIndices[lhs.itemID] ?? 0)
                            < (modelIndices[rhs.itemID] ?? 0)
                    }
                    return lhs.frameRect.minX < rhs.frameRect.minX
                }
                return lhs.frameRect.minY < rhs.frameRect.minY
            }
        }
        return orderedLayouts.compactMap { item in
            guard let modelIndex = modelIndices[item.itemID] else {
                return nil
            }
            return PresentationCompositionOverlayOrderEntry(
                itemID: item.itemID,
                modelIndex: modelIndex
            )
        }
    }
}

struct PresentationModeCanvasView: View {
    private enum PreviewState {
        case rendered(ScreenshotPresentationRenderResult)
        case liveTransparent(contentImage: CGImage)

        var layout: ScreenshotPresentationRenderLayout {
            switch self {
            case let .rendered(result):
                return result.layout
            case let .liveTransparent(contentImage):
                let size = CGSize(width: contentImage.width, height: contentImage.height)
                let rect = CGRect(origin: .zero, size: size)
                return ScreenshotPresentationRenderLayout(
                    canvasSize: size,
                    subjectRect: rect,
                    screenRect: rect,
                    contentRect: rect,
                    subjectScale: 1,
                    frame: .none
                )
            }
        }

        var canvasSize: CGSize {
            layout.canvasSize
        }
    }

    @ObservedObject var controller: EditorController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewState: PreviewState?
    @State private var previousPreviewState: PreviewState?
    @State private var previewCrossfadeOpacity = 1.0
    @State private var renderedComparisonPhase: CompositionComparisonPhase?
    @State private var renderSequence = 0
    @State private var hasCanvasManipulationFocus = false

    private var effectivePresentation: ScreenshotPresentation {
        controller.presentationInspectorTab == .layout
            ? .plain
            : controller.presentation
    }

    private func presentationBackgroundID(_ presentation: ScreenshotPresentation) -> String {
        switch presentation.background {
        case .transparent:
            return "transparent"
        case let .solid(color):
            return "solid:\(color.red):\(color.green):\(color.blue):\(color.alpha)"
        case let .twoColorGradient(start, end):
            return "gradient:\(start.red):\(start.green):\(start.blue):\(start.alpha):\(end.red):\(end.green):\(end.blue):\(end.alpha)"
        case let .radialSpotlight(base, spotlight):
            return "spotlight:\(base.red):\(base.green):\(base.blue):\(base.alpha):\(spotlight.red):\(spotlight.green):\(spotlight.blue):\(spotlight.alpha)"
        case let .blurredScreenshot(tint):
            return "blurred:\(tint.red):\(tint.green):\(tint.blue):\(tint.alpha)"
        }
    }

    private func presentationFrameID(_ frame: PresentationFrame) -> String {
        switch frame {
        case .none:
            return "none"
        case let .browser(style):
            return "browser:\(style.title):\(style.address):\(style.scheme.rawValue):\(style.showsTrafficLights)"
        case let .macOSWindow(style):
            return "mac:\(style.title):\(style.scheme.rawValue):\(style.showsTrafficLights)"
        case let .phone(style):
            return "phone:\(style.orientation.rawValue):\(style.bezelColor.red):\(style.bezelColor.green):\(style.bezelColor.blue):\(style.screenCornerRadius):\(style.showsSensorHousing):\(style.castsDeviceShadow)"
        case let .tablet(style):
            return "tablet:\(style.orientation.rawValue):\(style.bezelColor.red):\(style.bezelColor.green):\(style.bezelColor.blue):\(style.screenCornerRadius):\(style.showsSensorHousing):\(style.castsDeviceShadow)"
        }
    }

    private var renderID: String {
        let presentation = effectivePresentation
        return [
            "\(controller.presentationContentRevision)",
            "\(controller.persistenceRevision)",
            controller.effectiveCompositionComparisonPreviewPhase.rawValue,
            "\(presentation.isEnabled)",
            presentation.scene.map {
                [
                    $0.sceneID,
                    "\($0.version)",
                    $0.textSlotValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                    $0.screenshotSlotSettings.framingPreset.rawValue,
                    $0.screenshotSlotSettings.fit.rawValue,
                    $0.screenshotSlotSettings.alignment.rawValue,
                    "\($0.screenshotSlotSettings.scale)",
                    "\($0.screenshotSlotSettings.offset.width)",
                    "\($0.screenshotSlotSettings.offset.height)",
                    "\($0.screenshotSlotSettings.hasManualAdjustment)",
                ].joined(separator: ":")
            } ?? "scene:none",
            presentation.canvas.label,
            presentationFrameID(presentation.frame),
            presentation.subjectPlacement.fit.rawValue,
            presentation.subjectPlacement.alignment.rawValue,
            "\(presentation.subjectPlacement.scale)",
            "\(presentation.subjectPlacement.offset.width)",
            "\(presentation.subjectPlacement.offset.height)",
            "\(presentation.padding)",
            "\(presentation.cornerRadius)",
            presentation.shadow.rawValue,
            "\(presentation.shadowBlurRadius)",
            "\(presentation.shadowOffsetX)",
            "\(presentation.shadowOffsetY)",
            "\(presentation.shadowOpacity)",
            presentationBackgroundID(presentation),
        ].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            let previewPixelDimension = maxPreviewPixelDimension(for: proxy.size)
            let layout = previewState.map { activeLayout(for: $0) }
            let contentSize = layout?.canvasSize ?? .zero
            let sceneSlotRect = effectivePresentation.scene == nil ? nil : layout?.subjectRect
            let compositionLayout = controller.presentationInspectorTab == .layout
                ? try? controller.currentCompositionRenderLayout()
                : nil

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let previousPreviewState {
                    preview(previousPreviewState, availableSize: proxy.size)
                }

                if let previewState {
                    preview(previewState, availableSize: proxy.size)
                        .opacity(previewCrossfadeOpacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                PresentationViewportEventLayer(
                    controller: controller,
                    contentSize: contentSize,
                    presentationLayout: layout,
                    compositionLayout: compositionLayout,
                    sceneSlotRect: sceneSlotRect,
                    focusRequestRevision: controller
                        .compositionCanvasFocusRequestRevision,
                    onCanvasInteraction: {
                        hasCanvasManipulationFocus = true
                    }
                )
                .allowsHitTesting(true)
            }
            .overlay {
                if let layout, let compositionLayout,
                   controller.presentationInspectorTab == .layout {
                    compositionSelectionOverlay(
                        presentationLayout: layout,
                        compositionLayout: compositionLayout
                    )
                }
            }
            .task(id: "\(renderID)|\(Int(previewPixelDimension.rounded()))") {
                await refreshPreviewRender(maxPixelDimension: previewPixelDimension)
            }
            .task(id: blinkPlaybackID) {
                await runBlinkPreview()
            }
            .onChange(of: controller.presentationInspectorTab) { _, _ in
                hasCanvasManipulationFocus = false
            }
            .onChange(
                of: controller.composition?.items.map(\.id) ?? []
            ) { _, _ in
                // Appending a capture keeps the new item logically selected
                // for the inspector, without covering the result in selection
                // frames before the user interacts with the canvas.
                hasCanvasManipulationFocus = false
            }
        }
    }

    private var blinkPlaybackID: String {
        guard let composition = controller.composition,
              composition.layout.mode == .compare,
              composition.comparison.mode == .blink else {
            return "blink:inactive"
        }
        let comparison = composition.comparison
        return [
            "blink",
            comparison.primaryItemID?.uuidString ?? "none",
            comparison.secondaryItemID?.uuidString ?? "none",
            "\(comparison.blinkInterval)",
            "\(comparison.blinkCrossfadeDuration)",
            "\(comparison.blinkLoops)",
            "\(controller.isCompositionBlinkPreviewPlaying)",
            "\(reduceMotion)",
        ].joined(separator: ":")
    }

    private func runBlinkPreview() async {
        guard let composition = controller.composition,
              composition.layout.mode == .compare,
              composition.comparison.mode == .blink,
              controller.isCompositionBlinkPreviewPlaying,
              !reduceMotion else {
            return
        }
        let comparison = composition.comparison
        let intervalNanoseconds = UInt64(
            max(comparison.blinkInterval, 0.15) * 1_000_000_000
        )
        let animation = Animation.linear(
            duration: max(comparison.blinkCrossfadeDuration, 0)
        )

        if !comparison.blinkLoops {
            withAnimation(animation) {
                controller.setCompositionComparisonPreviewPhase(
                    .primary,
                    pausesPlayback: false
                )
            }
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            withAnimation(animation) {
                controller.setCompositionComparisonPreviewPhase(
                    .secondary,
                    pausesPlayback: false
                )
                controller.isCompositionBlinkPreviewPlaying = false
            }
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: intervalNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            let nextPhase: CompositionComparisonPhase =
                controller.effectiveCompositionComparisonPreviewPhase == .primary
                ? .secondary
                : .primary
            withAnimation(animation) {
                controller.setCompositionComparisonPreviewPhase(
                    nextPhase,
                    pausesPlayback: false
                )
            }
        }
    }

    private func compositionSelectionOverlay(
        presentationLayout: ScreenshotPresentationRenderLayout,
        compositionLayout: CompositionRenderLayout
    ) -> some View {
        let viewportRect = controller.viewport.imageRect
        let selectedIDs = Set(controller.composition?.selectedItemIDs ?? [])
        let composition = controller.composition
        let orderedItems = composition.map {
            PresentationCompositionOverlayOrdering.orderedItems(
                composition: $0,
                layout: compositionLayout
            )
        } ?? []
        let comparisonPhase =
            controller.effectiveCompositionComparisonPreviewPhase
        let comparisonOverlayOpacity =
            composition?.comparison.overlayOpacity ?? 1
        let resolvedAnnotations = composition.map {
            CompositionRenderer.resolvedCanvasAnnotations(
                composition: $0,
                layout: compositionLayout
            )
        } ?? []

        return ZStack(alignment: .topLeading) {
            ForEach(
                Array(orderedItems.enumerated()),
                id: \.element.itemID
            ) { accessibilityIndex, entry in
                if let item = compositionLayout.itemLayout(
                    for: entry.itemID
                ),
                   let comparisonVisibleRect =
                    PresentationCompositionOverlayGeometry
                        .comparisonVisibleRect(
                            for: item,
                            in: compositionLayout,
                            comparisonPhase: comparisonPhase,
                            overlayOpacity: comparisonOverlayOpacity
                        ),
                   let displayRect = PresentationCompositionOverlayGeometry
                        .visibleDisplayRect(
                            for: comparisonVisibleRect,
                            presentationLayout: presentationLayout,
                            compositionLayout: compositionLayout,
                            viewportRect: viewportRect
                        ) {
                    let isSelected = selectedIDs.contains(item.itemID)
                    let compositionItem = composition?.items.first {
                        $0.id == entry.itemID
                    }
                    let isFreeform =
                        composition?.layout.mode == .freeform
                    CompositionCanvasItemOverlay(
                        controller: controller,
                        layoutItem: item,
                        compositionItem: compositionItem,
                        displayRect: displayRect,
                        itemNumber: entry.modelIndex + 1,
                        accessibilityIndex: accessibilityIndex,
                        accessibilityItemCount: orderedItems.count,
                        modelIndex: entry.modelIndex,
                        modelItemCount: composition?.items.count ?? 0,
                        isFreeform: isFreeform,
                        isSelected: isSelected,
                        showsSelectionAffordance:
                            hasCanvasManipulationFocus,
                        isHovered: controller.hoveredCompositionItemID
                            == item.itemID,
                        showsResizeHandles: isFreeform
                            && PresentationCompositionOverlayGeometry
                                .isFullyVisible(
                                    compositionRect: item.frameRect,
                                    presentationLayout: presentationLayout,
                                    compositionLayout: compositionLayout
                                ),
                        canRemove: (composition?.items.count ?? 0) > 1
                    )
                    .zIndex(
                        PresentationCompositionOverlayOrdering
                            .visualZIndex(
                                for: item,
                                modelIndex: entry.modelIndex
                            )
                    )
                }
            }

            ForEach(
                Array(resolvedAnnotations.enumerated()),
                id: \.element.id
            ) { index, annotation in
                if let annotationRect =
                    PresentationCompositionOverlayGeometry
                        .visibleDisplayRect(
                            for: annotation.boundingRect,
                            presentationLayout: presentationLayout,
                            compositionLayout: compositionLayout,
                            viewportRect: viewportRect
                        ) {
                    CompositionCanvasAnnotationAccessibilityOverlay(
                        controller: controller,
                        annotation: annotation,
                        displayRect: annotationRect,
                        index: index,
                        annotationCount: resolvedAnnotations.count,
                        isSelected: composition?.canvas
                            .selectedAnnotationIDs
                            .contains(annotation.id) == true
                    )
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Composition canvas")
        .accessibilityValue(
            hasCanvasManipulationFocus
                ? String(localized: "Selection bounds visible")
                : String(localized: "Selection bounds hidden")
        )
        .accessibilityIdentifier("composition.canvas")
    }

    private func refreshPreviewRender(maxPixelDimension: CGFloat) async {
        renderSequence += 1
        let sequence = renderSequence
        let requestedComparisonPhase =
            controller.effectiveCompositionComparisonPreviewPhase
        let hadExistingPreview = previewState != nil
        if !controller.isPrivateDocument {
            PresentationPerformanceMetrics.logEvent(
                "presentationCanvas.render.schedule",
                context: "sequence=\(sequence) hasPreview=\(hadExistingPreview) cap=\(Int(maxPixelDimension.rounded()))"
            )
        }

        do {
            if hadExistingPreview {
                try await Task.sleep(nanoseconds: 140_000_000)
                try Task.checkCancellation()
            }

            guard let input = controller.presentationPreviewRenderInput(
                presentation: effectivePresentation,
                maxPixelDimension: maxPixelDimension,
                comparisonPhase: controller.effectiveCompositionComparisonPreviewPhase,
                context: "presentationCanvas"
            ) else {
                if !controller.isPrivateDocument {
                    PresentationPerformanceMetrics.logEvent(
                        "presentationCanvas.render.noInput",
                        context: "sequence=\(sequence)"
                    )
                }
                previousPreviewState = nil
                previewState = nil
                return
            }

            if input.presentation.canUseLiveTransparentPresentationPreview {
                let layout = ScreenshotPresentationRenderer.layout(
                    contentSize: CGSize(width: input.contentImage.width, height: input.contentImage.height),
                    presentation: input.presentation
                )
                controller.updatePresentationViewportContentSize(layout.canvasSize)
                installPreviewState(
                    .liveTransparent(contentImage: input.contentImage),
                    phase: requestedComparisonPhase,
                    sequence: sequence
                )
                if !input.suppressesContentDiagnostics {
                    PresentationPerformanceMetrics.logEvent(
                        "presentationCanvas.liveTransparent.finish",
                        context: "sequence=\(sequence) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) canvas=\(PresentationPerformanceMetrics.size(layout.canvasSize)) subject=\(PresentationPerformanceMetrics.size(layout.subjectRect.size))"
                    )
                }
                return
            }

            if !input.suppressesContentDiagnostics {
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.render.start",
                    context: "sequence=\(sequence) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) cap=\(Int(maxPixelDimension.rounded()))"
                )
            }

            let result = await Task.detached(priority: .userInitiated) {
                PresentationPerformanceMetrics.withLoggingSuppressed(
                    input.suppressesContentDiagnostics
                ) {
                    PresentationPerformanceMetrics.measure(
                        "presentationCanvas.detachedRender",
                        context: "sequence=\(sequence) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) \(PresentationPerformanceMetrics.presentationSummary(input.presentation, maxPixelDimension: maxPixelDimension))",
                        warnAfterMS: 24
                    ) {
                        ScreenshotPresentationRenderer.renderWithLayout(
                            contentImage: input.contentImage,
                            presentation: input.presentation,
                            maxPixelDimension: maxPixelDimension
                        )
                    }
                }
            }.value

            try Task.checkCancellation()
            if let result {
                installPreviewState(
                    .rendered(result),
                    phase: requestedComparisonPhase,
                    sequence: sequence
                )
            } else {
                previousPreviewState = nil
                previewState = nil
            }
            if let result {
                controller.updatePresentationViewportContentSize(result.layout.canvasSize)
            }
            if !input.suppressesContentDiagnostics {
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.render.finish",
                    context: "sequence=\(sequence) revision=\(input.contentRevision) output=\(PresentationPerformanceMetrics.imageSize(result?.image))"
                )
            }
        } catch is CancellationError {
            if !controller.isPrivateDocument {
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.render.cancel",
                    context: "sequence=\(sequence)"
                )
            }
        } catch {
            if !controller.isPrivateDocument {
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.render.error",
                    context: "sequence=\(sequence) error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func installPreviewState(
        _ newState: PreviewState,
        phase: CompositionComparisonPhase,
        sequence: Int
    ) {
        let comparison = controller.composition?.comparison
        let isBlink = controller.composition?.layout.mode == .compare
            && comparison?.mode == .blink
        let duration = comparison?.blinkCrossfadeDuration ?? 0
        let shouldCrossfade = isBlink
            && !reduceMotion
            && duration > 0
            && renderedComparisonPhase != nil
            && renderedComparisonPhase != phase
            && previewState != nil

        renderedComparisonPhase = phase
        guard shouldCrossfade, let previewState else {
            previousPreviewState = nil
            previewCrossfadeOpacity = 1
            self.previewState = newState
            return
        }

        previousPreviewState = previewState
        self.previewState = newState
        previewCrossfadeOpacity = 0
        withAnimation(.linear(duration: duration)) {
            previewCrossfadeOpacity = 1
        }
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(max(duration, 0) * 1_000_000_000)
            )
            guard renderSequence == sequence else {
                return
            }
            previousPreviewState = nil
        }
    }

    private func maxPreviewPixelDimension(for availableSize: CGSize) -> CGFloat {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let longestVisibleSide = max(availableSize.width, availableSize.height) * backingScale
        return min(max(longestVisibleSide, 640), 1800)
    }

    private func preview(_ state: PreviewState, availableSize: CGSize) -> some View {
        let layout = activeLayout(for: state)
        let viewportRect = controller.viewport.imageRect
        let scale = viewportRect.width / max(layout.canvasSize.width, 1)

        return ZStack {
            PresentationOutOfCapturePatternView(
                excludedSize: .zero,
                settings: controller.outOfCapturePatternSettings
            )
            .allowsHitTesting(false)

            previewContent(state, displayScale: scale)
                .overlay(alignment: .topLeading) {
                    if PresentationCanvasAffordancePolicy.showsSubjectOutline(
                        in: controller.presentationInspectorTab,
                        hasCanvasManipulationFocus:
                            hasCanvasManipulationFocus
                    ) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                Color.accentColor.opacity(0.72),
                                style: StrokeStyle(
                                    lineWidth: 1.25,
                                    dash: [7, 5]
                                )
                            )
                            .frame(
                                width: max(
                                    layout.subjectRect.width * scale,
                                    1
                                ),
                                height: max(
                                    layout.subjectRect.height * scale,
                                    1
                                )
                            )
                            .offset(
                                x: layout.subjectRect.minX * scale,
                                y: layout.subjectRect.minY * scale
                            )
                            .allowsHitTesting(false)
                    }
            }
            .shadow(color: .black.opacity(0.20), radius: 24, y: 10)
            .frame(
                width: max(viewportRect.width, 1),
                height: max(viewportRect.height, 1)
            )
            .position(x: viewportRect.midX, y: viewportRect.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func activeLayout(for state: PreviewState) -> ScreenshotPresentationRenderLayout {
        switch state {
        case let .rendered(result):
            return result.layout

        case let .liveTransparent(contentImage):
            return ScreenshotPresentationRenderer.layout(
                contentSize: CGSize(width: contentImage.width, height: contentImage.height),
                presentation: effectivePresentation
            )
        }
    }

    @ViewBuilder
    private func previewContent(_ state: PreviewState, displayScale: CGFloat) -> some View {
        switch state {
        case let .rendered(result):
            Image(decorative: result.image, scale: 1)
                .resizable()
                .frame(
                    width: max(state.canvasSize.width * displayScale, 1),
                    height: max(state.canvasSize.height * displayScale, 1)
                )

        case let .liveTransparent(contentImage):
            let layout = activeLayout(for: state)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: max(layout.canvasSize.width * displayScale, 1),
                        height: max(layout.canvasSize.height * displayScale, 1)
                    )

                Image(decorative: contentImage, scale: 1)
                    .resizable()
                    .frame(
                        width: max(layout.contentRect.width * displayScale, 1),
                        height: max(layout.contentRect.height * displayScale, 1)
                    )
                    .offset(
                        x: layout.contentRect.minX * displayScale,
                        y: layout.contentRect.minY * displayScale
                    )
            }
        }
    }
}

private struct CompositionCanvasItemOverlay: View {
    @ObservedObject var controller: EditorController
    let layoutItem: CompositionItemRenderLayout
    let compositionItem: CompositionItem?
    let displayRect: CGRect
    let itemNumber: Int
    let accessibilityIndex: Int
    let accessibilityItemCount: Int
    let modelIndex: Int
    let modelItemCount: Int
    let isFreeform: Bool
    let isSelected: Bool
    let showsSelectionAffordance: Bool
    let isHovered: Bool
    let showsResizeHandles: Bool
    let canRemove: Bool

    private var displayName: String {
        let title = compositionItem?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Item \(itemNumber)" : title
    }

    private var resizeHandlePoints: [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: displayRect.width, y: 0),
            CGPoint(x: 0, y: displayRect.height),
            CGPoint(x: displayRect.width, y: displayRect.height),
        ]
    }

    var body: some View {
        itemOutline
            .frame(
                width: displayRect.width,
                height: displayRect.height
            )
            .position(
                x: displayRect.midX,
                y: displayRect.midY
            )
            .allowsHitTesting(false)
            .modifier(
                CompositionCanvasItemAccessibilityModifier(
                    controller: controller,
                    itemID: layoutItem.itemID,
                    displayName: displayName,
                    accessibilityValue: accessibilityValue,
                    accessibilityIndex: accessibilityIndex,
                    accessibilityItemCount: accessibilityItemCount,
                    modelIndex: modelIndex,
                    modelItemCount: modelItemCount,
                    isFreeform: isFreeform,
                    isSelected: isSelected,
                    isIncluded: compositionItem?.isIncluded != false,
                    canRemove: canRemove
                )
            )
    }

    private var itemOutline: some View {
        let emphasis = PresentationCanvasAffordancePolicy
            .itemOutlineEmphasis(
                isSelected: isSelected,
                isHovered: isHovered,
                hasCanvasManipulationFocus:
                    showsSelectionAffordance
            )

        return ZStack(alignment: .topLeading) {
            Color.clear

            switch emphasis {
            case .none:
                EmptyView()

            case .hover:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.58), lineWidth: 1)

            case .selected:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)

                Text("Item \(itemNumber)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    }
                    .padding(6)
            }

            if isSelected, showsSelectionAffordance, showsResizeHandles {
                ForEach(resizeHandlePoints, id: \.self) { point in
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(x: point.x, y: point.y)
                }
            }
        }
    }

    private var accessibilityValue: String {
        let selection = isSelected
            ? String(localized: "Selected")
            : String(localized: "Not selected")
        let inclusion = compositionItem?.isIncluded == false
            ? String(localized: "Excluded")
            : String(localized: "Included")
        let selectionAffordance =
            isSelected && showsSelectionAffordance
                ? String(localized: "Selection bounds visible")
                : String(localized: "Selection bounds hidden")
        let baseValue: String
        if controller.compositionFramingItemID == layoutItem.itemID {
            baseValue = String(
                localized: "\(selection), \(inclusion), framing, item \(itemNumber) of \(modelItemCount)"
            )
        } else {
            baseValue = String(
                localized: "\(selection), \(inclusion), item \(itemNumber) of \(modelItemCount)"
            )
        }
        return "\(baseValue), \(selectionAffordance)"
    }

}

private struct CompositionCanvasAnnotationAccessibilityOverlay: View {
    @ObservedObject var controller: EditorController
    let annotation: Annotation
    let displayRect: CGRect
    let index: Int
    let annotationCount: Int
    let isSelected: Bool

    private var descriptor: AnnotationAccessibilityDescriptor {
        AnnotationAccessibilityDescriptor(
            annotation: annotation,
            isSelected: isSelected,
            layerPosition: index + 1,
            layerCount: annotationCount
        )
    }

    var body: some View {
        Color.clear
            .frame(width: displayRect.width, height: displayRect.height)
            .position(x: displayRect.midX, y: displayRect.midY)
            .allowsHitTesting(false)
            .modifier(
                CompositionCanvasAnnotationAccessibilityModifier(
                    controller: controller,
                    annotationID: annotation.id,
                    label: descriptor.label,
                    value: descriptor.value,
                    index: index
                )
            )
    }
}

private struct CompositionCanvasItemAccessibilityModifier: ViewModifier {
    @ObservedObject var controller: EditorController
    let itemID: UUID
    let displayName: String
    let accessibilityValue: String
    let accessibilityIndex: Int
    let accessibilityItemCount: Int
    let modelIndex: Int
    let modelItemCount: Int
    let isFreeform: Bool
    let isSelected: Bool
    let isIncluded: Bool
    let canRemove: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let isFraming = controller.compositionFramingItemID == itemID
        let framingActionName = isFraming
            ? String(localized: "Finish Framing")
            : String(localized: "Adjust Framing")
        let canMoveEarlier = isFreeform
            ? controller.canMoveFreeformCompositionItem(
                itemID,
                direction: .towardBack
            )
            : modelIndex > 0
        let canMoveLater = isFreeform
            ? controller.canMoveFreeformCompositionItem(
                itemID,
                direction: .towardFront
            )
            : modelIndex + 1 < modelItemCount
        let moveEarlierLabel = isFreeform
            ? String(localized: "Send Backward")
            : String(localized: "Move Earlier")
        let moveLaterLabel = isFreeform
            ? String(localized: "Bring Forward")
            : String(localized: "Move Later")
        let base = content
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityLabel(displayName)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(
                "Press to select. Custom actions edit, frame, arrange, duplicate, include, exclude, or remove this item."
            )
            .accessibilityAction {
                controller.selectCompositionItems([itemID])
                controller.requestCompositionCanvasFocus()
            }
            .accessibilityAction(named: Text("Toggle Selection")) {
                controller.toggleCompositionItemSelection(itemID)
                controller.requestCompositionCanvasFocus()
            }
            .accessibilityAction(named: Text("Edit Selected Capture")) {
                controller.editCompositionLayerItem(itemID)
            }
            .accessibilityAction(named: Text(framingActionName)) {
                if isFraming {
                    controller.finishCompositionItemFraming()
                } else {
                    controller.beginCompositionItemFraming(itemID)
                }
                controller.requestCompositionCanvasFocus()
            }
            .accessibilityAction(named: Text(isIncluded ? "Exclude" : "Include")) {
                controller.setCompositionItems([itemID], included: !isIncluded)
            }
            .accessibilityAction(named: Text("Duplicate")) {
                controller.selectCompositionItems([itemID])
                controller.duplicateSelectedCompositionItem()
            }
            .accessibilityIdentifier(
                "composition.canvas.item.\(itemID.uuidString)"
            )
            .accessibilitySortPriority(
                Double(accessibilityItemCount - accessibilityIndex)
            )

        if canMoveEarlier, canMoveLater, canRemove {
            base
                .accessibilityAction(named: Text(moveEarlierLabel)) {
                    moveEarlier()
                }
                .accessibilityAction(named: Text(moveLaterLabel)) {
                    moveLater()
                }
                .accessibilityAction(named: Text("Remove")) {
                    removeItem()
                }
        } else if canMoveEarlier, canMoveLater {
            base
                .accessibilityAction(named: Text(moveEarlierLabel)) {
                    moveEarlier()
                }
                .accessibilityAction(named: Text(moveLaterLabel)) {
                    moveLater()
                }
        } else if canMoveEarlier, canRemove {
            base
                .accessibilityAction(named: Text(moveEarlierLabel)) {
                    moveEarlier()
                }
                .accessibilityAction(named: Text("Remove")) {
                    removeItem()
                }
        } else if canMoveLater, canRemove {
            base
                .accessibilityAction(named: Text(moveLaterLabel)) {
                    moveLater()
                }
                .accessibilityAction(named: Text("Remove")) {
                    removeItem()
                }
        } else if canMoveEarlier {
            base.accessibilityAction(named: Text(moveEarlierLabel)) {
                moveEarlier()
            }
        } else if canMoveLater {
            base.accessibilityAction(named: Text(moveLaterLabel)) {
                moveLater()
            }
        } else if canRemove {
            base.accessibilityAction(named: Text("Remove")) {
                removeItem()
            }
        } else {
            base
        }
    }

    private func removeItem() {
        controller.selectCompositionItems([itemID])
        controller.removeSelectedCompositionItems()
    }

    private func moveEarlier() {
        if isFreeform {
            controller.moveFreeformCompositionItem(
                itemID,
                direction: .towardBack
            )
        } else {
            controller.moveCompositionItem(itemID, to: modelIndex - 1)
        }
    }

    private func moveLater() {
        if isFreeform {
            controller.moveFreeformCompositionItem(
                itemID,
                direction: .towardFront
            )
        } else {
            controller.moveCompositionItem(itemID, to: modelIndex + 1)
        }
    }
}

private struct CompositionCanvasAnnotationAccessibilityModifier: ViewModifier {
    @ObservedObject var controller: EditorController
    let annotationID: UUID
    let label: String
    let value: String
    let index: Int

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint("Press to edit this composition annotation.")
            .accessibilityAction {
                controller.editCompositionLayerCanvas()
                controller.selectLayerAnnotations(
                    [annotationID],
                    in: .composition
                )
            }
            .accessibilityAction(named: Text("Delete")) {
                controller.deleteLayerAnnotations(
                    [annotationID],
                    in: .composition
                )
            }
            .accessibilityIdentifier(
                "composition.canvas.annotation.\(annotationID.uuidString)"
            )
            .accessibilitySortPriority(-Double(index + 1))
    }
}

private struct PresentationViewportEventLayer: NSViewRepresentable {
    @ObservedObject var controller: EditorController
    let contentSize: CGSize
    let presentationLayout: ScreenshotPresentationRenderLayout?
    let compositionLayout: CompositionRenderLayout?
    let sceneSlotRect: CGRect?
    let focusRequestRevision: Int
    let onCanvasInteraction: () -> Void

    func makeNSView(context: Context) -> PresentationViewportEventHostView {
        let view = PresentationViewportEventHostView(
            controller: controller,
            contentSize: contentSize,
            presentationLayout: presentationLayout,
            compositionLayout: compositionLayout,
            sceneSlotRect: sceneSlotRect,
            onCanvasInteraction: onCanvasInteraction
        )
        view.consumeFocusRequest(focusRequestRevision)
        return view
    }

    func updateNSView(_ nsView: PresentationViewportEventHostView, context: Context) {
        nsView.controller = controller
        nsView.contentSize = contentSize
        nsView.presentationLayout = presentationLayout
        nsView.compositionLayout = compositionLayout
        nsView.sceneSlotRect = sceneSlotRect
        nsView.onCanvasInteraction = onCanvasInteraction
        nsView.consumeFocusRequest(focusRequestRevision)
    }
}

private final class PresentationViewportEventHostView: NSView {
    private enum DragMode {
        case pan
        case subjectPlacement
        case sceneFraming
        case compositionItem(UUID)
        case compositionResize(UUID, CompositionFreeformResizeCorner)
        case compositionFraming(UUID)
        case compositionDivider(UUID, UUID, CompositionDividerAxis)
        case compositionWipe

        var isUndoableManipulation: Bool {
            switch self {
            case .subjectPlacement, .sceneFraming, .compositionItem, .compositionResize,
                 .compositionFraming, .compositionDivider, .compositionWipe:
                return true
            case .pan:
                return false
            }
        }
    }

    var controller: EditorController {
        didSet {
            synchronizeViewport()
        }
    }
    var contentSize: CGSize {
        didSet {
            synchronizeViewport()
        }
    }
    var presentationLayout: ScreenshotPresentationRenderLayout?
    var compositionLayout: CompositionRenderLayout?
    var sceneSlotRect: CGRect?
    var onCanvasInteraction: () -> Void

    private var lastDragPoint: CGPoint?
    private var dragMode: DragMode?
    private var mouseDownPoint: CGPoint?
    private var mouseDownModifiers: NSEvent.ModifierFlags = []
    private var dragDistance: CGFloat = 0
    private var consumedFocusRequestRevision: Int?
    private var pointerTrackingArea: NSTrackingArea?

    init(
        controller: EditorController,
        contentSize: CGSize,
        presentationLayout: ScreenshotPresentationRenderLayout?,
        compositionLayout: CompositionRenderLayout?,
        sceneSlotRect: CGRect?,
        onCanvasInteraction: @escaping () -> Void
    ) {
        self.controller = controller
        self.contentSize = contentSize
        self.presentationLayout = presentationLayout
        self.compositionLayout = compositionLayout
        self.sceneSlotRect = sceneSlotRect
        self.onCanvasInteraction = onCanvasInteraction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("PresentationViewportEventHostView is programmatic-only; use init(controller:contentSize:) instead of init(coder:).")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        synchronizeViewport()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            controller.setHoveredCompositionItem(nil)
        }
        requestFirstResponder()
        synchronizeViewport()
    }

    func consumeFocusRequest(_ revision: Int) {
        guard consumedFocusRequestRevision != revision else {
            return
        }
        consumedFocusRequestRevision = revision
        requestFirstResponder()
    }

    private func requestFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                return
            }
            window.makeFirstResponder(self)
        }
    }

    override func magnify(with event: NSEvent) {
        synchronizeViewport()
        let point = convert(event.locationInWindow, from: nil)
        controller.magnifyViewport(by: event.magnification, anchoredAt: point)
    }

    override func scrollWheel(with event: NSEvent) {
        synchronizeViewport()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)

        if modifiers.contains(.command) || modifiers.contains(.option) {
            controller.zoomViewportFromScrollWheel(deltaY: event.scrollingDeltaY, anchoredAt: point)
        } else {
            controller.panViewport(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredCompositionItem(
            at: convert(event.locationInWindow, from: nil)
        )
    }

    override func mouseExited(with event: NSEvent) {
        controller.setHoveredCompositionItem(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        onCanvasInteraction()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredCompositionItem(at: point)
        mouseDownPoint = point
        mouseDownModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        dragDistance = 0
        switch controller.presentationInspectorTab {
        case .scene:
            if event.clickCount == 2, isInsideSceneSlot(point) {
                controller.resetAppliedPresentationSceneFraming()
                lastDragPoint = nil
                dragMode = nil
                return
            }
            dragMode = isInsideSceneSlot(point) ? .sceneFraming : .pan

        case .style:
            dragMode = isInsidePresentationSubject(point) ? .subjectPlacement : .pan

        case .layout:
            guard let compositionPoint = compositionPoint(fromViewPoint: point),
                  let compositionLayout else {
                dragMode = .pan
                lastDragPoint = point
                return
            }

            if let resize = freeformResizeHandle(
                at: compositionPoint,
                layout: compositionLayout
            ) {
                controller.selectCompositionItems([resize.itemID])
                dragMode = .compositionResize(resize.itemID, resize.corner)
            } else if let divider = compositionLayout.comparison?.dividerRect,
               compositionLayout.comparison?.mode == .wipe,
               divider.insetBy(dx: -10, dy: -10).contains(compositionPoint) {
                dragMode = .compositionWipe
            } else if let divider = weightedDivider(at: compositionPoint, layout: compositionLayout) {
                dragMode = .compositionDivider(divider.first, divider.second, divider.axis)
            } else if let itemID = controller.compositionItemID(
                at: compositionPoint,
                in: compositionLayout,
                comparisonPhase:
                    controller.effectiveCompositionComparisonPreviewPhase
            ) {
                if event.clickCount == 2 {
                    controller.enterCompositionItemEditing(itemID)
                    lastDragPoint = nil
                    dragMode = nil
                    return
                }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.shift) || modifiers.contains(.command) {
                    controller.toggleCompositionItemSelection(itemID)
                } else if controller.composition?.selectedItemIDs.contains(itemID) != true {
                    controller.selectCompositionItems([itemID])
                }

                if modifiers.contains(.option) || controller.compositionFramingItemID == itemID {
                    controller.beginCompositionItemFraming(itemID)
                    dragMode = .compositionFraming(itemID)
                } else {
                    dragMode = .compositionItem(itemID)
                }
            } else {
                controller.selectCompositionItems([])
                dragMode = .pan
            }
        }

        lastDragPoint = point
        if dragMode?.isUndoableManipulation == true {
            controller.beginCoalescedEditorGesture()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mouseDownPoint {
            dragDistance = max(
                dragDistance,
                hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
            )
        }
        defer {
            lastDragPoint = point
        }

        guard let lastDragPoint else {
            return
        }

        let delta = CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y)
        guard let dragMode else {
            controller.panViewport(by: delta)
            return
        }
        switch dragMode {
        case .subjectPlacement:
            let scale = displayScale
            guard scale > 0 else {
                return
            }
            var offset = controller.presentation.subjectPlacement.offset
            offset.width += delta.width / scale
            offset.height += delta.height / scale
            controller.updatePresentationSubjectOffset(offset)

        case .sceneFraming:
            let scale = displayScale
            guard scale > 0 else {
                return
            }
            controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(
                width: delta.width / scale,
                height: delta.height / scale
            ))

        case .compositionItem:
            guard controller.composition?.layout.mode == .freeform,
                  let prior = compositionPoint(fromViewPoint: lastDragPoint),
                  let current = compositionPoint(fromViewPoint: point) else {
                return
            }
            controller.moveSelectedCompositionItemsBy(
                dx: current.x - prior.x,
                dy: current.y - prior.y
            )
            if !event.modifierFlags.contains(.command) {
                controller.snapSelectedFreeformCompositionItems(
                    threshold: max(1, 8 / max(compositionDisplayScale, 0.001))
                )
            }

        case .compositionResize(let itemID, let corner):
            guard let prior = compositionPoint(fromViewPoint: lastDragPoint),
                  let current = compositionPoint(fromViewPoint: point) else {
                return
            }
            controller.resizeFreeformCompositionItem(
                itemID: itemID,
                corner: corner,
                by: CGSize(width: current.x - prior.x, height: current.y - prior.y),
                preservesAspectRatio: event.modifierFlags.contains(.shift)
            )

        case .compositionFraming(let itemID):
            guard let prior = compositionPoint(fromViewPoint: lastDragPoint),
                  let current = compositionPoint(fromViewPoint: point) else {
                return
            }
            controller.adjustCompositionItemFraming(
                itemID: itemID,
                by: CGSize(width: current.x - prior.x, height: current.y - prior.y)
            )

        case .compositionDivider(let firstID, let secondID, let axis):
            guard let prior = compositionPoint(fromViewPoint: lastDragPoint),
                  let current = compositionPoint(fromViewPoint: point),
                  let liveLayout = try? controller.currentCompositionRenderLayout() else {
                return
            }
            let amount = axis == .horizontal
                ? current.x - prior.x
                : current.y - prior.y
            controller.adjustCompositionDivider(
                firstItemID: firstID,
                secondItemID: secondID,
                by: amount,
                axis: axis,
                layout: liveLayout
            )

        case .compositionWipe:
            guard let compositionPoint = compositionPoint(fromViewPoint: point),
                  let comparison = compositionLayout?.comparison,
                  let sharedFrame = comparison.sharedFrame else {
                return
            }
            let position: CGFloat
            switch comparison.axis {
            case .horizontal:
                position = (compositionPoint.x - sharedFrame.minX) / max(sharedFrame.width, 1)
            case .vertical:
                position = (compositionPoint.y - sharedFrame.minY) / max(sharedFrame.height, 1)
            }
            controller.adjustCompositionWipeDivider(to: position)

        case .pan:
            controller.panViewport(by: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .compositionItem = dragMode,
           dragDistance >= 4,
           controller.composition?.layout.mode != .freeform,
           let compositionPoint = compositionPoint(
               fromViewPoint: convert(event.locationInWindow, from: nil)
           ),
           let layout = try? controller.currentCompositionRenderLayout(),
           let targetID = controller.compositionItemID(
               at: compositionPoint,
               in: layout,
               comparisonPhase:
                   controller.effectiveCompositionComparisonPreviewPhase
           ),
           let destination = controller.composition?.items.firstIndex(where: { $0.id == targetID }) {
            controller.moveSelectedCompositionItems(to: destination)
        }
        let clickedItemID: UUID?
        if case .compositionItem(let itemID) = dragMode {
            clickedItemID = itemID
        } else {
            clickedItemID = nil
        }
        if dragMode?.isUndoableManipulation == true {
            controller.endCoalescedEditorGesture()
        }
        if dragDistance < 4,
           let clickedItemID,
           !mouseDownModifiers.contains(.shift),
           !mouseDownModifiers.contains(.command) {
            controller.selectCompositionItems([clickedItemID])
        }
        lastDragPoint = nil
        dragMode = nil
        mouseDownPoint = nil
        mouseDownModifiers = []
        dragDistance = 0
        updateHoveredCompositionItem(
            at: convert(event.locationInWindow, from: nil)
        )
    }

    override func keyDown(with event: NSEvent) {
        onCanvasInteraction()
        guard controller.presentationInspectorTab == .layout,
              controller.hasComposition else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let selectedID = controller.composition?.selectedItemIDs.last
        switch event.keyCode {
        case 36, 76:
            guard let selectedID else {
                NSSound.beep()
                return
            }
            if modifiers.contains(.option) {
                controller.beginCompositionItemFraming(selectedID)
            } else {
                controller.enterCompositionItemEditing(selectedID)
            }
        case 51, 117:
            controller.removeSelectedCompositionItems()
        case 53:
            controller.finishCompositionItemFraming()
        case 123:
            handleCompositionArrowKey(dx: -1, dy: 0, modifiers: modifiers)
        case 124:
            handleCompositionArrowKey(dx: 1, dy: 0, modifiers: modifiers)
        case 125:
            handleCompositionArrowKey(dx: 0, dy: 1, modifiers: modifiers)
        case 126:
            handleCompositionArrowKey(dx: 0, dy: -1, modifiers: modifiers)
        default:
            if modifiers.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "d" {
                controller.duplicateSelectedCompositionItem()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if dragMode?.isUndoableManipulation == true {
            controller.cancelCoalescedEditorGesture()
        }
        controller.finishCompositionItemFraming()
        lastDragPoint = nil
        dragMode = nil
        mouseDownPoint = nil
        mouseDownModifiers = []
        dragDistance = 0
    }

    private func updateHoveredCompositionItem(at viewPoint: CGPoint) {
        guard controller.presentationInspectorTab == .layout,
              let compositionLayout,
              let compositionPoint = compositionPoint(
                fromViewPoint: viewPoint
              ) else {
            controller.setHoveredCompositionItem(nil)
            NSCursor.arrow.set()
            return
        }
        let itemID = controller.compositionItemID(
            at: compositionPoint,
            in: compositionLayout,
            comparisonPhase:
                controller.effectiveCompositionComparisonPreviewPhase
        )
        controller.setHoveredCompositionItem(itemID)
        if itemID == nil {
            NSCursor.arrow.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    private func handleCompositionArrowKey(
        dx: CGFloat,
        dy: CGFloat,
        modifiers: NSEvent.ModifierFlags
    ) {
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        if let framingItemID = controller.compositionFramingItemID {
            controller.adjustCompositionItemFraming(
                itemID: framingItemID,
                by: CGSize(width: dx * step, height: dy * step)
            )
            if let offset = controller.composition?.items
                .first(where: { $0.id == framingItemID })?
                .framing
                .offset {
                AppAccessibility.announce(
                    "Focal offset \(Int(offset.width.rounded())) horizontal, "
                        + "\(Int(offset.height.rounded())) vertical."
                )
            }
            return
        }
        if modifiers.contains(.option),
           controller.composition?.layout.mode == .freeform {
            controller.resizeSelectedFreeformCompositionItemsBy(
                widthDelta: dx * step,
                heightDelta: dy * step
            )
            return
        }
        controller.moveCompositionSelectionForKeyboard(
            dx: dx * step,
            dy: dy * step
        )
    }

    private func synchronizeViewport() {
        controller.updateViewportCanvasSize(bounds.size)

        guard contentSize.width > 0, contentSize.height > 0 else {
            return
        }

        controller.updatePresentationViewportContentSize(contentSize)
    }

    private var displayScale: CGFloat {
        let viewportRect = controller.viewport.imageRect
        guard contentSize.width > 0,
              viewportRect.width > 0 else {
            return 1
        }

        return viewportRect.width / contentSize.width
    }

    private var compositionDisplayScale: CGFloat {
        guard let presentationLayout,
              let compositionLayout,
              compositionLayout.canvasSize.width > 0 else {
            return displayScale
        }
        return displayScale
            * presentationLayout.contentRect.width
            / compositionLayout.canvasSize.width
    }

    private func isInsideSceneSlot(_ viewPoint: CGPoint) -> Bool {
        guard let sceneSlotRect,
              controller.presentation.scene != nil else {
            return false
        }

        let viewportRect = controller.viewport.imageRect
        let scale = displayScale
        guard scale > 0 else {
            return false
        }

        let scenePoint = CGPoint(
            x: (viewPoint.x - viewportRect.minX) / scale,
            y: (viewPoint.y - viewportRect.minY) / scale
        )
        return sceneSlotRect.insetBy(dx: -8, dy: -8).contains(scenePoint)
    }

    private func isInsidePresentationSubject(_ viewPoint: CGPoint) -> Bool {
        guard let presentationLayout,
              let presentationPoint = presentationPoint(fromViewPoint: viewPoint) else {
            return false
        }
        return presentationLayout.subjectRect.insetBy(dx: -8, dy: -8).contains(presentationPoint)
    }

    private func presentationPoint(fromViewPoint viewPoint: CGPoint) -> CGPoint? {
        let viewportRect = controller.viewport.imageRect
        let scale = displayScale
        guard scale > 0,
              viewportRect.width > 0,
              viewportRect.height > 0 else {
            return nil
        }
        return CGPoint(
            x: (viewPoint.x - viewportRect.minX) / scale,
            y: (viewPoint.y - viewportRect.minY) / scale
        )
    }

    private func compositionPoint(fromViewPoint viewPoint: CGPoint) -> CGPoint? {
        guard let presentationLayout,
              let compositionLayout else {
            return nil
        }
        return PresentationCompositionOverlayGeometry.compositionPoint(
            fromDisplayPoint: viewPoint,
            presentationLayout: presentationLayout,
            compositionLayout: compositionLayout,
            viewportRect: controller.viewport.imageRect
        )
    }

    private func weightedDivider(
        at point: CGPoint,
        layout: CompositionRenderLayout
    ) -> (first: UUID, second: UUID, axis: CompositionDividerAxis)? {
        guard controller.composition?.layout.sizingMode == .weighted else {
            return nil
        }
        guard let hit = CompositionWeightedDividerHitTesting.divider(
            at: point,
            in: layout.items
        ) else {
            return nil
        }
        return (hit.firstItemID, hit.secondItemID, hit.axis)
    }

    private func freeformResizeHandle(
        at point: CGPoint,
        layout: CompositionRenderLayout
    ) -> (itemID: UUID, corner: CompositionFreeformResizeCorner)? {
        guard controller.composition?.layout.mode == .freeform else {
            return nil
        }
        let selectedIDs = Set(controller.composition?.selectedItemIDs ?? [])
        let radius = max(4, 9 / max(compositionDisplayScale, 0.001))
        for placement in layout.items
            .filter({ selectedIDs.contains($0.itemID) })
            .sorted(by: { $0.zIndex > $1.zIndex }) {
            guard let presentationLayout,
                  PresentationCompositionOverlayGeometry.isFullyVisible(
                      compositionRect: placement.frameRect,
                      presentationLayout: presentationLayout,
                      compositionLayout: layout
                  ) else {
                continue
            }
            let handles: [(CGPoint, CompositionFreeformResizeCorner)] = [
                (
                    CGPoint(x: placement.frameRect.minX, y: placement.frameRect.minY),
                    .topLeading
                ),
                (
                    CGPoint(x: placement.frameRect.maxX, y: placement.frameRect.minY),
                    .topTrailing
                ),
                (
                    CGPoint(x: placement.frameRect.minX, y: placement.frameRect.maxY),
                    .bottomLeading
                ),
                (
                    CGPoint(x: placement.frameRect.maxX, y: placement.frameRect.maxY),
                    .bottomTrailing
                ),
            ]
            for (handlePoint, corner) in handles {
                let hitRect = CGRect(
                    x: handlePoint.x - radius,
                    y: handlePoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                if hitRect.contains(point) {
                    return (placement.itemID, corner)
                }
            }
        }
        return nil
    }
}

private struct PresentationOutOfCapturePatternView: NSViewRepresentable {
    let excludedSize: CGSize
    let settings: EditorOutOfCapturePatternSettings

    func makeNSView(context: Context) -> PresentationOutOfCapturePatternHostView {
        PresentationOutOfCapturePatternHostView()
    }

    func updateNSView(_ nsView: PresentationOutOfCapturePatternHostView, context: Context) {
        nsView.configure(excludedSize: excludedSize, settings: settings)
    }
}

private final class PresentationOutOfCapturePatternHostView: NSView {
    private var excludedSize: CGSize = .zero
    private var settings: EditorOutOfCapturePatternSettings = .default

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("PresentationOutOfCapturePatternHostView is programmatic-only; use init(frame:) instead of init(coder:).")
    }

    func configure(excludedSize: CGSize, settings: EditorOutOfCapturePatternSettings) {
        guard self.excludedSize != excludedSize || self.settings != settings else {
            return
        }

        self.excludedSize = excludedSize
        self.settings = settings
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let excludedRect = CGRect(
            x: bounds.midX - excludedSize.width / 2,
            y: bounds.midY - excludedSize.height / 2,
            width: excludedSize.width,
            height: excludedSize.height
        )
        OutOfCapturePatternRenderer.draw(
            bounds: bounds,
            excluding: excludedRect,
            settings: settings,
            appearance: effectiveAppearance
        )
    }
}

private extension ScreenshotPresentation {
    var canUseLiveTransparentPresentationPreview: Bool {
        if !isEnabled {
            return true
        }

        if scene != nil {
            return false
        }

        return background == .transparent
            && canvas == .original
            && frame == .none
            && shadow == .off
            && cornerRadius == 0
    }
}
