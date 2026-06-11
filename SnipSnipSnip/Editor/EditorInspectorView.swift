import SwiftUI

/// Defer a closure past the current SwiftUI view update cycle to avoid
/// "Publishing changes from within view updates is not allowed" warnings.
/// Use this to wrap controller mutations triggered by SwiftUI bindings.
private func deferPublish(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        action()
    }
}

private let collapsedInspectorHistoryLimit = 5
private struct HistoryPreviewSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

private struct InspectorGlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .sssGlassSurface(cornerRadius: 16, tint: .white.opacity(0.04), shadowOpacity: 0.035)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
    }
}

private struct UIMapInspectorLegendItem: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(color, lineWidth: 2)
                .background(color.opacity(0.16))
                .frame(width: 18, height: 14)

            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UIMapInspectorMetadataRow: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }
}

struct EditorHistoryActions {
    let onRestoreHistoryEntry: (DocumentHistoryEntry) -> Void
    let onRestoreRecentSnipEntry: (DocumentHistoryEntry) -> Void
    let onFloatHistoryEntry: (DocumentHistoryEntry) -> Void
    let onDeleteHistoryEntry: (DocumentHistoryEntry) -> Void
    let onDeleteAllHistoryEntries: () -> Void
    let onDeleteRecentSnipEntry: (DocumentHistoryEntry) -> Void
    let onDeleteAllRecentSnipEntries: () -> Void
    let onRestoreRecycledHistoryEntry: (DocumentHistoryEntry) -> Void
    let onPermanentlyDeleteRecycledHistoryEntry: (DocumentHistoryEntry) -> Void
    let onEmptyRecycleBin: () -> Void
}

struct EditorInspectorView: View {
    @ObservedObject var controller: EditorController
    let historyEntries: [DocumentHistoryEntry]
    let recentSnipEntries: [DocumentHistoryEntry]
    let captureHistoryEntries: [DocumentHistoryEntry]
    let recycleBinEntries: [DocumentHistoryEntry]
    @Binding var captureSearchQuery: String
    let captureHistorySearchResultsLabel: String
    let actions: EditorHistoryActions
    @Binding var previewedHistoryEntry: DocumentHistoryEntry?
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?
    @State private var isShowingRecycleBin = false
    @State private var isShowingPresentationPreview = false
    @State private var isShowingPresentationCustomization = false
    @State private var isShowingShadowFineTuning = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if showsUIMapInspectionSection {
                        uiMapInspectionSection
                    } else {
                        styleSection

                        if controller.showsTextAlignmentControls || controller.canAlignSelection {
                            alignmentSection
                        }
                    }

                    if controller.showsCropControls {
                        cropSection
                    }

                    if FeatureFlags.presentationStylingEnabled {
                        presentationSection
                    }

                    changeHistorySection

