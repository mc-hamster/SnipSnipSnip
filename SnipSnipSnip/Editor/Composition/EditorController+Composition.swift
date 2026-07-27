import CoreGraphics
import Foundation

nonisolated enum CompositionEditingScope: Equatable, Sendable {
    case layout
    case composition
    case item(UUID)
}

nonisolated struct CompositionInsertionResult: Equatable, Sendable {
    let itemID: UUID
    let assetID: UUID
    let itemCount: Int
    let isPrivateDocument: Bool
}

extension EditorController {
    var composition: CompositionSnapshot? {
        snapshot.composition
    }

    var hasComposition: Bool {
        snapshot.composition?.isActivated == true
    }

    var compositionItemCount: Int {
        snapshot.composition?.items.count ?? 1
    }

    var includedCompositionItemCount: Int {
        snapshot.composition?.items.filter(\.isIncluded).count ?? 1
    }

    var selectedCompositionItems: [CompositionItem] {
        guard let composition = snapshot.composition else {
            return []
        }
        let selected = Set(composition.selectedItemIDs)
        return composition.items.filter { selected.contains($0.id) }
    }

    @discardableResult
    func appendCaptureToComposition(
        _ addedCapture: CapturedScreenshot,
        isPrivate: Bool,
        afterItemID: UUID? = nil,
        taintsDocument: Bool = true
    ) throws -> CompositionInsertionResult {
        commitPendingTextEdits()

        let addedAssetID = try compositionAssetRepository.add(
            capture: addedCapture,
            isPrivate: isPrivate
        )
        let addedItem = Self.compositionItem(
            for: addedCapture,
            assetID: addedAssetID
        )

        if snapshot.composition != nil {
            execute(AddCompositionItemCommand(item: addedItem, afterItemID: afterItemID))
        } else {
            let rootAssetID = try compositionAssetRepository.add(
                capture: capture,
                isPrivate: isPrivateDocument
            )
            let rootItem = CompositionItem(
                assetID: rootAssetID,
                editState: ScreenshotEditState(
                    cropRect: snapshot.cropRect,
                    annotations: snapshot.annotations,
                    selectedAnnotationIDs: [],
                    nextCalloutNumber: snapshot.nextCalloutNumber,
                    pinnedUIMapElementIDs: snapshot.pinnedUIMapElementIDs
                ),
                title: capture.sourceName,
                accessibilityLabel: capture.sourceName
            )
            var composition = CompositionSnapshot(
                items: [rootItem, addedItem],
                selectedItemIDs: [addedItem.id],
                layout: CompositionLayoutConfiguration(mode: .auto),
                canvas: CompositionCanvasState(appearance: CompositionCanvasAppearance())
            )
            composition.repairComparisonSelection()
            execute(SetCompositionCommand(composition: composition))
        }

        if isPrivate, taintsDocument {
            markDocumentPrivate()
        }
        presentationInspectorTab = .layout
        setWorkspaceMode(.presentation)
        let itemCount = snapshot.composition?.items.count ?? 1
        showNotice(
            String(
                localized: "Added \(addedCapture.sourceName). \(itemCount) captures in this result."
            )
        )

        return CompositionInsertionResult(
            itemID: addedItem.id,
            assetID: addedAssetID,
            itemCount: snapshot.composition?.items.count ?? 1,
            isPrivateDocument: isPrivateDocument
        )
    }

    @discardableResult
    func appendEditableDocument(
        _ document: EditableScreenshotDocument,
        afterItemID: UUID? = nil,
        replacingItemID: UUID? = nil
    ) throws -> UUID? {
        let initialAssetIDs = Set(compositionAssetRepository.assetIDs)
        let importsPrivatePixels = document.isPrivate
            || document.compositionStoredAssets.contains {
                $0.descriptor.isPrivate
            }
        beginCoalescedEditorGesture()
        do {
            let lastInsertedItemID = try appendEditableDocumentContents(
                document,
                afterItemID: afterItemID,
                replacingItemID: replacingItemID
            )
            endCoalescedEditorGesture()
            if lastInsertedItemID != nil, importsPrivatePixels {
                markDocumentPrivate()
            }
            return lastInsertedItemID
        } catch {
            cancelCoalescedEditorGesture()
            let addedAssetIDs = Set(compositionAssetRepository.assetIDs)
                .subtracting(initialAssetIDs)
            compositionAssetRepository.removeAssets(addedAssetIDs)
            throw error
        }
    }

