import AppKit
import Combine
import SwiftUI

#if DEBUG
struct AnnotationTextEditorOverlayDebugState {
    var overlayFrame: CGRect
    var textViewFrame: CGRect
    var usedTextRect: CGRect
    var text: String
    var lineFragmentCount: Int
    var displayScale: CGFloat
    var textInsetX: CGFloat
    var textInsetY: CGFloat
}
#endif

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

private final class AnnotationCanvasCropMaskView: NSView {
    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            lastSignature = nil
            draftCropRect = nil
            needsDisplay = true
        }
    }

    private struct Signature: Equatable {
        let cropRect: CGRect
        let canvasRect: CGRect
        let imageBounds: CGRect
        let overlayAlpha: CGFloat
        let isDraft: Bool
        let boundsSize: CGSize
    }

    private var draftCropRect: CGRect?
    private var lastSignature: Signature?

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateDraftCropRect(_ rect: CGRect?) {
        guard draftCropRect != rect else {
            return
        }

        draftCropRect = rect
        invalidateIfNeeded(force: true)
    }

    func controllerDidChange() {
        invalidateIfNeeded()
    }

    func refreshAfterLayout() {
        invalidateIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let signature = currentSignature(),
              signature.overlayAlpha > 0,
              signature.cropRect.gscIntegralStandardized != signature.imageBounds.gscIntegralStandardized else {
            return
        }

        NSColor.black.withAlphaComponent(signature.overlayAlpha).setFill()
        signature.canvasRect.fill(using: .sourceOver)
        NSColor.clear.setFill()
        viewRect(for: signature.cropRect, in: signature.canvasRect).fill(using: .clear)
    }

    private func invalidateIfNeeded(force: Bool = false) {
        guard let signature = currentSignature() else {
            lastSignature = nil
            if force {
                needsDisplay = true
            }
            return
        }

        guard force || signature != lastSignature else {
            return
        }

        lastSignature = signature
        needsDisplay = true
    }

    private func currentSignature() -> Signature? {
        let canvasRect = controller.viewport.imageRect
        let imageBounds = controller.capture.documentRect

        guard canvasRect.width > 0,
              canvasRect.height > 0,
              imageBounds.width > 0,
              imageBounds.height > 0 else {
            return nil
        }

        let isDraft = draftCropRect != nil
        let cropRect = (draftCropRect ?? controller.snapshot.cropRect).gscIntegralStandardized
        let overlayAlpha = isDraft
            ? 0.18
            : (cropRect == imageBounds.gscIntegralStandardized ? 0 : controller.cropOutsideOverlayAlpha)

        return Signature(
            cropRect: cropRect,
            canvasRect: canvasRect,
            imageBounds: imageBounds,
            overlayAlpha: overlayAlpha,
            isDraft: isDraft,
            boundsSize: bounds.size
        )
    }

    private func viewRect(for documentRect: CGRect, in canvasRect: CGRect) -> CGRect {
        DocumentProjection(
            sourceDocumentRect: controller.capture.documentRect,
            destinationBounds: canvasRect
        )
        .destinationRect(fromDocumentRect: documentRect)
    }
}

private final class AnnotationCanvasStableContentView: NSView {
    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            lastSignature = nil
            needsDisplay = true
        }
    }

    private struct Signature: Equatable {
        let baseImageID: ObjectIdentifier
        let annotations: [Annotation]
        let pinnedUIMapElements: [UIMapElement]
        let uiMapOverlayOptions: UIMapOverlayOptions
        let outOfCapturePatternSettings: EditorOutOfCapturePatternSettings
        let canvasRect: CGRect
        let boundsSize: CGSize
        let appearanceName: NSAppearance.Name?
    }

    private var lastSignature: Signature?
    fileprivate private(set) var debugInvalidationCount = 0

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func controllerDidChange() {
        invalidateIfNeeded()
    }

    func refreshAfterLayout() {
        invalidateIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let canvasRect = controller.viewport.imageRect
        guard canvasRect.width > 0, canvasRect.height > 0 else {
            return
        }

        OutOfCapturePatternRenderer.draw(
            bounds: bounds,
            excluding: canvasRect,
            settings: controller.outOfCapturePatternSettings,
            appearance: effectiveAppearance
        )

        EditorRenderer.drawAnnotations(
            baseImage: controller.capture.image,
            snapshot: snapshotForStableRendering,
            canvasRect: canvasRect,
            draftAnnotations: [],
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions
        )
    }

    private func invalidateIfNeeded() {
        guard let signature = currentSignature() else {
            lastSignature = nil
            return
        }

        guard signature != lastSignature else {
            return
        }

        lastSignature = signature
        debugInvalidationCount += 1
        needsDisplay = true
    }

    private func currentSignature() -> Signature? {
        let canvasRect = controller.viewport.imageRect
        guard canvasRect.width > 0, canvasRect.height > 0 else {
            return nil
        }

        return Signature(
            baseImageID: ObjectIdentifier(controller.capture.image as AnyObject),
            annotations: controller.snapshot.annotations,
            pinnedUIMapElements: controller.pinnedUIMapElements,
            uiMapOverlayOptions: controller.uiMapOverlayOptions,
            outOfCapturePatternSettings: controller.outOfCapturePatternSettings,
            canvasRect: canvasRect,
            boundsSize: bounds.size,
            appearanceName: effectiveAppearance.name
        )
    }

    private var snapshotForStableRendering: EditorSnapshot {
        guard let annotation = controller.selectedAnnotation,
              controller.selectedAnnotations.count == 1,
              annotation.rotationDegrees == 0,
              case .text = annotation.kind else {
            return controller.snapshot
        }

        var snapshot = controller.snapshot
        snapshot.annotations.removeAll { $0.id == annotation.id }
        return snapshot
    }
}

