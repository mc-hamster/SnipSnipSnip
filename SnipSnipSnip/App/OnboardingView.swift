import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case captureAccess
    case firstSnip
    case clipboard
    case discoverMore
    case startup
    case ready

    var id: Int { rawValue }

    static func visibleCases(for capabilities: AppCapabilitySnapshot) -> [OnboardingStep] {
        allCases
    }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .captureAccess:
            return "Capture Access"
        case .firstSnip:
            return "Try Your First Snip"
        case .startup:
            return "Keep Ready"
        case .clipboard:
            return "Clipboard History"
        case .discoverMore:
            return "Discover More"
        case .ready:
            return "Ready"
        }
    }

    func summary(for capabilities: AppCapabilitySnapshot) -> String {
        switch self {
        case .welcome:
            return "Capture faster, edit immediately, and keep recovery close by."
        case .captureAccess:
            return "Allow Screen Recording so macOS can provide screenshot pixels and live previews."
        case .firstSnip:
            return "Take a guided region capture now, or skip the tutorial and continue setup."
        case .startup:
            return "Choose whether \(AppBranding.displayName) stays ready after login and in the background."
        case .clipboard:
            return "Choose whether to monitor copied content and protect its local history with Keychain."
        case .discoverMore:
            return "See the other local capture, documentation, presentation, recovery, and automation workflows."
        case .ready:
            return "Review your choices and keep Help and Support close by."
        }
    }

    var symbol: String {
        switch self {
        case .welcome:
            return "sparkles"
        case .captureAccess:
            return "hand.raised.fill"
        case .firstSnip:
            return "viewfinder"
        case .startup:
            return "power.circle.fill"
        case .clipboard:
            return "clipboard.fill"
        case .discoverMore:
            return "square.grid.2x2"
        case .ready:
            return "checkmark.circle.fill"
        }
    }
}

private struct OnboardingLayoutMetrics {
    let isCompactWidth: Bool
    let isCompactHeight: Bool
    let cardSpacing: CGFloat
    let featureSpacing: CGFloat
    let stepIconFrame: CGFloat

    init(size: CGSize) {
        isCompactWidth = size.width < 1_120
        isCompactHeight = size.height < 760
        cardSpacing = isCompactHeight ? 18 : 24
        featureSpacing = isCompactWidth ? 12 : 16
        stepIconFrame = isCompactWidth ? 58 : 68
    }
}

struct OnboardingView: View {
    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel
    @ObservedObject var clipboard: ClipboardWorkflowModel
    @ObservedObject var guide: GuideWorkflowModel
    private let capabilities: AppCapabilitySnapshot
    private let skipOnboardingAction: () -> Void
    private let completeOnboardingAction: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedStep: OnboardingStep = .welcome
    @State private var hasMadeClipboardChoice = false
    @State private var launchAtLoginErrorMessage: String?

