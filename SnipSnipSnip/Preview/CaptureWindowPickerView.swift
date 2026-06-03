import SwiftUI

struct CaptureWindowPickerView: View {
    let windows: [CaptureWindowSummary]
    let onSelect: (CaptureWindowSummary) -> Void
    let onPickOnScreen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: onPickOnScreen) {
                        HStack(spacing: 12) {
                            Image(systemName: "cursorarrow.click.2")
                                .font(.system(size: 24, weight: .medium))
                                .frame(width: 44, height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.15))
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Pick On Screen")
                                    .font(.headline)
                                Text("Hover a visible window to highlight it, then click to capture.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Windows") {
                    ForEach(windows) { window in
                        Button {
                            onSelect(window)
                        } label: {
                            HStack(spacing: 12) {
                                CaptureWindowThumbnailView(window: window)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(window.displayTitle)
                                        .font(.headline)
                                        .lineLimit(2)

                                    Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose Window")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}