private final class AnnotationTextEditorOverlayView: NSView, NSTextViewDelegate {
    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            editingAnnotationID = nil
            synchronize()
        }
    }

    private let textView = NSTextView(frame: .zero)
    private var editingAnnotationID: UUID?
    private var isSynchronizing = false

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.maximumNumberOfLines = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        addSubview(textView)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func layout() {
        super.layout()
        textView.frame = bounds.insetBy(dx: textInsetX, dy: textInsetY)
        if let annotation = editableTextAnnotation,
           case let .text(shape) = annotation.kind {
            configureTextContainer(for: shape)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let annotation = editableTextAnnotation else {
            return
        }

        annotation.style.fillColor.nsColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    func synchronize() {
        guard let annotation = editableTextAnnotation,
              case let .text(shape) = annotation.kind,
              let projectedRect = projectedTextRect(for: shape.rect)
        else {
            endEditingIfNeeded()
            return
        }

        let didChangeAnnotation = editingAnnotationID != annotation.id
        editingAnnotationID = annotation.id
        isHidden = false
        frame = projectedRect.integral
        layer?.cornerRadius = cornerRadius
        configureTextView(for: annotation, shape: shape)
        fitFrameToText(shape.text, annotation: annotation, shape: shape)
        needsDisplay = true

        if didChangeAnnotation, window?.firstResponder !== textView {
            window?.makeFirstResponder(textView)
            if shape.text == "Text" {
                textView.setSelectedRange(NSRange(location: 0, length: (shape.text as NSString).length))
            } else {
                textView.setSelectedRange(NSRange(location: (shape.text as NSString).length, length: 0))
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isSynchronizing,
              editingAnnotationID != nil,
              controller.selectedAnnotation?.id == editingAnnotationID else {
            return
        }

        guard let annotation = editableTextAnnotation,
              case let .text(shape) = annotation.kind else {
            return
        }

        fitFrameToText(textView.string, annotation: annotation, shape: shape)
        controller.updateText(textView.string)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isSynchronizing,
              let annotation = editableTextAnnotation,
              case let .text(shape) = annotation.kind,
              let replacementString else {
            return true
        }

        let currentText = textView.string as NSString
        guard affectedCharRange.location <= currentText.length,
              affectedCharRange.location + affectedCharRange.length <= currentText.length else {
            return true
        }

        let proposedText = currentText.replacingCharacters(in: affectedCharRange, with: replacementString)
        fitFrameToText(proposedText, annotation: annotation, shape: shape)
        return true
    }

    private var editableTextAnnotation: Annotation? {
        guard let annotation = controller.selectedAnnotation,
              controller.selectedAnnotations.count == 1,
              annotation.rotationDegrees == 0,
              case .text = annotation.kind else {
            return nil
        }

        return annotation
    }

    private func projectedTextRect(for documentRect: CGRect) -> CGRect? {
        let canvasRect = controller.viewport.imageRect
        let documentBounds = controller.capture.documentRect

        guard canvasRect.width > 0,
              canvasRect.height > 0,
              documentBounds.width > 0,
              documentBounds.height > 0 else {
            return nil
        }

        return DocumentProjection(
            sourceDocumentRect: documentBounds,
            destinationBounds: canvasRect
        )
        .destinationRect(fromDocumentRect: documentRect)
    }

    private func configureTextView(for annotation: Annotation, shape: TextShape) {
        let selectedRange = textView.selectedRange()
        let attributes = textAttributes(for: annotation, shape: shape)

        isSynchronizing = true
        defer {
            isSynchronizing = false
        }

        if textView.string != shape.text {
            textView.textStorage?.setAttributedString(NSAttributedString(string: shape.text, attributes: attributes))
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (shape.text as NSString).length),
                length: min(selectedRange.length, max((shape.text as NSString).length - min(selectedRange.location, (shape.text as NSString).length), 0))
            ))
        } else {
            textView.textStorage?.setAttributes(
                attributes,
                range: NSRange(location: 0, length: (shape.text as NSString).length)
            )
        }

        textView.typingAttributes = attributes
        textView.alignment = shape.alignment.nsTextAlignment
        configureTextContainer(for: shape)
        needsLayout = true
    }

    private func fitFrameToText(_ text: String, annotation: Annotation, shape: TextShape) {
        let fittedRect = fittedTextRect(for: text, annotation: annotation, shape: shape)
        guard let projectedRect = projectedTextRect(for: fittedRect) else {
            return
        }

        frame = projectedRect.integral
        textView.frame = bounds.insetBy(dx: textInsetX, dy: textInsetY)
        configureTextContainer(for: shape)
        growFrameToFitLiveText(text, attributes: textAttributes(for: annotation, shape: shape), shape: shape)
        needsDisplay = true
    }

    private func fittedTextRect(for text: String, annotation: Annotation, shape: TextShape) -> CGRect {
        let font = NSFont.systemFont(ofSize: annotation.style.fontSize, weight: .semibold)

        if shape.automaticallySizesToText {
            return gscSnugTextRect(
                for: text,
                origin: shape.rect.origin,
                font: font,
                horizontalPadding: 24,
                verticalPadding: 20,
                minSize: CGSize(width: 44, height: 34),
                maxWidth: 520
            )
        }

        return gscFittedTextRect(
            for: text,
            currentRect: shape.rect,
            font: font,
            horizontalPadding: 24,
            verticalPadding: 20,
            minSize: shape.rect.size,
            maxWidth: 520
        )
    }

    private func textAttributes(for annotation: Annotation, shape: TextShape) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = shape.alignment.nsTextAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: NSFont.systemFont(ofSize: annotation.style.fontSize * displayScale, weight: .semibold),
            .foregroundColor: annotation.style.strokeColor.nsColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func growFrameToFitLiveText(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        shape: TextShape
    ) {
        let contentWidth = max(textView.bounds.width, 1)
        let requiredContentHeight = measuredTextHeight(
            for: text,
            width: contentWidth,
            attributes: attributes
        )
        let requiredHeight = ceil(requiredContentHeight + textInsetY * 2 + liveTextVerticalSlack)

        guard requiredHeight > bounds.height else {
            layoutLiveTextIfNeeded()
            return
        }

        frame.size.height = requiredHeight
        textView.frame = bounds.insetBy(dx: textInsetX, dy: textInsetY)
        configureTextContainer(for: shape)
        layoutLiveTextIfNeeded()
    }

    private func measuredTextHeight(
        for text: String,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let textStorage = NSTextStorage(string: measurementText(for: text), attributes: attributes)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    private func measurementText(for text: String) -> String {
        guard !text.isEmpty else {
            return " "
        }

        return text.hasSuffix("\n") || text.hasSuffix("\r") ? text + " " : text
    }

    private func layoutLiveTextIfNeeded() {
        guard let textContainer = textView.textContainer else {
            return
        }

        textView.layoutManager?.ensureLayout(for: textContainer)
    }

    private func configureTextContainer(for _: TextShape) {
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: max(textView.bounds.width, 1),
            height: .greatestFiniteMagnitude
        )
    }

    #if DEBUG
    func debugInsertText(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    var debugState: AnnotationTextEditorOverlayDebugState? {
        guard !isHidden,
              let textContainer = textView.textContainer else {
            return nil
        }

        textView.layoutManager?.ensureLayout(for: textContainer)
        let glyphRange = textView.layoutManager?.glyphRange(for: textContainer) ?? NSRange(location: 0, length: 0)
        var lineFragmentCount = 0
        textView.layoutManager?.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineFragmentCount += 1
        }

        return AnnotationTextEditorOverlayDebugState(
            overlayFrame: frame,
            textViewFrame: textView.frame,
            usedTextRect: textView.layoutManager?.usedRect(for: textContainer) ?? .zero,
            text: textView.string,
            lineFragmentCount: max(lineFragmentCount, 1),
            displayScale: displayScale,
            textInsetX: textInsetX,
            textInsetY: textInsetY
        )
    }
    #endif

    private func endEditingIfNeeded() {
        if window?.firstResponder === textView {
            window?.makeFirstResponder(superview)
        }

        editingAnnotationID = nil
        isHidden = true
    }

    private var displayScale: CGFloat {
        let documentBounds = controller.capture.documentRect
        let canvasRect = controller.viewport.imageRect

        guard documentBounds.width > 0, documentBounds.height > 0 else {
            return 1
        }

        return max(min(canvasRect.width / documentBounds.width, canvasRect.height / documentBounds.height), .leastNonzeroMagnitude)
    }

    private var textInsetX: CGFloat {
        12 * displayScale
    }

    private var textInsetY: CGFloat {
        10 * displayScale
    }

    private var liveTextVerticalSlack: CGFloat {
        max(ceil(4 * displayScale), 1)
    }

    private var cornerRadius: CGFloat {
        12 * displayScale
    }
}

