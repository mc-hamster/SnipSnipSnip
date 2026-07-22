import AppKit
import SwiftUI

struct GuideQuickStartView: View {
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel

    @State private var outputIntent: GuideOutputIntent
    @State private var audioIntent: GuideAudioIntent
    @State private var isShowingFineTune = false

    init(guide: GuideWorkflowModel, permissions: PermissionWorkflowModel) {
        self.guide = guide
        self.permissions = permissions
        let intent = GuideCaptureSetupIntent(preferences: guide.capturePreferences)
        _outputIntent = State(initialValue: intent.output)
        _audioIntent = State(initialValue: intent.audio)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                if guide.isShowingFirstUseSetup {
                    firstUseCard
                }

                outputQuestion

                if outputIntent == .stepsAndVideo {
                    audioQuestion
                }

                sourceQuestion
                fineTuneCard
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            footer
        }
        .frame(width: 760, height: 730)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: prepareSourceSelection)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "list.number")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("Create a Guide")
                    .font(.title2.weight(.semibold))

                Text("Tell us what you want to make. We’ll set up the capture for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var firstUseCard: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Private by design")
                        .font(.headline)
                    Text("Work normally and each action becomes an editable step. Everything stays on this Mac, and secure fields are masked automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var outputQuestion: some View {
        Section("1. What do you want to make?") {
            Text("You’ll always get editable steps. Choose whether to keep the full recording too.")
                .foregroundStyle(.secondary)

            Picker("Output", selection: $outputIntent) {
                Text("Step-by-step guide").tag(GuideOutputIntent.stepsOnly)
                Text("Guide + video").tag(GuideOutputIntent.stepsAndVideo)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(outputIntent == .stepsOnly
                ? "Best for PDF, Word, images, GIF, or a slideshow. No source video or audio is retained."
                : "Also keeps the source recording for full-motion and action-highlight video exports.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioQuestion: some View {
        Section("2. How should the video sound?") {
            Text("Choose what viewers should hear. You can change either source from the Guide controls while recording.")
                .foregroundStyle(.secondary)

            Picker("Audio", selection: $audioIntent) {
                Text("No audio").tag(GuideAudioIntent.none)
                Text("My narration").tag(GuideAudioIntent.narration)
                Text("App audio").tag(GuideAudioIntent.appAudio)
                Text("Narration + app audio").tag(GuideAudioIntent.narrationAndAppAudio)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(audioHelp(for: audioIntent))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceQuestion: some View {
        Section("\(outputIntent == .stepsAndVideo ? 3 : 2). What will you walk through?") {
            Text("Keep the Guide focused on one window or app, select an area, or show the whole display.")
                .foregroundStyle(.secondary)

            Picker("Source", selection: $guide.selectedSourceKind) {
                Text("One window").tag("window")
                Text("One app").tag("app")
                Text("An area").tag("region")
                Text("Everything on a display").tag("display")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: guide.selectedSourceKind) { _, _ in prepareSourceSelection() }

            Text(sourceHelp(for: guide.selectedSourceKind))
                .font(.caption)
                .foregroundStyle(.secondary)

            sourcePicker
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
        Section {
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
                .padding(.top, 12)
            } label: {
                Label("Fine-tune capture", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .help("Open optional settings for video smoothness, pointer visibility, desktop cleanup, instructions, and privacy.")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: outputIntent == .stepsOnly ? "checkmark.circle.fill" : "record.circle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(captureSummary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    if outputIntent == .stepsAndVideo {
                        Text("Estimated source video: \(storageEstimate) for \(guide.storageEstimateMinutes) minutes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                Button("Cancel") { guide.isShowingQuickStart = false }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Guide setup without starting a capture.")

                Button("Start Guide") {
                    applyIntent()
                    guide.completeFirstUseSetup()
                    guide.startSelectedSource()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .help(canStart ? "Start capturing this Guide with the choices shown in the summary." : "Open an app window before starting this Guide.")
            }

            HStack(spacing: 12) {
                if guide.hasRecoverableGuide {
                    Button("Recover Interrupted Guide", action: guide.recoverLatestGuide)
                        .buttonStyle(.glass)
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
        .padding(.vertical, 14)
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
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
