import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case captureAccess
    case clipboard
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .captureAccess:
            return "Capture Access"
        case .clipboard:
            return "Clipboard History"
        case .ready:
            return "You’re Ready"
        }
    }

    var summary: String {
        switch self {
        case .captureAccess:
            return "Welcome to SnipSnipSnip. One required permission unlocks screenshots, live previews, and recording."
        case .clipboard:
            return "Choose whether to keep an encrypted, local history of copied content."
        case .ready:
            return "Choose startup behavior, keep the essential shortcuts close, and finish setup."
        }
    }

    var symbol: String {
        switch self {
        case .captureAccess:
            return "display"
        case .clipboard:
            return "clipboard.fill"
        case .ready:
            return "checkmark.circle.fill"
        }
    }
}

enum OnboardingWindowLayout {
    static let minimumSize = CGSize(width: 680, height: 430)
    static let idealSize = CGSize(width: 720, height: 460)
}

private struct OnboardingFeature: Identifiable {
    let title: String
    let detail: String
    let systemImage: String

    var id: String { title }
}

private enum OnboardingClipboardChoice: Hashable {
    case enabled
    case disabled
}

struct OnboardingView: View {
    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var permissions: PermissionWorkflowModel
    @ObservedObject var clipboard: ClipboardWorkflowModel
    private let capabilities: AppCapabilitySnapshot
    private let completeOnboardingAction: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedStep: OnboardingStep = .captureAccess
    @State private var hasMadeClipboardChoice = false
    @State private var launchAtLoginErrorMessage: String?

    init(
        lifecycle: AppLifecycleModel,
        permissions: PermissionWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        capabilities: AppCapabilitySnapshot,
        completeOnboarding: @escaping () -> Void
    ) {
        self.lifecycle = lifecycle
        self.permissions = permissions
        self.clipboard = clipboard
        self.capabilities = capabilities
        self.completeOnboardingAction = completeOnboarding

        if lifecycle.onboardingResumeCheckpoint?.currentStep == .clipboard {
            _selectedStep = State(initialValue: .clipboard)
        }

        _hasMadeClipboardChoice = State(
            initialValue: lifecycle.onboardingPresentationMode == .replay
                || lifecycle.hasAcknowledgedOnboardingClipboardChoice
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            onboardingHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            Form {
                if lifecycle.onboardingPresentationMode == .replay {
                    replaySummary
                } else {
                    currentStepContent
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(
            minWidth: OnboardingWindowLayout.minimumSize.width,
            idealWidth: OnboardingWindowLayout.idealSize.width,
            minHeight: OnboardingWindowLayout.minimumSize.height,
            idealHeight: OnboardingWindowLayout.idealSize.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            refreshOnboardingPermissions()
            lifecycle.refreshLaunchAtLoginStatus()
        }
        .onChange(of: selectedStep) { _, _ in
            refreshOnboardingPermissions()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }
            refreshOnboardingPermissions()
        }
        .alert("Couldn’t Update Launch at Login", isPresented: Binding(get: {
            launchAtLoginErrorMessage != nil
        }, set: { isPresented in
            if !isPresented {
                launchAtLoginErrorMessage = nil
            }
        })) {
            Button("OK", role: .cancel) {
                launchAtLoginErrorMessage = nil
            }

            Button("Open Login Items") {
                lifecycle.openLaunchAtLoginSettings()
                launchAtLoginErrorMessage = nil
            }
        } message: {
            Text(launchAtLoginErrorMessage ?? "")
        }
    }

    private var onboardingHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: headerSymbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))

                Text(headerSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 20)

