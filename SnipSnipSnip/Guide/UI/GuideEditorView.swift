import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct GuideEditorView: View {
    @ObservedObject var controller: GuideEditorController
    let capabilities: AppCapabilitySnapshot
    let recentSnips: [DocumentHistoryEntry]
    let onAddRecentSnip: (DocumentHistoryEntry) -> Void
    let savedThemes: [GuideTheme]
    let onSaveTheme: (GuideTheme) -> Void
    let onSetDefaultBranding: (GuideTheme, CGImage?) -> Void
    @State private var isImportingImages = false
    @State private var isImportingLogo = false
    @State private var inspectorScope: GuideInspectorScope = .step
    @SceneStorage("guide.inspector.isPresented") private var isInspectorPresented = true

    var body: some View {
        NavigationSplitView {
            stepList
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            canvas
                .frame(minWidth: 500)
        }
        .inspector(isPresented: $isInspectorPresented) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .toolbar {
            ToolbarItem(id: "guide-inspector", placement: .primaryAction) {
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(isInspectorPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .help(isInspectorPresented ? "Hide Guide Inspector" : "Show Guide Inspector")
                .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
            }
        }
    }

    private var visibleSteps: [GuideStep] {
        let query = controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return controller.project.steps }
        return controller.project.steps.filter { $0.caption.localizedCaseInsensitiveContains(query) || $0.note.localizedCaseInsensitiveContains(query) }
    }

    private var stepList: some View {
        VStack(spacing: 8) {
            TextField("Search steps", text: $controller.searchQuery).textFieldStyle(.roundedBorder).padding([.top, .horizontal], 10)
            List(selection: $controller.selection) {
                ForEach(visibleSteps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Text(controller.displayNumber(for: step.id).map(String.init) ?? "–")
                            .font(.headline)
                            .foregroundStyle(step.isDeleted ? .tertiary : .primary)
                            .frame(width: 24)
                        if let image = controller.stepThumbnails[step.id] {
                            Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: 86, height: 54).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                                .frame(width: 86, height: 54)
                                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Label(step.eventKind.rawValue.capitalized, systemImage: icon(step.eventKind)).font(.caption)
                            Text(step.caption)
                                .lineLimit(2)
                                .foregroundStyle(step.isDeleted ? .tertiary : .primary)
                                .strikethrough(step.isDeleted)
                            if step.isDeleted {
                                Label("Deleted", systemImage: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .tag(step.id)
                    .task(id: step.id) {
                        controller.requestThumbnail(for: step.id, priority: .userInitiated)
                        controller.prefetchThumbnails(after: step.id)
                    }
                    .contextMenu {
                        Button(step.isIncluded ? "Exclude" : "Include") { controller.setIncluded(!step.isIncluded, stepID: step.id) }
                        if step.isDeleted { Button("Restore") { controller.restore(stepID: step.id) } }
                    }
                }
                .onMove(perform: controller.reorder)
            }
            HStack {
                Menu("Add") {
                    Button("Import Images…") { isImportingImages = true }
                    if !recentSnips.isEmpty {
                        Menu("Recent Snips") {
                            ForEach(recentSnips.prefix(10)) { entry in
                                Button(entry.libraryMenuTitle) {
                                    onAddRecentSnip(entry)
                                }
                            }
                        }
                    }
                }
                Button("Delete", role: .destructive, action: controller.deleteSelected)
                    .disabled(controller.selection.isEmpty)
                    .help("Delete the selected steps. Deleted steps remain available to restore from their context menu.")
                Button("Duplicate", action: controller.duplicateSelected).disabled(controller.selection.isEmpty)
                Button { controller.moveSelection(by: -1) } label: { Image(systemName: "arrow.up") }.disabled(controller.selection.isEmpty)
                Button { controller.moveSelection(by: 1) } label: { Image(systemName: "arrow.down") }.disabled(controller.selection.isEmpty)
                Spacer()
                Text("\(controller.includedSteps.count) included").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
        }
        .fileImporter(isPresented: $isImportingImages, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    controller.addImportedImage(image, caption: "Review \(url.deletingPathExtension().lastPathComponent).")
                }
            }
        }
    }

    private var canvas: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let step = controller.selectedStep, let image = controller.stepImages[step.id],
               let rendered = GuideRenderer.renderStepCard(
                   step: step,
                   image: image,
                   theme: controller.project.theme,
                   advancedEdit: controller.advancedEdits[step.id],
                   logo: controller.logoImage,
                   displayNumber: controller.displayNumber(for: step.id) ?? step.sequence
               ) {
                GeometryReader { proxy in
                    ZStack {
                        Image(decorative: rendered, scale: 1).resizable().scaledToFit().padding(30)
                        if let marker = step.session.marker, !marker.isHidden {
                            GuideMarkerHandles(
                                number: controller.displayNumber(for: step.id) ?? step.sequence,
                                showsNumber: step.showsStepNumber(using: controller.project.theme),
                                showsTarget: step.showsActionTarget(using: controller.project.theme),
                                viewportSize: proxy.size,
                                cardPixelSize: CGSize(width: CGFloat(rendered.width), height: CGFloat(rendered.height)),
                                sourceImageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                                sourceCoordinateSize: step.session.sourcePixelSize,
                                marker: marker,
                                onBeginMove: { controller.beginMarkerDrag(stepID: step.id) },
                                onMoveTarget: { controller.updateMarkerDuringDrag(stepID: step.id, target: $0) },
                                onEndMoveTarget: { controller.endMarkerDrag(stepID: step.id, target: $0) },
                                onMoveTail: { controller.updateMarkerDuringDrag(stepID: step.id, tail: $0) },
                                onEndMoveTail: { controller.endMarkerDrag(stepID: step.id, tail: $0) },
                                onFinishMove: { controller.finishMarkerDrag(stepID: step.id) }
                            )
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select a Step", systemImage: "list.number", description: Text("Choose a step to preview and edit it."))
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorScope) {
                Text("Step")
                    .tag(GuideInspectorScope.step)
                    .disabled(controller.selectedStep == nil)
                Text("Guide").tag(GuideInspectorScope.guide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Inspector scope")
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            switch inspectorScope {
            case .step:
                stepInspector
            case .guide:
                guideInspector
            }
        }
        .onAppear {
            if controller.selectedStep == nil {
                inspectorScope = .guide
            }
        }
        .onChange(of: controller.selection) { _, selection in
            inspectorScope = selection.isEmpty ? .guide : .step
        }
        .sheet(isPresented: Binding(
            get: { controller.advancedEditorController != nil },
            set: { if !$0 { controller.cancelAdvancedEdit() } }
        )) {
            if let editor = controller.advancedEditorController {
                GuideAdvancedEditorSheet(
                    editor: editor,
                    onCancel: controller.cancelAdvancedEdit,
                    onCommit: controller.commitAdvancedEdit
                )
            }
        }
        .fileImporter(isPresented: $isImportingLogo, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            controller.setLogo(image)
        }
    }

    @ViewBuilder private var stepInspector: some View {
        if let step = controller.selectedStep {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InsetGroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Instruction")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: captionBinding(step.id))
                                .frame(minHeight: 88)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

                            Picker("Action", selection: eventBinding(step.id)) {
                                ForEach(GuideEventKind.allCases) {
                                    Text($0.rawValue.capitalized).tag($0)
                                }
                            }

                            HStack {
                                Text("Duration")
                                Slider(value: durationBinding(step.id), in: 0.5...5, step: 0.5)
                                Text("\(step.duration, specifier: "%.1f")s")
                                    .monospacedDigit()
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                            .help("How long this step appears in step-based animated and video exports.")

                            if controller.selection.count > 1 {
                                Button("Apply Duration to \(controller.selection.count) Steps") {
                                    controller.setDurationForSelection(step.duration)
                                }
                            }

                            Toggle("Include in exports", isOn: includeBinding(step.id))
                            Toggle("Show step number", isOn: stepNumberVisibleBinding(step.id))
                                .help("Show or hide the number on this step's card and marker.")
                        }
                        .padding(.vertical, 4)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let displayNumber = controller.displayNumber(for: step.id) {
                                Text("Step \(displayNumber)")
                            } else {
                                Text("Deleted Step")
                            }
                            Text("Edit what this step says and how it plays")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let marker = step.session.marker {
                        InsetGroupBox("Marker") {
                            Toggle("Show marker", isOn: markerVisibleBinding(step.id))
                            Toggle("Show action crosshairs", isOn: actionTargetVisibleBinding(step.id))
                                .help("Show or hide the crosshairs marking where the action happened on this step.")
                            if !marker.isHidden {
                                HStack {
                                    Text("Length")
                                    Slider(value: markerLengthBinding(step.id), in: 30...240, step: 5)
                                    Text("\(Int(marker.length ?? controller.project.theme.markerLength)) pt")
                                        .monospacedDigit()
                                        .frame(minWidth: 42, alignment: .trailing)
                                }
                                Text(step.showsStepNumber(using: controller.project.theme)
                                     ? "Drag the target handle to move the action, or the number handle to reposition the step number."
                                     : "Drag the target handle to move where this step points.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    InsetGroupBox("Screenshot") {
                        Button("Edit Screenshot…") {
                            controller.beginAdvancedEdit(capabilities: capabilities)
                        }
                        .help("Open the full screenshot editor for this step.")
                    }

                    GuideInspectorDisclosureSection(
                        title: "Internal Note",
                        subtitle: "Optional context included with this step"
                    ) {
                        TextEditor(text: noteBinding(step.id))
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No Step Selected",
                systemImage: "list.number",
                description: Text("Select a step, or choose Guide to edit shared styling.")
            )
        }
    }

    private var guideInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InsetGroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Untitled Guide", text: projectStringBinding(\.title))
                    }
                    .padding(.vertical, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guide")
                        Text("Applies to every step")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                InsetGroupBox("Appearance") {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Menu(controller.project.theme.name) {
                            Button("Standard") {
                                controller.update(name: "Apply Theme") { $0.theme = GuideTheme() }
                            }
                            ForEach(savedThemes) { theme in
                                Button(theme.name) {
                                    controller.update(name: "Apply Theme") { $0.theme = theme }
                                }
                            }
                            Divider()
                            Button("Save Current Theme…") {
                                onSaveTheme(controller.project.theme)
                            }
                            Button("Make Default for New Guides…") {
                                onSetDefaultBranding(controller.project.theme, controller.logoImage)
                            }
                        }
                        .help("Save this theme or make its branding and styling the default for new Guides.")
                    }

                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(GuideAppearance.allCases) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    ColorPicker("Accent", selection: themeColorBinding(\.accentColorHex))
                    ColorPicker("Background", selection: themeColorBinding(\.backgroundColorHex))

                    Divider()

                    Toggle("Show click pulses in video", isOn: themeBoolBinding(\.showsClickHighlight))
                        .help("Show a brief pulse at clicks in video exports. Crosshairs on still steps are controlled per step.")
                    Toggle("Add screenshot shadows", isOn: themeBoolBinding(\.showsScreenshotShadow))
                        .help("Add a soft shadow around screenshots throughout this Guide.")
                }

                GuideInspectorDisclosureSection(
                    title: "Branding",
                    subtitle: "Organization, logo, footer, and legal text"
                ) {
                    TextField("Organization", text: themeStringBinding(\.organizationName))
                    TextField("Copyright / footer", text: themeStringBinding(\.footer))
                    Text("Legal statement")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: themeOptionalStringBinding(\.legalStatement))
                        .frame(minHeight: 64)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    HStack {
                        Button(controller.logoImage == nil ? "Choose Logo…" : "Replace Logo…") {
                            isImportingLogo = true
                        }
                        if controller.logoImage != nil {
                            Button("Remove", role: .destructive) {
                                controller.setLogo(nil)
                            }
                        }
                    }
                }

                GuideInspectorDisclosureSection(
                    title: "Advanced Style",
                    subtitle: "Marker and screenshot details"
                ) {
                    ColorPicker("Marker", selection: themeColorBinding(\.markerColorHex))
                    HStack {
                        Text("Line width")
                        Slider(value: themeDoubleBinding(\.markerLineWidth), in: 1...10, step: 0.5)
                        Text("\(controller.project.theme.markerLineWidth, specifier: "%.1f") pt")
                            .monospacedDigit()
                    }
                    Picker("Arrowhead", selection: themeStringBinding(\.markerHeadStyle)) {
                        Text("Triangle").tag("triangle")
                        Text("Open").tag("open")
                        Text("Circle").tag("circle")
                    }
                    Picker("Number style", selection: markerNumberStyleBinding) {
                        Text("Circle").tag("circle")
                        Text("Square").tag("square")
                        Text("Number Only").tag("plain")
                    }
                    HStack {
                        Text("Corner radius")
                        Slider(value: themeDoubleBinding(\.screenshotCornerRadius), in: 0...32, step: 1)
                        Text("\(Int(controller.project.theme.screenshotCornerRadius))")
                            .monospacedDigit()
                    }
                }
            }
            .padding(16)
        }
    }

    private func projectStringBinding(_ keyPath: WritableKeyPath<GuideProject, String>) -> Binding<String> {
        Binding(get: { controller.project[keyPath: keyPath] }, set: { value in controller.update(name: "Edit Guide", coalescingKey: "project-string-\(keyPath.hashValue)") { $0[keyPath: keyPath] = value } })
    }
    private var appearanceBinding: Binding<GuideAppearance> { Binding(get: { controller.project.theme.appearance }, set: { value in controller.update(name: "Change Appearance") { $0.theme.appearance = value } }) }
    private func themeStringBinding(_ keyPath: WritableKeyPath<GuideTheme, String>) -> Binding<String> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style", coalescingKey: "theme-string-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeOptionalStringBinding(_ keyPath: WritableKeyPath<GuideTheme, String?>) -> Binding<String> { Binding(get: { controller.project.theme[keyPath: keyPath] ?? "" }, set: { value in controller.update(name: "Change Guide Branding", coalescingKey: "theme-optional-string-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value.isEmpty ? nil : value } }) }
    private func themeDoubleBinding(_ keyPath: WritableKeyPath<GuideTheme, Double>) -> Binding<Double> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style", coalescingKey: "theme-double-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeBoolBinding(_ keyPath: WritableKeyPath<GuideTheme, Bool>) -> Binding<Bool> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeColorBinding(_ keyPath: WritableKeyPath<GuideTheme, String>) -> Binding<Color> { Binding(get: { Color(guideHex: controller.project.theme[keyPath: keyPath]) }, set: { value in controller.update(name: "Change Guide Color", coalescingKey: "theme-color-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value.guideHex } }) }
    private func captionBinding(_ id: UUID) -> Binding<String> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.caption ?? "" }, set: { controller.updateCaption(stepID: id, caption: $0) }) }
    private func noteBinding(_ id: UUID) -> Binding<String> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.note ?? "" }, set: { value in controller.update(name: "Edit Note", coalescingKey: "note-\(id.uuidString)") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].note = value } } }) }
    private func eventBinding(_ id: UUID) -> Binding<GuideEventKind> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.eventKind ?? .manual }, set: { value in controller.update(name: "Change Action") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].eventKind = value } } }) }
    private func durationBinding(_ id: UUID) -> Binding<Double> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.duration ?? 2 }, set: { value in controller.update(name: "Change Duration", coalescingKey: "duration-\(id.uuidString)") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].duration = value } } }) }
    private func includeBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.isIncluded ?? true }, set: { controller.setIncluded($0, stepID: id) }) }
    private func stepNumberVisibleBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard let step = controller.project.steps.first(where: { $0.id == id }) else { return true }
                return step.showsStepNumber(using: controller.project.theme)
            },
            set: { visible in
                controller.update(name: "Toggle Step Number") { project in
                    guard let index = project.steps.firstIndex(where: { $0.id == id }) else { return }
                    project.steps[index].session.showsStepNumber = visible
                }
            }
        )
    }
    private func actionTargetVisibleBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard let step = controller.project.steps.first(where: { $0.id == id }) else { return true }
                return step.showsActionTarget(using: controller.project.theme)
            },
            set: { visible in
                controller.update(name: "Toggle Action Crosshairs") { project in
                    guard let index = project.steps.firstIndex(where: { $0.id == id }) else { return }
                    project.steps[index].session.showsActionTarget = visible
                }
            }
        )
    }
    private func markerLengthBinding(_ id: UUID) -> Binding<Double> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.session.marker?.length ?? controller.project.theme.markerLength }, set: { controller.updateMarkerLength(stepID: id, length: $0) }) }
    private func markerVisibleBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { !(controller.project.steps.first(where: { $0.id == id })?.session.marker?.isHidden ?? false) }, set: { visible in controller.update(name: "Toggle Marker") { project in if let i = project.steps.firstIndex(where: { $0.id == id }), var marker = project.steps[i].session.marker { marker.isHidden = !visible; project.steps[i].session.marker = marker } } }) }
    private var markerNumberStyleBinding: Binding<String> {
        Binding(
            get: {
                let style = controller.project.theme.markerNumberStyle
                return style == "none" ? "circle" : style
            },
            set: { value in
                controller.update(name: "Change Guide Style") {
                    $0.theme.markerNumberStyle = value
                }
            }
        )
    }
    private func icon(_ kind: GuideEventKind) -> String { switch kind { case .click: "cursorarrow.click"; case .doubleClick: "cursorarrow.motionlines.click"; case .selection: "selection.pin.in.out"; case .textEntry: "text.cursor"; case .scroll: "scroll"; case .gesture: "hand.draw"; case .shortcut: "command"; case .manual: "plus.square" } }
}

