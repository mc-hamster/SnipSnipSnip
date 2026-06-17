import SwiftUI

/// Defer a closure past the current SwiftUI view update cycle to avoid
/// "Publishing changes from within view updates is not allowed" warnings.
/// Use this to wrap controller mutations triggered by SwiftUI bindings.
private func deferPublish(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        action()
    }
}

private enum PresentationBackgroundChoice: String, CaseIterable, Identifiable {
    case transparent
    case solid
    case gradient
    case spotlight
    case blurredScreenshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent:
            return "Transparent"
        case .solid:
            return "Solid"
        case .gradient:
            return "Gradient"
        case .spotlight:
            return "Spotlight"
        case .blurredScreenshot:
            return "Blurred"
        }
    }

    init(background: ScreenshotPresentationBackground) {
        switch background {
        case .transparent:
            self = .transparent
        case .solid:
            self = .solid
        case .twoColorGradient:
            self = .gradient
        case .radialSpotlight:
            self = .spotlight
        case .blurredScreenshot:
            self = .blurredScreenshot
        }
    }

    func background(current: ScreenshotPresentationBackground) -> ScreenshotPresentationBackground {
        switch self {
        case .transparent:
            return .transparent
        case .solid:
            if case .solid = current {
                return current
            }
            return .solid(RGBAColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1))
        case .gradient:
            if case .twoColorGradient = current {
                return current
            }
            return .twoColorGradient(
                start: RGBAColor(red: 0.91, green: 0.95, blue: 1.0, alpha: 1),
                end: RGBAColor(red: 0.70, green: 0.76, blue: 0.88, alpha: 1)
            )
        case .spotlight:
            if case .radialSpotlight = current {
                return current
            }
            return .radialSpotlight(
                base: RGBAColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1),
                spotlight: RGBAColor(red: 0.44, green: 0.64, blue: 1.0, alpha: 1)
            )
        case .blurredScreenshot:
            if case .blurredScreenshot = current {
                return current
            }
            return .blurredScreenshot(tint: RGBAColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 0.38))
        }
    }
}

private enum PresentationInspectorTab: String, CaseIterable, Identifiable {
    case style
    case scene

    var id: String { rawValue }

    var label: String {
        switch self {
        case .style:
            return "Style"
        case .scene:
            return "Scene"
        }
    }
}

