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
    @State private var isImportingImages = false
    @State private var isImportingLogo = false

    var body: some View {
        HSplitView {
            stepList.frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            canvas.frame(minWidth: 500)
            inspector.frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
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
                        Text("\(step.sequence)").font(.headline).frame(width: 24)
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
                            Text(step.caption).lineLimit(2).foregroundStyle(step.isDeleted ? .tertiary : .primary)
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
                                Button(entry.title) { onAddRecentSnip(entry) }
                            }
                        }
                    }
                }
                Button("Delete", action: controller.deleteSelected).disabled(controller.selection.isEmpty)
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
               let rendered = GuideRenderer.renderStepCard(step: step, image: image, theme: controller.project.theme, advancedEdit: controller.advancedEdits[step.id], logo: controller.logoImage) {
                GeometryReader { proxy in
                    ZStack {
                        Image(decorative: rendered, scale: 1).resizable().scaledToFit().padding(30)
                        if let marker = step.session.marker, !marker.isHidden {
                            GuideMarkerHandles(
                                number: step.sequence,
                                showsNumber: controller.project.theme.showsNumberedMarkers,
                                viewportSize: proxy.size,
                                cardPixelSize: CGSize(width: CGFloat(rendered.width), height: CGFloat(rendered.height)),
                                sourceImageSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)),
                                sourceCoordinateSize: step.session.sourcePixelSize,
                                marker: marker,
                                onMoveTarget: { controller.updateMarker(stepID: step.id, target: $0) },
                                onMoveTail: { controller.updateMarker(stepID: step.id, tail: $0) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Guide title", text: projectStringBinding(\.title))
                        HStack {
                            Menu("Apply Theme") {
                                Button("Standard") { controller.update(name: "Apply Theme") { $0.theme = GuideTheme() } }
                                ForEach(savedThemes) { theme in
                                    Button(theme.name) { controller.update(name: "Apply Theme") { $0.theme = theme } }
                                }
                            }
                            Button("Save Theme") { onSaveTheme(controller.project.theme) }
                        }
                        Picker("Appearance", selection: appearanceBinding) {
                            ForEach(GuideAppearance.allCases) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        ColorPicker("Accent", selection: themeColorBinding(\.accentColorHex))
                        ColorPicker("Background", selection: themeColorBinding(\.backgroundColorHex))
                        TextField("Organization", text: themeStringBinding(\.organizationName))
                        TextField("Footer", text: themeStringBinding(\.footer))
                        HStack {
                            Button(controller.logoImage == nil ? "Choose Logo…" : "Replace Logo…") { isImportingLogo = true }
                            if controller.logoImage != nil { Button("Remove", role: .destructive) { controller.setLogo(nil) } }
                        }
                        Divider()
                        Toggle("Show numbered step markers", isOn: themeBoolBinding(\.showsNumberedMarkers))
                            .help("Show or hide the numbered marker on every still step in this Guide.")
                        Toggle("Show click target highlights", isOn: themeBoolBinding(\.showsClickHighlight))
                            .help("Show a target ring on still steps and a brief pulse at clicks in video exports.")
                        Toggle("Add screenshot shadows", isOn: themeBoolBinding(\.showsScreenshotShadow))
                            .help("Add a soft shadow around screenshots throughout this Guide.")
                        DisclosureGroup("Fine-tune marker and card style") {
                            VStack(alignment: .leading, spacing: 10) {
                                ColorPicker("Marker", selection: themeColorBinding(\.markerColorHex))
                                HStack {
                                    Text("Width")
                                    Slider(value: themeDoubleBinding(\.markerLineWidth), in: 1...10, step: 0.5)
                                    Text("\(controller.project.theme.markerLineWidth, specifier: "%.1f") pt")
                                }
                                Picker("Arrowhead", selection: themeStringBinding(\.markerHeadStyle)) {
                                    Text("Triangle").tag("triangle")
                                    Text("Open").tag("open")
                                    Text("Circle").tag("circle")
                                }
                                if controller.project.theme.showsNumberedMarkers {
                                    Picker("Number style", selection: themeStringBinding(\.markerNumberStyle)) {
                                        Text("Circle").tag("circle")
                                        Text("Square").tag("square")
                                        Text("Number Only").tag("plain")
                                    }
                                }
                                HStack {
                                    Text("Corner radius")
                                    Slider(value: themeDoubleBinding(\.screenshotCornerRadius), in: 0...32, step: 1)
                                    Text("\(Int(controller.project.theme.screenshotCornerRadius))")
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guide Settings").font(.headline)
                        Text("Applies to every step in this Guide")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let step = controller.selectedStep {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Action", selection: eventBinding(step.id)) {
                                ForEach(GuideEventKind.allCases) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            Text("Caption").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: captionBinding(step.id)).frame(minHeight: 80).overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            Text("Note").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: noteBinding(step.id)).frame(minHeight: 70).overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                            HStack { Text("Duration"); Slider(value: durationBinding(step.id), in: 0.5...5, step: 0.5); Text("\(step.duration, specifier: "%.1f")s") }
                            if let marker = step.session.marker {
                                Text("Marker").font(.headline)
                                HStack {
                                    Text("Length")
                                    Slider(value: markerLengthBinding(step.id), in: 30...240, step: 5)
                                    Text("\(Int(marker.length ?? controller.project.theme.markerLength)) pt")
                                }
                                Toggle("Show marker", isOn: markerVisibleBinding(step.id))
                                Text(controller.project.theme.showsNumberedMarkers
                                     ? "Drag the white target and numbered handle directly in the preview."
                                     : "Drag the white target directly in the preview.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if controller.selection.count > 1 {
                                Button("Apply Duration to \(controller.selection.count) Steps") {
                                    controller.setDurationForSelection(step.duration)
                                }
                            }
                            Toggle("Include in exports", isOn: includeBinding(step.id))
                            Divider()
                            Text("Privacy").font(.headline)
                            HStack {
                                Button("Blur Center") { addRedaction(.blur, stepID: step.id) }
                                Button("Pixelate") { addRedaction(.pixelate, stepID: step.id) }
                                Button("Solid") { addRedaction(.solid, stepID: step.id) }
                            }
                            Text("Advanced Edit preserves the base image and commits the screenshot edit as one Guide command.").font(.caption).foregroundStyle(.secondary)
                            Button("Advanced Edit…") { controller.beginAdvancedEdit(capabilities: capabilities) }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        Text("Selected Step \(step.sequence)").font(.headline)
                    }
                }
            }.padding(16)
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

    private func projectStringBinding(_ keyPath: WritableKeyPath<GuideProject, String>) -> Binding<String> {
        Binding(get: { controller.project[keyPath: keyPath] }, set: { value in controller.update(name: "Edit Guide", coalescingKey: "project-string-\(keyPath.hashValue)") { $0[keyPath: keyPath] = value } })
    }
    private var appearanceBinding: Binding<GuideAppearance> { Binding(get: { controller.project.theme.appearance }, set: { value in controller.update(name: "Change Appearance") { $0.theme.appearance = value } }) }
    private func themeStringBinding(_ keyPath: WritableKeyPath<GuideTheme, String>) -> Binding<String> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style", coalescingKey: "theme-string-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeDoubleBinding(_ keyPath: WritableKeyPath<GuideTheme, Double>) -> Binding<Double> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style", coalescingKey: "theme-double-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeBoolBinding(_ keyPath: WritableKeyPath<GuideTheme, Bool>) -> Binding<Bool> { Binding(get: { controller.project.theme[keyPath: keyPath] }, set: { value in controller.update(name: "Change Guide Style") { $0.theme[keyPath: keyPath] = value } }) }
    private func themeColorBinding(_ keyPath: WritableKeyPath<GuideTheme, String>) -> Binding<Color> { Binding(get: { Color(guideHex: controller.project.theme[keyPath: keyPath]) }, set: { value in controller.update(name: "Change Guide Color", coalescingKey: "theme-color-\(keyPath.hashValue)") { $0.theme[keyPath: keyPath] = value.guideHex } }) }
    private func captionBinding(_ id: UUID) -> Binding<String> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.caption ?? "" }, set: { controller.updateCaption(stepID: id, caption: $0) }) }
    private func noteBinding(_ id: UUID) -> Binding<String> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.note ?? "" }, set: { value in controller.update(name: "Edit Note", coalescingKey: "note-\(id.uuidString)") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].note = value } } }) }
    private func eventBinding(_ id: UUID) -> Binding<GuideEventKind> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.eventKind ?? .manual }, set: { value in controller.update(name: "Change Action") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].eventKind = value } } }) }
    private func durationBinding(_ id: UUID) -> Binding<Double> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.duration ?? 2 }, set: { value in controller.update(name: "Change Duration", coalescingKey: "duration-\(id.uuidString)") { if let i = $0.steps.firstIndex(where: { $0.id == id }) { $0.steps[i].duration = value } } }) }
    private func includeBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.isIncluded ?? true }, set: { controller.setIncluded($0, stepID: id) }) }
    private func markerLengthBinding(_ id: UUID) -> Binding<Double> { Binding(get: { controller.project.steps.first(where: { $0.id == id })?.session.marker?.length ?? controller.project.theme.markerLength }, set: { controller.updateMarkerLength(stepID: id, length: $0) }) }
    private func markerVisibleBinding(_ id: UUID) -> Binding<Bool> { Binding(get: { !(controller.project.steps.first(where: { $0.id == id })?.session.marker?.isHidden ?? false) }, set: { visible in controller.update(name: "Toggle Marker") { project in if let i = project.steps.firstIndex(where: { $0.id == id }), var marker = project.steps[i].session.marker { marker.isHidden = !visible; project.steps[i].session.marker = marker } } }) }
    private func addRedaction(_ kind: GuideRedactionKind, stepID: UUID) { controller.update(name: "Add Redaction") { project in guard let i = project.steps.firstIndex(where: { $0.id == stepID }) else { return }; let size = project.steps[i].session.sourcePixelSize; project.steps[i].session.redactions.append(GuideRedaction(kind: kind, rect: CGRect(x: size.width * 0.35, y: size.height * 0.4, width: size.width * 0.3, height: size.height * 0.2))) } }
    private func icon(_ kind: GuideEventKind) -> String { switch kind { case .click: "cursorarrow.click"; case .doubleClick: "cursorarrow.motionlines.click"; case .selection: "selection.pin.in.out"; case .textEntry: "text.cursor"; case .scroll: "scroll"; case .gesture: "hand.draw"; case .shortcut: "command"; case .manual: "plus.square" } }
}

