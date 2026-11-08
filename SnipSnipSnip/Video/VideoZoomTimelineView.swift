import SwiftUI

struct VideoZoomTimelineView: View {
    @ObservedObject var controller: VideoEditorController

    var body: some View {
        if !controller.session.effects.zooms.isEmpty || !controller.session.removedRanges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zooms & Removed Sections").font(.caption).foregroundStyle(.secondary)
                GeometryReader { proxy in
                    let duration = max(controller.recording.duration, 0.1)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.quaternary)
                        ForEach(controller.session.effects.zooms) { zoom in
                            Button {
                                controller.selectZoom(zoom.id)
                            } label: {
                                Label("\(zoom.scale, specifier: "%.1f")×", systemImage: "plus.magnifyingglass")
                                    .font(.caption2).lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .frame(width: max((zoom.end - zoom.start) / duration * proxy.size.width, 8))
                            .offset(x: zoom.start / duration * proxy.size.width)
                            .help("Adjust the zoom from \(zoom.start.formatted()) to \(zoom.end.formatted()) seconds.")
                            .accessibilityLabel("Zoom at \(zoom.start.formatted()) seconds")
                            .accessibilityValue(controller.selectedZoom?.id == zoom.id ? "Selected" : "Not selected")
                        }
                        ForEach(controller.session.removedRanges) { range in
                            Rectangle().fill(.secondary.opacity(0.5))
                                .overlay { Image(systemName: "scissors").font(.caption2) }
                                .frame(width: max(range.duration / duration * proxy.size.width, 2))
                                .offset(x: range.start / duration * proxy.size.width)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                }
                .frame(height: 24)
            }
            .padding(.horizontal, 26)
        }
    }
}
