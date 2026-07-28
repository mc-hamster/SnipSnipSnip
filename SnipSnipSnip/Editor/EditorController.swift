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
    var statusMarkSymbol: String?
    var statusMarkVisualStyle: String?

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
        statusMarkSymbol = style.statusMarkSymbol.rawValue
        statusMarkVisualStyle = style.statusMarkVisualStyle.rawValue
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
            freehandSimplification: CGFloat(freehandSimplification ?? 1.5),
            statusMarkSymbol: StatusMarkSymbol(rawValue: statusMarkSymbol ?? "checkmark") ?? .checkmark,
            statusMarkVisualStyle: StatusMarkVisualStyle(rawValue: statusMarkVisualStyle ?? "outlined") ?? .outlined
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

enum EditorCanvasInvalidationReason: Equatable {
    case full
    case viewport
    case cropPreview
    case cropChrome
    case uiMapOverlay
    case uiMapHover

    var invalidatesStableContent: Bool {
        self == .full || self == .viewport
    }
}

@MainActor
final class EditorController: ObservableObject {
    /// A stable lifetime token used to route asynchronous capture results.
    let documentGenerationID = UUID()
    nonisolated static let maximumHistorySnapshotCount = 100

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
    @Published var workspaceMode: EditorWorkspaceMode = .edit {
        didSet {
            guard workspaceMode != oldValue else {
                return
            }

            if workspaceMode == .presentation {
                clearTransientToolState()
                if activeTool != .select {
                    activeTool = .select
                }
            }

            invalidateCanvas()
        }
    }
    @Published private(set) var workflowResumeState: ScreenshotWorkflowResumeState
    @Published var errorMessage: String? {
        didSet {
            if let errorMessage, errorMessage != oldValue {
                AppAccessibility.announce("Editor error: \(errorMessage)", priority: .high)
            }
        }
    }
    @Published private(set) var notice: EditorNotice?
    var noticeMessage: String? { notice?.message }
    var editorSingleKeyToolShortcutsEnabled = true
    @Published private(set) var toolStyles: [EditorTool: AnnotationStyle]
    @Published private(set) var canvasRevision = 0
    private(set) var canvasInvalidationReason: EditorCanvasInvalidationReason = .full
    @Published var ocrReviewText: String?
    @Published var isRecognizingOCR = false
    @Published private(set) var imageColorSamplingTarget: ImageColorSamplingTarget?
    @Published private(set) var previewedImageSampleColor: RGBAColor?
    @Published var cropAspectRatioPreset: CropAspectRatioPreset = .freeform
    private(set) var viewport: EditorViewport
    @Published var persistenceRevision = 0
    @Published private(set) var cropOutsideOverlayAlpha: CGFloat = AppPreferenceDefaults.editorCropOutsideOverlayAlpha
    @Published private(set) var outOfCapturePatternSettings: EditorOutOfCapturePatternSettings = .default
    @Published var selectedUIMapElementID: UUID?
    @Published private(set) var hoveredUIMapElementID: UUID?
    @Published var showsAllUIMapElements = false {
        didSet {
            invalidateCanvas(.uiMapOverlay)
        }
    }
    @Published var uiMapOverlayOptions = UIMapOverlayOptions() {
        didSet {
            invalidateCanvas()
        }
    }
    @Published private(set) var isProcessingUIMap = false
    @Published private(set) var capture: CapturedScreenshot
    /// The immutable document-level capture remains stable while item and
    /// whole-composition editing temporarily project another image into the
    /// existing annotation canvas.
    private(set) var documentCapture: CapturedScreenshot
    @Published private(set) var compositionEditingScope: CompositionEditingScope = .layout
    @Published var compositionFramingItemID: UUID?
    @Published private(set) var hoveredCompositionItemID: UUID?

    func setHoveredCompositionItem(_ itemID: UUID?) {
        guard hoveredCompositionItemID != itemID else {
            return
        }
        hoveredCompositionItemID = itemID
    }

    @Published private(set) var compositionCanvasFocusRequestRevision = 0
    @Published private(set) var isPrivateDocument: Bool
    /// The on-disk source version, used to require an explicit migration
    /// choice before overwriting a legacy package.
    @Published private(set) var sourceDocumentFormatVersion: Int
    let compositionAssetRepository: CompositionAssetRepository
    @Published var presentationTemplates: [PresentationTemplate] = PresentationTemplate.builtInTemplates
    @Published private(set) var compositionTemplates: [CompositionTemplate] = CompositionTemplateStore.builtInTemplates
    @Published var presentationInspectorTab: PresentationInspectorTab = .style
    @Published var compositionInspectorScrollPosition: String?
    @Published var compositionComparisonPreviewPhase: CompositionComparisonPhase?
    @Published private(set) var compositionRegistrationOutcome: CompositionRegistrationOutcome?
    @Published var isCompositionBlinkPreviewPlaying = true
    @Published var defaultPresentationTemplateID: String?
    @Published var presentationScenesRootURL: URL = PresentationSceneStore.defaultRootURL
    @Published var presentationScenes: [PresentationSceneDefinition] = []
    @Published var presentationSceneDiagnostics: [PresentationSceneDiagnostic] = []
    @Published var savedPresentations: [SavedPresentation] = []
    @Published private(set) var presentationContentRevision = 0
    var presentationContentCache: (
        revision: Int,
        targetMaximumPixelDimension: Int?,
        comparisonPhase: CompositionComparisonPhase,
        image: CGImage
    )?

    private let textRecognizer: any CaptureTextRecognizing
    private let initialSnapshot: EditorSnapshot
    let defaults: UserDefaults
    let capabilities: AppCapabilitySnapshot
    var toolbarToolActivationHandler: ((EditorTool) -> Void)?
    private var preferredRedactionMode: RedactionMode

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var hasTruncatedUndoHistory = false
    private var textEditingSession: TextEditingSession?
    private var pendingTextEditingCommitTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var imageColorSamplingSourceTool: EditorTool?
    private var compositionEditingRootState: ScreenshotEditState?
    private var compositionEditingLayout: CompositionRenderLayout?
    private var compositionEditingLogicalCanvasSize: CGSize?
    private var compositionEditingReturnViewport: EditorViewport?
    private var compositionEditingReturnInspectorTab: PresentationInspectorTab?
    private var compositionEditingReturnInspectorScrollPosition: String?
    /// Each nested operation keeps its own rollback point. Only the outermost
    /// successful operation writes undo history, while a failed inner import
    /// can roll back just its partial edits without discarding earlier valid
    /// items in the same batch.
    private var coalescedGestureInitialSnapshots: [EditorSnapshot] = []

    private var documentCanvasSize: CGSize {
        CGSize(width: capture.image.width, height: capture.image.height)
    }

    private var fullImageRect: CGRect {
        CGRect(origin: .zero, size: documentCanvasSize)
    }

    private static func embeddingDormantComposition(
        in snapshot: EditorSnapshot,
        capture: CapturedScreenshot,
        assetID: UUID,
        itemID: UUID
    ) -> EditorSnapshot {
        guard snapshot.composition == nil else {
            return snapshot
        }
        let item = CompositionItem(
            id: itemID,
            assetID: assetID,
            editState: ScreenshotEditState(
                cropRect: snapshot.cropRect,
                annotations: snapshot.annotations,
                selectedAnnotationIDs: snapshot.selectedAnnotationIDs,
                nextCalloutNumber: snapshot.nextCalloutNumber,
                pinnedUIMapElementIDs: snapshot.pinnedUIMapElementIDs
            ),
            title: capture.sourceName,
            accessibilityLabel: capture.sourceName
        )
        var updated = snapshot
        updated.composition = CompositionSnapshot(
            items: [item],
            selectedItemIDs: [item.id],
            isActivated: false,
            layout: CompositionLayoutConfiguration(mode: .auto),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        return updated
    }

    /// Intent-created Steps and Collection documents are composition content
    /// from their first source, even though they contain only one item. Apply
    /// that initial state before the document session is constructed so it
    /// does not create a synthetic undo entry or dirty transition.
    private static func configuringInitialComposition(
        in snapshot: EditorSnapshot,
        for purpose: ScreenshotDocumentPurpose
    ) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        switch purpose {
        case .screenshot, .comparison:
            // A one-item Comparison is an explicit awaiting-After state. Keep
            // its layout dormant because Compare geometry requires two items.
            return snapshot
        case .steps:
            composition.layout.mode = .steps
            composition.isActivated = true
        case .collection:
            composition.layout.mode = .auto
            composition.isActivated = true
        }
        var updated = snapshot
        updated.composition = composition
        return updated
    }

    deinit {
        pendingTextEditingCommitTask?.cancel()
        pendingTextEditingCommitTask = nil
        noticeTask?.cancel()
    }

