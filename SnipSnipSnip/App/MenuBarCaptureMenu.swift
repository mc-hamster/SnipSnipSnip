import SwiftUI

enum AppSceneID {
    static let mainWindow = "main-window"
    static let helpWindow = "help-window"
    static let onboardingWindow = "onboarding-window"
}

struct RegionCaptureSettingsMenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("Region Capture Overlay", selection: overlayModeBinding) {
            ForEach(RegionCaptureOverlayMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .help("Choose whether region capture shows a full-screen crosshair, the magnifying glass, or both during region capture.")

        Toggle("Always Capture on Mouse Up", isOn: autoCaptureBinding)
            .help("Capture the selected region immediately when you release the mouse instead of showing Capture and Cancel buttons.")
    }

    private var overlayModeBinding: Binding<RegionCaptureOverlayMode> {
        Binding(
            get: { model.regionCapturePreferences.overlayMode },
            set: { newValue in
                var preferences = model.regionCapturePreferences
                preferences.overlayMode = newValue
                model.regionCapturePreferences = preferences
            }
        )
    }

    private var autoCaptureBinding: Binding<Bool> {
        Binding(
            get: { model.regionCapturePreferences.autoCapturesOnMouseUp },
            set: { newValue in
                var preferences = model.regionCapturePreferences
                preferences.showsActionControls = !newValue
                model.regionCapturePreferences = preferences
            }
        )
    }
}

struct CaptureTimerMenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ForEach(CaptureDelay.allCases) { delay in
            Toggle(delay.label, isOn: binding(for: delay))
        }
    }

    private func binding(for delay: CaptureDelay) -> Binding<Bool> {
        Binding(
            get: { model.captureDelay == delay },
            set: { isSelected in
                if isSelected {
                    model.captureDelay = delay
                }
            }
        )
    }
}

struct ScreenshotCaptureSettingsMenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle("Include Cursor", isOn: $model.screenshotIncludesCursor)
            .help("Add the cursor as an editable screenshot overlay. Scrolling Capture always excludes it.")
    }
}

enum ConnectedDeviceCaptureMenuMode {
    case screenshot
    case recording
}

struct ConnectedDeviceCaptureMenuContent: View {
    @ObservedObject var model: AppModel
    let mode: ConnectedDeviceCaptureMenuMode

    var body: some View {
        if model.isLoadingConnectedDevices {
            Text("Looking for Devices...")
                .foregroundStyle(.secondary)
        } else if model.connectedDevices.isEmpty {
            Button(ConnectedDeviceCaptureMenu.emptyStateTitle, action: model.presentConnectedDeviceEmptyState)
                .help(model.connectedDeviceEmptyStateMessage)
        } else {
            ForEach(model.connectedDevices) { device in
                Button(device.displayName) {
                    switch mode {
                    case .screenshot:
                        model.captureConnectedDevice(device)
                    case .recording:
                        model.recordConnectedDevice(device)
                    }
                }
                .disabled(model.isConnectedDeviceSessionActive)
            }
        }

        Divider()

        Button("Refresh Devices", action: model.refreshConnectedDevices)
            .disabled(model.isLoadingConnectedDevices || model.isConnectedDeviceSessionActive)
    }
}