    private func appendEditableDocumentContents(
        _ document: EditableScreenshotDocument,
        afterItemID: UUID?,
        replacingItemID: UUID?
    ) throws -> UUID? {
        guard let sourceComposition = document.session.currentSnapshot.composition else {
            let insertion: CompositionInsertionResult
            if let replacingItemID {
                insertion = try replaceCompositionItem(
                    itemID: replacingItemID,
                    with: document.capture,
                    isPrivate: document.isPrivate,
                    taintsDocument: false
                )
            } else {
                insertion = try appendCaptureToComposition(
                    document.capture,
                    isPrivate: document.isPrivate,
                    afterItemID: afterItemID,
                    taintsDocument: false
                )
            }
            updateCompositionItem(itemID: insertion.itemID) { item in
                item.editState = ScreenshotEditState(
                    cropRect: document.session.currentSnapshot.cropRect,
                    annotations: document.session.currentSnapshot.annotations,
                    selectedAnnotationIDs: [],
                    nextCalloutNumber: document.session.currentSnapshot.nextCalloutNumber,
                    pinnedUIMapElementIDs: document.session.currentSnapshot.pinnedUIMapElementIDs
                )
                item.title = document.capture.sourceName
            }
            return insertion.itemID
        }

        let sourceRepository = CompositionAssetRepository(
            storedAssets: document.compositionStoredAssets
        )
        var sourceCaptures: [UUID: CapturedScreenshot] = [:]
        for sourceItem in sourceComposition.items
        where sourceCaptures[sourceItem.assetID] == nil {
            sourceCaptures[sourceItem.assetID] = try sourceRepository
                .capturedScreenshot(for: sourceItem.assetID)
        }
        var importedAssetIDs: [UUID: UUID] = [:]
        var lastInsertedItemID = afterItemID ?? snapshot.composition?.items.last?.id
        var pendingReplacementItemID = replacingItemID

        for sourceItem in sourceComposition.items {
            let targetItemID: UUID
            let targetAssetID: UUID

            if let pendingReplacementItemID {
                guard let sourceCapture = sourceCaptures[sourceItem.assetID] else {
                    throw CompositionAssetRepositoryError.missingAsset(
                        sourceItem.assetID
                    )
                }
                let insertion = try replaceCompositionItem(
                    itemID: pendingReplacementItemID,
                    with: sourceCapture,
                    isPrivate: document.isPrivate
                        || sourceRepository.storedAsset(for: sourceItem.assetID)?.descriptor.isPrivate == true,
                    taintsDocument: false
                )
                targetItemID = insertion.itemID
                targetAssetID = insertion.assetID
                importedAssetIDs[sourceItem.assetID] = targetAssetID
                self.updateCompositionItem(itemID: targetItemID) { item in
                    item.editState = sourceItem.editState
                    item.framing = sourceItem.framing
                    item.opacity = sourceItem.opacity
                    item.weight = sourceItem.weight
                    item.title = sourceItem.title
                    item.caption = sourceItem.caption
                    item.accessibilityLabel = sourceItem.accessibilityLabel
                    item.freeformFrame = sourceItem.freeformFrame
                    item.isIncluded = sourceItem.isIncluded
                    item.semanticRole = sourceItem.semanticRole
                    item.zIndex = sourceItem.zIndex
                }
            } else if let reusedAssetID = importedAssetIDs[sourceItem.assetID] {
                targetItemID = UUID()
                targetAssetID = reusedAssetID
                let duplicate = CompositionItem(
                    id: targetItemID,
                    assetID: targetAssetID,
                    editState: sourceItem.editState,
                    framing: sourceItem.framing,
                    opacity: sourceItem.opacity,
                    weight: sourceItem.weight,
                    title: sourceItem.title,
                    caption: sourceItem.caption,
                    accessibilityLabel: sourceItem.accessibilityLabel,
                    freeformFrame: sourceItem.freeformFrame,
                    isIncluded: sourceItem.isIncluded,
                    semanticRole: sourceItem.semanticRole,
                    zIndex: sourceItem.zIndex
                )
                execute(
                    AddCompositionItemCommand(
                        item: duplicate,
                        afterItemID: lastInsertedItemID
                    )
                )
            } else {
                guard let sourceCapture = sourceCaptures[sourceItem.assetID] else {
                    throw CompositionAssetRepositoryError.missingAsset(
                        sourceItem.assetID
                    )
                }
                let insertion = try appendCaptureToComposition(
                    sourceCapture,
                    isPrivate: document.isPrivate
                        || sourceRepository.storedAsset(for: sourceItem.assetID)?.descriptor.isPrivate == true,
                    afterItemID: lastInsertedItemID,
                    taintsDocument: false
                )
                targetItemID = insertion.itemID
                targetAssetID = insertion.assetID
                importedAssetIDs[sourceItem.assetID] = targetAssetID
                updateCompositionItem(itemID: targetItemID) { item in
                    item.editState = sourceItem.editState
                    item.framing = sourceItem.framing
                    item.opacity = sourceItem.opacity
                    item.weight = sourceItem.weight
                    item.title = sourceItem.title
                    item.caption = sourceItem.caption
                    item.accessibilityLabel = sourceItem.accessibilityLabel
                    item.freeformFrame = sourceItem.freeformFrame
                    item.isIncluded = sourceItem.isIncluded
                    item.semanticRole = sourceItem.semanticRole
                    item.zIndex = sourceItem.zIndex
                }
            }
            lastInsertedItemID = targetItemID
            pendingReplacementItemID = nil
        }
        return lastInsertedItemID
    }

