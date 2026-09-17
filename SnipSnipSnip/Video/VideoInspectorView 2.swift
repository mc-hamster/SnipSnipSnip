import SwiftUI

enum VideoInspectorSection: String, CaseIterable, Identifiable {
    case trim = "Trim"
    case polish = "Polish"
    case zooms = "Zooms"
    case cursor = "Cursor & Clicks"
    case audio = "Sound & Shortcuts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .trim: "scissors"
        case .polish: "paintbrush"
        case .zooms: "plus.magnifyingglass"
        case .cursor: "cursorarrow"
        case .audio: "speaker.wave.2"
        }
    }
}

struct VideoInspectorView: View {
    @ObservedObject var controller: VideoEditorController
    var supportsShortcutCapture = true
    @State private var cutStart: Double = 0
    @State private var cutEnd: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch controller.inspectorSection {
                    case .trim: trim
                    case .polish: polish
                    case .zooms: zooms
                    case .cursor: cursor
                    case .audio: audio
                    }
                }
                .padding(16)
            }
            .accessibilityIdentifier("video.inspector.section")
            Divider()
            Text("Your original video is kept. Undo any change with ⌘Z.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .background(.background)
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
    }

    private var trim: some View {
        Group {
            InsetGroupBox("Keep This Part") {
                timeField("Start", value: Binding(get: { controller.session.trimStartSeconds }, set: { controller.updateTrimStart($0) }))
                timeField("End", value: Binding(get: { controller.session.trimEndSeconds }, set: { controller.updateTrimEnd($0) }))
                LabeledContent("Finished Length", value: controller.trimmedDurationLabel)
                Button("Use Start Frame as Thumbnail", action: controller.setPosterToTrimStart)
                    .help("Set the still image shown for the saved Video. This does not start playback.")
            }
            InsetGroupBox("Remove a Mistake") {
                HStack {
                    Button("Mark Start") { cutStart = controller.currentTimeSeconds; cutEnd = max(cutEnd, cutStart) }
                    Button("Mark End") { cutEnd = controller.currentTimeSeconds }
                }
                timeField("From", value: $cutStart)
                timeField("To", value: $cutEnd)
                Button("Remove Section") {
                    controller.perform(.cut(VideoTimeRange(start: cutStart, end: cutEnd)))
                }
                .disabled(cutEnd - cutStart < 0.1 || cutStart < controller.session.trimStartSeconds || cutEnd > controller.session.trimEndSeconds || cutEnd - cutStart >= controller.trimmedDuration - 0.1)
                Text("Move the playhead to each end of the mistake, then mark it. Removed sections stay available to restore.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !controller.session.removedRanges.isEmpty {
                InsetGroupBox("Removed Sections") {
                    ForEach(controller.session.removedRanges) { range in
                        HStack {
                            Text("\(range.start, specifier: "%.1f")–\(range.end, specifier: "%.1f") s")
                                .monospacedDigit()
                            Spacer()
                            Button("Restore") { controller.perform(.restoreCut(range.id)) }
                        }
                    }
                }
            }
        }
    }

    private var polish: some View {
        Group {
            InsetGroupBox("Polish") {
                Button(action: controller.polishVideo) {
                    Label("Polish Video", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("video.polish.automatic")
                Text(controller.recording.interactions == nil
                     ? "Add a clean background. You can add your own zooms next."
                     : "Add a clean background, a smooth cursor, and zooms that follow your clicks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            InsetGroupBox("Background") {
                Toggle("Add Background", isOn: Binding(get: { controller.session.effects.presentation.isEnabled }, set: { enabled in
                    var effects = controller.session.effects
                    if enabled && effects.presentation == .plain { effects.presentation = ScreenshotPresentationPreset.lifted.settings }
                    effects.presentation.isEnabled = enabled
                    controller.perform(.effects(effects, name: "Change Background"))
                }))
                if controller.session.effects.presentation.isEnabled {
                    Picker("Look", selection: Binding(get: { backgroundChoice }, set: { setBackground($0) })) {
                        Text("Light").tag(0)
                        Text("Dark").tag(1)
                        Text("Blue").tag(2)
                        Text("Warm").tag(3)
                    }
                    Picker("Shape", selection: Binding(get: { canvasChoice }, set: { setCanvas($0) })) {
                        Text("Match Video").tag("original")
                        ForEach(PresentationCanvasPreset.allCases) { preset in Text(preset.label).tag(preset.rawValue) }
                    }
                    adjustment("Space Around Video", value: scalarEffect(\.presentation.padding, name: "Change Spacing"), range: 0...160, format: "%.0f")
                    adjustment("Round Corners", value: scalarEffect(\.presentation.cornerRadius, name: "Change Corners"), range: 0...60, format: "%.0f")
                    Picker("Shadow", selection: effect(\.presentation.shadow, name: "Change Shadow")) {
                        Text("None").tag(ScreenshotShadowStyle.off)
                        Text("Soft").tag(ScreenshotShadowStyle.drop)
                        Text("Strong").tag(ScreenshotShadowStyle.strong)
                    }
                }
            }
            InsetGroupBox("Effects") {
                DisclosureGroup("Fine-Tune Motion") {
                    adjustment("Motion Blur", value: effect(\.motionBlur, name: "Change Motion Blur"), range: 0...1, format: "%.2f")
                    Text("A little blur softens zoom transitions. Leave it off for the sharpest text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            InsetGroupBox("Reset") {
                Button("Reset Video Edits") { controller.perform(.reset) }
                Text("Restore the full recording and its original appearance. You can undo this too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var zooms: some View {
        Group {
            InsetGroupBox("Zooms") {
                Button("Add Zoom at Playhead", action: controller.addZoom)
                    .accessibilityIdentifier("video.zoom.add")
                if let interactions = controller.recording.interactions, !interactions.clicks.isEmpty {
                    Button("Suggest Zooms from Clicks") {
                        var effects = controller.session.effects
                        effects.zooms = VideoSmartZooms.suggest(track: interactions, duration: controller.recording.duration)
                        controller.perform(.effects(effects, name: "Suggest Zooms"))
                    }
                }
                Text("Select a zoom to see its target on the full frame. Click or drag the target to choose a fixed focus.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(controller.session.effects.zooms) { zoom in
                InsetGroupBox("Zoom at \(zoom.start, specifier: "%.1f") s") {
                    Button { controller.selectZoom(zoom.id) } label: {
                        Label("Show Target", systemImage: controller.selectedZoom?.id == zoom.id ? "checkmark.circle" : "scope")
                    }
                    .accessibilityValue(controller.selectedZoom?.id == zoom.id ? "Selected" : "")
                    .help("Pause at this zoom’s midpoint and show the area it will focus on.")
                    timeField("Start", value: zoomBinding(zoom.id, \.start))
                    timeField("End", value: zoomBinding(zoom.id, \.end))
                    adjustment("Magnification", value: zoomBinding(zoom.id, \.scale), range: 1...4, format: "%.1f×")
                    if controller.recording.interactions != nil {
                        Toggle("Follow Cursor", isOn: zoomBinding(zoom.id, \.followsCursor))
                    }
                    if !zoom.followsCursor || controller.recording.interactions == nil {
                        adjustment("Horizontal Focus", value: zoomBinding(zoom.id, \.center.x), range: 0...1, format: "%.2f")
                        adjustment("Vertical Focus", value: zoomBinding(zoom.id, \.center.y), range: 0...1, format: "%.2f")
                    }
                    DisclosureGroup("Timing") {
                        adjustment("Transition Seconds", value: zoomBinding(zoom.id, \.transitionDuration), range: 0.15...2, format: "%.2f")
                    }
                    HStack {
                        Button("Preview Zoom") { controller.previewZoom(zoom.id) }
                            .disabled(controller.isPreparingPreview || controller.previewError != nil)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            var effects = controller.session.effects
                            effects.zooms.removeAll { $0.id == zoom.id }
                            controller.perform(.effects(effects, name: "Remove Zoom"))
                        }
                    }
                }
            }
        }
    }

    private var cursor: some View {
        Group {
            if controller.recording.interactions == nil {
                InsetGroupBox("Cursor & Clicks") {
                    Label("Cursor Is Part of This Video", systemImage: "info.circle")
                    Text("This video has no separate cursor data. Record a new Video in SnipSnipSnip to adjust the cursor and clicks afterward.")
                        .foregroundStyle(.secondary)
                }
            } else {
                InsetGroupBox("Cursor") {
                    Toggle("Show Cursor", isOn: effect(\.showsCursor, name: "Show Cursor"))
                    Toggle("Smooth Movement", isOn: effect(\.smoothsCursor, name: "Smooth Cursor"))
                        .disabled(!controller.session.effects.showsCursor)
                    adjustment("Size", value: effect(\.cursorScale, name: "Resize Cursor"), range: 0.75...4, format: "%.1f×")
                        .disabled(!controller.session.effects.showsCursor)
                }
                InsetGroupBox("Clicks") {
                    Toggle("Highlight Clicks", isOn: effect(\.showsClicks, name: "Highlight Clicks"))
                    Text("A brief ring makes each click easy to follow.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var audio: some View {
        Group {
            InsetGroupBox("Sound") {
                adjustment("Volume", value: effect(\.audioVolume, name: "Change Volume"), range: 0...2, format: "%.1f×")
                Text("Set volume to zero to export a silent video. Recorded microphone and system sound are adjusted together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            InsetGroupBox("Keyboard Shortcuts") {
                if controller.recording.interactions?.shortcuts.isEmpty == false {
                    Toggle("Show Shortcuts", isOn: effect(\.showsShortcuts, name: "Show Shortcuts"))
                } else {
                    Text("No shortcuts were recorded.")
                    if supportsShortcutCapture {
                        Text("For your next recording, enable Record Keyboard Shortcuts in Settings > Video. It records shortcut names only, never typed text.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Shortcut recording is not available in this build. Videos with existing shortcut data can still display it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func timeField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing).frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(label) in seconds")
            Text("s").foregroundStyle(.secondary)
        }
    }

    private func adjustment(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                if editing { controller.beginContinuousEdit(label) } else { controller.endContinuousEdit() }
            })
            .labelsHidden()
            .accessibilityLabel(label)
        }
    }

    private func effect<Value>(_ path: WritableKeyPath<VideoEffects, Value>, name: String) -> Binding<Value> {
        Binding(get: { controller.session.effects[keyPath: path] }, set: { value in
            var effects = controller.session.effects
            effects[keyPath: path] = value
            controller.perform(.effects(effects, name: name))
        })
    }

    private func scalarEffect(_ path: WritableKeyPath<VideoEffects, CGFloat>, name: String) -> Binding<Double> {
        let binding = effect(path, name: name)
        return Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = CGFloat($0) })
    }

    private func zoomBinding<Value>(_ id: UUID, _ path: WritableKeyPath<VideoZoom, Value>) -> Binding<Value> {
        let fallback = controller.session.effects.zooms.first(where: { $0.id == id }) ?? VideoZoom(start: 0, end: 1)
        return Binding(get: { (controller.session.effects.zooms.first(where: { $0.id == id }) ?? fallback)[keyPath: path] }, set: { value in
            var effects = controller.session.effects
            guard let index = effects.zooms.firstIndex(where: { $0.id == id }) else { return }
            controller.selectedZoomID = id
            effects.zooms[index][keyPath: path] = value
            controller.perform(.effects(effects, name: "Adjust Zoom"))
        })
    }

    private var backgroundChoice: Int {
        guard case .solid(let color) = controller.session.effects.presentation.background else { return 0 }
        if color.red < 0.2 { return 1 }
        if color.blue > color.red + 0.1 { return 2 }
        if color.red > color.blue + 0.1 { return 3 }
        return 0
    }

    private func setBackground(_ index: Int) {
        let colors = [RGBAColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1),
                      RGBAColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
                      RGBAColor(red: 0.58, green: 0.73, blue: 0.94, alpha: 1),
                      RGBAColor(red: 0.94, green: 0.84, blue: 0.69, alpha: 1)]
        var effects = controller.session.effects
        effects.presentation.background = .solid(colors[min(max(index, 0), colors.count - 1)])
        controller.perform(.effects(effects, name: "Change Background"))
    }

    private var canvasChoice: String {
        if case .preset(let preset) = controller.session.effects.presentation.canvas { return preset.rawValue }
        return "original"
    }

    private func setCanvas(_ raw: String) {
        var effects = controller.session.effects
        effects.presentation.canvas = PresentationCanvasPreset(rawValue: raw).map { .preset($0) } ?? .original
        controller.perform(.effects(effects, name: "Change Video Shape"))
    }
}
