import SwiftUI

struct LayersWindowView: View {
    @ObservedObject var documents: DocumentWorkflowModel

    var body: some View {
        Group {
            if let controller = documents.editorController {
                if controller.hasComposition {
                    CompositionLayersView(controller: controller)
                } else {
                    AnnotationLayersView(controller: controller)
                }
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

private enum CompositionLayersScope: String, CaseIterable, Identifiable {
    case items
    case composition
    case item

    var id: String { rawValue }

    var label: String {
        switch self {
        case .items:
            return "Items"
        case .composition:
            return "Result"
        case .item:
            return "Capture"
        }
    }
}

private struct CompositionLayersView: View {
    @ObservedObject var controller: EditorController
    @State private var scope: CompositionLayersScope = .items
    @State private var selectedItemID: UUID?
    @State private var itemSelection = Set<UUID>()

    private var composition: CompositionSnapshot {
        controller.composition ?? CompositionSnapshot(items: [])
    }

    var body: some View {
        VStack(spacing: 0) {
            compositionScopePicker
            Divider()

            switch scope {
            case .items:
                CompositionItemsLayersView(
                    controller: controller,
                    selection: $itemSelection
                )
            case .composition:
                CompositionAnnotationLayersView(
                    controller: controller,
                    layerScope: .composition,
                    title: "Result Annotations",
                    emptyMessage: "Choose Annotate Result to add annotations above every capture.",
                    editTitle: "Annotate Result",
                    isEditing: controller.compositionEditingScope == .composition,
                    onEdit: controller.editCompositionLayerCanvas
                )
            case .item:
                itemAnnotationScope
            }
        }
        .onAppear(perform: synchronizeInitialScope)
        .onChange(of: controller.compositionEditingScope) { _, editingScope in
            switch editingScope {
            case .layout:
                break
            case .composition:
                scope = .composition
            case .item(let itemID):
                selectedItemID = itemID
                scope = .item
            }
        }
        .onChange(of: controller.snapshot.composition?.selectedItemIDs ?? []) { _, selectedIDs in
            let selectedSet = Set(selectedIDs)
            if itemSelection != selectedSet {
                itemSelection = selectedSet
            }
            if let selectedID = selectedIDs.last,
               composition.items.contains(where: { $0.id == selectedID }) {
                selectedItemID = selectedID
            }
        }
        .onChange(of: composition.items.map(\.id)) { _, itemIDs in
            guard let selectedItemID, itemIDs.contains(selectedItemID) else {
                self.selectedItemID = itemIDs.first
                return
            }
        }
    }

    private var compositionScopePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Layer Scope", selection: $scope) {
                ForEach(CompositionLayersScope.allCases) { candidate in
                    Text(candidate.label).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Layer Scope")
            .accessibilityValue(scope.label)
            .accessibilityIdentifier("layers.composition.scope")

            Text(scopeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var itemAnnotationScope: some View {
        if let selectedItemID,
           let index = composition.items.firstIndex(where: { $0.id == selectedItemID }) {
            let item = composition.items[index]
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        selectAdjacentItem(offset: -1)
                    } label: {
                        Label("Previous Item", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(index == composition.items.startIndex)
                    .help("Previous Item")
                    .accessibilityLabel("Previous Item")
                    .accessibilityIdentifier("layers.item.previous")

                    Picker("Item", selection: $selectedItemID) {
                        ForEach(Array(composition.items.enumerated()), id: \.element.id) { itemIndex, candidate in
                            Text("\(itemIndex + 1). \(compositionItemName(candidate, at: itemIndex))")
                                .tag(Optional(candidate.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Item Annotation Scope")
                    .accessibilityValue(compositionItemName(item, at: index))
                    .accessibilityIdentifier("layers.item.picker")
                    .onChange(of: self.selectedItemID) { _, itemID in
                        if let itemID {
                            selectItem(itemID)
                        }
                    }

                    Button {
                        selectAdjacentItem(offset: 1)
                    } label: {
                        Label("Next Item", systemImage: "chevron.right")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(index == composition.items.index(before: composition.items.endIndex))
                    .help("Next Item")
                    .accessibilityLabel("Next Item")
                    .accessibilityIdentifier("layers.item.next")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                CompositionAnnotationLayersView(
                    controller: controller,
                    layerScope: .item(item.id),
                    title: "\(compositionItemName(item, at: index)) Annotations",
                    emptyMessage: "Choose Edit Selected Capture to crop or annotate this source.",
                    editTitle: "Edit Selected Capture",
                    isEditing: controller.compositionEditingScope == .item(item.id),
                    onEdit: { editItem(item.id) }
                )
            }
        } else {
            LayersEmptyStateView(
                title: "No Item Selected",
                systemImage: "rectangle.stack",
                message: "Select an item in the Items scope to inspect its annotations."
            )
        }
    }

    private var scopeDescription: String {
        switch scope {
        case .items:
            return "Arrange capture panels and control which items are included."
        case .composition:
            return "Annotations above the assembled composition."
        case .item:
            return "Crop and annotations belonging to one original source."
        }
    }

    private func synchronizeInitialScope() {
        itemSelection = Set(composition.selectedItemIDs)
        selectedItemID = composition.selectedItemIDs.last ?? composition.items.first?.id
        switch controller.compositionEditingScope {
        case .layout:
            scope = .items
        case .composition:
            scope = .composition
        case .item(let itemID):
            selectedItemID = itemID
            scope = .item
        }
    }

    private func editItem(_ itemID: UUID) {
        selectedItemID = itemID
        itemSelection = [itemID]
        controller.editCompositionLayerItem(itemID)
    }

    private func selectItem(_ itemID: UUID) {
        selectedItemID = itemID
        itemSelection = [itemID]
        controller.selectCompositionItems([itemID])
        if case .item(let currentItemID) = controller.compositionEditingScope,
           currentItemID != itemID {
            controller.editCompositionLayerItem(itemID)
        }
    }

    private func selectAdjacentItem(offset: Int) {
        guard let selectedItemID,
              let currentIndex = composition.items.firstIndex(where: { $0.id == selectedItemID }) else {
            return
        }
        let destination = currentIndex + offset
        guard composition.items.indices.contains(destination) else {
            return
        }
        selectItem(composition.items[destination].id)
    }
}

private struct CompositionItemsLayersView: View {
    @ObservedObject var controller: EditorController
    @Binding var selection: Set<UUID>

    private var items: [CompositionItem] {
        controller.composition?.items ?? []
    }

    private var orderedSelection: [UUID] {
        items.compactMap { selection.contains($0.id) ? $0.id : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            itemCommandBar
            Divider()

            List(selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    CompositionItemLayerRow(
                        controller: controller,
                        item: item,
                        index: index,
                        itemCount: items.count,
                        isSelected: selection.contains(item.id),
                        onSelect: {
                            controller.selectCompositionItems([item.id])
                        },
                        onToggleSelection: {
                            controller.toggleCompositionItemSelection(item.id)
                        },
                        onEdit: {
                            controller.editCompositionLayerItem(item.id)
                        },
                        onMoveEarlier: {
                            controller.arrangeCompositionLayerItems(
                                [item.id],
                                arrangement: .forward
                            )
                        },
                        onMoveLater: {
                            controller.arrangeCompositionLayerItems(
                                [item.id],
                                arrangement: .backward
                            )
                        },
                        onToggleIncluded: {
                            controller.setCompositionItems(
                                [item.id],
                                included: !item.isIncluded
                            )
                        },
                        onDuplicate: {
                            controller.duplicateCompositionLayerItems([item.id])
                        },
                        onRemove: {
                            controller.removeCompositionLayerItems([item.id])
                        }
                    )
                    .tag(item.id)
                }
                .onMove(perform: moveItems)
            }
            .listStyle(.inset)
            .accessibilityLabel("Composition Items")
            .accessibilityIdentifier("layers.composition.items")
            .onChange(of: selection) { _, selectedIDs in
                let ordered = items.compactMap { selectedIDs.contains($0.id) ? $0.id : nil }
                guard ordered != controller.composition?.selectedItemIDs else {
                    return
                }
                controller.selectCompositionItems(ordered)
            }
        }
    }

    private var itemCommandBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Move to Beginning", systemImage: "arrow.up.to.line") {
                    controller.arrangeCompositionLayerItems(orderedSelection, arrangement: .front)
                }
                .disabled(!canArrange(.front))

                Button("Move Earlier", systemImage: "arrow.up") {
                    controller.arrangeCompositionLayerItems(orderedSelection, arrangement: .forward)
                }
                .disabled(!canArrange(.forward))
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button("Move Later", systemImage: "arrow.down") {
                    controller.arrangeCompositionLayerItems(orderedSelection, arrangement: .backward)
                }
                .disabled(!canArrange(.backward))
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button("Move to End", systemImage: "arrow.down.to.line") {
                    controller.arrangeCompositionLayerItems(orderedSelection, arrangement: .back)
                }
                .disabled(!canArrange(.back))
            } label: {
                Label("Arrange", systemImage: "rectangle.stack")
            }
            .accessibilityIdentifier("layers.items.arrange")

            Button {
                if let itemID = orderedSelection.first {
                    controller.editCompositionLayerItem(itemID)
                }
            } label: {
                Label("Edit Selected Capture", systemImage: "pencil")
            }
            .disabled(orderedSelection.count != 1)
            .keyboardShortcut(.return, modifiers: [])
            .help("Edit the selected capture's crop and source annotations")
            .accessibilityIdentifier("layers.items.edit")

            Menu {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    controller.duplicateCompositionLayerItems(orderedSelection)
                }
                .disabled(orderedSelection.isEmpty)
                .keyboardShortcut("d", modifiers: .command)

                Button("Include", systemImage: "eye") {
                    controller.setCompositionItems(orderedSelection, included: true)
                }
                .disabled(orderedSelection.isEmpty)

                Button("Exclude", systemImage: "eye.slash") {
                    controller.setCompositionItems(orderedSelection, included: false)
                }
                .disabled(orderedSelection.isEmpty)
            } label: {
                Label("Item Actions", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("layers.items.actions")

            Spacer(minLength: 0)

            Button(role: .destructive) {
                controller.removeCompositionLayerItems(orderedSelection)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .disabled(!controller.canRemoveCompositionLayerItems(orderedSelection))
            .keyboardShortcut(.delete, modifiers: [])
            .help(
                orderedSelection.count == items.count
                    ? "A composition must keep at least one item"
                    : "Remove selected items"
            )
            .accessibilityIdentifier("layers.items.remove")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item layer commands")
    }

    private func canArrange(_ arrangement: CompositionLayerArrangement) -> Bool {
        controller.canArrangeCompositionLayerItems(
            orderedSelection,
            arrangement: arrangement
        )
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        let movedIDs = source.compactMap { items.indices.contains($0) ? items[$0].id : nil }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = destination - removedBeforeDestination
        controller.moveCompositionLayerItems(movedIDs, to: adjustedDestination)
    }
}

private struct CompositionItemLayerRow: View {
    @ObservedObject var controller: EditorController
    let item: CompositionItem
    let index: Int
    let itemCount: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onToggleIncluded: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void

    private var displayName: String {
        compositionItemName(item, at: index)
    }

    private var availability: CompositionAssetAvailability {
        controller.compositionAssetRepository.availability(for: item.assetID) ?? .missing
    }

    var body: some View {
        rowContent
            .modifier(
                CompositionItemLayerAccessibilityModifier(
                    itemID: item.id,
                    displayName: displayName,
                    accessibilityValue: accessibilityValue,
                    isSelected: isSelected,
                    isIncluded: item.isIncluded,
                    canMoveEarlier: index > 0,
                    canMoveLater: index < itemCount - 1,
                    canRemove: itemCount > 1,
                    onSelect: onSelect,
                    onToggleSelection: onToggleSelection,
                    onEdit: onEdit,
                    onMoveEarlier: onMoveEarlier,
                    onMoveLater: onMoveLater,
                    onToggleIncluded: onToggleIncluded,
                    onDuplicate: onDuplicate,
                    onRemove: onRemove
                )
            )
            .contextMenu {
                itemContextMenu
            }
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .lineLimit(1)

                Text(itemStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 2) {
                Button(action: onMoveEarlier) {
                    Image(systemName: "chevron.up")
                }
                .disabled(index == 0)
                .help("Move Earlier")
                .accessibilityLabel("Move \(displayName) earlier")

                Button(action: onMoveLater) {
                    Image(systemName: "chevron.down")
                }
                .disabled(index == itemCount - 1)
                .help("Move Later")
                .accessibilityLabel("Move \(displayName) later")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var itemContextMenu: some View {
        Button("Edit Selected Capture", systemImage: "pencil", action: onEdit)
        Button("Move Earlier", systemImage: "arrow.up", action: onMoveEarlier)
            .disabled(index == 0)
        Button("Move Later", systemImage: "arrow.down", action: onMoveLater)
            .disabled(index == itemCount - 1)
        Button("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
        Button(
            item.isIncluded ? "Exclude" : "Include",
            systemImage: item.isIncluded ? "eye.slash" : "eye",
            action: onToggleIncluded
        )
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            .disabled(itemCount <= 1)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = controller.compositionThumbnail(for: item.id, maxPixelDimension: 96) {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 34)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: availability == .corrupt ? "exclamationmark.triangle" : "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 34)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }

    private var itemStatus: String {
        [
            item.isIncluded ? "Included" : "Excluded",
            item.semanticRole.layersLabel,
            availability == .available ? nil : availability.layersLabel,
            item.caption?.isEmpty == false ? "Captioned" : nil,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }

    private var accessibilityValue: String {
        let inclusion = item.isIncluded ? "Included" : "Excluded"
        let selected = isSelected ? "Selected" : "Not selected"
        return "\(index + 1) of \(itemCount), \(inclusion), "
            + "\(item.semanticRole.layersLabel), \(availability.layersLabel), \(selected)"
    }
}

private struct CompositionItemLayerAccessibilityModifier: ViewModifier {
    let itemID: UUID
    let displayName: String
    let accessibilityValue: String
    let isSelected: Bool
    let isIncluded: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let canRemove: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onToggleIncluded: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(displayName)
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: Text("Select"), onSelect)
            .accessibilityAction(named: Text("Toggle Selection"), onToggleSelection)
            .accessibilityAction(named: Text("Edit Selected Capture"), onEdit)
            .accessibilityAction(
                named: Text(isIncluded ? "Exclude" : "Include"),
                onToggleIncluded
            )
            .accessibilityAction(named: Text("Duplicate"), onDuplicate)
            .accessibilityIdentifier("layers.item.\(itemID.uuidString)")

        if canMoveEarlier, canMoveLater, canRemove {
            base
                .accessibilityAction(named: Text("Move Earlier"), onMoveEarlier)
                .accessibilityAction(named: Text("Move Later"), onMoveLater)
                .accessibilityAction(named: Text("Remove"), onRemove)
        } else if canMoveEarlier, canMoveLater {
            base
                .accessibilityAction(named: Text("Move Earlier"), onMoveEarlier)
                .accessibilityAction(named: Text("Move Later"), onMoveLater)
        } else if canMoveEarlier, canRemove {
            base
                .accessibilityAction(named: Text("Move Earlier"), onMoveEarlier)
                .accessibilityAction(named: Text("Remove"), onRemove)
        } else if canMoveLater, canRemove {
            base
                .accessibilityAction(named: Text("Move Later"), onMoveLater)
                .accessibilityAction(named: Text("Remove"), onRemove)
        } else if canMoveEarlier {
            base.accessibilityAction(named: Text("Move Earlier"), onMoveEarlier)
        } else if canMoveLater {
            base.accessibilityAction(named: Text("Move Later"), onMoveLater)
        } else if canRemove {
            base.accessibilityAction(named: Text("Remove"), onRemove)
        } else {
            base
        }
    }
}

private struct CompositionAnnotationLayersView: View {
    @ObservedObject var controller: EditorController
    let layerScope: CompositionAnnotationLayerScope
    let title: String
    let emptyMessage: String
    let editTitle: String
    let isEditing: Bool
    let onEdit: () -> Void
    @State private var selection = Set<UUID>()

    private var layers: [Annotation] {
        controller.annotations(in: layerScope).reversed()
    }

    private var orderedSelection: [UUID] {
        controller.annotations(in: layerScope).compactMap {
            selection.contains($0.id) ? $0.id : nil
        }
    }

    private var canGroup: Bool {
        orderedSelection.count > 1
    }

    private var canUngroup: Bool {
        let selectedIDs = Set(orderedSelection)
        return controller.annotations(in: layerScope).contains {
            selectedIDs.contains($0.id) && $0.groupID != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            layerCommandBar
            Divider()

            if layers.isEmpty {
                LayersEmptyStateView(
                    title: "No \(title)",
                    systemImage: "rectangle.dashed",
                    message: emptyMessage
                )
            } else {
                List(selection: $selection) {
                    ForEach(Array(layers.enumerated()), id: \.element.id) { index, annotation in
                        LayerRow(
                            annotation: annotation,
                            isSelected: selection.contains(annotation.id),
                            position: index,
                            layerCount: layers.count,
                            onSelect: {
                                controller.selectLayerAnnotations(
                                    [annotation.id],
                                    in: layerScope
                                )
                            },
                            onToggleSelection: {
                                controller.toggleLayerAnnotationSelection(
                                    annotation.id,
                                    in: layerScope
                                )
                            },
                            onMoveForward: {
                                controller.arrangeLayerAnnotations(
                                    [annotation.id],
                                    in: layerScope,
                                    arrangement: .forward
                                )
                            },
                            onMoveBackward: {
                                controller.arrangeLayerAnnotations(
                                    [annotation.id],
                                    in: layerScope,
                                    arrangement: .backward
                                )
                            },
                            onDelete: {
                                controller.deleteLayerAnnotations(
                                    [annotation.id],
                                    in: layerScope
                                )
                            }
                        )
                        .tag(annotation.id)
                    }
                    .onMove(perform: moveLayers)
                }
                .listStyle(.inset)
                .accessibilityLabel(title)
                .accessibilityIdentifier(layerScope.accessibilityIdentifier)
            }
        }
        .onAppear(perform: synchronizeSelection)
        .onChange(of: selection) { _, newSelection in
            let orderedIDs = controller.annotations(in: layerScope).map(\.id).filter {
                newSelection.contains($0)
            }
            guard orderedIDs != controller.selectedAnnotationIDs(in: layerScope) else {
                return
            }
            controller.selectLayerAnnotations(orderedIDs, in: layerScope)
        }
        .onChange(of: controller.selectedAnnotationIDs(in: layerScope)) { _, selectedIDs in
            let selectedSet = Set(selectedIDs)
            if selection != selectedSet {
                selection = selectedSet
            }
        }
        .onChange(of: layerScope) { _, _ in
            synchronizeSelection()
        }
    }

    private var layerCommandBar: some View {
        HStack(spacing: 8) {
            Button {
                if isEditing {
                    controller.finishCompositionEditing()
                } else {
                    onEdit()
                }
            } label: {
                Label(isEditing ? "Done" : editTitle, systemImage: isEditing ? "checkmark" : "pencil")
            }
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityIdentifier(layerScope.editAccessibilityIdentifier)

            Menu {
                Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") {
                    arrange(.front)
                }
                .disabled(!canArrange(.front))

                Button("Bring Forward", systemImage: "arrow.up") {
                    arrange(.forward)
                }
                .disabled(!canArrange(.forward))
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])

                Button("Send Backward", systemImage: "arrow.down") {
                    arrange(.backward)
                }
                .disabled(!canArrange(.backward))
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

                Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") {
                    arrange(.back)
                }
                .disabled(!canArrange(.back))
            } label: {
                Label("Arrange", systemImage: "square.3.layers.3d")
            }

            Menu {
                Button("Group", systemImage: "square.stack.3d.up") {
                    controller.groupLayerAnnotations(orderedSelection, in: layerScope)
                }
                .disabled(!canGroup)

                Button("Ungroup", systemImage: "square.stack.3d.down.right") {
                    controller.ungroupLayerAnnotations(orderedSelection, in: layerScope)
                }
                .disabled(!canUngroup)
            } label: {
                Label("Group", systemImage: "square.stack.3d.up")
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                controller.deleteLayerAnnotations(orderedSelection, in: layerScope)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(orderedSelection.isEmpty)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Delete Selected Layers")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) commands")
    }

    private func arrange(_ arrangement: CompositionLayerArrangement) {
        controller.arrangeLayerAnnotations(
            orderedSelection,
            in: layerScope,
            arrangement: arrangement
        )
    }

    private func canArrange(_ arrangement: CompositionLayerArrangement) -> Bool {
        controller.canArrangeLayerAnnotations(
            orderedSelection,
            in: layerScope,
            arrangement: arrangement
        )
    }

    private func synchronizeSelection() {
        selection = Set(controller.selectedAnnotationIDs(in: layerScope))
    }

    private func moveLayers(from source: IndexSet, to destination: Int) {
        var reordered = layers.map(\.id)
        reordered.move(fromOffsets: source, toOffset: destination)
        controller.reorderLayerAnnotations(
            frontToBackAnnotationIDs: reordered,
            in: layerScope
        )
    }
}

private struct AnnotationLayersView: View {
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
                        LayerRow(
                            annotation: annotation,
                            isSelected: controller.snapshot.selectedAnnotationIDs.contains(annotation.id),
                            position: layers.firstIndex(where: { $0.id == annotation.id }) ?? 0,
                            layerCount: layers.count,
                            onSelect: {
                                controller.select(annotation.id)
                            },
                            onToggleSelection: {
                                controller.select(
                                    annotation.id,
                                    additive: true,
                                    toggle: true
                                )
                            },
                            onMoveForward: {
                                controller.select(annotation.id)
                                controller.bringForward()
                            },
                            onMoveBackward: {
                                controller.select(annotation.id)
                                controller.sendBackward()
                            },
                            onDelete: {
                                controller.select(annotation.id)
                                controller.deleteSelected()
                            }
                        )
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
    let position: Int
    let layerCount: Int
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onMoveForward: () -> Void
    let onMoveBackward: () -> Void
    let onDelete: () -> Void

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

            VStack(spacing: 2) {
                Button(action: onMoveForward) {
                    Image(systemName: "chevron.up")
                }
                .disabled(position == 0)
                .help("Bring Forward")
                .accessibilityLabel("Bring \(annotation.kind.layerTitle) forward")

                Button(action: onMoveBackward) {
                    Image(systemName: "chevron.down")
                }
                .disabled(position == layerCount - 1)
                .help("Send Backward")
                .accessibilityLabel("Send \(annotation.kind.layerTitle) backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .modifier(
            AnnotationLayerAccessibilityModifier(
                title: annotation.kind.layerTitle,
                value: accessibilityValue,
                isSelected: isSelected,
                canMoveForward: position > 0,
                canMoveBackward: position < layerCount - 1,
                onSelect: onSelect,
                onToggleSelection: onToggleSelection,
                onMoveForward: onMoveForward,
                onMoveBackward: onMoveBackward,
                onDelete: onDelete
            )
        )
        .contextMenu {
            Button("Bring Forward", systemImage: "arrow.up", action: onMoveForward)
                .disabled(position == 0)
            Button("Send Backward", systemImage: "arrow.down", action: onMoveBackward)
                .disabled(position == layerCount - 1)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var accessibilityValue: String {
        [
            annotation.kind.layerDetail,
            annotation.groupID == nil ? nil : "Grouped",
            isSelected ? "Selected" : "Not selected",
        ]
        .compactMap(\.self)
        .joined(separator: ", ")
    }
}

private struct AnnotationLayerAccessibilityModifier: ViewModifier {
    let title: String
    let value: String
    let isSelected: Bool
    let canMoveForward: Bool
    let canMoveBackward: Bool
    let onSelect: () -> Void
    let onToggleSelection: () -> Void
    let onMoveForward: () -> Void
    let onMoveBackward: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: Text("Select"), onSelect)
            .accessibilityAction(named: Text("Toggle Selection"), onToggleSelection)
            .accessibilityAction(named: Text("Delete"), onDelete)

        if canMoveForward, canMoveBackward {
            base
                .accessibilityAction(named: Text("Bring Forward"), onMoveForward)
                .accessibilityAction(named: Text("Send Backward"), onMoveBackward)
        } else if canMoveForward {
            base.accessibilityAction(named: Text("Bring Forward"), onMoveForward)
        } else if canMoveBackward {
            base.accessibilityAction(named: Text("Send Backward"), onMoveBackward)
        } else {
            base
        }
    }
}

private func compositionItemName(_ item: CompositionItem, at index: Int) -> String {
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Item \(index + 1)" : title
}

private extension CompositionItemSemanticRole {
    var layersLabel: String {
        switch self {
        case .standard:
            return "Standard"
        case .before:
            return "Before"
        case .after:
            return "After"
        case .step:
            return "Step"
        }
    }
}

private extension CompositionAssetAvailability {
    var layersLabel: String {
        switch self {
        case .available:
            return "Available"
        case .missing:
            return "Missing source"
        case .corrupt:
            return "Corrupt source"
        }
    }
}

private extension CompositionAnnotationLayerScope {
    var accessibilityIdentifier: String {
        switch self {
        case .composition:
            return "layers.composition.annotations"
        case .item:
            return "layers.item.annotations"
        }
    }

    var editAccessibilityIdentifier: String {
        switch self {
        case .composition:
            return "layers.composition.edit"
        case .item:
            return "layers.item.edit"
        }
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