    @discardableResult
    func replaceCompositionItem(
        itemID: UUID,
        with replacementCapture: CapturedScreenshot,
        isPrivate: Bool,
        taintsDocument: Bool = true
    ) throws -> CompositionInsertionResult {
        guard snapshot.composition?.items.contains(where: { $0.id == itemID }) == true else {
            throw CompositionLayoutError.emptyComposition
        }

        let assetID = try compositionAssetRepository.add(
            capture: replacementCapture,
            isPrivate: isPrivate
        )
        let replacementState = Self.editState(for: replacementCapture)
        execute(
            ReplaceCompositionItemCommand(
                itemID: itemID,
                assetID: assetID,
                editState: replacementState,
                title: replacementCapture.sourceName
            )
        )
        if isPrivate, taintsDocument {
            markDocumentPrivate()
        }
        showNotice("Replaced the selected composition item.")

        return CompositionInsertionResult(
            itemID: itemID,
            assetID: assetID,
            itemCount: snapshot.composition?.items.count ?? 1,
            isPrivateDocument: isPrivateDocument
        )
    }

    func setCompositionLayout(_ mode: CompositionLayoutMode, gridColumns: Int? = nil) {
        guard var layout = snapshot.composition?.layout else {
            return
        }
        layout.mode = mode
        layout.gridColumns = gridColumns
        execute(SetCompositionLayoutCommand(layout: layout))
    }

    func updateCompositionLayout(
        _ mutation: (inout CompositionLayoutConfiguration) -> Void
    ) {
        guard var layout = snapshot.composition?.layout else {
            return
        }
        mutation(&layout)
        execute(SetCompositionLayoutCommand(layout: layout))
    }

    func updateCompositionComparison(_ mutation: (inout CompositionComparisonSettings) -> Void) {
        guard var comparison = snapshot.composition?.comparison else {
            return
        }
        let prior = comparison
        mutation(&comparison)
        if comparison.mode != prior.mode
            || comparison.primaryItemID != prior.primaryItemID
            || comparison.secondaryItemID != prior.secondaryItemID
            || comparison.posterFrame != prior.posterFrame {
            compositionComparisonPreviewPhase = nil
            isCompositionBlinkPreviewPlaying = comparison.mode == .blink
        }
        execute(SetCompositionComparisonCommand(comparison: comparison))
    }

    func updateCompositionSteps(_ mutation: (inout CompositionStepsSettings) -> Void) {
        guard var steps = snapshot.composition?.steps else {
            return
        }
        mutation(&steps)
        execute(SetCompositionStepsCommand(steps: steps))
    }

    func updateCompositionCanvas(_ mutation: (inout CompositionCanvasState) -> Void) {
        guard var canvas = snapshot.composition?.canvas else {
            return
        }
        mutation(&canvas)
        execute(SetCompositionCanvasCommand(canvas: canvas))
    }

