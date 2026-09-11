import SwiftUI

/// A clear default path with format and size controls available when needed.
struct VideoExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var format: VideoExportFormat
    @State private var quality: VideoExportQualityPreset
    @State private var limitsSize: Bool
    @State private var sizeLimit: VideoExportSizeLimit
    let onExport: (VideoExportRequest) -> Void

    init(preferences: VideoExportPreferences, onExport: @escaping (VideoExportRequest) -> Void) {
        let request = VideoExportRequest(format: preferences.format, target: preferences.target).normalizedForAvailability()
        _format = State(initialValue: request.format)
        if case .quality(let preset) = request.target { _quality = State(initialValue: preset) }
        else { _quality = State(initialValue: .balanced) }
        if case .sizeLimit(let limit) = request.target {
            _limitsSize = State(initialValue: true)
            _sizeLimit = State(initialValue: limit)
        } else {
            _limitsSize = State(initialValue: false)
            _sizeLimit = State(initialValue: .under25MB)
        }
        self.onExport = onExport
    }

    private var target: VideoExportTarget {
        limitsSize && format == .mp4 ? .sizeLimit(sizeLimit) : .quality(quality)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Video").font(.title2.bold())
            Text("Your trims and effects are included. The original stays editable.").foregroundStyle(.secondary)
            Form {
                Picker("Format", selection: $format) {
                    ForEach(VideoExportFormat.allCases) { Text($0.label).tag($0) }
                }
                Text(format.exportDetail).font(.callout).foregroundStyle(.secondary)
                if format != .mp4 {
                    Label("Animated loops do not include sound.", systemImage: "speaker.slash")
                        .font(.callout)
                }
                Picker("Quality", selection: $quality) {
                    ForEach(VideoExportQualityPreset.allCases) { Text($0.label).tag($0) }
                }
                .disabled(format == .mp4 && limitsSize)
                if format == .mp4 {
                    Toggle("Keep Under a File Size", isOn: $limitsSize)
                    if limitsSize {
                        Picker("Maximum Size", selection: $sizeLimit) {
                            ForEach(VideoExportSizeLimit.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                Text(target.detail).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: limitsSize && format == .mp4 ? 280 : 240)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Location…") { onExport(VideoExportRequest(format: format, target: target)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