struct PresentationInspectorView: View {
    @ObservedObject var controller: EditorController
    @State private var isShowingShadowFineTuning = false
    @State private var selectedPresentationTemplateID: String?
    @State private var presentationTemplateNameDraft = "Custom Style"
    @State private var selectedSavedPresentationID: UUID?
    @State private var savedPresentationNameDraft = "Presentation"
    @State private var selectedTab: PresentationInspectorTab = .style
    @State private var isShowingSceneFramingAdjustments = false
    @State private var isShowingStyleManagement = false
    @State private var isShowingSceneFiles = false
    @State private var isShowingSceneDiagnostics = false
    @State private var isShowingVariants = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Presentation") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Presentation", systemImage: EditorWorkspaceMode.presentation.systemImage)
                        .font(.headline)

                    Text(presentationSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Type", selection: $selectedTab) {
                        ForEach(PresentationInspectorTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)

                    if selectedTab == .style {
                        presentationTemplateTiles

                        DisclosureGroup("Manage Styles", isExpanded: $isShowingStyleManagement) {
                            presentationTemplateActions
                                .padding(.top, 8)
                        }
                    } else {
                        presentationSceneLibrary
                    }
                }
            }

            if selectedTab == .style {
                GroupBox("Background") {
                    presentationBackgroundControls
                }

                GroupBox("Effects") {
                    presentationEffectsControls
                }
            } else {
                GroupBox("Scene Slots") {
                    presentationSceneSlotControls
                }

                GroupBox("Scene Files") {
                    presentationSceneFileControls
                }

                if !controller.presentationSceneDiagnostics.isEmpty {
                    GroupBox("Scene Diagnostics") {
                        DisclosureGroup("Review Issues", isExpanded: $isShowingSceneDiagnostics) {
                            presentationSceneDiagnostics
                                .padding(.top, 8)
                        }
                    }
                }
            }

            GroupBox("Variants") {
                savedPresentationLibrary
            }
        }
        .onAppear {
            syncSelectedPresentationTemplate()
            syncSelectedSavedPresentation()
        }
        .onChange(of: controller.presentationTemplates) { _, _ in
            syncSelectedPresentationTemplate()
        }
        .onChange(of: controller.savedPresentations) { _, _ in
            syncSelectedSavedPresentation()
        }
    }

    private var presentationTemplateTiles: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            ForEach(controller.presentationTemplates) { template in
                PresentationTemplateTileView(
                    controller: controller,
                    template: template,
                    isSelected: selectedPresentationTemplateID == template.id || controller.presentation == template.presentation,
                    isDefault: controller.defaultPresentationTemplateID == template.id,
                    action: {
                        selectedPresentationTemplateID = template.id
                        presentationTemplateNameDraft = template.name
                        deferPublish { controller.applyPresentationTemplate(id: template.id) }
                    }
                )
            }
        }
    }

    private var selectedPresentationTemplate: PresentationTemplate? {
        guard let selectedPresentationTemplateID else {
            return nil
        }

        return controller.presentationTemplates.first { $0.id == selectedPresentationTemplateID }
    }

    private var presentationSummary: String {
        if let template = controller.presentationTemplates.first(where: { controller.presentation == $0.presentation }) {
            return "Style: \(template.name)"
        }

        if let scene = controller.presentation.scene {
            return "Scene: \(scene.name)"
        }

        return "Unsaved presentation"
    }

    private var presentationSceneLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.presentationScenes.isEmpty {
                Label("No valid scenes found. Add SVG scenes to the User folder or reload after restoring bundled examples.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(PresentationSceneSource.allCases, id: \.rawValue) { source in
                    let scenes = controller.presentationScenes.filter { $0.source == source }
                    if !scenes.isEmpty {
                        Text(source.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ], spacing: 10) {
                            ForEach(scenes) { scene in
                                PresentationSceneTileView(
                                    controller: controller,
                                    scene: scene,
                                    isSelected: controller.presentation.scene?.sceneID == scene.id,
                                    action: {
                                        deferPublish { controller.applyPresentationScene(id: scene.id) }
                                    }
                                )
                            }
                        }
                    }
                }
            }

            Button {
                deferPublish { controller.clearPresentationScene() }
            } label: {
                Label("Clear Scene", systemImage: "xmark.circle")
            }
            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            .disabled(controller.presentation.scene == nil)
        }
    }

    private var savedPresentationLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Variant Name", text: $savedPresentationNameDraft)
                    .textFieldStyle(.roundedBorder)

                Button {
                    let requestedName = savedPresentationNameDraft
                    deferPublish {
                        if let id = controller.saveCurrentPresentationToDocument(named: requestedName) {
                            selectedSavedPresentationID = id
                            isShowingVariants = true
                            if let saved = controller.savedPresentations.first(where: { $0.id == id }) {
                                savedPresentationNameDraft = saved.name
                            }
                        }
                    }
                } label: {
                    Label("Save", systemImage: "plus")
                }
                .buttonStyle(SSSChromeButtonStyle())
                .help("Save the current presentation as a variant in this .sss document.")
            }

            if controller.savedPresentations.isEmpty {
                Label("No variants saved in this document yet.", systemImage: "tray")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Manage Variants", isExpanded: $isShowingVariants) {
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ], spacing: 10) {
                            ForEach(controller.savedPresentations) { saved in
                                SavedPresentationTileView(
                                    controller: controller,
                                    savedPresentation: saved,
                                    isSelected: selectedSavedPresentationID == saved.id || controller.presentation == saved.presentation,
                                    action: {
                                        selectedSavedPresentationID = saved.id
                                        savedPresentationNameDraft = saved.name
                                        deferPublish { controller.applySavedPresentation(id: saved.id) }
                                    }
                                )
                            }
                        }

                        savedPresentationManagementButtons
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var savedPresentationManagementButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    guard let selectedSavedPresentationID else {
                        return
                    }
                    let requestedName = savedPresentationNameDraft
                    deferPublish {
                        controller.renameSavedPresentation(id: selectedSavedPresentationID, name: requestedName)
                        if let saved = controller.savedPresentations.first(where: { $0.id == selectedSavedPresentationID }) {
                            savedPresentationNameDraft = saved.name
                        }
                    }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedSavedPresentation == nil)

                Button {
                    guard let selectedSavedPresentationID else {
                        return
                    }
                    deferPublish { controller.updateSavedPresentation(id: selectedSavedPresentationID) }
                } label: {
                    Label("Update", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedSavedPresentation == nil)
                .help("Replace the selected saved presentation with the current Presentation settings.")
            }

            HStack(spacing: 8) {
                Button {
                    guard let selectedSavedPresentationID else {
                        return
                    }
                    deferPublish {
                        if let id = controller.duplicateSavedPresentation(id: selectedSavedPresentationID) {
                            self.selectedSavedPresentationID = id
                            if let saved = controller.savedPresentations.first(where: { $0.id == id }) {
                                savedPresentationNameDraft = saved.name
                            }
                        }
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedSavedPresentation == nil)

                Button(role: .destructive) {
                    guard let selectedSavedPresentationID else {
                        return
                    }
                    deferPublish {
                        controller.deleteSavedPresentation(id: selectedSavedPresentationID)
                        self.selectedSavedPresentationID = nil
                        syncSelectedSavedPresentation()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedSavedPresentation == nil)
            }
        }
    }

    private var selectedSavedPresentation: SavedPresentation? {
        guard let selectedSavedPresentationID else {
            return nil
        }

        return controller.savedPresentations.first { $0.id == selectedSavedPresentationID }
    }

    @ViewBuilder
    private var presentationSceneSlotControls: some View {
        if let scene = controller.presentation.scene {
            let metadata = try? PresentationSceneValidator
                .validate(
                    svgText: scene.sanitizedSVGText,
                    source: scene.sceneID.hasPrefix("builtin.") ? .bundled : .user
                )
                .metadata

            VStack(alignment: .leading, spacing: 12) {
                Picker("Framing", selection: Binding(get: {
                    scene.screenshotSlotSettings.framingPreset
                }, set: { preset in
                    deferPublish { controller.updateAppliedPresentationSceneFramingPreset(preset) }
                })) {
                    ForEach(PresentationSceneFramingPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)

                if let analysis = controller.presentationSceneFramingAnalysis() {
                    sceneFramingWarnings(analysis)
                }

                DisclosureGroup("Adjust", isExpanded: $isShowingSceneFramingAdjustments) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Align")
                            Spacer(minLength: 8)
                            SubjectAlignmentPicker(
                                selection: scene.screenshotSlotSettings.alignment,
                                action: { alignment in
                                    deferPublish { controller.updateAppliedPresentationSceneFramingAlignment(alignment) }
                                }
                            )
                        }

                        presentationSlider(
                            "Scale",
                            value: scene.screenshotSlotSettings.scale,
                            range: (metadata?.primaryScreenshotSlot?.effectiveMinScale ?? 0.25)...(metadata?.primaryScreenshotSlot?.effectiveMaxScale ?? 3),
                            step: 0.01,
                            help: "Scale the screenshot inside the scene slot.",
                            action: controller.updateAppliedPresentationSceneFramingScale,
                            displaysPercent: true
                        )

                        sceneFramingNudgeControls

                        Button {
                            deferPublish { controller.resetAppliedPresentationSceneFraming() }
                        } label: {
                            Label("Reset Framing", systemImage: "scope")
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    }
                    .padding(.top, 8)
                }
                .disabled(metadata?.primaryScreenshotSlot?.allowUserOverride == false)

                ForEach(metadata?.textSlots ?? [], id: \.id) { slot in
                    TextField(slot.label, text: Binding(get: {
                        scene.textSlotValues[slot.id] ?? slot.defaultValue ?? ""
                    }, set: { value in
                        deferPublish { controller.updateAppliedPresentationSceneTextSlot(id: slot.id, value: value) }
                    }))
                    .textFieldStyle(.roundedBorder)
                }
            }
        } else {
            Text("Select a scene to edit its slots.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sceneFramingWarnings(_ analysis: PresentationSceneFramingAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(analysis.warningMessages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if analysis.hasManualAdjustment {
                Label("Manual framing is active.", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sceneFramingNudgeControls: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Nudge")
            Spacer(minLength: 8)
            Button {
                deferPublish { controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(width: -8, height: 0)) }
            } label: {
                Image(systemName: "arrow.left")
            }
            .help("Nudge left")

            Button {
                deferPublish { controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(width: 0, height: -8)) }
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Nudge up")

            Button {
                deferPublish { controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(width: 0, height: 8)) }
            } label: {
                Image(systemName: "arrow.down")
            }
            .help("Nudge down")

            Button {
                deferPublish { controller.adjustAppliedPresentationSceneFramingOffset(by: CGSize(width: 8, height: 0)) }
            } label: {
                Image(systemName: "arrow.right")
            }
            .help("Nudge right")
        }
        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
    }

    private var presentationSceneFileControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.presentationScenesRootURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button {
                    deferPublish { controller.revealPresentationScenesUserFolder() }
                } label: {
                    Label("Reveal User Folder", systemImage: "folder")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                Button {
                    deferPublish { controller.reloadPresentationScenes() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            }

            DisclosureGroup("Folder Layout", isExpanded: $isShowingSceneFiles) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Bundled contains app-managed examples.", systemImage: "shippingbox")
                    Label("User contains custom SVG scenes.", systemImage: "person.crop.rectangle.stack")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
    }

    private var presentationSceneDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.presentationSceneDiagnostics) { diagnostic in
                VStack(alignment: .leading, spacing: 3) {
                    Label(diagnostic.message, systemImage: diagnostic.severity.systemImage)
                        .font(.footnote)
                        .foregroundStyle(diagnostic.severity.color)
                    if let filePath = diagnostic.filePath {
                        Text(filePath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var presentationTemplateActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Style Name", text: $presentationTemplateNameDraft)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button {
                    let requestedName = presentationTemplateNameDraft
                    deferPublish {
                        if let id = controller.saveCurrentPresentationAsTemplate(named: requestedName) {
                            selectedPresentationTemplateID = id
                            if let template = controller.presentationTemplates.first(where: { $0.id == id }) {
                                presentationTemplateNameDraft = template.name
                            }
                        }
                    }
                } label: {
                    Label("Save Style", systemImage: "plus")
                }
                .buttonStyle(SSSChromeButtonStyle())
                .help("Save the current native presentation style globally.")

                Button {
                    guard let selectedPresentationTemplateID else {
                        return
                    }
                    let requestedName = presentationTemplateNameDraft
                    deferPublish {
                        controller.renamePresentationTemplate(id: selectedPresentationTemplateID, name: requestedName)
                        if let template = controller.presentationTemplates.first(where: { $0.id == selectedPresentationTemplateID }) {
                            presentationTemplateNameDraft = template.name
                        }
                    }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedPresentationTemplate?.isBuiltIn ?? true)

                Button {
                    guard let selectedPresentationTemplateID else {
                        return
                    }
                    deferPublish {
                        if let id = controller.duplicatePresentationTemplate(id: selectedPresentationTemplateID) {
                            self.selectedPresentationTemplateID = id
                            if let template = controller.presentationTemplates.first(where: { $0.id == id }) {
                                presentationTemplateNameDraft = template.name
                            }
                        }
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedPresentationTemplate == nil)
            }

            HStack(spacing: 8) {
                Button {
                    guard let selectedPresentationTemplateID else {
                        return
                    }
                    deferPublish { controller.setDefaultPresentationTemplate(id: selectedPresentationTemplateID) }
                } label: {
                    Label("Default", systemImage: controller.defaultPresentationTemplateID == selectedPresentationTemplateID ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.defaultPresentationTemplateID == selectedPresentationTemplateID))
                .disabled(selectedPresentationTemplate == nil)

                Button {
                    deferPublish { controller.setDefaultPresentationTemplate(id: nil) }
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(controller.defaultPresentationTemplateID == nil)

                Button(role: .destructive) {
                    guard let selectedPresentationTemplateID else {
                        return
                    }
                    deferPublish {
                        controller.deletePresentationTemplate(id: selectedPresentationTemplateID)
                        self.selectedPresentationTemplateID = nil
                        syncSelectedPresentationTemplate()
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .disabled(selectedPresentationTemplate?.isBuiltIn ?? true)
            }
        }
    }

    private var presentationBackgroundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Style", selection: Binding(get: {
                PresentationBackgroundChoice(background: controller.presentation.background)
            }, set: { choice in
                deferPublish { controller.updatePresentationBackground(choice.background(current: controller.presentation.background)) }
            })) {
                ForEach(PresentationBackgroundChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)

            switch controller.presentation.background {
            case .transparent:
                EmptyView()
            case let .solid(color):
                presentationPaletteBlock("Color", selection: color, action: controller.updatePresentationBackgroundColor)
            case let .twoColorGradient(start, end):
                presentationPaletteBlock("Start", selection: start, action: controller.updatePresentationGradientStart)
                presentationPaletteBlock("End", selection: end, action: controller.updatePresentationGradientEnd)
            case let .radialSpotlight(base, spotlight):
                presentationPaletteBlock("Base", selection: base, action: controller.updatePresentationSpotlightBase)
                presentationPaletteBlock("Spotlight", selection: spotlight, action: controller.updatePresentationSpotlightColor)
            case let .blurredScreenshot(tint):
                presentationPaletteBlock("Tint", selection: tint, action: controller.updatePresentationBlurTint)
            }
        }
    }

    private var presentationEffectsControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            presentationSlider(
                "Spacing",
                value: controller.presentation.padding,
                range: 0...96,
                step: 2,
                help: "Add canvas space around the screenshot.",
                action: controller.updatePresentationPadding
            )
            presentationSlider(
                "Corners",
                value: controller.presentation.cornerRadius,
                range: 0...100,
                step: 1,
                help: "Round the screenshot corners.",
                action: controller.updatePresentationCornerRadius
            )

            Picker("Shadow", selection: Binding(get: {
                controller.presentation.shadow
            }, set: { shadow in
                deferPublish { controller.updatePresentationShadow(shadow) }
            })) {
                ForEach(ScreenshotShadowStyle.allCases) { shadow in
                    Text(shadow.label).tag(shadow)
                }
            }
            .help("Choose a ready-made shadow style.")

            if controller.presentation.shadow != .off {
                DisclosureGroup("Fine Tune Shadow", isExpanded: $isShowingShadowFineTuning) {
                    shadowFineTuningControls
                }
            }
        }
        .padding(.top, 8)
    }

    private func presentationPaletteBlock(
        _ label: String,
        selection: RGBAColor,
        action: @escaping @MainActor (RGBAColor) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
            presentationPaletteRow(selection: selection, action: action)
        }
    }

    private func presentationIntegerField(_ value: Int, onCommit: @escaping @MainActor (Int) -> Void) -> some View {
        TextField("", value: Binding(get: {
            Double(value)
        }, set: { newValue in
            deferPublish { onCommit(max(Int(newValue.rounded()), 1)) }
        }), format: .number.precision(.fractionLength(0)))
            .multilineTextAlignment(.trailing)
            .frame(width: 74)
            .textFieldStyle(.roundedBorder)
    }

    private func syncSelectedPresentationTemplate() {
        if let selectedPresentationTemplateID,
           let template = controller.presentationTemplates.first(where: { $0.id == selectedPresentationTemplateID }) {
            presentationTemplateNameDraft = template.name
            return
        }

        if let matchingTemplate = controller.presentationTemplates.first(where: { controller.presentation == $0.presentation }) {
            selectedPresentationTemplateID = matchingTemplate.id
            presentationTemplateNameDraft = matchingTemplate.name
        } else {
            selectedPresentationTemplateID = nil
            presentationTemplateNameDraft = "Custom Style"
        }
    }

    private func syncSelectedSavedPresentation() {
        if let selectedSavedPresentationID,
           let saved = controller.savedPresentations.first(where: { $0.id == selectedSavedPresentationID }) {
            savedPresentationNameDraft = saved.name
            return
        }

        if let matchingSaved = controller.savedPresentations.first(where: { controller.presentation == $0.presentation }) {
            selectedSavedPresentationID = matchingSaved.id
            savedPresentationNameDraft = matchingSaved.name
        } else {
            selectedSavedPresentationID = nil
            savedPresentationNameDraft = "Presentation"
        }
    }

    private var shadowFineTuningControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Direction")
                Spacer(minLength: 8)
                ShadowDirectionPicker(
                    selection: controller.presentation.shadowDirection,
                    action: { direction in
                        deferPublish { controller.updatePresentationShadowDirection(direction) }
                    }
                )
            }

            presentationSlider("Softness", value: controller.presentation.shadowBlurRadius, range: 0...96, step: 2, help: "Blur the shadow edge.", action: controller.updatePresentationShadowBlurRadius)
            presentationSlider("Horizontal", value: abs(controller.presentation.shadowOffsetX), range: 0...72, step: 2, help: "Move the shadow sideways.", action: controller.updatePresentationShadowOffsetX)
            presentationSlider("Vertical", value: abs(controller.presentation.shadowOffsetY), range: 0...72, step: 2, help: "Move the shadow up or down.", action: controller.updatePresentationShadowOffsetY)
            presentationSlider("Darkness", value: controller.presentation.shadowOpacity, range: 0...0.75, step: 0.01, help: "Adjust shadow darkness.", action: controller.updatePresentationShadowOpacity, displaysPercent: true)
        }
        .padding(.top, 8)
    }

    private func presentationSlider(
        _ label: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        help: String,
        action: @escaping (CGFloat) -> Void,
        displaysPercent: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .help(help)
            InspectorSlider(value: Binding(get: {
                value
            }, set: { newValue in
                deferPublish { action(newValue) }
            }), range: range, step: step)
            Text(displaysPercent ? "\(Int((value * 100).rounded()))%" : "\(Int(value))")
                .monospacedDigit()
                .frame(width: 34)
        }
    }

}