    func updateCompositionItem(
        itemID: UUID,
        mutation: (inout CompositionItem) -> Void
    ) {
        guard var composition = snapshot.composition,
              let itemIndex = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        let originalFraming = composition.items[itemIndex].framing
        mutation(&composition.items[itemIndex])
        if composition.items[itemIndex].framing != originalFraming {
            synchronizeLinkedFraming(in: &composition, from: itemID)
        }
        execute(InspectorCompositionCommand(composition: composition, label: "Edit Capture"))
    }

    /// Applies one item mutation to the current selection as one undoable
    /// command. Inspector sliders and toggles use this instead of creating a
    /// separate undo entry for each selected item.
    func updateSelectedCompositionItems(
        label: String,
        mutation: (inout CompositionItem) -> Void
    ) {
        guard var composition = snapshot.composition else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        guard !selectedIDs.isEmpty else {
            return
        }
        let originalFraming = Dictionary(
            uniqueKeysWithValues: composition.items.map { ($0.id, $0.framing) }
        )
        for index in composition.items.indices where selectedIDs.contains(composition.items[index].id) {
            mutation(&composition.items[index])
        }
        var synchronizedGroups = Set<UUID>()
        for itemID in composition.selectedItemIDs.reversed() {
            guard let item = composition.items.first(where: { $0.id == itemID }),
                  let priorFraming = originalFraming[itemID],
                  item.framing != priorFraming,
                  let linkGroupID = item.framing.linkGroupID,
                  synchronizedGroups.insert(linkGroupID).inserted else {
                continue
            }
            synchronizeLinkedFraming(in: &composition, from: itemID)
        }
        execute(InspectorCompositionCommand(composition: composition, label: label))
    }

    func selectCompositionItems(_ itemIDs: [UUID]) {
        execute(SetCompositionSelectionCommand(itemIDs: itemIDs), undoable: false)
    }

    func toggleCompositionItemSelection(_ itemID: UUID) {
        guard let composition = snapshot.composition else {
            return
        }
        var selection = composition.selectedItemIDs
        if let index = selection.firstIndex(of: itemID) {
            selection.remove(at: index)
        } else {
            selection.append(itemID)
        }
        selectCompositionItems(selection)
    }

    func moveSelectedCompositionItems(to destinationIndex: Int) {
        guard let selected = snapshot.composition?.selectedItemIDs, !selected.isEmpty else {
            return
        }
        execute(MoveCompositionItemsCommand(itemIDs: selected, destinationIndex: destinationIndex))
    }

    func moveCompositionItem(_ itemID: UUID, to destinationIndex: Int) {
        guard var composition = snapshot.composition,
              let sourceIndex = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        let item = composition.items.remove(at: sourceIndex)
        let destination = min(max(destinationIndex, 0), composition.items.count)
        composition.items.insert(item, at: destination)
        composition.selectedItemIDs = [itemID]
        execute(InspectorCompositionCommand(composition: composition, label: "Reorder Captures"))
    }

    func duplicateSelectedCompositionItem() {
        guard let itemID = snapshot.composition?.selectedItemIDs.last else {
            return
        }
        execute(DuplicateCompositionItemCommand(itemID: itemID, duplicateItemID: UUID()))
    }

    func excludeSelectedCompositionItems(_ excluded: Bool) {
        guard let composition = snapshot.composition else {
            return
        }
        for itemID in composition.selectedItemIDs {
            updateCompositionItem(itemID: itemID) { $0.isIncluded = !excluded }
        }
    }

    func setSelectedCompositionItemsIncluded(_ included: Bool) {
        updateSelectedCompositionItems(label: included ? "Include Captures" : "Exclude Captures") {
            $0.isIncluded = included
        }
    }

    func setCompositionItems(_ itemIDs: [UUID], included: Bool) {
        guard var composition = snapshot.composition else {
            return
        }
        let requestedIDs = Set(itemIDs)
        for index in composition.items.indices where requestedIDs.contains(composition.items[index].id) {
            composition.items[index].isIncluded = included
        }
        composition.repairComparisonSelection()
        execute(
            InspectorCompositionCommand(
                composition: composition,
                label: included ? "Include Captures" : "Exclude Captures"
            )
        )
    }

