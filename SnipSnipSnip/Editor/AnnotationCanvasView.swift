import AppKit
import Combine
import SwiftUI

struct CropFocusPresentationState {
    let cropRect: CGRect
    let overlayAlpha: CGFloat
    let showsFocusedCropChrome: Bool
}

struct AnnotationCanvasContainer: NSViewRepresentable {
    @ObservedObject var controller: EditorController

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(controller: controller)
    }

    func updateNSView(_ nsView: AnnotationCanvasView, context: Context) {
        if nsView.controller !== controller {
            nsView.controller = controller
        }
    }
}

private final class AnnotationCanvasBaseImageView: NSView {
    var image: CGImage? {
        didSet {
            needsDisplay = true
        }
    }

    var imageSize: CGSize = .zero {
        didSet {
            guard oldValue != imageSize else {
                return
            }

            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else {
            return
        }

        NSImage(cgImage: image, size: imageSize).draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}

final class AnnotationCanvasView: NSView {
    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            displayedBaseImageCrop = nil
            overlayView.controller = controller
            bindController()
        }
    }

    private let baseImageView = AnnotationCanvasBaseImageView()
    private lazy var overlayView = AnnotationCanvasOverlayView(controller: controller)
    private var controllerChangeObserver: AnyCancellable?
    private var displayedBaseImageCrop: CGRect?

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(baseImageView)
        addSubview(overlayView)
        bindController()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        synchronizeViewportToBounds()
        overlayView.frame = bounds
        synchronizeBaseImagePresentation()
        overlayView.refreshAfterLayout()
    }

    func refreshCanvasDisplay() {
        synchronizeBaseImagePresentation()
        overlayView.needsDisplay = true
    }

    var debugCommittedCropPresentation: CropFocusPresentationState? {
        overlayView.debugCommittedCropPresentation
    }

    private func bindController() {
        controllerChangeObserver = controller.$canvasRevision.sink { [weak self] _ in
            guard let self else {
                return
            }

            self.synchronizeBaseImagePresentation()
            self.overlayView.controllerDidChange()
        }

        synchronizeBaseImagePresentation()
        overlayView.controllerDidChange()
    }

    private func synchronizeViewportToBounds() {
        controller.updateViewportCanvasSize(bounds.size)
    }

    private func synchronizeBaseImagePresentation() {
        let canvasRect = controller.viewport.imageRect
        baseImageView.frame = canvasRect

        guard canvasRect.width > 0, canvasRect.height > 0 else {
            displayedBaseImageCrop = nil
            baseImageView.image = nil
            baseImageView.isHidden = true
            return
        }

        baseImageView.isHidden = false

        let documentBounds = controller.capture.documentRect
        guard documentBounds.width > 0, documentBounds.height > 0 else {
            displayedBaseImageCrop = nil
            baseImageView.image = nil
            return
        }

        if displayedBaseImageCrop != documentBounds {
            displayedBaseImageCrop = documentBounds
            baseImageView.image = controller.capture.image
            baseImageView.imageSize = documentBounds.size
        }
    }
}

private final class AnnotationCanvasOverlayView: NSView {
    private static let singleKeyToolShortcuts: [String: EditorTool] = [
        "v": .select,
        "r": .rectangle,
        "o": .ellipse,
        "l": .line,
        "a": .arrow,
        "p": .freehand,
        "h": .highlighter,
        "b": .highlight,
        "t": .text,
        "c": .callout,
        "m": .measure,
        "s": .spotlight,
        "x": .redact
    ]

    var controller: EditorController

    private var interactionState = AnnotationCanvasInteractionState()
    private var cropHUDDocumentPoint: CGPoint?
    private var pointerTrackingArea: NSTrackingArea?

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        discardCursorRects()

        if controller.activeTool == .uiMapInspect, let uiMap = controller.uiMapSnapshot {
            let canvasRect = controller.viewport.imageRect
            for element in uiMap.allElements where element.isShowAllOverlayCandidate {
                let rect = viewRect(for: element.documentRect, in: canvasRect)
                if rect.width > 0, rect.height > 0 {
                    addCursorRect(rect, cursor: .pointingHand)
                }
            }
        } else if let selectionBounds = controller.selectionBoundingRect {
            let selectionRect = viewRect(for: selectionBounds, in: controller.viewport.imageRect)

            if selectionRect.width > 0, selectionRect.height > 0 {
                for handle in ResizeHandle.allCases {
                    addCursorRect(selectionHandleRect(for: handle, bounds: selectionRect), cursor: cursor(for: handle))
                }
            }
        }