    init(
        capture: CapturedScreenshot,
        defaults: UserDefaults = .standard,
        capabilities: AppCapabilitySnapshot,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        isPrivateDocument: Bool = false,
        documentPurpose: ScreenshotDocumentPurpose = .screenshot,
        workflowResumeState: ScreenshotWorkflowResumeState? = nil,
        sourceDocumentFormatVersion: Int = SSSDocumentPackage.formatVersion,
        compositionStoredAssets: [CompositionStoredAsset] = []
    ) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.preferredRedactionMode = defaults.string(forKey: EditorPreferenceKey.lastRedactionMode)
            .flatMap(RedactionMode.init(rawValue:)) ?? .blur
        self.capture = capture
        self.documentCapture = capture
        self.isPrivateDocument = isPrivateDocument
        self.sourceDocumentFormatVersion = sourceDocumentFormatVersion
        let compositionAssetRepository = CompositionAssetRepository(
            storedAssets: compositionStoredAssets
        )
        self.compositionAssetRepository = compositionAssetRepository
        self.textRecognizer = textRecognizer
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.presentationScenesRootURL = PresentationSceneStore.configuredRootURL(in: defaults)
        self.compositionComparisonPreviewPhase = nil
        let capturedCursorAnnotation = capture.cursorOverlay.map {
            Annotation.makeImageOverlay(image: $0.image, in: $0.rect, role: .capturedCursor)
        }
        let initialAnnotations = capturedCursorAnnotation.map { [$0] } ?? []
        let baseSnapshot = EditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(
                    width: capture.image.width,
                    height: capture.image.height
                )
            ),
            annotations: initialAnnotations,
            selectedAnnotationIDs: [],
            nextCalloutNumber: 1,
            // A new capture always opens as the content the user captured.
            // Legacy default looks remain available in Polish, but are never
            // applied before the user explicitly enters that stage.
            presentation: .plain,
            documentPurpose: documentPurpose
        )
        let embeddedDocumentSnapshot: EditorSnapshot
        if baseSnapshot.composition == nil,
           let assetID = try? compositionAssetRepository.add(
               capture: capture,
               isPrivate: isPrivateDocument
           ) {
            embeddedDocumentSnapshot = Self.embeddingDormantComposition(
                in: baseSnapshot,
                capture: capture,
                assetID: assetID,
                itemID: UUID()
            )
        } else {
            embeddedDocumentSnapshot = baseSnapshot
        }
        let initialDocumentSnapshot = Self.configuringInitialComposition(
            in: embeddedDocumentSnapshot,
            for: documentPurpose
        )
        let session = EditorDocumentSession(
            initialSnapshot: initialDocumentSnapshot,
            currentSnapshot: initialDocumentSnapshot,
            undoStack: [],
            redoStack: [],
            toolStyles: Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { ($0, AnnotationStyle.default(for: $0)) }),
            savedPresentations: []
        )
        self.initialSnapshot = session.initialSnapshot
        self.snapshot = session.currentSnapshot
        self.workflowResumeState = (
            workflowResumeState ?? ScreenshotWorkflowResumeState.inferred(
                for: initialDocumentSnapshot.documentPurpose,
                composition: initialDocumentSnapshot.composition
            )
        ).normalized(
            for: initialDocumentSnapshot.documentPurpose,
            composition: initialDocumentSnapshot.composition
        )
        self.toolStyles = Self.loadPersistedToolStyles(from: defaults, fallback: session.toolStyles)
        let documentCanvasSize = CGSize(width: capture.image.width, height: capture.image.height)
        self.viewport = EditorViewport(contentSize: documentCanvasSize)
        reloadCompositionTemplateLibrary()
        reloadPresentationTemplateLibrary()
        reloadPresentationScenes()
    }

    init(
        capture: CapturedScreenshot,
        session: EditorDocumentSession,
        defaults: UserDefaults = .standard,
        capabilities: AppCapabilitySnapshot,
        textRecognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer(),
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        isPrivateDocument: Bool = false,
        workflowResumeState: ScreenshotWorkflowResumeState? = nil,
        sourceDocumentFormatVersion: Int = SSSDocumentPackage.formatVersion,
        compositionStoredAssets: [CompositionStoredAsset] = []
    ) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.preferredRedactionMode = defaults.string(forKey: EditorPreferenceKey.lastRedactionMode)
            .flatMap(RedactionMode.init(rawValue:)) ?? .blur
        self.capture = capture
        self.documentCapture = capture
        self.isPrivateDocument = isPrivateDocument
        self.sourceDocumentFormatVersion = sourceDocumentFormatVersion
        let compositionAssetRepository = CompositionAssetRepository(
            storedAssets: compositionStoredAssets
        )
        self.compositionAssetRepository = compositionAssetRepository
        self.textRecognizer = textRecognizer
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.presentationScenesRootURL = PresentationSceneStore.configuredRootURL(in: defaults)
        self.compositionComparisonPreviewPhase = nil
        let loadedUndoHistoryWasTruncated =
            session.hasTruncatedUndoHistory
            || session.undoStack.count > Self.maximumHistorySnapshotCount
        let canonicalSession: EditorDocumentSession
        if session.currentSnapshot.composition == nil,
           let assetID = try? compositionAssetRepository.add(
               capture: capture,
               isPrivate: isPrivateDocument
           ) {
            let itemID = UUID()
            canonicalSession = EditorDocumentSession(
                initialSnapshot: Self.embeddingDormantComposition(
                    in: session.initialSnapshot,
                    capture: capture,
                    assetID: assetID,
                    itemID: itemID
                ),
                currentSnapshot: Self.embeddingDormantComposition(
                    in: session.currentSnapshot,
                    capture: capture,
                    assetID: assetID,
                    itemID: itemID
                ),
                undoStack: session.undoStack
                    .suffix(Self.maximumHistorySnapshotCount)
                    .map {
                        Self.embeddingDormantComposition(
                            in: $0,
                            capture: capture,
                            assetID: assetID,
                            itemID: itemID
                        )
                    },
                redoStack: session.redoStack
                    .suffix(Self.maximumHistorySnapshotCount)
                    .map {
                        Self.embeddingDormantComposition(
                            in: $0,
                            capture: capture,
                            assetID: assetID,
                            itemID: itemID
                        )
                },
                toolStyles: session.toolStyles,
                savedPresentations: session.savedPresentations,
                hasTruncatedUndoHistory: loadedUndoHistoryWasTruncated
            )
        } else {
            canonicalSession = session
        }
        self.initialSnapshot = canonicalSession.initialSnapshot
        self.snapshot = canonicalSession.currentSnapshot
        self.workflowResumeState = (
            workflowResumeState ?? ScreenshotWorkflowResumeState.inferred(
                for: canonicalSession.currentSnapshot.documentPurpose,
                composition: canonicalSession.currentSnapshot.composition
            )
        ).normalized(
            for: canonicalSession.currentSnapshot.documentPurpose,
            composition: canonicalSession.currentSnapshot.composition
        )
        self.hasTruncatedUndoHistory = loadedUndoHistoryWasTruncated
        self.undoStack = Array(
            canonicalSession.undoStack.suffix(Self.maximumHistorySnapshotCount)
        )
        self.redoStack = Array(
            canonicalSession.redoStack.suffix(Self.maximumHistorySnapshotCount)
        )
        self.toolStyles = session.toolStyles
        self.savedPresentations = session.savedPresentations
        let documentCanvasSize = CGSize(width: capture.image.width, height: capture.image.height)
        self.viewport = EditorViewport(contentSize: documentCanvasSize)
        pruneUnreferencedCompositionAssets()
        reloadCompositionTemplateLibrary()
        reloadPresentationTemplateLibrary()
        reloadPresentationScenes()
    }

    /// Replaces the derived template library while keeping its published
    /// storage read-only to editor clients.
    func replaceCompositionTemplateLibrary(_ templates: [CompositionTemplate]) {
        compositionTemplates = templates
    }

    var canUndo: Bool {
        !undoStack.isEmpty
            || (!hasTruncatedUndoHistory
                && canonicalCompositionEditingSnapshot(snapshot) != initialSnapshot)
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    var selectedAnnotations: [Annotation] {
        let idSet = Set(snapshot.selectedAnnotationIDs)
        return snapshot.annotations.filter { idSet.contains($0.id) }
    }

    var containsRedactions: Bool {
        if snapshot.annotations.contains(where: { $0.redactionMode != nil }) {
            return true
        }
        guard let composition = snapshot.composition else {
            return false
        }
        return composition.canvas.annotations.contains { $0.redactionMode != nil }
            || composition.items.contains { item in
                item.editState.annotations.contains { $0.redactionMode != nil }
            }
    }

    var requiresDocumentFormatMigration: Bool {
        sourceDocumentFormatVersion < SSSDocumentPackage.formatVersion
    }

    var documentPurpose: ScreenshotDocumentPurpose {
        snapshot.documentPurpose
    }

    var workflowStage: ScreenshotWorkflowStage {
        workflowResumeState.stage
    }

    /// Updates purpose and optional layout through the regular command
    /// pipeline. Callers that append a first additional capture should wrap
    /// the append and this call in the existing coalesced gesture transaction
    /// so both changes undo together.
    func setDocumentPurpose(
        _ purpose: ScreenshotDocumentPurpose,
        layoutMode: CompositionLayoutMode? = nil
    ) {
        execute(
            SetDocumentPurposeCommand(
                purpose: purpose,
                layoutMode: layoutMode
            )
        )
    }

    /// Restores package/recovery navigation without adding undo history or
    /// changing the persisted-content revision used for dirty tracking.
    func setWorkflowResumeState(_ state: ScreenshotWorkflowResumeState) {
        let normalized = state.normalized(
            for: documentPurpose,
            composition: snapshot.composition
        )
        guard normalized != workflowResumeState else {
            return
        }
        workflowResumeState = normalized
    }

    func setWorkflowStage(_ stage: ScreenshotWorkflowStage) {
        setWorkflowResumeState(ScreenshotWorkflowResumeState(stage: stage))
    }

    func enterPolish() {
        guard workflowResumeState.stage != .polishing else {
            return
        }
        let returnStage = workflowResumeState.stage.isCompatible(
            with: documentPurpose
        ) ? workflowResumeState.stage : ScreenshotWorkflowResumeState.inferred(
            for: documentPurpose,
            composition: snapshot.composition
        ).stage
        setWorkflowResumeState(
            ScreenshotWorkflowResumeState(
                stage: .polishing,
                returnStage: returnStage
            )
        )
    }

    func leavePolish() {
        guard workflowResumeState.stage == .polishing else {
            return
        }
        let destination = workflowResumeState.returnStage
            ?? ScreenshotWorkflowResumeState.inferred(
                for: documentPurpose,
                composition: snapshot.composition
            ).stage
        setWorkflowStage(destination)
    }

    /// Restores transient navigation after opening a package or recovery
    /// checkpoint. Workflow stage is persisted separately from editable
    /// content, so installing a controller must explicitly re-enter the
    /// matching workspace without creating undo or dirty-state changes.
    func restoreWorkflowWorkspace() {
        switch workflowStage {
        case .polishing:
            presentationInspectorTab =
                snapshot.presentation.scene == nil ? .style : .scene
            setWorkspaceMode(.presentation)
        case .editing, .awaitingComparisonAfter:
            presentationInspectorTab = .layout
            setWorkspaceMode(.edit)
        case .collecting, .arranging, .reviewingComparison:
            presentationInspectorTab = .layout
            setWorkspaceMode(.presentation)
        }
    }

    func markDocumentPrivate() {
        guard !isPrivateDocument else {
            return
        }

        isPrivateDocument = true
        persistenceRevision += 1
        invalidateCanvas(.cropChrome)
    }

    func markDocumentSavedInCurrentFormat() {
        sourceDocumentFormatVersion = SSSDocumentPackage.formatVersion
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

    var hasSelection: Bool {
        selectedCount > 0 || selectedUIMapElementID != nil
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

        return snapshot.pinnedUIMapElementIDs.compactMap { id in
            guard var element = uiMapSnapshot.element(matching: id) else {
                return nil
            }

            let hierarchy = uiMapSnapshot.parentHierarchy(for: id)
                .map(\.displayName)
                .joined(separator: " > ")
            element.overlayParentHierarchy = hierarchy.isEmpty ? nil : hierarchy
            return element
        }
    }

    var isInspectingUIMap: Bool {
        capabilities.isEnabled(.uiMap)
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

    var showsStatusMarkControls: Bool {
        selectedAnnotation?.editorTool == .statusMark || (selectedAnnotation == nil && activeTool == .statusMark)
    }

    var showsCalloutControls: Bool {
        selectedAnnotation?.editorTool == .callout || (selectedAnnotation == nil && activeTool == .callout)
    }

    var showsCropControls: Bool {
        compositionEditingScope != .composition
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
        snapshot.presentation
    }

    var presentationBackgroundColor: RGBAColor {
        switch snapshot.presentation.background {
        case .transparent:
            return RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
        case let .solid(color):
            return color
        case let .twoColorGradient(start, _):
            return start
        case let .radialSpotlight(base, _):
            return base
        case let .blurredScreenshot(tint):
            return tint
        }
    }

    var requiresPNGForFaithfulExport: Bool {
        snapshot.presentation.requiresPNGForFaithfulExport
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
            currentSnapshot: canonicalCompositionEditingSnapshot(snapshot),
            undoStack: undoStack,
            redoStack: redoStack,
            toolStyles: toolStyles,
            savedPresentations: savedPresentations,
            hasTruncatedUndoHistory: hasTruncatedUndoHistory
        )
    }

    var editableDocument: EditableScreenshotDocument {
        EditableScreenshotDocument(
            capture: documentCapture,
            session: documentSession,
            compositionStoredAssets: compositionAssetRepository.storedAssets(
                referencedBy: documentSession.referencedCompositionAssetIDs
            ),
            workflowResumeState: workflowResumeState,
            isPrivate: isPrivateDocument,
            sourceFormatVersion: sourceDocumentFormatVersion
        )
    }

    func execute(_ command: DocumentCommand, undoable: Bool = true) {
        commitPendingTextEdits()

        let previousSnapshot = canonicalCompositionEditingSnapshot(snapshot)
        let updatedSnapshot = canonicalCompositionEditingSnapshot(command.apply(to: snapshot))

        guard updatedSnapshot != previousSnapshot else {
            return
        }

        var shouldPruneCompositionAssets = false
        if undoable, coalescedGestureInitialSnapshots.isEmpty {
            shouldPruneCompositionAssets = appendUndoSnapshot(previousSnapshot)
                || !redoStack.isEmpty
            redoStack.removeAll()
        }

        let invalidationReason = previousSnapshot.isPresentationOnlyChange(to: updatedSnapshot)
            ? EditorCanvasInvalidationReason.cropChrome
            : .full
        applySnapshot(
            updatedSnapshot,
            fitViewportToCrop: projectedCompositionEditingSnapshot(updatedSnapshot).cropRect
                != projectedCompositionEditingSnapshot(previousSnapshot).cropRect,
            invalidationReason: invalidationReason,
            canonicalizesCompositionEditingChanges: false
        )
        if coalescedGestureInitialSnapshots.isEmpty {
            if shouldPruneCompositionAssets {
                pruneUnreferencedCompositionAssets()
            }
            persistenceRevision += 1
        }
    }

    @discardableResult
    private func appendUndoSnapshot(_ snapshot: EditorSnapshot) -> Bool {
        undoStack.append(snapshot)
        let overflow = undoStack.count - Self.maximumHistorySnapshotCount
        guard overflow > 0 else {
            return false
        }

        undoStack.removeFirst(overflow)
        hasTruncatedUndoHistory = true
        return true
    }

    @discardableResult
    private func appendRedoSnapshot(_ snapshot: EditorSnapshot) -> Bool {
        redoStack.append(snapshot)
        let overflow = redoStack.count - Self.maximumHistorySnapshotCount
        if overflow > 0 {
            redoStack.removeFirst(overflow)
            return true
        }
        return false
    }

    private func pruneUnreferencedCompositionAssets() {
        let referencedAssetIDs = EditorDocumentSession(
            initialSnapshot: initialSnapshot,
            currentSnapshot: canonicalCompositionEditingSnapshot(snapshot),
            undoStack: undoStack,
            redoStack: redoStack,
            toolStyles: [:]
        ).referencedCompositionAssetIDs
        let unreferencedAssetIDs = Set(compositionAssetRepository.assetIDs)
            .subtracting(referencedAssetIDs)
        compositionAssetRepository.removeAssets(unreferencedAssetIDs)
    }

    func beginCoalescedEditorGesture() {
        commitPendingTextEdits()
        coalescedGestureInitialSnapshots.append(
            canonicalCompositionEditingSnapshot(snapshot)
        )
    }

    func endCoalescedEditorGesture() {
        guard let initial = coalescedGestureInitialSnapshots.popLast() else {
            return
        }
        guard coalescedGestureInitialSnapshots.isEmpty else {
            return
        }
        let current = canonicalCompositionEditingSnapshot(snapshot)
        guard current != initial else {
            return
        }
        let shouldPruneCompositionAssets = appendUndoSnapshot(initial)
            || !redoStack.isEmpty
        redoStack.removeAll()
        if shouldPruneCompositionAssets {
            pruneUnreferencedCompositionAssets()
        }
        persistenceRevision += 1
    }

    func cancelCoalescedEditorGesture() {
        guard let initial = coalescedGestureInitialSnapshots.popLast() else {
            return
        }
        applySnapshot(
            initial,
            fitViewportToCrop: false,
            canonicalizesCompositionEditingChanges: false
        )
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

    func resizeSelectedAnnotations(widthDelta: CGFloat, heightDelta: CGFloat, minimumSize: CGFloat = 4) {
        guard let oldBounds = selectionBoundingRect, !selectedAnnotations.isEmpty else {
            return
        }

        let newBounds = CGRect(
            x: oldBounds.minX,
            y: oldBounds.minY,
            width: max(minimumSize, oldBounds.width + widthDelta),
            height: max(minimumSize, oldBounds.height + heightDelta)
        )
        updateAnnotations(selectedAnnotations.map { $0.scaled(from: oldBounds, to: newBounds) })
    }

    func duplicateSelectedAnnotations(offset: CGSize = CGSize(width: 10, height: 10)) {
        guard !selectedAnnotations.isEmpty else {
            return
        }

        let duplicates = selectedAnnotations.map { annotation in
            let translated = annotation.translated(by: offset)
            return Annotation(
                id: UUID(),
                groupID: nil,
                kind: translated.kind,
                style: translated.style,
                rotationDegrees: translated.rotationDegrees
            )
        }
        for duplicate in duplicates {
            execute(AddAnnotationCommand(annotation: duplicate))
        }
        execute(SetSelectionCommand(annotationIDs: duplicates.map(\.id)), undoable: false)
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

    func clearSelection() {
        guard !snapshot.selectedAnnotationIDs.isEmpty || selectedUIMapElementID != nil else {
            return
        }

        if selectedUIMapElementID != nil {
            selectedUIMapElementID = nil
        }
        execute(SetSelectionCommand(annotationIDs: []), undoable: false)
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

    func autoCropCurrentCrop() {
        autoCropCurrentCrop(padding: 0)
    }

    func autoCropCurrentCropWithPadding() {
        autoCropCurrentCrop(padding: AutoCropOptions.paddedCropPadding)
    }

    private func autoCropCurrentCrop(padding: CGFloat) {
        let currentCrop = snapshot.cropRect.gscIntegralStandardized
        let requiredBounds = gscBoundingRect(of: snapshot.annotations.compactMap { annotation in
            let bounds = annotation.boundingRect.gscIntegralStandardized
            return bounds.intersects(currentCrop) ? bounds : nil
        })
        let resolvedRequiredBounds = requiredBounds.isNull || requiredBounds.isEmpty ? nil : requiredBounds

        guard let tightenedCrop = AutoCropAnalyzer.tightenedCropRect(
            baseImage: capture.image,
            currentCrop: currentCrop,
            requiredBounds: resolvedRequiredBounds,
            options: AutoCropOptions(padding: padding)
        ) else {
            showNotice("Auto Crop couldn't find anything to tighten.")
            return
        }

        execute(SetCropCommand(rect: tightenedCrop))
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

        applySnapshot(updatedSnapshot, fitViewportToCrop: false, invalidationReason: .cropPreview)
    }

    func commitPreviewedCropRect(_ rect: CGRect, originalRect: CGRect) {
        let finalRect = rect.gscIntegralStandardized
        let initialRect = originalRect.gscIntegralStandardized

        guard finalRect != initialRect else {
            let restoredSnapshot = SetCropCommand(rect: initialRect).apply(to: snapshot)
            if restoredSnapshot != snapshot {
                applySnapshot(restoredSnapshot, fitViewportToCrop: false, invalidationReason: .cropPreview)
            }
            return
        }

        let originalSnapshot = SetCropCommand(rect: initialRect).apply(to: snapshot)
        let committedSnapshot = SetCropCommand(rect: finalRect).apply(to: snapshot)
        applySnapshot(committedSnapshot, fitViewportToCrop: true)
        let shouldPruneCompositionAssets =
            appendUndoSnapshot(canonicalCompositionEditingSnapshot(originalSnapshot))
            || !redoStack.isEmpty
        redoStack.removeAll()
        if shouldPruneCompositionAssets {
            pruneUnreferencedCompositionAssets()
        }
        persistenceRevision += 1
    }

    func updateText(_ text: String) {
        guard let annotation = selectedAnnotation, annotation.isTextEditable else {
            return
        }

        beginTextEditingSessionIfNeeded(for: annotation.id)

        let updatedAnnotation: Annotation
        if case let .text(shape) = annotation.kind, shape.automaticallySizesToText {
            updatedAnnotation = annotation.updatingText(
                text,
                maximumAutoTextWidth: maximumAutoTextWidth(for: shape),
                autoTextBounds: snapshot.cropRect
            )
        } else if case let .callout(shape) = annotation.kind, shape.automaticallySizesToText {
            updatedAnnotation = annotation.updatingText(
                text,
                maximumAutoTextWidth: maximumAutoCalloutWidth(for: shape),
                autoTextBounds: snapshot.cropRect
            )
        } else {
            updatedAnnotation = annotation.updatingText(text)
        }
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
            .updatingText(
                seedText,
                maximumAutoTextWidth: gscAutoTextMaxWidth(
                    originX: textRect.minX,
                    within: snapshot.cropRect,
                    minWidth: 44
                ),
                autoTextBounds: snapshot.cropRect
            )

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

    func updateStatusMarkSymbol(_ value: StatusMarkSymbol) {
        mutateStyle { $0.statusMarkSymbol = value }
    }

    func updateStatusMarkVisualStyle(_ value: StatusMarkVisualStyle) {
        mutateStyle { $0.statusMarkVisualStyle = value }
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
        if workspaceMode == .presentation {
            setWorkspaceMode(.edit)
        }

        if tool == .crop, compositionEditingScope == .composition {
            activeTool = .select
            showNotice("Use Layout canvas size and trim controls for the whole composition.")
            return
        }

        if tool == .blur {
            selectedUIMapElementID = nil
            hoveredUIMapElementID = nil
            activeTool = preferredRedactionMode.editorTool
            toolbarToolActivationHandler?(activeTool)
            invalidateCanvas()
            return
        }

        clearTransientToolState(clearUIMapSelection: false)

        if tool == .uiMapInspect {
            guard capabilities.isEnabled(.uiMap), uiMapSnapshot != nil else {
                activeTool = .select
                selectedUIMapElementID = nil
                hoveredUIMapElementID = nil
                toolbarToolActivationHandler?(activeTool)
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
        toolbarToolActivationHandler?(activeTool)
        invalidateCanvas()
    }

    private func clearTransientToolState(clearUIMapSelection: Bool = true) {
        imageColorSamplingTarget = nil
        imageColorSamplingSourceTool = nil
        previewedImageSampleColor = nil

        if clearUIMapSelection {
            selectedUIMapElementID = nil
            hoveredUIMapElementID = nil
        }
    }

    func beginImageColorSampling(_ target: ImageColorSamplingTarget) {
        if workspaceMode == .presentation {
            setWorkspaceMode(.edit)
        }

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
        if workspaceMode == .presentation {
            setWorkspaceMode(.edit)
        }

        storePreferredRedactionMode(mode)

        if !selectedRedactions.isEmpty {
            updateAnnotations(selectedRedactions.map { $0.updatingRedactionMode(mode) })
            return
        }

        activeTool = mode.editorTool
    }

    func undo() {
        commitPendingTextEdits()
        let priorPurpose = documentPurpose
        let priorStage = workflowStage

        if let previous = undoStack.popLast() {
            let shouldPruneCompositionAssets =
                appendRedoSnapshot(canonicalCompositionEditingSnapshot(snapshot))
            applySnapshot(
                previous,
                fitViewportToCrop: projectedCompositionEditingSnapshot(previous).cropRect
                    != snapshot.cropRect,
                canonicalizesCompositionEditingChanges: false
            )
            restoreWorkflowWorkspaceAfterHistoryNavigation(
                priorPurpose: priorPurpose,
                priorStage: priorStage
            )
            if shouldPruneCompositionAssets {
                pruneUnreferencedCompositionAssets()
            }
            persistenceRevision += 1
            return
        }

        guard !hasTruncatedUndoHistory, snapshot != initialSnapshot else {
            return
        }

        let shouldPruneCompositionAssets =
            appendRedoSnapshot(canonicalCompositionEditingSnapshot(snapshot))
        applySnapshot(
            initialSnapshot,
            fitViewportToCrop: projectedCompositionEditingSnapshot(initialSnapshot).cropRect
                != snapshot.cropRect,
            canonicalizesCompositionEditingChanges: false
        )
        restoreWorkflowWorkspaceAfterHistoryNavigation(
            priorPurpose: priorPurpose,
            priorStage: priorStage
        )
        if shouldPruneCompositionAssets {
            pruneUnreferencedCompositionAssets()
        }
        persistenceRevision += 1
    }

    func redo() {
        commitPendingTextEdits()
        let priorPurpose = documentPurpose
        let priorStage = workflowStage

        guard let next = redoStack.popLast() else {
            return
        }

        let shouldPruneCompositionAssets =
            appendUndoSnapshot(canonicalCompositionEditingSnapshot(snapshot))
        applySnapshot(
            next,
            fitViewportToCrop: projectedCompositionEditingSnapshot(next).cropRect
                != snapshot.cropRect,
            canonicalizesCompositionEditingChanges: false
        )
        restoreWorkflowWorkspaceAfterHistoryNavigation(
            priorPurpose: priorPurpose,
            priorStage: priorStage
        )
        if shouldPruneCompositionAssets {
            pruneUnreferencedCompositionAssets()
        }
        persistenceRevision += 1
    }

    private func restoreWorkflowWorkspaceAfterHistoryNavigation(
        priorPurpose: ScreenshotDocumentPurpose,
        priorStage: ScreenshotWorkflowStage
    ) {
        guard compositionEditingScope == .layout,
              documentPurpose != priorPurpose || workflowStage != priorStage else {
            return
        }
        restoreWorkflowWorkspace()
    }

    func updateViewportCanvasSize(_ size: CGSize) {
        guard viewport.canvasSize != size else {
            return
        }

        updateViewport(publishChange: false, invalidationReason: .viewport) {
            $0.updatingCanvasSize(size)
        }
    }

    func updatePresentationViewportContentSize(_ size: CGSize) {
        guard workspaceMode == .presentation else {
            return
        }

        guard viewport.contentSize != size else {
            return
        }

        updateViewport(invalidationReason: .cropChrome) {
            $0.updatingContentSize(size, fitToWindow: false)
        }
    }

    func restoreEditViewportContentSize() {
        guard viewport.contentSize != documentCanvasSize else {
            return
        }

        updateViewport(invalidationReason: .cropChrome) {
            $0.updatingContentSize(documentCanvasSize, fitToWindow: false)
        }
    }

    func zoomIn() {
        updateViewport(invalidationReason: .viewport) { $0.zoomed(to: $0.zoomScale * 1.25) }
    }

    func zoomOut() {
        updateViewport(invalidationReason: .viewport) { $0.zoomed(to: $0.zoomScale / 1.25) }
    }

    func zoomToFit() {
        updateViewport(invalidationReason: .viewport) { $0.zoomedToFit() }
    }

    func zoomToInitialDisplayScale() {
        updateViewport(invalidationReason: .viewport) {
            guard workspaceMode != .presentation else {
                return $0.zoomedForInitialDisplay(maxDisplayScale: EditorViewport.maxInitialDisplayScale)
            }

            let updatedViewport = $0.updatingContentSize(documentCanvasSize, fitToWindow: false)

            guard snapshot.cropRect.gscIntegralStandardized != fullImageRect else {
                return updatedViewport.zoomedForInitialDisplay(maxDisplayScale: EditorViewport.maxInitialDisplayScale)
            }

            return updatedViewport.focused(on: snapshot.cropRect)
        }
    }

    func zoomToActualSize() {
        updateViewport(invalidationReason: .viewport) { $0.zoomed(to: $0.actualSizeZoomScale) }
    }

    func magnifyViewport(by magnification: CGFloat, anchoredAt anchor: CGPoint) {
        let factor = max(0.05, 1 + magnification)
        updateViewport(invalidationReason: .viewport) { $0.zoomed(to: $0.zoomScale * factor, anchoredAt: anchor) }
    }

    func zoomViewportFromScrollWheel(deltaY: CGFloat, anchoredAt anchor: CGPoint) {
        guard deltaY != 0 else {
            return
        }

        let factor = pow(1.0018, deltaY)
        updateViewport(invalidationReason: .viewport) { $0.zoomed(to: $0.zoomScale * factor, anchoredAt: anchor) }
    }

    func updateCropOutsideOverlayAlpha(_ alpha: CGFloat) {
        let clampedAlpha = min(max(alpha, 0), 0.9)

        guard cropOutsideOverlayAlpha != clampedAlpha else {
            return
        }

        cropOutsideOverlayAlpha = clampedAlpha
        invalidateCanvas(.cropChrome)
    }

    func updateOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) {
        guard outOfCapturePatternSettings != settings else {
            return
        }

        outOfCapturePatternSettings = settings
        invalidateCanvas()
    }

    func panViewport(by delta: CGSize) {
        updateViewport(invalidationReason: .viewport) { $0.panned(by: delta) }
    }

    func scrollViewport(horizontalPosition: CGFloat? = nil, verticalPosition: CGFloat? = nil) {
        updateViewport(invalidationReason: .viewport) {
            $0.scrolledTo(horizontalPosition: horizontalPosition, verticalPosition: verticalPosition)
        }
    }

    func selectUIMapElement(_ elementID: UUID?) {
        if elementID != nil, !snapshot.selectedAnnotationIDs.isEmpty {
            execute(SetSelectionCommand(annotationIDs: []), undoable: false)
        }

        selectedUIMapElementID = elementID
        invalidateCanvas(.uiMapOverlay)
    }

    func hoverUIMapElement(_ elementID: UUID?) {
        guard hoveredUIMapElementID != elementID else {
            return
        }

        hoveredUIMapElementID = elementID
        invalidateCanvas(.uiMapHover)
    }

    func selectAndTogglePinnedUIMapElement(_ elementID: UUID?) {
        guard let elementID else {
            selectUIMapElement(nil)
            return
        }

        let wasPinned = isUIMapElementPinned(elementID)
        togglePinnedUIMapElement(elementID)

        if wasPinned {
            if hoveredUIMapElementID == elementID {
                hoverUIMapElement(nil)
            }
            selectUIMapElement(nil)
        } else {
            selectUIMapElement(elementID)
        }
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
        switch compositionEditingScope {
        case .item(let itemID):
            if let assetID = snapshot.composition?.items.first(where: { $0.id == itemID })?.assetID {
                try? compositionAssetRepository.replaceUIMap(for: assetID, with: uiMap)
            }
        case .layout:
            documentCapture = documentCapture.attachingUIMap(uiMap)
        case .composition:
            break
        }
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

    func exportedImage(appearance: ScreenshotOutputAppearance) throws -> CGImage {
        try renderExportInput(
            exportRenderInput(
                for: appearance,
                compositionSafetyPolicy: .fail
            )
        )
    }

    func exportedImageForInteractiveUse(
        appearance: ScreenshotOutputAppearance
    ) throws -> CGImage {
        try renderExportInput(
            exportRenderInput(
                for: appearance,
                compositionSafetyPolicy: .prompt
            )
        )
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

                    let recognizedText = try await textRecognizer.recognizeText(in: cropped)
                    return CaptureTextRecognizer.normalizedRecognizedText(recognizedText)
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

    var hasStyledOutputConfigured: Bool {
        snapshot.presentation.isEnabled
    }

    var polishConfigurationLabel: String {
        guard hasStyledOutputConfigured else {
            return String(localized: "No Polish configured")
        }
        if let scene = snapshot.presentation.scene {
            return String.localizedStringWithFormat(
                String(localized: "Polish configured · %@"),
                scene.name
            )
        }
        if let template = presentationTemplates.first(where: { $0.presentation == snapshot.presentation }) {
            return String.localizedStringWithFormat(
                String(localized: "Polish configured · %@"),
                template.name
            )
        }
        return String(localized: "Polish configured · Custom look")
    }

    var automationOutputAppearance: ScreenshotOutputAppearance {
        hasStyledOutputConfigured ? .styled : .plain
    }

    /// The direct UI follows the pixels currently shown in the active
    /// workspace. Plain and Styled remain explicit automation/export model
    /// values, but they are not exposed as competing choices in routine
    /// editor chrome.
    var currentWorkspaceOutputAppearance: ScreenshotOutputAppearance {
        workflowStage == .polishing && hasStyledOutputConfigured
            ? .styled
            : .plain
    }

    /// Item and composition annotation scopes are temporary editing canvases,
    /// not document output previews. Keep document-level output unavailable
    /// until Done restores the Layout scope.
    var isDocumentOutputAvailable: Bool {
        compositionEditingScope == .layout
    }

    func copyAnnotatedImage(appearance: ScreenshotOutputAppearance) {
        do {
            let input = try exportRenderInput(for: appearance)
            Task { @MainActor [weak self] in
                do {
                    let pngData = try await EditorExportRenderer.renderPNGData(from: input)
                    try ImageExporter.copyPNGDataToClipboard(pngData)
                    self?.showNotice(EditorNotice(
                        message: String(localized: "Copied screenshot."),
                        accessibilityAnnouncement: String(
                            localized: "Screenshot copied to the clipboard."
                        )
                    ))
                } catch {
                    self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func exportFormatRequiresPNG(appearance: ScreenshotOutputAppearance) -> Bool {
        appearance == .styled
            && snapshot.presentation.requiresPNGForFaithfulExport
    }

    func renderedImageForExport(appearance: ScreenshotOutputAppearance) async throws -> CGImage {
        try await EditorExportRenderer.renderImage(
            from: exportRenderInput(
                for: appearance,
                compositionSafetyPolicy: .fail
            )
        )
    }

    func saveAnnotatedImage(
        appearance: ScreenshotOutputAppearance,
        format: ImageExportFormat = .png,
        filenameTemplate: ScreenshotFilenameTemplate = ScreenshotFilenameTemplate.default,
        exportOptions: ImageExportOptions = .default
    ) {
        let input: EditorExportRenderInput
        do {
            input = try exportRenderInput(for: appearance)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        let suggestedFilename = ImageExporter.editedFilename(
            suggestedFilename: filenameTemplate.resolvedFilename(for: capture, formatExtension: format.fileExtension),
            format: format,
            appearance: appearance
        )

        Task { @MainActor [weak self] in
            do {
                if input.snapshot.presentation.requiresPNGForFaithfulExport, format != .png {
                    throw ImageExportError.transparentPresentationRequiresPNG
                }

                guard let url = await ImageExporter.destinationURL(
                    suggestedFilename: suggestedFilename,
                    format: format,
                    appearance: appearance
                ) else {
                    return
                }

                let image = try await EditorExportRenderer.renderImage(from: input)
                try await ImageExporter.write(image, format: format, to: url, options: exportOptions)
                self?.showNotice(EditorNotice(
                    message: String(
                        localized: "Exported \(format.label) to \(url.lastPathComponent)."
                    ),
                    action: .reveal(url),
                    dismissalDelaySeconds: 6
                ))
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func shareAnnotatedImage(appearance: ScreenshotOutputAppearance) {
        let input: EditorExportRenderInput
        do {
            input = try exportRenderInput(for: appearance)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

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
        appearance: ScreenshotOutputAppearance,
        requestedFormat: ImageExportFormat,
        filenameTemplate: ScreenshotFilenameTemplate,
        exportOptions: ImageExportOptions = .default
    ) -> PromisedFilePayload? {
        let input: EditorExportRenderInput
        do {
            input = try exportRenderInput(
                for: appearance,
                compositionSafetyPolicy: .scaleToFit
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        let format = ImageExporter.dragOutFormat(
            requestedFormat: requestedFormat,
            requiresPNGForFaithfulExport: input.snapshot.presentation.requiresPNGForFaithfulExport
        )
        let suggestedFilename = ImageExporter.editedFilename(
            suggestedFilename: filenameTemplate.resolvedFilename(for: capture, formatExtension: format.fileExtension),
            format: format,
            appearance: appearance
        )

        if format != requestedFormat {
            showNotice("PNG used to preserve transparent Polish.")
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
        showNotice(EditorNotice(message: message))
    }

    func showNotice(_ newNotice: EditorNotice) {
        noticeTask?.cancel()
        notice = newNotice
        AppAccessibility.announce(newNotice.accessibilityAnnouncement)
        guard let dismissalDelaySeconds = newNotice.dismissalDelaySeconds else {
            return
        }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(dismissalDelaySeconds))
            guard !Task.isCancelled else {
                return
            }
            guard self?.notice?.id == newNotice.id else {
                return
            }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    private func exportRenderInput(
        for appearance: ScreenshotOutputAppearance,
        compositionSafetyPolicy:
            EditorCompositionRasterSafetyPolicy = .prompt
    ) throws -> EditorExportRenderInput {
        var exportSnapshot = canonicalCompositionEditingSnapshot(snapshot)
        switch appearance {
        case .plain:
            exportSnapshot.presentation = .plain
        case .styled:
            guard exportSnapshot.presentation.isEnabled else {
                throw ScreenshotOutputError.styledOutputNotConfigured
            }
        }

        let compositionOutput: CompositionOutputInput?
        let maximumOutputDimension: Int?
        if exportSnapshot.composition?.isActivated == true {
            let output = CompositionOutputInput(
                baseImage: documentCapture.image,
                snapshot: exportSnapshot,
                compositionAssets: [:],
                compositionAssetRepository:
                    compositionAssetRepository,
                compositionAssetDescriptors:
                    compositionAssetRepository.descriptors,
                pinnedUIMapElements: pinnedUIMapElements,
                uiMapOverlayOptions: uiMapOverlayOptions,
                appearance: appearance,
                suppressesContentDiagnostics: isPrivateDocument
            )
            let preflight = try CompositionOutputExporter.preflight(
                output,
                format: .png
            )
            compositionOutput = output
            if preflight.isOversized {
                switch compositionSafetyPolicy {
                case .fail:
                    throw CompositionOutputError.outputTooLarge(
                        width: Int(
                            preflight.estimatedPixelSize.width.rounded(.up)
                        ),
                        height: Int(
                            preflight.estimatedPixelSize.height.rounded(.up)
                        )
                    )
                case .prompt:
                    guard presentCompositionRasterScaleConfirmation(
                        preflight
                    ) else {
                        throw CancellationError()
                    }
                    maximumOutputDimension =
                        preflight.recommendedMaximumOutputDimension
                case .scaleToFit:
                    maximumOutputDimension =
                        preflight.recommendedMaximumOutputDimension
                    showNotice(
                        "Output was scaled to fit the safe raster size and memory limits."
                    )
                }
            } else {
                maximumOutputDimension = nil
            }
        } else {
            compositionOutput = nil
            maximumOutputDimension = nil
        }

        return EditorExportRenderInput(
            baseImage: documentCapture.image,
            snapshot: exportSnapshot,
            compositionOutput: compositionOutput,
            compositionMaximumOutputDimension: maximumOutputDimension,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions,
            suppressesContentDiagnostics: isPrivateDocument
        )
    }

    private func renderExportInput(
        _ input: EditorExportRenderInput
    ) throws -> CGImage {
        if let compositionOutput = input.compositionOutput {
            return try CompositionOutputExporter.staticImage(
                compositionOutput,
                maximumOutputDimension:
                    input.compositionMaximumOutputDimension
            )
        }
        return try CompositionDocumentRenderer.renderImage(
            baseImage: input.baseImage,
            snapshot: input.snapshot,
            pinnedUIMapElements: input.pinnedUIMapElements,
            uiMapOverlayOptions: input.uiMapOverlayOptions
        )
    }

    private func presentCompositionRasterScaleConfirmation(
        _ preflight: CompositionOutputPreflight
    ) -> Bool {
        let workingSetMB = max(
            1,
            Int(
                ceil(
                    Double(preflight.estimatedWorkingSetBytes)
                        / 1_048_576
                )
            )
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "Composition Is Too Large for a Full-Size Raster"
        alert.informativeText =
            "The estimated output is \(preflight.sizeDescription) pixels and may use about \(workingSetMB) MB while rendering. Scale it to the safe raster limits?"
        alert.addButton(withTitle: "Scale to Fit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func commitPendingTextEdits() {
        pendingTextEditingCommitTask?.cancel()
        pendingTextEditingCommitTask = nil

        guard let session = textEditingSession else {
            return
        }

        textEditingSession = nil

        refitPendingTextBounds(for: session)

        guard canonicalCompositionEditingSnapshot(snapshot)
            != canonicalCompositionEditingSnapshot(session.originalSnapshot) else {
            return
        }

        let shouldPruneCompositionAssets =
            appendUndoSnapshot(canonicalCompositionEditingSnapshot(session.originalSnapshot))
            || !redoStack.isEmpty
        redoStack.removeAll()
        if shouldPruneCompositionAssets {
            pruneUnreferencedCompositionAssets()
        }
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

    private func maximumAutoTextWidth(for shape: TextShape) -> CGFloat {
        gscAutoTextMaxWidth(
            originX: shape.rect.minX,
            within: snapshot.cropRect,
            minWidth: 44
        )
    }

    private func maximumAutoCalloutWidth(for shape: CalloutShape) -> CGFloat {
        gscAutoTextMaxWidth(
            originX: shape.rect.minX,
            within: snapshot.cropRect,
            minWidth: 194
        )
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

    var compositionEditingScopeTitle: String? {
        switch compositionEditingScope {
        case .layout:
            return nil
        case .composition:
            return "Annotate Result"
        case .item(let itemID):
            let title = snapshot.composition?.items.first(where: { $0.id == itemID })?.title
            return title?.isEmpty == false
                ? "Edit Selected Capture — \(title!)"
                : "Edit Selected Capture"
        }
    }

    var canSelectPreviousCompositionItem: Bool {
        adjacentCompositionItemID(offset: -1) != nil
    }

    var canSelectNextCompositionItem: Bool {
        adjacentCompositionItemID(offset: 1) != nil
    }

    func enterCompositionItemEditing(_ itemID: UUID) {
        guard compositionEditingScope == .layout,
              snapshot.composition?.items.contains(where: { $0.id == itemID }) == true else {
            return
        }

        commitPendingTextEdits()
        let canonical = snapshot
        do {
            let itemCapture = try compositionCapture(for: itemID)
            rememberCompositionEditingReturnContext()
            compositionEditingRootState = editState(from: canonical)
            compositionEditingLayout = nil
            compositionEditingLogicalCanvasSize = nil
            capture = itemCapture
            compositionEditingScope = .item(itemID)
            workspaceMode = .edit
            activeTool = .select
            clearTransientToolState()
            applySnapshot(
                canonical,
                fitViewportToCrop: true,
                canonicalizesCompositionEditingChanges: false
            )
            showNotice("Editing one source item. Choose Done to return to Layout.")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func enterCompositionEditing() {
        guard compositionEditingScope == .layout,
              snapshot.composition != nil else {
            return
        }

        commitPendingTextEdits()
        let canonical = snapshot
        do {
            var options = CompositionRenderOptions()
            options.drawsCanvasAnnotations = false
            options.targetMaximumPixelDimension = 4_096
            let logicalLayout = try CompositionLayoutEngine.layout(
                composition: canonical.composition!,
                assetDescriptors: compositionAssetRepository.descriptors
            )
            let result = try CompositionRenderer.renderPreview(
                composition: canonical.composition!,
                assetRepository: compositionAssetRepository,
                options: options
            )
            rememberCompositionEditingReturnContext()
            let bounds = CGRect(origin: .zero, size: result.layout.canvasSize)
            let assembledCapture = CapturedScreenshot(
                image: result.image,
                kind: .region,
                sourceName: "Composition",
                sourceRect: bounds,
                capturedAt: Date()
            )
            compositionEditingRootState = editState(from: canonical)
            compositionEditingLayout = result.layout
            compositionEditingLogicalCanvasSize = logicalLayout.canvasSize
            capture = assembledCapture
            compositionEditingScope = .composition
            workspaceMode = .edit
            activeTool = .select
            clearTransientToolState()
            applySnapshot(
                canonical,
                fitViewportToCrop: true,
                canonicalizesCompositionEditingChanges: false
            )
            showNotice("Editing annotations over the complete composition. Choose Done to return to Layout.")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func enterCompositionEditingFromPresentation() {
        presentationInspectorTab = .layout
        enterCompositionEditing()
    }

    func finishCompositionEditing() {
        guard compositionEditingScope != .layout else {
            return
        }

        commitPendingTextEdits()
        let canonical = canonicalCompositionEditingSnapshot(snapshot)
        let returnViewport = compositionEditingReturnViewport
        let returnInspectorTab = compositionEditingReturnInspectorTab
        let returnInspectorScrollPosition = compositionEditingReturnInspectorScrollPosition
        compositionEditingScope = .layout
        capture = documentCapture
        compositionEditingRootState = nil
        compositionEditingLayout = nil
        compositionEditingLogicalCanvasSize = nil
        compositionEditingReturnViewport = nil
        compositionEditingReturnInspectorTab = nil
        compositionEditingReturnInspectorScrollPosition = nil
        activeTool = .select
        clearTransientToolState()
        workspaceMode = .presentation
        applySnapshot(canonical, fitViewportToCrop: false)
        if let returnViewport {
            objectWillChange.send()
            viewport = returnViewport
            invalidateCanvas(.viewport)
        }
        if let returnInspectorTab {
            presentationInspectorTab = returnInspectorTab
        }
        compositionInspectorScrollPosition = returnInspectorScrollPosition
        requestCompositionCanvasFocus()
        showNotice("Composition edits applied.")
    }

    func requestCompositionCanvasFocus() {
        compositionCanvasFocusRequestRevision &+= 1
    }

    private func rememberCompositionEditingReturnContext() {
        compositionEditingReturnViewport = viewport
        compositionEditingReturnInspectorTab = .layout
        compositionEditingReturnInspectorScrollPosition = compositionInspectorScrollPosition
    }

    func selectPreviousCompositionItemForEditing() {
        switchCompositionItemEditing(to: adjacentCompositionItemID(offset: -1))
    }

    func selectNextCompositionItemForEditing() {
        switchCompositionItemEditing(to: adjacentCompositionItemID(offset: 1))
    }

    func pinSelectedCompositionAnnotationsToCanvas() {
        retargetSelectedCompositionAnnotations(toItemID: nil)
    }

    func pinSelectedCompositionAnnotationEndpointsToVisibleItems() {
        retargetSelectedCompositionAnnotations(
            toItemID: nil,
            usesItemsUnderEndpoints: true
        )
    }

    func pinSelectedCompositionAnnotations(to itemID: UUID) {
        retargetSelectedCompositionAnnotations(toItemID: itemID)
    }

    private func switchCompositionItemEditing(to itemID: UUID?) {
        guard case .item = compositionEditingScope, let itemID else {
            return
        }
        commitPendingTextEdits()
        var canonical = canonicalCompositionEditingSnapshot(snapshot)
        do {
            let itemCapture = try compositionCapture(for: itemID)
            canonical.composition?.selectedItemIDs = [itemID]
            capture = itemCapture
            compositionEditingScope = .item(itemID)
            applySnapshot(
                canonical,
                fitViewportToCrop: true,
                canonicalizesCompositionEditingChanges: false
            )
            activeTool = .select
            clearTransientToolState()
            AppAccessibility.announce(
                compositionEditingScopeTitle ?? "Edit Selected Capture"
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func adjacentCompositionItemID(offset: Int) -> UUID? {
        guard case .item(let currentID) = compositionEditingScope,
              let items = snapshot.composition?.items,
              let currentIndex = items.firstIndex(where: { $0.id == currentID }) else {
            return nil
        }
        let targetIndex = currentIndex + offset
        guard items.indices.contains(targetIndex) else {
            return nil
        }
        return items[targetIndex].id
    }

    private func retargetSelectedCompositionAnnotations(
        toItemID itemID: UUID?,
        usesItemsUnderEndpoints: Bool = false
    ) {
        guard compositionEditingScope == .composition,
              let layout = compositionEditingLayout else {
            return
        }
        var canonical = canonicalCompositionEditingSnapshot(snapshot)
        guard var composition = canonical.composition else {
            return
        }
        let selectedIDs = Set(snapshot.selectedAnnotationIDs)
        guard !selectedIDs.isEmpty else {
            return
        }
        let canvasSize = layout.canvasSize
        for annotation in composition.canvas.annotations where selectedIDs.contains(annotation.id) {
            let points = compositionAnchorPoints(for: annotation)
            let primaryItemID = usesItemsUnderEndpoints
                ? compositionItemID(containing: points.primary, layout: layout)
                : itemID
            let primary = makeCompositionAnchor(
                at: points.primary,
                itemID: primaryItemID,
                layout: layout,
                canvasSize: canvasSize
            )
            let secondary = points.secondary.map {
                let secondaryItemID = usesItemsUnderEndpoints
                    ? compositionItemID(containing: $0, layout: layout)
                    : itemID
                return makeCompositionAnchor(
                    at: $0,
                    itemID: secondaryItemID,
                    layout: layout,
                    canvasSize: canvasSize
                )
            }
            composition.canvas.annotationAnchors[annotation.id] = CompositionAnnotationAnchors(
                primary: primary,
                secondary: secondary
            )
        }
        canonical.composition = composition
        execute(SetCompositionCanvasCommand(canvas: composition.canvas))
        if usesItemsUnderEndpoints {
            showNotice(
                "Pinned each selected annotation endpoint to the visible item beneath it."
            )
        } else {
            showNotice(
                itemID == nil
                    ? "Pinned selected annotations to the canvas."
                    : "Pinned selected annotations to the item."
            )
        }
    }

    private func canonicalCompositionEditingSnapshot(_ candidate: EditorSnapshot) -> EditorSnapshot {
        guard let rootState = compositionEditingRootState,
              compositionEditingScope != .layout,
              var composition = candidate.composition else {
            return candidate
        }

        switch compositionEditingScope {
        case .layout:
            break
        case .item(let itemID):
            if let index = composition.items.firstIndex(where: { $0.id == itemID }) {
                composition.items[index].editState = editState(from: candidate)
            }
        case .composition:
            let displayCanvasSize = capture.pixelSize
            let logicalCanvasSize = compositionEditingLogicalCanvasSize
                ?? displayCanvasSize
            composition.canvas.annotations = candidate.annotations.map {
                scaledCompositionEditingAnnotation(
                    $0,
                    from: displayCanvasSize,
                    to: logicalCanvasSize
                )
            }
            composition.canvas.selectedAnnotationIDs = candidate.selectedAnnotationIDs
            composition.canvas.nextCalloutNumber = candidate.nextCalloutNumber
            var displayCanvas = composition.canvas
            displayCanvas.annotations = candidate.annotations
            updateCompositionAnnotationAnchors(
                in: &displayCanvas,
                layout: compositionEditingLayout,
                canvasSize: displayCanvasSize
            )
            composition.canvas.annotationAnchors = displayCanvas.annotationAnchors
                .mapValues {
                    scaledCompositionEditingAnchors(
                        $0,
                        from: displayCanvasSize,
                        to: logicalCanvasSize
                    )
                }
        }

        var canonical = candidate
        canonical.composition = composition
        canonical.cropRect = rootState.cropRect
            ?? CGRect(origin: .zero, size: documentCapture.pixelSize)
        canonical.annotations = rootState.annotations
        canonical.selectedAnnotationIDs = rootState.selectedAnnotationIDs
        canonical.nextCalloutNumber = rootState.nextCalloutNumber
        canonical.pinnedUIMapElementIDs = rootState.pinnedUIMapElementIDs
        return canonical
    }

    private func projectedCompositionEditingSnapshot(_ canonical: EditorSnapshot) -> EditorSnapshot {
        guard compositionEditingScope != .layout,
              let composition = canonical.composition else {
            return canonical
        }

        var projected = canonical
        let projectedState: ScreenshotEditState
        switch compositionEditingScope {
        case .layout:
            return canonical
        case .item(let itemID):
            guard let item = composition.items.first(where: { $0.id == itemID }) else {
                return canonical
            }
            projectedState = item.editState
        case .composition:
            let logicalCanvasSize = compositionEditingLogicalCanvasSize
                ?? capture.pixelSize
            projectedState = ScreenshotEditState(
                cropRect: CGRect(origin: .zero, size: capture.pixelSize),
                annotations: composition.canvas.annotations.map {
                    scaledCompositionEditingAnnotation(
                        $0,
                        from: logicalCanvasSize,
                        to: capture.pixelSize
                    )
                },
                selectedAnnotationIDs: composition.canvas.selectedAnnotationIDs,
                nextCalloutNumber: composition.canvas.nextCalloutNumber
            )
        }
        projected.cropRect = projectedState.cropRect
            ?? CGRect(origin: .zero, size: capture.pixelSize)
        projected.annotations = projectedState.annotations
        projected.selectedAnnotationIDs = projectedState.selectedAnnotationIDs
        projected.nextCalloutNumber = projectedState.nextCalloutNumber
        projected.pinnedUIMapElementIDs = projectedState.pinnedUIMapElementIDs
        return projected
    }

    private func scaledCompositionEditingAnnotation(
        _ annotation: Annotation,
        from sourceSize: CGSize,
        to destinationSize: CGSize
    ) -> Annotation {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0,
              sourceSize != destinationSize else {
            return annotation
        }
        let sourceBounds = CGRect(origin: .zero, size: sourceSize)
        let destinationBounds = CGRect(origin: .zero, size: destinationSize)
        let styleScale = min(
            destinationSize.width / sourceSize.width,
            destinationSize.height / sourceSize.height
        )
        var scaled = annotation.scaled(
            from: sourceBounds,
            to: destinationBounds
        )
        var style = scaled.style.scaledForDisplay(by: styleScale)
        style.effectRadius *= styleScale
        scaled.style = style
        if case .arrow(var shape) = scaled.kind {
            shape.labelFontSize *= styleScale
            scaled.kind = .arrow(shape)
        }
        return scaled
    }

    private func scaledCompositionEditingAnchors(
        _ anchors: CompositionAnnotationAnchors,
        from sourceSize: CGSize,
        to destinationSize: CGSize
    ) -> CompositionAnnotationAnchors {
        CompositionAnnotationAnchors(
            primary: scaledCompositionEditingAnchor(
                anchors.primary,
                from: sourceSize,
                to: destinationSize
            ),
            secondary: anchors.secondary.map {
                scaledCompositionEditingAnchor(
                    $0,
                    from: sourceSize,
                    to: destinationSize
                )
            }
        )
    }

    private func scaledCompositionEditingAnchor(
        _ anchor: CompositionAnnotationAnchor,
        from sourceSize: CGSize,
        to destinationSize: CGSize
    ) -> CompositionAnnotationAnchor {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return anchor
        }
        let scaleX = destinationSize.width / sourceSize.width
        let scaleY = destinationSize.height / sourceSize.height
        func scaledPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scaleX, y: point.y * scaleY)
        }
        let target: CompositionAnchorTarget
        switch anchor.target {
        case .canvasNormalized, .itemNormalized:
            target = anchor.target
        case .detachedCanvas(let point):
            target = .detachedCanvas(scaledPoint(point))
        }
        return CompositionAnnotationAnchor(
            target: target,
            lastCanvasPoint: scaledPoint(anchor.lastCanvasPoint)
        )
    }

    private func editState(from snapshot: EditorSnapshot) -> ScreenshotEditState {
        ScreenshotEditState(
            cropRect: snapshot.cropRect,
            annotations: snapshot.annotations,
            selectedAnnotationIDs: snapshot.selectedAnnotationIDs,
            nextCalloutNumber: snapshot.nextCalloutNumber,
            pinnedUIMapElementIDs: snapshot.pinnedUIMapElementIDs
        )
    }

    private func updateCompositionAnnotationAnchors(
        in canvas: inout CompositionCanvasState,
        layout: CompositionRenderLayout?,
        canvasSize: CGSize
    ) {
        let validIDs = Set(canvas.annotations.map(\.id))
        canvas.annotationAnchors = canvas.annotationAnchors.filter { validIDs.contains($0.key) }
        for annotation in canvas.annotations {
            let points = compositionAnchorPoints(for: annotation)
            let prior = canvas.annotationAnchors[annotation.id]
            canvas.annotationAnchors[annotation.id] = CompositionAnnotationAnchors(
                primary: updatedCompositionAnchor(
                    prior?.primary,
                    at: points.primary,
                    layout: layout,
                    canvasSize: canvasSize
                ),
                secondary: points.secondary.map {
                    updatedCompositionAnchor(
                        prior?.secondary,
                        at: $0,
                        layout: layout,
                        canvasSize: canvasSize
                    )
                }
            )
        }
    }

    private func compositionAnchorPoints(for annotation: Annotation) -> (primary: CGPoint, secondary: CGPoint?) {
        switch annotation.kind {
        case .line(let shape):
            return (shape.start, shape.end)
        case .arrow(let shape):
            return (shape.start, shape.end)
        case .measurement(let shape):
            return (shape.start, shape.end)
        default:
            return (annotation.boundingRect.origin, nil)
        }
    }

    private func updatedCompositionAnchor(
        _ prior: CompositionAnnotationAnchor?,
        at point: CGPoint,
        layout: CompositionRenderLayout?,
        canvasSize: CGSize
    ) -> CompositionAnnotationAnchor {
        guard let prior else {
            let itemID = layout.flatMap {
                compositionItemID(containing: point, layout: $0)
            }
            return makeCompositionAnchor(
                at: point,
                itemID: itemID,
                layout: layout,
                canvasSize: canvasSize
            )
        }
        let target: CompositionAnchorTarget
        switch prior.target {
        case .canvasNormalized:
            target = .canvasNormalized(normalizedCompositionPoint(point, in: canvasSize))
        case .detachedCanvas:
            target = .detachedCanvas(point)
        case .itemNormalized(let itemID, _):
            if let itemLayout = layout?.itemLayout(for: itemID),
               itemLayout.imageDrawRect.width > 0,
               itemLayout.imageDrawRect.height > 0 {
                target = .itemNormalized(
                    itemID: itemID,
                    point: CGPoint(
                        x: (point.x - itemLayout.imageDrawRect.minX) / itemLayout.imageDrawRect.width,
                        y: (point.y - itemLayout.imageDrawRect.minY) / itemLayout.imageDrawRect.height
                    )
                )
            } else {
                target = .detachedCanvas(point)
            }
        }
        return CompositionAnnotationAnchor(target: target, lastCanvasPoint: point)
    }

    private func makeCompositionAnchor(
        at point: CGPoint,
        itemID: UUID?,
        layout: CompositionRenderLayout?,
        canvasSize: CGSize
    ) -> CompositionAnnotationAnchor {
        if let itemID,
           let itemLayout = layout?.itemLayout(for: itemID),
           itemLayout.imageDrawRect.width > 0,
           itemLayout.imageDrawRect.height > 0 {
            return CompositionAnnotationAnchor(
                target: .itemNormalized(
                    itemID: itemID,
                    point: CGPoint(
                        x: (point.x - itemLayout.imageDrawRect.minX) / itemLayout.imageDrawRect.width,
                        y: (point.y - itemLayout.imageDrawRect.minY) / itemLayout.imageDrawRect.height
                    )
                ),
                lastCanvasPoint: point
            )
        }
        return CompositionAnnotationAnchor(
            target: .canvasNormalized(normalizedCompositionPoint(point, in: canvasSize)),
            lastCanvasPoint: point
        )
    }

    private func compositionItemID(
        containing point: CGPoint,
        layout: CompositionRenderLayout
    ) -> UUID? {
        layout.items
            .sorted {
                if $0.zIndex == $1.zIndex {
                    return $0.itemID.uuidString > $1.itemID.uuidString
                }
                return $0.zIndex > $1.zIndex
            }
            .first(where: {
                $0.imageClipRect.contains(point)
            })?
            .itemID
    }

    private func normalizedCompositionPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width > 0 ? point.x / size.width : 0,
            y: size.height > 0 ? point.y / size.height : 0
        )
    }

    private func applySnapshot(
        _ updatedSnapshot: EditorSnapshot,
        fitViewportToCrop: Bool,
        invalidationReason: EditorCanvasInvalidationReason = .full,
        canonicalizesCompositionEditingChanges: Bool = true
    ) {
        let canonical = canonicalizesCompositionEditingChanges
            ? canonicalCompositionEditingSnapshot(updatedSnapshot)
            : updatedSnapshot
        let projected = projectedCompositionEditingSnapshot(canonical)
        snapshot = projected
        workflowResumeState = workflowResumeState.normalized(
            for: projected.documentPurpose,
            composition: projected.composition
        )
        invalidateCanvas(invalidationReason)
        updateViewport(
            publishChange: fitViewportToCrop,
            invalidationReason: fitViewportToCrop ? .full : invalidationReason
        ) {
            let updatedViewport = $0.updatingContentSize(documentCanvasSize, fitToWindow: false)

            guard fitViewportToCrop else {
                return updatedViewport
            }

            if projected.cropRect.gscIntegralStandardized == fullImageRect {
                return updatedViewport.zoomedToFit()
            }

            return updatedViewport.focused(on: projected.cropRect)
        }
    }

    private func updateViewport(
        publishChange: Bool = true,
        invalidationReason: EditorCanvasInvalidationReason = .full,
        _ mutation: (EditorViewport) -> EditorViewport
    ) {
        let updatedViewport = mutation(viewport)

        guard updatedViewport != viewport else {
            return
        }

        if publishChange {
            objectWillChange.send()
        }

        viewport = updatedViewport
        invalidateCanvas(invalidationReason)
    }

    private func invalidateCanvas(_ reason: EditorCanvasInvalidationReason = .full) {
        canvasInvalidationReason = reason
        canvasRevision += 1

        if reason == .full || reason == .uiMapOverlay {
            presentationContentRevision += 1
            presentationContentCache = nil
            compositionRegistrationOutcome = nil
            if !isPrivateDocument {
                PresentationPerformanceMetrics.logEvent(
                    "controller.presentationContent.invalidate",
                    context: "reason=\(reason.metricName) revision=\(presentationContentRevision) canvasRevision=\(canvasRevision)"
                )
            }
        }
    }

    func invalidateCompositionContent() {
        invalidateCanvas(.full)
    }

    func setCompositionRegistrationOutcome(_ outcome: CompositionRegistrationOutcome?) {
        compositionRegistrationOutcome = outcome
    }
}

private extension EditorCanvasInvalidationReason {
    var metricName: String {
        switch self {
        case .full:
            return "full"
        case .viewport:
            return "viewport"
        case .cropPreview:
            return "cropPreview"
        case .cropChrome:
            return "cropChrome"
        case .uiMapOverlay:
            return "uiMapOverlay"
        case .uiMapHover:
            return "uiMapHover"
        }
    }
}

private extension EditorSnapshot {
    func isPresentationOnlyChange(to updated: EditorSnapshot) -> Bool {
        guard presentation != updated.presentation else {
            return false
        }

        var comparable = self
        comparable.presentation = updated.presentation
        return comparable == updated
    }
}

nonisolated private enum EditorCompositionRasterSafetyPolicy {
    case fail
    case prompt
    case scaleToFit
}

nonisolated private struct EditorExportRenderInput: @unchecked Sendable {
    let baseImage: CGImage
    let snapshot: EditorSnapshot
    let compositionOutput: CompositionOutputInput?
    let compositionMaximumOutputDimension: Int?
    let pinnedUIMapElements: [UIMapElement]
    let uiMapOverlayOptions: UIMapOverlayOptions
    let suppressesContentDiagnostics: Bool

    init(
        baseImage: CGImage,
        snapshot: EditorSnapshot,
        compositionOutput: CompositionOutputInput? = nil,
        compositionMaximumOutputDimension: Int? = nil,
        pinnedUIMapElements: [UIMapElement] = [],
        uiMapOverlayOptions: UIMapOverlayOptions = UIMapOverlayOptions(),
        suppressesContentDiagnostics: Bool = false
    ) {
        self.baseImage = baseImage
        self.snapshot = snapshot
        self.compositionOutput = compositionOutput
        self.compositionMaximumOutputDimension =
            compositionMaximumOutputDimension
        self.pinnedUIMapElements = pinnedUIMapElements
        self.uiMapOverlayOptions = uiMapOverlayOptions
        self.suppressesContentDiagnostics = suppressesContentDiagnostics
    }
}

nonisolated private enum EditorExportRenderer {
    static func renderImage(from input: EditorExportRenderInput) async throws -> CGImage {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let image = try PresentationPerformanceMetrics
                .withLoggingSuppressed(
                    input.suppressesContentDiagnostics
                ) {
                    try PresentationPerformanceMetrics.measure(
                        "export.renderImage",
                        context: "base=\(input.baseImage.width)x\(input.baseImage.height) crop=\(PresentationPerformanceMetrics.size(input.snapshot.cropRect.size)) annotations=\(input.snapshot.annotations.count) compositionItems=\(input.snapshot.composition?.items.count ?? 0) \(PresentationPerformanceMetrics.presentationSummary(input.snapshot.presentation))",
                        warnAfterMS: 120
                    ) {
                        if let compositionOutput = input.compositionOutput {
                            return try CompositionOutputExporter.staticImage(
                                compositionOutput,
                                maximumOutputDimension:
                                    input.compositionMaximumOutputDimension
                            )
                        }
                        return try CompositionDocumentRenderer.renderImage(
                            baseImage: input.baseImage,
                            snapshot: input.snapshot,
                            pinnedUIMapElements: input.pinnedUIMapElements,
                            uiMapOverlayOptions: input.uiMapOverlayOptions
                        )
                    }
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

            return try PresentationPerformanceMetrics
                .withLoggingSuppressed(
                    input.suppressesContentDiagnostics
                ) {
                    let image = try PresentationPerformanceMetrics.measure(
                        "export.renderPNG.image",
                        context: "base=\(input.baseImage.width)x\(input.baseImage.height) crop=\(PresentationPerformanceMetrics.size(input.snapshot.cropRect.size)) annotations=\(input.snapshot.annotations.count) compositionItems=\(input.snapshot.composition?.items.count ?? 0) \(PresentationPerformanceMetrics.presentationSummary(input.snapshot.presentation))",
                        warnAfterMS: 120
                    ) {
                        if let compositionOutput = input.compositionOutput {
                            return try CompositionOutputExporter.staticImage(
                                compositionOutput,
                                maximumOutputDimension:
                                    input.compositionMaximumOutputDimension
                            )
                        }
                        return try CompositionDocumentRenderer.renderImage(
                            baseImage: input.baseImage,
                            snapshot: input.snapshot,
                            pinnedUIMapElements:
                                input.pinnedUIMapElements,
                            uiMapOverlayOptions:
                                input.uiMapOverlayOptions
                        )
                    }

                    try Task.checkCancellation()
                    return try PresentationPerformanceMetrics.measure(
                        "export.renderPNG.encode",
                        context: "image=\(image.width)x\(image.height)",
                        warnAfterMS: 80
                    ) {
                        try ImageExporter.pngData(for: image)
                    }
                }
            }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