    func setCompositionSectionSizing(_ sizing: CompositionSizingMode) {
        guard var composition = snapshot.composition else {
            return
        }
        composition.layout.sizingMode = sizing
        switch sizing {
        case .equal:
            for index in composition.items.indices {
                composition.items[index].weight = 1
            }
        case .weighted:
            if composition.items.count > 1,
               composition.items.map(\.weight).allSatisfy({
                   abs($0 - composition.items[0].weight) <= 0.001
               }) {
                let preferredID = composition.selectedItemIDs.last ?? composition.items[0].id
                if let index = composition.items.firstIndex(where: { $0.id == preferredID }) {
                    composition.items[index].weight = 1.25
                }
            }
        }
        execute(InspectorCompositionCommand(composition: composition, label: "Change Section Sizing"))
    }

    func setCompositionItemRole(_ itemID: UUID, role: CompositionItemSemanticRole) {
        guard var composition = snapshot.composition,
              let index = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        composition.items[index].semanticRole = role
        switch role {
        case .before:
            composition.comparison.primaryItemID = itemID
            if composition.comparison.secondaryItemID == itemID {
                composition.comparison.secondaryItemID = composition.items.first {
                    $0.id != itemID && $0.isIncluded
                }?.id
            }
        case .after:
            composition.comparison.secondaryItemID = itemID
            if composition.comparison.primaryItemID == itemID {
                composition.comparison.primaryItemID = composition.items.first {
                    $0.id != itemID && $0.isIncluded
                }?.id
            }
        case .standard, .step:
            break
        }
        execute(InspectorCompositionCommand(composition: composition, label: "Change Item Role"))
    }

    func setSelectedCompositionFramingLinked(_ linked: Bool) {
        guard var composition = snapshot.composition else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        guard !selectedIDs.isEmpty else {
            return
        }
        let existingGroupID = composition.items
            .first(where: { selectedIDs.contains($0.id) && $0.framing.linkGroupID != nil })?
            .framing
            .linkGroupID
        let groupID = linked ? (existingGroupID ?? UUID()) : nil
        for index in composition.items.indices where selectedIDs.contains(composition.items[index].id) {
            composition.items[index].framing.linkGroupID = groupID
        }
        execute(InspectorCompositionCommand(composition: composition, label: linked ? "Link Item Framing" : "Unlink Item Framing"))
    }

    func resetSelectedCompositionFraming() {
        updateSelectedCompositionItems(label: "Reset Item Framing") { item in
            let linkGroupID = item.framing.linkGroupID
            item.framing = CompositionItemFraming(linkGroupID: linkGroupID)
        }
    }

    func moveSelectedCompositionItemsBy(dx: CGFloat, dy: CGFloat) {
        guard var composition = snapshot.composition else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        guard !selectedIDs.isEmpty else {
            return
        }
        for index in composition.items.indices where selectedIDs.contains(composition.items[index].id) {
            var frame = composition.items[index].freeformFrame
                ?? CGRect(
                    origin: .zero,
                    size: compositionAssetRepository
                        .storedAsset(for: composition.items[index].assetID)?
                        .descriptor
                        .pixelSize
                        ?? CGSize(width: 320, height: 200)
                )
            frame.origin.x += dx
            frame.origin.y += dy
            composition.items[index].freeformFrame = frame
        }
        execute(InspectorCompositionCommand(composition: composition, label: "Move Composition Items"))
    }

    var comparisonFramingIsLinked: Bool {
        guard let composition = snapshot.composition,
              let primaryID = composition.comparison.primaryItemID,
              let secondaryID = composition.comparison.secondaryItemID,
              let primary = composition.items.first(where: { $0.id == primaryID }),
              let secondary = composition.items.first(where: { $0.id == secondaryID }),
              let groupID = primary.framing.linkGroupID else {
            return false
        }
        return secondary.framing.linkGroupID == groupID
    }

    var comparisonFramingMatches: Bool {
        guard let composition = snapshot.composition,
              let primaryID = composition.comparison.primaryItemID,
              let secondaryID = composition.comparison.secondaryItemID,
              let primary = composition.items.first(where: { $0.id == primaryID }),
              let secondary = composition.items.first(where: { $0.id == secondaryID }) else {
            return false
        }
        return primary.framing.contentMode == secondary.framing.contentMode
            && primary.framing.horizontalAlignment == secondary.framing.horizontalAlignment
            && primary.framing.verticalAlignment == secondary.framing.verticalAlignment
            && abs(primary.framing.scale - secondary.framing.scale) <= 0.001
            && abs(primary.framing.offset.width - secondary.framing.offset.width) <= 0.001
            && abs(primary.framing.offset.height - secondary.framing.offset.height) <= 0.001
    }

