import AppKit
import SwiftUI

struct QuickControlsDockShell<Content: View>: View {
    let presentation: QuickControlsDockState
    let edge: QuickControlsDockEdge
    let status: String?
    let statusSymbol: String
    let togglePresentation: () -> Void
    @ViewBuilder let content: Content

    init(
        presentation: QuickControlsDockState,
        edge: QuickControlsDockEdge,
        status: String?,
        statusSymbol: String,
        togglePresentation: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.edge = edge
        self.status = status
        self.statusSymbol = statusSymbol
        self.togglePresentation = togglePresentation
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickControlsDockHeader(
                presentation: presentation,
                edge: edge,
                status: status,
                statusSymbol: statusSymbol,
                togglePresentation: togglePresentation
            )

            Divider().opacity(0.65)
            content
        }
        .background(Color.clear)
        .sssFloatingOverlaySurface(
            cornerRadius: QuickControlsDockMetrics.panelCornerRadius,
            isInteractive: true,
            shadowOpacity: 0.16
        )
        .padding(QuickControlsDockMetrics.panelInset)
    }
}

struct QuickControlsDockHeader: View {
    let presentation: QuickControlsDockState
    let edge: QuickControlsDockEdge
    let status: String?
    let statusSymbol: String
    let togglePresentation: () -> Void

    var body: some View {
        Group {
            if presentation == .expanded { expandedHeader } else { compactHeader }
        }
        .frame(
            height: presentation == .expanded
                ? QuickControlsDockMetrics.expandedHeaderHeight
                : QuickControlsDockMetrics.compactHeaderHeight
        )
        .background(.background.opacity(0.24))
    }

    private var expandedHeader: some View {
        HStack(spacing: 7) {
            brandMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Quick Controls")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let status {
                    Label(status, systemImage: statusSymbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: togglePresentation) {
                Image(systemName: edge == .right ? "chevron.right" : "chevron.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse Quick Controls")
            .accessibilityLabel("Collapse Quick Controls")
            QuickControlsDockMenu()
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
    }

    private var compactHeader: some View {
        HStack(spacing: 2) {
            if edge == .right {
                expandButton
            }
            brandMark(size: 23, showsStatus: true)
            if edge == .left {
                expandButton
            }
        }
        .padding(.horizontal, 1)
    }

    private var expandButton: some View {
        Button(action: togglePresentation) {
            Image(systemName: edge == .right ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 21, height: 28)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(status.map { "\($0). Expand Quick Controls" } ?? "Expand Quick Controls")
        .accessibilityLabel("Expand Quick Controls")
        .accessibilityValue(status ?? "Ready")
    }

    private func brandMark(size: CGFloat, showsStatus: Bool = false) -> some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if showsStatus, status != nil {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                }
            }
            .accessibilityHidden(true)
            .help("Drag to Move Quick Controls")
    }
}

private struct QuickControlsDockMenu: View {
    @EnvironmentObject private var quickControls: QuickControlsModel

    var body: some View {
        Menu {
            Button(
                quickControls.preferences.resolvedDockState == .expanded
                    ? "Collapse Quick Controls"
                    : "Expand Quick Controls"
            ) { quickControls.toggleDockState() }
            Button("Customize Quick Controls…", action: quickControls.showCustomization)
            Divider()
            Button("Open \(AppBranding.displayName)") { quickControls.perform(.openApplication) }
            Button("Hide Quick Controls") { quickControls.setVisible(false) }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Quick Controls Menu")
    }
}

struct QuickControlsDockSectionHeader: View {
    let category: QuickControlCategory
    let presentation: QuickControlsDockState

    var body: some View {
        if presentation == .expanded {
            HStack(spacing: 7) {
                Text(category.label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                Rectangle().fill(.separator).frame(height: 0.5)
            }
            .padding(.top, 7)
            .padding(.horizontal, 3)
            .frame(height: QuickControlsDockMetrics.expandedSectionHeight)
            .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(.separator)
                .frame(width: 22, height: 0.5)
                .frame(height: QuickControlsDockMetrics.compactSectionHeight)
                .accessibilityHidden(true)
        }
    }
}

struct QuickControlDockLabel: View {
    let kind: QuickControlKind
    let presentation: QuickControlsDockState
    var state: QuickControlTileState

    init(kind: QuickControlKind, presentation: QuickControlsDockState, state: QuickControlTileState = .init()) {
        self.kind = kind
        self.presentation = presentation
        self.state = state
    }

    var body: some View {
        if presentation == .expanded { expandedContent } else { compactContent }
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.label).font(.caption.weight(.semibold)).lineLimit(1)
                Text(state.detail ?? kind.intentDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else if state.isOn {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: QuickControlsDockMetrics.expandedControlHeight)
    }

    private var compactContent: some View {
        ZStack(alignment: .topTrailing) {
            icon.frame(width: QuickControlsDockMetrics.compactControlSize, height: QuickControlsDockMetrics.compactControlSize)
            if state.showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if kind.category == .record {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: kind.systemImage).symbolRenderingMode(.monochrome)
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.background, lineWidth: 1))
            }
            .foregroundStyle(Color.red)
            .font(.system(size: 16, weight: .semibold))
        } else {
            Image(systemName: kind.systemImage)
                .symbolVariant(.none)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 16, weight: .medium))
        }
    }

}

struct QuickControlDockButtonStyle: ButtonStyle {
    let presentation: QuickControlsDockState
    let isOn: Bool
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .quickControlDockSurface(presentation: presentation, isOn: isOn, isSelected: isSelected)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct QuickControlDockSurfaceModifier: ViewModifier {
    let presentation: QuickControlsDockState
    let isOn: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: presentation == .expanded ? .infinity : nil)
            .frame(
                width: presentation == .compact ? QuickControlsDockMetrics.compactControlSize : nil,
                height: presentation == .compact ? QuickControlsDockMetrics.compactControlSize : QuickControlsDockMetrics.expandedControlHeight
            )
            .contentShape(RoundedRectangle(cornerRadius: QuickControlsDockMetrics.controlCornerRadius, style: .continuous))
            .background(
                isOn || isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: QuickControlsDockMetrics.controlCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: QuickControlsDockMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(
                        isOn || isSelected ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.11),
                        lineWidth: isSelected ? 2 : 0.75
                    )
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
    }
}

extension View {
    func quickControlDockSurface(
        presentation: QuickControlsDockState,
        isOn: Bool,
        isSelected: Bool = false
    ) -> some View {
        modifier(QuickControlDockSurfaceModifier(presentation: presentation, isOn: isOn, isSelected: isSelected))
    }
}

struct QuickControlsEmptyState: View {
    let presentation: QuickControlsDockState
    var customize: (() -> Void)?

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            if presentation == .expanded {
                Text("No Controls").font(.subheadline.weight(.semibold))
                Text("Add controls in customization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let customize {
                Button(presentation == .expanded ? "Customize" : "Add", action: customize)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }
}
