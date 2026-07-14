import CoreGraphics
import Foundation

nonisolated struct AnnotationDescriptor: Equatable {
    let editorTool: EditorTool
    let displayName: String
    let isTextEditable: Bool
    let supportsFillEditing: Bool
    let redactionMode: RedactionMode?
}

nonisolated enum AnnotationDescriptorRegistry {
    static func descriptor(for kind: AnnotationKind) -> AnnotationDescriptor {
        switch kind {
        case .rectangle:
            return descriptor(editorTool: .rectangle)
        case .ellipse:
            return descriptor(editorTool: .ellipse)
        case .line:
            return descriptor(editorTool: .line, supportsFillEditing: false)
        case .arrow:
            return descriptor(editorTool: .arrow, supportsFillEditing: false)
        case .statusMark:
            return descriptor(editorTool: .statusMark)
        case .freehand:
            return descriptor(editorTool: .freehand, supportsFillEditing: false)
        case .highlighter:
            return descriptor(editorTool: .highlighter, supportsFillEditing: false)
        case .highlight:
            return descriptor(editorTool: .highlight)
        case .text:
            return descriptor(editorTool: .text, isTextEditable: true)
        case .callout:
            return descriptor(editorTool: .callout, isTextEditable: true)
        case .measurement:
            return descriptor(editorTool: .measure)
        case .spotlight:
            return descriptor(editorTool: .spotlight)
        case .imageOverlay(let shape):
            return AnnotationDescriptor(
                editorTool: .select,
                displayName: shape.role == .capturedCursor ? "Cursor" : "Image",
                isTextEditable: false,
                supportsFillEditing: true,
                redactionMode: nil
            )
        case .redaction(let shape):
            return AnnotationDescriptor(
                editorTool: shape.mode.editorTool,
                displayName: shape.mode.label,
                isTextEditable: false,
                supportsFillEditing: true,
                redactionMode: shape.mode
            )
        }
    }

    private static func descriptor(
        editorTool: EditorTool,
        displayName: String? = nil,
        isTextEditable: Bool = false,
        supportsFillEditing: Bool? = nil,
        redactionMode: RedactionMode? = nil
    ) -> AnnotationDescriptor {
        AnnotationDescriptor(
            editorTool: editorTool,
            displayName: displayName ?? editorTool.label,
            isTextEditable: isTextEditable,
            supportsFillEditing: supportsFillEditing ?? editorTool.supportsFillEditing,
            redactionMode: redactionMode
        )
    }
}