private enum GuideInspectorScope: String, CaseIterable, Identifiable {
    case step
    case guide

    var id: String { rawValue }
}

private struct GuideInspectorDisclosureSection<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GuideMarkerHandles: View {
    let number: Int
    let showsNumber: Bool
    let showsTarget: Bool
    let viewportSize: CGSize
    let cardPixelSize: CGSize
    let sourceImageSize: CGSize
    let sourceCoordinateSize: CGSize
    let marker: GuideMarker
    let onBeginMove: () -> Void
    let onMoveTarget: (CGPoint) -> Void
    let onEndMoveTarget: (CGPoint) -> Void
    let onMoveTail: (CGPoint) -> Void
    let onEndMoveTail: (CGPoint) -> Void
    let onFinishMove: () -> Void

    var body: some View {
        let target = viewPoint(for: marker.target)
        let tail = viewPoint(for: marker.tail)
        ZStack {
            handle(
                at: target,
                accessibilityLabel: "Marker target",
                help: "Drag to point the marker at the action."
            ) {
                if showsTarget {
                    ZStack {
                        Circle()
                            .stroke(.black.opacity(0.8), lineWidth: 4)
                        Circle()
                            .stroke(
                                .white,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3])
                            )
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.78))
                            .frame(width: 10, height: 10)
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
            } onMove: {
                onMoveTarget($0)
            } onEnd: {
                onEndMoveTarget($0)
            }

