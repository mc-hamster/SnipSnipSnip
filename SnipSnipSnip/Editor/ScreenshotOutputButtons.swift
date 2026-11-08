import SwiftUI

struct ScreenshotCopyButton: View {
    @ObservedObject var activity: ScreenshotOutputActivity
    let outputDescription: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Label("Copy", systemImage: "doc.on.doc").hidden().accessibilityHidden(true)
                Label("Copying…", systemImage: "doc.on.doc").hidden().accessibilityHidden(true)
            }
                .overlay {
                    Label(activity.showsCopyProgress ? "Copying…" : "Copy", systemImage: "doc.on.doc")
                }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(activity.isCopying)
        .help("Copy the output currently shown in this workspace.")
        .accessibilityLabel(activity.showsCopyProgress ? "Copying screenshot…" : "Copy")
        .accessibilityValue(outputDescription)
        .accessibilityIdentifier("editor.output.copy.current")
    }
}

struct ScreenshotExportMenu<Content: View>: View {
    @ObservedObject var activity: ScreenshotOutputActivity
    let outputDescription: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            ZStack {
                Label("Export", systemImage: "square.and.arrow.down").hidden().accessibilityHidden(true)
                Label("Exporting…", systemImage: "square.and.arrow.down").hidden().accessibilityHidden(true)
            }
                .overlay {
                    Label(activity.showsExportProgress ? "Exporting…" : "Export", systemImage: "square.and.arrow.down")
                }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(activity.isExporting)
        .help("Export the output currently shown in this workspace.")
        .accessibilityLabel(activity.showsExportProgress ? "Exporting screenshot" : "Export")
        .accessibilityValue(outputDescription)
        .accessibilityIdentifier("editor.output.export.current")
    }
}

/// Measure all localized family labels, so changing variants never moves tools.
struct StableEditorToolLabel: View {
    let tool: EditorTool
    let family: [EditorTool]

    var body: some View {
        ZStack {
            ForEach(family) { candidate in
                Label(candidate.label, systemImage: candidate.systemImage)
                    .hidden().accessibilityHidden(true)
            }
        }
        .overlay(alignment: .leading) {
            Label(tool.label, systemImage: tool.systemImage)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
