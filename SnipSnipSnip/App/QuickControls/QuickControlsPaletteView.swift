import SwiftUI

struct QuickControlsView: View {
    @ObservedObject private var quickControls: QuickControlsModel
    @ObservedObject private var lifecycle: AppLifecycleModel
    @ObservedObject private var capture: CaptureWorkflowModel
    @ObservedObject private var clipboard: ClipboardWorkflowModel
    @ObservedObject private var video: VideoWorkflowModel
    @ObservedObject private var guide: GuideWorkflowModel

    init(quickControls: QuickControlsModel) {
        self.quickControls = quickControls
        self.lifecycle = quickControls.lifecycle
        self.capture = quickControls.capture
        self.clipboard = quickControls.clipboard
        self.video = quickControls.video
        self.guide = quickControls.guide
    }

    var body: some View {
        let presentation = quickControls.preferences.resolvedDockState

        QuickControlsDockShell(
            presentation: presentation,
            edge: quickControls.preferences.resolvedDockEdge,
            status: quickControls.activeStatusLabel,
            statusSymbol: statusSymbol,
            togglePresentation: quickControls.toggleDockState
        ) {
            if quickControls.preferences.items.isEmpty {
                QuickControlsEmptyState(
                    presentation: presentation,
                    customize: quickControls.showCustomization
                )
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: presentation == .expanded ? 6 : 5) {
                        ForEach(QuickControlsDockGrouping.sections(for: quickControls.preferences.items)) { section in
                            QuickControlsDockSectionHeader(
                                category: section.category,
                                presentation: presentation
                            )
                            ForEach(section.items) { item in
                                control(for: item, presentation: presentation)
                            }
                        }
                    }
                    .padding(.horizontal, presentation == .expanded ? 8 : 3)
                    .padding(.top, QuickControlsDockMetrics.contentTopPadding)
                    .padding(.bottom, QuickControlsDockMetrics.contentBottomPadding)
                }
                .scrollIndicators(.hidden)
            }
        }
        .environmentObject(quickControls)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Controls")
        .accessibilityIdentifier("quickControls.palette")
    }

    @ViewBuilder
    private func control(for item: QuickControlItem, presentation: QuickControlsDockState) -> some View {
        let state = quickControls.tileState(for: item.kind)

        switch item.kind {
        case .capturePresets:
            Menu {
                CapturePresetMenuContent(capture: capture, video: video, lifecycle: lifecycle)
            } label: {
                QuickControlDockLabel(kind: item.kind, presentation: presentation, state: state)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .quickControlDockSurface(presentation: presentation, isOn: state.isOn)
            .disabled(quickControls.isDisabled(item.kind))
            .accessibilityLabel(item.kind.label)
            .help(item.kind.label)

        case .timer:
            Menu {
                CaptureTimerMenuContent(capture: capture)
            } label: {
                QuickControlDockLabel(kind: item.kind, presentation: presentation, state: state)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .quickControlDockSurface(presentation: presentation, isOn: state.isOn)
            .accessibilityLabel(item.kind.label)
            .help(capture.captureDelay.shortLabel)

        case .includeCursor:
            toggleButton(item.kind, presentation: presentation, state: state) {
                capture.screenshotIncludesCursor.toggle()
            }
        case .privateCapture:
            toggleButton(item.kind, presentation: presentation, state: state) {
                capture.updatePrivateCaptureEnabled(!capture.privateCaptureEnabled)
            }
        case .autoCopy:
            toggleButton(item.kind, presentation: presentation, state: state) {
                clipboard.autoCopyEnabled.toggle()
            }
        default:
            Button { quickControls.perform(item.kind) } label: {
                QuickControlDockLabel(kind: item.kind, presentation: presentation, state: state)
            }
            .buttonStyle(QuickControlDockButtonStyle(presentation: presentation, isOn: state.isOn))
            .disabled(quickControls.isDisabled(item.kind))
            .accessibilityLabel(item.kind.label)
            .help(item.kind.label)
        }
    }

    private func toggleButton(
        _ kind: QuickControlKind,
        presentation: QuickControlsDockState,
        state: QuickControlTileState,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            QuickControlDockLabel(kind: kind, presentation: presentation, state: state)
        }
        .buttonStyle(QuickControlDockButtonStyle(presentation: presentation, isOn: state.isOn))
        .disabled(quickControls.isDisabled(kind))
        .accessibilityLabel(kind.label)
        .accessibilityValue(state.isOn ? "On" : "Off")
        .help("\(kind.label): \(state.isOn ? "On" : "Off")")
    }

    private var statusSymbol: String {
        guide.isActive || video.blocksNewCapture ? "record.circle" : "hourglass"
    }
}
