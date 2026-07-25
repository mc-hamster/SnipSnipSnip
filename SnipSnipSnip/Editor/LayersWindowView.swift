import SwiftUI

struct LayersWindowView: View {
    @ObservedObject var documents: DocumentWorkflowModel

    var body: some View {
        Group {
            if let controller = documents.editorController {
                LayersListView(controller: controller)
            } else {
                LayersEmptyStateView(
                    title: "No Screenshot Open",
                    systemImage: "square.3.layers.3d",
                    message: "Open or capture a screenshot to inspect its editable layers."
                )
            }
        }
        .frame(minWidth: 320, minHeight: 420)
    }
}

private struct LayersListView: View {
    @ObservedObject var controller: EditorController
    @State private var selection = Set<UUID>()

    private var layers: [Annotation] {
        controller.snapshot.annotations.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            if layers.isEmpty {
                LayersEmptyStateView(
                    title: "No Layers",
                    systemImage: "rectangle.dashed",
                    message: "Add annotations or image overlays to see them here."
                )
            } else {
                layerCommandBar
                Divider()

                List(selection: $selection) {
                    ForEach(layers) { annotation in
                        LayerRow(annotation: annotation, isSelected: controller.snapshot.selectedAnnotationIDs.contains(annotation.id))
                            .tag(annotation.id)
                    }
                    .onMove(perform: moveLayers)
                }
                .listStyle(.inset)
                .accessibilityLabel("Annotation Layers")
                .accessibilityIdentifier("layers.list")
                .onChange(of: selection) { _, newSelection in
                    syncSelectionToController(newSelection)
                }
                .onChange(of: controller.snapshot.selectedAnnotationIDs) { _, selectedIDs in
                    let selectedSet = Set(selectedIDs)
                    if selection != selectedSet {
                        selection = selectedSet
                    }
                }
                .onAppear {
                    selection = Set(controller.snapshot.selectedAnnotationIDs)
                }
            }
        }
    }

    private var layerCommandBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled", action: controller.sendToFront)
                    .disabled(controller.selectedCount == 0)
                Button("Bring Forward", systemImage: "arrow.up", action: controller.bringForward)
                    .disabled(!controller.canBringForward)
                Button("Send Backward", systemImage: "arrow.down", action: controller.sendBackward)
                    .disabled(!controller.canSendBackward)
                Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled", action: controller.sendToBack)
                    .disabled(controller.selectedCount == 0)
            } label: {
                Label("Arrange", systemImage: "square.3.layers.3d")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)

            Menu {
                Button("Group", systemImage: "square.stack.3d.up", action: controller.groupSelected)
                    .disabled(!controller.canGroupSelection)
                Button("Ungroup", systemImage: "square.stack.3d.down.right", action: controller.ungroupSelected)
                    .disabled(!controller.canUngroupSelection)
            } label: {
                Label("Group", systemImage: "square.stack.3d.up")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)

            Spacer(minLength: 0)

            Button(role: .destructive, action: controller.deleteSelected) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .help("Delete Selected Layers")
            .disabled(controller.selectedCount == 0)
        }
        .controlSize(.small)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func syncSelectionToController(_ selectedIDs: Set<UUID>) {
        let orderedIDs = controller.snapshot.annotations.map(\.id).filter { selectedIDs.contains($0) }
        guard orderedIDs != controller.snapshot.selectedAnnotationIDs else {
            return
        }

        controller.select(annotationIDs: orderedIDs)
    }

    private func moveLayers(from source: IndexSet, to destination: Int) {
        var reordered = layers.map(\.id)
        reordered.move(fromOffsets: source, toOffset: destination)
        controller.reorderLayers(frontToBackAnnotationIDs: reordered)
    }
}

private struct LayersEmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 260)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct LayerRow: View {
    let annotation: Annotation
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: annotation.kind.layerSystemImage)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(annotation.kind.layerTitle)
                    .font(.body)

                if let detail = annotation.kind.layerDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if annotation.groupID != nil {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .help("Grouped")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(annotation.kind.layerTitle)
        .accessibilityValue(
            [
                annotation.kind.layerDetail,
                annotation.groupID == nil ? nil : "Grouped",
                isSelected ? "Selected" : "Not selected",
            ]
            .compactMap(\.self)
            .joined(separator: ", ")
        )
    }
}

private extension AnnotationKind {
    var layerSystemImage: String {
        switch self {
        case .rectangle:
            return "rectangle"
        case .ellipse:
            return "circle"
        case .line:
            return "line.diagonal"
        case .arrow:
            return "arrow.up.right"
        case .statusMark:
            return "checkmark.circle"
        case .freehand:
            return "scribble"
        case .highlighter:
            return "marker"
        case .highlight:
            return "highlighter"
        case .text:
            return "textformat"
        case .callout:
            return "text.bubble"
        case .measurement:
            return "ruler"
        case .spotlight:
            return "scope"
        case .imageOverlay:
            return "photo"
        case .redaction:
            return "eye.slash"
        }
    }

    var layerTitle: String {
        switch self {
        case .rectangle:
            return "Rectangle"
        case .ellipse:
            return "Ellipse"
        case .line:
            return "Line"
        case .arrow:
            return "Arrow"
        case .statusMark:
            return "Status Mark"
        case .freehand:
            return "Freehand"
        case .highlighter:
            return "Highlighter"
        case .highlight:
            return "Highlight"
        case .text:
            return "Text"
        case .callout(let shape):
            return "Callout \(shape.number)"
        case .measurement:
            return "Measurement"
        case .spotlight:
            return "Spotlight"
        case .imageOverlay:
            return "Image Overlay"
        case .redaction(let shape):
            return "\(shape.mode.label) Redaction"
        }
    }

    var layerDetail: String? {
        switch self {
        case .text(let shape):
            return shape.text.trimmingCharacters(in: .whitespacesAndNewlines).sssLayerPreviewText
        case .callout(let shape):
            return shape.text.trimmingCharacters(in: .whitespacesAndNewlines).sssLayerPreviewText
        case .arrow(let shape):
            return shape.label.trimmingCharacters(in: .whitespacesAndNewlines).sssLayerPreviewText
        case .statusMark:
            return nil
        case .freehand(let shape):
            return "\(shape.points.count) points"
        default:
            return nil
        }
    }
}

private extension String {
    var sssLayerPreviewText: String? {
        guard !isEmpty else {
            return nil
        }

        if count <= 42 {
            return self
        }

        let endIndex = index(startIndex, offsetBy: 42)
        return String(self[..<endIndex]) + "..."
    }
}
