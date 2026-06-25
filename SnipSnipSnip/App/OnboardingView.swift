import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case uiMap
    case startup
    case support
    case permissions

    var id: Int { rawValue }

    static func visibleCases(for capabilities: AppCapabilitySnapshot) -> [OnboardingStep] {
        allCases.filter { step in
            step != .uiMap || capabilities.isEnabled(.uiMap)
        }
    }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .permissions:
            return "Permissions"
        case .uiMap:
            return "UI Map"
        case .startup:
            return "Launch at Login"
        case .support:
            return "Support"
        }
    }

    func summary(for capabilities: AppCapabilitySnapshot) -> String {
        switch self {
        case .welcome:
            return "Capture faster, edit immediately, and keep recovery close by."
        case .permissions:
            if capabilities.isEnabled(.scrollingCapture) {
                return "Set up capture pixels and scrolling capture, then see which permissions are asked later."
            }

            if capabilities.isEnabled(.uiMap) {
                return "Set up capture pixels, live window thumbnails, recording, and optional Window UI Map access."
            }

            if capabilities.isEnabled(.connectedDeviceCapture) {
                return "Set up capture pixels, live window thumbnails, recording, and learn when connected-device preview asks for Camera access."
            }

            return "Set up capture pixels, live window thumbnails, and recording with one-time macOS permissions."
        case .uiMap:
            return "Choose whether screenshots save visible interface metadata."
        case .startup:
            return "Keep \(AppBranding.displayName) ready right after login if you want the easiest setup."
        case .support:
            return "Find help fast and send support requests or feature requests from the support page."
        }
    }

    var accent: Color {
        switch self {
        case .welcome:
            return .teal
        case .permissions:
            return .orange
        case .uiMap:
            return .blue
        case .startup:
            return .green
        case .support:
            return .pink
        }
    }

    var symbol: String {
        switch self {
        case .welcome:
            return "sparkles"
        case .permissions:
            return "hand.raised.fill"
        case .uiMap:
            return "rectangle.3.group"
        case .startup:
            return "power.circle.fill"
        case .support:
            return "bubble.left.and.bubble.right.fill"
        }
    }
}

private struct OnboardingLayoutMetrics {
    let isCompactWidth: Bool
    let isCompactHeight: Bool
    let outerPadding: CGFloat
    let sectionSpacing: CGFloat
    let railWidth: CGFloat
    let contentPadding: CGFloat
    let cardSpacing: CGFloat
    let featureSpacing: CGFloat
    let primaryTitleSize: CGFloat
    let stepTitleSize: CGFloat
    let stepIconFrame: CGFloat
    let statusCardPadding: CGFloat
    let featureCardPadding: CGFloat

    init(size: CGSize) {
        isCompactWidth = size.width < 1_120
        isCompactHeight = size.height < 760
        outerPadding = isCompactWidth ? 20 : 28
        sectionSpacing = isCompactHeight ? 18 : 24
        railWidth = isCompactWidth ? 248 : 280
        contentPadding = (isCompactWidth || isCompactHeight) ? 22 : 28
        cardSpacing = isCompactHeight ? 18 : 24
        featureSpacing = isCompactWidth ? 12 : 16
        primaryTitleSize = isCompactWidth ? 30 : 34
        stepTitleSize = isCompactWidth ? 24 : 28
        stepIconFrame = isCompactWidth ? 58 : 68
        statusCardPadding = isCompactWidth ? 16 : 18
        featureCardPadding = isCompactWidth ? 16 : 18
    }
}

struct OnboardingView: View {
    private static let windowCornerRadius: CGFloat = 14

    @ObservedObject var lifecycle: AppLifecycleModel
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel
    private let capabilities: AppCapabilitySnapshot
    private let skipOnboardingAction: () -> Void
    private let completeOnboardingAction: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedStep: OnboardingStep = .welcome
    @State private var launchAtLoginErrorMessage: String?