private struct LivePresentationThumbnailView: View {
    @ObservedObject var controller: EditorController
    var presentation: ScreenshotPresentation?
    var thumbnailSize = CGSize(width: 96, height: 64)
    var cornerRadius: CGFloat = 10
    var contentMode: ContentMode = .fill
    @State private var previewImage: CGImage?

    private var effectivePresentation: ScreenshotPresentation {
        presentation ?? controller.presentation
    }

    private var presentationBackgroundID: String {
        switch effectivePresentation.background {
        case .transparent:
            return "transparent"
        case let .solid(color):
            return "solid:\(color.red):\(color.green):\(color.blue):\(color.alpha)"
        case let .twoColorGradient(start, end):
            return "gradient:\(start.red):\(start.green):\(start.blue):\(start.alpha):\(end.red):\(end.green):\(end.blue):\(end.alpha)"
        case let .radialSpotlight(base, spotlight):
            return "spotlight:\(base.red):\(base.green):\(base.blue):\(base.alpha):\(spotlight.red):\(spotlight.green):\(spotlight.blue):\(spotlight.alpha)"
        case let .blurredScreenshot(tint):
            return "blurred:\(tint.red):\(tint.green):\(tint.blue):\(tint.alpha)"
        }
    }

    private var renderID: String {
        [
            "\(controller.presentationContentRevision)",
            "\(effectivePresentation.isEnabled)",
            effectivePresentation.scene.map { scene in
                [
                    scene.sceneID,
                    "\(scene.version)",
                    scene.textSlotValues.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
                    scene.screenshotSlotSettings.framingPreset.rawValue,
                    scene.screenshotSlotSettings.fit.rawValue,
                    scene.screenshotSlotSettings.alignment.rawValue,
                    "\(scene.screenshotSlotSettings.scale)",
                    "\(scene.screenshotSlotSettings.offset.width)",
                    "\(scene.screenshotSlotSettings.offset.height)",
                    "\(scene.screenshotSlotSettings.hasManualAdjustment)",
                ].joined(separator: ":")
            } ?? "scene:none",
            effectivePresentation.canvas.label,
            effectivePresentation.frame.kindLabel,
            effectivePresentation.subjectPlacement.fit.rawValue,
            effectivePresentation.subjectPlacement.alignment.rawValue,
            "\(effectivePresentation.subjectPlacement.scale)",
            "\(effectivePresentation.subjectPlacement.offset.width)",
            "\(effectivePresentation.subjectPlacement.offset.height)",
            "\(effectivePresentation.padding)",
            "\(effectivePresentation.cornerRadius)",
            effectivePresentation.shadow.rawValue,
            "\(effectivePresentation.shadowBlurRadius)",
            "\(effectivePresentation.shadowOffsetX)",
            "\(effectivePresentation.shadowOffsetY)",
            "\(effectivePresentation.shadowOpacity)",
            presentationBackgroundID,
            "\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))",
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.98),
                            Color(red: 0.88, green: 0.91, blue: 0.96),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(
                        width: max(thumbnailSize.width - 28, 1),
                        height: max(thumbnailSize.height - 28, 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            } else {
                RoundedRectangle(cornerRadius: max(cornerRadius - 4, 4), style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .frame(
                        width: max(thumbnailSize.width - 28, 1),
                        height: max(thumbnailSize.height - 28, 1)
                    )
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .task(id: renderID) {
            let cacheKey = renderID
            if let cachedImage = PresentationThumbnailCache.shared.image(for: cacheKey) {
                previewImage = cachedImage
                PresentationPerformanceMetrics.logEvent(
                    "presentationTemplateTile.render.cacheHit",
                    context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
                )
                return
            }

            PresentationPerformanceMetrics.logEvent(
                "presentationTemplateTile.render.schedule",
                context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) selected=\(presentation == nil)"
            )
            if previewImage != nil {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            guard !Task.isCancelled else {
                PresentationPerformanceMetrics.logEvent(
                    "presentationTemplateTile.render.cancel",
                    context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
                )
                return
            }
            let maxPixelDimension = max(thumbnailSize.width, thumbnailSize.height) * 2
            guard let input = controller.presentationPreviewRenderInput(
                presentation: presentation,
                context: "presentationTemplateTile"
            ) else {
                previewImage = nil
                PresentationPerformanceMetrics.logEvent(
                    "presentationTemplateTile.render.noInput",
                    context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
                )
                return
            }

            PresentationPerformanceMetrics.logEvent(
                "presentationTemplateTile.render.start",
                context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) revision=\(input.contentRevision) cap=\(Int(maxPixelDimension.rounded()))"
            )
            let image = await Task.detached(priority: .utility) {
                PresentationPerformanceMetrics.measure(
                    "presentationTemplateTile.detachedRender",
                    context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) revision=\(input.contentRevision) \(PresentationPerformanceMetrics.presentationSummary(input.presentation, maxPixelDimension: maxPixelDimension))",
                    warnAfterMS: 12
                ) {
                    ScreenshotPresentationRenderer.renderWithLayout(
                        contentImage: input.contentImage,
                        presentation: input.presentation,
                        maxPixelDimension: maxPixelDimension
                    )?.image
                }
            }.value

            guard !Task.isCancelled else {
                PresentationPerformanceMetrics.logEvent(
                    "presentationTemplateTile.render.cancel",
                    context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height))"
                )
                return
            }

            previewImage = image
            if let image {
                PresentationThumbnailCache.shared.insert(image, for: cacheKey)
            }
            PresentationPerformanceMetrics.logEvent(
                "presentationTemplateTile.render.finish",
                context: "size=\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)) image=\(PresentationPerformanceMetrics.imageSize(previewImage))"
            )
        }
    }
}

