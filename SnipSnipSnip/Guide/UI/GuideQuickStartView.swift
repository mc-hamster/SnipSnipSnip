import SwiftUI

struct GuideQuickStartView: View {
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel

    @State private var outputIntent: GuideOutputIntent
    @State private var audioIntent: GuideAudioIntent
    @State private var isShowingFineTune = false

    private let choiceColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(guide: GuideWorkflowModel, permissions: PermissionWorkflowModel) {
        self.guide = guide
        self.permissions = permissions
        let intent = GuideCaptureSetupIntent(preferences: guide.capturePreferences)
        _outputIntent = State(initialValue: intent.output)
        _audioIntent = State(initialValue: intent.audio)
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        if guide.isShowingFirstUseSetup {
                            firstUseCard
                        }

                        outputQuestion

                        if outputIntent == .stepsAndVideo {
                            audioQuestion
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        sourceQuestion
                        fineTuneCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
                .scrollBounceBehavior(.basedOnSize)

                footer
            }
        }
        .frame(width: 760, height: 730)
        .onAppear(perform: prepareSourceSelection)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.12, blue: 0.16),
                    Color(red: 0.05, green: 0.08, blue: 0.11),
                    Color(red: 0.10, green: 0.11, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.16))
                .frame(width: 280, height: 280)
                .offset(x: -290, y: -270)
                .blur(radius: 18)

            Circle()
                .fill(Color.indigo.opacity(0.18))
                .frame(width: 320, height: 320)
                .offset(x: 310, y: 270)
                .blur(radius: 22)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "list.number")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.tint(.cyan.opacity(0.18)), in: .rect(cornerRadius: 17))

            VStack(alignment: .leading, spacing: 5) {
                Text("Create a Guide")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Tell us what you want to make. We’ll set up the capture for you.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 18)

            Button("Cancel") { guide.isShowingQuickStart = false }
                .buttonStyle(SSSChromeButtonStyle(tint: .white))
                .keyboardShortcut(.cancelAction)
                .help("Close Guide setup without starting a capture.")
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var firstUseCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.mint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text("Private by design")
                    .font(.headline)
                Text("Work normally and each action becomes an editable step. Everything stays on this Mac, and secure fields are masked automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sssGlassSurface(cornerRadius: 18, tint: .mint.opacity(0.09), shadowOpacity: 0.04)
        .overlay(cardBorder(cornerRadius: 18))
    }

    private var outputQuestion: some View {
        questionCard(
            number: "1",
            title: "What do you want to make?",
            detail: "You’ll always get editable steps. Choose whether to keep the full recording too."
        ) {
            LazyVGrid(columns: choiceColumns, spacing: 12) {
                GuideIntentChoiceCard(
                    title: "Step-by-step guide",
                    detail: "For PDF, Word, images, GIF, or a slideshow.",
                    systemImage: "rectangle.stack",
                    tint: .cyan,
                    isSelected: outputIntent == .stepsOnly,
                    helpText: "Capture editable still steps without keeping the full recording. Best for written instructions, PDFs, Word documents, images, GIFs, and slideshow videos."
                ) {
                    outputIntent = .stepsOnly
                }

                GuideIntentChoiceCard(
                    title: "Guide + video",
                    detail: "Also export full motion or action highlights.",
                    systemImage: "play.rectangle.on.rectangle",
                    tint: .cyan,
                    isSelected: outputIntent == .stepsAndVideo,
                    helpText: "Capture editable still steps and keep the full recording. Choose this when you may export a complete video walkthrough or action highlights."
                ) {
                    outputIntent = .stepsAndVideo
                }
            }
        }
    }

    private var audioQuestion: some View {
        questionCard(
            number: "2",
            title: "How should the video sound?",
            detail: "Choose what viewers should hear. You can change either source from the Guide controls while recording."
        ) {
            LazyVGrid(columns: choiceColumns, spacing: 12) {
                audioChoice(.none, title: "No audio", detail: "Keep the walkthrough silent.", image: "speaker.slash")
                audioChoice(.narration, title: "My narration", detail: "Explain the workflow as you go.", image: "mic")
                audioChoice(.appAudio, title: "App audio", detail: "Include sound from the Mac.", image: "speaker.wave.2")
                audioChoice(.narrationAndAppAudio, title: "Narration + app audio", detail: "Record your voice and the Mac together.", image: "waveform.badge.mic")
            }
        }
    }

    private var sourceQuestion: some View {
        questionCard(
            number: outputIntent == .stepsAndVideo ? "3" : "2",
            title: "What will you walk through?",
            detail: "Keep the Guide focused on one window or app, select an area, or show the whole display."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: choiceColumns, spacing: 12) {
                    sourceChoice("window", title: "One window", detail: "Follow a specific window.", image: "macwindow")
                    sourceChoice("app", title: "One app", detail: "Follow the app as its windows change.", image: "app.dashed")
                    sourceChoice("region", title: "An area", detail: "Drag over the area after you start.", image: "selection.pin.in.out")
                    sourceChoice("display", title: "Everything on a display", detail: "Show the full screen.", image: "display")
                }

                sourcePicker
            }
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        switch guide.selectedSourceKind {
        case "window":
            sourceMenu(
                label: "Window",
                selection: selectedWindow?.displayTitle ?? "Choose a window",
                choices: guide.availableWindows,
                choiceTitle: \.displayTitle
            )
        case "app":
            sourceMenu(
                label: "App",
                selection: selectedWindow?.ownerName ?? "Choose an app",
                choices: availableApps,
                choiceTitle: \.ownerName
            )
        case "display":
            Menu {
                ForEach(guide.dependencies.systemServices.screens.screens, id: \.displayID) { display in
                    Button(display.name) { guide.selectedDisplayID = display.displayID }
                }
            } label: {
                sourceSelectionLabel(
                    label: "Display",
                    selection: selectedDisplayName ?? "Choose a display"
                )
            }
            .menuStyle(.borderlessButton)
            .help("Choose which display the Guide should capture.")
        default:
            Label("You’ll choose the area after clicking Start Guide.", systemImage: "cursorarrow.rays")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var fineTuneCard: some View {
        DisclosureGroup(isExpanded: $isShowingFineTune) {
            VStack(alignment: .leading, spacing: 12) {
                if outputIntent == .stepsAndVideo {
                    Picker("Video smoothness", selection: $guide.capturePreferences.framesPerSecond) {
                        Text("Smaller file · 15 fps").tag(15)
                        Text("Balanced · 30 fps").tag(30)
                        Text("Extra smooth · 60 fps").tag(60)
                    }
                    .help("Set the frame rate for full-motion and action-highlight video. This does not change the quality of still steps; higher frame rates use more storage.")
                }

                Toggle("Show the pointer in still steps", isOn: $guide.capturePreferences.showsCursorInSteps)
                    .help("Draw the pointer at its recorded position in each still step. This does not add the pointer to the captured source video.")
                Toggle("Hide desktop icons", isOn: $guide.capturePreferences.hidesDesktopIcons)
                    .help("Remove Finder files and folders from the desktop in captured steps and source video. App windows are still captured normally.")
                Toggle("Polish step instructions on this Mac", isOn: $guide.capturePreferences.aiCaptionRefinement)
                    .help("Rewrite automatically generated instructions to sound more natural using on-device processing. Turn this off to keep the original action-based wording; nothing is uploaded.")
                Toggle("Mask secure fields", isOn: $guide.capturePreferences.masksSecureFields)
                    .help("Add an editable solid cover over detected password and other secure fields in still steps. Secure text itself is never saved.")

                if guide.selectedSourceKind == "display" {
                    Toggle("Include the menu bar", isOn: $guide.capturePreferences.menuBarIncludedForDisplays)
                        .help("Include the macOS menu bar in full-display still steps and source video. This setting has no effect on window, app, or area captures.")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.top, 14)
        } label: {
            Label("Fine-tune capture", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .help("Open optional settings for video smoothness, pointer visibility, desktop cleanup, instructions, and privacy.")
        }
        .padding(16)
        .sssGlassSurface(cornerRadius: 18, tint: .white.opacity(0.025), shadowOpacity: 0.025)
        .overlay(cardBorder(cornerRadius: 18))
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Divider().opacity(0.35)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: outputIntent == .stepsOnly ? "checkmark.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 3) {
                    Text(captureSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if outputIntent == .stepsAndVideo {
                        Text("Estimated source video: \(storageEstimate) for \(guide.storageEstimateMinutes) minutes")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }

                Spacer(minLength: 12)

                Button("Start Guide") {
                    applyIntent()
                    guide.completeFirstUseSetup()
                    guide.startSelectedSource()
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .cyan, isSelected: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .help(canStart ? "Start capturing this Guide with the choices shown in the summary." : "Open an app window before starting this Guide.")
            }

            HStack(spacing: 12) {
                if guide.hasRecoverableGuide {
                    Button("Recover Interrupted Guide", action: guide.recoverLatestGuide)
                        .buttonStyle(SSSChromeButtonStyle(tint: .white))
                        .help("Open the most recent Guide that was autosaved before an interruption.")
                }

                if !permissions.permissionStatus.hasScreenRecording || !permissions.permissionStatus.hasAccessibility {
                    Label("Screen Recording and Accessibility access are required.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func questionCard<Content: View>(
        number: String,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Text(number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 26, height: 26)
                    .background(.cyan.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sssGlassSurface(cornerRadius: 20, tint: .white.opacity(0.04), shadowOpacity: 0.04)
        .overlay(cardBorder(cornerRadius: 20))
    }

    private func audioChoice(_ value: GuideAudioIntent, title: String, detail: String, image: String) -> some View {
        GuideIntentChoiceCard(
            title: title,
            detail: detail,
            systemImage: image,
            tint: .purple,
            isSelected: audioIntent == value,
            helpText: audioHelp(for: value)
        ) {
            audioIntent = value
        }
    }

    private func sourceChoice(_ value: String, title: String, detail: String, image: String) -> some View {
        GuideIntentChoiceCard(
            title: title,
            detail: detail,
            systemImage: image,
            tint: .indigo,
            isSelected: guide.selectedSourceKind == value,
            helpText: sourceHelp(for: value)
        ) {
            guide.selectedSourceKind = value
            prepareSourceSelection()
        }
    }

    private func sourceMenu(
        label: String,
        selection: String,
        choices: [CaptureWindowSummary],
        choiceTitle: KeyPath<CaptureWindowSummary, String>
    ) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button(choice[keyPath: choiceTitle]) { guide.selectedWindowID = choice.id }
            }
        } label: {
            sourceSelectionLabel(label: label, selection: selection)
        }
        .menuStyle(.borderlessButton)
        .help("Choose the \(label.lowercased()) the Guide should follow.")
    }

    private func sourceSelectionLabel(label: String, selection: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(selection)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(cardBorder(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cardBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
    }

    private var availableApps: [CaptureWindowSummary] {
        var seen = Set<pid_t>()
        return guide.availableWindows
            .sorted { $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending }
            .filter { seen.insert($0.ownerPID).inserted }
    }

    private var selectedWindow: CaptureWindowSummary? {
        guard let selectedWindowID = guide.selectedWindowID else { return guide.availableWindows.first }
        return guide.availableWindows.first { $0.id == selectedWindowID } ?? guide.availableWindows.first
    }

    private var selectedDisplayName: String? {
        guard let selectedDisplayID = guide.selectedDisplayID else { return nil }
        return guide.dependencies.systemServices.screens.screens.first { $0.displayID == selectedDisplayID }?.name
    }

    private var canStart: Bool {
        !(["window", "app"].contains(guide.selectedSourceKind) && guide.availableWindows.isEmpty)
    }

    private var captureSummary: String {
        let output = outputIntent == .stepsOnly ? "Editable steps" : "Editable steps + full-motion video"
        let sound: String
        if outputIntent == .stepsOnly {
            sound = "no source video"
        } else {
            switch audioIntent {
            case .none: sound = "no audio"
            case .narration: sound = "your narration"
            case .appAudio: sound = "app audio"
            case .narrationAndAppAudio: sound = "narration + app audio"
            }
        }
        return "\(output) • \(sound) • \(sourceSummary)"
    }

    private var sourceSummary: String {
        switch guide.selectedSourceKind {
        case "window": return selectedWindow?.displayTitle ?? "one window"
        case "app": return selectedWindow?.ownerName ?? "one app"
        case "region": return "an area you choose"
        default: return selectedDisplayName ?? "one display"
        }
    }

    private var storageEstimate: String {
        let mb = guide.storageEstimateMinutes * 18
        return mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    private func audioHelp(for value: GuideAudioIntent) -> String {
        switch value {
        case .none:
            return "Keep the source video silent. You can still add or replace audio after capture."
        case .narration:
            return "Record your microphone so you can explain the workflow while demonstrating it."
        case .appAudio:
            return "Record sounds playing on the Mac without recording your microphone."
        case .narrationAndAppAudio:
            return "Record your microphone and sounds playing on the Mac together."
        }
    }

    private func sourceHelp(for value: String) -> String {
        switch value {
        case "window":
            return "Capture one specific window. Other windows from the same app stay out of the Guide."
        case "app":
            return "Follow one app as you move between its windows, sheets, and panels."
        case "region":
            return "Draw a custom area after starting. Only activity inside that area appears in the Guide."
        default:
            return "Capture everything visible on one display, including movement between apps."
        }
    }

    private func prepareSourceSelection() {
        if guide.selectedWindowID == nil || selectedWindow == nil {
            guide.selectedWindowID = guide.availableWindows.first?.id
        }
        if guide.selectedDisplayID == nil {
            guide.selectedDisplayID = guide.dependencies.systemServices.screens.mainScreen?.displayID
        }
    }

    private func applyIntent() {
        guide.capturePreferences = GuideCaptureSetupIntent(
            output: outputIntent,
            audio: audioIntent
        ).applying(to: guide.capturePreferences)
    }
}

private struct GuideIntentChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.45))
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .glassEffect(
                .regular.tint(tint.opacity(isSelected ? 0.26 : 0.035)).interactive(),
                in: .rect(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.55) : Color.white.opacity(0.10), lineWidth: isSelected ? 1.1 : 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}
