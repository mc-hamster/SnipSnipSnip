import AppKit
import Foundation

nonisolated enum AnnotationAccessibilityAction: String, CaseIterable, Sendable {
    case select
    case toggleSelection
    case editText
    case delete
    case duplicate
    case bringForward
    case sendBackward
    case bringToFront
    case sendToBack
    case group
    case ungroup

    var title: String {
        switch self {
        case .select: "Select"
        case .toggleSelection: "Toggle Selection"
        case .editText: "Edit Text"
        case .delete: "Delete"
        case .duplicate: "Duplicate"
        case .bringForward: "Bring Forward"
        case .sendBackward: "Send Backward"
        case .bringToFront: "Bring to Front"
        case .sendToBack: "Send to Back"
        case .group: "Group"
        case .ungroup: "Ungroup"
        }
    }
}

nonisolated struct AnnotationAccessibilityDescriptor: Equatable, Sendable {
    let id: UUID
    let type: String
    let visibleText: String?
    let isSelected: Bool
    let layerPosition: Int
    let layerCount: Int
    let geometry: CGRect
    let supportedActions: [AnnotationAccessibilityAction]

    init(
        annotation: Annotation,
        isSelected: Bool,
        layerPosition: Int,
        layerCount: Int,
        canGroup: Bool = false,
        canUngroup: Bool = false
    ) {
        id = annotation.id
        type = annotation.kind.displayName
        visibleText = Self.visibleText(for: annotation.kind)
        self.isSelected = isSelected
        self.layerPosition = layerPosition
        self.layerCount = layerCount
        geometry = annotation.boundingRect.gscIntegralStandardized

        var actions: [AnnotationAccessibilityAction] = [
            .select, .toggleSelection, .delete, .duplicate,
            .bringForward, .sendBackward, .bringToFront, .sendToBack,
        ]
        if annotation.isTextEditable {
            actions.append(.editText)
        }
        if canGroup {
            actions.append(.group)
        }
        if canUngroup {
            actions.append(.ungroup)
        }
        supportedActions = actions
    }

    var label: String {
        visibleText.map { "\(type), \($0)" } ?? type
    }

    var value: String {
        let selected = isSelected ? "Selected" : "Not selected"
        let geometryDescription = Self.geometryDescription(geometry)
        return "\(selected), layer \(layerPosition) of \(layerCount), \(geometryDescription)"
    }

    private static func visibleText(for kind: AnnotationKind) -> String? {
        switch kind {
        case .text(let shape):
            shape.text.isEmpty ? nil : shape.text
        case .callout(let shape):
            shape.text.isEmpty ? "Callout \(shape.number)" : "Callout \(shape.number): \(shape.text)"
        case .arrow(let shape):
            shape.label.isEmpty ? nil : shape.label
        case .redaction:
            nil
        default:
            nil
        }
    }

    static func geometryDescription(_ rect: CGRect) -> String {
        AccessibilityValueFormatter.geometry(rect)
    }
}

nonisolated final class AnnotationAccessibilityElement: NSAccessibilityElement {
    weak var canvas: AnnotationCanvasView?
    let annotationID: UUID

    init(canvas: AnnotationCanvasView, descriptor: AnnotationAccessibilityDescriptor, frame: CGRect) {
        self.canvas = canvas
        self.annotationID = descriptor.id
        super.init()
        setAccessibilityParent(canvas)
        setAccessibilityRole(.button)
        setAccessibilityLabel(descriptor.label)
        setAccessibilityValue(descriptor.value)
        setAccessibilitySelected(descriptor.isSelected)
        setAccessibilityFrame(frame)
        setAccessibilityIdentifier("editor.annotation.\(descriptor.id.uuidString)")
        setAccessibilityHelp("Press to select. Use custom actions to edit, arrange, duplicate, group, or delete this annotation.")
        setAccessibilityCustomActions(descriptor.supportedActions.map { action in
            NSAccessibilityCustomAction(name: action.title) { [weak canvas] in
                MainActor.assumeIsolated {
                    canvas?.performAccessibilityAction(action, for: descriptor.id) ?? false
                }
            }
        })
    }

    override func accessibilityPerformPress() -> Bool {
        let targetCanvas = canvas
        let targetID = annotationID
        return MainActor.assumeIsolated { [weak targetCanvas] in
            targetCanvas?.performAccessibilityAction(.select, for: targetID) ?? false
        }
    }
}