        let ib = imageBounds
        let vr = controller.viewport.imageRect
        if controller.activeTool != .uiMapInspect,
           ib.width > 0, ib.height > 0, vr.width > 0, vr.height > 0 {
            for handle in ResizeHandle.allCases {
                let handleRect = cropHandleRect(for: handle)
                if handleRect.origin.x.isFinite, handleRect.origin.y.isFinite {
                    addCursorRect(handleRect, cursor: cursor(for: handle))
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let canvasRect = controller.viewport.imageRect
        guard canvasRect.width > 0, canvasRect.height > 0 else {
            return
        }

        if let draftCropRect = interactionState.draftCropRect {
            drawCropMask(for: viewRect(for: draftCropRect, in: canvasRect), overlayAlpha: 0.18, inside: canvasRect)
        } else {
            let committedRect = committedCropRect(in: canvasRect)
            if committedCropOverlayAlpha > 0 {
                drawCropMask(for: committedRect, overlayAlpha: committedCropOverlayAlpha, inside: canvasRect)
            }
        }

        drawOutOfCapturePattern(excluding: canvasRect)

        EditorRenderer.drawAnnotations(
            baseImage: controller.capture.image,
            snapshot: controller.snapshot,
            canvasRect: canvasRect,
            draftAnnotations: interactionState.draftAnnotations,
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions
        )

        let displayedSelection = interactionState.draftAnnotations.isEmpty ? controller.selectedAnnotations : interactionState.draftAnnotations

        if !displayedSelection.isEmpty {
            drawSelection(for: displayedSelection, in: canvasRect)
        }

        if let draftSelectionRect = interactionState.draftSelectionRect {
            drawMarqueeSelection(draftSelectionRect, in: canvasRect)
        }

        if !interactionState.snapGuides.isEmpty {
            drawSnapGuides(interactionState.snapGuides, in: canvasRect)
        }

        drawSelectedUIMapElement(in: canvasRect)

        if let draftCropRect = interactionState.draftCropRect {
            if case .recognizingText = interactionState.dragMode {
                drawCropOutlineAndHandles(for: viewRect(for: draftCropRect, in: canvasRect), strokeColor: .systemBlue)
            } else {
                drawCropOutlineAndHandles(for: viewRect(for: draftCropRect, in: canvasRect), strokeColor: .systemGreen)
                drawCropInteractionHUD(for: draftCropRect, in: canvasRect)
            }
        } else {
            drawCropOutlineAndHandles(
                for: committedCropRect(in: canvasRect),
                strokeColor: NSColor.systemGreen.withAlphaComponent(0.92)
            )
        }
    }

    func controllerDidChange() {
        invalidateCursorRects()
        needsDisplay = true
    }

    func refreshAfterLayout() {
        invalidateCursorRects()
        needsDisplay = true
    }

    private func drawSelectedUIMapElement(in canvasRect: CGRect) {
        if controller.showsAllUIMapElements, let uiMap = controller.uiMapSnapshot {
            for element in uiMap.allElements {
                let isSelected = element.id == controller.selectedUIMapElementID
                guard isSelected || element.isShowAllOverlayCandidate else {
                    continue
                }

                drawUIMapElement(
                    element,
                    in: canvasRect,
                    isSelected: isSelected
                )
            }
            return
        }

        if let hoveredElementID = controller.hoveredUIMapElementID,
           hoveredElementID != controller.selectedUIMapElementID,
           let hoveredElement = controller.uiMapSnapshot?.element(matching: hoveredElementID) {
            drawUIMapElement(hoveredElement, in: canvasRect, isSelected: false)
        }

        guard let element = controller.selectedUIMapElement else {
            return
        }

        drawUIMapElement(element, in: canvasRect, isSelected: true)
    }

    private func drawUIMapElement(_ element: UIMapElement, in canvasRect: CGRect, isSelected: Bool) {
        let options = controller.uiMapOverlayOptions
        let rect = viewRect(for: element.documentRect, in: canvasRect)
        guard rect.width > 0, rect.height > 0 else {
            return
        }

        let color = uiMapOverlayColor(for: element)

        if options.showsOutline {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            if isSelected {
                color.withAlphaComponent(0.18).setFill()
                path.fill()
            }
            color.withAlphaComponent(isSelected ? 0.95 : 0.48).setStroke()
            path.lineWidth = isSelected ? 2 : 1
            path.stroke()
        }

        guard !(controller.showsAllUIMapElements || controller.activeTool == .uiMapInspect) || isSelected else {
            return
        }

        let labelSegments = uiMapOverlayLabelSegments(for: element, options: options)
        guard !labelSegments.isEmpty else {
            return
        }

        let label = labelSegments.joined(separator: "  ")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let attributedLabel = NSAttributedString(string: label, attributes: attributes)
        let labelSize = attributedLabel.size()
        let labelRect = CGRect(
            x: rect.minX,
            y: max(canvasRect.minY, rect.minY - labelSize.height - 8),
            width: min(labelSize.width + 12, max(canvasRect.width, 1)),
            height: labelSize.height + 6
        )

        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()
        attributedLabel.draw(at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 3))
    }

    private func uiMapOverlayColor(for element: UIMapElement) -> NSColor {
        element.isRecognizedTextSupplement ? .systemOrange : .systemBlue
    }

    private func uiMapOverlayLabelSegments(for element: UIMapElement, options: UIMapOverlayOptions) -> [String] {
        var segments: [String] = []

        if options.showsLabel {
            segments.append(element.displayName)
        }

        if options.showsIdentifier, let identifier = element.accessibilityIdentifier {
            segments.append("#\(identifier)")
        }

        if options.showsRole {
            segments.append(element.typeLabel)
        }

        if options.showsCoordinates {
            segments.append("x \(Int(element.documentRect.minX)), y \(Int(element.documentRect.minY))")
        }

        if options.showsDimensions {
            segments.append("\(Int(element.documentRect.width)) x \(Int(element.documentRect.height))")
        }

        return segments
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)

        if controller.activeTool != .uiMapInspect,
           let handle = cropHandle(at: viewPoint) {
            interactionState.beginCropResize(
                originalBounds: controller.snapshot.cropRect.gscIntegralStandardized,
                handle: handle
            )
            cropHUDDocumentPoint = handle.position(in: controller.snapshot.cropRect.gscIntegralStandardized)
            needsDisplay = true
            return
        }

        guard let point = documentPoint(from: viewPoint) else {
            return
        }

        if controller.activeTool != .crop,
           controller.activeTool != .uiMapInspect,
           let selectionBounds = controller.selectionBoundingRect,
           let handle = selectionHandle(at: viewPoint) {
            interactionState.beginResize(annotations: controller.selectedAnnotations, originalBounds: selectionBounds, handle: handle)
            needsDisplay = true
            return
        }

        if controller.activeTool != .select,
           controller.activeTool != .crop,
           controller.activeTool != .uiMapInspect,
           let selectionBounds = controller.selectionBoundingRect,
           controller.selectedAnnotations.contains(where: { $0.contains(point) }) {
            interactionState.beginMove(annotations: controller.selectedAnnotations, anchor: point, originalBounds: selectionBounds)
            needsDisplay = true
            return
        }

        switch controller.activeTool {
        case .select:
            handleSelectMouseDown(point, viewPoint: viewPoint, with: event)
        case .uiMapInspect:
            handleUIMapInspectMouseDown(point)
        case .rectangle:
            interactionState.beginRectDrawing(tool: .rectangle, anchor: point)
        case .ellipse:
            interactionState.beginRectDrawing(tool: .ellipse, anchor: point)
        case .line:
            interactionState.beginLineDrawing(tool: .line, anchor: point)
        case .arrow:
            interactionState.beginLineDrawing(tool: .arrow, anchor: point)
        case .measure:
            interactionState.beginLineDrawing(tool: .measure, anchor: point)
        case .freehand:
            interactionState.beginFreehand(tool: .freehand, at: point, style: controller.style(for: .freehand))
        case .highlighter:
            interactionState.beginFreehand(tool: .highlighter, at: point, style: controller.style(for: .highlighter))
        case .highlight:
            interactionState.beginRectDrawing(tool: .highlight, anchor: point)
        case .text:
            controller.addAnnotation(Annotation.makeText(at: point, style: controller.style(for: .text)))
            needsDisplay = true
        case .callout:
            controller.addAnnotation(Annotation.makeCallout(at: point, number: controller.nextCalloutNumber, style: controller.style(for: .callout)))
            needsDisplay = true
        case .spotlight:
            interactionState.beginRectDrawing(tool: .spotlight, anchor: point)
        case .colorPicker:
            controller.previewSampledColor(at: point)
            needsDisplay = true
        case .ocrText:
            interactionState.beginTextRecognition(at: point)
        case .blur:
            interactionState.beginRectDrawing(tool: .blur, anchor: point)
        case .pixelate:
            interactionState.beginRectDrawing(tool: .pixelate, anchor: point)
        case .redact:
            interactionState.beginRectDrawing(tool: .redact, anchor: point)
        case .crop:
            interactionState.beginCrop(at: point)
            cropHUDDocumentPoint = point
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard controller.activeTool == .uiMapInspect else {
            controller.hoverUIMapElement(nil)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let point = documentPoint(from: viewPoint) else {
            controller.hoverUIMapElement(nil)
            return
        }

        controller.hoverUIMapElement(uiMapElement(at: point)?.id)
    }

    override func mouseExited(with event: NSEvent) {
        controller.hoverUIMapElement(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let rawViewPoint = convert(event.locationInWindow, from: nil)

        // Crop handle resize must use unclamped document coordinates so dragging
        // at or beyond the image edge still registers. updateResizedCrop clamps
        // the result to imageBounds internally.
        let isCropBoundsDrag: Bool
        switch interactionState.dragMode {
        case .resizingCrop, .movingCrop:
            isCropBoundsDrag = true
        default:
            isCropBoundsDrag = false
        }

        if isCropBoundsDrag {
            let point = documentPointUnclamped(from: rawViewPoint)
            cropHUDDocumentPoint = point
            interactionState.update(
                at: point,
                snapshot: controller.snapshot,
                imageBounds: imageBounds,
                cropAspectRatio: controller.cropAspectRatioPreset.ratio,
                styleProvider: controller.style(for:)
            )
            if let draftCropRect = interactionState.draftCropRect {
                controller.previewCropRect(draftCropRect)
            }
            needsDisplay = true
            return
        }

        guard let point = documentPoint(from: rawViewPoint) else {
            return
        }

        if controller.activeTool == .colorPicker {
            controller.previewSampledColor(at: point)
            needsDisplay = true
            return
        }

        interactionState.update(
            at: point,
            snapshot: controller.snapshot,
            imageBounds: imageBounds,
            cropAspectRatio: controller.cropAspectRatioPreset.ratio,
            styleProvider: controller.style(for:)
        )

        if case .cropping = interactionState.dragMode {
            cropHUDDocumentPoint = point
        }

        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let activeDragMode = interactionState.dragMode
        let finalDraftCropRect = interactionState.draftCropRect

        defer {
            interactionState.reset()
            cropHUDDocumentPoint = nil
            needsDisplay = true
        }

        if controller.activeTool == .colorPicker,
           let point = documentPoint(from: convert(event.locationInWindow, from: nil)) {
            controller.applySampledColor(at: point, toFill: event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option))
            return
        }

        apply(
            interactionState.finish(snapshot: controller.snapshot),
            activeDragMode: activeDragMode,
            finalDraftCropRect: finalDraftCropRect
        )
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if handleTextEntryKey(event, modifiers: modifiers) {
            needsDisplay = true
            return
        }

        switch (modifiers, event.charactersIgnoringModifiers) {
        case ([.command], "z"):
            controller.undo()
        case ([.command, .shift], "z"):
            controller.redo()
        case ([.command], "a"):
            controller.selectAll()
        case ([.command], "v"):
            if !controller.addImageOverlayFromPasteboard() {
                super.keyDown(with: event)
            }
        case ([.command], "g"):
            controller.groupSelected()
        case ([.command, .shift], "g"):
            controller.ungroupSelected()
        case ([], _) where handleArrowNudge(event, step: 1):
            break
        case ([.shift], _) where handleArrowNudge(event, step: 10):
            break
        case ([], _) where handleSingleKeyToolShortcut(event):
            break
        case (_, String(UnicodeScalar(NSDeleteCharacter)!)), (_, String(UnicodeScalar(NSBackspaceCharacter)!)):
            controller.deleteSelected()
        default:
            super.keyDown(with: event)
        }

        needsDisplay = true
    }

    private func handleArrowNudge(_ event: NSEvent, step: CGFloat) -> Bool {
        let delta: CGSize

        switch event.keyCode {
        case 123:
            delta = CGSize(width: -step, height: 0)
        case 124:
            delta = CGSize(width: step, height: 0)
        case 125:
            delta = CGSize(width: 0, height: step)
        case 126:
            delta = CGSize(width: 0, height: -step)
        default:
            return false
        }

        controller.nudgeSelectedAnnotations(by: delta)
        return true
    }

    private func handleSingleKeyToolShortcut(_ event: NSEvent) -> Bool {
        guard controller.editorSingleKeyToolShortcutsEnabled,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let tool = Self.singleKeyToolShortcuts[characters] else {
            return false
        }

        controller.activateToolbarTool(tool)
        return true
    }

    override func magnify(with event: NSEvent) {
        guard interactionState.dragMode == nil else {
            super.magnify(with: event)
            return
        }

        synchronizeViewportToBounds()
        controller.magnifyViewport(by: event.magnification, anchoredAt: convert(event.locationInWindow, from: nil))
        canvasView?.refreshCanvasDisplay()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard interactionState.dragMode == nil else {
            super.scrollWheel(with: event)
            return
        }

        synchronizeViewportToBounds()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) || modifiers.contains(.option) {
            controller.zoomViewportFromScrollWheel(deltaY: event.scrollingDeltaY, anchoredAt: convert(event.locationInWindow, from: nil))
        } else {
            controller.panViewport(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
        canvasView?.refreshCanvasDisplay()
        needsDisplay = true
    }

    fileprivate func synchronizeViewportToBounds() {
        controller.updateViewportCanvasSize(bounds.size)
    }

    private var canvasView: AnnotationCanvasView? {
        superview as? AnnotationCanvasView
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    private var imageBounds: CGRect {
        controller.capture.documentRect
    }

    private var documentProjection: DocumentProjection? {
        let canvasRect = controller.viewport.imageRect
        let documentBounds = imageBounds

        guard canvasRect.width > 0,
              canvasRect.height > 0,
              documentBounds.width > 0,
              documentBounds.height > 0 else {
            return nil
        }

        return DocumentProjection(sourceDocumentRect: documentBounds, destinationBounds: canvasRect)
    }

    private func documentPoint(from point: CGPoint) -> CGPoint? {
        let canvasRect = controller.viewport.imageRect

        guard canvasRect.contains(point) else {
            return nil
        }

        return documentPointUnclamped(from: point)
    }

    /// Converts a view point to document coordinates without requiring the point
    /// to be within the image bounds. Used for crop resize so dragging at or
    /// beyond the image edge still produces valid document coordinates (the
    /// caller is responsible for clamping the result).
    private func documentPointUnclamped(from point: CGPoint) -> CGPoint {
        documentProjection?.documentPoint(fromDestinationPoint: point) ?? imageBounds.origin
    }

    private func viewRect(for documentRect: CGRect, in canvasRect: CGRect) -> CGRect {
        guard let projection = documentProjection,
              projection.destinationBounds == canvasRect else {
            return CGRect(origin: .zero, size: .zero)
        }

        return projection.destinationRect(fromDocumentRect: documentRect)
    }

    private func viewPoint(for documentPoint: CGPoint, in canvasRect: CGRect) -> CGPoint {
        guard let projection = documentProjection,
              projection.destinationBounds == canvasRect else {
            return .zero
        }

        return projection.destinationPoint(fromDocumentPoint: documentPoint)
    }

    private func handleSelectMouseDown(_ point: CGPoint, viewPoint: CGPoint, with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let additive = modifiers.contains(.shift)
        let toggle = modifiers.contains(.command)

        if let selectionBounds = controller.selectionBoundingRect,
           let handle = selectionHandle(at: viewPoint) {
            interactionState.beginResize(annotations: controller.selectedAnnotations, originalBounds: selectionBounds, handle: handle)
            return
        }

        if let annotation = controller.snapshot.annotations.reversed().first(where: { $0.contains(point) }) {
            if additive || toggle {
                controller.select(annotation.id, additive: additive, toggle: toggle)
                needsDisplay = true
                return
            }

            if !controller.snapshot.selectedAnnotationIDs.contains(annotation.id) {
                controller.select(annotation.id)
            }

            if let selectionBounds = controller.selectionBoundingRect {
                interactionState.beginMove(annotations: controller.selectedAnnotations, anchor: point, originalBounds: selectionBounds)
            }
            needsDisplay = true
            return
        }

        let cropRect = controller.snapshot.cropRect.gscIntegralStandardized
        if cropRect.contains(point) {
            interactionState.beginCropMove(anchor: point, originalBounds: cropRect)
            cropHUDDocumentPoint = point
            needsDisplay = true
            return
        }

        if !additive && !toggle {
            controller.select(annotationIDs: [])
        }

        interactionState.beginMarquee(at: point, additive: additive || toggle)
        needsDisplay = true
    }

    private func handleUIMapInspectMouseDown(_ point: CGPoint) {
        controller.selectAndTogglePinnedUIMapElement(uiMapElement(at: point)?.id)
        needsDisplay = true
    }

    private func uiMapElement(at point: CGPoint) -> UIMapElement? {
        controller.uiMapSnapshot?.allElements
            .filter(\.isShowAllOverlayCandidate)
            .filter { $0.documentRect.contains(point) }
            .min { first, second in
                uiMapHitTestArea(first.documentRect) < uiMapHitTestArea(second.documentRect)
            }
    }

    private func uiMapHitTestArea(_ rect: CGRect) -> CGFloat {
        max(rect.width, 0) * max(rect.height, 0)
    }

    private func selectionHandleRect(for handle: ResizeHandle, bounds: CGRect) -> CGRect {
        let position = handle.position(in: bounds)
        return CGRect(x: position.x - 8, y: position.y - 8, width: 16, height: 16)
    }

    private func selectionHandle(at viewPoint: CGPoint) -> ResizeHandle? {
        guard let selectionBounds = controller.selectionBoundingRect else {
            return nil
        }

        let selectionRect = viewRect(for: selectionBounds, in: controller.viewport.imageRect)
        return ResizeHandle.allCases.first { handle in
            selectionHandleRect(for: handle, bounds: selectionRect).contains(viewPoint)
        }
    }

    private func cropHandleRect(for handle: ResizeHandle) -> CGRect {
        let cropRect = viewRect(for: controller.snapshot.cropRect.gscIntegralStandardized, in: controller.viewport.imageRect)
        let position = cropHandlePosition(for: handle, in: cropRect)
        return CGRect(x: position.x - 10, y: position.y - 10, width: 20, height: 20)
    }

    private func cropHandle(at viewPoint: CGPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first { handle in
            cropHandleRect(for: handle).contains(viewPoint)
        }
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: handle.frameResizeCursorPosition, directions: .all)
        }

        switch handle {
        case .top, .bottom:
            return .resizeUpDown
        case .left, .right:
            return .resizeLeftRight
        default:
            return .crosshair
        }
    }

    private func drawSelection(for annotations: [Annotation], in canvasRect: CGRect) {
        for annotation in annotations {
            let individualRect = viewRect(for: annotation.boundingRect, in: canvasRect)
            let outline = NSBezierPath(rect: individualRect)
            NSColor.selectedControlColor.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        }

        let bounds = gscBoundingRect(of: annotations.map(\.boundingRect))
        let rect = viewRect(for: bounds, in: canvasRect)
        let overallOutline = NSBezierPath(rect: rect)
        NSColor.selectedControlColor.setStroke()
        overallOutline.lineWidth = 2
        overallOutline.setLineDash([4, 4], count: 2, phase: 0)
        overallOutline.stroke()

        NSColor.selectedControlColor.setFill()
        for handle in ResizeHandle.allCases {
            let point = handle.position(in: rect)
            CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8).fill()
        }
    }

    private func drawCropMask(for rect: CGRect, overlayAlpha: CGFloat, inside imageRect: CGRect) {
        NSColor.black.withAlphaComponent(overlayAlpha).setFill()
        imageRect.fill(using: .sourceOver)
        NSColor.clear.setFill()
        rect.fill(using: .clear)
    }

    private func drawOutOfCapturePattern(excluding imageRect: CGRect) {
        OutOfCapturePatternRenderer.draw(
            bounds: bounds,
            excluding: imageRect,
            settings: controller.outOfCapturePatternSettings,
            appearance: effectiveAppearance
        )
    }

    var debugCommittedCropPresentation: CropFocusPresentationState? {
        let canvasRect = controller.viewport.imageRect
        guard canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        return CropFocusPresentationState(
            cropRect: committedCropRect(in: canvasRect),
            overlayAlpha: committedCropOverlayAlpha,
            showsFocusedCropChrome: showsFocusedCropChrome
        )
    }

    private var showsFocusedCropChrome: Bool {
        controller.snapshot.cropRect.gscIntegralStandardized != imageBounds
    }

    private var committedCropOverlayAlpha: CGFloat {
        showsFocusedCropChrome ? controller.cropOutsideOverlayAlpha : 0
    }

    private func committedCropRect(in canvasRect: CGRect) -> CGRect {
        viewRect(for: controller.snapshot.cropRect.gscIntegralStandardized, in: canvasRect).integral
    }

    private func drawCropOutlineAndHandles(for rect: CGRect, strokeColor: NSColor) {
        let path = NSBezierPath(rect: rect)
        strokeColor.setStroke()
        path.lineWidth = 2
        path.stroke()

        drawCropHandles(for: rect)
    }

    private func drawCropInteractionHUD(for draftCropRect: CGRect, in canvasRect: CGRect) {
        guard shouldShowCropInteractionHUD,
              let focusDocumentPoint = clampedCropHUDDocumentPoint(),
              draftCropRect.width > 1,
              draftCropRect.height > 1 else {
            return
        }

        let focusViewPoint = viewPoint(for: focusDocumentPoint, in: canvasRect)
        let dimensions = gscCropPixelDimensionText(for: draftCropRect)
        let attributes = cropDimensionTextAttributes()
        let dimensionSize = NSString(string: dimensions).size(withAttributes: attributes)
        let layout = gscCropInteractionHUDLayout(
            around: focusViewPoint,
            in: bounds,
            dimensionSize: CGSize(width: ceil(dimensionSize.width), height: ceil(dimensionSize.height))
        )

        drawCropLoupe(layout: layout, focusDocumentPoint: focusDocumentPoint)
        drawCropDimensionBadge(text: dimensions, in: layout.dimensionRect, attributes: attributes)
    }

    private var shouldShowCropInteractionHUD: Bool {
        switch interactionState.dragMode {
        case .cropping, .resizingCrop, .movingCrop:
            return true
        default:
            return false
        }
    }

    private func clampedCropHUDDocumentPoint() -> CGPoint? {
        guard let point = cropHUDDocumentPoint else {
            return nil
        }

        return CGPoint(
            x: min(max(point.x, imageBounds.minX), imageBounds.maxX),
            y: min(max(point.y, imageBounds.minY), imageBounds.maxY)
        )
    }

    private func drawCropLoupe(layout: CropInteractionHUDLayout, focusDocumentPoint: CGPoint) {
        let cropRect = gscCenteredCropRect(around: focusDocumentPoint, size: 24, within: imageBounds)

        guard let croppedImage = controller.capture.image.gscCropped(topLeftPixelRect: cropRect) else {
            return
        }

        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: layout.loupeRect, xRadius: 16, yRadius: 16).fill()

        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: croppedImage, size: cropRect.size).draw(
            in: layout.loupeImageRect,
            from: CGRect(origin: .zero, size: cropRect.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.current?.imageInterpolation = previousInterpolation ?? .default

        NSColor.white.setStroke()
        let border = NSBezierPath(roundedRect: layout.loupeRect, xRadius: 16, yRadius: 16)
        border.lineWidth = 2
        border.stroke()

        let relativeFocusX = (focusDocumentPoint.x - cropRect.minX) / max(cropRect.width, 1)
        let relativeFocusY = (focusDocumentPoint.y - cropRect.minY) / max(cropRect.height, 1)
        let crosshairCenter = CGPoint(
            x: layout.loupeImageRect.minX + relativeFocusX * layout.loupeImageRect.width,
            y: layout.loupeImageRect.minY + relativeFocusY * layout.loupeImageRect.height
        )
        let crosshair = NSBezierPath()
        crosshair.move(to: CGPoint(x: crosshairCenter.x - 14, y: crosshairCenter.y))
        crosshair.line(to: CGPoint(x: crosshairCenter.x + 14, y: crosshairCenter.y))
        crosshair.move(to: CGPoint(x: crosshairCenter.x, y: crosshairCenter.y - 14))
        crosshair.line(to: CGPoint(x: crosshairCenter.x, y: crosshairCenter.y + 14))
        crosshair.lineWidth = 1.5
        crosshair.stroke()
    }

    private func drawCropDimensionBadge(text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        border.lineWidth = 1
        border.stroke()

        let textSize = NSString(string: text).size(withAttributes: attributes)
        let textRect = CGRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        NSString(string: text).draw(in: textRect, withAttributes: attributes)
    }

    private func cropDimensionTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
    }

