import AppKit
import SwiftUI

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
    @State private var previewState: PreviewState?
    @State private var renderSequence = 0

    private var effectivePresentation: ScreenshotPresentation {
        controller.presentation
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
        let presentation = controller.presentation
        return [
            "\(controller.presentationContentRevision)",
            "\(controller.persistenceRevision)",
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

            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let previewState {
                    preview(previewState, availableSize: proxy.size)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                PresentationViewportEventLayer(
                    controller: controller,
                    contentSize: contentSize,
                    sceneSlotRect: sceneSlotRect
                )
                .allowsHitTesting(true)
            }
            .overlay(alignment: .topLeading) {
                Label("Final Export Preview", systemImage: EditorWorkspaceMode.presentation.systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(18)
            }
            .task(id: "\(renderID)|\(Int(previewPixelDimension.rounded()))") {
                await refreshPreviewRender(maxPixelDimension: previewPixelDimension)
            }
        }
    }

    private func refreshPreviewRender(maxPixelDimension: CGFloat) async {
        renderSequence += 1
        let sequence = renderSequence
        let hadExistingPreview = previewState != nil
        PresentationPerformanceMetrics.logEvent(
            "presentationCanvas.render.schedule",
            context: "sequence=\(sequence) hasPreview=\(hadExistingPreview) cap=\(Int(maxPixelDimension.rounded()))"
        )

        do {
            if hadExistingPreview {
                try await Task.sleep(nanoseconds: 140_000_000)
                try Task.checkCancellation()
            }

            guard let input = controller.presentationPreviewRenderInput(context: "presentationCanvas") else {
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.render.noInput",
                    context: "sequence=\(sequence)"
                )
                previewState = nil
                return
            }

            if input.presentation.canUseLiveTransparentPresentationPreview {
                let layout = ScreenshotPresentationRenderer.layout(
                    contentSize: CGSize(width: input.contentImage.width, height: input.contentImage.height),
                    presentation: input.presentation
                )
                controller.updatePresentationViewportContentSize(layout.canvasSize)
                previewState = .liveTransparent(contentImage: input.contentImage)
                PresentationPerformanceMetrics.logEvent(
                    "presentationCanvas.liveTransparent.finish",
                    context: "sequence=\(sequence) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) canvas=\(PresentationPerformanceMetrics.size(layout.canvasSize)) subject=\(PresentationPerformanceMetrics.size(layout.subjectRect.size))"
                )
                return
            }

            PresentationPerformanceMetrics.logEvent(
                "presentationCanvas.render.start",
                context: "sequence=\(sequence) revision=\(input.contentRevision) content=\(input.contentImage.width)x\(input.contentImage.height) cap=\(Int(maxPixelDimension.rounded()))"
            )

            let result = await Task.detached(priority: .userInitiated) {
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
            }.value

            try Task.checkCancellation()
            previewState = result.map { .rendered($0) }
            if let result {
                controller.updatePresentationViewportContentSize(result.layout.canvasSize)
            }
            PresentationPerformanceMetrics.logEvent(
                "presentationCanvas.render.finish",
                context: "sequence=\(sequence) revision=\(input.contentRevision) output=\(PresentationPerformanceMetrics.imageSize(result?.image))"
            )
        } catch is CancellationError {
            PresentationPerformanceMetrics.logEvent(
                "presentationCanvas.render.cancel",
                context: "sequence=\(sequence)"
            )
        } catch {
            PresentationPerformanceMetrics.logEvent(
                "presentationCanvas.render.error",
                context: "sequence=\(sequence) error=\(error.localizedDescription)"
            )
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.72), style: StrokeStyle(lineWidth: 1.25, dash: [7, 5]))
                    .frame(
                        width: max(layout.subjectRect.width * scale, 1),
                        height: max(layout.subjectRect.height * scale, 1)
                    )
                    .offset(
                        x: layout.subjectRect.minX * scale,
                        y: layout.subjectRect.minY * scale
                    )
                    .allowsHitTesting(false)
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

private struct PresentationViewportEventLayer: NSViewRepresentable {
    @ObservedObject var controller: EditorController
    let contentSize: CGSize
    let sceneSlotRect: CGRect?

    func makeNSView(context: Context) -> PresentationViewportEventHostView {
        PresentationViewportEventHostView(
            controller: controller,
            contentSize: contentSize,
            sceneSlotRect: sceneSlotRect
        )
    }

    func updateNSView(_ nsView: PresentationViewportEventHostView, context: Context) {
        nsView.controller = controller
        nsView.contentSize = contentSize
        nsView.sceneSlotRect = sceneSlotRect
    }
}

private final class PresentationViewportEventHostView: NSView {
    private enum DragMode {
        case pan
        case sceneFraming
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
    var sceneSlotRect: CGRect?

    private var lastDragPoint: CGPoint?
    private var dragMode: DragMode?

    init(controller: EditorController, contentSize: CGSize, sceneSlotRect: CGRect?) {
        self.controller = controller
        self.contentSize = contentSize
        self.sceneSlotRect = sceneSlotRect
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        synchronizeViewport()
    }

    override func magnify(with event: NSEvent) {
        synchronizeViewport()
        let point = convert(event.locationInWindow, from: nil)
        if isInsideSceneSlot(point) {
            controller.scaleAppliedPresentationSceneFraming(by: max(1 + event.magnification, 0.05))
        } else {
            controller.magnifyViewport(by: event.magnification, anchoredAt: point)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        synchronizeViewport()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)

        if modifiers.contains(.option), isInsideSceneSlot(point) {
            controller.scaleAppliedPresentationSceneFraming(by: exp(event.scrollingDeltaY / 300))
        } else if modifiers.contains(.command) || modifiers.contains(.option) {
            controller.zoomViewportFromScrollWheel(deltaY: event.scrollingDeltaY, anchoredAt: point)
        } else {
            controller.panViewport(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, isInsideSceneSlot(point) {
            controller.resetAppliedPresentationSceneFraming()
            lastDragPoint = nil
            dragMode = nil
            return
        }

        lastDragPoint = point
        dragMode = isInsideSceneSlot(point) ? .sceneFraming : .pan
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            lastDragPoint = point
        }

        guard let lastDragPoint else {
            return
        }

        let delta = CGSize(width: point.x - lastDragPoint.x, height: point.y - lastDragPoint.y)
        switch dragMode {
        case .sceneFraming:
            let scale = displayScale
            guard scale > 0 else {
                return
            }
            controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(
                width: delta.width / scale,
                height: delta.height / scale
            ))
        case .pan, .none:
            controller.panViewport(by: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        dragMode = nil
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
