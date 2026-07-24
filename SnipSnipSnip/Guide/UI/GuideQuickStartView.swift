import AppKit
import SwiftUI

struct GuideQuickStartView: View {
    @ObservedObject var guide: GuideWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel

    @State private var outputIntent: GuideOutputIntent
    @State private var audioIntent: GuideAudioIntent
    @State private var showsStepNumbers: Bool
    @State private var showsActionTargets: Bool
    @State private var isShowingFineTune = false

    init(guide: GuideWorkflowModel, permissions: PermissionWorkflowModel) {
        self.guide = guide
        self.permissions = permissions
        let intent = GuideCaptureSetupIntent(preferences: guide.capturePreferences)
        _outputIntent = State(initialValue: intent.output)
        _audioIntent = State(initialValue: intent.audio)
        _showsStepNumbers = State(initialValue: intent.showsStepNumbers)
        _showsActionTargets = State(initialValue: intent.showsActionTargets)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a Guide")
                    .font(.title2.weight(.semibold))
                Text("Choose what to make and what Guide should follow.")
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

            Toggle("Number each step", isOn: $showsStepNumbers)
                .help("Choose whether newly captured steps start with a visible step number. You can change this later for any individual step.")

            Text(showsStepNumbers
                ? "Each captured step starts with a number. You can hide it for an individual step in the editor."
                : "Steps start without numbers. You can show one for an individual step in the editor.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show action crosshairs", isOn: $showsActionTargets)
                .help("Choose whether newly captured steps mark where the action happened. You can change this later for any individual step.")

            Text(showsActionTargets
                ? "Each captured step marks the action with crosshairs. You can hide them for an individual step in the editor."
                : "Steps start without crosshairs. You can show them for an individual step in the editor.")
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
        Section("\(outputIntent == .stepsAndVideo ? 3 : 2). What will you capture?") {
            Text("Choose how Guide should follow your work. You’ll select the exact target after Start Guide.")
                .foregroundStyle(.secondary)

            Picker("Source", selection: $guide.selectedSourceKind) {
                Label("Region", systemImage: "selection.pin.in.out").tag("region")
                Label("Window", systemImage: "rectangle.on.rectangle").tag("window")
                Label("App", systemImage: "app.dashed").tag("app")
                Label("Display", systemImage: "macwindow").tag("display")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(sourceHelp(for: guide.selectedSourceKind))
                .font(.caption)
                .foregroundStyle(.secondary)

            Label(targetSelectionPrompt, systemImage: "cursorarrow.rays")
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
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Guide setup without starting a capture.")

                Button("Start Guide") {
                    applyIntent()
                    guide.completeFirstUseSetup()
                    guide.beginSelectedSourceSelection()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Choose the target on screen, then start capturing this Guide.")
            }

            HStack(spacing: 12) {
                if guide.hasRecoverableGuide {
                    Button("Recover Interrupted Guide", action: guide.recoverLatestGuide)
                        .buttonStyle(.bordered)
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
        let numbering = showsStepNumbers ? "numbered steps" : "no step numbers"
        return "\(output) • \(numbering) • \(sound) • \(sourceSummary)"
    }

    private var sourceSummary: String {
        switch guide.selectedSourceKind {
        case "window": return "choose a window after Start"
        case "app": return "choose an app after Start"
        case "region": return "draw a region after Start"
        default: return "choose a display after Start"
        }
    }

    private var targetSelectionPrompt: String {
        switch guide.selectedSourceKind {
        case "window":
            return "After Start Guide, click the window to follow or choose it from a list."
        case "app":
            return "After Start Guide, click any window from the app to follow or choose it from a list."
        case "region":
            return "After Start Guide, draw the region on screen."
        default:
            return "After Start Guide, click the display to capture."
        }
    }

    private var storageEstimate: String {
        let mb = guide.storageEstimateMinutes * 18
        return mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    private func audioHelp(for value: GuideAudioIntent) -> String {
        switch value {
        case .none:
            return "Keep the source video silent. Audio is not retained and cannot be added later in the Guide editor."
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
            return "Follow one specific window as it moves or resizes. Other windows from the same app stay out of the Guide."
        case "app":
            return "Follow one app as you move between its windows, sheets, and panels."
        case "region":
            return "Keep a fixed custom area in the Guide. Only activity inside that area appears."
        default:
            return "Capture everything visible on one display, including movement between apps."
        }
    }

    private func applyIntent() {
        guide.capturePreferences = GuideCaptureSetupIntent(
            output: outputIntent,
            audio: audioIntent,
            showsStepNumbers: showsStepNumbers,
            showsActionTargets: showsActionTargets
        ).applying(to: guide.capturePreferences)
    }
}
