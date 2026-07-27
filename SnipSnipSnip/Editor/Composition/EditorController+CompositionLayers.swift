import CoreGraphics
import Foundation

/// The annotation-bearing scopes exposed by the Layers window. Items are
/// represented separately because their selection and ordering live on
/// `CompositionSnapshot`, rather than in an annotation edit state.
nonisolated enum CompositionAnnotationLayerScope: Hashable, Sendable {
    case composition
    case item(UUID)
}

nonisolated enum CompositionLayerArrangement: Sendable {
    case front
    case forward
    case backward
    case back
}

extension EditorController {
    func annotations(in layerScope: CompositionAnnotationLayerScope) -> [Annotation] {
        switch layerScope {
        case .composition:
            return snapshot.composition?.canvas.annotations ?? []
        case .item(let itemID):
            return snapshot.composition?.items
                .first(where: { $0.id == itemID })?
                .editState
                .annotations
                ?? []
        }
    }

    func selectedAnnotationIDs(in layerScope: CompositionAnnotationLayerScope) -> [UUID] {
        switch layerScope {
        case .composition:
            return snapshot.composition?.canvas.selectedAnnotationIDs ?? []
        case .item(let itemID):
            return snapshot.composition?.items
                .first(where: { $0.id == itemID })?
                .editState
                .selectedAnnotationIDs
                ?? []
        }
    }