    private func drawCropHandles(for rect: CGRect) {
        for handle in ResizeHandle.allCases {
            let point = cropHandlePosition(for: handle, in: rect)
            let diameter: CGFloat = handle.isCorner ? 10 : 8
            let handleRect = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            let path = NSBezierPath(ovalIn: handleRect)
            NSColor.systemGreen.setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.82).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func cropHandlePosition(for handle: ResizeHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .top:
            return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:
            return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:
            return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:
            return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:
            return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func drawMarqueeSelection(_ marqueeRect: CGRect, in canvasRect: CGRect) {
        let rect = viewRect(for: marqueeRect, in: canvasRect)
        NSColor.selectedControlColor.withAlphaComponent(0.12).setFill()
        rect.fill()

        let outline = NSBezierPath(rect: rect)
        NSColor.selectedControlColor.setStroke()
        outline.lineWidth = 1.5
        outline.setLineDash([5, 3], count: 2, phase: 0)
        outline.stroke()
    }

    private func drawSnapGuides(_ guides: [SnapGuide], in canvasRect: CGRect) {
        guard let projection = documentProjection,
              projection.destinationBounds == canvasRect else {
            return
        }

        for guide in guides {
            let path = NSBezierPath()
            NSColor.systemOrange.setStroke()
            path.lineWidth = 1.5
            path.setLineDash([6, 4], count: 2, phase: 0)

            switch guide.orientation {
            case .vertical:
                let x = projection.destinationPoint(
                    fromDocumentPoint: CGPoint(x: guide.position, y: projection.sourceDocumentRect.minY)
                ).x
                path.move(to: CGPoint(x: x, y: canvasRect.minY))
                path.line(to: CGPoint(x: x, y: canvasRect.maxY))
            case .horizontal:
                let y = projection.destinationPoint(
                    fromDocumentPoint: CGPoint(x: projection.sourceDocumentRect.minX, y: guide.position)
                ).y
                path.move(to: CGPoint(x: canvasRect.minX, y: y))
                path.line(to: CGPoint(x: canvasRect.maxX, y: y))
            }

            path.stroke()
        }
    }

    private func apply(
        _ commit: AnnotationCanvasInteractionState.Commit,
        activeDragMode: AnnotationCanvasInteractionState.DragMode? = nil,
        finalDraftCropRect: CGRect? = nil
    ) {
        let committedCrop: Bool

        if case .crop = commit {
            committedCrop = true
        } else {
            committedCrop = false
        }

        switch commit {
        case .none:
            break
        case let .add(annotation):
            controller.addAnnotation(annotation)
        case let .update(annotations):
            controller.updateAnnotations(annotations)
        case let .select(ids, additive):
            controller.select(annotationIDs: ids, additive: additive)
        case .clearSelection:
            controller.select(annotationIDs: [])
        case let .crop(rect):
            if case let .resizingCrop(originalBounds, _) = activeDragMode {
                controller.commitPreviewedCropRect(rect, originalRect: originalBounds)
                canvasView?.refreshCanvasDisplay()
            } else if case let .movingCrop(_, originalBounds) = activeDragMode {
                controller.commitPreviewedCropRect(rect, originalRect: originalBounds)
                canvasView?.refreshCanvasDisplay()
            } else {
                controller.execute(SetCropCommand(rect: rect))
            }
        case let .ocr(rect):
            controller.recognizeText(in: rect)
        }

        if !committedCrop {
            if case let .resizingCrop(originalBounds, _) = activeDragMode {
                controller.commitPreviewedCropRect(finalDraftCropRect ?? originalBounds, originalRect: originalBounds)
            } else if case let .movingCrop(_, originalBounds) = activeDragMode {
                controller.commitPreviewedCropRect(finalDraftCropRect ?? originalBounds, originalRect: originalBounds)
            }
        }
    }

    private func handleTextEntryKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else {
            return false
        }

        let selected = controller.selectedAnnotation

        switch event.keyCode {
        case 36, 76:
            if selected?.isTextEditable == true {
                controller.insertLineBreakInTextSelection()
                return true
            }
        case 51, 117:
            if selected?.isTextEditable == true {
                controller.deleteBackwardInTextSelection()
                return true
            }
        default:
            break
        }

        guard let characters = event.characters, !characters.isEmpty else {
            return true
        }

        let printable = characters.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(printable))

        guard !text.isEmpty else {
            return true
        }

        if selected?.isTextEditable == true {
            controller.applyTextInput(text)
        } else if !controller.selectedAnnotations.isEmpty || controller.canBeginTextAnnotationFromUIMapSelection {
            controller.beginTextAnnotation(with: text)
        } else {
            return false
        }

        return true
    }
}