    func swapCompositionComparisonItems() {
        updateCompositionComparison { comparison in
            swap(&comparison.primaryItemID, &comparison.secondaryItemID)
        }
    }

    func matchCompositionComparisonFraming() {
        guard var composition = snapshot.composition,
              let primaryID = composition.comparison.primaryItemID,
              let secondaryID = composition.comparison.secondaryItemID,
              let primary = composition.items.first(where: { $0.id == primaryID }),
              let secondaryIndex = composition.items.firstIndex(where: { $0.id == secondaryID }) else {
            return
        }
        let linkGroupID = composition.items[secondaryIndex].framing.linkGroupID
        composition.items[secondaryIndex].framing = primary.framing
        if linkGroupID != nil, primary.framing.linkGroupID == nil {
            composition.items[secondaryIndex].framing.linkGroupID = linkGroupID
        }
        execute(InspectorCompositionCommand(composition: composition, label: "Match Comparison Framing"))
    }

    func setCompositionComparisonFramingLinked(_ linked: Bool) {
        guard var composition = snapshot.composition,
              let primaryID = composition.comparison.primaryItemID,
              let secondaryID = composition.comparison.secondaryItemID,
              let primaryIndex = composition.items.firstIndex(where: { $0.id == primaryID }),
              let secondaryIndex = composition.items.firstIndex(where: { $0.id == secondaryID }) else {
            return
        }
        let groupID = linked
            ? (composition.items[primaryIndex].framing.linkGroupID
                ?? composition.items[secondaryIndex].framing.linkGroupID
                ?? UUID())
            : nil
        composition.items[primaryIndex].framing.linkGroupID = groupID
        composition.items[secondaryIndex].framing.linkGroupID = groupID
        composition.comparison.keepsViewsLinked = linked
        execute(InspectorCompositionCommand(composition: composition, label: linked ? "Link Comparison Framing" : "Unlink Comparison Framing"))
    }

    func resetCompositionComparison() {
        guard var composition = snapshot.composition else {
            return
        }
        let primaryID = composition.comparison.primaryItemID
        let secondaryID = composition.comparison.secondaryItemID
        let primaryLabel = composition.comparison.primaryLabel
        let secondaryLabel = composition.comparison.secondaryLabel
        composition.comparison = CompositionComparisonSettings(
            primaryItemID: primaryID,
            secondaryItemID: secondaryID,
            primaryLabel: primaryLabel,
            secondaryLabel: secondaryLabel
        )
        if let primaryID,
           let secondaryID,
           let primaryIndex = composition.items.firstIndex(where: { $0.id == primaryID }),
           let secondaryIndex = composition.items.firstIndex(where: { $0.id == secondaryID }) {
            let groupID = composition.items[primaryIndex].framing.linkGroupID
                ?? composition.items[secondaryIndex].framing.linkGroupID
                ?? UUID()
            composition.items[primaryIndex].framing.linkGroupID = groupID
            composition.items[secondaryIndex].framing.linkGroupID = groupID
        }
        compositionComparisonPreviewPhase = nil
        isCompositionBlinkPreviewPlaying = true
        execute(InspectorCompositionCommand(composition: composition, label: "Reset Comparison"))
    }

    func removeSelectedCompositionItems() {
        guard let itemIDs = snapshot.composition?.selectedItemIDs else {
            return
        }
        removeCompositionItemsPreservingAnchorPositions(itemIDs)
    }

    func removeCompositionItemsPreservingAnchorPositions(_ itemIDs: [UUID]) {
        guard let composition = snapshot.composition else {
            return
        }
        let resolvedAnchors: [UUID: CompositionAnnotationAnchors]
        if let layout = try? currentCompositionRenderLayout() {
            resolvedAnchors = composition.canvas.annotationAnchors.mapValues { anchors in
                CompositionAnnotationAnchors(
                    primary: anchors.primary.updatingLastCanvasPoint(
                        CompositionRenderer.resolvedCanvasPoint(
                            for: anchors.primary,
                            layout: layout
                        )
                    ),
                    secondary: anchors.secondary.map { secondary in
                        secondary.updatingLastCanvasPoint(
                            CompositionRenderer.resolvedCanvasPoint(
                                for: secondary,
                                layout: layout
                            )
                        )
                    }
                )
            }
        } else {
            resolvedAnchors = [:]
        }
        execute(
            RemoveCompositionItemsCommand(
                itemIDs: itemIDs,
                resolvedAnchors: resolvedAnchors
            )
        )
    }

