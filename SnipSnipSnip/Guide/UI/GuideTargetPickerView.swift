import SwiftUI

struct GuideTargetPickerView: View {
    let kind: GuideTargetPickerKind
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
                                Text(kind.onScreenDetail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(targets.isEmpty)
                }

                Section(kind.collectionTitle) {
                    if targets.isEmpty {
                        ContentUnavailableView(
                            "No Capturable \(kind.collectionTitle)",
                            systemImage: kind == .window ? "macwindow" : "app.dashed",
                            description: Text("Open the \(kind == .window ? "window" : "app") you want to follow, then return to Guide setup and try again.")
                        )
                    } else {
                        ForEach(targets) { target in
                            Button {
                                onSelect(target.window)
                            } label: {
                                HStack(spacing: 12) {
                                    CaptureWindowThumbnailView(window: target.window)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(target.title)
                                            .font(.headline)
                                            .lineLimit(2)

                                        Text(target.detail)
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
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .help("Return to Create a Guide.")
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private var targets: [Target] {
        switch kind {
        case .window:
            windows.map {
                Target(
                    window: $0,
                    title: $0.displayTitle,
                    detail: "\(Int($0.frame.width)) × \(Int($0.frame.height))"
                )
            }
        case .app:
            Dictionary(grouping: windows, by: \.ownerPID)
                .values
                .compactMap { appWindows -> Target? in
                    guard let representative = appWindows.sorted(by: targetOrder).first else {
                        return nil
                    }
                    let count = appWindows.count
                    return Target(
                        window: representative,
                        title: representative.ownerName,
                        detail: count == 1 ? "1 visible window" : "\(count) visible windows"
                    )
                }
                .sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
        }
    }

    private func targetOrder(_ lhs: CaptureWindowSummary, _ rhs: CaptureWindowSummary) -> Bool {
        if lhs.focusRank != rhs.focusRank {
            return lhs.focusRank < rhs.focusRank
        }
        return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
    }

    private struct Target: Identifiable {
        var id: CGWindowID { window.id }
        let window: CaptureWindowSummary
        let title: String
        let detail: String
    }
}