    init(
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        permissions: PermissionWorkflowModel,
        clipboard: ClipboardWorkflowModel,
        guide: GuideWorkflowModel,
        capabilities: AppCapabilitySnapshot,
        skipOnboarding: @escaping () -> Void,
        completeOnboarding: @escaping () -> Void
    ) {
        self.lifecycle = lifecycle
        self.capture = capture
        self.permissions = permissions
        self.clipboard = clipboard
        self.guide = guide
        self.capabilities = capabilities
        self.skipOnboardingAction = skipOnboarding
        self.completeOnboardingAction = completeOnboarding
        if lifecycle.onboardingResumeCheckpoint == .firstSnip {
            _selectedStep = State(initialValue: .firstSnip)
        }
        _hasMadeClipboardChoice = State(
            initialValue: lifecycle.hasAcknowledgedOnboardingClipboardChoice
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingLayoutMetrics(size: proxy.size)

            NavigationSplitView {
                stepRail(metrics: metrics)
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
            } detail: {
                contentCard(metrics: metrics)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 920, minHeight: 640)
        .task {
            refreshOnboardingPermissions()
            lifecycle.refreshLaunchAtLoginStatus()
        }
        .onChange(of: selectedStep) { _, _ in
            Task { @MainActor in
                refreshOnboardingPermissions()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                return
            }

            Task { @MainActor in
                refreshOnboardingPermissions()
            }
        }
        .alert("Couldn't Update Launch at Login", isPresented: Binding(get: {
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

    @ViewBuilder
    private var skipOnboardingButton: some View {
        if canBypassOnboarding {
            Button("Skip for Now", action: skipOnboarding)
                .buttonStyle(.glass)
        }
    }

    private func headerCopy(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to \(AppBranding.displayName)")
                .font(.title2.weight(.semibold))

            Text("SnipSnipSnip is running in your menu bar. This short setup pass gets you from first launch to fast capture, editor workflows, and support without hunting through menus.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepRail(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            headerCopy(metrics: metrics)
                .padding(16)

            List(visibleSteps, selection: $selectedStep) { step in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                        if let status = sidebarStatus(for: step) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: step.symbol)
                }
                .tag(step)
                .help(step.summary(for: capabilities))
            }
            .listStyle(.sidebar)

            onboardingStatusCard(metrics: metrics)
                .padding(12)
        }
    }

    private func onboardingStatusCard(metrics: OnboardingLayoutMetrics) -> some View {
        InsetGroupBox {
            Text(lifecycle.onboardingPresentationMode == .firstRun
                ? "Screen Recording and an explicit Clipboard History choice are required. The first capture tutorial is optional."
                : "Replay mode reflects your current settings and never blocks completion.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("Ready When You Are", systemImage: "scissors")
        }
    }

    private func contentCard(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            currentStepHeader(metrics: metrics)
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            Form {
                currentStepContent(metrics: metrics)
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func currentStepHeader(metrics: OnboardingLayoutMetrics) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: selectedStep.symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: metrics.stepIconFrame, height: metrics.stepIconFrame)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(selectedStep.title)
                    .font(.title2.weight(.semibold))

                Text(selectedStep.summary(for: capabilities))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func currentStepContent(metrics: OnboardingLayoutMetrics) -> some View {
        switch selectedStep {
        case .welcome:
            welcomeStep(metrics: metrics)
        case .captureAccess:
            permissionsStep(metrics: metrics)
        case .firstSnip:
            firstSnipStep(metrics: metrics)
        case .startup:
            startupStep(metrics: metrics)
        case .clipboard:
            clipboardStep(metrics: metrics)
        case .discoverMore:
            discoverMoreStep(metrics: metrics)
        case .ready:
            readyStep(metrics: metrics)
        }
    }

    private func welcomeStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            featurePair(metrics: metrics) {
                onboardingFeatureCard(
                    title: "Capture From the Menu Bar",
                    detail: "Region, window, fullscreen, frontmost window, and repeat capture stay one click away.",
                    systemImage: "menubar.rectangle",
                    metrics: metrics
                )
                onboardingFeatureCard(
                    title: "Edit Right Away",
                    detail: "Every screenshot opens in the editor for crop, annotation, redaction, sharing, and export.",
                    systemImage: "wand.and.stars",
                    metrics: metrics
                )
            }

            featurePair(metrics: metrics) {
                onboardingFeatureCard(
                    title: "Recover Past Work",
                    detail: "Recent Snips, autosave checkpoints, and archive search keep earlier work close.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    metrics: metrics
                )
                onboardingFeatureCard(
                    title: "Stay Local",
                    detail: "Screenshots, OCR, rendering, history, and privacy controls stay on this Mac.",
                    systemImage: "lock.shield",
                    metrics: metrics
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Default shortcuts")
                    .font(.headline.weight(.semibold))

                ForEach(defaultCaptureShortcutEntries) { entry in
                    shortcutRow(key: entry.keys, action: entry.action)
                }
            }
        }
    }

    private var defaultCaptureShortcutEntries: [ShortcutCatalogEntry] {
        AppShortcut.catalogSections
            .first { $0.title == "Default Global Capture" }
            .map { Array($0.entries.prefix(5)) } ?? []
    }

    private func permissionsStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            permissionCard(requirement: .screenRecording, metrics: metrics)

            if let restartSummaryText = permissionRestartSummaryText {
                Label(restartSummaryText, systemImage: "arrow.clockwise.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            deferredPermissionNotes(metrics: metrics)

            actionGroup {
                if permissions.screenRecordingSetupNeedsAttention {
                    Button(AppBranding.branded("Restart SnipSnipSnip"), action: restartAfterPermissionSetup)
                        .buttonStyle(.glassProminent)
                        .tint(.orange)
                } else {
                    Button("Set Up Screen Recording") {
                        permissions.requestPermission(.screenRecording)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(
                        permissions.permissionStatus.hasScreenRecording
                            || permissions.activePermissionRequest != nil
                    )
                }

                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.glass)
            }

            Text(permissionsSummaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func firstSnipStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            InsetGroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drag around anything on screen. Release to capture immediately, or use the review controls you chose in Settings.")
                        .foregroundStyle(.secondary)

                    actionGroup {
                        Button("Start Guided Region Capture") {
                            selectedStep = .clipboard
                            capture.captureRegion()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!permissions.permissionStatus.hasScreenRecording)
                        .accessibilityIdentifier("onboarding.firstSnip.start")

                        Button("Skip Tutorial") {
                            selectedStep = .clipboard
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("onboarding.firstSnip.skip")
                    }
                }
            } label: {
                Label("Your First Snip", systemImage: "viewfinder")
            }

            Text("The tutorial is optional. Region capture remains available from the menu bar, Capture menu, and Shift-Command-1.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func guideStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            featurePair(metrics: metrics) {
                onboardingFeatureCard(
                    title: "Work Normally",
                    detail: "Each click, double-click, scroll, three-finger swipe, supported shortcut, or Manual Step becomes one editable instruction.",
                    systemImage: "cursorarrow.click.2",
                    metrics: metrics
                )
                onboardingFeatureCard(
                    title: "Menus Stay Visible",
                    detail: "Guide keeps the frame from just before the action, so menus and popovers that close remain in the step.",
                    systemImage: "menucard",
                    metrics: metrics
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Keep full-motion source video", isOn: guideOnboardingCaptureBinding(\.sourceVideoEnabled))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                Toggle("Refine captions on device", isOn: guideOnboardingCaptureBinding(\.aiCaptionRefinement))
                    .toggleStyle(.switch)
                Toggle("Mask secure fields automatically", isOn: guideOnboardingCaptureBinding(\.masksSecureFields))
                    .toggleStyle(.switch)
                Text("Source video is on by default so Full Motion and Action Highlights can be exported later. PDF and GIF are the one-click export defaults. Everything stays local, and Private Guide skips OCR and caption refinement.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideOnboardingCaptureBinding<Value>(_ keyPath: WritableKeyPath<GuideCapturePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { guide.capturePreferences[keyPath: keyPath] },
            set: { value in
                var preferences = guide.capturePreferences
                preferences[keyPath: keyPath] = value
                guide.capturePreferences = preferences
            }
        )
    }

    private func uiMapStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("UI Map works with Window capture. It can save available names, roles, identifiers, and locations from the selected window alongside the screenshot.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text("UI Map metadata stays local to the screenshot document and is used for inspection, search, documentation, accessibility review, and QA workflows. You can disable it now or change this later in Settings.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable UI Map for Window captures", isOn: uiMapBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)

                if capture.windowUIMapNeedsAccessibilityAccess {
                    GroupBox {
                        Label("Window UI Map will add Accessibility to the next permissions step.", systemImage: "lock.trianglebadge.exclamationmark.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            featurePair(metrics: metrics) {
                onboardingFeatureCard(
                    title: "Clean by Default",
                    detail: "Screenshots do not show UI Map labels automatically. Select elements later from the floating UI Map panel.",
                    systemImage: "rectangle.dashed",
                    metrics: metrics
                )

                onboardingFeatureCard(
                    title: "Document Local",
                    detail: "Flattened PNG, JPEG, and PDF exports do not include UI Map metadata unless you intentionally render visible overlays.",
                    systemImage: "doc.badge.gearshape",
                    metrics: metrics
                )
            }
        }
    }

    private func startupStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Start \(AppBranding.displayName) automatically when I log in", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)

                HStack {
                    Label(lifecycle.launchAtLoginStatus.stateLabel, systemImage: lifecycle.launchAtLoginStatus.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(launchAtLoginColor)

                    Spacer(minLength: 12)
                }

                Text(lifecycle.launchAtLoginStatus.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if lifecycle.launchAtLoginStatus.needsSystemSettingsApproval || lifecycle.launchAtLoginStatus == .unavailable {
                    Button("Open Login Items in System Settings", action: lifecycle.openLaunchAtLoginSettings)
                        .buttonStyle(.glass)
                        .tint(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Why turn it on?")
                    .font(.headline.weight(.semibold))

                Text("If \(AppBranding.displayName) starts at login, the menu bar extra, capture shortcuts, and quick editor flow are already in place when you need them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func clipboardStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Clipboard History is optional and off by default.")
                    .font(.headline.weight(.semibold))

                Text("When enabled, \(AppBranding.displayName) monitors supported content copied on this Mac and saves an encrypted local history. Its encryption key is protected by Keychain, so macOS may ask you to allow Keychain access.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                actionGroup {
                    Button("Enable Clipboard History") {
                        clipboard.updateClipboardHistoryEnabled(true)
                        acknowledgeClipboardChoice()
                    }
                    .buttonStyle(.glass)
                    .accessibilityValue(clipboard.preferences.isEnabled ? "Selected" : "Not selected")
                    .accessibilityIdentifier("onboarding.clipboard.enable")

                    Button("Keep Off") {
                        clipboard.updateClipboardHistoryEnabled(false)
                        acknowledgeClipboardChoice()
                    }
                    .buttonStyle(.glass)
                    .accessibilityValue(!clipboard.preferences.isEnabled && hasMadeClipboardChoice ? "Selected" : "Not selected")
                    .accessibilityIdentifier("onboarding.clipboard.keepOff")
                }

                if clipboard.preferences.isEnabled {
                    Toggle("Also add screenshots that were not copied", isOn: uncopiedScreenshotsBinding)
                        .toggleStyle(.switch)
                }

                Text("You can change either choice later in Settings > Library > Clipboard. Private Capture screenshots are never added, and Clipboard History does not upload its contents.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            featurePair(metrics: metrics) {
                onboardingFeatureCard(
                    title: "Your Choice",
                    detail: "No clipboard content is monitored and no history key is requested until you turn the feature on.",
                    systemImage: "hand.raised.fill",
                    metrics: metrics
                )
                onboardingFeatureCard(
                    title: "Local and Encrypted",
                    detail: "History stays on this Mac, is excluded from Spotlight and backup, and uses a Keychain-protected encryption key.",
                    systemImage: "lock.shield.fill",
                    metrics: metrics
                )
            }
        }
    }

    private func discoverMoreStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            if capabilities.isEnabled(.guideCapture) {
                onboardingFeatureCard(
                    title: "Guide",
                    detail: "Turn normal actions into editable, polished instructions while keeping source material local.",
                    systemImage: "list.number",
                    metrics: metrics
                )
            }
            if capabilities.isEnabled(.uiMap) {
                onboardingFeatureCard(
                    title: "UI Map",
                    detail: "Save available names, roles, identifiers, and locations with Window captures.",
                    systemImage: "rectangle.3.group",
                    metrics: metrics
                )
            }
            if capabilities.isEnabled(.screenRecording) {
                onboardingFeatureCard(
                    title: "Screen Recording",
                    detail: "Record a display or window with configurable audio, cursor, and click feedback.",
                    systemImage: "record.circle",
                    metrics: metrics
                )
            }
            if capabilities.isEnabled(.presentation) {
                onboardingFeatureCard(
                    title: "Presentation Beta",
                    detail: "Turn a screenshot into polished plain or styled output without changing its editable source.",
                    systemImage: "sparkles.rectangle.stack",
                    metrics: metrics
                )
            }
            if capabilities.isEnabled(.recovery) {
                onboardingFeatureCard(
                    title: "Recovery",
                    detail: "Recent Snips, archive checkpoints, and the Recycle Bin protect unfinished work.",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    metrics: metrics
                )
            }
            if capabilities.isEnabled(.automation) {
                onboardingFeatureCard(
                    title: "Automation",
                    detail: "Run supported capture and export workflows from Shortcuts, AppleScript, URLs, or the command line.",
                    systemImage: "gearshape.2",
                    metrics: metrics
                )
            }

            if shouldIncludeAccessibilityPermissionInOnboarding {
                InsetGroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(accessibilityPermissionPurposeText + " uses Accessibility only when that workflow needs to observe or control another app. Region and Fullscreen capture do not require it.")
                            .foregroundStyle(.secondary)
                        if permissions.permissionStatus.hasAccessibility {
                            Label("Accessibility allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Set Up Accessibility") {
                                permissions.requestPermission(.accessibility)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                } label: {
                    Label("Optional Access", systemImage: "accessibility")
                }
            }
        }
    }

    private func readyStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            InsetGroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        permissions.permissionStatus.hasScreenRecording ? "Screen Recording allowed" : "Screen Recording needs setup",
                        systemImage: permissions.permissionStatus.hasScreenRecording ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    Label(
                        clipboard.preferences.isEnabled ? "Clipboard History enabled" : "Clipboard History kept off",
                        systemImage: clipboard.preferences.isEnabled ? "checkmark.circle.fill" : "minus.circle"
                    )
                    Label(
                        lifecycle.launchAtLoginStatus.prefersEnabledToggle ? "Launch at Login enabled" : "Launch at Login off",
                        systemImage: lifecycle.launchAtLoginStatus.prefersEnabledToggle ? "checkmark.circle.fill" : "minus.circle"
                    )
                }
            } label: {
                Label("Setup Summary", systemImage: "checklist")
            }

            actionGroup {
                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.glass)

                Button("Open Support Page") {
                    openURL(AppLinks.support)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func supportStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            onboardingFeatureCard(
                title: "Need Help?",
                detail: "The Help guide covers setup, permissions, editing, exporting, privacy, and troubleshooting.",
                systemImage: "book.pages",
                metrics: metrics
            )

            onboardingFeatureCard(
                title: "Support and Feature Requests",
                detail: "Open the support page for setup help, bug reports, support requests, and feature requests.",
                systemImage: "bubble.left.and.bubble.right",
                metrics: metrics
            )

            actionGroup {
                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.glassProminent)

                Button("Open Support Page") {
                    openURL(AppLinks.support)
                }
                .buttonStyle(.glass)

                Button("Open Website") {
                    openURL(AppLinks.website)
                }
                .buttonStyle(.glass)
            }

            Text("You can replay this onboarding from Settings > General whenever you want the guided tour again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Button("Back", action: moveBack)
                    .buttonStyle(.glass)
                    .disabled(selectedStep == .welcome)

                Spacer(minLength: 16)

                Button(AppBranding.branded(primaryFooterTitle), action: primaryFooterAction)
                    .buttonStyle(.glassProminent)
                    .disabled(isPrimaryFooterDisabled)
            }

            VStack(alignment: .leading, spacing: 12) {
                Button("Back", action: moveBack)
                    .buttonStyle(.glass)
                    .disabled(selectedStep == .welcome)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(AppBranding.branded(primaryFooterTitle), action: primaryFooterAction)
                        .buttonStyle(.glassProminent)
                        .disabled(isPrimaryFooterDisabled)
                }
            }
        }
    }

    private var primaryFooterTitle: String {
        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess,
           permissions.screenRecordingSetupNeedsAttention,
           permissions.activePermissionRequest != nil {
            return "Waiting for Settings"
        }

        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess,
           permissions.screenRecordingSetupNeedsAttention {
            return "Restart SnipSnipSnip"
        }

        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess,
           !permissions.permissionStatus.hasScreenRecording {
            return "Set Up Screen Recording"
        }

        return selectedStep == visibleSteps.last ? "Open SnipSnipSnip" : "Next"
    }

    private var isPrimaryFooterDisabled: Bool {
        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess {
            return permissions.activePermissionRequest != nil
        }
        if selectedStep == .clipboard,
           lifecycle.onboardingPresentationMode == .firstRun {
            return !hasMadeClipboardChoice
        }
        if selectedStep == .ready,
           lifecycle.onboardingPresentationMode == .firstRun {
            return !permissions.permissionStatus.hasScreenRecording || !hasMadeClipboardChoice
        }
        return false
    }

    private func primaryFooterAction() {
        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess,
           permissions.screenRecordingSetupNeedsAttention {
            restartAfterPermissionSetup()
            return
        }

        if lifecycle.onboardingPresentationMode == .firstRun,
           selectedStep == .captureAccess,
           !permissions.permissionStatus.hasScreenRecording {
            permissions.requestPermission(.screenRecording)
            return
        }

        moveForward()
    }

    private func onboardingFeatureCard(
        title: String,
        detail: String,
        systemImage: String,
        metrics: OnboardingLayoutMetrics
    ) -> some View {
        InsetGroupBox {
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featurePair<Content: View>(
        metrics: OnboardingLayoutMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if metrics.isCompactWidth {
                VStack(alignment: .leading, spacing: metrics.featureSpacing) {
                    content()
                }
            } else {
                HStack(alignment: .top, spacing: metrics.featureSpacing) {
                    content()
                }
            }
        }
    }

    private func actionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                content()
            }

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
        }
    }

    private func permissionCard(
        requirement: CapturePermissionRequirement,
        metrics: OnboardingLayoutMetrics
    ) -> some View {
        let needsAttention = permissionNeedsAttention(requirement)
        let hasAccess = !needsAttention && permissions.permissionStatus.hasAccess(to: requirement)
        let isWaiting = !needsAttention && permissions.activePermissionRequest == requirement

        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        permissionHeader(requirement: requirement, hasAccess: hasAccess)

                        Spacer(minLength: 12)

                        if !hasAccess {
                            permissionActions(requirement: requirement, isWaiting: isWaiting, needsAttention: needsAttention)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        permissionHeader(requirement: requirement, hasAccess: hasAccess)
                        if !hasAccess {
                            permissionActions(requirement: requirement, isWaiting: isWaiting, needsAttention: needsAttention)
                        }
                    }
                }

                Text(permissionDescription(for: requirement))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let followUpText = permissionFollowUpText(for: requirement, isWaiting: isWaiting, needsAttention: needsAttention) {
                    Label(followUpText, systemImage: needsAttention ? "arrow.clockwise.circle.fill" : "gearshape.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(needsAttention ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func permissionHeader(requirement: CapturePermissionRequirement, hasAccess: Bool) -> some View {
        let statusLabel = permissionStatusLabel(for: requirement, hasAccess: hasAccess)
        let statusColor = permissionStatusColor(for: requirement, hasAccess: hasAccess)

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: requirement.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 36, height: 36)
                .background(statusColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.title)
                    .font(.headline.weight(.semibold))

                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
    }

    @ViewBuilder
    private func permissionActions(
        requirement: CapturePermissionRequirement,
        isWaiting: Bool,
        needsAttention: Bool
    ) -> some View {
        if needsAttention {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    restartPermissionButton()
                    checkAgainButton(tint: .secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    restartPermissionButton()
                    checkAgainButton(tint: .secondary)
                }
            }
        } else if isWaiting {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    checkAgainButton(tint: .orange)
                    Button("Open Settings") {
                        permissions.openPermissionSettings(requirement)
                    }
                    .buttonStyle(.glass)
                }

                VStack(alignment: .leading, spacing: 10) {
                    checkAgainButton(tint: .orange)
                    Button("Open Settings") {
                        permissions.openPermissionSettings(requirement)
                    }
                    .buttonStyle(.glass)
                }
            }
        } else {
            Button("Set Up") {
                permissions.requestPermission(requirement)
            }
            .buttonStyle(.glassProminent)
            .tint(.orange)
            .disabled(permissions.activePermissionRequest != nil)
        }
    }

    private func restartPermissionButton() -> some View {
        Button(AppBranding.branded("Restart SnipSnipSnip"), action: restartAfterPermissionSetup)
            .buttonStyle(.glassProminent)
            .tint(.orange)
    }

    private func checkAgainButton(tint: Color) -> some View {
        Button("Check Again") {
            permissions.checkPermissionSetupGuideStatus()
        }
        .buttonStyle(.glass)
        .tint(tint)
    }

    private func permissionNeedsAttention(_ requirement: CapturePermissionRequirement) -> Bool {
        requirement == .screenRecording && permissions.screenRecordingSetupNeedsAttention
    }

    private func permissionStatusLabel(for requirement: CapturePermissionRequirement, hasAccess: Bool) -> String {
        if hasAccess {
            return "Allowed"
        }

        if permissions.activePermissionRequest == requirement {
            return "Waiting for Settings"
        }

        if permissionNeedsAttention(requirement) {
            return "Restart Required"
        }

        return "Missing"
    }

    private func permissionStatusColor(for requirement: CapturePermissionRequirement, hasAccess: Bool) -> Color {
        if hasAccess {
            return .green
        }

        if permissions.activePermissionRequest == requirement || permissionNeedsAttention(requirement) {
            return .orange
        }

        return .orange
    }

    private func permissionFollowUpText(
        for requirement: CapturePermissionRequirement,
        isWaiting: Bool,
        needsAttention: Bool
    ) -> String? {
        guard requirement == .screenRecording else {
            return nil
        }

        if needsAttention {
            if hasRemainingPermissionSetupBeforeRestart {
                return "Screen Recording will be available after restart. You can finish \(accessibilityPermissionPurposeText) first, then restart once."
            }

            return "macOS has not given this running copy Screen Recording access yet. Restart \(AppBranding.displayName) to finish applying the permission."
        }

        if isWaiting {
            return "Use the macOS prompt or System Settings to turn on \(AppBranding.displayName), then return here. \(AppBranding.displayName) checks again when this window becomes active."
        }

        return nil
    }

    private var permissionRestartSummaryText: String? {
        guard permissions.screenRecordingSetupNeedsAttention else {
            return nil
        }

        if hasRemainingPermissionSetupBeforeRestart {
            return "Screen Recording is ready to apply after restart. Finish Accessibility now if you want \(accessibilityPermissionPurposeText) ready too, then restart once."
        }

        return "Restart \(AppBranding.displayName) to finish applying Screen Recording access."
    }

    private var hasRemainingPermissionSetupBeforeRestart: Bool {
        onboardingPermissionRequirements.contains { requirement in
            requirement != .screenRecording && !permissions.permissionStatus.hasAccess(to: requirement)
        }
    }

    private var accessibilityPermissionPurposeText: String {
        let includesScrollingCapture = capabilities.isEnabled(.scrollingCapture)
        let includesUIMap = capabilities.isEnabled(.uiMap) && capture.uiMapEnabled

        switch (includesUIMap, includesScrollingCapture) {
        case (true, true):
            return "Window UI Map and Scrolling Capture"
        case (true, false):
            return "Window UI Map"
        case (false, true):
            return "Scrolling Capture"
        case (false, false):
            return "Accessibility workflows"
        }
    }

    private func deferredPermissionNotes(metrics: OnboardingLayoutMetrics) -> some View {
        InsetGroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("These do not appear during onboarding. macOS asks later if you enable the matching workflow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    if capabilities.isEnabled(.connectedDeviceCapture) {
                        deferredPermissionRow(
                            title: "Camera",
                            detail: "Connected iPhone or iPad preview, screenshots, and recordings.",
                            systemImage: "camera.fill"
                        )
                    }

                    deferredPermissionRow(
                        title: "Microphone",
                        detail: "Video recording only when microphone narration is enabled.",
                        systemImage: "mic.fill"
                    )

                    deferredPermissionRow(
                        title: "System Audio",
                        detail: "Video recording only when system audio capture is enabled.",
                        systemImage: "speaker.wave.2.fill"
                    )
                }
            }
        } label: {
            Text("Asked Only When Used")
        }
    }

    private func deferredPermissionRow(title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionDescription(for requirement: CapturePermissionRequirement) -> String {
        switch requirement {
        case .screenRecording:
            return "Required for capture pixels, live window thumbnails, fullscreen capture, and video recording."
        case .accessibility:
            if capabilities.isEnabled(.scrollingCapture) && capabilities.isEnabled(.uiMap) && capture.uiMapEnabled {
                return "Required only for Scrolling Capture and Window UI Map. Region and Fullscreen captures do not require Accessibility because of UI Map."
            }

            if capabilities.isEnabled(.uiMap) && capture.uiMapEnabled {
                return "Required only for Window UI Map. Region and Fullscreen captures do not require Accessibility because of UI Map."
            }

            return "Required only for Scrolling Capture so \(AppBranding.displayName) can scroll the selected app while collecting segments."
        }
    }

    private var permissionsSummaryText: String {
        if capabilities.isEnabled(.scrollingCapture) && capabilities.isEnabled(.uiMap) && capture.uiMapEnabled {
            return "Screen Recording is required for pixels and live window thumbnails. Accessibility is only required for Scrolling Capture and Window UI Map. \(deferredPermissionSummaryText)"
        }

        if capabilities.isEnabled(.uiMap) && capture.uiMapEnabled {
            return "Screen Recording is required for pixels and live window thumbnails. Accessibility is only required for Window UI Map. \(deferredPermissionSummaryText)"
        }

        if capabilities.isEnabled(.scrollingCapture) {
            return "Screen Recording is required for pixels and live window thumbnails. Accessibility is only required for Scrolling Capture. \(deferredPermissionSummaryText)"
        }

        return "Screen Recording is required for pixels, live window thumbnails, and recording. \(deferredPermissionSummaryText)"
    }

    private var deferredPermissionSummaryText: String {
        if capabilities.isEnabled(.connectedDeviceCapture) {
            return "Camera, Microphone, and System Audio are asked later only when their matching capture or recording source is used."
        }

        return "Microphone and System Audio are asked later only when their matching recording source is used."
    }

    private func shortcutRow(key: String, action: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                shortcutBadge(key)

                Text(AppBranding.branded(action))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                shortcutBadge(key)

                Text(AppBranding.branded(action))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutBadge(_ key: String) -> some View {
        Text(key)
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

    private var uiMapBinding: Binding<Bool> {
        Binding(
            get: { capture.uiMapEnabled },
            set: { newValue in
                capture.updateUIMapEnabled(newValue, requestAccessIfNeeded: false)
            }
        )
    }

    private var clipboardHistoryBinding: Binding<Bool> {
        Binding(
            get: { clipboard.preferences.isEnabled },
            set: { newValue in
                clipboard.updateClipboardHistoryEnabled(newValue)
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

    private var shouldIncludeAccessibilityPermissionInOnboarding: Bool {
        capabilities.isEnabled(.scrollingCapture)
            || capabilities.isEnabled(.guideCapture)
            || (capabilities.isEnabled(.uiMap) && capture.uiMapEnabled)
    }

    private var onboardingPermissionRequirements: [CapturePermissionRequirement] {
        var requirements: [CapturePermissionRequirement] = [.screenRecording]
        if shouldIncludeAccessibilityPermissionInOnboarding {
            requirements.append(.accessibility)
        }
        return requirements
    }

    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.visibleCases(for: capabilities)
    }

    private func sidebarStatus(for step: OnboardingStep) -> String? {
        switch step {
        case .welcome, .firstSnip, .discoverMore:
            return nil
        case .startup:
            return lifecycle.launchAtLoginStatus.stateLabel
        case .clipboard:
            if lifecycle.onboardingPresentationMode == .firstRun && !hasMadeClipboardChoice {
                return "Choose"
            }
            return clipboard.preferences.isEnabled ? "On" : "Off"
        case .captureAccess:
            return permissions.permissionStatus.hasScreenRecording ? "Allowed" : "Needs Setup"
        case .ready:
            return canCompleteOnboarding ? "Ready" : "Needs Setup"
        }
    }

    private var canBypassOnboarding: Bool {
        canCompleteOnboarding
    }

    private var canCompleteOnboarding: Bool {
        OnboardingCompletionPolicy.canComplete(
            mode: lifecycle.onboardingPresentationMode,
            hasScreenRecording: permissions.permissionStatus.hasScreenRecording,
            hasMadeClipboardChoice: hasMadeClipboardChoice
        )
    }

    private func refreshOnboardingPermissions() {
        permissions.refreshPermissions()
    }

    private func moveBack() {
        let steps = visibleSteps
        guard let currentIndex = steps.firstIndex(of: selectedStep),
              currentIndex > steps.startIndex else {
            return
        }

        selectedStep = steps[steps.index(before: currentIndex)]
    }

    private func moveForward() {
        let steps = visibleSteps
        guard let currentIndex = steps.firstIndex(of: selectedStep) else {
            completeOnboarding()
            return
        }

        let nextIndex = steps.index(after: currentIndex)
        if nextIndex < steps.endIndex {
            selectedStep = steps[nextIndex]
            return
        }

        completeOnboarding()
    }

    private func skipOnboarding() {
        guard canBypassOnboarding else {
            selectedStep = permissions.permissionStatus.hasScreenRecording ? .clipboard : .captureAccess
            return
        }

        skipOnboardingAction()
        dismiss()
    }

    private func restartAfterPermissionSetup() {
        lifecycle.saveOnboardingResumeCheckpoint(.firstSnip)
        AppTerminationController.shared.requestRestartWithoutConfirmation()
    }

    private func completeOnboarding() {
        guard canBypassOnboarding else {
            selectedStep = permissions.permissionStatus.hasScreenRecording ? .clipboard : .captureAccess
            return
        }

        completeOnboardingAction()
        dismiss()
    }

    private func acknowledgeClipboardChoice() {
        hasMadeClipboardChoice = true
        lifecycle.acknowledgeOnboardingClipboardChoice()
    }
}
