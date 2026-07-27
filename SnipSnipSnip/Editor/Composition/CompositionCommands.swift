import CoreGraphics
import Foundation

nonisolated struct SetCompositionCommand: DocumentCommand {
    let composition: CompositionSnapshot?

    var label: String { "Set Composition" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct AddCompositionItemCommand: DocumentCommand {
    let item: CompositionItem
    let afterItemID: UUID?

    var label: String { "Add Capture" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition,
              !composition.items.contains(where: { $0.id == item.id }) else {
            return snapshot
        }

        if !composition.isActivated, !composition.items.isEmpty {
            composition.items[0].editState = ScreenshotEditState(
                cropRect: snapshot.cropRect,
                annotations: snapshot.annotations,
                selectedAnnotationIDs: snapshot.selectedAnnotationIDs,
                nextCalloutNumber: snapshot.nextCalloutNumber,
                pinnedUIMapElementIDs: snapshot.pinnedUIMapElementIDs
            )
        }
        if let afterItemID,
           let index = composition.items.firstIndex(where: { $0.id == afterItemID }) {
            composition.items.insert(item, at: composition.items.index(after: index))
        } else {
            composition.items.append(item)
        }
        composition.isActivated = true
        composition.selectedItemIDs = [item.id]
        composition.repairComparisonSelection()

        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct RemoveCompositionItemsCommand: DocumentCommand {
    let itemIDs: [UUID]
    let resolvedAnchors: [UUID: CompositionAnnotationAnchors]

    init(
        itemIDs: [UUID],
        resolvedAnchors: [UUID: CompositionAnnotationAnchors] = [:]
    ) {
        self.itemIDs = itemIDs
        self.resolvedAnchors = resolvedAnchors
    }

    var label: String { "Remove Capture" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }

        let requestedIDs = Set(itemIDs)
        var removableIDs = Set(composition.items.map(\.id)).intersection(requestedIDs)
        if removableIDs.count == composition.items.count,
           let protectedID = composition.items.first?.id {
            removableIDs.remove(protectedID)
        }
        guard !removableIDs.isEmpty else {
            return snapshot
        }

        composition.canvas.annotationAnchors = Dictionary(
            uniqueKeysWithValues: composition.canvas.annotationAnchors.map { annotationID, anchors in
                let current = resolvedAnchors[annotationID] ?? anchors
                return (
                    annotationID,
                    CompositionAnnotationAnchors(
                        primary: current.primary.detachingIfNeeded(from: removableIDs),
                        secondary: current.secondary?.detachingIfNeeded(from: removableIDs)
                    )
                )
            }
        )
        composition.items.removeAll { removableIDs.contains($0.id) }
        composition.selectedItemIDs.removeAll { removableIDs.contains($0) }
        if composition.selectedItemIDs.isEmpty, let first = composition.items.first {
            composition.selectedItemIDs = [first.id]
        }
        composition.repairComparisonSelection()

        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated private extension CompositionAnnotationAnchor {
    func detachingIfNeeded(from removedItemIDs: Set<UUID>) -> CompositionAnnotationAnchor {
        guard case .itemNormalized(let itemID, _) = target,
              removedItemIDs.contains(itemID) else {
            return self
        }
        return CompositionAnnotationAnchor(
            target: .detachedCanvas(lastCanvasPoint),
            lastCanvasPoint: lastCanvasPoint
        )
    }
}

nonisolated struct MoveCompositionItemsCommand: DocumentCommand {
    let itemIDs: [UUID]
    let destinationIndex: Int

    var label: String { "Reorder Captures" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }

        let movingIDs = Set(itemIDs)
        let moving = composition.items.filter { movingIDs.contains($0.id) }
        guard !moving.isEmpty else {
            return snapshot
        }

        var remaining = composition.items.filter { !movingIDs.contains($0.id) }
        let insertion = min(max(destinationIndex, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        composition.items = remaining

        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct DuplicateCompositionItemCommand: DocumentCommand {
    let itemID: UUID
    let duplicateItemID: UUID

    var label: String { "Duplicate Capture" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition,
              let index = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return snapshot
        }

        let source = composition.items[index]
        let duplicate = CompositionItem(
            id: duplicateItemID,
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
        composition.items.insert(duplicate, at: composition.items.index(after: index))
        composition.isActivated = true
        composition.selectedItemIDs = [duplicate.id]

        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct ReplaceCompositionItemCommand: DocumentCommand {
    let itemID: UUID
    let assetID: UUID
    let editState: ScreenshotEditState
    let title: String

    var label: String { "Replace Capture" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        updateItem(in: snapshot, itemID: itemID) { item in
            item = CompositionItem(
                id: item.id,
                assetID: assetID,
                editState: editState,
                framing: item.framing,
                opacity: item.opacity,
                weight: item.weight,
                title: title,
                caption: item.caption,
                accessibilityLabel: item.accessibilityLabel,
                freeformFrame: item.freeformFrame,
                isIncluded: item.isIncluded,
                semanticRole: item.semanticRole,
                zIndex: item.zIndex
            )
        }
    }
}

nonisolated struct SetCompositionSelectionCommand: DocumentCommand {
    let itemIDs: [UUID]

    var label: String { "Select Captures" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        let validIDs = Set(composition.items.map(\.id))
        composition.selectedItemIDs = itemIDs.filter { validIDs.contains($0) }
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct SetCompositionLayoutCommand: DocumentCommand {
    let layout: CompositionLayoutConfiguration

    var label: String { "Change Composition Layout" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        composition.layout = layout
        composition.repairComparisonSelection()
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct SetCompositionComparisonCommand: DocumentCommand {
    let comparison: CompositionComparisonSettings

    var label: String { "Change Comparison" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        composition.comparison = comparison
        composition.repairComparisonSelection()
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct SetCompositionStepsCommand: DocumentCommand {
    let steps: CompositionStepsSettings

    var label: String { "Change Steps" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        composition.steps = steps
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct SetCompositionCanvasCommand: DocumentCommand {
    let canvas: CompositionCanvasState

    var label: String { "Change Composition Canvas" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard var composition = snapshot.composition else {
            return snapshot
        }
        composition.canvas = canvas
        var updated = snapshot
        updated.composition = composition
        return updated
    }
}

nonisolated struct UpdateCompositionItemCommand: DocumentCommand {
    let item: CompositionItem

    var label: String { "Edit Capture" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = updateItem(in: snapshot, itemID: item.id) { $0 = item }
        updated.composition?.repairComparisonSelection()
        return updated
    }
}

nonisolated private func updateItem(
    in snapshot: EditorSnapshot,
    itemID: UUID,
    mutation: (inout CompositionItem) -> Void
) -> EditorSnapshot {
    guard var composition = snapshot.composition,
          let index = composition.items.firstIndex(where: { $0.id == itemID }) else {
        return snapshot
    }

    mutation(&composition.items[index])
    var updated = snapshot
    updated.composition = composition
    return updated
}

nonisolated extension CompositionSnapshot {
    mutating func repairComparisonSelection() {
        let includedIDs = items.filter(\.isIncluded).map(\.id)
        guard includedIDs.count >= 2 else {
            comparison.primaryItemID = nil
            comparison.secondaryItemID = nil
            return
        }

        if !includedIDs.contains(comparison.primaryItemID ?? UUID()) {
            comparison.primaryItemID = includedIDs.first
        }
        if !includedIDs.contains(comparison.secondaryItemID ?? UUID())
            || comparison.secondaryItemID == comparison.primaryItemID {
            comparison.secondaryItemID = includedIDs.first { $0 != comparison.primaryItemID }
        }
    }
}