private final class PresentationThumbnailCache: @unchecked Sendable {
    static let shared = PresentationThumbnailCache()

    private final class Entry: NSObject {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 96
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, for key: String) {
        cache.setObject(Entry(image: image), forKey: key as NSString)
    }
}

private struct PresentationTemplateTileView: View {
    @ObservedObject var controller: EditorController
    let template: PresentationTemplate
    let isSelected: Bool
    let isDefault: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                LivePresentationThumbnailView(
                    controller: controller,
                    presentation: template.presentation,
                    thumbnailSize: CGSize(width: 112, height: 76),
                    cornerRadius: 10,
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity)

                HStack(spacing: 5) {
                    Text(template.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    if isDefault {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sssGlassSurface(cornerRadius: 12, tint: isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.03), shadowOpacity: 0.025)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.72) : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.4 : 0.8)
            }
        }
        .buttonStyle(.plain)
        .help("Apply the \(template.name) presentation template.")
    }
}

private struct PresentationSceneTileView: View {
    @ObservedObject var controller: EditorController
    let scene: PresentationSceneDefinition
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                LivePresentationThumbnailView(
                    controller: controller,
                    presentation: controller.presentationPreview(for: scene),
                    thumbnailSize: CGSize(width: 112, height: 76),
                    cornerRadius: 10,
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Text(scene.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text("v\(scene.version)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let description = scene.metadata.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(scene.fileURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sssGlassSurface(cornerRadius: 12, tint: isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.03), shadowOpacity: 0.02)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .help("Apply the \(scene.name) presentation scene.")
    }
}

private struct SavedPresentationTileView: View {
    @ObservedObject var controller: EditorController
    let savedPresentation: SavedPresentation
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                LivePresentationThumbnailView(
                    controller: controller,
                    presentation: savedPresentation.presentation,
                    thumbnailSize: CGSize(width: 112, height: 76),
                    cornerRadius: 10,
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity)

                Text(savedPresentation.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sssGlassSurface(cornerRadius: 12, tint: isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.03), shadowOpacity: 0.02)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .help("Apply the saved \(savedPresentation.name) presentation from this document.")
    }
}

private extension PresentationSceneDiagnosticSeverity {
    var systemImage: String {
        switch self {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct PresentationPaletteSwatchView: View {
    let option: PaletteColorOption
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(nsColor: option.color.nsColor))
            .overlay {
                if option.showsCheckerboard {
                    CheckerboardPattern()
                        .clipShape(Circle())
                }
            }
            .overlay {
                Circle()
                    .stroke(option.showsCheckerboard || option.color == .textForeground ? Color.black.opacity(0.18) : Color.clear, lineWidth: 1)
            }
            .frame(width: 20, height: 20)
            .overlay {
                Circle()
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.25), lineWidth: isSelected ? 3 : 1)
            }
    }
}

