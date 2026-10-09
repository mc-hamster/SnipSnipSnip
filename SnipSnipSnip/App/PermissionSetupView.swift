import SwiftUI

/// Recovery after requesting access. This is not a replacement for the macOS
/// consent alert; only the system can grant permission.
struct PermissionSetupView: View {
    @ObservedObject var permissions: PermissionWorkflowModel
    let guide: PermissionSetupGuide
    var showsPrimaryAction = true
    var onContinue: (() -> Void)? = nil
    var onRestart: () -> Void = {
        AppTerminationController.shared.requestRestartWithoutConfirmation()
    }
    @State private var showsTroubleshooting = false

    private var requiresRestart: Bool {
        guide.requirement == .screenRecording && permissions.screenRecordingSetupNeedsAttention
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(guide.requirement.title): \(permissions.statusTitle(for: guide.requirement))", systemImage: requiresRestart ? "arrow.clockwise.circle" : guide.requirement.systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("permissions.setup.status")

            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(permissions.canContinueOperation
                 ? "Access is ready. Choose Continue to resume \(permissions.permissionContinuation?.featureName ?? "capture")."
                 : requiresRestart
                 ? "Access has changed. Restart to finish applying it to this running copy."
                 : "In System Settings, open Privacy & Security > \(guide.requirement.settingsPaneTitle) and turn on \(guide.appName). Access updates automatically when macOS makes it available.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }

            DisclosureGroup("Troubleshooting", isExpanded: $showsTroubleshooting) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If the app is missing from the list, add this copy using the + button in System Settings.")
                    Text(guide.appPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Reveal App", action: permissions.revealAppForPermissionSetup)
                        Button("Copy Path", action: permissions.copyAppPathForPermissionSetup)
                    }
                }
                .font(.callout)
                .padding(.top, 8)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissions.setup")
    }

    @ViewBuilder private var actions: some View {
        if showsPrimaryAction {
            if permissions.canContinueOperation {
                Button("Continue", action: onContinue ?? permissions.continueOperation)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permissions.setup.continue")
            } else if requiresRestart {
                Button("Restart \(AppBranding.displayName)", action: onRestart)
                    .buttonStyle(.borderedProminent)
            } else if permissions.activePermissionRequest == nil && permissions.permissionContinuation != nil {
                Button("Set Up \(guide.requirement.title)", action: permissions.continueOperation)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") { permissions.openPermissionSettings(guide.requirement) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("permissions.setup.openSettings")
            }
        }
        Button(permissions.isCheckingPermission ? "Checking…" : "Check Again", action: permissions.checkPermissionSetupGuideStatus)
            .disabled(permissions.isCheckingPermission)
            .accessibilityIdentifier("permissions.setup.checkAgain")
        if let title = permissions.permissionContinuation?.alternativeTitle,
           let action = permissions.permissionContinuation?.alternative {
            Button(title, action: action)
                .accessibilityIdentifier("permissions.setup.alternative")
        }
        Button("Cancel Setup", action: permissions.dismissPermissionSetupGuide)
            .accessibilityIdentifier("permissions.setup.cancel")
    }

    private var explanation: String {
        if guide.requirement == .screenRecording {
            return "\(AppBranding.displayName) needs Screen Recording access to capture screen pixels and record Video."
        }
        switch guide.featureName {
        case "Guide":
            return "Guide uses Accessibility to observe clicks and keyboard focus while you capture a workflow."
        case "Window Capture with UI Map":
            return "UI Map uses Accessibility to read visible controls and their locations in the selected window."
        case "Scrolling Capture":
            return "Scrolling Capture uses Accessibility to scroll the selected app while capturing its content."
        default:
            return "Accessibility enables Scrolling Capture, UI Map, Guide, and optional keyboard-shortcut recording. Ordinary Region and Screen capture work without it."
        }
    }
}