            if lifecycle.onboardingPresentationMode == .firstRun {
                VStack(alignment: .trailing, spacing: 7) {
                    Text("Step \(currentStepNumber) of \(OnboardingStep.allCases.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ProgressView(
                        value: Double(currentStepNumber),
                        total: Double(OnboardingStep.allCases.count)
                    )
                    .frame(width: 112)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("Step \(currentStepNumber) of \(OnboardingStep.allCases.count)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: String {
        lifecycle.onboardingPresentationMode == .replay ? "Setup Summary" : selectedStep.title
    }

    private var headerSummary: String {
        lifecycle.onboardingPresentationMode == .replay
            ? "Review or update the choices that keep SnipSnipSnip ready. Changes save immediately."
            : selectedStep.summary
    }

    private var headerSymbol: String {
        lifecycle.onboardingPresentationMode == .replay ? "checklist" : selectedStep.symbol
    }

    private var currentStepNumber: Int {
        (OnboardingStep.allCases.firstIndex(of: selectedStep) ?? 0) + 1
    }

    @ViewBuilder
    private var currentStepContent: some View {
        switch selectedStep {
        case .captureAccess:
            captureAccessStep
        case .clipboard:
            clipboardStep
        case .ready:
            readyStep
        }
    }

    private var captureAccessStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            screenRecordingGroup(showsSetupActions: false)

            Label(
                "macOS groups screenshot access under Screen Recording. SnipSnipSnip captures only when you choose a capture or recording action.",
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            deferredPermissionNotes

            Button("Open Capture Access Help") {
                openWindow(id: AppSceneID.helpWindow)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var clipboardStep: some View {
        clipboardChoiceGroup
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            launchAtLoginGroup

            InsetGroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(defaultCaptureShortcutEntries) { entry in
                        shortcutRow(key: entry.keys, action: entry.action)
                    }
                }
                .padding(.vertical, 2)
            } label: {
                Label("Essential shortcuts", systemImage: "command")
            }

            exploreMoreDisclosure

            Text("You can replay this setup from Settings > General.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var replaySummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            screenRecordingGroup(showsSetupActions: true)
            clipboardChoiceGroup
            launchAtLoginGroup
            exploreMoreDisclosure

            actionGroup {
                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }

                Button("Open Support Page") {
                    openURL(AppLinks.support)
                }
            }
        }
    }

    private func screenRecordingGroup(showsSetupActions: Bool) -> some View {
        let needsAttention = permissions.screenRecordingSetupNeedsAttention
        let hasAccess = !needsAttention && permissions.permissionStatus.hasScreenRecording
        let isWaiting = !needsAttention && permissions.activePermissionRequest == .screenRecording

        return InsetGroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "display")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(permissionStatusColor(hasAccess: hasAccess))
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Screen Recording")
                            .font(.headline.weight(.semibold))

                        Label(
                            permissionStatusLabel(hasAccess: hasAccess),
                            systemImage: hasAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(permissionStatusColor(hasAccess: hasAccess))
                    }

                    Spacer(minLength: 12)
                }

                Text("Required for screenshot pixels, live window thumbnails, screen capture, and video recording.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if needsAttention {
                    Label(
                        "Restart SnipSnipSnip to finish applying access.",
                        systemImage: "arrow.clockwise.circle.fill"
                    )
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)

