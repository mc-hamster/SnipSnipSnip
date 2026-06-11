import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum EditorPreferenceKey {
    static let lastRedactionMode = "editor.lastRedactionMode"
    static let lastStrokeColorID = "editor.lastStrokeColorID"
    static let lastFillColorID = "editor.lastFillColorID"
    static let toolStyles = "editor.toolStyles"
}

private struct PersistedEditorToolStyleRecord: Codable {
    var strokeColor: PersistedEditorColorRecord
    var fillColor: PersistedEditorColorRecord
    var lineWidth: Double
    var fontSize: Double
    var effectRadius: Double
    var cornerRadius: Double?
    var dashStyle: String?
    var freehandSmoothing: Double?
    var freehandSimplification: Double?

    init(_ style: AnnotationStyle) {
        strokeColor = PersistedEditorColorRecord(style.strokeColor)
        fillColor = PersistedEditorColorRecord(style.fillColor)
        lineWidth = Double(style.lineWidth)
        fontSize = Double(style.fontSize)
        effectRadius = Double(style.effectRadius)
        cornerRadius = Double(style.cornerRadius)
        dashStyle = style.dashStyle.rawValue
        freehandSmoothing = Double(style.freehandSmoothing)
        freehandSimplification = Double(style.freehandSimplification)
    }

    var annotationStyle: AnnotationStyle {
        AnnotationStyle(
            strokeColor: strokeColor.rgbaColor,
            fillColor: fillColor.rgbaColor,
            lineWidth: CGFloat(lineWidth),
            fontSize: CGFloat(fontSize),
            effectRadius: CGFloat(effectRadius),
            cornerRadius: CGFloat(cornerRadius ?? 0),
            dashStyle: StrokeDashStyle(rawValue: dashStyle ?? "solid") ?? .solid,
            freehandSmoothing: CGFloat(freehandSmoothing ?? 0.65),
            freehandSimplification: CGFloat(freehandSimplification ?? 1.5)
        )
    }
}

private struct PersistedEditorColorRecord: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: RGBAColor) {
        red = Double(color.red)
        green = Double(color.green)
        blue = Double(color.blue)
        alpha = Double(color.alpha)
    }

    var rgbaColor: RGBAColor {
        RGBAColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: CGFloat(alpha)
        )
    }
}

@MainActor
final class EditorController: ObservableObject {
    enum ImageColorSamplingTarget: String {
        case picker
        case fill
    }

    private enum TextPlacementDirection {
        case right
        case below
        case left
        case above
    }

    private struct TextEditingSession {
        let annotationID: UUID
        let originalSnapshot: EditorSnapshot
    }

    private static let textEditingCommitDelayNanoseconds: UInt64 = 300_000_000

    @Published private(set) var snapshot: EditorSnapshot
    @Published var activeTool: EditorTool = .select {
        didSet {
            guard activeTool != oldValue else {
                return
            }

            invalidateCanvas()
        }
    }
    @Published var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    var editorSingleKeyToolShortcutsEnabled = true
    @Published private(set) var toolStyles: [EditorTool: AnnotationStyle]
    @Published private(set) var canvasRevision = 0
    @Published var ocrReviewText: String?
    @Published var isRecognizingOCR = false
    @Published private(set) var imageColorSamplingTarget: ImageColorSamplingTarget?
    @Published private(set) var previewedImageSampleColor: RGBAColor?
    @Published var cropAspectRatioPreset: CropAspectRatioPreset = .freeform
    private(set) var viewport: EditorViewport
    @Published private(set) var persistenceRevision = 0
    @Published private(set) var cropOutsideOverlayAlpha: CGFloat = AppModel.defaultEditorCropOutsideOverlayAlpha
    @Published private(set) var outOfCapturePatternSettings: EditorOutOfCapturePatternSettings = .default
    @Published var selectedUIMapElementID: UUID?
    @Published private(set) var hoveredUIMapElementID: UUID?
    @Published var showsAllUIMapElements = false {
        didSet {
            invalidateCanvas()
        }
    }
    @Published var uiMapOverlayOptions = UIMapOverlayOptions() {
        didSet {
            invalidateCanvas()
        }
    }
    @Published private(set) var isProcessingUIMap = false
    @Published private(set) var capture: CapturedScreenshot

    private let textRecognizer: any CaptureTextRecognizing
    private let initialSnapshot: EditorSnapshot
    private let defaults: UserDefaults
    private var preferredRedactionMode: RedactionMode

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var textEditingSession: TextEditingSession?
    private var pendingTextEditingCommitTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var imageColorSamplingSourceTool: EditorTool?

    private var documentCanvasSize: CGSize {
        CGSize(width: capture.image.width, height: capture.image.height)
    }

    private var fullImageRect: CGRect {
        CGRect(origin: .zero, size: documentCanvasSize)
    }

    deinit {
        pendingTextEditingCommitTask?.cancel()
        pendingTextEditingCommitTask = nil
        noticeTask?.cancel()
    }

