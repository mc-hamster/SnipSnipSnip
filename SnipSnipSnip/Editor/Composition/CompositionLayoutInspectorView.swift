import AppKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum CompositionFileDropDestination: Equatable, Sendable {
    case insert(afterItemID: UUID?)
    case replace(itemID: UUID)
}

/// Actions that cross the editor/controller boundary. Composition mutations
/// remain on `EditorController`; capture and editing-scope transitions are
/// supplied by the owning workflow.
struct CompositionInspectorActions {
    var addCapture: CompositionAddActions?
    var importRecovery: CompositionImportRecoveryActions?
    var editComposition: (() -> Void)?
    var editItem: ((UUID) -> Void)?
    var replaceItem: ((UUID) -> Void)?
    var recaptureItem: ((UUID) -> Void)?
    var locateItem: ((UUID) -> Void)?
    var dropFiles: (([URL], CompositionFileDropDestination) -> Void)?
    var openSelectedAsScreenshot: ((UUID) -> Void)?

    static let unavailable = CompositionInspectorActions()
}

struct CompositionImportRecoveryActions {
    let summary: String
    let retryFailed: () -> Void
    let showDetails: () -> Void
    let dismiss: () -> Void
}

struct CompositionLayoutInspectorView: View {
    @ObservedObject var controller: EditorController
    var actions: CompositionInspectorActions = .unavailable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTemplateID: String?
    @State private var templateNameDraft = "Custom Composition"
    @State private var isShowingTemplateManagement = false
    @State private var isShowingAdvancedAppearance = false
    @State private var isShowingAdvancedComparison = false

    private let layoutColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    private var collectionLayoutModes: [CompositionLayoutMode] {
        CompositionLayoutMode.inspectorOrder.filter {
            $0 != .compare && $0 != .steps
        }
    }

    var body: some View {
        if let composition = controller.composition {
            compositionSections(composition)
        } else {
            singleCaptureState
        }
    }

    @ViewBuilder
    private func compositionSections(_ composition: CompositionSnapshot) -> some View {
        InsetGroupBox {
            compositionSummary(composition)
        } label: {
            Label(
                focusedSummaryLabel,
                systemImage: focusedSummarySystemImage
            )
        }
        .id("composition.summary")
        .accessibilityIdentifier("composition.summary")

        if let recovery = actions.importRecovery {
            InsetGroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(recovery.summary, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                        .accessibilityLabel(
                            String(localized: "Import results. \(recovery.summary)")
                        )

                    HStack(spacing: 8) {
                        Button(
                            "Retry Failed",
                            systemImage: "arrow.clockwise",
                            action: recovery.retryFailed
                        )
                        .buttonStyle(.borderedProminent)
                        .help(
                            "Try the failed files again at their original composition destination."
                        )
                        .accessibilityIdentifier("composition.import.retryFailed")

                        Button(
                            "Details…",
                            systemImage: "list.bullet.rectangle",
                            action: recovery.showDetails
                        )
                        .buttonStyle(.bordered)
                        .help("Show each failed file and the reason it could not be added.")
                        .accessibilityIdentifier("composition.import.details")

                        Spacer(minLength: 0)

                        Button(action: recovery.dismiss) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss import results.")
                        .accessibilityLabel("Dismiss Import Results")
                        .accessibilityIdentifier("composition.import.dismiss")
                    }
                }
            } label: {
                Label("Import Results", systemImage: "tray.and.arrow.down")
            }
            .id("composition.import-results")
        }

