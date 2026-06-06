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
        var annotations = snapshot.annotations
        let selectedIndices = snapshot.selectedAnnotationIndices(in: annotationIDs)

        guard !selectedIndices.isEmpty else {
            return snapshot
        }

        guard let minIndex = selectedIndices.min(),
              let maxIndex = selectedIndices.max() else {
            return snapshot
        }

        let selectedCount = selectedIndices.count
        let selectedAnnotations = selectedIndices.sorted().map { annotations[$0] }

        switch (direction, distance) {
        case (.forward, .one):
            guard maxIndex < annotations.count - 1 else {
                return snapshot
            }
            annotations.remove(at: selectedIndices)
            let insertIndex = maxIndex - selectedCount + 2
            annotations.insert(contentsOf: selectedAnnotations, at: insertIndex)

        case (.backward, .one):
            guard minIndex > 0 else {
                return snapshot
            }
            annotations.remove(at: selectedIndices)
            annotations.insert(contentsOf: selectedAnnotations, at: minIndex - 1)

        case (.forward, .extreme):
            guard maxIndex < annotations.count - 1 else {
                return snapshot
            }
            annotations.remove(at: selectedIndices)
            annotations.append(contentsOf: selectedAnnotations)

        case (.backward, .extreme):
            guard minIndex > 0 else {
                return snapshot
            }
            annotations.remove(at: selectedIndices)
            annotations.insert(contentsOf: selectedAnnotations, at: 0)
        }

        var updated = snapshot
        updated.annotations = annotations
        return updated
    }
}

private extension Array {
    nonisolated mutating func remove(at indices: [Index]) {
        for index in indices.sorted(by: >) {
            remove(at: index)
        }
    }
}