    func selectLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) {
        let expandedIDs = expandedLayerAnnotationIDs(annotationIDs, in: layerScope)
        applyLayerAnnotationCommand(
            SetSelectionCommand(annotationIDs: expandedIDs),
            in: layerScope,
            undoable: false
        )
    }

    func toggleLayerAnnotationSelection(
        _ annotationID: UUID,
        in layerScope: CompositionAnnotationLayerScope
    ) {
        let toggledIDs = Set(expandedLayerAnnotationIDs([annotationID], in: layerScope))
        guard !toggledIDs.isEmpty else {
            return
        }
        var selectedIDs = Set(selectedAnnotationIDs(in: layerScope))
        if toggledIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(toggledIDs)
        } else {
            selectedIDs.formUnion(toggledIDs)
        }
        let orderedIDs = annotations(in: layerScope).compactMap {
            selectedIDs.contains($0.id) ? $0.id : nil
        }
        selectLayerAnnotations(orderedIDs, in: layerScope)
    }

    func reorderLayerAnnotations(
        frontToBackAnnotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) {
        applyLayerAnnotationCommand(
            SetAnnotationOrderCommand(
                annotationIDsBackToFront: Array(frontToBackAnnotationIDs.reversed())
            ),
            in: layerScope
        )
    }

    func arrangeLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope,
        arrangement: CompositionLayerArrangement
    ) {
        let expandedIDs = expandedLayerAnnotationIDs(annotationIDs, in: layerScope)
        let direction: ReorderDirection
        let distance: ReorderDistance
        switch arrangement {
        case .front:
            direction = .forward
            distance = .extreme
        case .forward:
            direction = .forward
            distance = .one
        case .backward:
            direction = .backward
            distance = .one
        case .back:
            direction = .backward
            distance = .extreme
        }
        applyLayerAnnotationCommand(
            ReorderAnnotationsCommand(
                annotationIDs: expandedIDs,
                direction: direction,
                distance: distance
            ),
            in: layerScope
        )
    }

    func deleteLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) {
        let expandedIDs = expandedLayerAnnotationIDs(annotationIDs, in: layerScope)
        guard !expandedIDs.isEmpty else {
            return
        }
        applyLayerAnnotationCommand(
            DeleteAnnotationsCommand(annotationIDs: expandedIDs),
            in: layerScope
        )
    }

    func groupLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) {
        guard annotationIDs.count > 1 else {
            return
        }
        applyLayerAnnotationCommand(
            SetGroupCommand(annotationIDs: annotationIDs, groupID: UUID()),
            in: layerScope
        )
    }

    func ungroupLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) {
        let groupIDs = Set(
            annotations(in: layerScope).compactMap { annotation in
                annotationIDs.contains(annotation.id) ? annotation.groupID : nil
            }
        )
        let groupedIDs = annotations(in: layerScope).compactMap { annotation -> UUID? in
            guard let groupID = annotation.groupID, groupIDs.contains(groupID) else {
                return nil
            }
            return annotation.id
        }
        guard !groupedIDs.isEmpty else {
            return
        }
        applyLayerAnnotationCommand(
            SetGroupCommand(annotationIDs: groupedIDs, groupID: nil),
            in: layerScope
        )
        selectLayerAnnotations(groupedIDs, in: layerScope)
    }

    func canArrangeLayerAnnotations(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope,
        arrangement: CompositionLayerArrangement
    ) -> Bool {
        let annotations = annotations(in: layerScope)
        let expandedIDs = expandedLayerAnnotationIDs(annotationIDs, in: layerScope)
        let selectedIndices = annotations.indices.filter {
            expandedIDs.contains(annotations[$0].id)
        }
        guard let minimum = selectedIndices.min(),
              let maximum = selectedIndices.max(),
              !selectedIndices.isEmpty else {
            return false
        }
        switch arrangement {
        case .front, .forward:
            return maximum < annotations.count - 1
        case .backward, .back:
            return minimum > 0
        }
    }

    func arrangeCompositionLayerItems(
        _ itemIDs: [UUID],
        arrangement: CompositionLayerArrangement
    ) {
        guard var composition = snapshot.composition else {
            return
        }
        let selectedIDs = Set(itemIDs)
        let movingItems = composition.items.filter { selectedIDs.contains($0.id) }
        guard !movingItems.isEmpty, movingItems.count < composition.items.count else {
            return
        }

        let selectedIndices = composition.items.indices.filter {
            selectedIDs.contains(composition.items[$0].id)
        }
        guard let minimum = selectedIndices.min(), let maximum = selectedIndices.max() else {
            return
        }

        var remainingItems = composition.items.filter { !selectedIDs.contains($0.id) }
        let destination: Int
        switch arrangement {
        case .front:
            destination = 0
        case .forward:
            guard minimum > 0 else {
                return
            }
            destination = minimum - 1
        case .backward:
            guard maximum < composition.items.count - 1 else {
                return
            }
            destination = min(minimum + 1, remainingItems.count)
        case .back:
            destination = remainingItems.count
        }
        remainingItems.insert(contentsOf: movingItems, at: destination)
        composition.items = remainingItems
        composition.selectedItemIDs = composition.items.compactMap {
            selectedIDs.contains($0.id) ? $0.id : nil
        }
        if composition.layout.mode == .freeform {
            for index in composition.items.indices {
                composition.items[index].zIndex = index + 1
            }
        }
        execute(
            CompositionLayersSnapshotCommand(
                composition: composition,
                label: "Reorder Captures"
            )
        )
    }

    func moveCompositionLayerItems(_ itemIDs: [UUID], to destinationIndex: Int) {
        guard var composition = snapshot.composition else {
            return
        }
        let requestedIDs = Set(itemIDs)
        let movingItems = composition.items.filter { requestedIDs.contains($0.id) }
        guard !movingItems.isEmpty else {
            return
        }
        var remainingItems = composition.items.filter { !requestedIDs.contains($0.id) }
        let insertionIndex = min(max(destinationIndex, 0), remainingItems.count)
        remainingItems.insert(contentsOf: movingItems, at: insertionIndex)
        guard remainingItems.map(\.id) != composition.items.map(\.id) else {
            return
        }
        composition.items = remainingItems
        composition.selectedItemIDs = composition.items.compactMap {
            requestedIDs.contains($0.id) ? $0.id : nil
        }
        if composition.layout.mode == .freeform {
            for index in composition.items.indices {
                composition.items[index].zIndex = index + 1
            }
        }
        execute(
            CompositionLayersSnapshotCommand(
                composition: composition,
                label: "Reorder Captures"
            )
        )
    }

    func canArrangeCompositionLayerItems(
        _ itemIDs: [UUID],
        arrangement: CompositionLayerArrangement
    ) -> Bool {
        guard let items = snapshot.composition?.items else {
            return false
        }
        let selectedIDs = Set(itemIDs)
        let selectedIndices = items.indices.filter { selectedIDs.contains(items[$0].id) }
        guard let minimum = selectedIndices.min(),
              let maximum = selectedIndices.max(),
              !selectedIndices.isEmpty,
              selectedIndices.count < items.count else {
            return false
        }
        switch arrangement {
        case .front, .forward:
            return minimum > 0
        case .backward, .back:
            return maximum < items.count - 1
        }
    }

    func duplicateCompositionLayerItems(_ itemIDs: [UUID]) {
        guard var composition = snapshot.composition else {
            return
        }
        let requestedIDs = Set(itemIDs)
        guard !requestedIDs.isEmpty else {
            return
        }

        var duplicateIDs: [UUID] = []
        var insertionOffset = 0
        for originalIndex in composition.items.indices {
            let sourceIndex = originalIndex + insertionOffset
            let source = composition.items[sourceIndex]
            guard requestedIDs.contains(source.id) else {
                continue
            }
            let duplicateID = UUID()
            let duplicate = CompositionItem(
                id: duplicateID,
                assetID: source.assetID,
                editState: source.editState,
                framing: source.framing,
                opacity: source.opacity,
                weight: source.weight,
                title: source.title,
                caption: source.caption,
                accessibilityLabel: source.accessibilityLabel,
                freeformFrame: source.freeformFrame?.offsetBy(dx: 24, dy: 24),
                isIncluded: source.isIncluded,
                semanticRole: source.semanticRole,
                zIndex: source.zIndex + 1
            )
            composition.items.insert(duplicate, at: sourceIndex + 1)
            duplicateIDs.append(duplicateID)
            insertionOffset += 1
        }
        guard !duplicateIDs.isEmpty else {
            return
        }
        composition.selectedItemIDs = duplicateIDs
        if composition.layout.mode == .freeform {
            for index in composition.items.indices {
                composition.items[index].zIndex = index + 1
            }
        }
        composition.repairComparisonSelection()
        execute(
            CompositionLayersSnapshotCommand(
                composition: composition,
                label: "Duplicate Captures"
            )
        )
    }

    func removeCompositionLayerItems(_ itemIDs: [UUID]) {
        guard let composition = snapshot.composition else {
            return
        }
        let validIDs = Set(composition.items.map(\.id)).intersection(itemIDs)
        guard !validIDs.isEmpty, validIDs.count < composition.items.count else {
            return
        }
        if case .item(let editingItemID) = compositionEditingScope,
           validIDs.contains(editingItemID) {
            finishCompositionEditing()
        }
        removeCompositionItemsPreservingAnchorPositions(Array(validIDs))
    }

    func canRemoveCompositionLayerItems(_ itemIDs: [UUID]) -> Bool {
        guard let items = snapshot.composition?.items else {
            return false
        }
        let validIDs = Set(items.map(\.id)).intersection(itemIDs)
        return !validIDs.isEmpty && validIDs.count < items.count
    }

    func editCompositionLayerItem(_ itemID: UUID) {
        switch compositionEditingScope {
        case .layout:
            break
        case .composition:
            finishCompositionEditing()
        case .item(let currentID):
            if currentID == itemID {
                return
            }
            finishCompositionEditing()
        }
        selectCompositionItems([itemID])
        enterCompositionItemEditing(itemID)
    }

    func editCompositionLayerCanvas() {
        switch compositionEditingScope {
        case .composition:
            return
        case .item:
            finishCompositionEditing()
        case .layout:
            break
        }
        enterCompositionEditing()
    }

    private func applyLayerAnnotationCommand(
        _ command: DocumentCommand,
        in layerScope: CompositionAnnotationLayerScope,
        undoable: Bool = true
    ) {
        if layerScope.matches(compositionEditingScope) {
            execute(command, undoable: undoable)
            return
        }

        guard var composition = snapshot.composition else {
            return
        }
        var projected = snapshot
        let originalAnnotations: [Annotation]
        switch layerScope {
        case .composition:
            let canvas = composition.canvas
            originalAnnotations = canvas.annotations
            projected.annotations = canvas.annotations
            projected.selectedAnnotationIDs = canvas.selectedAnnotationIDs
            projected.nextCalloutNumber = canvas.nextCalloutNumber
        case .item(let itemID):
            guard let item = composition.items.first(where: { $0.id == itemID }) else {
                return
            }
            originalAnnotations = item.editState.annotations
            projected.cropRect = item.editState.cropRect
                ?? projected.cropRect
            projected.annotations = item.editState.annotations
            projected.selectedAnnotationIDs = item.editState.selectedAnnotationIDs
            projected.nextCalloutNumber = item.editState.nextCalloutNumber
            projected.pinnedUIMapElementIDs = item.editState.pinnedUIMapElementIDs
        }

        let updated = command.apply(to: projected)
        guard updated.annotations != originalAnnotations
                || updated.selectedAnnotationIDs != projected.selectedAnnotationIDs
                || updated.nextCalloutNumber != projected.nextCalloutNumber else {
            return
        }

        switch layerScope {
        case .composition:
            composition.canvas.annotations = updated.annotations
            composition.canvas.selectedAnnotationIDs = updated.selectedAnnotationIDs
            composition.canvas.nextCalloutNumber = updated.nextCalloutNumber
            let remainingIDs = Set(updated.annotations.map(\.id))
            composition.canvas.annotationAnchors = composition.canvas.annotationAnchors.filter {
                remainingIDs.contains($0.key)
            }
        case .item(let itemID):
            guard let itemIndex = composition.items.firstIndex(where: { $0.id == itemID }) else {
                return
            }
            composition.items[itemIndex].editState.annotations = updated.annotations
            composition.items[itemIndex].editState.selectedAnnotationIDs = updated.selectedAnnotationIDs
            composition.items[itemIndex].editState.nextCalloutNumber = updated.nextCalloutNumber
        }
        execute(
            CompositionLayersSnapshotCommand(
                composition: composition,
                label: command.label
            ),
            undoable: undoable
        )
    }

    private func expandedLayerAnnotationIDs(
        _ annotationIDs: [UUID],
        in layerScope: CompositionAnnotationLayerScope
    ) -> [UUID] {
        let annotations = annotations(in: layerScope)
        let requestedIDs = Set(annotationIDs)
        let requestedGroupIDs = Set(
            annotations.compactMap { annotation in
                requestedIDs.contains(annotation.id) ? annotation.groupID : nil
            }
        )
        return annotations.compactMap { annotation -> UUID? in
            if requestedIDs.contains(annotation.id) {
                return annotation.id
            }
            if let groupID = annotation.groupID, requestedGroupIDs.contains(groupID) {
                return annotation.id
            }
            return nil
        }
    }
}

nonisolated private extension CompositionAnnotationLayerScope {
    func matches(_ editingScope: CompositionEditingScope) -> Bool {
        switch (self, editingScope) {
        case (.composition, .composition):
            return true
        case (.item(let expected), .item(let current)):
            return expected == current
        default:
            return false
        }
    }
}

nonisolated private struct CompositionLayersSnapshotCommand: DocumentCommand {
    let composition: CompositionSnapshot
    let label: String

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.composition = composition
        updated.composition?.repairComparisonSelection()
        return updated
    }
}
