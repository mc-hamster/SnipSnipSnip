import SwiftUI

enum CaptureWindowPickerPurpose {
    case screenshot, video

    var pickOnScreenInstructions: String {
        switch self {
        case .screenshot: String(localized: "Hover a visible window to highlight it, then click to capture.")
        case .video: String(localized: "Hover a visible window to highlight it, then click to select it for Video.")
        }
    }

    var selectionHint: String {
        switch self {
        case .screenshot: String(localized: "Capture this window.")
        case .video: String(localized: "Record this window.")
        }
    }
}

enum CaptureWindowSearch {
    static func matches(_ window: CaptureWindowSummary, query: String) -> Bool {
        let tokens = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let searchable = window.ownerName + " " + window.title
        return tokens.allSatisfy { searchable.localizedStandardContains($0) }
    }
}

struct CaptureWindowPickerView: View {
    let windows: [CaptureWindowSummary]
    var purpose: CaptureWindowPickerPurpose = .screenshot
    let onSelect: (CaptureWindowSummary) -> Void
    let onPickOnScreen: () -> Void
    let onCancel: () -> Void
    @State private var search = ""

    private var matchingWindows: [CaptureWindowSummary] {
        windows.filter { CaptureWindowSearch.matches($0, query: search) }
    }

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
                                Text(purpose.pickOnScreenInstructions)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Windows") {
                    if windows.isEmpty {
                        ContentUnavailableView {
                            Label("No Available Windows", systemImage: "macwindow")
                        } description: {
                            Text("Open a window and reopen this chooser, or try Pick On Screen.")
                        }
                    } else if matchingWindows.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Windows", systemImage: "magnifyingglass")
                        } description: {
                            Text("Search by app name or window title.")
                        } actions: {
                            Button("Clear Search") { search = "" }
                        }
                    }
                    ForEach(matchingWindows) { window in
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
                        .accessibilityLabel(window.displayTitle)
                        .accessibilityValue(
                            "\(Int(window.frame.width)) by \(Int(window.frame.height)) pixels"
                        )
                        .accessibilityHint(purpose.selectionHint)
                        .accessibilityIdentifier("capture.window.list.\(window.id)")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search Apps and Windows")
            .accessibilityIdentifier("capture.window.search")
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
