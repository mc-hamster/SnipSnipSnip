import AppKit
import SwiftUI

extension CapturePreset {
    var resolvedSymbolName: String {
        symbolName ?? "camera.viewfinder"
    }
}

extension CapturePresetTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .gray: .gray
        }
    }

    var appKitColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .green: .systemGreen
        case .gray: .systemGray
        }
    }
}

struct CapturePresetBadge: View {
    let symbolName: String
    let tint: CapturePresetTint
    var size: CGFloat = 24

    init(symbolName: String?, tint: CapturePresetTint, size: CGFloat = 24) {
        self.symbolName = symbolName ?? "camera.viewfinder"
        self.tint = tint
        self.size = size
    }

    init(preset: CapturePreset, size: CGFloat = 24) {
        self.init(symbolName: preset.symbolName, tint: preset.tint, size: size)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(size * 0.28, 4), style: .continuous)
                .fill(tint.color.opacity(0.18))

            Image(systemName: symbolName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(tint.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CapturePresetTintLabel: View {
    let tint: CapturePresetTint
    let symbolName: String?

    var body: some View {
        HStack(spacing: 6) {
            CapturePresetBadge(symbolName: symbolName, tint: tint, size: 18)
            Text(tint.label)
        }
    }
}

@MainActor
func capturePresetMenuImage(for preset: CapturePreset, size: CGFloat = 18) -> NSImage? {
    guard let baseImage = NSImage(
        systemSymbolName: preset.resolvedSymbolName,
        accessibilityDescription: preset.name
    )?.withSymbolConfiguration(.init(pointSize: size * 0.58, weight: .semibold)) else {
        return nil
    }

    let tintedSymbol = (baseImage.copy() as? NSImage) ?? baseImage
    tintedSymbol.lockFocus()
    preset.tint.appKitColor.set()
    NSRect(origin: .zero, size: tintedSymbol.size).fill(using: .sourceAtop)
    tintedSymbol.unlockFocus()
    tintedSymbol.isTemplate = false

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let bounds = NSRect(origin: .zero, size: image.size)
    preset.tint.appKitColor.withAlphaComponent(0.18).setFill()
    NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
        xRadius: max(size * 0.28, 4),
        yRadius: max(size * 0.28, 4)
    ).fill()

    let symbolSize = tintedSymbol.size
    tintedSymbol.draw(
        at: NSPoint(
            x: (bounds.width - symbolSize.width) / 2,
            y: (bounds.height - symbolSize.height) / 2
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    image.unlockFocus()
    image.isTemplate = false
    return image
}
