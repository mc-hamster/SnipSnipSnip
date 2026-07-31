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
    private enum EditableTextContext {
        case text(annotation: Annotation, shape: TextShape)
        case callout(annotation: Annotation, shape: CalloutShape)

        init?(annotation: Annotation) {
            switch annotation.kind {
            case let .text(shape):
                self = .text(annotation: annotation, shape: shape)
            case let .callout(shape):
                self = .callout(annotation: annotation, shape: shape)
            default:
                return nil
            }
        }

        var annotation: Annotation {
            switch self {
            case let .text(annotation, _):
                return annotation
            case let .callout(annotation, _):
                return annotation
            }
        }

        var documentRect: CGRect {
            switch self {
            case let .text(_, shape):
                return shape.rect
            case let .callout(_, shape):
                return shape.rect
            }
        }

        var text: String {
            switch self {
            case let .text(_, shape):
                return shape.text
            case let .callout(_, shape):
                return shape.text
            }
        }

        var alignment: TextAlignmentMode {
            switch self {
            case let .text(_, shape):
                return shape.alignment
            case let .callout(_, shape):
                return shape.alignment
            }
        }

        var automaticallySizesToText: Bool {
            switch self {
            case let .text(_, shape):
                return shape.automaticallySizesToText
            case let .callout(_, shape):
                return shape.automaticallySizesToText
            }
        }

        var placeholderText: String {
            switch self {
            case .text:
                return "Text"
            case let .callout(_, shape):
                return "Callout \(shape.number)"
            }
        }

        var isPlainText: Bool {
            if case .text = self {
                return true
            }

            return false
        }
    }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A selected text annotation is drawn by this live editor overlay. When
        // Select is active, let the canvas receive the gesture so the annotation
        // can be moved or resized instead of NSTextView consuming the drag.
        controller.activeTool == .select ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        if let context = editableTextContext {
            textView.frame = textViewFrame(in: bounds, context: context)
            configureTextContainer()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let annotation = editableTextAnnotation else {
            return
        }

        switch annotation.kind {
        case .text:
            annotation.style.fillColor.nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        case let .callout(shape):
            drawCalloutBackground(shape, annotation: annotation)
        default:
            break
        }
    }

    func synchronize() {
        guard let context = editableTextContext,
              let projectedRect = projectedTextRect(for: context.documentRect)
        else {
            endEditingIfNeeded()
            return
        }

        let annotation = context.annotation
        let didChangeAnnotation = editingAnnotationID != annotation.id
        editingAnnotationID = annotation.id
        isHidden = false
        frame = projectedRect.integral
        layer?.cornerRadius = context.isPlainText ? cornerRadius : 0
        configureTextView(for: context)
        fitFrameToText(context.text, context: context)
        needsDisplay = true

        if didChangeAnnotation, window?.firstResponder !== textView {
            window?.makeFirstResponder(textView)
            if context.text == context.placeholderText {
                textView.setSelectedRange(NSRange(location: 0, length: (context.text as NSString).length))
            } else {
                textView.setSelectedRange(NSRange(location: (context.text as NSString).length, length: 0))
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isSynchronizing,
              editingAnnotationID != nil,
              controller.selectedAnnotation?.id == editingAnnotationID else {
            return
        }

        guard let context = editableTextContext else {
            return
        }

        applyLiveTextAttributes(for: context)
        fitFrameToText(textView.string, context: context)
        controller.updateText(textView.string)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isSynchronizing,
              let context = editableTextContext,
              let replacementString else {
            return true
        }

        let currentText = textView.string as NSString
        guard affectedCharRange.location <= currentText.length,
              affectedCharRange.location + affectedCharRange.length <= currentText.length else {
            return true
        }

        let proposedText = currentText.replacingCharacters(in: affectedCharRange, with: replacementString)
        applyLiveTextAttributes(for: context)
        fitFrameToText(proposedText, context: context)
        return true
    }

    private var editableTextContext: EditableTextContext? {
        guard let annotation = controller.selectedAnnotation,
              controller.selectedAnnotations.count == 1,
              annotation.rotationDegrees == 0,
              let context = EditableTextContext(annotation: annotation) else {
            return nil
        }

        return context
    }

    private var editableTextAnnotation: Annotation? {
        editableTextContext?.annotation
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

    private func configureTextView(for context: EditableTextContext) {
        let selectedRange = textView.selectedRange()
        let attributes = textAttributes(for: context)
        let text = context.text

        isSynchronizing = true
        defer {
            isSynchronizing = false
        }

        if textView.string != text {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, (text as NSString).length),
                length: min(selectedRange.length, max((text as NSString).length - min(selectedRange.location, (text as NSString).length), 0))
            ))
        } else {
            textView.textStorage?.setAttributes(
                attributes,
                range: NSRange(location: 0, length: (text as NSString).length)
            )
        }

        textView.typingAttributes = attributes
        textView.font = attributes[.font] as? NSFont
        textView.alignment = context.alignment.nsTextAlignment
        textView.frame = textViewFrame(in: bounds, context: context)
        configureTextContainer()
        needsLayout = true
    }

    private func applyLiveTextAttributes(for context: EditableTextContext) {
        let attributes = textAttributes(for: context)
        let selectedRange = textView.selectedRange()
        let textLength = (textView.string as NSString).length

        isSynchronizing = true
        defer {
            isSynchronizing = false
        }

        if textLength > 0 {
            textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textLength))
        }
        textView.typingAttributes = attributes
        textView.font = attributes[.font] as? NSFont
        textView.alignment = context.alignment.nsTextAlignment
        textView.setSelectedRange(NSRange(
            location: min(selectedRange.location, textLength),
            length: min(selectedRange.length, max(textLength - min(selectedRange.location, textLength), 0))
        ))
    }

    private func fitFrameToText(_ text: String, context: EditableTextContext) {
        let fittedRect = fittedTextRect(for: text, context: context)
        guard let projectedRect = projectedTextRect(for: fittedRect) else {
            return
        }

        frame = liveFittedOverlayRect(
            for: text,
            projectedRect: projectedRect,
            context: context
        )
        textView.frame = textViewFrame(in: bounds, context: context)
        configureTextContainer()
        layoutLiveTextIfNeeded()
        needsDisplay = true
    }

    private func fittedTextRect(for text: String, context: EditableTextContext) -> CGRect {
        let font = NSFont.systemFont(ofSize: context.annotation.style.fontSize, weight: .semibold)

        switch context {
        case let .text(_, shape):
            if shape.automaticallySizesToText {
                let fittedRect = gscSnugTextRect(
                    for: text,
                    origin: shape.rect.origin,
                    font: font,
                    horizontalPadding: 24,
                    verticalPadding: 20,
                    minSize: CGSize(width: 44, height: 34),
                    maxWidth: maximumAutoTextWidth(for: shape)
                )

                return gscTextRectPositionedWithinBounds(fittedRect, bounds: controller.snapshot.cropRect)
            }

            return gscFittedTextRect(
                for: text,
                currentRect: shape.rect,
                font: font,
                horizontalPadding: 24,
                verticalPadding: 20,
                minSize: shape.rect.size,
                maxWidth: max(maximumAutoTextWidth(for: shape), shape.rect.width)
            )
        case let .callout(_, shape):
            let minSize = CGSize(width: 194, height: 72)
            if shape.automaticallySizesToText {
                let fittedRect = gscSnugCalloutRect(
                    for: text,
                    origin: shape.rect.origin,
                    font: font,
                    textHorizontalPadding: 40,
                    textVerticalPadding: 24,
                    badgeAllowance: calloutBadgeAllowance,
                    minSize: minSize,
                    maxWidth: maximumAutoCalloutWidth(for: shape)
                )

                return gscTextRectPositionedWithinBounds(fittedRect, bounds: controller.snapshot.cropRect)
            }

            return gscFittedCalloutRect(
                for: text,
                currentRect: shape.rect,
                font: font,
                textHorizontalPadding: 40,
                textVerticalPadding: 24,
                badgeAllowance: calloutBadgeAllowance,
                minSize: minSize,
                maxWidth: max(maximumAutoCalloutWidth(for: shape), shape.rect.width)
            )
        }
    }

    private func maximumAutoTextWidth(for shape: TextShape) -> CGFloat {
        gscAutoTextMaxWidth(
            originX: shape.rect.minX,
            within: controller.snapshot.cropRect,
            minWidth: 44
        )
    }

    private func maximumAutoCalloutWidth(for shape: CalloutShape) -> CGFloat {
        gscAutoTextMaxWidth(
            originX: shape.rect.minX,
            within: controller.snapshot.cropRect,
            minWidth: 194
        )
    }

    private func textAttributes(for context: EditableTextContext) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = context.alignment.nsTextAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        return [
            .font: NSFont.systemFont(ofSize: context.annotation.style.fontSize * displayScale, weight: .semibold),
            .foregroundColor: context.annotation.style.strokeColor.nsColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    private func liveFittedOverlayRect(
        for text: String,
        projectedRect: CGRect,
        context: EditableTextContext
    ) -> CGRect {
        let attributes = textAttributes(for: context)
        let font = attributes[.font] as? NSFont
        let minOverlaySize = minimumOverlaySize(for: context)
        var overlayRect = projectedRect.standardized

        if context.automaticallySizesToText {
            let maxOverlayWidth = max(maximumOverlayWidth(for: context), minOverlaySize.width)
            let maxContentWidth = max(textContentWidth(forOverlayWidth: maxOverlayWidth, height: max(overlayRect.height, minOverlaySize.height), context: context), 1)
            let minContentWidth = max(textContentWidth(forOverlayWidth: minOverlaySize.width, height: minOverlaySize.height, context: context), 1)
            let unwrappedContentWidth = ceil(
                liveTextLayoutMetrics(for: text, width: 100_000, attributes: attributes).usedRect.width
            ) + liveTextHorizontalLayoutSlack(for: font)
            let targetContentWidth = unwrappedContentWidth <= maxContentWidth
                ? max(unwrappedContentWidth, minContentWidth)
                : maxContentWidth

            overlayRect.size.width = min(
                max(overlayWidth(forTextContentWidth: targetContentWidth, height: max(overlayRect.height, minOverlaySize.height), context: context), minOverlaySize.width),
                maxOverlayWidth
            )
            overlayRect = positionLiveOverlayRectWithinCrop(overlayRect)
        }

        let contentWidth = max(textContentWidth(forOverlayWidth: overlayRect.width, height: max(overlayRect.height, minOverlaySize.height), context: context), 1)
        let textMetrics = liveTextLayoutMetrics(for: text, width: contentWidth, attributes: attributes)
        let targetHeight = ceil(textMetrics.usedRect.height)
            + verticalTextPadding(for: context)
            + liveTextVerticalLayoutSlack(for: font)
        overlayRect.size.height = max(overlayRect.height, targetHeight, minOverlaySize.height)

        if context.automaticallySizesToText {
            overlayRect = positionLiveOverlayRectWithinCrop(overlayRect)
        }

        return overlayRect.integral
    }

    private func minimumOverlaySize(for context: EditableTextContext) -> CGSize {
        switch context {
        case .text:
            return CGSize(width: 44 * displayScale, height: 34 * displayScale)
        case .callout:
            return CGSize(width: 194 * displayScale, height: 72 * displayScale)
        }
    }

    private func maximumOverlayWidth(for context: EditableTextContext) -> CGFloat {
        switch context {
        case let .text(_, shape):
            return maximumAutoTextWidth(for: shape) * displayScale
        case let .callout(_, shape):
            return maximumAutoCalloutWidth(for: shape) * displayScale
        }
    }

    private func textContentWidth(forOverlayWidth overlayWidth: CGFloat, height: CGFloat, context: EditableTextContext) -> CGFloat {
        switch context {
        case .text:
            return overlayWidth - textInsetX * 2
        case .callout:
            let badgeDiameter = calloutBadgeDiameter(forHeight: height)
            return overlayWidth - badgeDiameter + calloutBadgeOverlap - calloutTextInsetX * 2
        }
    }

    private func overlayWidth(forTextContentWidth contentWidth: CGFloat, height: CGFloat, context: EditableTextContext) -> CGFloat {
        switch context {
        case .text:
            return contentWidth + textInsetX * 2
        case .callout:
            let badgeDiameter = calloutBadgeDiameter(forHeight: height)
            return contentWidth + badgeDiameter - calloutBadgeOverlap + calloutTextInsetX * 2
        }
    }

    private func verticalTextPadding(for context: EditableTextContext) -> CGFloat {
        switch context {
        case .text:
            return textInsetY * 2
        case .callout:
            return calloutTextInsetY * 2
        }
    }

    private func positionLiveOverlayRectWithinCrop(_ rect: CGRect) -> CGRect {
        guard let cropRect = projectedTextRect(for: controller.snapshot.cropRect) else {
            return rect.integral
        }

        return gscTextRectPositionedWithinBounds(rect, bounds: cropRect)
    }

    private func liveTextLayoutMetrics(
        for text: String,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> (usedRect: CGRect, lineCount: Int) {
        let textStorage = NSTextStorage(
            string: liveTextMeasurementString(for: text),
            attributes: attributes
        )
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: max(width, 1), height: liveTextMeasurementHeight)
        )

        layoutManager.usesFontLeading = textView.layoutManager?.usesFontLeading ?? true
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping

        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            lineCount += 1
        }

        return (layoutManager.usedRect(for: textContainer), max(lineCount, 1))
    }

    private func liveTextMeasurementString(for text: String) -> String {
        guard !text.isEmpty else {
            return " "
        }

        return text.hasSuffix("\n") || text.hasSuffix("\r") ? text + " " : text
    }

    private func liveTextHorizontalLayoutSlack(for font: NSFont?) -> CGFloat {
        max((font?.pointSize ?? 0) * 0.06, displayScale, 0.75)
    }

    private func liveTextVerticalLayoutSlack(for font: NSFont?) -> CGFloat {
        ceil(max((font?.pointSize ?? 0) * 0.12, (font?.descender.magnitude ?? 0) * 0.5, 2 * displayScale, 1))
    }

    private func layoutLiveTextIfNeeded() {
        guard let textContainer = textView.textContainer else {
            return
        }

        textView.layoutManager?.ensureLayout(for: textContainer)
    }

    private func configureTextContainer() {
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: max(textView.bounds.width, 1),
            height: liveTextMeasurementHeight
        )
    }

    private func textViewFrame(in localBounds: CGRect, context: EditableTextContext) -> CGRect {
        switch context {
        case .text:
            return localBounds.insetBy(dx: textInsetX, dy: textInsetY)
        case .callout:
            return calloutBodyRect(in: localBounds).insetBy(dx: calloutTextInsetX, dy: calloutTextInsetY)
        }
    }

    private func drawCalloutBackground(_ shape: CalloutShape, annotation: Annotation) {
        let bodyRect = calloutBodyRect(in: bounds)
        let badgeRect = calloutBadgeRect(in: bounds)
        let bodyPath = NSBezierPath(
            roundedRect: bodyRect,
            xRadius: calloutBodyCornerRadius,
            yRadius: calloutBodyCornerRadius
        )

        if shape.style == .filled {
            annotation.style.fillColor.nsColor.setFill()
            bodyPath.fill()
        } else {
            annotation.style.fillColor.withAlpha(0.18).nsColor.setFill()
            bodyPath.fill()
            annotation.style.strokeColor.nsColor.setStroke()
            bodyPath.lineWidth = max(annotation.style.lineWidth * displayScale, 2 * displayScale)
            bodyPath.stroke()
        }

        let badgePath = NSBezierPath(ovalIn: badgeRect)
        if shape.style == .filled {
            annotation.style.fillColor.nsColor.setFill()
            badgePath.fill()
        } else {
            annotation.style.strokeColor.nsColor.setStroke()
            annotation.style.fillColor.withAlpha(0.12).nsColor.setFill()
            badgePath.lineWidth = max(annotation.style.lineWidth * displayScale, 2 * displayScale)
            badgePath.fill()
            badgePath.stroke()
        }

        let numberText = NSAttributedString(
            string: "\(shape.number)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: max(annotation.style.fontSize * displayScale - 2 * displayScale, 16 * displayScale),
                    weight: .bold
                ),
                .foregroundColor: annotation.style.strokeColor.nsColor
            ]
        )
        let numberSize = numberText.size()
        numberText.draw(
            at: CGPoint(
                x: badgeRect.midX - numberSize.width / 2,
                y: badgeRect.midY - numberSize.height / 2
            )
        )
    }

    private func calloutBadgeRect(in localBounds: CGRect) -> CGRect {
        let alignedBounds = localBounds.integral
        let diameter = calloutBadgeDiameter(forHeight: alignedBounds.height)
        return CGRect(
            x: alignedBounds.minX + 10 * displayScale,
            y: alignedBounds.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    private func calloutBodyRect(in localBounds: CGRect) -> CGRect {
        let alignedBounds = localBounds.integral
        let badgeRect = calloutBadgeRect(in: alignedBounds)
        return CGRect(
            x: badgeRect.maxX - calloutBadgeOverlap,
            y: alignedBounds.minY,
            width: max(alignedBounds.width - badgeRect.width + calloutBadgeOverlap, 1),
            height: alignedBounds.height
        )
    }

    private func calloutBadgeDiameter(forHeight height: CGFloat) -> CGFloat {
        min(max(height - 18 * displayScale, 32 * displayScale), 48 * displayScale)
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

    private var calloutTextInsetX: CGFloat {
        20 * displayScale
    }

    private var calloutTextInsetY: CGFloat {
        12 * displayScale
    }

    private var calloutBadgeOverlap: CGFloat {
        8 * displayScale
    }

    private var calloutBadgeAllowance: CGFloat {
        40
    }

    private var cornerRadius: CGFloat {
        12 * displayScale
    }

    private var calloutBodyCornerRadius: CGFloat {
        16 * displayScale
    }

    private var liveTextMeasurementHeight: CGFloat {
        100_000
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
    private var lastAccessibilitySelectedIDs: Set<UUID> = []

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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot annotation canvas")
        setAccessibilityHelp("Tab through annotations. Use arrow keys to move a selection and Option-arrow keys to resize it.")
        setAccessibilityIdentifier("editor.annotationCanvas")
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
        refreshAccessibilityElements(postNotification: false)
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
    var debugInteractionOverlayView: NSView {
        overlayView
    }

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
            self.refreshAccessibilityElements(postNotification: true)
        }

        synchronizeBaseImagePresentation()
        cropMaskView.controllerDidChange()
        stableContentView.controllerDidChange()
        overlayView.controllerDidChange()
        textEditorOverlayView.synchronize()
        refreshAccessibilityElements(postNotification: false)
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

    func performAccessibilityAction(
        _ action: AnnotationAccessibilityAction,
        for annotationID: UUID
    ) -> Bool {
        let isAlreadySelected = controller.snapshot.selectedAnnotationIDs.contains(annotationID)
        if !isAlreadySelected {
            controller.select(annotationID)
        }

        switch action {
        case .select:
            controller.select(annotationID)
        case .toggleSelection:
            controller.select(annotationID, additive: true, toggle: true)
        case .editText:
            guard controller.snapshot.annotations.first(where: { $0.id == annotationID })?.isTextEditable == true else {
                return false
            }
            controller.select(annotationID)
            window?.makeFirstResponder(overlayView)
        case .delete:
            controller.deleteSelected()
        case .duplicate:
            controller.duplicateSelectedAnnotations()
        case .bringForward:
            controller.bringForward()
        case .sendBackward:
            controller.sendBackward()
        case .bringToFront:
            controller.sendToFront()
        case .sendToBack:
            controller.sendToBack()
        case .group:
            controller.groupSelected()
        case .ungroup:
            controller.ungroupSelected()
        }
        refreshAccessibilityElements(postNotification: true)
        return true
    }

    fileprivate func traverseAnnotations(backward: Bool) {
        let orderedIDs = controller.snapshot.annotations.reversed().map(\.id)
        guard !orderedIDs.isEmpty else {
            return
        }
        let currentID = controller.snapshot.selectedAnnotationIDs.last
        let currentIndex = currentID.flatMap { orderedIDs.firstIndex(of: $0) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = backward
                ? (currentIndex - 1 + orderedIDs.count) % orderedIDs.count
                : (currentIndex + 1) % orderedIDs.count
        } else {
            nextIndex = backward ? orderedIDs.count - 1 : 0
        }
        controller.select(orderedIDs[nextIndex])
        refreshAccessibilityElements(postNotification: true, focusedAnnotationID: orderedIDs[nextIndex])
    }

    fileprivate func toggleSelectedAnnotation() {
        guard let annotationID = controller.snapshot.selectedAnnotationIDs.last else {
            traverseAnnotations(backward: false)
            return
        }
        controller.select(annotationID, additive: true, toggle: true)
        refreshAccessibilityElements(postNotification: true)
    }

    fileprivate func returnAccessibilityFocusToCanvas() {
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    private func refreshAccessibilityElements(
        postNotification: Bool,
        focusedAnnotationID: UUID? = nil
    ) {
        let annotations = Array(controller.snapshot.annotations.reversed())
        let selectedIDs = Set(controller.snapshot.selectedAnnotationIDs)
        let selectionChanged = selectedIDs != lastAccessibilitySelectedIDs
        lastAccessibilitySelectedIDs = selectedIDs
        let projection = DocumentProjection(
            sourceDocumentRect: controller.capture.documentRect,
            destinationBounds: controller.viewport.imageRect
        )
        let selectedCount = selectedIDs.count

        let elements = annotations.enumerated().map { index, annotation in
            let descriptor = AnnotationAccessibilityDescriptor(
                annotation: annotation,
                isSelected: selectedIDs.contains(annotation.id),
                layerPosition: index + 1,
                layerCount: annotations.count,
                canGroup: selectedCount > 1 && selectedIDs.contains(annotation.id),
                canUngroup: annotation.groupID != nil
            )
            let localFrame = projection.destinationRect(fromDocumentRect: annotation.boundingRect)
            let windowFrame = convert(localFrame, to: nil)
            let screenFrame = window?.convertToScreen(windowFrame) ?? .zero
            return AnnotationAccessibilityElement(canvas: self, descriptor: descriptor, frame: screenFrame)
        }
        setAccessibilityChildren(elements)

        guard postNotification else {
            return
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
        if selectionChanged {
            let announcement: String
            if selectedIDs.isEmpty {
                announcement = "No annotations selected."
            } else if selectedIDs.count == 1,
                      let annotation = annotations.first(where: { selectedIDs.contains($0.id) }) {
                announcement = "\(annotation.kind.displayName) selected."
            } else {
                announcement = "\(selectedIDs.count) annotations selected."
            }
            AppAccessibility.announce(announcement)
        }
        if let focusedAnnotationID,
           let focusedElement = elements.first(where: { $0.annotationID == focusedAnnotationID }) {
            NSAccessibility.post(element: focusedElement, notification: .focusedUIElementChanged)
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
        drawNumberedArrowResequencingPreview(in: canvasRect)

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
        let parentHierarchy: String?
        if options.showsParentHierarchy {
            parentHierarchy = controller.uiMapSnapshot?.parentHierarchy(for: element.id)
                .map(\.displayName)
                .joined(separator: " > ")
        } else {
            parentHierarchy = nil
        }

        return element.overlayLabelSegments(
            options: options,
            parentHierarchy: parentHierarchy
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let point = documentPoint(from: viewPoint),
              let annotation = annotation(at: point) else {
            return nil
        }

        window?.makeFirstResponder(self)
        if !controller.snapshot.selectedAnnotationIDs.contains(annotation.id) {
            controller.select(annotation.id)
        }

        let count = controller.selectedCount
        let title = count == 1 ? "Delete Annotation" : "Delete \(count) Annotations"
        let deleteItem = NSMenuItem(
            title: title,
            action: #selector(deleteSelectedAnnotationsFromContextMenu(_:)),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: title)

        let menu = NSMenu()
        menu.addItem(deleteItem)
        return menu
    }

    @objc private func deleteSelectedAnnotationsFromContextMenu(_ sender: Any?) {
        controller.deleteSelected()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)

        if controller.numberedArrowResequencingOrder != nil {
            if let point = documentPoint(from: viewPoint),
               let annotation = annotation(at: point),
               annotation.editorTool == .numberedArrow {
                controller.chooseNumberedArrowForResequencing(annotation.id)
            }
            needsDisplay = true
            return
        }

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
        case .numberedArrow:
            interactionState.beginLineDrawing(tool: .numberedArrow, anchor: point)
        case .statusMark:
            interactionState.beginStatusMarkDrawing(
                at: point,
                within: controller.snapshot.cropRect,
                style: controller.style(for: .statusMark)
            )
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
                numberedArrowNumber: controller.nextNumberedArrowNumber,
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
            numberedArrowNumber: controller.nextNumberedArrowNumber,
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

        if controller.numberedArrowResequencingOrder != nil {
            if event.keyCode == 53 {
                controller.cancelNumberedArrowResequencing()
                return
            }
            if event.keyCode == 36, controller.canFinishNumberedArrowResequencing {
                controller.finishNumberedArrowResequencing()
                return
            }
        }

        if event.keyCode == 48 {
            canvasView?.traverseAnnotations(backward: modifiers.contains(.shift))
            return
        }
        if event.keyCode == 49, modifiers == [.shift] {
            canvasView?.toggleSelectedAnnotation()
            return
        }
        if event.keyCode == 53 {
            canvasView?.returnAccessibilityFocusToCanvas()
            return
        }
        if modifiers == [.option], handleArrowResize(event, step: 1) {
            return
        }
        if modifiers == [.option, .shift], handleArrowResize(event, step: 10) {
            return
        }

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

    private func handleArrowResize(_ event: NSEvent, step: CGFloat) -> Bool {
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
        controller.resizeSelectedAnnotations(widthDelta: delta.width, heightDelta: delta.height)
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

        if let annotation = annotation(at: point) {
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

    private func annotation(at point: CGPoint) -> Annotation? {
        controller.snapshot.annotations.reversed().first { $0.contains(point) }
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

    private func drawNumberedArrowResequencingPreview(in canvasRect: CGRect) {
        guard let order = controller.numberedArrowResequencingOrder else { return }

        for (index, annotationID) in order.enumerated() {
            guard let annotation = controller.snapshot.annotations.first(where: { $0.id == annotationID }),
                  case let .arrow(shape) = annotation.kind,
                  shape.sequenceNumber != nil else {
                continue
            }

            let rect = viewRect(for: AnnotationGeometry.numberedArrowBadgeRect(for: shape), in: canvasRect)
            let badge = NSBezierPath(ovalIn: rect)
            NSColor.controlAccentColor.setFill()
            badge.fill()
            NSColor.selectedControlTextColor.setStroke()
            badge.lineWidth = 2
            badge.stroke()

            let text = NSAttributedString(
                string: "\(index + 1)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: max(rect.height * 0.48, 11),
                        weight: .bold
                    ),
                    .foregroundColor: NSColor.selectedControlTextColor
                ]
            )
            let size = text.size()
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
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
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        guard let textLayout = GlyphLineRenderer.layout(text: dimensions, font: font) else {
            return
        }
        let layout = gscCropInteractionHUDLayout(
            around: focusViewPoint,
            in: bounds,
            dimensionSize: textLayout.size
        )

        drawCropLoupe(layout: layout, focusDocumentPoint: focusDocumentPoint)
        drawCropDimensionBadge(textLayout: textLayout, in: layout.dimensionRect)
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

    private func drawCropDimensionBadge(textLayout: GlyphLineLayout, in rect: CGRect) {
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        border.lineWidth = 1
        border.stroke()

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        GlyphLineRenderer.draw(
            textLayout,
            at: CGPoint(
                x: rect.midX - textLayout.size.width / 2,
                y: rect.midY - textLayout.size.height / 2
            ),
            color: .white,
            in: context
        )
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
