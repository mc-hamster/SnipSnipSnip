import SwiftUI

enum AppSceneID {
    static let mainWindow = "main-window"
    static let helpWindow = "help-window"
    static let layersWindow = "layers-window"
    static let uiMapWindow = "ui-map-window"
    static let onboardingWindow = "onboarding-window"
}

struct RegionCaptureSettingsMenuContent: View {
    @ObservedObject var capture: CaptureWorkflowModel

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
            get: { capture.regionCapturePreferences.overlayMode },
            set: { newValue in
                var preferences = capture.regionCapturePreferences
                preferences.overlayMode = newValue
                capture.regionCapturePreferences = preferences
            }
        )
    }

    private var autoCaptureBinding: Binding<Bool> {
        Binding(
            get: { capture.regionCapturePreferences.autoCapturesOnMouseUp },
            set: { newValue in
                var preferences = capture.regionCapturePreferences
                preferences.showsActionControls = !newValue
                if newValue {
                    preferences.advancedControlsEnabled = false
                }
                capture.regionCapturePreferences = preferences
            }
        )
    }
}

struct CaptureTimerMenuContent: View {
    @ObservedObject var capture: CaptureWorkflowModel

    var body: some View {
        ForEach(CaptureDelay.allCases) { delay in
            Toggle(delay.label, isOn: binding(for: delay))
        }
    }

    private func binding(for delay: CaptureDelay) -> Binding<Bool> {
        Binding(
            get: { capture.captureDelay == delay },
            set: { isSelected in
                if isSelected {
                    capture.captureDelay = delay
                }
            }
        )
    }
}

struct CapturePresetMenuContent: View {
    @ObservedObject var capture: CaptureWorkflowModel
    @ObservedObject var video: VideoWorkflowModel
    @ObservedObject var lifecycle: AppLifecycleModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if capture.capturePresets.isEmpty {
            Text("No Presets")
                .foregroundStyle(.secondary)
        } else {
            ForEach(capture.capturePresets.sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite && !rhs.isFavorite }
                return (lhs.lastRunAt ?? .distantPast) > (rhs.lastRunAt ?? .distantPast)
            }) { preset in
                Button {
                    capture.capturePreset(preset)
                } label: {
                    Label {
                        Text(preset.name + (preset.hotKey.map { "  ⌘⇧\($0.label)" } ?? ""))
                    } icon: {
                        CapturePresetBadge(preset: preset, size: 18)
                    }
                }
                .disabled(isCaptureActionDisabled)
            }
        }

        Divider()

        Button("Save Last Capture as Preset...", action: capture.beginSavingLastCaptureAsPreset)
            .disabled(!capture.canSaveLastCaptureAsPreset || isCaptureActionDisabled)

        Button("Manage Presets...") {
            lifecycle.selectedSettingsTab = .presets
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var isCaptureActionDisabled: Bool {
        capture.isWorking || video.blocksNewCapture || capture.isConnectedDeviceSessionActive
    }
}

struct ScreenshotCaptureSettingsMenuContent: View {
    @ObservedObject var capture: CaptureWorkflowModel

    var body: some View {
        Toggle("Include Cursor", isOn: $capture.screenshotIncludesCursor)
            .help("Add the cursor as an editable screenshot overlay. Scrolling Capture always excludes it.")

        if capture.dependencies.capabilities.isEnabled(.uiMap) {
            Toggle("Include UI Map for Window Captures", isOn: uiMapBinding)
                .help("Save available names, roles, identifiers, and locations of visible interface elements when capturing a window.")
        }
    }

    private var uiMapBinding: Binding<Bool> {
        Binding(
            get: { capture.uiMapEnabled },
            set: { capture.updateUIMapEnabled($0) }
        )
    }
}

enum ConnectedDeviceCaptureMenuMode {
    case screenshot
    case recording
}

struct ConnectedDeviceCaptureMenuContent: View {
    @ObservedObject var capture: CaptureWorkflowModel
    let mode: ConnectedDeviceCaptureMenuMode

    var body: some View {
        Group {
            if capture.isConnectedDeviceSessionActive {
                Button("Connected Device Preview Active", action: capture.presentConnectedDeviceSessionActiveMessage)
                    .help("Close the current connected-device preview before starting another connected-device session.")
            } else if capture.isLoadingConnectedDevices {
                Text("Looking for Devices...")
                    .foregroundStyle(.secondary)
            } else if capture.connectedDevices.isEmpty {
                Button(ConnectedDeviceCaptureMenu.emptyStateTitle, action: capture.presentConnectedDeviceEmptyState)
                    .help(capture.connectedDeviceEmptyStateMessage)
            } else {
                ForEach(capture.connectedDevices) { device in
                    Button(device.displayName) {
                        switch mode {
                        case .screenshot:
                            capture.captureConnectedDevice(device)
                        case .recording:
                            capture.recordConnectedDevice(device)
                        }
                    }
                    .disabled(capture.isConnectedDeviceSessionActive)
                    .help("Open a live connected-device preview. macOS may ask for Camera access because trusted iPhone and iPad screens are exposed as video sources.")
                }
            }

            Divider()

            Button("Refresh Devices", action: capture.refreshConnectedDevices)
                .disabled(capture.isLoadingConnectedDevices || capture.isConnectedDeviceSessionActive)
        }
        .onAppear {
            capture.refreshConnectedDevices()
        }
    }
}
