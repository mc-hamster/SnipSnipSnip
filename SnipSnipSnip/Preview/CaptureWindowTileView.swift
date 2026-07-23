import SwiftUI

struct CaptureWindowThumbnailView: View {
    let window: CaptureWindowSummary
    var thumbnailSize = CGSize(width: 116, height: 72)
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let thumbnail = window.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: "macwindow")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}

struct CaptureWindowTileView: View {
    let window: CaptureWindowSummary
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    CaptureWindowThumbnailView(
                        window: window,
                        thumbnailSize: CGSize(width: 228, height: 136),
                        cornerRadius: 14
                    )

                    Label("Capture", systemImage: "camera.viewfinder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: .capsule)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                        .padding(10)
                        .opacity(isHovering ? 1 : 0)
                        .offset(y: isHovering ? 0 : -6)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isHovering ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(window.displayTitle)
                        .font(.headline)
                        .foregroundStyle(isHovering ? Color.accentColor : .primary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                    }
                }
            }
            .frame(width: 228, alignment: .leading)
            .padding(14)
            .background(
                isHovering ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isHovering ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(CaptureWindowTileButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                isHovering = hovering
            }
        }
    }
}

private struct CaptureWindowTileButtonStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isHovering ? 1.01 : 1)
            .shadow(
                color: isHovering ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.045),
                radius: isHovering ? 14 : 8,
                y: isHovering ? 7 : 4
            )
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: configuration.isPressed)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovering)
    }
}