                    if showsSetupActions {
                        actionGroup {
                            Button(AppBranding.branded("Restart SnipSnipSnip"), action: restartAfterPermissionSetup)
                                .buttonStyle(.borderedProminent)

                            Button("Check Again", action: permissions.checkPermissionSetupGuideStatus)
                        }
                    } else {
                        Button("Check Again", action: permissions.checkPermissionSetupGuideStatus)
                    }
                } else if isWaiting {
                    Text("Turn on SnipSnipSnip in System Settings, then return here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    actionGroup {
                        Button("Check Again", action: permissions.checkPermissionSetupGuideStatus)
                        Button("Open Settings") {
                            permissions.openPermissionSettings(.screenRecording)
                        }
                    }
                } else if showsSetupActions && !hasAccess {
                    Button("Set Up Screen Recording") {
                        permissions.requestPermission(.screenRecording)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(permissions.activePermissionRequest != nil)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Required capture access", systemImage: "checkmark.shield")
        }
    }

    private var clipboardChoiceGroup: some View {
        InsetGroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save supported copied items in an encrypted history protected by Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Clipboard History", selection: clipboardChoiceBinding) {
                    Text("Enable Clipboard History")
                        .tag(OnboardingClipboardChoice.enabled as OnboardingClipboardChoice?)
                        .accessibilityIdentifier("onboarding.clipboard.enable")

                    Text("Keep Off")
                        .tag(OnboardingClipboardChoice.disabled as OnboardingClipboardChoice?)
                        .accessibilityIdentifier("onboarding.clipboard.keepOff")
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("onboarding.clipboard.choice")

                if clipboard.preferences.isEnabled {
                    Toggle("Also add screenshots that were not copied", isOn: uncopiedScreenshotsBinding)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("onboarding.clipboard.uncopiedScreenshots")
                }

                Label(clipboardChoiceStatus, systemImage: clipboardChoiceStatusSymbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } label: {
            Label("Private and optional", systemImage: "lock.shield.fill")
        }
    }

    private var launchAtLoginGroup: some View {
        InsetGroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Start \(AppBranding.displayName) automatically when I log in", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)

                Label(
                    lifecycle.launchAtLoginStatus.stateLabel,
                    systemImage: lifecycle.launchAtLoginStatus.systemImage
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(launchAtLoginColor)

                Text("Keeps the menu bar capture actions and global shortcuts ready after login.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if lifecycle.launchAtLoginStatus.needsSystemSettingsApproval || lifecycle.launchAtLoginStatus == .unavailable {
                    Button("Open Login Items in System Settings", action: lifecycle.openLaunchAtLoginSettings)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Keep capture ready", systemImage: "menubar.rectangle")
        }
    }

    private var exploreMoreDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(discoverableFeatures) { feature in
                    onboardingDiscoveryRow(feature)
                }
            }
            .padding(.top, 10)
        } label: {
            Label("More tools to explore", systemImage: "sparkles")
        }
    }

    private var deferredPermissionNotes: some View {
        DisclosureGroup("Other access is requested only when used") {
            VStack(alignment: .leading, spacing: 12) {
                if shouldMentionAccessibility {
                    deferredPermissionRow(
                        title: "Accessibility",
                        detail: "Scrolling Capture, UI Map, and assisted workflows.",
                        systemImage: "accessibility"
                    )
                }

                if capabilities.isEnabled(.connectedDeviceCapture) {
                    deferredPermissionRow(
                        title: "Camera",
                        detail: "Connected-device preview and capture.",
                        systemImage: "camera.fill"
                    )
                }

                deferredPermissionRow(
                    title: "Microphone",
                    detail: "Only when narration is enabled for recording.",
                    systemImage: "mic.fill"
                )

                deferredPermissionRow(
                    title: "System Audio",
                    detail: "Only when system audio is enabled for recording.",
                    systemImage: "speaker.wave.2.fill"
                )
            }
            .padding(.top, 10)
        }
    }

    private var discoverableFeatures: [OnboardingFeature] {
        var features: [OnboardingFeature] = []

        if capabilities.isEnabled(.guideCapture) {
            features.append(OnboardingFeature(
                title: "Guide",
                detail: "Build polished step-by-step instructions.",
                systemImage: "list.number"
            ))
        }
        if capabilities.isEnabled(.uiMap) {
            features.append(OnboardingFeature(
                title: "UI Map",
                detail: "Inspect interface details from Window captures.",
                systemImage: "rectangle.3.group"
            ))
        }
        if capabilities.isEnabled(.screenRecording) {
            features.append(OnboardingFeature(
                title: "Video",
                detail: "Record a screen or window with audio.",
                systemImage: "record.circle"
            ))
        }
        if capabilities.isEnabled(.presentation) {
            features.append(OnboardingFeature(
                title: "Create & Polish",
                detail: "Compare, explain, combine, or add an optional finishing look.",
                systemImage: "sparkles.rectangle.stack"
            ))
        }
        if capabilities.isEnabled(.recovery) {
            features.append(OnboardingFeature(
                title: WorkflowVocabulary.Library.snipLibrary,
                detail: "Find recent work, restore interrupted sessions, and recover deleted snips.",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
            ))
        }
        if capabilities.isEnabled(.automation) {
            features.append(OnboardingFeature(
                title: "Automation",
                detail: "Connect capture and export to your workflows.",
                systemImage: "gearshape.2"
            ))
        }

        return features
    }

    private func onboardingDiscoveryRow(_ feature: OnboardingFeature) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.subheadline.weight(.semibold))

                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: feature.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deferredPermissionRow(title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if lifecycle.onboardingPresentationMode == .firstRun && selectedStep != .captureAccess {
                Button("Back", action: moveBack)
            }

            Spacer(minLength: 16)

            Button(primaryFooterTitle, action: primaryFooterAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isPrimaryFooterDisabled)
        }
    }

    private var primaryFooterTitle: String {
        if lifecycle.onboardingPresentationMode == .replay {
            return "Close"
        }

        if selectedStep == .captureAccess,
           permissions.activePermissionRequest == .screenRecording {
            return "Waiting for Settings"
        }

        if selectedStep == .captureAccess,
           permissions.screenRecordingSetupNeedsAttention {
            return AppBranding.branded("Restart SnipSnipSnip")
        }

        if selectedStep == .captureAccess,
           !permissions.permissionStatus.hasScreenRecording {
            return "Set Up Screen Recording"
        }

        return selectedStep == .ready ? "Finish" : "Continue"
    }

    private var isPrimaryFooterDisabled: Bool {
        if lifecycle.onboardingPresentationMode == .replay {
            return false
        }

        if selectedStep == .captureAccess {
            return permissions.activePermissionRequest != nil
        }

        if selectedStep == .clipboard {
            return !hasMadeClipboardChoice
        }

        return !canCompleteOnboarding
    }

    private func primaryFooterAction() {
        if lifecycle.onboardingPresentationMode == .replay {
            completeOnboarding()
            return
        }

        if selectedStep == .captureAccess,
           permissions.screenRecordingSetupNeedsAttention {
            restartAfterPermissionSetup()
            return
        }

        if selectedStep == .captureAccess,
           !permissions.permissionStatus.hasScreenRecording {
            permissions.requestPermission(.screenRecording)
            return
        }

        moveForward()
    }

    private func moveBack() {
        let steps = OnboardingStep.allCases
        guard let currentIndex = steps.firstIndex(of: selectedStep),
              currentIndex > steps.startIndex else {
            return
        }
        selectedStep = steps[steps.index(before: currentIndex)]
    }

    private func moveForward() {
        let steps = OnboardingStep.allCases
        guard let currentIndex = steps.firstIndex(of: selectedStep) else {
            completeOnboarding()
            return
        }

        let nextIndex = steps.index(after: currentIndex)
        if nextIndex < steps.endIndex {
            selectedStep = steps[nextIndex]
        } else {
            completeOnboarding()
        }
    }

    private func completeOnboarding() {
        guard canCompleteOnboarding else {
            selectedStep = permissions.permissionStatus.hasScreenRecording ? .clipboard : .captureAccess
            return
        }

        completeOnboardingAction()
        dismiss()
    }

    private var canCompleteOnboarding: Bool {
        OnboardingCompletionPolicy.canComplete(
            mode: lifecycle.onboardingPresentationMode,
            hasScreenRecording: permissions.permissionStatus.hasScreenRecording,
            hasMadeClipboardChoice: hasMadeClipboardChoice
        )
    }

    private func restartAfterPermissionSetup() {
        lifecycle.saveOnboardingResumeCheckpoint(.clipboard)
        AppTerminationController.shared.requestRestartWithoutConfirmation()
    }

    private func refreshOnboardingPermissions() {
        permissions.refreshPermissions()
    }

    private var defaultCaptureShortcutEntries: [ShortcutCatalogEntry] {
        AppShortcut.catalogSections
            .first { $0.title == "Default Global Shortcuts" }
            .map { Array($0.entries.prefix(3)) } ?? []
    }

    private func shortcutRow(key: String, action: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(AppBranding.branded(action))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func actionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                content()
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
    }

    private func permissionStatusLabel(hasAccess: Bool) -> String {
        if hasAccess {
            return "Allowed"
        }
        if permissions.activePermissionRequest == .screenRecording {
            return "Waiting for Settings"
        }
        if permissions.screenRecordingSetupNeedsAttention {
            return "Restart Required"
        }
        return "Needs Setup"
    }

    private func permissionStatusColor(hasAccess: Bool) -> Color {
        hasAccess ? .green : .orange
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { lifecycle.launchAtLoginStatus.prefersEnabledToggle },
            set: { newValue in
                let result = lifecycle.updateLaunchAtLoginEnabled(newValue)
                if case let .failed(message) = result {
                    launchAtLoginErrorMessage = message
                }
            }
        )
    }

    private var uncopiedScreenshotsBinding: Binding<Bool> {
        Binding(
            get: { clipboard.preferences.recordsUncopiedSnips },
            set: { newValue in
                clipboard.updateRecordsUncopiedSnips(newValue)
            }
        )
    }

    private var clipboardChoiceBinding: Binding<OnboardingClipboardChoice?> {
        Binding(
            get: {
                guard hasMadeClipboardChoice else {
                    return nil
                }
                return clipboard.preferences.isEnabled ? .enabled : .disabled
            },
            set: { choice in
                guard let choice else {
                    return
                }
                clipboard.updateClipboardHistoryEnabled(choice == .enabled)
                acknowledgeClipboardChoice()
            }
        )
    }

    private var clipboardChoiceStatus: String {
        guard hasMadeClipboardChoice else {
            return "Choose one option to continue."
        }
        return clipboard.preferences.isEnabled
            ? "Enabled. Private Capture screenshots are never added."
            : "Kept off. Nothing is monitored."
    }

    private var clipboardChoiceStatusSymbol: String {
        guard hasMadeClipboardChoice else {
            return "circle.dashed"
        }
        return clipboard.preferences.isEnabled ? "checkmark.circle.fill" : "hand.raised.fill"
    }

    private var launchAtLoginColor: Color {
        switch lifecycle.launchAtLoginStatus {
        case .disabled:
            return .secondary
        case .enabled:
            return .green
        case .requiresApproval:
            return .orange
        case .unavailable:
            return .red
        }
    }

    private var shouldMentionAccessibility: Bool {
        capabilities.isEnabled(.scrollingCapture)
            || capabilities.isEnabled(.guideCapture)
            || capabilities.isEnabled(.uiMap)
    }

    private func acknowledgeClipboardChoice() {
        hasMadeClipboardChoice = true
        lifecycle.acknowledgeOnboardingClipboardChoice()
    }
}
