import AppKit
import SwiftUI

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case uiMap
    case startup
    case support

    var id: Int { rawValue }

    static var visibleCases: [OnboardingStep] {
        allCases.filter { step in
            step != .uiMap || FeatureFlags.uiMapEnabled
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

    var summary: String {
        switch self {
        case .welcome:
            return "Capture faster, edit immediately, and keep recovery close by."
        case .permissions:
            if FeatureFlags.scrollingCaptureEnabled {
                return "Unlock capture pixels and scrolling capture with one-time macOS permissions."
            }

            return "Unlock capture pixels, live window thumbnails, and recording with one-time macOS permissions."
        case .uiMap:
            return "Choose whether screenshots save visible interface metadata."
        case .startup:
            return "Keep SnipSnipSnip ready right after login if you want the easiest setup."
        case .support:
            return "Find help fast and send support requests or feature requests through Discord."
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

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    @State private var selectedStep: OnboardingStep = .welcome
    @State private var launchAtLoginErrorMessage: String?

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
            model.refreshPermissions()
            model.refreshLaunchAtLoginStatus()
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
                model.openLaunchAtLoginSettings()
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

                Button("Skip for Now", action: skipOnboarding)
                    .buttonStyle(SSSChromeButtonStyle(tint: .white))
            }

            VStack(alignment: .leading, spacing: 14) {
                headerCopy(metrics: metrics)

                HStack {
                    Spacer(minLength: 0)

                    Button("Skip for Now", action: skipOnboarding)
                        .buttonStyle(SSSChromeButtonStyle(tint: .white))
                }
            }
        }
    }

    private func headerCopy(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome to SnipSnipSnip")
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
            ForEach(OnboardingStep.visibleCases) { step in
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

                            Text(step.summary)
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

            Text("Onboarding is skippable, and every step can be revisited later from Settings > General.")
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

                Text(selectedStep.summary)
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

                shortcutRow(key: "Command-Shift-1", action: "Capture a region")
                shortcutRow(key: "Command-Shift-2", action: "Capture a window")
                shortcutRow(key: "Command-Shift-3", action: "Capture fullscreen")
                shortcutRow(key: "Command-Shift-4", action: "Capture the frontmost window")
                shortcutRow(key: "Command-Shift-R", action: "Repeat the last capture")
            }
        }
    }

    private func permissionsStep(metrics: OnboardingLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.cardSpacing) {
            permissionCard(requirement: .screenRecording, metrics: metrics)
            if FeatureFlags.scrollingCaptureEnabled {
                permissionCard(requirement: .accessibility, metrics: metrics)
            }

            actionGroup {
                Button("Grant Missing Access", action: model.requestMissingCapturePermissions)
                    .buttonStyle(SSSChromeButtonStyle())

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
                Text("UI Map can save the names, roles, and locations of visible interface elements alongside screenshots you capture. This makes screenshots easier to search, inspect, document, and review for QA and accessibility.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Text("UI Map metadata is local to the screenshot document. It is used for inspection, search, documentation, accessibility review, and QA workflows. You can disable UI Map now or change this later in Settings.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Enable UI Map", isOn: uiMapBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)

                if model.uiMapNeedsAccessibilityAccess {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("UI Map needs Accessibility access before metadata can be captured.", systemImage: "lock.trianglebadge.exclamationmark.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)

                        Button("Grant Accessibility") {
                            model.requestAccessibilityAccess()
                        }
                        .buttonStyle(SSSChromeButtonStyle(tint: .orange))
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
                Toggle("Start SnipSnipSnip automatically when I log in", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
                    .controlSize(.large)

                HStack {
                    Label(model.launchAtLoginStatus.stateLabel, systemImage: model.launchAtLoginStatus.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(launchAtLoginColor)

                    Spacer(minLength: 12)
                }

                Text(model.launchAtLoginStatus.detail)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                if model.launchAtLoginStatus.needsSystemSettingsApproval || model.launchAtLoginStatus == .unavailable {
                    Button("Open Login Items in System Settings", action: model.openLaunchAtLoginSettings)
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

                Text("If SnipSnipSnip starts at login, the menu bar extra, capture shortcuts, and quick editor flow are already in place when you need them.")
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
                detail: "Join Discord for support requests, bug reports, and feature requests. That's the fastest way to reach the project.",
                systemImage: "bubble.left.and.bubble.right",
                metrics: metrics
            )

            actionGroup {
                Button("Open Help Guide") {
                    openWindow(id: AppSceneID.helpWindow)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(SSSChromeButtonStyle())

                Button("Join Discord") {
                    NSWorkspace.shared.open(AppLinks.supportDiscord)
                }
                .buttonStyle(SSSChromeButtonStyle(tint: .pink))

                Button("Open Website") {
                    NSWorkspace.shared.open(AppLinks.website)
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

                HStack(spacing: 10) {
                    Button("Skip", action: skipOnboarding)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                    Button(selectedStep == OnboardingStep.visibleCases.last ? "Open SnipSnipSnip" : "Continue", action: moveForward)
                        .buttonStyle(SSSChromeButtonStyle(tint: selectedStep.accent))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Button("Back", action: moveBack)
                    .buttonStyle(SSSChromeButtonStyle(tint: .secondary))
                    .disabled(selectedStep == .welcome)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button("Skip", action: skipOnboarding)
                        .buttonStyle(SSSChromeButtonStyle(tint: .secondary))

                    Button(selectedStep == OnboardingStep.visibleCases.last ? "Open SnipSnipSnip" : "Continue", action: moveForward)
                        .buttonStyle(SSSChromeButtonStyle(tint: selectedStep.accent))
                }
            }
        }
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
        let hasAccess = model.permissionStatus.hasAccess(to: requirement)

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    permissionHeader(requirement: requirement, hasAccess: hasAccess)

                    Spacer(minLength: 12)

                    permissionButton(requirement: requirement, hasAccess: hasAccess)
                }

                VStack(alignment: .leading, spacing: 12) {
                    permissionHeader(requirement: requirement, hasAccess: hasAccess)
                    permissionButton(requirement: requirement, hasAccess: hasAccess)
                }
            }

            Text(permissionDescription(for: requirement))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(metrics.featureCardPadding)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
        }
    }

    private func permissionHeader(requirement: CapturePermissionRequirement, hasAccess: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: requirement.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(hasAccess ? .green : .orange)
                .frame(width: 36, height: 36)
                .background((hasAccess ? Color.green : Color.orange).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(hasAccess ? "Granted" : "Missing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hasAccess ? .green : .orange)
            }
        }
    }

    private func permissionButton(requirement: CapturePermissionRequirement, hasAccess: Bool) -> some View {
        Button(hasAccess ? "Open Settings" : "Grant") {
            if hasAccess {
                model.openPermissionSettings(requirement)
            } else {
                model.requestPermission(requirement)
            }
        }
        .buttonStyle(SSSChromeButtonStyle(tint: hasAccess ? .secondary : .orange))
    }

    private func permissionDescription(for requirement: CapturePermissionRequirement) -> String {
        switch requirement {
        case .screenRecording:
            return "Required for capture pixels, live window thumbnails, fullscreen capture, and video recording."
        case .accessibility:
            return "Required only for Scrolling Capture so SnipSnipSnip can scroll the selected app while collecting segments."
        }
    }

    private var permissionsSummaryText: String {
        if FeatureFlags.scrollingCaptureEnabled {
            return "Screen Recording is required for pixels and live window thumbnails. Accessibility is only required for Scrolling Capture."
        }

        return "Screen Recording is required for pixels, live window thumbnails, and recording."
    }

    private func shortcutRow(key: String, action: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                shortcutBadge(key)

                Text(action)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
            }

            VStack(alignment: .leading, spacing: 8) {
                shortcutBadge(key)

                Text(action)
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
            get: { model.launchAtLoginStatus.prefersEnabledToggle },
            set: { newValue in
                let result = model.updateLaunchAtLoginEnabled(newValue)

                if case let .failed(message) = result {
                    launchAtLoginErrorMessage = message
                }
            }
        )
    }

    private var uiMapBinding: Binding<Bool> {
        Binding(
            get: { model.uiMapEnabled },
            set: { newValue in
                model.updateUIMapEnabled(newValue)
            }
        )
    }

    private var launchAtLoginColor: Color {
        switch model.launchAtLoginStatus {
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

    private func moveBack() {
        let steps = OnboardingStep.visibleCases
        guard let currentIndex = steps.firstIndex(of: selectedStep),
              currentIndex > steps.startIndex else {
            return
        }

        selectedStep = steps[steps.index(before: currentIndex)]
    }

    private func moveForward() {
        let steps = OnboardingStep.visibleCases
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
        model.skipOnboarding()
        dismiss()
    }

    private func completeOnboarding() {
        model.completeOnboarding()
        dismiss()
    }
}
