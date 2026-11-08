import SwiftUI

/// Explicit, optional setup for UI Map. Rendering this view never requests access.
struct UIMapAccessView: View {
    @ObservedObject var permissions: PermissionWorkflowModel
    let capabilities: AppCapabilitySnapshot

    var body: some View {
        if capabilities.isEnabled(.uiMap) {
            VStack(alignment: .leading, spacing: 10) {
                Text("UI Map uses Accessibility to read visible controls and their locations during Window captures. Ordinary Region and Screen screenshots work without this access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PermissionStatusRow(requirement: .accessibility, permissions: permissions)

                if let guide = uiMapSetupGuide {
                    PermissionSetupView(permissions: permissions, guide: guide)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("permissions.uiMap")
        }
    }

    private var uiMapSetupGuide: PermissionSetupGuide? {
        guard var guide = permissions.permissionSetupGuide, guide.requirement == .accessibility else { return nil }
        if guide.featureName == nil { guide.featureName = "Window Capture with UI Map" }
        return guide
    }
}

/// Keep UI Map's preference observation local to its optional onboarding card.
struct UIMapOnboardingSetupView: View {
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var permissions: PermissionWorkflowModel
    let capabilities: AppCapabilitySnapshot

    var body: some View {
        if capabilities.isEnabled(.uiMap) {
            InsetGroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable UI Map for Window captures", isOn: Binding(
                        get: { capture.uiMapEnabled },
                        set: { capture.updateUIMapEnabled($0) }
                    ))
                    .accessibilityIdentifier("onboarding.uiMap.enabled")

                    Text("Optional. Enabling UI Map starts macOS Accessibility setup if access is needed. You can finish setup with UI Map turned off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    UIMapAccessView(permissions: permissions, capabilities: capabilities)
                }
            } label: {
                Label("UI Map Access", systemImage: "accessibility")
            }
            .accessibilityIdentifier("onboarding.uiMap")
        }
    }
}