        if controller.documentPurpose == .collection {
            InsetGroupBox("Arrange") {
                LazyVGrid(columns: layoutColumns, spacing: 8) {
                    ForEach(collectionLayoutModes, id: \.rawValue) { mode in
                        CompositionLayoutTile(
                            mode: mode,
                            isSelected: composition.layout.mode == mode,
                            isEnabled: true
                        ) {
                            compositionDeferPublish {
                                controller.setCompositionLayout(mode)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Arrangement layouts")

                Divider()

                compositionTemplateControls(composition)
            }
            .id("composition.layout")
            .accessibilityIdentifier("composition.layout")
        } else if controller.documentPurpose == .comparison {
            InsetGroupBox("Review Comparison") {
                comparisonControls(composition)
            }
            .id("composition.comparison")
            .accessibilityIdentifier("composition.comparison")
        } else if controller.documentPurpose == .steps {
            InsetGroupBox("Order & Caption") {
                stepsControls(composition)
            }
            .id("composition.steps")
            .accessibilityIdentifier("composition.steps")
        }

        InsetGroupBox(
            controller.documentPurpose == .steps ? "Steps" : "Captures"
        ) {
            compositionItemList(composition)
        }
        .id("composition.items")
        .accessibilityIdentifier("composition.items")

        InsetGroupBox("Canvas") {
            canvasControls(composition)
        }
        .id("composition.canvas")
        .accessibilityIdentifier("composition.canvasSettings")

        if !composition.selectedItemIDs.isEmpty {
            InsetGroupBox(verbatim: selectedItemsHeading(composition)) {
                selectedItemControls(composition)
            }
            .id("composition.selection")
        }
    }

    private func compositionTemplateControls(
        _ composition: CompositionSnapshot
    ) -> some View {
        let templates = controller.compatibleCompositionTemplates.filter {
            $0.layout.mode != .compare && $0.layout.mode != .steps
        }
        let selectedTemplate = selectedTemplateID.flatMap { selectedID in
            templates.first { $0.id == selectedID }
        }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Templates")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: layoutColumns, spacing: 8) {
                ForEach(templates) { template in
                    CompositionTemplateTile(
                        template: template,
                        isSelected: selectedTemplateID == template.id,
                        isEnabled: template.layout.mode != .compare
                            || controller.includedCompositionItemCount >= 2
                    ) {
                        selectedTemplateID = template.id
                        templateNameDraft = template.name
                        compositionDeferPublish {
                            controller.applyCompositionTemplate(id: template.id)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Compatible composition templates")

            Text(
                "Built-in templates adapt to compatible item counts. Your saved templates require exactly \(composition.items.count) \(composition.items.count == 1 ? "item" : "items")."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(
                "Manage Templates",
                isExpanded: $isShowingTemplateManagement
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    CompositionCommitTextField(
                        title: "Template Name",
                        prompt: "Custom Composition",
                        value: templateNameDraft
                    ) { value in
                        templateNameDraft = value
                    }
                    .accessibilityIdentifier("composition.template.name")

                    HStack(spacing: 8) {
                        Button {
                            let name = templateNameDraft
                            compositionDeferPublish {
                                if let id = controller.saveCurrentCompositionAsTemplate(named: name)
                                {
                                    selectedTemplateID = id
                                    templateNameDraft =
                                        controller.compositionTemplates
                                        .first(where: { $0.id == id })?
                                        .name ?? name
                                }
                            }
                        } label: {
                            Label("Save Current", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .help(
                            "Save layout structure and appearance without images, item identities, titles, or captions."
                        )
                        .accessibilityIdentifier("composition.template.save")

                        Button {
                            guard let selectedTemplateID else { return }
                            let name = templateNameDraft
                            compositionDeferPublish {
                                controller.renameCompositionTemplate(
                                    id: selectedTemplateID,
                                    name: name
                                )
                                templateNameDraft =
                                    controller.compositionTemplates
                                    .first(where: { $0.id == selectedTemplateID })?
                                    .name ?? name
                            }
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTemplate == nil || selectedTemplate?.isBuiltIn == true)
                        .help("Rename the selected user template.")
                        .accessibilityIdentifier("composition.template.rename")
                    }

                    HStack(spacing: 8) {
                        Button {
                            guard let selectedTemplateID else { return }
                            compositionDeferPublish {
                                if let id = controller.duplicateCompositionTemplate(
                                    id: selectedTemplateID)
                                {
                                    self.selectedTemplateID = id
                                    templateNameDraft =
                                        controller.compositionTemplates
                                        .first(where: { $0.id == id })?
                                        .name ?? "Composition Copy"
                                }
                            }
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTemplate == nil)
                        .help("Duplicate the selected template as an exact-count user template.")
                        .accessibilityIdentifier("composition.template.duplicate")

                        Button(role: .destructive) {
                            guard let selectedTemplateID else { return }
                            compositionDeferPublish {
                                controller.deleteCompositionTemplate(id: selectedTemplateID)
                                self.selectedTemplateID = nil
                                templateNameDraft = "Custom Composition"
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTemplate == nil || selectedTemplate?.isBuiltIn == true)
                        .help("Delete the selected user template.")
                        .accessibilityIdentifier("composition.template.delete")
                    }

                    HStack(spacing: 8) {
                        Button {
                            importCompositionTemplate()
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .help(
                            "Import a composition template and bind it to the current item count."
                        )
                        .accessibilityIdentifier("composition.template.import")

                        Button {
                            guard let selectedTemplate else { return }
                            exportCompositionTemplate(selectedTemplate)
                        } label: {
                            Label("Export…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTemplate == nil)
                        .help(
                            "Export the selected template without captures or document-specific text."
                        )
                        .accessibilityIdentifier("composition.template.export")
                    }
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: controller.compositionTemplates) { _, updatedTemplates in
            if let selectedTemplateID,
                !updatedTemplates.contains(where: { $0.id == selectedTemplateID })
            {
                self.selectedTemplateID = nil
                templateNameDraft = "Custom Composition"
            }
        }
    }

    private var singleCaptureState: some View {
        InsetGroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("One capture", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))

                Text(
                    "Add another capture or image, then choose whether to compare, explain with steps, or combine. Your annotations and optional Polish are preserved."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Label(
                    "Use Add… in the current workflow bar.",
                    systemImage: "plus.rectangle.on.rectangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } label: {
            Label("Layout", systemImage: "rectangle.3.group")
        }
    }

    private func compositionSummary(_ composition: CompositionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(composition.items.count) \(composition.items.count == 1 ? "item" : "items")"
                    )
                    .font(.subheadline.weight(.semibold))
                    Text(
                        "\(controller.includedCompositionItemCount) included • \(composition.selectedItemIDs.count) selected"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if controller.isPrivateDocument {
                    Label("Private", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Private Composition")
                        .accessibilityIdentifier(
                            "composition.privateStatus"
                        )
                }
            }

            if controller.isPrivateDocument {
                Text("Private Composition remains private even if its private source is removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    compositionEditButton
                    changeGoalMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    compositionEditButton
                    changeGoalMenu
                }
            }
        }
    }

    private var compositionEditButton: some View {
        Button {
            actions.editComposition?()
        } label: {
            Label("Annotate Result", systemImage: "pencil.and.outline")
        }
        .buttonStyle(.bordered)
        .disabled(actions.editComposition == nil)
        .help("Add annotations that appear above every capture in the result.")
        .accessibilityIdentifier("composition.editComposition")
    }

    private var focusedSummaryLabel: String {
        switch controller.documentPurpose {
        case .screenshot:
            return "Captures"
        case .comparison:
            return "Before & After"
        case .steps:
            return "Order & Caption"
        case .collection:
            return "Arrange"
        }
    }

    private var focusedSummarySystemImage: String {
        switch controller.documentPurpose {
        case .screenshot:
            return "photo"
        case .comparison:
            return "rectangle.split.2x1"
        case .steps:
            return "list.number"
        case .collection:
            return "rectangle.3.group"
        }
    }

    private var changeGoalMenu: some View {
        Menu {
            purposeButton(
                .comparison,
                title: "Compare Two Versions",
                layoutMode: .compare
            )
            purposeButton(
                .steps,
                title: "Explain with Steps",
                layoutMode: .steps
            )
            purposeButton(
                .collection,
                title: "Combine Images",
                layoutMode: .auto
            )

            if controller.composition?.items.count == 1 {
                Divider()
                purposeButton(
                    .screenshot,
                    title: "Use as One Screenshot",
                    layoutMode: nil
                )
            } else {
                Divider()
                Button(
                    "Open Selected as New Screenshot",
                    systemImage: "arrow.up.right.square"
                ) {
                    guard let selectedItemID =
                        controller.composition?.selectedItemIDs.last
                    else {
                        return
                    }
                    actions.openSelectedAsScreenshot?(selectedItemID)
                }
                .disabled(
                    controller.composition?.selectedItemIDs.count != 1
                        || actions.openSelectedAsScreenshot == nil
                )
            }
        } label: {
            Label("Change Goal", systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .help("Change how these captures are organized without removing them.")
        .accessibilityIdentifier("composition.changeGoal")
    }

    private func purposeButton(
        _ purpose: ScreenshotDocumentPurpose,
        title: String,
        layoutMode: CompositionLayoutMode?
    ) -> some View {
        Button {
            compositionDeferPublish {
                controller.setDocumentPurpose(
                    purpose,
                    layoutMode: layoutMode
                )
                switch purpose {
                case .screenshot:
                    controller.setWorkflowStage(.editing)
                    controller.setWorkspaceMode(.edit)
                case .comparison:
                    controller.setWorkflowStage(
                        controller.includedCompositionItemCount >= 2
                            ? .reviewingComparison
                            : .awaitingComparisonAfter
                    )
                    controller.presentationInspectorTab = .layout
                    controller.setWorkspaceMode(.presentation)
                case .steps:
                    controller.setWorkflowStage(.collecting)
                    controller.presentationInspectorTab = .layout
                    controller.setWorkspaceMode(.presentation)
                case .collection:
                    controller.setWorkflowStage(.arranging)
                    controller.presentationInspectorTab = .layout
                    controller.setWorkspaceMode(.presentation)
                }
            }
        } label: {
            if controller.documentPurpose == purpose {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(controller.documentPurpose == purpose)
    }

    private func compositionItemList(_ composition: CompositionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(composition.items.enumerated()), id: \.element.id) { index, item in
                CompositionInspectorItemRow(
                    controller: controller,
                    item: item,
                    index: index,
                    roleLabel: roleLabel(for: item, at: index, in: composition),
                    canMoveUp: index > 0,
                    canMoveDown: index < composition.items.count - 1,
                    canRemove: composition.items.count > 1,
                    editAction: actions.editItem,
                    replaceAction: actions.replaceItem,
                    recaptureAction: actions.recaptureItem,
                    locateAction: actions.locateItem,
                    fileDropAction: actions.dropFiles
                )
                .dropDestination(for: String.self) { identifiers, location in
                    guard let identifier = identifiers.first,
                        let itemID = UUID(uuidString: identifier)
                    else {
                        return false
                    }
                    let destination = location.y > 32 ? index + 1 : index
                    compositionDeferPublish {
                        controller.moveCompositionItem(itemID, to: destination)
                    }
                    return true
                } isTargeted: { _ in
                    // The row's native focus/selection boundary remains the
                    // redundant drop target cue; no color-only state is added.
                }

                CompositionAddHereDropTarget(
                    afterItemID: item.id,
                    dropAction: actions.dropFiles
                )
            }

            Text(
                "Drag items to reorder. Drop files between items to Add Here, or over an item to Replace Item. Move buttons and the item menu provide complete keyboard alternatives."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func canvasControls(_ composition: CompositionSnapshot) -> some View {
        let appearance = composition.canvas.appearance

        return VStack(alignment: .leading, spacing: 12) {
            CompositionCommitTextField(
                title: "Title",
                prompt: "Optional composition title",
                value: composition.canvas.title
            ) { value in
                controller.updateCompositionCanvas { $0.title = value }
            }
            .accessibilityIdentifier("composition.canvas.title")

            Menu {
                ForEach(CompositionAppearanceTheme.allCases) { theme in
                    Button(theme.label) {
                        compositionDeferPublish {
                            controller.updateCompositionCanvas {
                                $0.appearance = theme.appearance
                            }
                        }
                    }
                }
            } label: {
                Label("Apply Theme", systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .help(
                "Apply a complete reusable canvas, panel, caption, title, numbering, connector, and comparison appearance."
            )
            .accessibilityIdentifier("composition.canvas.theme")

            Picker(
                "Orientation",
                selection: Binding(
                    get: {
                        composition.layout.orientation
                    },
                    set: { orientation in
                        compositionDeferPublish {
                            controller.updateCompositionLayout { layout in
                                layout.orientation = orientation
                                if let aspectRatio = orientation.standardAspectRatio {
                                    layout.targetAspectRatio = aspectRatio
                                }
                            }
                        }
                    })
            ) {
                ForEach(CompositionCanvasOrientation.allCases, id: \.rawValue) { orientation in
                    Text(orientation.inspectorLabel).tag(orientation)
                }
            }
            .pickerStyle(.menu)
            .help("Choose the target shape used by Auto and structured layouts.")
            .accessibilityIdentifier("composition.canvas.orientation")

            if composition.layout.orientation == .custom {
                CompositionCommitSlider(
                    label: "Width ÷ Height",
                    value: composition.layout.targetAspectRatio,
                    range: 0.25...4,
                    step: 0.05,
                    valueLabel: {
                        String(format: "%.2f", Double($0))
                    }
                ) { aspectRatio in
                    compositionDeferPublish {
                        controller.updateCompositionLayout {
                            $0.targetAspectRatio = aspectRatio
                        }
                    }
                }
                .help("Set the custom target aspect ratio used by Auto and structured layouts.")
                .accessibilityIdentifier("composition.canvas.customAspectRatio")
            }

            if composition.layout.mode == .grid || composition.layout.mode == .auto {
                Picker(
                    "Columns",
                    selection: Binding<Int?>(
                        get: {
                            composition.layout.gridColumns
                        },
                        set: { columns in
                            compositionDeferPublish {
                                controller.updateCompositionLayout { $0.gridColumns = columns }
                            }
                        })
                ) {
                    Text("Auto").tag(Int?.none)
                    ForEach(1...max(composition.items.count, 1), id: \.self) { columns in
                        Text("\(columns)").tag(Int?.some(columns))
                    }
                }
                .pickerStyle(.menu)
                .help("Choose a fixed column count, or let Auto determine it.")
                .accessibilityIdentifier("composition.canvas.columns")
            }

            if composition.layout.mode == .freeform {
                freeformCanvasControls(composition)
            }

            CompositionCommitSlider(
                label: "Padding",
                value: appearance.insets.uniformValue,
                range: 0...160,
                step: 2,
                valueLabel: { "\(Int($0.rounded()))" }
            ) { value in
                controller.updateCompositionCanvas {
                    $0.appearance.insets = CompositionInsets(value)
                }
            }
            .help("Add space around the complete composition.")
            .accessibilityIdentifier("composition.canvas.padding")

            CompositionCommitSlider(
                label: "Gap",
                value: appearance.itemSpacing,
                range: 0...96,
                step: 1,
                valueLabel: { "\(Int($0.rounded()))" }
            ) { value in
                controller.updateCompositionCanvas {
                    $0.appearance.itemSpacing = value
                }
            }
            .help("Set the spacing between composition items.")
            .accessibilityIdentifier("composition.canvas.gap")

            Picker(
                "Section Sizing",
                selection: Binding(
                    get: {
                        composition.layout.sizingMode
                    },
                    set: { sizing in
                        compositionDeferPublish {
                            controller.setCompositionSectionSizing(sizing)
                        }
                    })
            ) {
                ForEach(CompositionSizingMode.allCases, id: \.rawValue) { sizing in
                    Text(sizing.inspectorLabel).tag(sizing)
                }
            }
            .pickerStyle(.segmented)
            .help("Use equal sections or let each item have its own proportional weight.")
            .accessibilityIdentifier("composition.canvas.sectionSizing")

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Canvas Fill")
                    .font(.caption.weight(.semibold))
                CompositionColorPalette(
                    selection: appearance.fill.color,
                    allowsTransparent: true
                ) { color in
                    compositionDeferPublish {
                        controller.updateCompositionCanvas {
                            $0.appearance.fill =
                                color.map(CompositionCanvasFill.color) ?? .transparent
                        }
                    }
                }
                .accessibilityIdentifier("composition.canvas.fill")
            }

            CompositionCommitSlider(
                label: "Border",
                value: appearance.itemBorderWidth,
                range: 0...12,
                step: 0.5,
                valueLabel: { $0 == 0 ? "Off" : String(format: "%.1f", Double($0)) }
            ) { value in
                controller.updateCompositionCanvas {
                    $0.appearance.itemBorderWidth = value
                }
            }
            .help("Draw a border around every included item.")
            .accessibilityIdentifier("composition.canvas.borderWidth")

            if appearance.itemBorderWidth > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Border Color")
                        .font(.caption.weight(.semibold))
                    CompositionColorPalette(selection: appearance.itemBorderColor) { color in
                        guard let color else { return }
                        compositionDeferPublish {
                            controller.updateCompositionCanvas {
                                $0.appearance.itemBorderColor = color
                            }
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.borderColor")
                }
            }

            CompositionCommitSlider(
                label: "Corners",
                value: appearance.itemCornerRadius,
                range: 0...64,
                step: 1,
                valueLabel: { "\(Int($0.rounded()))" }
            ) { value in
                controller.updateCompositionCanvas {
                    $0.appearance.itemCornerRadius = value
                }
            }
            .help("Round every item frame.")
            .accessibilityIdentifier("composition.canvas.cornerRadius")

            advancedAppearanceControls(appearance)

            DisclosureGroup("Captions and Type") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(
                        "Placement",
                        selection: Binding(
                            get: {
                                appearance.captionPlacement
                            },
                            set: { placement in
                                compositionDeferPublish {
                                    controller.updateCompositionCanvas {
                                        $0.appearance.captionPlacement = placement
                                    }
                                }
                            })
                    ) {
                        ForEach(CompositionCaptionPlacement.allCases, id: \.rawValue) { placement in
                            Text(placement.inspectorLabel).tag(placement)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Place captions above, below, over, or outside the item content.")
                    .accessibilityIdentifier("composition.canvas.captionPlacement")

                    CompositionCommitSlider(
                        label: "Caption Size",
                        value: appearance.captionFontSize,
                        range: 9...48,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionCanvas {
                            $0.appearance.captionFontSize = value
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.captionSize")

                    CompositionCommitTextField(
                        title: "Caption Font",
                        prompt: "System",
                        value: appearance.captionFontName ?? ""
                    ) { value in
                        controller.updateCompositionCanvas {
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.appearance.captionFontName = trimmed.isEmpty ? nil : trimmed
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.captionFont")

                    Picker(
                        "Caption Weight",
                        selection: Binding(
                            get: {
                                appearance.captionFontWeight
                            },
                            set: { weight in
                                compositionDeferPublish {
                                    controller.updateCompositionCanvas {
                                        $0.appearance.captionFontWeight = weight
                                    }
                                }
                            })
                    ) {
                        ForEach(CompositionTextWeight.allCases, id: \.rawValue) { weight in
                            Text(weight.inspectorLabel).tag(weight)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("composition.canvas.captionWeight")

                    Picker(
                        "Caption Alignment",
                        selection: Binding(
                            get: {
                                appearance.captionTextAlignment
                            },
                            set: { alignment in
                                compositionDeferPublish {
                                    controller.updateCompositionCanvas {
                                        $0.appearance.captionTextAlignment = alignment
                                    }
                                }
                            })
                    ) {
                        ForEach(CompositionTextAlignment.allCases, id: \.rawValue) { alignment in
                            Text(alignment.inspectorLabel).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("composition.canvas.captionAlignment")

                    Text("Caption Color")
                        .font(.caption.weight(.semibold))
                    CompositionColorPalette(selection: appearance.captionColor) { color in
                        guard let color else { return }
                        compositionDeferPublish {
                            controller.updateCompositionCanvas {
                                $0.appearance.captionColor = color
                            }
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.captionColor")
                }
                .padding(.top, 8)
            }

            DisclosureGroup("Title Type") {
                VStack(alignment: .leading, spacing: 12) {
                    CompositionCommitSlider(
                        label: "Title Size",
                        value: appearance.titleFontSize,
                        range: 12...96,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionCanvas {
                            $0.appearance.titleFontSize = value
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.titleSize")

                    CompositionCommitTextField(
                        title: "Title Font",
                        prompt: "System",
                        value: appearance.titleFontName ?? ""
                    ) { value in
                        controller.updateCompositionCanvas {
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.appearance.titleFontName = trimmed.isEmpty ? nil : trimmed
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.titleFont")

                    Picker(
                        "Title Weight",
                        selection: Binding(
                            get: {
                                appearance.titleFontWeight
                            },
                            set: { weight in
                                compositionDeferPublish {
                                    controller.updateCompositionCanvas {
                                        $0.appearance.titleFontWeight = weight
                                    }
                                }
                            })
                    ) {
                        ForEach(CompositionTextWeight.allCases, id: \.rawValue) { weight in
                            Text(weight.inspectorLabel).tag(weight)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("composition.canvas.titleWeight")

                    Picker(
                        "Title Alignment",
                        selection: Binding(
                            get: {
                                appearance.titleTextAlignment
                            },
                            set: { alignment in
                                compositionDeferPublish {
                                    controller.updateCompositionCanvas {
                                        $0.appearance.titleTextAlignment = alignment
                                    }
                                }
                            })
                    ) {
                        ForEach(CompositionTextAlignment.allCases, id: \.rawValue) { alignment in
                            Text(alignment.inspectorLabel).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("composition.canvas.titleAlignment")

                    Text("Title Color")
                        .font(.caption.weight(.semibold))
                    CompositionColorPalette(selection: appearance.titleColor) { color in
                        guard let color else { return }
                        compositionDeferPublish {
                            controller.updateCompositionCanvas {
                                $0.appearance.titleColor = color
                            }
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.titleColor")
                }
                .padding(.top, 8)
            }
        }
    }

    private func advancedAppearanceControls(
        _ appearance: CompositionCanvasAppearance
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isShowingAdvancedAppearance.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: isShowingAdvancedAppearance
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(width: 10)
                    .accessibilityHidden(true)

                    Text("Advanced Appearance")

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced Appearance")
            .accessibilityValue(
                isShowingAdvancedAppearance ? "Expanded" : "Collapsed"
            )
            .accessibilityIdentifier(
                "composition.canvas.advancedAppearance"
            )

            if isShowingAdvancedAppearance {
                VStack(alignment: .leading, spacing: 12) {
                    compositionAppearanceColorControl(
                        "Panel Fill",
                        selection: appearance.itemFill,
                        allowsTransparent: true,
                        identifier: "composition.canvas.itemFill"
                    ) { canvas, color in
                        canvas.appearance.itemFill = color ?? .clear
                    }

                    CompositionCommitSlider(
                        label: "Shadow",
                        value: appearance.itemShadowBlur,
                        range: 0...64,
                        step: 1,
                        valueLabel: { $0 == 0 ? "Off" : "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionCanvas {
                            $0.appearance.itemShadowBlur = value
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.shadowBlur")

                    if appearance.itemShadowBlur > 0 {
                        compositionAppearanceColorControl(
                            "Shadow Color",
                            selection: appearance.itemShadowColor,
                            identifier: "composition.canvas.shadowColor"
                        ) { canvas, color in
                            guard let color else { return }
                            canvas.appearance.itemShadowColor = color
                        }

                        HStack(spacing: 8) {
                            CompositionCommitNumberField(
                                label: "Shadow X",
                                value: appearance.itemShadowOffset.width,
                                minimum: -128
                            ) { value in
                                controller.updateCompositionCanvas {
                                    $0.appearance.itemShadowOffset.width = min(value, 128)
                                }
                            }
                            CompositionCommitNumberField(
                                label: "Shadow Y",
                                value: appearance.itemShadowOffset.height,
                                minimum: -128
                            ) { value in
                                controller.updateCompositionCanvas {
                                    $0.appearance.itemShadowOffset.height = min(value, 128)
                                }
                            }
                        }
                    }

                    compositionAppearanceColorControl(
                        "Caption Background",
                        selection: appearance.captionBackgroundColor,
                        allowsTransparent: true,
                        identifier: "composition.canvas.captionBackground"
                    ) { canvas, color in
                        canvas.appearance.captionBackgroundColor = color ?? .clear
                    }

                    CompositionCommitSlider(
                        label: "Caption Padding",
                        value: appearance.captionInsets.uniformValue,
                        range: 0...64,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionCanvas {
                            $0.appearance.captionInsets = CompositionInsets(value)
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.captionPadding")

                    compositionAppearanceColorControl(
                        "Title Background",
                        selection: appearance.titleBackgroundColor,
                        allowsTransparent: true,
                        identifier: "composition.canvas.titleBackground"
                    ) { canvas, color in
                        canvas.appearance.titleBackgroundColor = color ?? .clear
                    }

                    CompositionCommitSlider(
                        label: "Title Padding",
                        value: appearance.titleInsets.uniformValue,
                        range: 0...80,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionCanvas {
                            $0.appearance.titleInsets = CompositionInsets(value)
                        }
                    }
                    .accessibilityIdentifier("composition.canvas.titlePadding")

                    if controller.documentPurpose == .steps {
                        Divider()

                        compositionAppearanceColorControl(
                            "Step Badge",
                            selection: appearance.stepBadgeFill,
                            identifier: "composition.canvas.stepBadgeFill"
                        ) { canvas, color in
                            guard let color else { return }
                            canvas.appearance.stepBadgeFill = color
                        }

                        compositionAppearanceColorControl(
                            "Step Number",
                            selection: appearance.stepBadgeForeground,
                            identifier: "composition.canvas.stepBadgeForeground"
                        ) { canvas, color in
                            guard let color else { return }
                            canvas.appearance.stepBadgeForeground = color
                        }

                        CompositionCommitSlider(
                            label: "Badge Size",
                            value: appearance.stepBadgeDiameter,
                            range: 16...96,
                            step: 1,
                            valueLabel: { "\(Int($0.rounded()))" }
                        ) { value in
                            controller.updateCompositionCanvas {
                                $0.appearance.stepBadgeDiameter = value
                            }
                        }
                        .accessibilityIdentifier("composition.canvas.stepBadgeSize")

                        compositionAppearanceColorControl(
                            "Connector",
                            selection: appearance.connectorColor,
                            identifier: "composition.canvas.connectorColor"
                        ) { canvas, color in
                            guard let color else { return }
                            canvas.appearance.connectorColor = color
                        }

                        CompositionCommitSlider(
                            label: "Connector Width",
                            value: appearance.connectorWidth,
                            range: 0.5...12,
                            step: 0.5,
                            valueLabel: { String(format: "%.1f", Double($0)) }
                        ) { value in
                            controller.updateCompositionCanvas {
                                $0.appearance.connectorWidth = value
                            }
                        }
                        .accessibilityIdentifier("composition.canvas.connectorWidth")
                    }

                    if controller.documentPurpose == .comparison {
                        Divider()

                        compositionAppearanceColorControl(
                            "Comparison Divider",
                            selection: appearance.comparisonDividerColor,
                            identifier: "composition.canvas.comparisonDividerColor"
                        ) { canvas, color in
                            guard let color else { return }
                            canvas.appearance.comparisonDividerColor = color
                        }

                        CompositionCommitSlider(
                            label: "Divider Width",
                            value: appearance.comparisonDividerWidth,
                            range: 0.5...12,
                            step: 0.5,
                            valueLabel: { String(format: "%.1f", Double($0)) }
                        ) { value in
                            controller.updateCompositionCanvas {
                                $0.appearance.comparisonDividerWidth = value
                            }
                        }
                        .accessibilityIdentifier("composition.canvas.comparisonDividerWidth")
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func compositionAppearanceColorControl(
        _ label: String,
        selection: RGBAColor,
        allowsTransparent: Bool = false,
        identifier: String,
        mutation: @escaping (inout CompositionCanvasState, RGBAColor?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
            CompositionColorPalette(
                selection: selection.alpha <= 0.001 && allowsTransparent
                    ? nil
                    : selection,
                allowsTransparent: allowsTransparent
            ) { color in
                compositionDeferPublish {
                    controller.updateCompositionCanvas { canvas in
                        mutation(&canvas, color)
                    }
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }

    private func freeformCanvasControls(
        _ composition: CompositionSnapshot
    ) -> some View {
        let size = resolvedFreeformCanvasContentSize(composition)
        let usesAutomaticExpansion =
            composition.layout.freeformCanvasSize == nil

        return DisclosureGroup("Freeform Canvas") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    CompositionCommitNumberField(
                        label: "Width",
                        value: size.width,
                        minimum: 24
                    ) { width in
                        compositionDeferPublish {
                            controller.setFreeformCompositionCanvasSize(
                                CGSize(
                                    width: width,
                                    height: resolvedFreeformCanvasContentSize(
                                        controller.composition ?? composition
                                    ).height
                                )
                            )
                        }
                    }
                    CompositionCommitNumberField(
                        label: "Height",
                        value: size.height,
                        minimum: 24
                    ) { height in
                        compositionDeferPublish {
                            controller.setFreeformCompositionCanvasSize(
                                CGSize(
                                    width: resolvedFreeformCanvasContentSize(
                                        controller.composition ?? composition
                                    ).width,
                                    height: height
                                )
                            )
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Trim to Items") {
                        compositionDeferPublish {
                            controller
                                .trimFreeformCompositionCanvasToIncludedItems()
                        }
                    }
                    .accessibilityIdentifier(
                        "composition.canvas.trimFreeform"
                    )

                    Button("Auto Expand") {
                        compositionDeferPublish {
                            controller.setFreeformCompositionCanvasSize(nil)
                        }
                    }
                    .disabled(usesAutomaticExpansion)
                    .accessibilityIdentifier(
                        "composition.canvas.autoExpandFreeform"
                    )
                }
                .buttonStyle(.bordered)

                Text(
                    usesAutomaticExpansion
                        ? "The canvas expands automatically as items move or resize."
                        : "The canvas uses an explicit size. Items may extend beyond its export bounds."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
        }
    }

    private func resolvedFreeformCanvasContentSize(
        _ composition: CompositionSnapshot
    ) -> CGSize {
        if let explicit = composition.layout.freeformCanvasSize,
            explicit.width.isFinite,
            explicit.height.isFinite
        {
            return explicit
        }
        if let layout = try? controller.currentCompositionRenderLayout() {
            let insets = composition.canvas.appearance.insets
            return CGSize(
                width: max(
                    layout.canvasSize.width - insets.leading - insets.trailing,
                    24
                ),
                height: max(
                    layout.canvasSize.height - insets.top - insets.bottom,
                    24
                )
            )
        }
        return CGSize(width: 640, height: 480)
    }

    private func comparisonControls(_ composition: CompositionSnapshot) -> some View {
        let comparison = composition.comparison
        let included = composition.items.filter(\.isIncluded)

        return VStack(alignment: .leading, spacing: 12) {
            Picker(
                "What should people notice?",
                selection: Binding(
                    get: {
                        ComparisonResultChoice(mode: comparison.mode)
                    },
                    set: { choice in
                        compositionDeferPublish {
                            controller.updateCompositionComparison {
                                $0.mode = choice.defaultMode
                            }
                        }
                    })
            ) {
                ForEach(ComparisonResultChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .help("Choose the clearest way to communicate the difference.")
            .accessibilityIdentifier("composition.compare.result")

            Picker(
                "A",
                selection: Binding(
                    get: {
                        comparison.primaryItemID
                    },
                    set: { itemID in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.primaryItemID = itemID }
                        }
                    })
            ) {
                ForEach(Array(included.enumerated()), id: \.element.id) { index, item in
                    Text(itemDisplayName(item, at: index)).tag(Optional(item.id))
                }
            }
            .pickerStyle(.menu)
            .help("Choose the Before or A item.")
            .accessibilityIdentifier("composition.compare.primary")

            Picker(
                "B",
                selection: Binding(
                    get: {
                        comparison.secondaryItemID
                    },
                    set: { itemID in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.secondaryItemID = itemID }
                        }
                    })
            ) {
                ForEach(Array(included.enumerated()), id: \.element.id) { index, item in
                    Text(itemDisplayName(item, at: index)).tag(Optional(item.id))
                }
            }
            .pickerStyle(.menu)
            .help("Choose the After or B item.")
            .accessibilityIdentifier("composition.compare.secondary")

            HStack(spacing: 8) {
                Button {
                    compositionDeferPublish {
                        controller.swapCompositionComparisonItems()
                    }
                } label: {
                    Label("Swap A/B", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .help("Exchange the A and B comparison roles.")
                .accessibilityIdentifier("composition.compare.swap")

                Button {
                    compositionDeferPublish {
                        controller.matchCompositionComparisonFraming()
                    }
                } label: {
                    Label("Match Framing", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(comparison.primaryItemID == nil || comparison.secondaryItemID == nil)
                .help("Apply A’s Fit or Fill, alignment, zoom, and focal offset to B.")
                .accessibilityIdentifier("composition.compare.matchFraming")
            }

            Picker(
                "Direction",
                selection: Binding(
                    get: {
                        comparison.axis
                    },
                    set: { axis in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.axis = axis }
                        }
                    })
            ) {
                ForEach(CompositionAxis.allCases, id: \.rawValue) { axis in
                    Text(axis.inspectorLabel).tag(axis)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose a horizontal or vertical comparison.")
            .accessibilityIdentifier("composition.compare.axis")

            Toggle(
                "Show Before/After Labels",
                isOn: Binding(
                    get: {
                        comparison.showsLabels
                    },
                    set: { showsLabels in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.showsLabels = showsLabels }
                        }
                    })
            )
            .toggleStyle(.switch)
            .help("Show accessible A and B labels in the composition and exported output.")
            .accessibilityIdentifier("composition.compare.showsLabels")

            if comparison.showsLabels {
                HStack(spacing: 8) {
                    CompositionCommitTextField(
                        title: "A Label",
                        prompt: "Before",
                        value: comparison.primaryLabel
                    ) { value in
                        controller.updateCompositionComparison { $0.primaryLabel = value }
                    }
                    CompositionCommitTextField(
                        title: "B Label",
                        prompt: "After",
                        value: comparison.secondaryLabel
                    ) { value in
                        controller.updateCompositionComparison { $0.secondaryLabel = value }
                    }
                }
            }

            Toggle(
                "Keep Views Linked",
                isOn: Binding(
                    get: {
                        comparison.keepsViewsLinked
                    },
                    set: { isLinked in
                        compositionDeferPublish {
                            controller.setCompositionComparisonFramingLinked(isLinked)
                        }
                    })
            )
            .toggleStyle(.switch)
            .help("Keep A and B framing changes synchronized.")
            .accessibilityIdentifier("composition.compare.linkFraming")

            Button {
                if reduceMotion {
                    isShowingAdvancedComparison.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isShowingAdvancedComparison.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text("More Options")
                    Spacer(minLength: 8)
                    Image(
                        systemName: isShowingAdvancedComparison
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More Options")
            .accessibilityValue(
                isShowingAdvancedComparison
                    ? String(localized: "Expanded")
                    : String(localized: "Collapsed")
            )
            .accessibilityIdentifier("composition.compare.moreOptions")

            if isShowingAdvancedComparison {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(
                        "Method",
                        selection: Binding(
                            get: {
                                comparison.mode
                            },
                            set: { mode in
                                compositionDeferPublish {
                                    controller.updateCompositionComparison {
                                        $0.mode = mode
                                    }
                                }
                            })
                    ) {
                        ForEach(
                            CompositionComparisonMode.allCases,
                            id: \.rawValue
                        ) { mode in
                            Text(mode.inspectorLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Choose a specific comparison method.")
                    .accessibilityIdentifier("composition.compare.mode")

                    comparisonModeControls(comparison)
                    comparisonRegistrationControls(comparison)
                }
                .padding(.top, 8)
            }

            compositionComparisonStatus(composition)

            Button {
                compositionDeferPublish {
                    controller.resetCompositionComparison()
                }
            } label: {
                Label("Reset Comparison", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .help("Restore comparison controls while preserving the current A and B choices.")
            .accessibilityIdentifier("composition.compare.reset")
        }
    }

    @ViewBuilder
    private func comparisonModeControls(_ comparison: CompositionComparisonSettings) -> some View {
        switch comparison.mode {
        case .sideBySide:
            EmptyView()
        case .overlay:
            CompositionCommitSlider(
                label: "B Opacity",
                value: comparison.overlayOpacity,
                range: 0...1,
                step: 0.01,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.overlayOpacity = value }
            }
            .accessibilityIdentifier("composition.compare.opacity")
        case .wipe:
            CompositionCommitSlider(
                label: "Divider",
                value: comparison.wipePosition,
                range: 0...1,
                step: 0.01,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.wipePosition = value }
            }
            .accessibilityIdentifier("composition.compare.wipePosition")
        case .blink:
            HStack(spacing: 8) {
                Picker(
                    "Preview Frame",
                    selection: Binding(
                        get: {
                            controller.effectiveCompositionComparisonPreviewPhase
                        },
                        set: { phase in
                            compositionDeferPublish {
                                controller.setCompositionComparisonPreviewPhase(phase)
                            }
                        })
                ) {
                    Text(comparison.primaryLabel.isEmpty ? "Before" : comparison.primaryLabel)
                        .tag(CompositionComparisonPhase.primary)
                    Text(comparison.secondaryLabel.isEmpty ? "After" : comparison.secondaryLabel)
                        .tag(CompositionComparisonPhase.secondary)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("composition.compare.previewPhase")

                if !reduceMotion {
                    Button {
                        compositionDeferPublish {
                            if controller.isCompositionBlinkPreviewPlaying {
                                controller.isCompositionBlinkPreviewPlaying = false
                            } else {
                                controller.resetCompositionComparisonPreviewToPoster()
                                controller.isCompositionBlinkPreviewPlaying = true
                            }
                        }
                    } label: {
                        Image(
                            systemName: controller.isCompositionBlinkPreviewPlaying
                                ? "pause.fill"
                                : "play.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        controller.isCompositionBlinkPreviewPlaying
                            ? "Pause comparison preview"
                            : "Play comparison preview"
                    )
                    .help(
                        controller.isCompositionBlinkPreviewPlaying
                            ? "Pause the Before and After preview."
                            : "Play the Before and After preview."
                    )
                    .accessibilityIdentifier("composition.compare.previewPlayback")
                }
            }

            CompositionCommitSlider(
                label: "Interval",
                value: CGFloat(comparison.blinkInterval),
                range: 0.15...3,
                step: 0.05,
                valueLabel: { String(format: "%.2fs", Double($0)) }
            ) { value in
                controller.updateCompositionComparison { $0.blinkInterval = TimeInterval(value) }
            }
            .accessibilityIdentifier("composition.compare.blinkInterval")

            CompositionCommitSlider(
                label: "Crossfade",
                value: CGFloat(comparison.blinkCrossfadeDuration),
                range: 0...1,
                step: 0.05,
                valueLabel: { String(format: "%.2fs", Double($0)) }
            ) { value in
                controller.updateCompositionComparison {
                    $0.blinkCrossfadeDuration = TimeInterval(value)
                }
            }
            .accessibilityIdentifier("composition.compare.blinkCrossfade")

            Toggle(
                "Loop",
                isOn: Binding(
                    get: {
                        comparison.blinkLoops
                    },
                    set: { loops in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.blinkLoops = loops }
                        }
                    })
            )
            .toggleStyle(.switch)
            .help("Repeat the Before and After animation.")
            .accessibilityIdentifier("composition.compare.blinkLoops")

            Picker(
                "Static Poster",
                selection: Binding(
                    get: {
                        comparison.posterFrame
                    },
                    set: { poster in
                        compositionDeferPublish {
                            controller.updateCompositionComparison { $0.posterFrame = poster }
                        }
                    })
            ) {
                ForEach(CompositionPosterFrame.allCases, id: \.rawValue) { frame in
                    Text(frame.inspectorLabel).tag(frame)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose the image used by static PNG, JPEG, and PDF output.")
            .accessibilityIdentifier("composition.compare.posterFrame")

            if reduceMotion {
                Label(
                    "Reduced Motion shows manual Before and After controls instead of automatic blinking.",
                    systemImage: "figure.walk.motion"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .difference:
            CompositionCommitSlider(
                label: "Sensitivity",
                value: comparison.changeThreshold,
                range: 0...1,
                step: 0.01,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.changeThreshold = value }
            }
            .help("Suppress small pixel differences or reveal subtler changes.")
            .accessibilityIdentifier("composition.compare.sensitivity")

            CompositionCommitSlider(
                label: "Intensity",
                value: comparison.differenceIntensity,
                range: 0...2,
                step: 0.05,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.differenceIntensity = value }
            }
            .accessibilityIdentifier("composition.compare.differenceIntensity")

            differenceCueControls(comparison)
        case .changeHighlight:
            CompositionCommitSlider(
                label: "Sensitivity",
                value: comparison.changeThreshold,
                range: 0...1,
                step: 0.01,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.changeThreshold = value }
            }
            .accessibilityIdentifier("composition.compare.sensitivity")

            differenceCueControls(comparison)
        }
    }

    private func comparisonRegistrationControls(
        _ comparison: CompositionComparisonSettings
    ) -> some View {
        DisclosureGroup("Alignment and Registration") {
            VStack(alignment: .leading, spacing: 12) {
                Picker(
                    "Registration",
                    selection: Binding(
                        get: {
                            comparison.registrationMode
                        },
                        set: { mode in
                            compositionDeferPublish {
                                controller.updateCompositionComparison {
                                    $0.registrationMode = mode
                                }
                            }
                        })
                ) {
                    ForEach(CompositionRegistrationMode.allCases, id: \.rawValue) { mode in
                        Text(mode.inspectorLabel).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Align local image content automatically, manually, or not at all.")
                .accessibilityIdentifier("composition.compare.registration")

                if comparison.registrationMode == .automatic {
                    CompositionCommitSlider(
                        label: "Sensitivity",
                        value: comparison.registrationSensitivity,
                        range: 0...1,
                        step: 0.01,
                        valueLabel: { "\(Int(($0 * 100).rounded()))%" }
                    ) { value in
                        controller.updateCompositionComparison {
                            $0.registrationSensitivity = value
                        }
                    }
                    .accessibilityIdentifier("composition.compare.registrationSensitivity")

                    if controller.compositionRegistrationOutcome == .automaticFailed {
                        Label(
                            "Automatic alignment could not find a reliable match.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        Button("Adjust Manually") {
                            compositionDeferPublish {
                                controller.updateCompositionComparison {
                                    $0.registrationMode = .manual
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("composition.compare.manualFallback")
                    }
                } else if comparison.registrationMode == .manual {
                    CompositionCommitSlider(
                        label: "Offset X",
                        value: comparison.manualRegistrationOffset.width,
                        range: -500...500,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionComparison {
                            $0.manualRegistrationOffset.width = value
                        }
                    }
                    .accessibilityIdentifier("composition.compare.registrationX")

                    CompositionCommitSlider(
                        label: "Offset Y",
                        value: comparison.manualRegistrationOffset.height,
                        range: -500...500,
                        step: 1,
                        valueLabel: { "\(Int($0.rounded()))" }
                    ) { value in
                        controller.updateCompositionComparison {
                            $0.manualRegistrationOffset.height = value
                        }
                    }
                    .accessibilityIdentifier("composition.compare.registrationY")
                }
            }
            .padding(.top, 8)
        }
    }

    private func differenceCueControls(
        _ comparison: CompositionComparisonSettings
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CompositionCommitSlider(
                label: "Unchanged",
                value: comparison.unchangedContentOpacity,
                range: 0...1,
                step: 0.01,
                valueLabel: { "\(Int(($0 * 100).rounded()))%" }
            ) { value in
                controller.updateCompositionComparison { $0.unchangedContentOpacity = value }
            }
            .help("Dim unchanged content so differences remain prominent.")
            .accessibilityIdentifier("composition.compare.unchangedOpacity")

            Picker(
                "Difference Cues",
                selection: Binding(
                    get: {
                        comparison.differenceCueStyle
                    },
                    set: { cueStyle in
                        compositionDeferPublish {
                            controller.updateCompositionComparison {
                                $0.differenceCueStyle = cueStyle
                            }
                        }
                    })
            ) {
                ForEach(CompositionDifferenceCueStyle.allCases, id: \.rawValue) { style in
                    Text(style.inspectorLabel).tag(style)
                }
            }
            .pickerStyle(.menu)
            .help("Use luminance, outlines, or patterns so differences never rely on color alone.")
            .accessibilityIdentifier("composition.compare.differenceCues")
        }
    }

    private func compositionComparisonStatus(_ composition: CompositionSnapshot) -> some View {
        let matches = controller.comparisonFramingMatches
        let registration: String
        let registrationNeedsAttention: Bool
        switch composition.comparison.registrationMode {
        case .disabled:
            registration = "Registration off"
            registrationNeedsAttention = false
        case .manual:
            registration = "Manual alignment"
            registrationNeedsAttention = false
        case .automatic:
            switch controller.compositionRegistrationOutcome {
            case .automaticSucceeded(_, let confidence):
                registration = "Auto aligned • \(Int((confidence * 100).rounded()))% confidence"
                registrationNeedsAttention = false
            case .automaticFailed:
                registration = "Auto alignment needs manual adjustment"
                registrationNeedsAttention = true
            case .disabled, .manual, nil:
                registration = "Auto alignment pending"
                registrationNeedsAttention = false
            }
        }
        let needsAttention = !matches || registrationNeedsAttention
        return Label(
            matches
                ? "A and B framing matches • \(registration)"
                : "A and B framing differs • \(registration)",
            systemImage: needsAttention ? "exclamationmark.triangle" : "checkmark.circle"
        )
        .font(.caption)
        .foregroundStyle(needsAttention ? Color.orange : Color.secondary)
        .accessibilityValue(needsAttention ? "Needs alignment" : "Aligned")
    }

    private func stepsControls(_ composition: CompositionSnapshot) -> some View {
        let steps = composition.steps

        return VStack(alignment: .leading, spacing: 12) {
            Picker(
                "Flow",
                selection: Binding(
                    get: {
                        steps.flow
                    },
                    set: { flow in
                        compositionDeferPublish {
                            controller.updateCompositionSteps {
                                $0.flow = flow
                                switch flow {
                                case .row:
                                    $0.axis = .horizontal
                                case .column, .grid:
                                    $0.axis = .vertical
                                }
                            }
                        }
                    })
            ) {
                ForEach(CompositionStepFlow.allCases, id: \.rawValue) { flow in
                    Text(flow.inspectorLabel).tag(flow)
                }
            }
            .pickerStyle(.segmented)
            .help("Arrange steps as a row, column, or grid.")
            .accessibilityIdentifier("composition.steps.flow")

            if steps.flow == .grid {
                Stepper(
                    "Grid Columns: \(steps.gridColumns)",
                    value: Binding(
                        get: {
                            steps.gridColumns
                        },
                        set: { value in
                            compositionDeferPublish {
                                controller.updateCompositionSteps {
                                    $0.gridColumns = min(
                                        max(value, 1),
                                        max(composition.items.count, 1)
                                    )
                                }
                            }
                        }),
                    in: 1...max(composition.items.count, 1)
                )
                .help("Choose the number of columns in the step grid.")
                .accessibilityIdentifier("composition.steps.gridColumns")
            }

            Toggle(
                "Paginate PDF",
                isOn: Binding(
                    get: {
                        steps.itemsPerPage != nil
                    },
                    set: { isEnabled in
                        compositionDeferPublish {
                            controller.updateCompositionSteps {
                                $0.itemsPerPage =
                                    isEnabled
                                    ? ($0.itemsPerPage ?? 1)
                                    : nil
                            }
                        }
                    })
            )
            .toggleStyle(.switch)
            .help("Export Steps as multiple PDF pages.")
            .accessibilityIdentifier("composition.steps.pagination")

            if let itemsPerPage = steps.itemsPerPage {
                Stepper(
                    "Steps per Page: \(itemsPerPage)",
                    value: Binding(
                        get: {
                            itemsPerPage
                        },
                        set: { value in
                            compositionDeferPublish {
                                controller.updateCompositionSteps {
                                    $0.itemsPerPage = max(value, 1)
                                }
                            }
                        }),
                    in: 1...max(composition.items.filter(\.isIncluded).count, 1)
                )
                .help("Choose exactly how many included steps appear on each PDF page.")
                .accessibilityIdentifier("composition.steps.itemsPerPage")
            }

            Picker(
                "Numbering",
                selection: Binding(
                    get: {
                        steps.numberingStyle
                    },
                    set: { style in
                        compositionDeferPublish {
                            controller.updateCompositionSteps { $0.numberingStyle = style }
                        }
                    })
            ) {
                ForEach(CompositionStepNumberingStyle.allCases, id: \.rawValue) { style in
                    Text(style.inspectorLabel).tag(style)
                }
            }
            .pickerStyle(.menu)
            .help("Choose the marker format for the ordered sequence.")
            .accessibilityIdentifier("composition.steps.numbering")

            Stepper(
                "Start at \(steps.startIndex)",
                value: Binding(
                    get: {
                        steps.startIndex
                    },
                    set: { value in
                        compositionDeferPublish {
                            controller.updateCompositionSteps { $0.startIndex = max(1, value) }
                        }
                    }),
                in: 1...1_000_000
            )
            .help("Set the first visible step number.")
            .accessibilityIdentifier("composition.steps.start")

            Toggle(
                "Show Captions",
                isOn: Binding(
                    get: {
                        steps.showsCaptions
                    },
                    set: { value in
                        compositionDeferPublish {
                            controller.updateCompositionSteps { $0.showsCaptions = value }
                        }
                    })
            )
            .toggleStyle(.switch)
            .help("Reserve caption space below each step.")
            .accessibilityIdentifier("composition.steps.captions")

            Picker(
                "Connectors",
                selection: Binding(
                    get: {
                        steps.connectorStyle
                    },
                    set: { style in
                        compositionDeferPublish {
                            controller.updateCompositionSteps { $0.connectorStyle = style }
                        }
                    })
            ) {
                ForEach(CompositionStepConnectorStyle.allCases, id: \.rawValue) { style in
                    Text(style.inspectorLabel).tag(style)
                }
            }
            .pickerStyle(.menu)
            .help("Draw no connector, a line, or an arrow between steps.")
            .accessibilityIdentifier("composition.steps.connectors")

            Text(
                "Steps arranges captures you already have. Guide records a workflow automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func selectedItemControls(_ composition: CompositionSnapshot) -> some View {
        let selected = controller.selectedCompositionItems
        let representative = selected.last

        return VStack(alignment: .leading, spacing: 12) {
            if let item = representative, selected.count == 1 {
                CompositionCommitTextField(
                    title: "Item Name",
                    prompt: "Source name",
                    value: item.title
                ) { value in
                    controller.updateCompositionItem(itemID: item.id) { $0.title = value }
                }
                .accessibilityIdentifier("composition.selected.title")

                CompositionCommitTextField(
                    title: "Caption",
                    prompt: "Optional caption",
                    value: item.caption ?? ""
                ) { value in
                    controller.updateCompositionItem(itemID: item.id) {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        $0.caption = trimmed.isEmpty ? nil : value
                    }
                }
                .accessibilityIdentifier("composition.selected.caption")

                Picker(
                    "Role",
                    selection: Binding(
                        get: {
                            item.semanticRole
                        },
                        set: { role in
                            compositionDeferPublish {
                                controller.setCompositionItemRole(item.id, role: role)
                            }
                        })
                ) {
                    ForEach(CompositionItemSemanticRole.allCases, id: \.rawValue) { role in
                        Text(role.inspectorLabel).tag(role)
                    }
                }
                .pickerStyle(.menu)
                .help(
                    "Give the item a reusable semantic role for comparison, steps, and accessible output."
                )
                .accessibilityIdentifier("composition.selected.role")
            }

            if let representative {
                Picker(
                    "Framing",
                    selection: Binding(
                        get: {
                            representative.framing.contentMode
                        },
                        set: { mode in
                            compositionDeferPublish {
                                controller.updateSelectedCompositionItems(
                                    label: "Change Item Framing"
                                ) {
                                    $0.framing.contentMode = mode
                                }
                            }
                        })
                ) {
                    ForEach(CompositionContentMode.allCases, id: \.rawValue) { mode in
                        Text(mode.inspectorLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Fit all pixels, fill the frame, or display at actual pixel size.")
                .accessibilityIdentifier("composition.selected.contentMode")

                HStack(alignment: .center, spacing: 12) {
                    Text("Align")
                    Spacer(minLength: 8)
                    CompositionAlignmentPicker(
                        horizontal: representative.framing.horizontalAlignment,
                        vertical: representative.framing.verticalAlignment
                    ) { horizontal, vertical in
                        compositionDeferPublish {
                            controller.updateSelectedCompositionItems(
                                label: "Align Composition Item"
                            ) {
                                $0.framing.horizontalAlignment = horizontal
                                $0.framing.verticalAlignment = vertical
                            }
                        }
                    }
                }

                CompositionCommitSlider(
                    label: "Zoom",
                    value: representative.framing.scale,
                    range: 0.25...4,
                    step: 0.01,
                    valueLabel: { "\(Int(($0 * 100).rounded()))%" }
                ) { value in
                    controller.updateSelectedCompositionItems(label: "Zoom Composition Item") {
                        $0.framing.scale = value
                    }
                }
                .help("Zoom content inside the selected item frame.")
                .accessibilityIdentifier("composition.selected.zoom")

                CompositionCommitSlider(
                    label: "Focal X",
                    value: representative.framing.offset.width,
                    range: -500...500,
                    step: 1,
                    valueLabel: { "\(Int($0.rounded()))" }
                ) { value in
                    controller.updateSelectedCompositionItems(label: "Frame Composition Item") {
                        $0.framing.offset.width = value
                    }
                }
                .help("Move the focal point left or right inside the frame.")
                .accessibilityIdentifier("composition.selected.focalX")

                CompositionCommitSlider(
                    label: "Focal Y",
                    value: representative.framing.offset.height,
                    range: -500...500,
                    step: 1,
                    valueLabel: { "\(Int($0.rounded()))" }
                ) { value in
                    controller.updateSelectedCompositionItems(label: "Frame Composition Item") {
                        $0.framing.offset.height = value
                    }
                }
                .help("Move the focal point up or down inside the frame.")
                .accessibilityIdentifier("composition.selected.focalY")

                CompositionCommitSlider(
                    label: "Opacity",
                    value: representative.opacity,
                    range: 0...1,
                    step: 0.01,
                    valueLabel: { "\(Int(($0 * 100).rounded()))%" }
                ) { value in
                    controller.updateSelectedCompositionItems(label: "Change Item Opacity") {
                        $0.opacity = value
                    }
                }
                .help("Adjust the opacity of every selected item.")
                .accessibilityIdentifier("composition.selected.opacity")

                if composition.layout.sizingMode == .weighted
                    && (composition.layout.mode == .row
                        || composition.layout.mode == .column
                        || composition.layout.mode == .grid
                        || composition.layout.mode == .auto
                        || composition.layout.mode == .steps
                        || (composition.layout.mode == .compare
                            && composition.comparison.mode == .sideBySide))
                {
                    CompositionCommitSlider(
                        label: "Section Weight",
                        value: representative.weight,
                        range: 0.1...8,
                        step: 0.1,
                        valueLabel: { String(format: "%.1f", Double($0)) }
                    ) { value in
                        controller.updateSelectedCompositionItems(
                            label: "Resize Composition Sections"
                        ) {
                            $0.weight = value
                        }
                    }
                    .help("Give selected sections more or less space relative to the other items.")
                    .accessibilityIdentifier("composition.selected.weight")
                }

                Toggle(
                    "Link Framing",
                    isOn: Binding(
                        get: {
                            representative.framing.linkGroupID != nil
                        },
                        set: { linked in
                            compositionDeferPublish {
                                controller.setSelectedCompositionFramingLinked(linked)
                            }
                        })
                )
                .toggleStyle(.switch)
                .disabled(selected.count < 2 && representative.framing.linkGroupID == nil)
                .help("Keep framing synchronized among the selected linked items.")
                .accessibilityIdentifier("composition.selected.linkFraming")

                Button {
                    compositionDeferPublish {
                        controller.resetSelectedCompositionFraming()
                    }
                } label: {
                    Label("Reset Framing", systemImage: "scope")
                }
                .buttonStyle(.bordered)
                .help("Restore Fit, centered alignment, 100% zoom, and zero focal offset.")
                .accessibilityIdentifier("composition.selected.resetFraming")
            }

            Toggle(
                "Included",
                isOn: Binding(
                    get: {
                        !selected.isEmpty && selected.allSatisfy(\.isIncluded)
                    },
                    set: { included in
                        compositionDeferPublish {
                            controller.setSelectedCompositionItemsIncluded(included)
                        }
                    })
            )
            .toggleStyle(.switch)
            .help(
                "Keep selected items in the document while including or excluding them from this layout."
            )
            .accessibilityIdentifier("composition.selected.included")

            if composition.layout.mode == .freeform, let representative {
                freeformControls(
                    representative,
                    selectedCount: selected.count
                )
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    selectedItemPrimaryActions(selected, composition: composition)
                }
                VStack(alignment: .leading, spacing: 8) {
                    selectedItemPrimaryActions(selected, composition: composition)
                }
            }

            HStack(spacing: 8) {
                Button {
                    compositionDeferPublish {
                        controller.duplicateSelectedCompositionItem()
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                .disabled(selected.count != 1)
                .help("Duplicate the selected item while sharing its immutable source pixels.")
                .keyboardShortcut("d", modifiers: .command)
                .accessibilityIdentifier("composition.selected.duplicate")

                Button(role: .destructive) {
                    compositionDeferPublish {
                        controller.removeSelectedCompositionItems()
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(composition.items.count <= 1 || selected.isEmpty)
                .help(
                    composition.items.count <= 1
                        ? "A composition must retain at least one item."
                        : "Remove the selected items. The final item is always protected."
                )
                .accessibilityIdentifier("composition.selected.remove")
            }
        }
    }

    @ViewBuilder
    private func selectedItemPrimaryActions(
        _ selected: [CompositionItem],
        composition: CompositionSnapshot
    ) -> some View {
        let selectedItemID = selected.count == 1 ? selected.first?.id : nil

        Button {
            guard let selectedItemID else { return }
            actions.editItem?(selectedItemID)
        } label: {
            Label("Edit Selected Capture", systemImage: "pencil")
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedItemID == nil || actions.editItem == nil)
        .help("Edit the selected source’s crop, annotations, redactions, and UI Map.")
        .accessibilityIdentifier("composition.selected.edit")

        Button {
            guard let selectedItemID else { return }
            actions.replaceItem?(selectedItemID)
        } label: {
            Label("Replace", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.bordered)
        .disabled(selectedItemID == nil || actions.replaceItem == nil)
        .help(
            "Capture a replacement while retaining this item’s identity, caption, and anchored annotations."
        )
        .accessibilityIdentifier("composition.selected.replace")

        Button {
            guard let selectedItemID else { return }
            actions.recaptureItem?(selectedItemID)
        } label: {
            Label("Recapture", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(selectedItemID == nil || actions.recaptureItem == nil)
        .help("Repeat the latest compatible capture into this item while retaining its identity.")
        .accessibilityIdentifier("composition.selected.recapture")
    }

    private func freeformControls(
        _ item: CompositionItem,
        selectedCount: Int
    ) -> some View {
        let fallbackSize =
            controller.compositionAssetRepository
            .storedAsset(for: item.assetID)?
            .descriptor
            .pixelSize ?? CGSize(width: 320, height: 200)
        let frame = item.freeformFrame ?? CGRect(origin: .zero, size: fallbackSize)

        return DisclosureGroup("Freeform Position and Size") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    freeformStepper("X", value: frame.minX, itemID: item.id) { rectangle, value in
                        rectangle.origin.x = value
                    }
                    freeformStepper("Y", value: frame.minY, itemID: item.id) { rectangle, value in
                        rectangle.origin.y = value
                    }
                }

                HStack(spacing: 8) {
                    freeformStepper("Width", value: frame.width, itemID: item.id, minimum: 1) {
                        rectangle, value in
                        rectangle.size.width = value
                    }
                    freeformStepper("Height", value: frame.height, itemID: item.id, minimum: 1) {
                        rectangle, value in
                        rectangle.size.height = value
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        compositionDeferPublish {
                            controller.moveSelectedCompositionItemsBy(dx: -1, dy: 0)
                        }
                    } label: {
                        Image(systemName: "arrow.left")
                    }
                    .accessibilityLabel("Nudge selected items left")
                    .help("Nudge left")

                    Button {
                        compositionDeferPublish {
                            controller.moveSelectedCompositionItemsBy(dx: 0, dy: -1)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .accessibilityLabel("Nudge selected items up")
                    .help("Nudge up")

                    Button {
                        compositionDeferPublish {
                            controller.moveSelectedCompositionItemsBy(dx: 0, dy: 1)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                    }
                    .accessibilityLabel("Nudge selected items down")
                    .help("Nudge down")

                    Button {
                        compositionDeferPublish {
                            controller.moveSelectedCompositionItemsBy(dx: 1, dy: 0)
                        }
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .accessibilityLabel("Nudge selected items right")
                    .help("Nudge right")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("composition.selected.freeformNudge")

                HStack(spacing: 8) {
                    Menu {
                        Button("Left Edges") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.leading)
                            }
                        }
                        Button("Horizontal Centers") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.horizontalCenter)
                            }
                        }
                        Button("Right Edges") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.trailing)
                            }
                        }
                        Divider()
                        Button("Top Edges") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.top)
                            }
                        }
                        Button("Vertical Centers") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.verticalCenter)
                            }
                        }
                        Button("Bottom Edges") {
                            compositionDeferPublish {
                                controller.alignSelectedFreeformCompositionItems(.bottom)
                            }
                        }
                    } label: {
                        Label("Align", systemImage: "align.horizontal.left")
                    }
                    .disabled(selectedCount < 2)
                    .accessibilityIdentifier("composition.selected.freeformAlign")

                    Menu {
                        Button("Horizontally") {
                            compositionDeferPublish {
                                controller.distributeSelectedFreeformCompositionItems(.horizontal)
                            }
                        }
                        Button("Vertically") {
                            compositionDeferPublish {
                                controller.distributeSelectedFreeformCompositionItems(.vertical)
                            }
                        }
                    } label: {
                        Label("Distribute", systemImage: "rectangle.3.group")
                    }
                    .disabled(selectedCount < 3)
                    .accessibilityIdentifier("composition.selected.freeformDistribute")

                    Menu {
                        Button("Width") {
                            compositionDeferPublish {
                                controller.matchSelectedFreeformCompositionItemSizes(.width)
                            }
                        }
                        Button("Height") {
                            compositionDeferPublish {
                                controller.matchSelectedFreeformCompositionItemSizes(.height)
                            }
                        }
                        Button("Width and Height") {
                            compositionDeferPublish {
                                controller.matchSelectedFreeformCompositionItemSizes(.both)
                            }
                        }
                    } label: {
                        Label("Match Size", systemImage: "rectangle.on.rectangle")
                    }
                    .disabled(selectedCount < 2)
                    .accessibilityIdentifier("composition.selected.freeformMatchSize")
                }
                .menuStyle(.borderlessButton)
                .help(
                    "Align, distribute, or match the selected freeform items. The first selected item supplies the match size."
                )

                Stepper(
                    "Layer: \(item.zIndex)",
                    value: Binding(
                        get: {
                            item.zIndex
                        },
                        set: { zIndex in
                            compositionDeferPublish {
                                controller.updateCompositionItem(itemID: item.id) {
                                    $0.zIndex = zIndex
                                }
                            }
                        }),
                    in: -10_000...10_000
                )
                .help("Move the selected freeform item forward or backward in the layer order.")
                .accessibilityIdentifier("composition.selected.zIndex")
            }
            .padding(.top, 8)
        }
    }

    private func freeformStepper(
        _ label: String,
        value: CGFloat,
        itemID: UUID,
        minimum: CGFloat = -100_000,
        mutation: @escaping (inout CGRect, CGFloat) -> Void
    ) -> some View {
        HStack(spacing: 5) {
            CompositionCommitNumberField(
                label: label,
                value: value,
                minimum: minimum
            ) { newValue in
                compositionDeferPublish {
                    controller.updateCompositionItem(itemID: itemID) { item in
                        var frame =
                            item.freeformFrame
                            ?? CGRect(x: 0, y: 0, width: 320, height: 200)
                        mutation(&frame, newValue)
                        item.freeformFrame = frame
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(value.rounded()))")
    }

    private func importCompositionTemplate() {
        let panel = NSOpenPanel()
        panel.title = "Import Composition Template"
        panel.message =
            "Choose a composition template. Imported templates use the current item count."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.compositionTemplateFileType, .json]

        guard panel.runModal() == .OK,
            let url = panel.url
        else {
            return
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let importedIDs = controller.importCompositionTemplates(from: data)
            if let importedID = importedIDs.first {
                selectedTemplateID = importedID
                templateNameDraft =
                    controller.compositionTemplates
                    .first(where: { $0.id == importedID })?
                    .name ?? "Imported Composition"
            }
        } catch {
            controller.errorMessage =
                "The composition template could not be imported: \(error.localizedDescription)"
        }
    }

    private func exportCompositionTemplate(_ template: CompositionTemplate) {
        let panel = NSSavePanel()
        panel.title = "Export Composition Template"
        panel.message =
            "Templates contain layout and appearance only—never captures, titles, or captions."
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(safeTemplateFilename(template.name)).ssscompositiontemplate"
        panel.allowedContentTypes = [Self.compositionTemplateFileType]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK,
            let url = panel.url
        else {
            return
        }

        do {
            let data = try controller.compositionTemplateExportData(id: template.id)
            try data.write(to: url, options: .atomic)
            controller.showNotice("Exported \(template.name).")
        } catch {
            controller.errorMessage =
                "The composition template could not be exported: \(error.localizedDescription)"
        }
    }

    private func safeTemplateFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " -_")
        )
        let cleaned = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let collapsed = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Composition Template" : collapsed
    }

    private static let compositionTemplateFileType =
        UTType(
            tag: "ssscompositiontemplate",
            tagClass: .filenameExtension,
            conformingTo: .json
        ) ?? .json

    private func selectedItemsHeading(_ composition: CompositionSnapshot) -> String {
        let count = composition.selectedItemIDs.count
        return count == 1 ? "Selected Item" : "\(count) Selected Items"
    }

    private func roleLabel(
        for item: CompositionItem,
        at index: Int,
        in composition: CompositionSnapshot
    ) -> String {
        if composition.layout.mode == .compare {
            if item.id == composition.comparison.primaryItemID {
                return "A"
            }
            if item.id == composition.comparison.secondaryItemID {
                return "B"
            }
            return "Unused"
        }
        if composition.layout.mode == .steps {
            guard item.isIncluded else {
                return "Excluded"
            }
            let includedOrdinal = composition.items[..<index]
                .lazy
                .filter(\.isIncluded)
                .count
            return composition.steps.label(for: includedOrdinal) ?? "Step"
        }
        if item.semanticRole != .standard {
            return item.semanticRole.inspectorShortLabel
        }
        return "\(index + 1)"
    }

    private func itemDisplayName(_ item: CompositionItem, at index: Int) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Item \(index + 1)" : trimmed
    }
}

private struct CompositionInspectorItemRow: View {
    @ObservedObject var controller: EditorController
    let item: CompositionItem
    let index: Int
    let roleLabel: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let editAction: ((UUID) -> Void)?
    let replaceAction: ((UUID) -> Void)?
    let recaptureAction: ((UUID) -> Void)?
    let locateAction: ((UUID) -> Void)?
    let fileDropAction: (([URL], CompositionFileDropDestination) -> Void)?
    @State private var isFileDropTargeted = false

    private var isSelected: Bool {
        controller.composition?.selectedItemIDs.contains(item.id) == true
    }

    private var storedAsset: CompositionStoredAsset? {
        controller.compositionAssetRepository.storedAsset(for: item.assetID)
    }

    private var displayName: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        let source =
            storedAsset?.descriptor.sourceName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return source.isEmpty ? "Item \(index + 1)" : source
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                let modifiers = NSEvent.modifierFlags
                compositionDeferPublish {
                    if modifiers.contains(.shift) || modifiers.contains(.command) {
                        controller.toggleCompositionItemSelection(item.id)
                    } else {
                        controller.selectCompositionItems([item.id])
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    CompositionItemThumbnailView(
                        repository: controller.compositionAssetRepository,
                        assetID: item.assetID,
                        availability: storedAsset?.availability
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)

                            Text(roleLabel)
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }

                        itemStatus

                        if let caption = item.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 2)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName), \(roleLabel)")
            .accessibilityValue(itemAccessibilityValue)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help("Select \(displayName). Shift-click or Command-click to extend the selection.")
            .accessibilityIdentifier("composition.item.\(item.id.uuidString)")

            VStack(spacing: 3) {
                Button {
                    compositionDeferPublish {
                        controller.moveCompositionItem(item.id, to: index - 1)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .accessibilityLabel("Move \(displayName) up")
                .help("Move item up")
                .accessibilityIdentifier("composition.item.\(item.id.uuidString).moveUp")

                Button {
                    compositionDeferPublish {
                        controller.moveCompositionItem(item.id, to: index + 1)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .accessibilityLabel("Move \(displayName) down")
                .help("Move item down")
                .accessibilityIdentifier("composition.item.\(item.id.uuidString).moveDown")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Menu {
                Button("Edit Selected Capture", systemImage: "pencil") {
                    editAction?(item.id)
                }
                .disabled(editAction == nil)

                if storedAsset?.availability != .available {
                    Button("Locate Source…", systemImage: "folder.badge.questionmark") {
                        locateAction?(item.id)
                    }
                    .disabled(locateAction == nil)
                }

                Button("Replace Item", systemImage: "arrow.triangle.2.circlepath") {
                    replaceAction?(item.id)
                }
                .disabled(replaceAction == nil)

                Button("Recapture Item", systemImage: "arrow.clockwise") {
                    recaptureAction?(item.id)
                }
                .disabled(recaptureAction == nil)

                Button("Duplicate", systemImage: "plus.square.on.square") {
                    compositionDeferPublish {
                        controller.selectCompositionItems([item.id])
                        controller.duplicateSelectedCompositionItem()
                    }
                }

                Button(
                    item.isIncluded ? "Exclude" : "Include",
                    systemImage: item.isIncluded ? "eye.slash" : "eye"
                ) {
                    compositionDeferPublish {
                        controller.setCompositionItems([item.id], included: !item.isIncluded)
                    }
                }

                Divider()

                Button("Remove", systemImage: "trash", role: .destructive) {
                    compositionDeferPublish {
                        controller.selectCompositionItems([item.id])
                        controller.removeSelectedCompositionItems()
                    }
                }
                .disabled(!canRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(displayName)")
            .help("Edit, replace, duplicate, include, exclude, or remove \(displayName).")
            .accessibilityIdentifier("composition.item.\(item.id.uuidString).actions")
        }
        .draggable(item.id.uuidString) {
            Label("Move \(displayName)", systemImage: "line.3.horizontal")
                .padding(8)
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Label("Replace Item", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, let fileDropAction else {
                return false
            }
            fileDropAction(urls, .replace(itemID: item.id))
            return true
        } isTargeted: { isTargeted in
            isFileDropTargeted = isTargeted
        }
    }

    @ViewBuilder
    private var itemStatus: some View {
        switch storedAsset?.availability {
        case .missing:
            Label("Missing source", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption2)
        case .corrupt:
            Label("Unreadable source", systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .font(.caption2)
        case .available:
            if !item.isIncluded {
                Label("Excluded", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            } else if storedAsset?.descriptor.isPrivate == true {
                Label("Private source", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            } else {
                Label("Included", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
        case nil:
            Label("Missing source", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption2)
        }
    }

    private var itemAccessibilityValue: String {
        let status: String
        switch storedAsset?.availability {
        case .missing:
            status = "Missing source"
        case .corrupt:
            status = "Unreadable source"
        case .available:
            status = item.isIncluded ? "Included" : "Excluded"
        case nil:
            status = "Missing source"
        }
        return "\(isSelected ? "Selected" : "Not selected"), \(status)"
    }
}

private struct CompositionAddHereDropTarget: View {
    let afterItemID: UUID?
    let dropAction: (([URL], CompositionFileDropDestination) -> Void)?
    @State private var isTargeted = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor))
                .frame(height: isTargeted ? 28 : 2)

            if isTargeted {
                Label("Add Here", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .selectedControlTextColor))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isTargeted ? 32 : 8)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, let dropAction else {
                return false
            }
            dropAction(urls, .insert(afterItemID: afterItemID))
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement()
        .accessibilityLabel(
            afterItemID == nil ? "Add files before the first item" : "Add files after this item"
        )
        .accessibilityHint("Drop image files or editable SnipSnipSnip documents here.")
        .accessibilityIdentifier(
            "composition.drop.addHere.\(afterItemID?.uuidString ?? "first")"
        )
    }
}

private struct CompositionItemThumbnailView: View {
    let repository: CompositionAssetRepository
    let assetID: UUID
    let availability: CompositionAssetAvailability?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: unavailableSystemImage)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .task(id: "\(assetID.uuidString):\(availability?.rawValue ?? "missing")") {
            guard availability == .available else {
                image = nil
                return
            }
            let thumbnail = await Task.detached(priority: .utility) {
                try? repository.thumbnail(for: assetID, maxPixelDimension: 128)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
        .accessibilityHidden(true)
    }

    private var unavailableSystemImage: String {
        switch availability {
        case .corrupt:
            return "xmark.octagon"
        case .missing, nil:
            return "photo.badge.exclamationmark"
        case .available:
            return "photo"
        }
    }
}

private struct CompositionLayoutTile: View {
    let mode: CompositionLayoutMode
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CompositionLayoutGlyph(mode: mode)
                    .frame(height: 36)

                HStack(spacing: 4) {
                    Text(mode.inspectorLabel)
                        .font(.caption.weight(.semibold))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(mode.inspectorLabel) layout")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(mode.inspectorHelp)
        .accessibilityIdentifier("composition.layout.\(mode.rawValue)")
    }
}

private struct CompositionTemplateTile: View {
    let template: CompositionTemplate
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                CompositionLayoutGlyph(mode: template.layout.mode)
                    .frame(height: 30)

                HStack(spacing: 4) {
                    Text(template.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)

                Text(template.itemCount.inspectorLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(template.name) composition template")
        .accessibilityValue(
            "\(template.itemCount.inspectorLabel), \(isSelected ? "selected" : "not selected")"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(
            !isEnabled
                ? "Include at least two items before applying this comparison template."
                : template.isBuiltIn
                    ? "Apply the built-in \(template.name) template."
                    : "Apply the saved \(template.name) template."
        )
        .accessibilityIdentifier("composition.template.\(template.id)")
    }
}

private struct CompositionLayoutGlyph: View {
    let mode: CompositionLayoutMode

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                switch mode {
                case .auto:
                    itemRect(
                        CGRect(x: 2, y: 2, width: size.width * 0.58, height: size.height * 0.44))
                    itemRect(
                        CGRect(
                            x: size.width * 0.64, y: 2, width: size.width * 0.32 - 2,
                            height: size.height * 0.44))
                    itemRect(
                        CGRect(
                            x: 2, y: size.height * 0.54, width: size.width - 4,
                            height: size.height * 0.42))
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .compare:
                    itemRect(CGRect(x: 2, y: 3, width: size.width / 2 - 4, height: size.height - 6))
                    itemRect(
                        CGRect(
                            x: size.width / 2 + 2, y: 3, width: size.width / 2 - 4,
                            height: size.height - 6))
                case .steps:
                    ForEach(0..<3, id: \.self) { index in
                        let y = CGFloat(index) * (size.height / 3) + 2
                        Circle()
                            .strokeBorder(Color.primary, lineWidth: 1)
                            .frame(width: 8, height: 8)
                            .position(x: 7, y: y + size.height / 7)
                        itemRect(
                            CGRect(x: 15, y: y, width: size.width - 17, height: size.height / 3 - 4)
                        )
                    }
                case .row:
                    itemRect(CGRect(x: 2, y: 3, width: size.width / 2 - 4, height: size.height - 6))
                    itemRect(
                        CGRect(
                            x: size.width / 2 + 2, y: 3, width: size.width / 2 - 4,
                            height: size.height - 6))
                case .column:
                    itemRect(CGRect(x: 2, y: 2, width: size.width - 4, height: size.height / 2 - 4))
                    itemRect(
                        CGRect(
                            x: 2, y: size.height / 2 + 2, width: size.width - 4,
                            height: size.height / 2 - 4)
                    )
                case .grid:
                    ForEach(0..<4, id: \.self) { index in
                        let column = CGFloat(index % 2)
                        let row = CGFloat(index / 2)
                        itemRect(
                            CGRect(
                                x: 2 + column * size.width / 2,
                                y: 2 + row * size.height / 2,
                                width: size.width / 2 - 4,
                                height: size.height / 2 - 4
                            ))
                    }
                case .freeform:
                    itemRect(
                        CGRect(x: 3, y: 4, width: size.width * 0.62, height: size.height * 0.64))
                    itemRect(
                        CGRect(
                            x: size.width * 0.42, y: size.height * 0.34, width: size.width * 0.54,
                            height: size.height * 0.58))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func itemRect(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.secondary.opacity(0.13))
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.52), lineWidth: 1)
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
    }
}

private struct CompositionAlignmentPicker: View {
    let horizontal: CompositionHorizontalAlignment
    let vertical: CompositionVerticalAlignment
    let action: (CompositionHorizontalAlignment, CompositionVerticalAlignment) -> Void

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 0), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(CompositionAlignmentOption.allCases) { option in
                let isSelected = option.horizontal == horizontal && option.vertical == vertical
                Button {
                    action(option.horizontal, option.vertical)
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(isSelected ? Color.accentColor.opacity(0.62) : Color.clear)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay {
                    Rectangle()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel("\(option.label) alignment")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .help("\(option.label) alignment")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Item alignment")
    }
}

private struct CompositionCommitSlider: View {
    let label: String
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let valueLabel: (CGFloat) -> String
    let onCommit: (CGFloat) -> Void
    @State private var draft: CGFloat
    @State private var isEditing = false

    init(
        label: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        valueLabel: @escaping (CGFloat) -> String,
        onCommit: @escaping (CGFloat) -> Void
    ) {
        self.label = label
        self.value = value
        self.range = range
        self.step = step
        self.valueLabel = valueLabel
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Slider(
                value: Binding(
                    get: {
                        Double(draft)
                    },
                    set: { newValue in
                        draft = CGFloat(newValue)
                    }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step),
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing, draft != value {
                        onCommit(draft)
                    }
                }
            )
            Text(valueLabel(draft))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .onChange(of: value) { _, newValue in
            if !isEditing {
                draft = newValue
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct CompositionCommitTextField: View {
    let title: String
    let prompt: String
    let value: String
    let onCommit: (String) -> Void
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        title: String,
        prompt: String,
        value: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.prompt = prompt
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { wasFocused, focused in
                if wasFocused && !focused {
                    commit()
                }
            }
            .onChange(of: value) { _, newValue in
                if !isFocused {
                    draft = newValue
                }
            }
            .help("\(title): \(prompt)")
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
    }
}

private struct CompositionCommitNumberField: View {
    let label: String
    let value: CGFloat
    let minimum: CGFloat
    let onCommit: (CGFloat) -> Void
    @State private var draft: Double
    @FocusState private var isFocused: Bool

    init(
        label: String,
        value: CGFloat,
        minimum: CGFloat,
        onCommit: @escaping (CGFloat) -> Void
    ) {
        self.label = label
        self.value = value
        self.minimum = minimum
        self.onCommit = onCommit
        _draft = State(initialValue: Double(value))
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                label,
                value: $draft,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 54)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { wasFocused, focused in
                if wasFocused && !focused {
                    commit()
                }
            }
        }
        .onChange(of: value) { _, newValue in
            if !isFocused {
                draft = Double(newValue)
            }
        }
    }

    private func commit() {
        let clamped = max(minimum, CGFloat(draft))
        draft = Double(clamped)
        guard clamped != value else { return }
        onCommit(clamped)
    }
}

private struct CompositionColorPalette: View {
    let selection: RGBAColor?
    var allowsTransparent = false
    let action: (RGBAColor?) -> Void

    private var colors: [PaletteColorOption] {
        RGBAColor.paletteOptions.filter { option in
            option.color.alpha > 0
        }
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 24, maximum: 24), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            if allowsTransparent {
                Button {
                    action(nil)
                } label: {
                    ZStack {
                        CheckerboardPattern()
                            .clipShape(Circle())
                        if selection == nil {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                selection == nil
                                    ? Color.accentColor : Color(nsColor: .separatorColor),
                                lineWidth: selection == nil ? 2.5 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Transparent")
                .accessibilityValue(selection == nil ? "Selected" : "Not selected")
                .help("Transparent")
            }

            ForEach(colors) { option in
                let isSelected = selection == option.color
                Button {
                    action(option.color)
                } label: {
                    Circle()
                        .fill(Color(nsColor: option.color.nsColor))
                        .frame(width: 22, height: 22)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(
                                        option.color.luminance > 0.58 ? Color.black : Color.white)
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isSelected
                                        ? Color.accentColor : Color(nsColor: .separatorColor),
                                    lineWidth: isSelected ? 2.5 : 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .help(option.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

nonisolated enum CompositionAppearanceTheme: String, CaseIterable, Identifiable, Sendable {
    case clean
    case cards
    case dark
    case documentation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clean: "Clean"
        case .cards: "Cards"
        case .dark: "Dark"
        case .documentation: "Documentation"
        }
    }

    var appearance: CompositionCanvasAppearance {
        switch self {
        case .clean:
            return CompositionCanvasAppearance()
        case .cards:
            return CompositionCanvasAppearance(
                fill: .color(RGBAColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)),
                insets: CompositionInsets(32),
                itemSpacing: 24,
                itemFill: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                itemBorderColor: RGBAColor(red: 0.76, green: 0.78, blue: 0.82, alpha: 1),
                itemBorderWidth: 1,
                itemCornerRadius: 14,
                itemShadowColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.22),
                itemShadowBlur: 18,
                itemShadowOffset: CGSize(width: 0, height: 8),
                captionColor: RGBAColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1),
                captionBackgroundColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.94),
                captionFontWeight: .medium,
                captionTextAlignment: .center,
                titleFontWeight: .bold,
                titleTextAlignment: .center
            )
        case .dark:
            return CompositionCanvasAppearance(
                fill: .color(RGBAColor(red: 0.075, green: 0.08, blue: 0.095, alpha: 1)),
                insets: CompositionInsets(28),
                itemSpacing: 18,
                itemFill: RGBAColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1),
                itemBorderColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                itemBorderWidth: 1,
                itemCornerRadius: 10,
                itemShadowColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.6),
                itemShadowBlur: 14,
                itemShadowOffset: CGSize(width: 0, height: 6),
                captionColor: RGBAColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1),
                captionBackgroundColor: RGBAColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 0.96),
                captionFontWeight: .medium,
                titleColor: RGBAColor(red: 0.98, green: 0.98, blue: 1, alpha: 1),
                titleFontWeight: .bold,
                stepBadgeFill: RGBAColor(red: 0.30, green: 0.62, blue: 1, alpha: 1),
                stepBadgeForeground: RGBAColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1),
                connectorColor: RGBAColor(red: 0.55, green: 0.73, blue: 1, alpha: 1),
                comparisonDividerColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
        case .documentation:
            return CompositionCanvasAppearance(
                fill: .color(RGBAColor(red: 0.98, green: 0.975, blue: 0.95, alpha: 1)),
                insets: CompositionInsets(36),
                itemSpacing: 28,
                itemFill: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                itemBorderColor: RGBAColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 0.7),
                itemBorderWidth: 1,
                itemCornerRadius: 4,
                itemShadowColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.12),
                itemShadowBlur: 6,
                itemShadowOffset: CGSize(width: 0, height: 3),
                captionColor: RGBAColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1),
                captionBackgroundColor: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                captionFontSize: 15,
                captionFontWeight: .regular,
                titleColor: RGBAColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1),
                titleFontSize: 32,
                titleFontWeight: .bold,
                stepBadgeFill: RGBAColor(red: 0.11, green: 0.36, blue: 0.72, alpha: 1),
                stepBadgeForeground: RGBAColor(red: 1, green: 1, blue: 1, alpha: 1),
                connectorColor: RGBAColor(red: 0.11, green: 0.36, blue: 0.72, alpha: 1),
                comparisonDividerColor: RGBAColor(red: 0.11, green: 0.36, blue: 0.72, alpha: 1)
            )
        }
    }
}

private enum CompositionAlignmentOption: String, CaseIterable, Identifiable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { rawValue }

    var horizontal: CompositionHorizontalAlignment {
        switch self {
        case .topLeading, .leading, .bottomLeading:
            return .leading
        case .top, .center, .bottom:
            return .center
        case .topTrailing, .trailing, .bottomTrailing:
            return .trailing
        }
    }

    var vertical: CompositionVerticalAlignment {
        switch self {
        case .topLeading, .top, .topTrailing:
            return .top
        case .leading, .center, .trailing:
            return .center
        case .bottomLeading, .bottom, .bottomTrailing:
            return .bottom
        }
    }

    var label: String {
        switch self {
        case .topLeading:
            return "Top left"
        case .top:
            return "Top"
        case .topTrailing:
            return "Top right"
        case .leading:
            return "Left"
        case .center:
            return "Center"
        case .trailing:
            return "Right"
        case .bottomLeading:
            return "Bottom left"
        case .bottom:
            return "Bottom"
        case .bottomTrailing:
            return "Bottom right"
        }
    }
}

extension CompositionLayoutMode {
    fileprivate static let inspectorOrder: [CompositionLayoutMode] = [
        .auto, .compare, .steps, .row, .column, .grid, .freeform,
    ]

    fileprivate var inspectorLabel: String {
        switch self {
        case .auto:
            return "Auto"
        case .compare:
            return "Compare"
        case .steps:
            return "Steps"
        case .row:
            return "Row"
        case .column:
            return "Column"
        case .grid:
            return "Grid"
        case .freeform:
            return "Freeform"
        }
    }

    fileprivate var inspectorHelp: String {
        switch self {
        case .auto:
            return
                "Choose the deterministic row, column, or grid that keeps every item most legible."
        case .compare:
            return "Compare explicit A and B items; additional captures remain stored."
        case .steps:
            return "Arrange existing captures as a numbered manual sequence."
        case .row:
            return "Arrange items from left to right."
        case .column:
            return "Arrange items from top to bottom."
        case .grid:
            return "Arrange items in rows and columns."
        case .freeform:
            return "Move, resize, overlap, and layer items on an expanding canvas."
        }
    }
}

extension CompositionComparisonMode {
    fileprivate var inspectorLabel: String {
        switch self {
        case .sideBySide:
            return "Side by Side"
        case .overlay:
            return "Overlay"
        case .wipe:
            return "Wipe"
        case .blink:
            return "Blink"
        case .difference:
            return "Difference"
        case .changeHighlight:
            return "Change Highlight"
        }
    }
}

extension CompositionAxis {
    fileprivate var inspectorLabel: String {
        switch self {
        case .horizontal:
            return "Horizontal"
        case .vertical:
            return "Vertical"
        }
    }
}

extension CompositionStepNumberingStyle {
    fileprivate var inspectorLabel: String {
        switch self {
        case .none:
            return "None"
        case .decimal:
            return "1, 2, 3"
        case .uppercaseLetters:
            return "A, B, C"
        case .lowercaseLetters:
            return "a, b, c"
        case .uppercaseRoman:
            return "I, II, III"
        case .lowercaseRoman:
            return "i, ii, iii"
        }
    }
}

extension CompositionStepConnectorStyle {
    fileprivate var inspectorLabel: String {
        switch self {
        case .none:
            return "None"
        case .line:
            return "Line"
        case .arrow:
            return "Arrow"
        }
    }
}

extension CompositionContentMode {
    fileprivate var inspectorLabel: String {
        switch self {
        case .contain:
            return "Fit"
        case .fill:
            return "Fill"
        case .actualSize:
            return "100%"
        }
    }
}

extension CompositionTemplateItemCount {
    fileprivate var inspectorLabel: String {
        switch self {
        case .exact(let count):
            return "\(count) \(count == 1 ? "item" : "items")"
        case .flexible(let minimum, let maximum):
            if let maximum {
                return "\(minimum)–\(maximum) items"
            }
            return minimum == 1 ? "Flexible count" : "\(minimum)+ items"
        }
    }
}

extension CompositionSizingMode {
    fileprivate var inspectorLabel: String {
        switch self {
        case .equal:
            return "Equal"
        case .weighted:
            return "Weighted"
        }
    }
}

extension CompositionCanvasOrientation {
    fileprivate var inspectorLabel: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .landscape:
            return "Landscape"
        case .portrait:
            return "Portrait"
        case .square:
            return "Square"
        case .custom:
            return "Custom"
        }
    }

    fileprivate var standardAspectRatio: CGFloat? {
        switch self {
        case .automatic, .custom:
            return nil
        case .landscape:
            return 4 / 3
        case .portrait:
            return 3 / 4
        case .square:
            return 1
        }
    }
}

extension CompositionCaptionPlacement {
    fileprivate var inspectorLabel: String {
        switch self {
        case .hidden:
            return "Hidden"
        case .below:
            return "Below"
        case .above:
            return "Above"
        case .overlayTop:
            return "Overlay Top"
        case .overlayBottom:
            return "Overlay Bottom"
        }
    }
}

extension CompositionTextWeight {
    fileprivate var inspectorLabel: String {
        switch self {
        case .regular:
            return "Regular"
        case .medium:
            return "Medium"
        case .semibold:
            return "Semibold"
        case .bold:
            return "Bold"
        }
    }
}

extension CompositionTextAlignment {
    fileprivate var inspectorLabel: String {
        switch self {
        case .leading:
            return "Left"
        case .center:
            return "Center"
        case .trailing:
            return "Right"
        }
    }
}

extension CompositionRegistrationMode {
    fileprivate var inspectorLabel: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .manual:
            return "Manual"
        case .disabled:
            return "Off"
        }
    }

    fileprivate var inspectorStatusLabel: String {
        switch self {
        case .automatic:
            return "automatic registration"
        case .manual:
            return "manual alignment"
        case .disabled:
            return "registration off"
        }
    }
}

private enum ComparisonResultChoice: String, CaseIterable, Identifiable {
    case showBoth
    case highlightChanges
    case alternate

    var id: String { rawValue }

    init(mode: CompositionComparisonMode) {
        switch mode {
        case .sideBySide, .overlay, .wipe:
            self = .showBoth
        case .difference, .changeHighlight:
            self = .highlightChanges
        case .blink:
            self = .alternate
        }
    }

    var label: String {
        switch self {
        case .showBoth:
            return "Show Both"
        case .highlightChanges:
            return "Highlight Changes"
        case .alternate:
            return "Alternate"
        }
    }

    var defaultMode: CompositionComparisonMode {
        switch self {
        case .showBoth:
            return .sideBySide
        case .highlightChanges:
            return .changeHighlight
        case .alternate:
            return .blink
        }
    }
}

extension CompositionDifferenceCueStyle {
    fileprivate var inspectorLabel: String {
        switch self {
        case .luminance:
            return "Luminance"
        case .outline:
            return "Outline"
        case .pattern:
            return "Pattern"
        case .outlineAndPattern:
            return "Outline + Pattern"
        }
    }
}

extension CompositionPosterFrame {
    fileprivate var inspectorLabel: String {
        switch self {
        case .primary:
            return "A / Before"
        case .secondary:
            return "B / After"
        }
    }
}

extension CompositionStepFlow {
    fileprivate var inspectorLabel: String {
        switch self {
        case .row:
            return "Row"
        case .column:
            return "Column"
        case .grid:
            return "Grid"
        }
    }
}

extension CompositionItemSemanticRole {
    fileprivate var inspectorLabel: String {
        switch self {
        case .standard:
            return "Standard"
        case .before:
            return "Before / A"
        case .after:
            return "After / B"
        case .step:
            return "Step"
        }
    }

    fileprivate var inspectorShortLabel: String {
        switch self {
        case .standard:
            return "Item"
        case .before:
            return "Before"
        case .after:
            return "After"
        case .step:
            return "Step"
        }
    }
}

extension CompositionInsets {
    fileprivate var uniformValue: CGFloat {
        (top + leading + bottom + trailing) / 4
    }
}

extension CompositionCanvasFill {
    fileprivate var color: RGBAColor? {
        switch self {
        case .transparent:
            return nil
        case .color(let color):
            return color
        }
    }
}

extension RGBAColor {
    fileprivate var luminance: CGFloat {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

private func compositionDeferPublish(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        action()
    }
}