    func compositionAssetsForRendering() throws -> [UUID: CompositionAsset] {
        guard let composition = snapshot.composition else {
            return [:]
        }
        return try compositionAssetRepository.assets(
            for: Set(composition.items.filter(\.isIncluded).map(\.assetID))
        )
    }

    /// Captures a stable, encoded-only input for background package,
    /// recovery, and history preview work. The detached renderer receives its
    /// own repository so later editor mutations cannot change the preview
    /// halfway through a write.
    func compositionDocumentPreviewInput(
        snapshot requestedSnapshot: EditorSnapshot? = nil
    ) -> CompositionDocumentPreviewInput {
        let currentSession = documentSession
        let resolvedSnapshot = requestedSnapshot ?? currentSession.currentSnapshot
        let referencedAssetIDs = Set(
            resolvedSnapshot.composition?.items.map(\.assetID) ?? []
        )
        let previewRepository = CompositionAssetRepository(
            storedAssets: compositionAssetRepository.storedAssets(
                referencedBy: referencedAssetIDs
            )
        )
        return CompositionDocumentPreviewInput(
            baseImage: documentCapture.image,
            snapshot: resolvedSnapshot,
            assetRepository: previewRepository,
            pinnedUIMapElements: pinnedUIMapElements,
            uiMapOverlayOptions: uiMapOverlayOptions,
            isPrivate: isPrivateDocument
        )
    }

    func compositionThumbnail(for itemID: UUID, maxPixelDimension: Int = 240) -> CGImage? {
        guard let assetID = snapshot.composition?.items.first(where: { $0.id == itemID })?.assetID else {
            return nil
        }
        return try? compositionAssetRepository.thumbnail(
            for: assetID,
            maxPixelDimension: maxPixelDimension
        )
    }

    func compositionCapture(for itemID: UUID) throws -> CapturedScreenshot {
        guard let assetID = snapshot.composition?.items.first(where: { $0.id == itemID })?.assetID else {
            throw CompositionLayoutError.emptyComposition
        }
        return try compositionAssetRepository.capturedScreenshot(for: assetID)
    }

    func attachUIMap(_ uiMap: UIMapSnapshot?, toCompositionAsset assetID: UUID) {
        do {
            try compositionAssetRepository.replaceUIMap(for: assetID, with: uiMap)
            persistenceRevision += 1
            invalidateCompositionContent()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func compositionItem(
        for capture: CapturedScreenshot,
        assetID: UUID
    ) -> CompositionItem {
        CompositionItem(
            assetID: assetID,
            editState: editState(for: capture),
            title: capture.sourceName,
            accessibilityLabel: capture.sourceName
        )
    }

    private static func editState(for capture: CapturedScreenshot) -> ScreenshotEditState {
        let annotations = capture.cursorOverlay.map {
            [Annotation.makeImageOverlay(image: $0.image, in: $0.rect, role: .capturedCursor)]
        } ?? []
        return ScreenshotEditState(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(width: capture.image.width, height: capture.image.height)
            ),
            annotations: annotations
        )
    }

    private func synchronizeLinkedFraming(
        in composition: inout CompositionSnapshot,
        from sourceItemID: UUID
    ) {
        guard let source = composition.items.first(where: { $0.id == sourceItemID }),
              let linkGroupID = source.framing.linkGroupID else {
            return
        }
        for index in composition.items.indices
        where composition.items[index].id != sourceItemID
            && composition.items[index].framing.linkGroupID == linkGroupID {
            composition.items[index].framing = source.framing
        }
    }
}

private nonisolated extension CompositionAnnotationAnchor {
    func updatingLastCanvasPoint(
        _ point: CGPoint
    ) -> CompositionAnnotationAnchor {
        CompositionAnnotationAnchor(
            target: target,
            lastCanvasPoint: point
        )
    }
}

/// A focused whole-composition command used for inspector operations that
/// mutate multiple related fields atomically.
nonisolated struct InspectorCompositionCommand: DocumentCommand {
    let composition: CompositionSnapshot
    let label: String

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.composition = composition
        updated.composition?.repairComparisonSelection()
        return updated
    }
}