    init(
        capture: CapturedScreenshot,
        defaults: UserDefaults = .standard,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.defaults = defaults
        self.preferredRedactionMode = defaults.string(forKey: EditorPreferenceKey.lastRedactionMode)
            .flatMap(RedactionMode.init(rawValue:)) ?? .blur
        self.capture = capture
        self.textRecognizer = textRecognizer
        self.uiMapOverlayOptions = uiMapOverlayOptions
        let capturedCursorAnnotation = capture.cursorOverlay.map {
            Annotation.makeImageOverlay(image: $0.image, in: $0.rect, role: .capturedCursor)
        }
        let initialAnnotations = capturedCursorAnnotation.map { [$0] } ?? []
        let session = EditorDocumentSession(
            initialSnapshot: EditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: capture.image.width, height: capture.image.height)),
                annotations: initialAnnotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1
            ),
            currentSnapshot: EditorSnapshot(
                cropRect: CGRect(origin: .zero, size: CGSize(width: capture.image.width, height: capture.image.height)),
                annotations: initialAnnotations,
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1
            ),
            undoStack: [],
            redoStack: [],
            toolStyles: Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { ($0, AnnotationStyle.default(for: $0)) })
        )
        self.initialSnapshot = session.initialSnapshot
        self.snapshot = session.currentSnapshot
        self.toolStyles = Self.loadPersistedToolStyles(from: defaults, fallback: session.toolStyles)
        let documentCanvasSize = CGSize(width: capture.image.width, height: capture.image.height)
        self.viewport = EditorViewport(contentSize: documentCanvasSize)
    }

    init(
        capture: CapturedScreenshot,
        session: EditorDocumentSession,
        defaults: UserDefaults = .standard,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.defaults = defaults
        self.preferredRedactionMode = defaults.string(forKey: EditorPreferenceKey.lastRedactionMode)
            .flatMap(RedactionMode.init(rawValue:)) ?? .blur
        self.capture = capture
        self.textRecognizer = textRecognizer
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.initialSnapshot = session.initialSnapshot
        self.snapshot = session.currentSnapshot
        self.undoStack = session.undoStack
        self.redoStack = session.redoStack
        self.toolStyles = session.toolStyles
        let documentCanvasSize = CGSize(width: capture.image.width, height: capture.image.height)
        self.viewport = EditorViewport(contentSize: documentCanvasSize)
    }

    var canUndo: Bool {
        !undoStack.isEmpty || snapshot != initialSnapshot
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    var selectedAnnotations: [Annotation] {
        let idSet = Set(snapshot.selectedAnnotationIDs)
        return snapshot.annotations.filter { idSet.contains($0.id) }
    }

    var containsRedactions: Bool {
        snapshot.annotations.contains { $0.redactionMode != nil }
    }

    var selectedAnnotation: Annotation? {
        guard let id = snapshot.selectedAnnotationIDs.last else {
            return nil
        }

        return annotation(matching: id)
    }

    var selectionBoundingRect: CGRect? {
        guard !selectedAnnotations.isEmpty else {
            return nil
        }

        return gscBoundingRect(of: selectedAnnotations.map(\.boundingRect))
    }

    var selectedCount: Int {
        snapshot.selectedAnnotationIDs.count
    }

    var canGroupSelection: Bool {
        selectedAnnotations.count > 1
    }

    var canUngroupSelection: Bool {
        !selectedGroupIDs.isEmpty
    }

    var canAlignSelection: Bool {
        selectedAnnotations.count > 1 || showsTextAlignmentControls
    }

    var selectedText: String {
        switch selectedAnnotation?.kind {
        case let .text(shape):
            return shape.text
        case let .callout(shape):
            return shape.text
        default:
            return ""
        }
    }

    var inspectorStyle: AnnotationStyle {
        if let selectedAnnotation {
            return selectedAnnotation.style
        }

        return style(for: activeTool)
    }

    var currentRedactionMode: RedactionMode {
        if let mode = selectedAnnotation?.redactionMode {
            return mode
        }

        return activeTool.defaultRedactionMode ?? preferredRedactionMode
    }

    var showsFontControls: Bool {
        if selectedAnnotations.contains(where: \.isTextEditable) {
            return true
        }

        return activeTool == .text || activeTool == .callout
    }

    var showsEffectControls: Bool {
        if !selectedRedactions.isEmpty {
            return true
        }

        return activeTool.defaultRedactionMode != nil
    }

    var showsFillControls: Bool {
        if let selectedAnnotation {
            return selectedAnnotation.supportsFillEditing
        }

        return activeTool.supportsFillEditing
    }

    var stylePrimaryLabel: String {
        if selectedAnnotation?.isTextEditable == true || activeTool == .text || activeTool == .callout {
            return "Text Color"
        }

        return "Stroke"
    }

    var showsTextAlignmentControls: Bool {
        selectedAnnotations.count == 1 && selectedAnnotation?.isTextEditable == true
    }

    var currentTextAlignment: TextAlignmentMode {
        selectedAnnotation?.textAlignmentMode ?? .left
    }

    var selectedRotationDegrees: CGFloat {
        selectedAnnotation?.rotationDegrees ?? 0
    }

    var showsRotationControls: Bool {
        canRotateSelection
    }

    var canRotateSelection: Bool {
        selectedCount > 0 && !selectedAnnotations.contains { $0.editorTool == .arrow }
    }

    var selectedImageOverlayOpacity: CGFloat? {
        guard case let .imageOverlay(shape) = selectedAnnotation?.kind else {
            return nil
        }

        return shape.opacity
    }

    var selectedImageOverlayRole: ImageOverlayShape.Role? {
        guard case let .imageOverlay(shape) = selectedAnnotation?.kind else {
            return nil
        }

        return shape.role
    }

    var uiMapSnapshot: UIMapSnapshot? {
        capture.uiMap
    }

    var selectedUIMapElement: UIMapElement? {
        guard let selectedUIMapElementID else {
            return nil
        }

        return uiMapSnapshot?.element(matching: selectedUIMapElementID)
    }

    var pinnedUIMapElements: [UIMapElement] {
        guard let uiMapSnapshot else {
            return []
        }

        return snapshot.pinnedUIMapElementIDs.compactMap { uiMapSnapshot.element(matching: $0) }
    }

    var isInspectingUIMap: Bool {
        FeatureFlags.uiMapEnabled
            && (activeTool == .uiMapInspect || selectedUIMapElement != nil)
    }

    var canBeginTextAnnotationFromUIMapSelection: Bool {
        guard let selectedUIMapElementID else {
            return false
        }

        return isUIMapElementPinned(selectedUIMapElementID)
    }

    var isSamplingImageColor: Bool {
        imageColorSamplingTarget != nil
    }

    var sampledPickerPreviewColor: RGBAColor {
        if imageColorSamplingTarget == .picker, let previewedImageSampleColor {
            return previewedImageSampleColor
        }

        return inspectorStyle.strokeColor
    }

    var sampledFillPreviewColor: RGBAColor {
        if imageColorSamplingTarget == .fill, let previewedImageSampleColor {
            return previewedImageSampleColor
        }

        return inspectorStyle.fillColor
    }

    var showsRectangleControls: Bool {
        selectedAnnotation?.editorTool == .rectangle || (selectedAnnotation == nil && activeTool == .rectangle)
    }

    var showsEllipseControls: Bool {
        selectedAnnotation?.editorTool == .ellipse || (selectedAnnotation == nil && activeTool == .ellipse)
    }

    /// Returns the active fill preset for rectangle/ellipse: nil = Outline, 0.18 = Soft, 1 = Solid.
    var activeFillPreset: CGFloat? {
        let fillColor = inspectorStyle.fillColor
        guard fillColor.alpha > 0 else { return nil }
        if abs(fillColor.alpha - 1) < 0.01 { return 1 }
        return 0.18
    }

    var showsFreehandControls: Bool {
        selectedAnnotation?.editorTool == .freehand
            || selectedAnnotation?.editorTool == .highlighter
            || (selectedAnnotation == nil && (activeTool == .freehand || activeTool == .highlighter))
    }

    var showsFreehandTuningControls: Bool {
        selectedAnnotation?.editorTool == .freehand || (selectedAnnotation == nil && activeTool == .freehand)
    }

    var showsArrowControls: Bool {
        selectedAnnotation?.editorTool == .arrow || (selectedAnnotation == nil && activeTool == .arrow)
    }

    var showsCalloutControls: Bool {
        selectedAnnotation?.editorTool == .callout || (selectedAnnotation == nil && activeTool == .callout)
    }

    var showsCropControls: Bool {
        true
    }

    var maxLineWidth: CGFloat {
        if selectedAnnotation?.editorTool == .highlighter || (selectedAnnotation == nil && activeTool == .highlighter) {
            return 42
        }

        return 16
    }

    var selectedArrowLabel: String {
        guard case let .arrow(shape) = selectedAnnotation?.kind else {
            return ""
        }
        return shape.label
    }

    var selectedArrowLabelBoxColor: RGBAColor {
        guard case let .arrow(shape) = selectedAnnotation?.kind else {
            return .clear
        }
        return shape.labelBoxColor
    }

    var selectedArrowLabelTextColor: ArrowLabelTextColor {
        guard case let .arrow(shape) = selectedAnnotation?.kind else {
            return .stroke
        }
        return shape.labelTextColor
    }

    var nextCalloutNumber: Int {
        snapshot.nextCalloutNumber
    }

    var zoomPercentageLabel: String {
        "\(viewport.zoomPercentage)%"
    }

    var presentation: ScreenshotPresentation {
        guard FeatureFlags.presentationStylingEnabled else {
            return .plain
        }

        return snapshot.presentation
    }

    var presentationBackgroundColor: RGBAColor {
        switch snapshot.presentation.background {
        case .transparent:
            return RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
        case let .solid(color):
            return color
        }
    }

    var requiresPNGForFaithfulExport: Bool {
        guard FeatureFlags.presentationStylingEnabled else {
            return false
        }

        return snapshot.presentation.requiresPNGForFaithfulExport
    }

    var canZoomIn: Bool {
        viewport.canZoomIn
    }

    var canZoomOut: Bool {
        viewport.canZoomOut
    }

    var documentSession: EditorDocumentSession {
        EditorDocumentSession(
            initialSnapshot: initialSnapshot,
            currentSnapshot: snapshot,
            undoStack: undoStack,
            redoStack: redoStack,
            toolStyles: toolStyles
        )
    }

    func execute(_ command: DocumentCommand, undoable: Bool = true) {
        commitPendingTextEdits()

        let updatedSnapshot = command.apply(to: snapshot)

        guard updatedSnapshot != snapshot else {
            return
        }

        if undoable {
            undoStack.append(snapshot)
            redoStack.removeAll()
        }

        applySnapshot(updatedSnapshot, fitViewportToCrop: updatedSnapshot.cropRect != snapshot.cropRect)
        persistenceRevision += 1
    }

    func style(for tool: EditorTool) -> AnnotationStyle {
        toolStyles[tool] ?? .default(for: tool)
    }

    func addAnnotation(_ annotation: Annotation) {
        execute(AddAnnotationCommand(annotation: annotation))
    }

    func updateAnnotations(_ annotations: [Annotation]) {
        guard !annotations.isEmpty else {
            return
        }

        execute(UpdateAnnotationsCommand(annotations: annotations))
    }

    func nudgeSelectedAnnotations(by delta: CGSize) {
        guard !selectedAnnotations.isEmpty else {
            return
        }

        updateAnnotations(selectedAnnotations.map { $0.translated(by: delta) })
    }

    func select(_ annotationID: UUID?, additive: Bool = false, toggle: Bool = false) {
        select(annotationIDs: annotationID.map { [$0] } ?? [], additive: additive, toggle: toggle)
    }

    func select(annotationIDs: [UUID], additive: Bool = false, toggle: Bool = false) {
        let expanded = normalizedSelection(for: annotationIDs)
        let updatedSelection = updatedSelection(from: expanded, additive: additive, toggle: toggle)
        if selectedUIMapElementID != nil {
            selectedUIMapElementID = nil
        }
        execute(SetSelectionCommand(annotationIDs: updatedSelection), undoable: false)
        invalidateCanvas()
    }

    func selectAll() {
        if selectedUIMapElementID != nil {
            selectedUIMapElementID = nil
        }
        execute(SetSelectionCommand(annotationIDs: snapshot.annotations.map(\.id)), undoable: false)
        invalidateCanvas()
    }

    func deleteSelected() {
        guard !snapshot.selectedAnnotationIDs.isEmpty else {
            return
        }

        let deletedCallout = selectedAnnotations.contains { annotation in
            if case .callout = annotation.kind {
                return true
            }
            return false
        }
        execute(DeleteAnnotationsCommand(annotationIDs: snapshot.selectedAnnotationIDs))
        if deletedCallout {
            renumberCallouts()
        }
    }

    func groupSelected() {
        guard canGroupSelection else {
            return
        }

        execute(SetGroupCommand(annotationIDs: snapshot.selectedAnnotationIDs, groupID: UUID()))
    }

    func ungroupSelected() {
        guard !selectedGroupIDs.isEmpty else {
            return
        }

        let ids = annotationIDs(inGroups: selectedGroupIDs)

        execute(SetGroupCommand(annotationIDs: ids, groupID: nil))
        execute(SetSelectionCommand(annotationIDs: ids), undoable: false)
    }

    // MARK: - Layer Reordering

    var canBringForward: Bool {
        snapshot.canReorderForward
    }

    var canSendBackward: Bool {
        snapshot.canReorderBackward
    }

    func bringForward() {
        guard canBringForward, !snapshot.selectedAnnotationIDs.isEmpty else {
            return
        }

        execute(ReorderAnnotationsCommand(
            annotationIDs: snapshot.selectedAnnotationIDs,
            direction: .forward,
            distance: .one
        ))
    }

    func sendBackward() {
        guard canSendBackward, !snapshot.selectedAnnotationIDs.isEmpty else {
            return
        }

        execute(ReorderAnnotationsCommand(
            annotationIDs: snapshot.selectedAnnotationIDs,
            direction: .backward,
            distance: .one
        ))
    }

    func sendToFront() {
        guard !snapshot.selectedAnnotationIDs.isEmpty else {
            return
        }

        execute(ReorderAnnotationsCommand(
            annotationIDs: snapshot.selectedAnnotationIDs,
            direction: .forward,
            distance: .extreme
        ))
    }

    func sendToBack() {
        guard !snapshot.selectedAnnotationIDs.isEmpty else {
            return
        }

        execute(ReorderAnnotationsCommand(
            annotationIDs: snapshot.selectedAnnotationIDs,
            direction: .backward,
            distance: .extreme
        ))
    }

    func reorderLayers(frontToBackAnnotationIDs: [UUID]) {
        execute(SetAnnotationOrderCommand(annotationIDsBackToFront: Array(frontToBackAnnotationIDs.reversed())))
    }

    func alignSelected(_ mode: AlignmentMode) {
        if showsTextAlignmentControls {
            switch mode {
            case .left:
                updateTextAlignment(.left)
            case .horizontalCenter:
                updateTextAlignment(.center)
            case .right:
                updateTextAlignment(.right)
            case .top, .verticalCenter, .bottom:
                return
            }
            return
        }

        guard let bounds = selectionBoundingRect, selectedAnnotations.count > 1 else {
            return
        }

        let updated = selectedAnnotations.map { annotation -> Annotation in
            let rect = annotation.boundingRect
            var dx: CGFloat = 0
            var dy: CGFloat = 0

            switch mode {
            case .left:
                dx = bounds.minX - rect.minX
            case .horizontalCenter:
                dx = bounds.midX - rect.midX
            case .right:
                dx = bounds.maxX - rect.maxX
            case .top:
                dy = bounds.minY - rect.minY
            case .verticalCenter:
                dy = bounds.midY - rect.midY
            case .bottom:
                dy = bounds.maxY - rect.maxY
            }

            return annotation.translated(by: CGSize(width: dx, height: dy))
        }

        updateAnnotations(updated)
    }

    func updateTextAlignment(_ alignment: TextAlignmentMode) {
        guard let selectedAnnotation, selectedAnnotation.isTextEditable else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingTextAlignment(alignment)))
    }

    func resetCrop() {
        execute(SetCropCommand(rect: fullImageRect))
    }

    var canResetCrop: Bool {
        snapshot.cropRect.gscIntegralStandardized != fullImageRect
    }

    var cropDimensionsLabel: String {
        gscCropPixelDimensionText(for: snapshot.cropRect.gscIntegralStandardized)
    }

    func previewCropRect(_ rect: CGRect) {
        let updatedSnapshot = SetCropCommand(rect: rect.gscIntegralStandardized).apply(to: snapshot)

        guard updatedSnapshot != snapshot else {
            return
        }

        applySnapshot(updatedSnapshot, fitViewportToCrop: false)
    }

    func commitPreviewedCropRect(_ rect: CGRect, originalRect: CGRect) {
        let finalRect = rect.gscIntegralStandardized
        let initialRect = originalRect.gscIntegralStandardized

        guard finalRect != initialRect else {
            let restoredSnapshot = SetCropCommand(rect: initialRect).apply(to: snapshot)
            if restoredSnapshot != snapshot {
                applySnapshot(restoredSnapshot, fitViewportToCrop: false)
            }
            return
        }

        let originalSnapshot = SetCropCommand(rect: initialRect).apply(to: snapshot)
        let committedSnapshot = SetCropCommand(rect: finalRect).apply(to: snapshot)
        applySnapshot(committedSnapshot, fitViewportToCrop: true)
        undoStack.append(originalSnapshot)
        redoStack.removeAll()
        persistenceRevision += 1
    }

    func updateText(_ text: String) {
        guard let annotation = selectedAnnotation, annotation.isTextEditable else {
            return
        }

        beginTextEditingSessionIfNeeded(for: annotation.id)

        let updatedAnnotation = annotation.updatingText(text)
        let updatedSnapshot = UpdateAnnotationCommand(annotation: updatedAnnotation).apply(to: snapshot)

        guard updatedSnapshot != snapshot else {
            return
        }

        applySnapshot(updatedSnapshot, fitViewportToCrop: updatedSnapshot.cropRect != snapshot.cropRect)
        schedulePendingTextEditCommit()
    }

    func applyTextInput(_ text: String) {
        guard let annotation = selectedAnnotation, annotation.isTextEditable else {
            return
        }

        let currentText = selectedText
        let updatedText: String

        if shouldReplacePlaceholderText(for: annotation, currentText: currentText) {
            updatedText = text
        } else {
            updatedText = currentText + text
        }

        updateText(updatedText)
    }

    func beginTextAnnotation(with seedText: String) {
        guard !seedText.isEmpty else {
            return
        }

        let textRect = suggestedTextRectForNewAnnotation()
        let annotation = Annotation.makeText(at: textRect.origin, style: style(for: .text))
            .resized(to: textRect)
            .updatingText(seedText)

        addAnnotation(annotation)
        if selectedUIMapElementID != nil {
            selectedUIMapElementID = nil
        }
    }

    func deleteBackwardInTextSelection() {
        guard let annotation = selectedAnnotation, annotation.isTextEditable else {
            return
        }

        let currentText = selectedText

        guard !currentText.isEmpty else {
            return
        }

        updateText(String(currentText.dropLast()))
    }

    func insertLineBreakInTextSelection() {
        guard let annotation = selectedAnnotation, annotation.isTextEditable else {
            return
        }

        if shouldReplacePlaceholderText(for: annotation, currentText: selectedText) {
            updateText("")
        }

        updateText(selectedText + "\n")
    }

    func updateStrokeColor(_ color: RGBAColor) {
        storePreferredPaletteColor(color, forKey: EditorPreferenceKey.lastStrokeColorID)
        mutateStyle {
            $0.strokeColor = Self.resolvedPaletteColor(color, preservingAlphaFrom: $0.strokeColor)
        }
    }

    func updateFillColor(_ color: RGBAColor) {
        storePreferredPaletteColor(color, forKey: EditorPreferenceKey.lastFillColorID)
        mutateStyle {
            $0.fillColor = Self.resolvedPaletteColor(color, preservingAlphaFrom: $0.fillColor)
        }
    }

    func updateLineWidth(_ value: CGFloat) {
        mutateStyle { $0.lineWidth = min(value, maxLineWidth) }
    }

    func updateFontSize(_ value: CGFloat) {
        mutateStyle { $0.fontSize = value }
    }

    func updateEffectRadius(_ value: CGFloat) {
        mutateStyle { $0.effectRadius = value }
    }

    func updateCornerRadius(_ value: CGFloat) {
        mutateStyle { $0.cornerRadius = max(0, value) }
    }

    func updateDashStyle(_ value: StrokeDashStyle) {
        mutateStyle { $0.dashStyle = value }
    }

    func updateFreehandSmoothing(_ value: CGFloat) {
        mutateStyle { $0.freehandSmoothing = max(0, min(value, 1)) }
    }

    func updateFreehandSimplification(_ value: CGFloat) {
        mutateStyle { $0.freehandSimplification = max(0, value) }
    }

    func updateArrowCurvature(_ value: CGFloat) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(curvature: max(-180, min(value, 180)))))
    }

    func updateArrowHeadStyle(_ value: ArrowHeadStyle) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(headStyle: value)))
    }

    func updateArrowLabel(_ value: String) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(label: value)))
    }

    func updateArrowLabelBoxColor(_ value: RGBAColor) {
        guard let selectedAnnotation, case let .arrow(shape) = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(
            labelBoxColor: Self.resolvedPaletteColor(value, preservingAlphaFrom: shape.labelBoxColor)
        )))
    }

    func updateArrowLabelPlacement(_ value: ArrowLabelPlacement) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(labelPlacement: value)))
    }

    func updateArrowLabelFontSize(_ value: CGFloat) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(labelFontSize: max(8, min(value, 72)))))
    }

    func updateArrowLabelTextColor(_ value: ArrowLabelTextColor) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(labelTextColor: value)))
    }

    func updateArrowHeadShape(_ value: ArrowHeadShape) {
        guard let selectedAnnotation, case .arrow = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingArrow(headShape: value)))
    }

    func updateCalloutStyle(_ value: CalloutVisualStyle) {
        guard let selectedAnnotation, case .callout = selectedAnnotation.kind else {
            return
        }

        execute(UpdateAnnotationCommand(annotation: selectedAnnotation.updatingCalloutStyle(value)))
    }

    func updateRotationDegrees(_ value: CGFloat) {
        guard !selectedAnnotations.isEmpty else {
            return
        }

        updateAnnotations(selectedAnnotations.map { $0.updatingRotationDegrees(value) })
    }

    func rotateSelected(by delta: CGFloat) {
        guard canRotateSelection else {
            return
        }

        updateAnnotations(selectedAnnotations.map { $0.updatingRotationDegrees($0.rotationDegrees + delta) })
    }

    func rotateSelectedClockwise90() {
        rotateSelected(by: 90)
    }

    func updateSelectedImageOverlayOpacity(_ opacity: CGFloat) {
        guard let selectedAnnotation else {
            return
        }

        var updated = selectedAnnotation
        guard case let .imageOverlay(shape) = selectedAnnotation.kind else {
            return
        }

        updated.kind = .imageOverlay(ImageOverlayShape(
            assetID: shape.assetID,
            rect: shape.rect,
            image: shape.image,
            opacity: max(0, min(opacity, 1)),
            role: shape.role
        ))
        execute(UpdateAnnotationCommand(annotation: updated))
    }

    func activateToolbarTool(_ tool: EditorTool) {
        if tool == .blur {
            selectedUIMapElementID = nil
            hoveredUIMapElementID = nil
            activeTool = preferredRedactionMode.editorTool
            invalidateCanvas()
            return
        }

        imageColorSamplingTarget = nil
        imageColorSamplingSourceTool = nil
        previewedImageSampleColor = nil

        if tool == .uiMapInspect {
            guard FeatureFlags.uiMapEnabled, uiMapSnapshot != nil else {
                activeTool = .select
                selectedUIMapElementID = nil
                hoveredUIMapElementID = nil
                invalidateCanvas()
                return
            }

            if !snapshot.selectedAnnotationIDs.isEmpty {
                execute(SetSelectionCommand(annotationIDs: []), undoable: false)
            }
        } else if selectedUIMapElementID != nil {
            selectedUIMapElementID = nil
            hoveredUIMapElementID = nil
        } else if hoveredUIMapElementID != nil {
            hoveredUIMapElementID = nil
        }

        activeTool = tool
        invalidateCanvas()
    }

    func beginImageColorSampling(_ target: ImageColorSamplingTarget) {
        imageColorSamplingSourceTool = selectedAnnotation?.editorTool ?? activeTool
        imageColorSamplingTarget = target
        previewedImageSampleColor = nil
        activeTool = .colorPicker
    }

    func cancelImageColorSampling() {
        imageColorSamplingTarget = nil
        imageColorSamplingSourceTool = nil
        previewedImageSampleColor = nil
        if activeTool == .colorPicker {
            activeTool = .select
        }
    }

    func updateRedactionMode(_ mode: RedactionMode) {
        storePreferredRedactionMode(mode)

        if !selectedRedactions.isEmpty {
            updateAnnotations(selectedRedactions.map { $0.updatingRedactionMode(mode) })
            return
        }

        activeTool = mode.editorTool
    }

    func undo() {
        commitPendingTextEdits()

        if let previous = undoStack.popLast() {
            redoStack.append(snapshot)
            applySnapshot(previous, fitViewportToCrop: previous.cropRect != snapshot.cropRect)
            persistenceRevision += 1
            return
        }

        guard snapshot != initialSnapshot else {
            return
        }

        redoStack.append(snapshot)
        applySnapshot(initialSnapshot, fitViewportToCrop: initialSnapshot.cropRect != snapshot.cropRect)
        persistenceRevision += 1
    }

    func redo() {
        commitPendingTextEdits()

        guard let next = redoStack.popLast() else {
            return
        }

        undoStack.append(snapshot)
        applySnapshot(next, fitViewportToCrop: next.cropRect != snapshot.cropRect)
        persistenceRevision += 1
    }

    func updateViewportCanvasSize(_ size: CGSize) {
        updateViewport(publishChange: false) {
            $0.updatingCanvasSize(size)
        }
    }

    func zoomIn() {
        updateViewport { $0.zoomed(to: $0.zoomScale * 1.25) }
    }

    func zoomOut() {
        updateViewport { $0.zoomed(to: $0.zoomScale / 1.25) }
    }

    func zoomToFit() {
        updateViewport {
            guard snapshot.cropRect.gscIntegralStandardized != fullImageRect else {
                return $0.zoomedToFit()
            }

            return $0.focused(on: snapshot.cropRect)
        }
    }

    func zoomToInitialDisplayScale() {
        updateViewport {
            let updatedViewport = $0.updatingContentSize(documentCanvasSize, fitToWindow: false)

            guard snapshot.cropRect.gscIntegralStandardized != fullImageRect else {
                return updatedViewport.zoomedForInitialDisplay(maxDisplayScale: EditorViewport.maxInitialDisplayScale)
            }

            return updatedViewport.focused(on: snapshot.cropRect)
        }
    }

    func zoomToActualSize() {
        updateViewport { $0.zoomed(to: $0.actualSizeZoomScale) }
    }

    func magnifyViewport(by magnification: CGFloat, anchoredAt anchor: CGPoint) {
        let factor = max(0.05, 1 + magnification)
        updateViewport { $0.zoomed(to: $0.zoomScale * factor, anchoredAt: anchor) }
    }

    func zoomViewportFromScrollWheel(deltaY: CGFloat, anchoredAt anchor: CGPoint) {
        guard deltaY != 0 else {
            return
        }

        let factor = pow(1.0018, deltaY)
        updateViewport { $0.zoomed(to: $0.zoomScale * factor, anchoredAt: anchor) }
    }

    func updateCropOutsideOverlayAlpha(_ alpha: CGFloat) {
        let clampedAlpha = min(max(alpha, 0), 0.9)

        guard cropOutsideOverlayAlpha != clampedAlpha else {
            return
        }

        cropOutsideOverlayAlpha = clampedAlpha
        invalidateCanvas()
    }

    func updateOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) {
        guard outOfCapturePatternSettings != settings else {
            return
        }

        outOfCapturePatternSettings = settings
        invalidateCanvas()
    }

    func panViewport(by delta: CGSize) {
        updateViewport { $0.panned(by: delta) }
    }

    func scrollViewport(horizontalPosition: CGFloat? = nil, verticalPosition: CGFloat? = nil) {
        updateViewport {
            $0.scrolledTo(horizontalPosition: horizontalPosition, verticalPosition: verticalPosition)
        }
    }

    func selectUIMapElement(_ elementID: UUID?) {
        if elementID != nil, !snapshot.selectedAnnotationIDs.isEmpty {
            execute(SetSelectionCommand(annotationIDs: []), undoable: false)
        }

        selectedUIMapElementID = elementID
        invalidateCanvas()
    }

    func hoverUIMapElement(_ elementID: UUID?) {
        guard hoveredUIMapElementID != elementID else {
            return
        }

        hoveredUIMapElementID = elementID
        invalidateCanvas()
    }

    func selectAndTogglePinnedUIMapElement(_ elementID: UUID?) {
        guard let elementID else {
            selectUIMapElement(nil)
            return
        }

        selectUIMapElement(elementID)
        togglePinnedUIMapElement(elementID)
    }

    func beginUIMapProcessing() {
        guard !isProcessingUIMap else {
            return
        }

        isProcessingUIMap = true
    }

    func finishUIMapProcessing(with uiMap: UIMapSnapshot?) {
        isProcessingUIMap = false

        guard let uiMap else {
            return
        }

        attachUIMap(uiMap)
    }

    func attachUIMap(_ uiMap: UIMapSnapshot) {
        guard capture.uiMap != uiMap else {
            return
        }

        capture = capture.attachingUIMap(uiMap)
        persistenceRevision += 1
        invalidateCanvas()
    }

    func isUIMapElementPinned(_ elementID: UUID) -> Bool {
        snapshot.pinnedUIMapElementIDs.contains(elementID)
    }

    func togglePinnedUIMapElement(_ elementID: UUID) {
        guard uiMapSnapshot?.element(matching: elementID) != nil else {
            return
        }

        var pinnedElementIDs = snapshot.pinnedUIMapElementIDs
        if let existingIndex = pinnedElementIDs.firstIndex(of: elementID) {
            pinnedElementIDs.remove(at: existingIndex)
        } else {
            pinnedElementIDs.append(elementID)
        }

        execute(SetPinnedUIMapElementsCommand(elementIDs: pinnedElementIDs))
        invalidateCanvas()
    }

    func focusViewport(on documentRect: CGRect) {
        updateViewport {
            $0.focused(on: documentRect.insetBy(dx: -24, dy: -24))
        }
    }

    func exportedImage() -> CGImage? {
        ScreenshotPresentationRenderer.render(
            baseImage: capture.image,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
    }

    func applyPresentationPreset(_ preset: ScreenshotPresentationPreset) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        execute(SetPresentationCommand(presentation: preset.settings))
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

    func applySampledColor(at point: CGPoint, toFill: Bool = false) {
        guard let color = sampledBaseColor(at: point) else {
            errorMessage = "The color could not be sampled at that point."
            return
        }

        let targetIsFill = imageColorSamplingTarget == .fill || toFill
        let restoreTool = imageColorSamplingSourceTool

        if selectedAnnotations.isEmpty, let restoreTool {
            activeTool = restoreTool
        }
        if targetIsFill {
            updateFillColor(color)
        } else {
            updateStrokeColor(color)
        }
        imageColorSamplingTarget = nil
        imageColorSamplingSourceTool = nil
        previewedImageSampleColor = nil
        activeTool = .select
    }

    func previewSampledColor(at point: CGPoint) {
        previewedImageSampleColor = sampledBaseColor(at: point)
    }

    func applyRectangleFillPreset(_ opacity: CGFloat?) {
        guard showsRectangleControls else {
            return
        }

        guard let opacity else {
            updateFillColor(.clear)
            return
        }

        let baseColor = inspectorStyle.strokeColor == .clear ? RGBAColor.rectangleStroke : inspectorStyle.strokeColor
        updateFillColor(baseColor.withAlpha(max(0, min(opacity, 1))))
    }

    func applyEllipseFillPreset(_ opacity: CGFloat?) {
        guard showsEllipseControls else {
            return
        }

        guard let opacity else {
            updateFillColor(.clear)
            return
        }

        let baseColor = inspectorStyle.strokeColor == .clear ? RGBAColor.ellipseStroke : inspectorStyle.strokeColor
        updateFillColor(baseColor.withAlpha(max(0, min(opacity, 1))))
    }

    func updateCropRect(_ rect: CGRect) {
        execute(SetCropCommand(rect: rect.gscIntegralStandardized))
    }

    func updateCropOrigin(x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil) {
        var rect = snapshot.cropRect.gscIntegralStandardized
        if let x {
            rect.origin.x = x
        }
        if let y {
            rect.origin.y = y
        }
        if let width {
            rect.size.width = max(1, width)
        }
        if let height {
            rect.size.height = max(1, height)
        }

        updateCropRect(rect.gscClamped(to: fullImageRect))
    }

    func updateCropAspectRatioPreset(_ preset: CropAspectRatioPreset) {
        cropAspectRatioPreset = preset

        guard let ratio = preset.ratio else {
            return
        }

        updateCropRect(cropRectFittingCurrentCrop(to: ratio))
    }

    private func cropRectFittingCurrentCrop(to aspectRatio: CGFloat) -> CGRect {
        let currentCrop = snapshot.cropRect.gscIntegralStandardized
        guard aspectRatio > 0, currentCrop.width > 0, currentCrop.height > 0 else {
            return currentCrop
        }

        let currentRatio = currentCrop.width / currentCrop.height
        let targetSize: CGSize
        if currentRatio > aspectRatio {
            targetSize = CGSize(
                width: floor(currentCrop.height * aspectRatio),
                height: currentCrop.height
            )
        } else {
            targetSize = CGSize(
                width: currentCrop.width,
                height: floor(currentCrop.width / aspectRatio)
            )
        }

        let targetOrigin = CGPoint(
            x: round(currentCrop.midX - targetSize.width / 2),
            y: round(currentCrop.midY - targetSize.height / 2)
        )

        return CGRect(origin: targetOrigin, size: targetSize)
            .gscContained(in: currentCrop)
            .gscClamped(to: fullImageRect)
    }

    func copyCalloutStepGuideToClipboard() {
        let callouts = snapshot.annotations.compactMap { annotation -> CalloutShape? in
            guard case let .callout(shape) = annotation.kind else {
                return nil
            }
            return shape
        }.sorted { $0.number < $1.number }

        guard !callouts.isEmpty else {
            return
        }

        let guide = callouts.map { "\($0.number). \($0.text)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(guide, forType: .string)
    }

    func recognizeText(in rect: CGRect) {
        let localRect = rect.gscIntegralStandardized
        let baseImage = capture.image
        guard localRect.width > 1, localRect.height > 1 else {
            return
        }

        isRecognizingOCR = true
        let textRecognizer = textRecognizer
        Task { @MainActor [weak self] in
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    guard let cropped = CaptureTextRecognizer.cropImage(in: baseImage, region: localRect) else {
                        return ""
                    }

                    return try CaptureTextRecognizer.normalizedRecognizedText(
                        textRecognizer.recognizeText(in: cropped)
                    )
                }.value
                self?.ocrReviewText = text
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            self?.isRecognizingOCR = false
            self?.activeTool = .select
        }
    }

    func copyOCRReviewTextToClipboard() {
        let text = ocrReviewText ?? ""
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ocrReviewText = nil
    }

    func dismissOCRReview() {
        ocrReviewText = nil
    }

    func addImageOverlayFromPasteboard() -> Bool {
        guard let image = imageFromPasteboard() else {
            return false
        }

        addImageOverlay(image)
        return true
    }

    func importImageOverlay() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url, let image = cgImage(at: url) else {
            return
        }

        addImageOverlay(image)
    }

    func copyAnnotatedImage() {
        let input = EditorExportRenderInput(
            baseImage: capture.image,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )

        Task { @MainActor [weak self] in
            do {
                let pngData = try await EditorExportRenderer.renderPNGData(from: input)
                try ImageExporter.copyPNGDataToClipboard(pngData)
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func saveAnnotatedImage(
        format: ImageExportFormat = .png,
        filenameTemplate: ScreenshotFilenameTemplate = ScreenshotFilenameTemplate.default,
        exportOptions: ImageExportOptions = .default
    ) {
        let input = EditorExportRenderInput(
            baseImage: capture.image,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
        let suggestedFilename = ImageExporter.editedFilename(
            suggestedFilename: filenameTemplate.resolvedFilename(for: capture, formatExtension: format.fileExtension),
            format: format
        )

        Task { @MainActor [weak self] in
            do {
                if input.snapshot.presentation.requiresPNGForFaithfulExport, format != .png {
                    throw ImageExportError.transparentPresentationRequiresPNG
                }

                guard let url = await ImageExporter.destinationURL(suggestedFilename: suggestedFilename, format: format) else {
                    return
                }

                let image = try await EditorExportRenderer.renderImage(from: input)
                try await ImageExporter.write(image, format: format, to: url, options: exportOptions)
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func shareAnnotatedImage() {
        let input = EditorExportRenderInput(
            baseImage: capture.image,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )

        Task { @MainActor [weak self] in
            do {
                let image = try await EditorExportRenderer.renderImage(from: input)
                try ImageExporter.share(image)
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func promisedImagePayload(
        requestedFormat: ImageExportFormat,
        filenameTemplate: ScreenshotFilenameTemplate,
        exportOptions: ImageExportOptions = .default
    ) -> PromisedFilePayload {
        let input = EditorExportRenderInput(
            baseImage: capture.image,
            snapshot: snapshot,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions
        )
        let format = ImageExporter.dragOutFormat(
            requestedFormat: requestedFormat,
            requiresPNGForFaithfulExport: input.snapshot.presentation.requiresPNGForFaithfulExport
        )
        let suggestedFilename = ImageExporter.editedFilename(
            suggestedFilename: filenameTemplate.resolvedFilename(for: capture, formatExtension: format.fileExtension),
            format: format
        )

        if format != requestedFormat {
            showNotice("PNG used to preserve transparent presentation styling.")
        }

        return PromisedFilePayload(
            suggestedFilename: suggestedFilename,
            contentType: format.contentType,
            writer: { destinationURL in
                let image = try await EditorExportRenderer.renderImage(from: input)
                try await ImageExporter.write(image, format: format, to: destinationURL, mode: .direct, options: exportOptions)
            },
            completion: { [weak self] result in
                guard case .failure(let error) = result else {
                    return
                }

                Task { @MainActor [weak self] in
                    self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        )
    }

    func dismissError() {
        errorMessage = nil
    }

    func showNotice(_ message: String) {
        noticeTask?.cancel()
        noticeMessage = message
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
            self?.noticeMessage = nil
        }
    }

    func commitPendingTextEdits() {
        pendingTextEditingCommitTask?.cancel()
        pendingTextEditingCommitTask = nil

        guard let session = textEditingSession else {
            return
        }

        textEditingSession = nil

        refitPendingTextBounds(for: session)

        guard snapshot != session.originalSnapshot else {
            return
        }

        undoStack.append(session.originalSnapshot)
        redoStack.removeAll()
        persistenceRevision += 1
    }

    private func mutateStyle(_ mutation: (inout AnnotationStyle) -> Void) {
        if !selectedAnnotations.isEmpty {
            let updated = selectedAnnotations.map { annotation -> Annotation in
                var style = annotation.style
                mutation(&style)
                return annotation.updatingStyle(style)
            }

            updatePersistedToolStyles(using: updated)

            updateAnnotations(updated)
            return
        }

        guard activeTool.supportsStyleEditing else {
            return
        }

        var style = style(for: activeTool)
        mutation(&style)
        toolStyles[activeTool] = style
        persistToolStyles()
        persistenceRevision += 1
    }

    private func mutatePresentation(_ mutation: (inout ScreenshotPresentation) -> Void) {
        guard FeatureFlags.presentationStylingEnabled else {
            return
        }

        var presentation = snapshot.presentation
        mutation(&presentation)
        presentation.isEnabled = presentation != .plain
        execute(SetPresentationCommand(presentation: presentation))
    }

    private func addImageOverlay(_ image: CGImage) {
        let bounds = snapshot.cropRect.gscIntegralStandardized
        let maxWidth = min(bounds.width * 0.55, CGFloat(image.width))
        let scale = maxWidth / CGFloat(max(image.width, 1))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).gscIntegralStandardized
        addAnnotation(Annotation.makeImageOverlay(image: image, in: rect))
    }

    private func imageFromPasteboard() -> CGImage? {
        let pasteboard = NSPasteboard.general

        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                continue
            }

            return image
        }

        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: [:])?.first as? URL {
            return cgImage(at: url)
        }

        return nil
    }

    private func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func sampledBaseColor(at point: CGPoint) -> RGBAColor? {
        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))

        guard x >= 0, y >= 0, x < capture.image.width, y < capture.image.height,
              let dataProvider = capture.image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data),
              capture.image.bitsPerPixel >= 24,
              capture.image.bitsPerComponent == 8 else {
            return nil
        }

        let bytesPerPixel = capture.image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else {
            return nil
        }

        let offset = y * capture.image.bytesPerRow + x * bytesPerPixel
        let components = sampledComponents(from: bytes, offset: offset, bytesPerPixel: bytesPerPixel, bitmapInfo: capture.image.bitmapInfo)
        return RGBAColor(
            red: CGFloat(components.red) / 255,
            green: CGFloat(components.green) / 255,
            blue: CGFloat(components.blue) / 255,
            alpha: CGFloat(components.alpha) / 255
        )
    }

    private func sampledComponents(
        from bytes: UnsafePointer<UInt8>,
        offset: Int,
        bytesPerPixel: Int,
        bitmapInfo: CGBitmapInfo
    ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard bytesPerPixel >= 4 else {
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], 255)
        }

        let alphaInfo = CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue) ?? .none
        let byteOrder = bitmapInfo.intersection(.byteOrderMask)

        switch (byteOrder, alphaInfo) {
        case (.byteOrder32Little, .premultipliedFirst), (.byteOrder32Little, .first), (.byteOrder32Little, .noneSkipFirst):
            return (bytes[offset + 2], bytes[offset + 1], bytes[offset], alphaInfo == .noneSkipFirst ? 255 : bytes[offset + 3])
        case (.byteOrder32Little, .premultipliedLast), (.byteOrder32Little, .last), (.byteOrder32Little, .noneSkipLast):
            return (bytes[offset + 3], bytes[offset + 2], bytes[offset + 1], alphaInfo == .noneSkipLast ? 255 : bytes[offset])
        case (.byteOrder32Big, .premultipliedFirst), (.byteOrder32Big, .first), (.byteOrder32Big, .noneSkipFirst):
            return (bytes[offset + 1], bytes[offset + 2], bytes[offset + 3], alphaInfo == .noneSkipFirst ? 255 : bytes[offset])
        case (.byteOrder32Big, .premultipliedLast), (.byteOrder32Big, .last), (.byteOrder32Big, .noneSkipLast):
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], alphaInfo == .noneSkipLast ? 255 : bytes[offset + 3])
        default:
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
    }

    private func renumberCallouts() {
        var nextNumber = 1
        let updated = snapshot.annotations.map { annotation -> Annotation in
            guard case let .callout(shape) = annotation.kind else {
                return annotation
            }

            defer { nextNumber += 1 }
            let updatedText: String
            if shape.text == "Callout \(shape.number)" {
                updatedText = "Callout \(nextNumber)"
            } else {
                updatedText = shape.text
            }

            return annotation
                .updatingText(updatedText, refittingBounds: false)
                .updatingCalloutNumber(nextNumber)
        }

        guard updated != snapshot.annotations else {
            return
        }

        execute(UpdateAnnotationsCommand(annotations: updated))
    }

    private func shouldReplacePlaceholderText(for annotation: Annotation, currentText: String) -> Bool {
        switch annotation.kind {
        case .text:
            return currentText == "Text"
        case let .callout(shape):
            return currentText == "Callout \(shape.number)"
        default:
            return false
        }
    }

    private func normalizedSelection(for ids: [UUID]) -> [UUID] {
        let allIDs = ids.flatMap(expandedSelectionIDs(for:))

        return orderedSelection(from: allIDs)
    }

    private var selectedGroupIDs: Set<UUID> {
        Set(selectedAnnotations.compactMap(\.groupID))
    }

    private var selectedRedactions: [Annotation] {
        selectedAnnotations.filter { $0.redactionMode != nil }
    }

    private static func loadPersistedToolStyles(from defaults: UserDefaults, fallback styles: [EditorTool: AnnotationStyle]) -> [EditorTool: AnnotationStyle] {
        guard let data = defaults.data(forKey: EditorPreferenceKey.toolStyles),
              let persisted = try? JSONDecoder().decode([String: PersistedEditorToolStyleRecord].self, from: data) else {
                        return normalizedToolStyles(applyingPersistedPalettePreferences(to: styles, defaults: defaults))
        }

        var updated = styles

        for tool in EditorTool.allCases {
            guard let record = persisted[tool.rawValue] else {
                continue
            }

            updated[tool] = record.annotationStyle
        }

        return normalizedToolStyles(updated)
    }

    private static func normalizedToolStyles(_ styles: [EditorTool: AnnotationStyle]) -> [EditorTool: AnnotationStyle] {
        var normalized = styles

        if var highlighterStyle = normalized[.highlighter] {
            highlighterStyle.freehandSmoothing = 1
            highlighterStyle.freehandSimplification = 8
            normalized[.highlighter] = highlighterStyle
        }

        return normalized
    }

    private static func applyingPersistedPalettePreferences(to styles: [EditorTool: AnnotationStyle], defaults: UserDefaults) -> [EditorTool: AnnotationStyle] {
        let strokeColor = defaults.string(forKey: EditorPreferenceKey.lastStrokeColorID)
            .flatMap(RGBAColor.paletteOption(id:))?
            .color
        let fillColor = defaults.string(forKey: EditorPreferenceKey.lastFillColorID)
            .flatMap(RGBAColor.paletteOption(id:))?
            .color

        guard strokeColor != nil || fillColor != nil else {
            return styles
        }

        var updated = styles

        for tool in EditorTool.allCases {
            guard var style = updated[tool] else {
                continue
            }

            if tool.supportsStyleEditing, let strokeColor {
                style.strokeColor = resolvedPaletteColor(strokeColor, preservingAlphaFrom: style.strokeColor)
            }

            if tool.supportsFillEditing, let fillColor {
                style.fillColor = resolvedPaletteColor(fillColor, preservingAlphaFrom: style.fillColor)
            }

            updated[tool] = style
        }

        return updated
    }

    private static func resolvedPaletteColor(_ color: RGBAColor, preservingAlphaFrom existingColor: RGBAColor) -> RGBAColor {
        guard color != .clear else {
            return .clear
        }

        guard existingColor.alpha > 0 else {
            return color
        }

        return color.withAlpha(existingColor.alpha)
    }

    private func storePreferredRedactionMode(_ mode: RedactionMode) {
        preferredRedactionMode = mode
        defaults.set(mode.rawValue, forKey: EditorPreferenceKey.lastRedactionMode)
    }

    private func storePreferredPaletteColor(_ color: RGBAColor, forKey key: String) {
        guard let option = RGBAColor.paletteOption(for: color) else {
            return
        }

        defaults.set(option.id, forKey: key)
    }

    private func updatePersistedToolStyles(using annotations: [Annotation]) {
        var updatedToolStyles = toolStyles

        for annotation in annotations {
            updatedToolStyles[annotation.editorTool] = annotation.style
        }

        guard updatedToolStyles != toolStyles else {
            return
        }

        toolStyles = updatedToolStyles
        persistToolStyles()
    }

    private func persistToolStyles() {
        let records = Dictionary(uniqueKeysWithValues: toolStyles.map { key, value in
            (key.rawValue, PersistedEditorToolStyleRecord(value))
        })

        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        defaults.set(data, forKey: EditorPreferenceKey.toolStyles)
    }

    private func beginTextEditingSessionIfNeeded(for annotationID: UUID) {
        guard textEditingSession?.annotationID != annotationID else {
            return
        }

        commitPendingTextEdits()
        textEditingSession = TextEditingSession(annotationID: annotationID, originalSnapshot: snapshot)
    }

    private func schedulePendingTextEditCommit() {
        pendingTextEditingCommitTask?.cancel()
        pendingTextEditingCommitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.textEditingCommitDelayNanoseconds)
            } catch {
                return
            }

            self?.commitPendingTextEdits()
        }
    }

    private func refitPendingTextBounds(for session: TextEditingSession) {
        guard let annotation = annotation(matching: session.annotationID), annotation.isTextEditable else {
            return
        }

        let refittedAnnotation = annotation.refittingTextBounds()
        let refittedSnapshot = UpdateAnnotationCommand(annotation: refittedAnnotation).apply(to: snapshot)

        guard refittedSnapshot != snapshot else {
            return
        }

        applySnapshot(refittedSnapshot, fitViewportToCrop: refittedSnapshot.cropRect != snapshot.cropRect)
    }

    private func annotation(matching id: UUID) -> Annotation? {
        snapshot.annotations.first(where: { $0.id == id })
    }

    private func suggestedTextRectForNewAnnotation() -> CGRect {
        if let selectedUIMapElement,
           isUIMapElementPinned(selectedUIMapElement.id) {
            return gscSuggestedTextRect(adjacentTo: selectedUIMapElement.documentRect, within: snapshot.cropRect)
        }

        guard selectedAnnotations.count == 1, let annotation = selectedAnnotation else {
            return defaultSuggestedTextRect()
        }

        switch annotation.kind {
        case let .arrow(shape):
            return suggestedTextRect(near: shape.start, awayFrom: shape.end)
        default:
            return gscSuggestedTextRect(adjacentTo: annotation.boundingRect, within: snapshot.cropRect)
        }
    }

    private func defaultSuggestedTextRect() -> CGRect {
        let anchorRect = selectionBoundingRect ?? CGRect(
            x: snapshot.cropRect.midX - 40,
            y: snapshot.cropRect.midY - 20,
            width: 80,
            height: 40
        )

        return gscSuggestedTextRect(adjacentTo: anchorRect, within: snapshot.cropRect)
    }

    private func suggestedTextRect(near anchor: CGPoint, awayFrom avoidedPoint: CGPoint) -> CGRect {
        let directions = preferredTextPlacementDirections(from: anchor, awayFrom: avoidedPoint)
        let preferredRect = suggestedTextRect(near: anchor, preferredDirections: directions)

        guard snapshot.cropRect.contains(preferredRect) else {
            return defaultSuggestedTextRect()
        }

        return preferredRect
    }

    private func preferredTextPlacementDirections(from anchor: CGPoint, awayFrom avoidedPoint: CGPoint) -> [TextPlacementDirection] {
        let deltaX = avoidedPoint.x - anchor.x
        let deltaY = avoidedPoint.y - anchor.y

        if abs(deltaX) >= abs(deltaY) {
            let primary: TextPlacementDirection = deltaX >= 0 ? .left : .right
            let secondary: TextPlacementDirection = deltaY >= 0 ? .above : .below
            let tertiary: TextPlacementDirection = secondary == .above ? .below : .above
            let quaternary: TextPlacementDirection = primary == .left ? .right : .left
            return [primary, secondary, tertiary, quaternary]
        }

        let primary: TextPlacementDirection = deltaY >= 0 ? .above : .below
        let secondary: TextPlacementDirection = deltaX >= 0 ? .left : .right
        let tertiary: TextPlacementDirection = secondary == .left ? .right : .left
        let quaternary: TextPlacementDirection = primary == .above ? .below : .above
        return [primary, secondary, tertiary, quaternary]
    }

    private func suggestedTextRect(
        near anchor: CGPoint,
        preferredDirections: [TextPlacementDirection],
        size: CGSize = CGSize(width: 260, height: 80),
        padding: CGFloat = 14
    ) -> CGRect {
        let bounds = snapshot.cropRect.gscIntegralStandardized
        let clampedSize = CGSize(
            width: min(size.width, bounds.width),
            height: min(size.height, bounds.height)
        )

        for direction in preferredDirections {
            let rect = textRect(near: anchor, direction: direction, size: clampedSize, padding: padding).gscIntegralStandardized

            if bounds.contains(rect) {
                return rect
            }
        }

        let fallbackDirection = preferredDirections.first ?? .right
        let fallbackRect = textRect(near: anchor, direction: fallbackDirection, size: clampedSize, padding: padding)

        return CGRect(
            x: min(max(fallbackRect.minX, bounds.minX), bounds.maxX - clampedSize.width),
            y: min(max(fallbackRect.minY, bounds.minY), bounds.maxY - clampedSize.height),
            width: clampedSize.width,
            height: clampedSize.height
        ).gscIntegralStandardized
    }

    private func textRect(near anchor: CGPoint, direction: TextPlacementDirection, size: CGSize, padding: CGFloat) -> CGRect {
        switch direction {
        case .right:
            return CGRect(x: anchor.x + padding, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .below:
            return CGRect(x: anchor.x - size.width / 2, y: anchor.y + padding, width: size.width, height: size.height)
        case .left:
            return CGRect(x: anchor.x - size.width - padding, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        case .above:
            return CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height - padding, width: size.width, height: size.height)
        }
    }

    private func updatedSelection(from ids: [UUID], additive: Bool, toggle: Bool) -> [UUID] {
        if toggle {
            var current = snapshot.selectedAnnotationIDs

            for id in ids {
                if let index = current.firstIndex(of: id) {
                    current.remove(at: index)
                } else {
                    current.append(id)
                }
            }

            return current
        }

        if additive {
            return orderedSelection(from: snapshot.selectedAnnotationIDs + ids)
        }

        return ids
    }

    private func expandedSelectionIDs(for id: UUID) -> [UUID] {
        guard let groupID = annotation(matching: id)?.groupID else {
            return [id]
        }

        return annotationIDs(inGroups: [groupID])
    }

    private func annotationIDs(inGroups groupIDs: Set<UUID>) -> [UUID] {
        snapshot.annotations.compactMap { annotation in
            guard let groupID = annotation.groupID, groupIDs.contains(groupID) else {
                return nil
            }

            return annotation.id
        }
    }

    private func orderedSelection(from ids: [UUID]) -> [UUID] {
        let idSet = Set(ids)
        return snapshot.annotations.compactMap { annotation in
            idSet.contains(annotation.id) ? annotation.id : nil
        }
    }

    private func applySnapshot(_ updatedSnapshot: EditorSnapshot, fitViewportToCrop: Bool) {
        snapshot = updatedSnapshot
        invalidateCanvas()
        updateViewport(publishChange: fitViewportToCrop) {
            let updatedViewport = $0.updatingContentSize(documentCanvasSize, fitToWindow: false)

            guard fitViewportToCrop else {
                return updatedViewport
            }

            if updatedSnapshot.cropRect.gscIntegralStandardized == fullImageRect {
                return updatedViewport.zoomedToFit()
            }

            return updatedViewport.focused(on: updatedSnapshot.cropRect)
        }
    }

    private func updateViewport(publishChange: Bool = true, _ mutation: (EditorViewport) -> EditorViewport) {
        let updatedViewport = mutation(viewport)

        guard updatedViewport != viewport else {
            return
        }

        if publishChange {
            objectWillChange.send()
        }

        viewport = updatedViewport
        invalidateCanvas()
    }

    private func invalidateCanvas() {
        canvasRevision += 1
    }
}