            if showsNumber {
                handle(
                    at: tail,
                    accessibilityLabel: "Step \(number) number handle",
                    help: "Drag to move the Step \(number) number."
                ) {
                    ZStack {
                        Circle()
                            .stroke(.black.opacity(0.72), lineWidth: 4)
                        Circle()
                            .stroke(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 3])
                            )
                    }
                } onMove: {
                    onMoveTail($0)
                } onEnd: {
                    onEndMoveTail($0)
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .coordinateSpace(name: "guideMarkerCanvas")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker handles")
        .onDisappear(perform: onFinishMove)
    }

    private func handle<Content: View>(
        at point: CGPoint,
        accessibilityLabel: String,
        help: String,
        @ViewBuilder content: () -> Content,
        onMove: @escaping (CGPoint) -> Void,
        onEnd: @escaping (CGPoint) -> Void
    ) -> some View {
        content()
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("guideMarkerCanvas"))
                    .onChanged { value in
                        onBeginMove()
                        onMove(sourcePoint(for: value.location))
                    }
                    .onEnded { value in
                        onEnd(sourcePoint(for: value.location))
                    }
            )
            .help(help)
            .accessibilityLabel(accessibilityLabel)
    }

    private var layout: (scale: CGFloat, origin: CGPoint) {
        let content = CGSize(width: max(viewportSize.width - 60, 1), height: max(viewportSize.height - 60, 1))
        let scale = min(content.width / cardPixelSize.width, content.height / cardPixelSize.height)
        return (
            scale,
            CGPoint(
                x: (viewportSize.width - cardPixelSize.width * scale) / 2,
                y: (viewportSize.height - cardPixelSize.height * scale) / 2
            )
        )
    }

    private func viewPoint(for source: CGPoint) -> CGPoint {
        let imageScale = min((cardPixelSize.width - 144) / max(sourceImageSize.width, 1), 1)
        let imageSize = CGSize(width: sourceImageSize.width * imageScale, height: sourceImageSize.height * imageScale)
        let normalized = CGPoint(
            x: sourceCoordinateSize.width > 0 ? source.x / sourceCoordinateSize.width : 0,
            y: sourceCoordinateSize.height > 0 ? source.y / sourceCoordinateSize.height : 0
        )
        let value = layout
        return CGPoint(
            x: value.origin.x + (72 + normalized.x * imageSize.width) * value.scale,
            y: value.origin.y + (72 + normalized.y * imageSize.height) * value.scale
        )
    }

    private func sourcePoint(for view: CGPoint) -> CGPoint {
        let imageScale = min((cardPixelSize.width - 144) / max(sourceImageSize.width, 1), 1)
        let imageSize = CGSize(width: sourceImageSize.width * imageScale, height: sourceImageSize.height * imageScale)
        let value = layout
        let cardPoint = CGPoint(x: (view.x - value.origin.x) / value.scale, y: (view.y - value.origin.y) / value.scale)
        return CGPoint(
            x: min(max((cardPoint.x - 72) / max(imageSize.width, 1), 0), 1) * sourceCoordinateSize.width,
            y: min(max((cardPoint.y - 72) / max(imageSize.height, 1), 0), 1) * sourceCoordinateSize.height
        )
    }
}