private func presentationPaletteRow(selection: RGBAColor, action: @escaping @MainActor (RGBAColor) -> Void) -> some View {
    let columns = [GridItem(.adaptive(minimum: 20, maximum: 20), spacing: 8)]

    return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(RGBAColor.paletteOptions) { option in
            Button {
                deferPublish { action(option.color) }
            } label: {
                PresentationPaletteSwatchView(option: option, isSelected: selection == option.color)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(option.label)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

private struct PresentationDirectionGridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        for index in 1...2 {
            let x = rect.minX + CGFloat(index) * thirdWidth
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + CGFloat(index) * thirdHeight
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        return path
    }
}

private struct SubjectAlignmentPicker: View {
    let selection: PresentationSubjectAlignment
    let action: (PresentationSubjectAlignment) -> Void

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 0), count: 3)
    private let alignments: [PresentationSubjectAlignment] = [
        .topLeft, .top, .topRight,
        .left, .center, .right,
        .bottomLeft, .bottom, .bottomRight,
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(alignments) { alignment in
                Button {
                    action(alignment)
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(alignment == selection ? Color.accentColor.opacity(0.62) : Color.clear)
                        if alignment == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(alignment.label) alignment")
                .help("\(alignment.label) alignment")
            }
        }
        .frame(width: 78, height: 72)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
        )
        .overlay {
            PresentationDirectionGridLines()
                .stroke(Color.primary.opacity(0.58), lineWidth: 1.5)
                .padding(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