private struct GuideMarkerHandles: View {
    let number: Int
    let showsNumber: Bool
    let viewportSize: CGSize
    let cardPixelSize: CGSize
    let sourceImageSize: CGSize
    let sourceCoordinateSize: CGSize
    let marker: GuideMarker
    let onMoveTarget: (CGPoint) -> Void
    let onMoveTail: (CGPoint) -> Void

    var body: some View {
        let target = viewPoint(for: marker.target)
        let tail = viewPoint(for: marker.tail)
        ZStack {
            handle(
                at: target,
                color: .white,
                foreground: .black,
                accessibilityLabel: "Marker target",
                help: "Drag to point the marker at the action."
            ) {
                Image(systemName: "scope")
            } onMove: {
                onMoveTarget($0)
            }

            if showsNumber {
                handle(
                    at: tail,
                    color: .accentColor,
                    foreground: .white,
                    accessibilityLabel: "Step \(number) number handle",
                    help: "Drag to move the Step \(number) number."
                ) {
                    Text("\(number)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } onMove: {
                    onMoveTail($0)
                }
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .coordinateSpace(name: "guideMarkerCanvas")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Marker handles")
    }

    private func handle<Content: View>(
        at point: CGPoint,
        color: Color,
        foreground: Color,
        accessibilityLabel: String,
        help: String,
        @ViewBuilder content: () -> Content,
        onMove: @escaping (CGPoint) -> Void
    ) -> some View {
        content()
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 28, height: 28)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.black.opacity(0.45), lineWidth: 1))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("guideMarkerCanvas"))
                    .onEnded { value in onMove(sourcePoint(for: value.location)) }
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
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbarView(
                controller: editor,
                onBack: onCancel,
                onFloatReference: {},
                onExportPNG: {},
                onExportJPEG: {},
                onExportPDF: {},
                onCopyStyled: {},
                onCopyPlain: {},
                onShare: {},
                dragOutPayloadProvider: { nil },
                mode: .guideStep(onApply: onCommit)
            )
            .padding(12)
            Divider()
            EditorView(
                controller: editor,
                historyEntries: [],
                recentSnipEntries: [],
                captureHistoryEntries: [],
                recycleBinEntries: [],
                captureSearchQuery: $search,
                captureHistorySearchResultsLabel: "",
                historyActions: EditorHistoryActions(
                    onRestoreHistoryEntry: { _ in }, onRestoreRecentSnipEntry: { _ in },
                    onFloatHistoryEntry: { _ in }, onDeleteHistoryEntry: { _ in },
                    onDeleteAllHistoryEntries: {}, onDeleteRecentSnipEntry: { _ in },
                    onDeleteAllRecentSnipEntries: {}, onRestoreRecycledHistoryEntry: { _ in },
                    onPermanentlyDeleteRecycledHistoryEntry: { _ in }, onEmptyRecycleBin: {}
                )
            )
        }
        .frame(minWidth: 1000, minHeight: 700)
    }
}