private extension Color {
    init(guideHex: String) {
        let value = guideHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let number = UInt64(value, radix: 16) ?? 0xE53935
        self.init(
            red: Double((number >> 16) & 255) / 255,
            green: Double((number >> 8) & 255) / 255,
            blue: Double(number & 255) / 255
        )
    }

    var guideHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#E53935" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

private struct GuideAdvancedEditorSheet: View {
    @ObservedObject var editor: EditorController
    let onCancel: () -> Void
    let onCommit: () -> Void
    @State private var isInspectorPresented = true

    var body: some View {
        VStack(spacing: 0) {
            EditorCommandBar(
                controller: editor,
                isInspectorPresented: $isInspectorPresented,
                onBack: onCancel,
                onFloatReference: { _ in },
                onExportPNG: { _ in },
                onExportJPEG: { _ in },
                onExportPDF: { _ in },
                onCopy: { _ in },
                onShare: { _ in },
                onShowLayers: {},
                onShowUIMap: {},
                dragOutPayloadProvider: { _ in nil },
                mode: .guideStep(onApply: onCommit)
            )
            Divider()

            EditorView(
                controller: editor,
                isInspectorPresented: $isInspectorPresented,
                historyEntries: [],
                recycleBinEntries: [],
                historyActions: EditorHistoryActions(
                    onPresentSnipLibrary: { _ in },
                    onPresentHistoryPreview: { _ in }, onCloseHistoryPreview: { _ in },
                    onRestoreHistoryEntry: { _ in }, onRestoreRecentSnipEntry: { _ in },
                    onFloatHistoryEntry: { _ in }, onDeleteHistoryEntry: { _ in },
                    onDeleteAllHistoryEntries: {}, onDeleteRecentSnipEntry: { _ in },
                    onDeleteAllRecentSnipEntries: {}, onRestoreRecycledHistoryEntry: { _ in },
                    onPermanentlyDeleteRecycledHistoryEntry: { _ in }, onEmptyRecycleBin: {}
                )
            )
        }
        .toolbar(removing: .title)
        .frame(minWidth: 1000, minHeight: 700)
    }
}

struct GuideEditorToolbarContent: ToolbarContent {
    @ObservedObject var controller: GuideEditorController
    let onBack: () -> Void
    let onExport: (Bool) -> Void
    var exportIsActive = false
    var exportProgress: Double? = nil
    var exportStatus: String? = nil
    var onCancelExport: () -> Void = {}
    var onShowExportProgress: () -> Void = {}
    var hasExportedFiles = false
    var onRevealExports: () -> Void = {}
    var onCopyExports: () -> Void = {}
    var onShareExports: () -> Void = {}
    var dragOutPayloadProvider: @MainActor () -> PromisedFilePayload? = { nil }
    @State private var isShowingExportOptions = false

