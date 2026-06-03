import CoreGraphics
import Foundation

nonisolated protocol DocumentCommand {
    var label: String { get }
    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot
}

nonisolated struct AddAnnotationCommand: DocumentCommand {
    let annotation: Annotation

    var label: String { "Add Annotation" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.annotations.append(annotation)

        if case let .callout(shape) = annotation.kind {
            updated.nextCalloutNumber = max(updated.nextCalloutNumber, shape.number + 1)
        }

        updated.selectedAnnotationIDs = [annotation.id]
        return updated
    }
}

nonisolated struct UpdateAnnotationsCommand: DocumentCommand {
    let annotations: [Annotation]

    var label: String { "Update Annotations" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        let mapped = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

        updated.annotations = updated.annotations.map { annotation in
            mapped[annotation.id] ?? annotation
        }

        updated.selectedAnnotationIDs = updated.selectedAnnotationIDs.filter { id in
            updated.annotations.contains(where: { $0.id == id })
        }
        return updated
    }
}

nonisolated struct UpdateAnnotationCommand: DocumentCommand {
    let annotation: Annotation

    var label: String { "Update Annotation" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        UpdateAnnotationsCommand(annotations: [annotation]).apply(to: snapshot)
    }
}

nonisolated struct SetGroupCommand: DocumentCommand {
    let annotationIDs: [UUID]
    let groupID: UUID?

    var label: String {
        groupID == nil ? "Ungroup Selection" : "Group Selection"
    }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        let idSet = Set(annotationIDs)
        let updatedAnnotations = snapshot.annotations.map { annotation in
            guard idSet.contains(annotation.id) else {
                return annotation
            }

            return annotation.updatingGroup(groupID)
        }

        var updated = snapshot
        updated.annotations = updatedAnnotations
        return updated
    }
}

nonisolated struct DeleteAnnotationsCommand: DocumentCommand {
    let annotationIDs: [UUID]

    var label: String { "Delete Selection" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        let idSet = Set(annotationIDs)
        var updated = snapshot
        updated.annotations.removeAll { idSet.contains($0.id) }
        updated.selectedAnnotationIDs.removeAll { idSet.contains($0) }
        return updated
    }
}

nonisolated struct SetCropCommand: DocumentCommand {
    let rect: CGRect

    var label: String { "Set Crop" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.cropRect = rect.standardized.integral
        return updated
    }
}

nonisolated struct SetSelectionCommand: DocumentCommand {
    let annotationIDs: [UUID]

    init(annotationID: UUID?) {
        self.annotationIDs = annotationID.map { [$0] } ?? []
    }

    init(annotationIDs: [UUID]) {
        self.annotationIDs = annotationIDs
    }

    var label: String { "Set Selection" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        var unique: [UUID] = []

        for id in annotationIDs where !unique.contains(id) {
            unique.append(id)
        }

        updated.selectedAnnotationIDs = unique
        return updated
    }
}

nonisolated struct SetPresentationCommand: DocumentCommand {
    let presentation: ScreenshotPresentation

    var label: String { "Set Presentation" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        var updated = snapshot
        updated.presentation = presentation
        return updated
    }
}

// MARK: - Layer Reordering

nonisolated enum ReorderDirection {
    case forward  // toward end of array (higher z-order)
    case backward // toward start of array (lower z-order)
}

nonisolated enum ReorderDistance {
    case one      // move one position
    case extreme  // move to front or back
}

nonisolated struct ReorderAnnotationsCommand: DocumentCommand {
    let annotationIDs: [UUID]
    let direction: ReorderDirection
    let distance: ReorderDistance

    var label: String {
        switch (direction, distance) {
        case (.forward, .one): return "Bring Forward"
        case (.backward, .one): return "Send Backward"
        case (.forward, .extreme): return "Bring to Front"
        case (.backward, .extreme): return "Send to Back"
        }
    }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        let idSet = Set(annotationIDs)
        var annotations = snapshot.annotations

        // Find indices of selected annotations
        let selectedIndices = annotations.enumerated().compactMap { index, annotation in
            idSet.contains(annotation.id) ? index : nil
        }

        guard !selectedIndices.isEmpty else {
            return snapshot
        }

        let minIndex = selectedIndices.min()!
        let maxIndex = selectedIndices.max()!
        let selectedCount = selectedIndices.count

        // Extract selected annotations in their current order
        let selectedAnnotations = selectedIndices.sorted().map { annotations[$0] }

        switch (direction, distance) {
        case (.forward, .one):
            // Already at top if the highest selected index is the last element
            guard maxIndex < annotations.count - 1 else {
                return snapshot
            }
            // Remove selected annotations (highest to lowest to preserve indices)
            for index in selectedIndices.sorted(by: >) {
                annotations.remove(at: index)
            }
            // After removal, the insert position is maxIndex - selectedCount + 2
            // (the element at maxIndex+1 shifts down by selectedCount, we insert after it)
            let insertIndex = maxIndex - selectedCount + 2
            for (offset, annotation) in selectedAnnotations.enumerated() {
                annotations.insert(annotation, at: insertIndex + offset)
            }

        case (.backward, .one):
            // Already at bottom if the lowest selected index is 0
            guard minIndex > 0 else {
                return snapshot
            }
            // Remove selected annotations (highest to lowest to preserve indices)
            for index in selectedIndices.sorted(by: >) {
                annotations.remove(at: index)
            }
            // After removal, the insert position is minIndex - selectedCount
            // (because minIndex was reduced by the number of selected items that were before it, which is 0)
            // Actually, minIndex items are all removed, so the position shifts by the count of removed items before minIndex
            // Since minIndex is the lowest, no selected items are before it, so insertIndex = minIndex
            // But we want to insert BEFORE the item that was at minIndex - 1
            // After removal, that item is now at minIndex - 1 (unchanged since nothing before minIndex was removed)
            let insertIndex = minIndex - 1
            for (offset, annotation) in selectedAnnotations.enumerated() {
                annotations.insert(annotation, at: insertIndex + offset)
            }

        case (.forward, .extreme):
            // Move to end of array (top)
            guard maxIndex < annotations.count - 1 else {
                return snapshot // Already at top
            }
            for index in selectedIndices.sorted(by: >) {
                annotations.remove(at: index)
            }
            annotations.append(contentsOf: selectedAnnotations)

        case (.backward, .extreme):
            // Move to start of array (bottom)
            guard minIndex > 0 else {
                return snapshot // Already at bottom
            }
            for index in selectedIndices.sorted(by: >) {
                annotations.remove(at: index)
            }
            for (offset, annotation) in selectedAnnotations.enumerated().reversed() {
                annotations.insert(annotation, at: offset)
            }
        }

        var updated = snapshot
        updated.annotations = annotations
        return updated
    }
}