struct GuideEditorToolbarView: View {
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

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
            Divider().frame(height: 22)
            Text(controller.project.title.isEmpty ? "Untitled Guide" : controller.project.title).font(.headline).lineLimit(1)
            Spacer()
            Button(action: controller.undo) { Image(systemName: "arrow.uturn.backward") }.disabled(!controller.canUndo)
            Button(action: controller.redo) { Image(systemName: "arrow.uturn.forward") }.disabled(!controller.canRedo)
            if exportIsActive {
                if let exportProgress {
                    ProgressView(value: exportProgress).frame(width: 100)
                } else {
                    ProgressView().controlSize(.small).frame(width: 28)
                }
                Button("Progress…", action: onShowExportProgress)
                Button("Cancel", action: onCancelExport)
            } else {
                Button("Export…") { isShowingExportOptions = true }
                    .buttonStyle(.borderedProminent)
            }
            if hasExportedFiles {
                Menu {
                    Button("Share…", action: onShareExports)
                    Button("Copy Files", action: onCopyExports)
                    Button("Reveal in Finder", action: onRevealExports)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            PromisedFileDragView(
                accessibilityLabel: "Drag Guide export",
                payloadProvider: dragOutPayloadProvider
            )
            // PromisedFileDragNSView draws an icon plus the “Drag” label. Keep the
            // same intrinsic width as the screenshot and video editor toolbars so
            // the label does not paint into the adjacent Export control.
            .frame(width: 68, height: 30)
            .help("Drag the first selected Guide export format into Finder or another app.")
            if let exportStatus { Text(exportStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