    var body: some ToolbarContent {
        ToolbarItem(id: "guide-back", placement: .navigation) {
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }

        ToolbarItem(id: "guide-title", placement: .principal) {
            Text(controller.project.title.isEmpty ? "Untitled Guide" : controller.project.title)
                .font(.headline)
                .lineLimit(1)
        }

        ToolbarItem(id: "guide-undo", placement: .automatic) {
            Button(action: controller.undo) { Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Undo")
                .disabled(!controller.canUndo)
        }
        ToolbarItem(id: "guide-redo", placement: .automatic) {
            Button(action: controller.redo) { Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Redo")
                .disabled(!controller.canRedo)
        }

        if exportIsActive {
            ToolbarItem(id: "guide-export-progress", placement: .primaryAction) {
                Group {
                    if let exportProgress {
                    ProgressView(value: exportProgress).frame(width: 100)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 28)
                    }
                }
            }
            ToolbarItem(id: "guide-export-progress-window", placement: .primaryAction) {
                Button("Progress…", action: onShowExportProgress)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
            ToolbarItem(id: "guide-export-cancel", placement: .primaryAction) {
                Button("Cancel", action: onCancelExport)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        } else {
            ToolbarItem(id: "guide-export", placement: .primaryAction) {
                Button("Export…") { isShowingExportOptions = true }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .sheet(isPresented: $isShowingExportOptions) {
                        GuideExportOptionsSheet(
                            controller: controller,
                            onCancel: { isShowingExportOptions = false },
                            onExport: { showProgressWindow in
                                isShowingExportOptions = false
                                onExport(showProgressWindow)
                            }
                        )
                    }
            }
        }
        if hasExportedFiles {
            ToolbarItem(id: "guide-share", placement: .primaryAction) {
                Menu {
                    Button("Share…", action: onShareExports)
                    Button("Copy Files", action: onCopyExports)
                    Button("Reveal in Finder", action: onRevealExports)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
        }
        ToolbarItem(id: "guide-drag", placement: .primaryAction) {
            PromisedFileDragView(
                accessibilityLabel: "Drag Guide export",
                payloadProvider: dragOutPayloadProvider
            )
            // PromisedFileDragNSView draws an icon plus the “Drag” label. Keep the
            // same intrinsic width as the screenshot and video editor toolbars so
            // the label does not paint into the adjacent Export control.
            .frame(width: 68, height: 30)
            .help("Drag the first selected Guide export format into Finder or another app.")
        }
        if let exportStatus {
            ToolbarItem(id: "guide-export-status", placement: .primaryAction) {
                Text(exportStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct GuideExportOptionsSheet: View {
    @ObservedObject var controller: GuideEditorController
    let onCancel: () -> Void
    let onExport: (Bool) -> Void
    @State private var showsProgressWindow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Guide").font(.title2.bold())
                Text("Choose one or more formats, then choose where to save them.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                formatGroup("Documents", formats: [.pdf, .docx])
                formatGroup("Animated sharing", formats: [.gif, .apng])
                formatGroup("Video", formats: [.fullMotionMP4, .highlightMP4, .slideshowMP4])
                formatGroup("Files and packages", formats: [.stepImages, .zip])
            }

            if controller.mediaSegmentURLs.isEmpty {
                Label("Full Motion MP4 and Action Highlights require source video.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Full Motion MP4 and Action Highlights include captured microphone and system audio.", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Show export progress window", isOn: $showsProgressWindow)
                .help("Keep a small, cancellable export status window open while files are generated.")

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Choose Folder & Export") { onExport(showsProgressWindow) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.project.exportSettings.formats.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func requiresSourceVideo(_ format: GuideExportFormat) -> Bool {
        [.fullMotionMP4, .highlightMP4].contains(format)
    }

    @ViewBuilder
    private func formatGroup(_ title: String, formats: [GuideExportFormat]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(formats) { format in
                Toggle(format.label, isOn: formatBinding(format))
                    .disabled(requiresSourceVideo(format) && controller.mediaSegmentURLs.isEmpty)
            }
        }
    }

    private func formatBinding(_ format: GuideExportFormat) -> Binding<Bool> {
        Binding(
            get: { controller.project.exportSettings.formats.contains(format) },
            set: { enabled in
                controller.update(name: "Change Export Formats") { project in
                    if enabled { project.exportSettings.formats.insert(format) }
                    else { project.exportSettings.formats.remove(format) }
                }
            }
        )
    }
}