    init(
        lifecycle: AppLifecycleModel,
        capture: CaptureWorkflowModel,
        permissions: PermissionWorkflowModel,
        capabilities: AppCapabilitySnapshot,
        skipOnboarding: @escaping () -> Void,
        completeOnboarding: @escaping () -> Void
    ) {
        self.lifecycle = lifecycle
        self.capture = capture
        self.permissions = permissions
        self.capabilities = capabilities
        self.skipOnboardingAction = skipOnboarding
        self.completeOnboardingAction = completeOnboarding
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingLayoutMetrics(size: proxy.size)

            ZStack {
                background

                VStack(spacing: metrics.sectionSpacing) {
                    header(metrics: metrics)

                    HStack(alignment: .top, spacing: metrics.featureSpacing + 4) {
                        stepRail(metrics: metrics)
                        contentCard(metrics: metrics)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)

                    footer
                }
                .padding(metrics.outerPadding)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous))
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

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.13, blue: 0.17),
                    Color(red: 0.05, green: 0.09, blue: 0.12),
                    Color(red: 0.10, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.teal.opacity(0.18))
                .frame(width: 360, height: 360)
                .offset(x: -320, y: -220)
                .blur(radius: 12)

            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 320, height: 320)
                .offset(x: 360, y: -180)
                .blur(radius: 10)

            Circle()
                .fill(Color.pink.opacity(0.16))
                .frame(width: 380, height: 380)
                .offset(x: 320, y: 260)
                .blur(radius: 16)
        }
        .ignoresSafeArea()
    }

    private func header(metrics: OnboardingLayoutMetrics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: metrics.featureSpacing + 4) {
                headerCopy(metrics: metrics)

                Spacer(minLength: 20)

                skipOnboardingButton
            }

            VStack(alignment: .leading, spacing: 14) {
                headerCopy(metrics: metrics)

                HStack {
                    Spacer(minLength: 0)

                    skipOnboardingButton
                }
            }
        }
    }

    @ViewBuilder
    private var skipOnboardingButton: some View {
        if canBypassOnboarding {
            Button("Skip for Now", action: skipOnboarding)
                .buttonStyle(SSSChromeButtonStyle(tint: .white))
        }
    }

    private func headerCopy(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to \(AppBranding.displayName)")
                .font(.system(size: metrics.primaryTitleSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("A short setup pass gets you from first launch to fast capture, editor workflows, and support without hunting through menus.")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepRail(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleSteps) { step in
                Button {
                    selectedStep = step
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: step.symbol)
                            .font(.headline.weight(.semibold))
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title)
                                .font(.headline.weight(.semibold))

                            Text(step.summary(for: capabilities))
                                .font(metrics.isCompactHeight ? .caption : .footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: step.accent, isSelected: selectedStep == step))
            }

            Spacer(minLength: 0)

            onboardingStatusCard(metrics: metrics)
        }
        .frame(width: metrics.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func onboardingStatusCard(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ready When You Are", systemImage: "scissors")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text("After Screen Recording is set up, onboarding can be skipped and every step can be revisited later from Settings > General.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.statusCardPadding)
        .sssGlassSurface(cornerRadius: 20, tint: .white.opacity(0.08), shadowOpacity: 0.18)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
    }

    private func contentCard(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            currentStepHeader(metrics: metrics)

            ScrollView(.vertical, showsIndicators: true) {
                currentStepContent(metrics: metrics)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(metrics.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04))
        .sssGlassSurface(cornerRadius: 28, tint: .white.opacity(0.08), shadowOpacity: 0.22)
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
        }
    }

    private func currentStepHeader(metrics: OnboardingLayoutMetrics) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: selectedStep.symbol)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(selectedStep.accent)
                .frame(width: metrics.stepIconFrame, height: metrics.stepIconFrame)
                .background(selectedStep.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(selectedStep.title)
                    .font(.system(size: metrics.stepTitleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(selectedStep.summary(for: capabilities))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func currentStepContent(metrics: OnboardingLayoutMetrics) -> some View {
        switch selectedStep {
        case .welcome:
            welcomeStep(metrics: metrics)
        case .permissions:
            permissionsStep(metrics: metrics)
        case .uiMap:
            uiMapStep(metrics: metrics)
        case .startup:
            startupStep(metrics: metrics)
        case .support:
            supportStep(metrics: metrics)
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
                    .foregroundStyle(.white)

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
            if shouldIncludeAccessibilityPermissionInOnboarding {
                permissionCard(requirement: .accessibility, metrics: metrics)
            }

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
                        .buttonStyle(SSSChromeButtonStyle(tint: .orange))
                } else {
                    Button("Set Up Next") {
                        permissions.requestNextMissingSetupRequirement(in: onboardingPermissionRequirements)
                    }
                    .buttonStyle(SSSChromeButtonStyle())
                    .disabled(permissions.activePermissionRequest != nil)
                }

                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            }

            Text(permissionsSummaryText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func uiMapStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            VStack(alignment: .leading, spacing: 14) {
                Text("UI Map works with Window capture. It can save available names, roles, identifiers, and locations from the selected window alongside the screenshot.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Text("UI Map metadata stays local to the screenshot document and is used for inspection, search, documentation, accessibility review, and QA workflows. You can disable it now or change this later in Settings.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable UI Map for Window captures", isOn: uiMapBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)

                if capture.windowUIMapNeedsAccessibilityAccess {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Window UI Map will add Accessibility to the next permissions step.", systemImage: "lock.trianglebadge.exclamationmark.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.75)
                    }
                }
            }
            .padding(metrics.contentPadding)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
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
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                if lifecycle.launchAtLoginStatus.needsSystemSettingsApproval || lifecycle.launchAtLoginStatus == .unavailable {
                    Button("Open Login Items in System Settings", action: lifecycle.openLaunchAtLoginSettings)
                        .buttonStyle(SSSChromeButtonStyle(tint: .orange))
                }
            }
            .padding(metrics.contentPadding)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Why turn it on?")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text("If \(AppBranding.displayName) starts at login, the menu bar extra, capture shortcuts, and quick editor flow are already in place when you need them.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
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
                .buttonStyle(SSSChromeButtonStyle())

                Button("Open Support Page") {
                    openURL(AppLinks.support)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .pink))

                Button("Open Website") {
                    openURL(AppLinks.website)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
            }

            Text("You can replay this onboarding from Settings > General whenever you want the guided tour again.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Button("Back", action: moveBack)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .disabled(selectedStep == .welcome)

                Spacer(minLength: 16)

                Button(AppBranding.branded(primaryFooterTitle), action: primaryFooterAction)
                    .buttonStyle(SSSChromeButtonStyle(tint: selectedStep.accent))
                    .disabled(isPrimaryFooterDisabled)
            }

            VStack(alignment: .leading, spacing: 12) {
                Button("Back", action: moveBack)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .disabled(selectedStep == .welcome)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(AppBranding.branded(primaryFooterTitle), action: primaryFooterAction)
                        .buttonStyle(SSSChromeButtonStyle(tint: selectedStep.accent))
                        .disabled(isPrimaryFooterDisabled)
                }
            }
        }
    }

    private var primaryFooterTitle: String {
        if selectedStep == .permissions,
           permissions.screenRecordingSetupNeedsAttention,
           permissions.activePermissionRequest != nil {
            return "Waiting for Settings"
        }

        if selectedStep == .permissions,
           permissions.screenRecordingSetupNeedsAttention {
            return "Restart SnipSnipSnip"
        }

        if selectedStep == .permissions,
           !permissions.permissionStatus.hasScreenRecording {
            return "Set Up Screen Recording"
        }

        return selectedStep == visibleSteps.last ? "Open SnipSnipSnip" : "Next"
    }

    private var isPrimaryFooterDisabled: Bool {
        selectedStep == .permissions && permissions.activePermissionRequest != nil
    }

    private func primaryFooterAction() {
        if selectedStep == .permissions,
           permissions.screenRecordingSetupNeedsAttention {
            restartAfterPermissionSetup()
            return
        }

        if selectedStep == .permissions,
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
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.featureCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
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

        return VStack(alignment: .leading, spacing: 12) {
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
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)

            if let followUpText = permissionFollowUpText(for: requirement, isWaiting: isWaiting, needsAttention: needsAttention) {
                Label(followUpText, systemImage: needsAttention ? "arrow.clockwise.circle.fill" : "gearshape.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(needsAttention ? .orange : .white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(metrics.featureCardPadding)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
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
                    .foregroundStyle(.white)

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
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                }

                VStack(alignment: .leading, spacing: 10) {
                    checkAgainButton(tint: .orange)
                    Button("Open Settings") {
                        permissions.openPermissionSettings(requirement)
                    }
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                }
            }
        } else {
            Button("Set Up") {
                permissions.requestPermission(requirement)
            }
            .buttonStyle(SSSChromeButtonStyle(tint: .orange))
            .disabled(permissions.activePermissionRequest != nil)
        }
    }

    private func restartPermissionButton() -> some View {
        Button(AppBranding.branded("Restart SnipSnipSnip"), action: restartAfterPermissionSetup)
            .buttonStyle(SSSChromeButtonStyle(tint: .orange))
    }

    private func checkAgainButton(tint: Color) -> some View {
        Button("Check Again") {
            permissions.checkPermissionSetupGuideStatus()
        }
        .buttonStyle(SSSChromeButtonStyle(tint: tint))
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Asked Only When Used")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Text("These do not appear during onboarding. macOS asks later if you enable the matching workflow.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
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
        .padding(metrics.featureCardPadding)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
        }
    }

    private func deferredPermissionRow(title: String, detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.white.opacity(0.82))
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
                    .foregroundStyle(.white.opacity(0.78))
            }

            VStack(alignment: .leading, spacing: 8) {
                shortcutBadge(key)

                Text(AppBranding.branded(action))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
    }

    private func shortcutBadge(_ key: String) -> some View {
        Text(key)
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var canBypassOnboarding: Bool {
        permissions.permissionStatus.hasScreenRecording
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
            selectedStep = .permissions
            return
        }

        skipOnboardingAction()
        dismiss()
    }

    private func restartAfterPermissionSetup() {
        completeOnboardingAction()
        AppTerminationController.shared.requestRestartWithoutConfirmation()
    }

    private func completeOnboarding() {
        guard canBypassOnboarding else {
            selectedStep = .permissions
            return
        }

        completeOnboardingAction()
        dismiss()
    }
}