nonisolated private struct EditorExportRenderInput: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let pinnedUIMapElements: [UIMapElement]
    let uiMapOverlayOptions: UIMapOverlayOptions

    init(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions()
    ) {
        self.baseImage = baseImage
        self.snapshot = snapshot
        self.pinnedUIMapElements = pinnedUIMapElements
        self.uiMapOverlayOptions = uiMapOverlayOptions
    }
}

nonisolated private enum EditorExportRenderer {
    static func renderImage(from input: EditorExportRenderInput) async throws -> CGImage {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            guard let image = ScreenshotPresentationRenderer.render(
                baseImage: input.baseImage,
                snapshot: input.snapshot,
                pinnedUIMapElements: input.pinnedUIMapElements,
                uiMapOverlayOptions: input.uiMapOverlayOptions
            ) else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            return image
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func renderPNGData(from input: EditorExportRenderInput) async throws -> Data {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            guard let image = ScreenshotPresentationRenderer.render(
                baseImage: input.baseImage,
                snapshot: input.snapshot,
                pinnedUIMapElements: input.pinnedUIMapElements,
                uiMapOverlayOptions: input.uiMapOverlayOptions
            ) else {
                throw ImageExportError.encodingFailed
            }

            try Task.checkCancellation()
            return try ImageExporter.pngData(for: image)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
