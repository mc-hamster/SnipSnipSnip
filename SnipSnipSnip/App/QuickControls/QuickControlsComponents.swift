import AppKit
import SwiftUI

struct QuickControlsDockShell<Content: View>: View {
    let presentation: QuickControlsDockState
    let edge: QuickControlsDockEdge
    let status: String?
    let statusSymbol: String
    let collapse: () -> Void
    var headerAtBottom = false
    var allowsWindowDragging = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !headerAtBottom {
                header
            }
            if presentation != .iconOnly {
                if !headerAtBottom {
                    Divider().opacity(0.65)
                }
                content
                if headerAtBottom {
                    Divider().opacity(0.65)
                }
            }
            if headerAtBottom {
                header
            }
        }
        .sssFloatingOverlaySurface(
            cornerRadius: QuickControlsDockMetrics.panelCornerRadius,
            isInteractive: true,
            shadowOpacity: 0.16
        )
        .padding(QuickControlsDockMetrics.panelInset)
    }

    private var header: some View {
        QuickControlsDockHeader(
            presentation: presentation,
            edge: edge,
            status: status,
            statusSymbol: statusSymbol,
            collapse: collapse,
            allowsWindowDragging: allowsWindowDragging
        )
    }
}

private struct QuickControlsDockHeader: View {
    let presentation: QuickControlsDockState
    let edge: QuickControlsDockEdge
    let status: String?
    let statusSymbol: String
    let collapse: () -> Void
    let allowsWindowDragging: Bool

    var body: some View {
        HStack(spacing: 0) {
            if presentation != .full || edge == .left {
                logo
            }
            if presentation == .full {
                if edge == .left { collapseButton }
                title
                if edge == .right {
                    collapseButton
                    logo
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: presentation == .slim
            ? QuickControlsDockMetrics.compactHeaderHeight
            : QuickControlsDockMetrics.expandedHeaderHeight)
        .background(.background.opacity(0.24))
    }

    private var logo: some View {
        QuickControlsLogo(allowsWindowDragging: allowsWindowDragging, status: status)
            .frame(width: QuickControlsDockMetrics.logoHitWidth)
            .frame(maxHeight: .infinity)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Quick Controls")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let status {
                Label(status, systemImage: statusSymbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .overlay {
            if allowsWindowDragging {
                QuickControlsWindowDragTarget()
                    .help("Drag to Move Quick Controls")
                    .accessibilityHidden(true)
            }
        }
    }

    private var collapseButton: some View {
        Button(action: collapse) {
            Image(systemName: edge == .right ? "chevron.right" : "chevron.left")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Collapse Quick Controls")
        .accessibilityLabel("Collapse Quick Controls")
    }
}

private struct QuickControlsLogo: NSViewRepresentable {
    @EnvironmentObject private var quickControls: QuickControlsModel
    let allowsWindowDragging: Bool
    let status: String?

    func makeNSView(context: Context) -> QuickControlsLogoButton {
        let button = QuickControlsLogoButton()
        let image = NSApp.applicationIconImage.copy() as? NSImage
        image?.size = CGSize(width: 28, height: 28)
        button.image = image
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = button
        button.action = #selector(QuickControlsLogoButton.cycleMode)
        button.toolTip = String(localized: "Click to switch Quick Controls modes. Right-click for the menu.")
        button.setAccessibilityIdentifier("quickControls.logo")
        button.setAccessibilityLabel(String(localized: "Quick Controls Logo"))
        return button
    }

    func updateNSView(_ button: QuickControlsLogoButton, context: Context) {
        button.quickControls = quickControls
        button.allowsWindowDragging = allowsWindowDragging
        let mode = quickControls.preferences.resolvedDockState.label
        button.setAccessibilityValue(status.map { "\(mode), \($0)" } ?? mode)
    }
}

// The native button keeps click, keyboard, and VoiceOver activation available
// while handing off an actual drag to the window server after a movement threshold.
final class QuickControlsLogoButton: NSButton {
    weak var quickControls: QuickControlsModel?
    var allowsWindowDragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc func cycleMode() {
        quickControls?.cycleDockState()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        guard allowsWindowDragging, let window else {
            super.mouseDown(with: event)
            return
        }

        highlight(true)
        defer { highlight(false) }
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { nextEvent, stop in
            guard let nextEvent else {
                stop.pointee = true
                return
            }
            if nextEvent.type == .leftMouseUp {
                stop.pointee = true
                if bounds.contains(convert(nextEvent.locationInWindow, from: nil)) {
                    cycleMode()
                }
            } else {
                let current = nextEvent.locationInWindow
                let start = event.locationInWindow
                if hypot(current.x - start.x, current.y - start.y) >= 4 {
                    stop.pointee = true
                    window.performDrag(with: event)
                }
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift),
           event.charactersIgnoringModifiers?.utf16.first == UInt16(NSF10FunctionKey),
           accessibilityPerformShowMenu() {
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = makeContextMenu(), window != nil else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.minY), in: self)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    private func showContextMenu(with event: NSEvent) {
        guard let menu = makeContextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func makeContextMenu() -> NSMenu? {
        guard let quickControls else { return nil }
        let menu = NSMenu()
        for mode in QuickControlsDockState.allCases {
            let item = addItem(mode.label, action: #selector(selectMode(_:)), to: menu)
            item.representedObject = mode.rawValue
            item.state = quickControls.preferences.resolvedDockState == mode ? .on : .off
        }
        menu.addItem(.separator())
        addItem(String(localized: "Customize Quick Controls…"), action: #selector(customize), to: menu)
        menu.addItem(.separator())
        addItem(String(localized: "Open \(AppBranding.displayName)"), action: #selector(openApplication), to: menu)
        addItem(String(localized: "Hide Quick Controls"), action: #selector(hide), to: menu)
        return menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectMode(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String,
              let mode = QuickControlsDockState(rawValue: value) else { return }
        quickControls?.setDockState(mode)
    }

    @objc private func customize() { quickControls?.showCustomization() }
    @objc private func openApplication() { quickControls?.perform(.openApplication) }
    @objc private func hide() { quickControls?.setVisible(false) }
}

// Keep the window drag target over the non-button part of the Full header.
private struct QuickControlsWindowDragTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> QuickControlsWindowDragView {
        QuickControlsWindowDragView()
    }

    func updateNSView(_ nsView: QuickControlsWindowDragView, context: Context) {}
}

final class QuickControlsWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

struct QuickControlsDockSectionHeader: View {
    let category: QuickControlCategory
    let presentation: QuickControlsDockState

    var body: some View {
        if presentation == .full {
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
        if presentation == .full { expandedContent } else { compactContent }
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
            .frame(maxWidth: presentation == .full ? .infinity : nil)
            .frame(
                width: presentation == .slim ? QuickControlsDockMetrics.compactControlSize : nil,
                height: presentation == .slim ? QuickControlsDockMetrics.compactControlSize : QuickControlsDockMetrics.expandedControlHeight
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
            if presentation == .full {
                Text("No Controls").font(.subheadline.weight(.semibold))
                Text("Add controls in customization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let customize {
                Button(presentation == .full ? "Customize" : "Add", action: customize)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }
}