final class AnnotationCanvasView: NSView {
    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            displayedBaseImageCrop = nil
            cropMaskView.controller = controller
            stableContentView.controller = controller
            overlayView.controller = controller
            textEditorOverlayView.controller = controller
            bindController()
        }
    }

    private let baseImageView = AnnotationCanvasBaseImageView()
    private lazy var cropMaskView = AnnotationCanvasCropMaskView(controller: controller)
    private lazy var stableContentView = AnnotationCanvasStableContentView(controller: controller)
    private lazy var overlayView = AnnotationCanvasOverlayView(controller: controller)
    private lazy var textEditorOverlayView = AnnotationTextEditorOverlayView(controller: controller)
    private var controllerChangeObserver: AnyCancellable?
    private var displayedBaseImageCrop: CGRect?

    init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        addSubview(baseImageView)
        addSubview(cropMaskView)
        addSubview(stableContentView)
        addSubview(overlayView)
        addSubview(textEditorOverlayView)
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
        cropMaskView.frame = bounds
        stableContentView.frame = bounds
        overlayView.frame = bounds
        textEditorOverlayView.synchronize()
        synchronizeBaseImagePresentation()
        cropMaskView.refreshAfterLayout()
        stableContentView.refreshAfterLayout()
        overlayView.refreshAfterLayout()
    }

    func refreshCanvasDisplay() {
        synchronizeBaseImagePresentation()
        cropMaskView.controllerDidChange()
        stableContentView.controllerDidChange()
        overlayView.needsDisplay = true
        textEditorOverlayView.synchronize()
    }

    var debugCommittedCropPresentation: CropFocusPresentationState? {
        overlayView.debugCommittedCropPresentation
    }

    var debugStableContentInvalidationCount: Int {
        stableContentView.debugInvalidationCount
    }

    #if DEBUG
    var debugTextEditorOverlayState: AnnotationTextEditorOverlayDebugState? {
        textEditorOverlayView.debugState
    }

    func debugInsertTextIntoTextEditorOverlay(_ text: String) {
        textEditorOverlayView.debugInsertText(text)
    }
    #endif

    private func bindController() {
        controllerChangeObserver = controller.$canvasRevision.sink { [weak self] _ in
            guard let self else {
                return
            }

            let invalidationReason = self.controller.canvasInvalidationReason
            self.synchronizeBaseImagePresentation()
            self.cropMaskView.controllerDidChange()
            if invalidationReason.invalidatesStableContent {
                self.stableContentView.controllerDidChange()
            }
            self.overlayView.controllerDidChange()
            self.textEditorOverlayView.synchronize()
        }

        synchronizeBaseImagePresentation()
        cropMaskView.controllerDidChange()
        stableContentView.controllerDidChange()
        overlayView.controllerDidChange()
        textEditorOverlayView.synchronize()
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

    fileprivate func updateDraftCropMask(_ rect: CGRect?) {
        cropMaskView.updateDraftCropRect(rect)
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

    var controller: EditorController {
        didSet {
            guard controller !== oldValue else {
                return
            }

            invalidateUIMapOverlayElementCache()
            lastHoveredUIMapElementID = controller.hoveredUIMapElementID
            needsDisplay = true
        }
    }

    private var interactionState = AnnotationCanvasInteractionState()
    private var cropHUDDocumentPoint: CGPoint?
    private var pointerTrackingArea: NSTrackingArea?
    private var uiMapOverlayElementCache: UIMapOverlayElementCache?
    private var lastHoveredUIMapElementID: UUID?

    private struct UIMapOverlayElementCache {
        let allElements: [UIMapElement]
        let showAllElements: [UIMapElement]
        let hitTestElements: [UIMapElement]
        let elementsByID: [UUID: UIMapElement]
    }

    init(controller: EditorController) {
        self.controller = controller
        self.lastHoveredUIMapElementID = controller.hoveredUIMapElementID
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

        if controller.activeTool == .uiMapInspect {
            let canvasRect = controller.viewport.imageRect
            for element in uiMapOverlayElements().showAllElements {
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

        drawDraftAnnotations(in: canvasRect)

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
        switch controller.canvasInvalidationReason {
        case .uiMapHover:
            invalidateUIMapHoverChange(
                from: lastHoveredUIMapElementID,
                to: controller.hoveredUIMapElementID
            )
            lastHoveredUIMapElementID = controller.hoveredUIMapElementID
        case .uiMapOverlay:
            invalidateCursorRects()
            needsDisplay = true
            lastHoveredUIMapElementID = controller.hoveredUIMapElementID
        default:
            invalidateUIMapOverlayElementCache()
            invalidateCursorRects()
            needsDisplay = true
            lastHoveredUIMapElementID = controller.hoveredUIMapElementID
        }
    }

    func refreshAfterLayout() {
        invalidateCursorRects()
        needsDisplay = true
    }

    private func drawSelectedUIMapElement(in canvasRect: CGRect) {
        let uiMapElements = uiMapOverlayElements()

        if controller.showsAllUIMapElements {
            for element in uiMapElements.allElements {
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
           let hoveredElement = uiMapElements.elementsByID[hoveredElementID] {
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

        let color = uiMapOverlayColor(for: element, options: options)

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

        guard !controller.isUIMapElementPinned(element.id) else {
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

    private func uiMapOverlayColor(for element: UIMapElement, options: UIMapOverlayOptions) -> NSColor {
        if let outlineColor = options.outlineColor {
            return outlineColor.nsColor
        }

        return element.isRecognizedTextSupplement ? NSColor.systemOrange : NSColor.systemBlue
    }

    private func uiMapOverlayLabelSegments(for element: UIMapElement, options: UIMapOverlayOptions) -> [String] {
        var segments: [String] = []

        if options.showsSource {
            segments.append(element.isRecognizedTextSupplement ? "OCR supplement text" : "Accessibility element")
        }

        if options.showsLabel {
            if let name = element.name {
                segments.append(name)
            } else {
                segments.append(element.displayName)
            }
        }

        if options.showsAccessibilityLabel,
           let accessibilityLabel = element.accessibilityLabel,
           accessibilityLabel != element.name {
            segments.append(accessibilityLabel)
        }

        if options.showsIdentifier, let identifier = element.accessibilityIdentifier {
            segments.append("#\(identifier)")
        }

        if options.showsRole {
            segments.append(element.typeLabel)
        }

        if options.showsValue, let value = element.valueDescription {
            segments.append(value)
        }

        if options.showsCoordinates {
            segments.append("x \(Int(element.documentRect.minX)), y \(Int(element.documentRect.minY))")
        }

        if options.showsDimensions {
            segments.append("\(Int(element.documentRect.width)) x \(Int(element.documentRect.height))")
        }

        if options.showsOwningApplication, let owningApplication = element.owningApplication {
            segments.append(owningApplication)
        }

        if options.showsBundleIdentifier, let bundleIdentifier = element.bundleIdentifier {
            segments.append(bundleIdentifier)
        }

        if options.showsParentHierarchy {
            let hierarchy = controller.uiMapSnapshot?.parentHierarchy(for: element.id)
                .map(\.displayName)
                .joined(separator: " > ")
            if let hierarchy, !hierarchy.isEmpty {
                segments.append(hierarchy)
            }
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
            canvasView?.updateDraftCropMask(interactionState.draftCropRect)
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
            canvasView?.updateDraftCropMask(interactionState.draftCropRect)
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
            canvasView?.updateDraftCropMask(interactionState.draftCropRect)
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

        canvasView?.updateDraftCropMask(interactionState.draftCropRect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let activeDragMode = interactionState.dragMode
        let finalDraftCropRect = interactionState.draftCropRect

        defer {
            interactionState.reset()
            cropHUDDocumentPoint = nil
            canvasView?.updateDraftCropMask(nil)
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
        if !additive && !toggle {
            controller.clearSelection()
        }

        if cropRect.contains(point) {
            interactionState.beginCropMove(anchor: point, originalBounds: cropRect)
            cropHUDDocumentPoint = point
            canvasView?.updateDraftCropMask(interactionState.draftCropRect)
            needsDisplay = true
            return
        }

        interactionState.beginMarquee(at: point, additive: additive || toggle)
        needsDisplay = true
    }

    private func handleUIMapInspectMouseDown(_ point: CGPoint) {
        controller.selectAndTogglePinnedUIMapElement(uiMapElement(at: point)?.id)
        needsDisplay = true
    }

    private func uiMapElement(at point: CGPoint) -> UIMapElement? {
        uiMapOverlayElements().hitTestElements.first { $0.documentRect.contains(point) }
    }

    private func uiMapOverlayElements() -> UIMapOverlayElementCache {
        if let uiMapOverlayElementCache {
            return uiMapOverlayElementCache
        }

        guard let uiMap = controller.uiMapSnapshot else {
            let empty = UIMapOverlayElementCache(
                allElements: [],
                showAllElements: [],
                hitTestElements: [],
                elementsByID: [:]
            )
            uiMapOverlayElementCache = empty
            return empty
        }

        let allElements = uiMap.allElements
        let showAllElements = allElements.filter(\.isShowAllOverlayCandidate)
        let hitTestElements = showAllElements
            .enumerated()
            .sorted { first, second in
                let firstArea = uiMapHitTestArea(first.element.documentRect)
                let secondArea = uiMapHitTestArea(second.element.documentRect)

                if firstArea == secondArea {
                    return first.offset < second.offset
                }

                return firstArea < secondArea
            }
            .map(\.element)

        let cache = UIMapOverlayElementCache(
            allElements: allElements,
            showAllElements: showAllElements,
            hitTestElements: hitTestElements,
            elementsByID: Dictionary(uniqueKeysWithValues: allElements.map { ($0.id, $0) })
        )
        uiMapOverlayElementCache = cache
        return cache
    }

    private func invalidateUIMapOverlayElementCache() {
        uiMapOverlayElementCache = nil
    }

    private func invalidateUIMapHoverChange(from oldID: UUID?, to newID: UUID?) {
        guard oldID != newID else {
            return
        }

        let elementsByID = uiMapOverlayElements().elementsByID
        var invalidatedAnyRect = false
        for elementID in [oldID, newID].compactMap({ $0 }) {
            guard let element = elementsByID[elementID] else {
                continue
            }

            setNeedsDisplay(uiMapOverlayDirtyRect(for: element))
            invalidatedAnyRect = true
        }

        if !invalidatedAnyRect {
            needsDisplay = true
        }
    }

    private func uiMapOverlayDirtyRect(for element: UIMapElement) -> CGRect {
        viewRect(for: element.documentRect, in: controller.viewport.imageRect)
            .insetBy(dx: -8, dy: -8)
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

    private func drawDraftAnnotations(in canvasRect: CGRect) {
        guard !interactionState.draftAnnotations.isEmpty else {
            return
        }

        var draftOnlySnapshot = controller.snapshot
        draftOnlySnapshot.annotations = []
        draftOnlySnapshot.pinnedUIMapElementIDs = []

        EditorRenderer.drawAnnotations(
            baseImage: controller.capture.image,
            snapshot: draftOnlySnapshot,
            canvasRect: canvasRect,
            draftAnnotations: interactionState.draftAnnotations
        )
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

        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: layout.loupeRect, xRadius: 16, yRadius: 16).fill()

        let previousInterpolation = NSGraphicsContext.current?.imageInterpolation
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: controller.capture.image, size: imageBounds.size).draw(
            in: layout.loupeImageRect,
            from: appKitSourceRect(fromTopLeftRect: cropRect, imageBounds: imageBounds),
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

    private func appKitSourceRect(fromTopLeftRect rect: CGRect, imageBounds: CGRect) -> CGRect {
        let normalized = rect.gscIntegralStandardized
        return CGRect(
            x: normalized.minX,
            y: imageBounds.height - normalized.maxY,
            width: normalized.width,
            height: normalized.height
        ).gscIntegralStandardized
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
            controller.clearSelection()
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