                    if !recentSnipEntries.isEmpty
                        || !captureHistoryEntries.isEmpty
                        || !captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recentSnipsSection
                    }
                }
                .padding(16)
            }

            Divider()

            recycleBinFooter
        }
        .groupBoxStyle(InspectorGlassGroupBoxStyle())
        .background(.thinMaterial)
        .sheet(isPresented: $isShowingRecycleBin) {
            RecycleBinSheetView(
                recycleBinEntries: recycleBinEntries,
                actions: actions
            )
            .frame(minWidth: 620, minHeight: 520)
        }
        .sheet(isPresented: $isShowingPresentationPreview) {
            PresentationPreviewSheetView(
                controller: controller,
                dragOutPayloadProvider: dragOutPayloadProvider
            )
            .frame(minWidth: 720, minHeight: 620)
        }
    }

    private var showsUIMapInspectionSection: Bool {
        FeatureFlags.uiMapEnabled && controller.isInspectingUIMap
    }

    private var uiMapInspectionSection: some View {
        GroupBox("UI Map") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    UIMapInspectorLegendItem(color: .blue, label: "AX element")
                    UIMapInspectorLegendItem(color: .orange, label: "OCR text")
                }
                .font(.caption)

                if controller.activeTool == .uiMapInspect {
                    Label("Pin UI Map previews the element under the pointer. Click an element to pin it; click it again to unpin it.", systemImage: "cursorarrow.rays")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Show all captured elements", isOn: Binding(get: {
                        controller.showsAllUIMapElements
                    }, set: { value in
                        deferPublish { controller.showsAllUIMapElements = value }
                    }))
                    .toggleStyle(.checkbox)
                    .help("Show UI Map outlines for captured controls and leaf elements without changing the screenshot.")
                }

                if let element = controller.selectedUIMapElement {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Element")
                            .font(.subheadline.weight(.semibold))

                        Button(controller.isUIMapElementPinned(element.id) ? "Unpin" : "Pin") {
                            controller.togglePinnedUIMapElement(element.id)
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: controller.isUIMapElementPinned(element.id) ? .orange : .accentColor))
                        .help(controller.isUIMapElementPinned(element.id)
                            ? "Remove this UI Map overlay from copied, shared, and exported screenshots."
                            : "Keep this UI Map overlay visible in copied, shared, and exported screenshots."
                        )

                        if controller.isUIMapElementPinned(element.id) {
                            Label("Pinned overlays are included when you copy, share, or export the screenshot.", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        uiMapMetadataRows(for: element)
                    }

                    Divider()

                    uiMapOverlayOptions

                    Button("Clear Selection") {
                        controller.selectUIMapElement(nil)
                    }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                } else {
                    Text(controller.activeTool == .uiMapInspect
                        ? "Move over a UI element in the screenshot to preview it, then click to pin it."
                        : "Select a UI Map element in the panel, or switch to Pin UI Map to pin elements directly from the screenshot."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func uiMapMetadataRows(for element: UIMapElement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            UIMapInspectorMetadataRow(
                label: "Source",
                value: element.isRecognizedTextSupplement ? "OCR supplement text" : "Accessibility element"
            )
            UIMapInspectorMetadataRow(label: "Name", value: element.name)
            UIMapInspectorMetadataRow(label: "Accessibility Label", value: element.accessibilityLabel)
            UIMapInspectorMetadataRow(label: "Accessibility Identifier", value: element.accessibilityIdentifier)
            UIMapInspectorMetadataRow(label: "Role", value: element.roleDescription ?? element.role)
            UIMapInspectorMetadataRow(label: "Value", value: element.valueDescription)
            UIMapInspectorMetadataRow(label: "Position", value: "\(Int(element.documentRect.minX)), \(Int(element.documentRect.minY))")
            UIMapInspectorMetadataRow(label: "Size", value: "\(Int(element.documentRect.width)) x \(Int(element.documentRect.height))")
            UIMapInspectorMetadataRow(label: "Owning Application", value: element.owningApplication)
            UIMapInspectorMetadataRow(label: "Bundle Identifier", value: element.bundleIdentifier)

            if let hierarchy = controller.uiMapSnapshot?.parentHierarchy(for: element.id),
               !hierarchy.isEmpty {
                UIMapInspectorMetadataRow(
                    label: "Parent Hierarchy",
                    value: hierarchy.map(\.displayName).joined(separator: " > ")
                )
            }
        }
    }

    private var uiMapOverlayOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display")
                .font(.subheadline.weight(.semibold))

            Toggle("Show outline", isOn: uiMapOverlayBinding(\.showsOutline))
            Toggle("Show label", isOn: uiMapOverlayBinding(\.showsLabel))
            Toggle("Show identifier", isOn: uiMapOverlayBinding(\.showsIdentifier))
            Toggle("Show role", isOn: uiMapOverlayBinding(\.showsRole))
            Toggle("Show coordinates", isOn: uiMapOverlayBinding(\.showsCoordinates))
            Toggle("Show dimensions", isOn: uiMapOverlayBinding(\.showsDimensions))
        }
    }

    private func uiMapOverlayBinding(_ keyPath: WritableKeyPath<UIMapOverlayOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.uiMapOverlayOptions[keyPath: keyPath] },
            set: { newValue in
                deferPublish {
                    var options = controller.uiMapOverlayOptions
                    options[keyPath: keyPath] = newValue
                    controller.uiMapOverlayOptions = options
                }
            }
        )
    }

    private var presentationSection: some View {
        GroupBox("Presentation") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a Look")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 8) {
                    ForEach(ScreenshotPresentationPreset.allCases) { preset in
                        Button(preset.label) {
                            deferPublish { controller.applyPresentationPreset(preset) }
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.presentation == preset.settings))
                    }
                }

                Text(presentationSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Customize", isExpanded: $isShowingPresentationCustomization) {
                    presentationCustomizationControls
                }

                if controller.requiresPNGForFaithfulExport {
                    Text("Transparent background preserves shadows with PNG. JPEG and PDF are disabled in the editor toolbar Export menu while this is active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button {
                    isShowingPresentationPreview = true
                } label: {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            LivePresentationThumbnailView(
                                controller: controller,
                                thumbnailSize: CGSize(width: max(proxy.size.width, 220), height: 176),
                                cornerRadius: 16,
                                contentMode: .fit
                            )

                            Image(systemName: "magnifyingglass")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .padding(10)
                        }
                    }
                    .frame(height: 176)
                }
                .buttonStyle(.plain)
                .help("Open a larger preview of the final export styling.")

                Text("Preview the current export styling before you copy, share, or save.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presentationSummary: String {
        switch ScreenshotPresentationPreset.allCases.first(where: { controller.presentation == $0.settings }) {
        case .some(.plain):
            return "Original screenshot with no added styling."
        case .some(.lifted):
            return "A polished canvas with comfortable spacing and depth."
        case .some(.transparentShadow):
            return "A classic drop shadow on a transparent background."
        case nil:
            return "Custom presentation styling."
        }
    }

    private var presentationCustomizationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Transparent Background", isOn: Binding(get: {
                controller.presentation.isTransparent
            }, set: { value in
                deferPublish { controller.updatePresentationBackgroundIsTransparent(value) }
            }))
            .toggleStyle(.switch)

            if !controller.presentation.isTransparent {
                Text("Canvas Color")
                    .font(.caption.weight(.semibold))
                paletteRow(selection: controller.presentationBackgroundColor, action: controller.updatePresentationBackgroundColor)
            }

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

    private var styleSection: some View {
        GroupBox("Style") {
            VStack(alignment: .leading, spacing: 12) {
                Text(controller.stylePrimaryLabel)
                    .font(.caption.weight(.semibold))
                    .help("Adjust the primary color used by the current tool or selection.")
                paletteRow(selection: controller.inspectorStyle.strokeColor, action: controller.updateStrokeColor)

                if controller.showsFillControls {
                    Text("Fill")
                        .font(.caption.weight(.semibold))
                        .help("Adjust the fill or background color for tools that render one.")
                    paletteRow(selection: controller.inspectorStyle.fillColor, action: controller.updateFillColor)
                }

                if controller.activeTool != .crop, controller.activeTool != .ocrText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sample From Image")
                            .font(.caption.weight(.semibold))
                            .help("Click the screenshot to sample a color from the base image.")

                        HStack {
                            Button {
                                controller.beginImageColorSampling(.picker)
                            } label: {
                                Label("Picker", systemImage: "eyedropper")
                            }
                            .buttonStyle(SSSChromeButtonStyle())
                            ColorSampleSwatchView(color: controller.sampledPickerPreviewColor)
                                .help("Current picker color.")

                            if controller.showsFillControls {
                                Button {
                                    controller.beginImageColorSampling(.fill)
                                } label: {
                                    Label("Fill", systemImage: "eyedropper.halffull")
                                }
                                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                                ColorSampleSwatchView(color: controller.sampledFillPreviewColor)
                                    .help("Current fill color.")
                            }
                        }

                        if controller.isSamplingImageColor {
                            Text("Press and drag on the image to preview \(controller.imageColorSamplingTarget == .fill ? "fill" : "picker") color; release to apply.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Text("Line")
                        .help("Set the stroke thickness for the current tool or selection.")
                    InspectorSlider(value: Binding(get: {
                        controller.inspectorStyle.lineWidth
                    }, set: { value in
                        deferPublish { controller.updateLineWidth(value) }
                    }), range: 0...controller.maxLineWidth, step: 1)
                    .help("Set the stroke thickness for the current tool or selection.")
                    Text("\(Int(controller.inspectorStyle.lineWidth))")
                        .monospacedDigit()
                        .frame(width: 28)
                }

                if controller.showsFontControls {
                    HStack {
                        Text("Font")
                            .help("Set the text size for text and callout annotations.")
                        InspectorSlider(value: Binding(get: {
                            max(controller.inspectorStyle.fontSize, 12)
                        }, set: { value in
                            deferPublish { controller.updateFontSize(value) }
                        }), range: 12...48, step: 1)
                        .help("Set the text size for text and callout annotations.")
                        Text("\(Int(max(controller.inspectorStyle.fontSize, 12)))")
                            .monospacedDigit()
                            .frame(width: 28)
                    }
                }

                if controller.showsEffectControls {
                    HStack {
                        Text("Effect")
                            .help("Set the blur or pixelation strength for redaction tools.")
                        InspectorSlider(value: Binding(get: {
                            max(controller.inspectorStyle.effectRadius, 0)
                        }, set: { value in
                            deferPublish { controller.updateEffectRadius(value) }
                        }), range: 0...32, step: 1)
                        .help("Set the blur or pixelation strength for redaction tools.")
                        Text("\(Int(max(controller.inspectorStyle.effectRadius, 0)))")
                            .monospacedDigit()
                            .frame(width: 28)
                    }

                    Picker("Redaction", selection: Binding(get: {
                        controller.currentRedactionMode
                    }, set: { value in
                        deferPublish { controller.updateRedactionMode(value) }
                    })) {
                        ForEach(RedactionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("Choose how the redaction selection is rendered.")
                }

                if controller.showsRectangleControls {
                    Divider()

                    HStack {
                        Text("Corners")
                            .help("Round rectangle corners for rectangle annotations.")
                        InspectorSlider(value: Binding(get: {
                            controller.inspectorStyle.cornerRadius
                        }, set: { value in
                            deferPublish { controller.updateCornerRadius(value) }
                        }), range: 0...48, step: 1)
                        Text("\(Int(controller.inspectorStyle.cornerRadius))")
                            .monospacedDigit()
                            .frame(width: 28)
                    }

                    Picker("Border", selection: Binding(get: {
                        controller.inspectorStyle.dashStyle
                    }, set: { value in
                        deferPublish { controller.updateDashStyle(value) }
                    })) {
                        ForEach(StrokeDashStyle.allCases) { dashStyle in
                            Text(dashStyle.label).tag(dashStyle)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fill Preset")
                            .font(.caption.weight(.semibold))

                        HStack {
                            Button("Outline") {
                                deferPublish { controller.applyRectangleFillPreset(nil) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == nil))

                            Button("Soft") {
                                deferPublish { controller.applyRectangleFillPreset(0.18) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == 0.18))

                            Button("Solid") {
                                deferPublish { controller.applyRectangleFillPreset(1) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == 1))
                        }
                    }
                }

                if controller.showsEllipseControls {
                    Divider()

                    Picker("Border", selection: Binding(get: {
                        controller.inspectorStyle.dashStyle
                    }, set: { value in
                        deferPublish { controller.updateDashStyle(value) }
                    })) {
                        ForEach(StrokeDashStyle.allCases) { dashStyle in
                            Text(dashStyle.label).tag(dashStyle)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fill Preset")
                            .font(.caption.weight(.semibold))

                        HStack {
                            Button("Outline") {
                                deferPublish { controller.applyEllipseFillPreset(nil) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == nil))

                            Button("Soft") {
                                deferPublish { controller.applyEllipseFillPreset(0.18) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == 0.18))

                            Button("Solid") {
                                deferPublish { controller.applyEllipseFillPreset(1) }
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary, isSelected: controller.activeFillPreset == 1))
                        }
                    }
                }

                if controller.showsFreehandTuningControls {
                    Divider()

                    HStack {
                        Text("Smoothing")
                            .help("Control how strongly freehand strokes are curved during rendering.")
                        InspectorSlider(value: Binding(get: {
                            controller.inspectorStyle.freehandSmoothing
                        }, set: { value in
                            deferPublish { controller.updateFreehandSmoothing(value) }
                        }), range: 0...1, step: 0.05)
                        Text("\(Int(controller.inspectorStyle.freehandSmoothing * 100))%")
                            .monospacedDigit()
                            .frame(width: 46)
                    }

                    HStack {
                        Text("Simplify")
                            .help("Reduce jitter by dropping very small point changes from freehand strokes.")
                        InspectorSlider(value: Binding(get: {
                            controller.inspectorStyle.freehandSimplification
                        }, set: { value in
                            deferPublish { controller.updateFreehandSimplification(value) }
                        }), range: 0...8, step: 0.5)
                        Text(String(format: "%.1f", controller.inspectorStyle.freehandSimplification))
                            .monospacedDigit()
                            .frame(width: 46)
                    }
                }

                if controller.showsArrowControls, let selectedArrow = controller.selectedAnnotation, case let .arrow(shape) = selectedArrow.kind {
                    Divider()

                    Picker("Head Ends", selection: Binding(get: {
                        shape.headStyle
                    }, set: { value in
                        deferPublish { controller.updateArrowHeadStyle(value) }
                    })) {
                        ForEach(ArrowHeadStyle.allCases) { headStyle in
                            Text(headStyle.label).tag(headStyle)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Head Style")
                            .font(.caption.weight(.semibold))
                        Picker("", selection: Binding(get: {
                            shape.headShape
                        }, set: { value in
                            deferPublish { controller.updateArrowHeadShape(value) }
                        })) {
                            ForEach(ArrowHeadShape.allCases) { headShape in
                                Text(headShape.label).tag(headShape)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("Curve")
                            .help("Bend the selected arrow into a curved connector.")
                        InspectorSlider(value: Binding(get: {
                            shape.curvature
                        }, set: { value in
                            deferPublish { controller.updateArrowCurvature(value) }
                        }), range: -180...180, step: 4)
                        Text("\(Int(shape.curvature))")
                            .monospacedDigit()
                            .frame(width: 42)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Label")
                            .font(.caption.weight(.semibold))
                        TextField("Arrow Label", text: Binding(get: {
                            controller.selectedArrowLabel
                        }, set: { value in
                            deferPublish { controller.updateArrowLabel(value) }
                        }))
                        .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Label Box")
                            .font(.caption.weight(.semibold))
                            .help("Set the arrow label background color. Transparent keeps the label unboxed.")
                        paletteRow(selection: controller.selectedArrowLabelBoxColor, action: controller.updateArrowLabelBoxColor)
                    }

                    Picker("Label Text", selection: Binding(get: {
                        controller.selectedArrowLabelTextColor
                    }, set: { value in
                        deferPublish { controller.updateArrowLabelTextColor(value) }
                    })) {
                        ForEach(ArrowLabelTextColor.allCases) { color in
                            Text(color.label).tag(color)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Label Position")
                            .font(.caption.weight(.semibold))
                        Picker("", selection: Binding(get: {
                            shape.labelPlacement
                        }, set: { value in
                            deferPublish { controller.updateArrowLabelPlacement(value) }
                        })) {
                            ForEach(ArrowLabelPlacement.allCases) { placement in
                                Text(placement.label).tag(placement)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Text("Label Font")
                            .help("Set the arrow label font size.")
                        InspectorSlider(value: Binding(get: {
                            shape.labelFontSize
                        }, set: { value in
                            deferPublish { controller.updateArrowLabelFontSize(value) }
                        }), range: 8...48, step: 1)
                        Text("\(Int(shape.labelFontSize))")
                            .monospacedDigit()
                            .frame(width: 28)
                    }
                }

                if controller.showsCalloutControls, let selectedCallout = controller.selectedAnnotation, case let .callout(shape) = selectedCallout.kind {
                    Divider()

                    Picker("Callout Style", selection: Binding(get: {
                        shape.style
                    }, set: { value in
                        deferPublish { controller.updateCalloutStyle(value) }
                    })) {
                        ForEach(CalloutVisualStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if controller.selectedAnnotations.contains(where: { annotation in
                    if case .callout = annotation.kind {
                        return true
                    }
                    return false
                }) || controller.snapshot.annotations.contains(where: { annotation in
                    if case .callout = annotation.kind {
                        return true
                    }
                    return false
                }) {
                    Divider()

                    HStack {
                        Button("Step Guide") {
                            controller.copyCalloutStepGuideToClipboard()
                        }
                        .buttonStyle(SSSChromeButtonStyle())
                        .help("Copy the current callouts as a numbered step guide.")
                    }
                }

                if controller.selectedCount > 0 {
                    Divider()

                    if let opacity = controller.selectedImageOverlayOpacity {
                        if controller.selectedImageOverlayRole == .capturedCursor {
                            Text("Captured Cursor")
                                .font(.caption.weight(.semibold))
                                .help("This cursor was captured as an editable overlay. Move, resize, or delete it like any other image overlay.")
                        }

                        HStack {
                            Text("Opacity")
                                .help("Adjust the selected image overlay opacity.")
                            InspectorSlider(value: Binding(get: {
                                opacity
                            }, set: { value in
                                deferPublish { controller.updateSelectedImageOverlayOpacity(value) }
                            }), range: 0...1, step: 0.05)
                            Text("\(Int((controller.selectedImageOverlayOpacity ?? opacity) * 100))%")
                                .monospacedDigit()
                                .frame(width: 46)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cropValueField(_ value: CGFloat, onCommit: @escaping @MainActor (CGFloat) -> Void) -> some View {
        TextField("", value: Binding(get: {
            Double(value)
        }, set: { newValue in
            deferPublish { onCommit(CGFloat(newValue)) }
        }), format: .number.precision(.fractionLength(0)))
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .textFieldStyle(.roundedBorder)
    }

    private var cropSection: some View {
        GroupBox("Crop") {
            let cropRect = controller.snapshot.cropRect.gscIntegralStandardized

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Crop Size")
                        .font(.caption.weight(.semibold))
                        .help("Current crop size in pixels.")

                    Text(controller.cropDimensionsLabel)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .help("Current crop width and height in pixels.")
                }

                Picker("Aspect", selection: Binding(get: {
                    controller.cropAspectRatioPreset
                }, set: { preset in
                    deferPublish { controller.updateCropAspectRatioPreset(preset) }
                })) {
                    ForEach(CropAspectRatioPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .help("Choose Freeform for an unconstrained crop, or a fixed aspect ratio for new crop drags and crop handle resizing.")

                HStack(spacing: 10) {
                    Text("X")
                        .frame(width: 14, alignment: .leading)
                    cropValueField(cropRect.minX) { value in
                        controller.updateCropOrigin(x: value)
                    }

                    Text("Y")
                        .frame(width: 14, alignment: .leading)
                    cropValueField(cropRect.minY) { value in
                        controller.updateCropOrigin(y: value)
                    }
                }

                HStack(spacing: 10) {
                    Text("W")
                        .frame(width: 14, alignment: .leading)
                    cropValueField(cropRect.width) { value in
                        controller.updateCropOrigin(width: value)
                    }

                    Text("H")
                        .frame(width: 14, alignment: .leading)
                    cropValueField(cropRect.height) { value in
                        controller.updateCropOrigin(height: value)
                    }
                }

                HStack {
                    Button("Reset Crop") {
                        controller.resetCrop()
                    }
                    .buttonStyle(SSSChromeButtonStyle())
                    .help("Restore the editable area to the full captured image.")
                    .disabled(!controller.canResetCrop)

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var alignmentSection: some View {
        GroupBox("Alignment") {
            if controller.showsTextAlignmentControls {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Text alignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        ForEach(TextAlignmentMode.allCases) { mode in
                            Button {
                                controller.updateTextAlignment(mode)
                            } label: {
                                Label(mode.shortLabel, systemImage: mode.systemImage)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                            .help(mode.label)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(AlignmentMode.allCases) { mode in
                        Button {
                            controller.alignSelected(mode)
                        } label: {
                            Label(mode.label, systemImage: mode.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Align selected annotations to the \(mode.label.lowercased()) edge or axis.")
                        .disabled(!controller.canAlignSelection)
                    }
                }
            }
        }
    }

    private var changeHistorySection: some View {
        ChangeHistorySectionView(
            historyEntries: historyEntries,
            actions: actions,
            previewedHistoryEntry: $previewedHistoryEntry
        )
        .equatable()
    }

    private var recentSnipsSection: some View {
        RecentSnipsSectionView(
            recentSnipEntries: recentSnipEntries,
            captureHistoryEntries: captureHistoryEntries,
            captureSearchQuery: $captureSearchQuery,
            captureHistorySearchResultsLabel: captureHistorySearchResultsLabel,
            actions: actions,
            previewedHistoryEntry: $previewedHistoryEntry
        )
        .equatable()
    }

    private func paletteRow(selection: RGBAColor, action: @escaping @MainActor (RGBAColor) -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 20, maximum: 20), spacing: 8)]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(RGBAColor.paletteOptions) { option in
                Button {
                    deferPublish { action(option.color) }
                } label: {
                    PaletteSwatchView(option: option, isSelected: selection == option.color)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(option.label)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recycleBinFooter: some View {
        Button {
            isShowingRecycleBin = true
        } label: {
            HStack(spacing: 8) {
                Label("Recycle Bin", systemImage: "trash")
                Spacer(minLength: 8)
                if !recycleBinEntries.isEmpty {
                    Text("\(recycleBinEntries.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .sssGlassSurface(cornerRadius: 14, tint: .white.opacity(0.04), shadowOpacity: 0.025)
        .padding(10)
        .help("Open deleted snips. Deleted items can be restored until the recycle bin is emptied or retention expires.")
    }
}

private struct LivePresentationThumbnailView: View {
    @ObservedObject var controller: EditorController
    var thumbnailSize = CGSize(width: 96, height: 64)
    var cornerRadius: CGFloat = 10
    var contentMode: ContentMode = .fill
    @State private var previewImage: CGImage?

    private var presentationBackgroundID: String {
        switch controller.presentation.background {
        case .transparent:
            return "transparent"
        case let .solid(color):
            return "solid:\(color.red):\(color.green):\(color.blue):\(color.alpha)"
        }
    }

    private var renderID: String {
        [
            "\(controller.canvasRevision)",
            "\(controller.persistenceRevision)",
            "\(controller.presentation.isEnabled)",
            "\(controller.presentation.padding)",
            "\(controller.presentation.cornerRadius)",
            controller.presentation.shadow.rawValue,
            "\(controller.presentation.shadowBlurRadius)",
            "\(controller.presentation.shadowOffsetX)",
            "\(controller.presentation.shadowOffsetY)",
            "\(controller.presentation.shadowOpacity)",
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
                .overlay {
                    if controller.presentation.isTransparent {
                        CheckerboardPattern()
                            .opacity(0.28)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }

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
            previewImage = controller.exportedImage()
        }
    }
}

private struct PaletteSwatchView: View {
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

private struct ColorSampleSwatchView: View {
    let color: RGBAColor

    var body: some View {
        Circle()
            .fill(Color(nsColor: color.nsColor))
            .overlay {
                if color.alpha == 0 {
                    CheckerboardPattern()
                        .clipShape(Circle())
                }
            }
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
            }
            .frame(width: 18, height: 18)
            .accessibilityLabel("Current color")
    }
}

private struct ShadowDirectionPicker: View {
    let selection: ScreenshotShadowDirection
    let action: (ScreenshotShadowDirection) -> Void

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 0), count: 3)
    private let directions: [ScreenshotShadowDirection] = [
        .topLeft, .top, .topRight,
        .left, .center, .right,
        .bottomLeft, .bottom, .bottomRight,
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(directions) { direction in
                Button {
                    action(direction)
                } label: {
                    ZStack {
                        Rectangle()
                            .fill(direction == selection ? Color.accentColor.opacity(0.62) : Color.clear)
                        if direction == selection {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(direction.accessibilityLabel) shadow")
                .help("\(direction.accessibilityLabel) shadow")
            }
        }
        .frame(width: 78, height: 72)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
        )
        .overlay {
            ShadowDirectionGridLines()
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

private struct ShadowDirectionGridLines: Shape {
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

private struct InspectorSlider: NSViewRepresentable {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: Double(value),
            minValue: Double(range.lowerBound),
            maxValue: Double(range.upperBound),
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 17
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = Double(range.lowerBound)
        slider.maxValue = Double(range.upperBound)
        slider.doubleValue = Double(value)
        slider.numberOfTickMarks = 17
        slider.tickMarkPosition = .below
    }

    final class Coordinator: NSObject {
        var parent: InspectorSlider

        init(_ parent: InspectorSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let rawValue = CGFloat(sender.doubleValue)
            let resolvedValue: CGFloat

            if parent.step > 0 {
                resolvedValue = (rawValue / parent.step).rounded() * parent.step
            } else {
                resolvedValue = rawValue
            }

            parent.value = min(max(resolvedValue, parent.range.lowerBound), parent.range.upperBound)
        }
    }
}

private struct CheckerboardPattern: View {
    private let tileSize: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let columns = Int(ceil(proxy.size.width / tileSize))
            let rows = Int(ceil(proxy.size.height / tileSize))

            Canvas { context, _ in
                let light = Color.white
                let dark = Color(nsColor: .quaternaryLabelColor).opacity(0.35)

                for row in 0..<rows {
                    for column in 0..<columns {
                        let rect = CGRect(
                            x: CGFloat(column) * tileSize,
                            y: CGFloat(row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(
                            Path(rect),
                            with: .color((row + column).isMultiple(of: 2) ? light : dark)
                        )
                    }
                }
            }
        }
    }
}

private struct ChangeHistorySectionView: View, Equatable {
    let historyEntries: [DocumentHistoryEntry]
    let actions: EditorHistoryActions
    @Binding var previewedHistoryEntry: DocumentHistoryEntry?
    @State private var showsAllEntries = false

    static func == (lhs: ChangeHistorySectionView, rhs: ChangeHistorySectionView) -> Bool {
        historyEntriesEqual(lhs.historyEntries, rhs.historyEntries)
    }

    private var displayedEntries: [DocumentHistoryEntry] {
        if showsAllEntries {
            return historyEntries
        }

        return Array(historyEntries.prefix(collapsedInspectorHistoryLimit))
    }

    var body: some View {
        GroupBox("Change History") {
            VStack(alignment: .leading, spacing: 12) {
                if historyEntries.isEmpty {
                    Text("Autosave history appears here after edits or saves.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text("Click a thumbnail to inspect a snapshot before restoring it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        Button(role: .destructive, action: actions.onDeleteAllHistoryEntries) {
                            Label("Clear", systemImage: "trash")
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .controlSize(.small)
                        .help("Delete every history snapshot for this snip.")
                    }

                    ForEach(displayedEntries) { entry in
                        HistoryEntryRowView(
                            entry: entry,
                            title: entry.historySummary,
                            titleHelp: entry.historySummaryHelp,
                            subtitle: entry.savedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                            detail: nil,
                            previewHelp: "Open a larger preview of this history snapshot.",
                            restoreLabel: "Restore",
                            restoreHelp: "Restore the document to this history snapshot.",
                            deleteHelp: "Delete this history snapshot.",
                            onPreview: {
                                previewedHistoryEntry = entry
                            },
                            onRestore: {
                                actions.onRestoreHistoryEntry(entry)
                            },
                            onDelete: {
                                if previewedHistoryEntry?.id == entry.id {
                                    previewedHistoryEntry = nil
                                }
                                actions.onDeleteHistoryEntry(entry)
                            }
                        )
                    }

                    if historyEntries.count > collapsedInspectorHistoryLimit {
                        ExpandCollapseHistoryButton(
                            title: showsAllEntries ? "Less" : "More"
                        ) {
                            showsAllEntries.toggle()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecentSnipsSectionView: View, Equatable {
    let recentSnipEntries: [DocumentHistoryEntry]
    let captureHistoryEntries: [DocumentHistoryEntry]
    @Binding var captureSearchQuery: String
    let captureHistorySearchResultsLabel: String
    let actions: EditorHistoryActions
    @Binding var previewedHistoryEntry: DocumentHistoryEntry?
    @State private var showsAllRecentSnips = false

    static func == (lhs: RecentSnipsSectionView, rhs: RecentSnipsSectionView) -> Bool {
        historyEntriesEqual(lhs.recentSnipEntries, rhs.recentSnipEntries)
            && historyEntriesEqual(lhs.captureHistoryEntries, rhs.captureHistoryEntries)
            && lhs.captureSearchQuery == rhs.captureSearchQuery
            && lhs.captureHistorySearchResultsLabel == rhs.captureHistorySearchResultsLabel
    }

    private var displayedRecentSnips: [DocumentHistoryEntry] {
        if showsAllRecentSnips {
            return recentSnipEntries
        }

        return Array(recentSnipEntries.prefix(collapsedInspectorHistoryLimit))
    }

    private var filteredCaptureHistoryEntries: [DocumentHistoryEntry] {
        let query = captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return captureHistoryEntries
        }

        return captureHistoryEntries.filter { $0.matchesSearchQuery(query) }
    }

    private var showsSearchResults: Bool {
        !captureSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GroupBox("Recent Snips") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Text("Switch back to an earlier snip without interrupting the current capture flow.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button(role: .destructive, action: actions.onDeleteAllRecentSnipEntries) {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .controlSize(.small)
                    .disabled(recentSnipEntries.isEmpty)
                    .help("Delete every recent snip except the one currently open.")
                }

                TextField("Search captures", text: $captureSearchQuery)
                    .textFieldStyle(.roundedBorder)

                Text(captureHistorySearchResultsLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if showsSearchResults {
                    if captureHistoryEntries.isEmpty {
                        Text("Capture history search appears here after you have autosaves, recent snips, or saved checkpoints to search.")
                            .foregroundStyle(.secondary)
                    } else if filteredCaptureHistoryEntries.isEmpty {
                        Text("No captures matched the current search.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredCaptureHistoryEntries) { entry in
                            HistoryEntryRowView(
                                entry: entry,
                                title: entry.title,
                                titleHelp: nil,
                                subtitle: entry.savedAt.formatted(date: .abbreviated, time: .shortened),
                                detail: entry.label,
                                previewHelp: "Open a larger preview of this capture history entry.",
                                restoreLabel: "Open",
                                restoreHelp: "Open this capture history entry in the editor.",
                                deleteHelp: "Delete this capture history entry.",
                                onPreview: {
                                    previewedHistoryEntry = entry
                                },
                                onRestore: {
                                    actions.onRestoreHistoryEntry(entry)
                                },
                                onDelete: {
                                    if previewedHistoryEntry?.id == entry.id {
                                        previewedHistoryEntry = nil
                                    }
                                    actions.onDeleteHistoryEntry(entry)
                                }
                            )
                        }
                    }
                }

                if !recentSnipEntries.isEmpty {
                    if showsSearchResults {
                        Divider()
                    }

                    ForEach(displayedRecentSnips) { entry in
                        HistoryEntryRowView(
                            entry: entry,
                            title: entry.title,
                            titleHelp: nil,
                            subtitle: entry.savedAt.formatted(date: .abbreviated, time: .shortened),
                            detail: entry.label,
                            previewHelp: "Open a larger preview of this recent snip.",
                            restoreLabel: "Restore",
                            restoreHelp: "Restore this recent snip and keep the current one in Recent Snips.",
                            deleteHelp: "Delete this recent snip.",
                            onPreview: {
                                previewedHistoryEntry = entry
                            },
                            onRestore: {
                                actions.onRestoreRecentSnipEntry(entry)
                            },
                            onDelete: {
                                if previewedHistoryEntry?.id == entry.id {
                                    previewedHistoryEntry = nil
                                }
                                actions.onDeleteRecentSnipEntry(entry)
                            }
                        )
                    }

                    if recentSnipEntries.count > collapsedInspectorHistoryLimit {
                        ExpandCollapseHistoryButton(
                            title: showsAllRecentSnips ? "Less" : "More"
                        ) {
                            showsAllRecentSnips.toggle()
                        }
                    }
                } else if !showsSearchResults {
                    Text("Recent snips appear here when a newer capture replaces the current editor session.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RecycleBinSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let recycleBinEntries: [DocumentHistoryEntry]
    let actions: EditorHistoryActions
    @State private var previewedEntry: DocumentHistoryEntry?

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recycle Bin")
                            .font(.title2.weight(.semibold))

                        Text("Deleted snips stay here temporarily and can be restored before the recycle bin is emptied.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                Spacer(minLength: 12)

                Button(action: dismiss.callAsFunction) {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .keyboardShortcut(.cancelAction)
                .help("Close the recycle bin.")

                Button(role: .destructive, action: actions.onEmptyRecycleBin) {
                    Label("Empty Now", systemImage: "trash.slash")
                }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .disabled(recycleBinEntries.isEmpty)
                    .help("Permanently delete every item currently in the recycle bin.")
                }
                .padding(20)

                Divider()

                if recycleBinEntries.isEmpty {
                    ContentUnavailableView(
                        "Recycle Bin is Empty",
                        systemImage: "trash",
                        description: Text("Deleted snips will appear here until retention expires or you empty the recycle bin.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(recycleBinEntries) { entry in
                                RecycleBinEntryRowView(
                                    entry: entry,
                                    onPreview: {
                                        previewedEntry = entry
                                    },
                                    onRestore: {
                                        previewedEntry = nil
                                        actions.onRestoreRecycledHistoryEntry(entry)
                                        dismiss()
                                    },
                                    onPermanentDelete: {
                                        if previewedEntry?.id == entry.id {
                                            previewedEntry = nil
                                        }
                                        actions.onPermanentlyDeleteRecycledHistoryEntry(entry)
                                    }
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            if let previewedEntry {
                HistoryPreviewOverlayView(
                    entry: previewedEntry,
                    onClose: {
                        self.previewedEntry = nil
                    },
                    onFloat: {
                        actions.onFloatHistoryEntry(previewedEntry)
                    },
                    onRestore: {
                        self.previewedEntry = nil
                        actions.onRestoreRecycledHistoryEntry(previewedEntry)
                        dismiss()
                    }
                )
                .zIndex(1)
            }
        }
    }
}

private struct RecycleBinEntryRowView: View {
    let entry: DocumentHistoryEntry
    let onPreview: () -> Void
    let onRestore: () -> Void
    let onPermanentDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onPreview) {
                DocumentPreviewThumbnailView(
                    packageURL: entry.packageURL,
                    thumbnailSize: CGSize(width: 116, height: 76),
                    cornerRadius: 12
                )
            }
            .buttonStyle(.plain)
            .help("Open a larger preview of this deleted snip.")

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(entry.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(deletedDateLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button("Restore", action: onRestore)
                    .buttonStyle(SSSChromeButtonStyle())
                    .help("Restore this snip and open it in the editor.")

                Button(role: .destructive, action: onPermanentDelete) {
                    Label("Delete Forever", systemImage: "trash.slash")
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .controlSize(.small)
                .help("Permanently delete this snip from the recycle bin.")
            }
        }
        .padding(14)
        .sssGlassSurface(cornerRadius: 12, shadowOpacity: 0.03)
    }

    private var deletedDateLabel: String {
        guard let deletedAt = entry.deletedAt else {
            return "Deleted recently"
        }

        return "Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ExpandCollapseHistoryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryEntryRowView: View, Equatable {
    let entry: DocumentHistoryEntry
    let title: String
    let titleHelp: String?
    let subtitle: String
    let detail: String?
    let previewHelp: String
    let restoreLabel: String
    let restoreHelp: String
    let deleteHelp: String
    let onPreview: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    static func == (lhs: HistoryEntryRowView, rhs: HistoryEntryRowView) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.title == rhs.title
            && lhs.titleHelp == rhs.titleHelp
            && lhs.subtitle == rhs.subtitle
            && lhs.detail == rhs.detail
            && lhs.previewHelp == rhs.previewHelp
            && lhs.restoreLabel == rhs.restoreLabel
            && lhs.restoreHelp == rhs.restoreHelp
            && lhs.deleteHelp == rhs.deleteHelp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onPreview) {
                    ZStack(alignment: .bottomTrailing) {
                        DocumentPreviewThumbnailView(
                            packageURL: entry.packageURL,
                            thumbnailSize: CGSize(width: 88, height: 58),
                            cornerRadius: 12
                        )

                        Image(systemName: "magnifyingglass")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 24, height: 24)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(6)
                    }
                }
                .buttonStyle(.plain)
                .help(previewHelp)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .help(titleHelp ?? title)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail {
                        Text(detail)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(detail == "Includes unsaved changes" ? .orange : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(restoreLabel, action: onRestore)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .help(restoreHelp)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                        .lineLimit(1)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                .controlSize(.small)
                .help(deleteHelp)
            }
        }
    }
}

private struct PresentationPreviewSheetView: View {
    @ObservedObject var controller: EditorController
    let dragOutPayloadProvider: @MainActor () -> PromisedFilePayload?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { proxy in
            let previewHeight = max(360, min(proxy.size.height * 0.68, 700))

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Presentation Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text("Final Export")
                            .font(.title2.weight(.semibold))

                        Text("Live preview of the current crop, annotations, and presentation styling.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: dismiss.callAsFunction) {
                        Label("Close", systemImage: "xmark")
                    }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .help("Close this preview.")
                }

                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))

                    LivePresentationThumbnailView(
                        controller: controller,
                        thumbnailSize: CGSize(width: max(proxy.size.width - 120, 420), height: previewHeight - 44),
                        cornerRadius: 22,
                        contentMode: .fit
                    )
                    .padding(22)
                    .overlay {
                        PromisedFileDragView(
                            accessibilityLabel: "Drag presentation preview to share",
                            payloadProvider: dragOutPayloadProvider,
                            showsIcon: false
                        )
                        .help("Drag this styled screenshot into Finder, Mail, or another app.")
                    }

                    Label("Drag preview to share. This preview updates with the current presentation settings.", systemImage: "wand.and.stars")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(18)
                }
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

                HStack(spacing: 12) {
                    Label(
                        controller.requiresPNGForFaithfulExport ? "Transparent presentation keeps shadow fidelity only in PNG." : "Copy, Share, and Export use this presentation result.",
                        systemImage: controller.requiresPNGForFaithfulExport ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(controller.requiresPNGForFaithfulExport ? .orange : .secondary)

                    Spacer()

                    Button(action: dismiss.callAsFunction) {
                        Label("Back to Editing", systemImage: "chevron.backward")
                    }
                    .buttonStyle(HistoryPreviewSecondaryButtonStyle())
                    .help("Close this preview and return to editing.")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private func historyEntriesEqual(_ lhs: [DocumentHistoryEntry], _ rhs: [DocumentHistoryEntry]) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }

    return zip(lhs, rhs).allSatisfy { left, right in
        left.id == right.id
            && left.sessionID == right.sessionID
            && left.title == right.title
            && left.label == right.label
            && left.savedAt == right.savedAt
            && left.packageURL == right.packageURL
            && left.previewAssetURL == right.previewAssetURL
            && left.sourceDocumentURL == right.sourceDocumentURL
            && left.hasUnsavedChanges == right.hasUnsavedChanges
            && left.searchableText == right.searchableText
    }
}

struct HistoryPreviewOverlayView: View {
    let entry: DocumentHistoryEntry
    let onClose: () -> Void
    let onFloat: () -> Void
    let onRestore: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(proxy.size.width - 40, 1040)
            let previewHeight = max(360, min(proxy.size.height * 0.68, 700))

            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onClose()
                    }

                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("History Preview")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Text(entry.label)
                                    .font(.title2.weight(.semibold))

                                if entry.hasUnsavedChanges {
                                    Text("Unsaved changes")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.orange.opacity(0.12), in: Capsule())
                                }
                            }

                            Text(entry.savedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(action: onClose) {
                            Label("Close", systemImage: "xmark")
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .keyboardShortcut(.cancelAction)
                        .help("Close this preview.")
                    }

                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))

                        DocumentPreviewThumbnailView(
                            packageURL: entry.packageURL,
                            thumbnailSize: CGSize(width: 1180, height: 820),
                            cornerRadius: 22,
                            contentMode: .fit
                        )
                        .padding(22)

                        Label("Click outside the preview to dismiss", systemImage: "cursorarrow.click")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .padding(18)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                    HStack(spacing: 12) {
                        Label(
                            entry.hasUnsavedChanges ? "This snapshot includes edits that were not saved to disk." : "This snapshot reflects a saved state.",
                            systemImage: entry.hasUnsavedChanges ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(entry.hasUnsavedChanges ? .orange : .secondary)

                        Spacer()

                        Button(action: onClose) {
                            Label("Back to Editing", systemImage: "chevron.backward")
                        }
                        .buttonStyle(HistoryPreviewSecondaryButtonStyle())
                        .help("Close this preview and return to editing.")

                        Button(action: onFloat) {
                            Label("Float Reference", systemImage: "pin")
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                        .help("Open this snapshot in an always-on-top floating reference window.")

                        Button(action: onRestore) {
                            Label("Restore Snapshot", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                        .buttonStyle(SSSChromeButtonStyle())
                        .help("Restore the document to this history snapshot.")
                    }
                }
                .padding(28)
                .frame(maxWidth: panelWidth)
                .sssGlassSurface(cornerRadius: 30)
                .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .onTapGesture {
                }
                .padding(20)
            }
        }
    }
}
