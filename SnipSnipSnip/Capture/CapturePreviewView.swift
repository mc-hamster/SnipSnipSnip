import SwiftUI

struct CapturePreviewView: View {
    @ObservedObject var model: CapturePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Screenshot", systemImage: "checkmark.circle")
                    .font(.headline)
                Spacer()
                Button(action: model.close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Close Capture Preview")
                    .accessibilityIdentifier("capture.preview.close")
                    .help("Close the preview without deleting the screenshot.")
                    .keyboardShortcut(.cancelAction)
            }
            ZStack {
                Rectangle().fill(Color(nsColor: .textBackgroundColor))
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high).scaledToFit()
                        .padding(6)
                    PromisedFileDragView(
                        accessibilityLabel: String(localized: "Drag Screenshot"),
                        payloadProvider: { model.drag() },
                        showsIcon: false,
                        onClick: model.edit,
                        shouldRestoreWindowAfterDrag: { model.allowsWindowRestoration }
                    )
                    .help("Drag into another app, or click to open in Editor.")
                } else if model.hasError {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle).foregroundStyle(.secondary)
                } else {
                    ProgressView().accessibilityLabel("Preparing Capture Preview")
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Drag the screenshot into another app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: model.copyScreenshot) {
                    Label(model.isCopying ? "Copying…" : "Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.image == nil || model.isCopying)
                .accessibilityIdentifier("capture.preview.copy")
                .keyboardShortcut(.defaultAction)
                Button("Edit", action: model.edit)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open in Editor")
                    .accessibilityIdentifier("capture.preview.edit")
                    .help("Add arrows, text, highlights, or redactions before sharing.")
                Button("Export…", action: model.export)
                    .buttonStyle(.bordered)
                    .disabled(model.image == nil)
                    .accessibilityIdentifier("capture.preview.export")
            }
            Label(model.message, systemImage: model.hasError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(model.message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("capture.preview.status")
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 304, height: 310)
        .sssFloatingOverlaySurface(cornerRadius: 12, isInteractive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture Preview")
    }
}
