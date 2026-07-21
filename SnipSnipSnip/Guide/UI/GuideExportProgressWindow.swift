import AppKit
import SwiftUI

/// A lightweight utility window so long-running Guide exports never obscure
/// the editor or leave cancellation controls out of reach.
@MainActor
final class GuideExportProgressWindowController: NSObject, NSWindowDelegate {
    static let shared = GuideExportProgressWindowController()
    private var panel: NSPanel?

    func show(workflow: DocumentWorkflowModel) {
        if let panel {
            panel.contentView = NSHostingView(rootView: GuideExportProgressView(workflow: workflow, onClose: hide))
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 390, height: 190),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Guide Export"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: GuideExportProgressView(workflow: workflow, onClose: hide))
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

private struct GuideExportProgressView: View {
    @ObservedObject var workflow: DocumentWorkflowModel
    let onClose: () -> Void

    private var isExporting: Bool { workflow.guideExportIsActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: isExporting ? "square.and.arrow.up" : "checkmark.circle.fill")
                    .foregroundStyle(isExporting ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isExporting ? "Exporting Guide" : "Guide Export")
                        .font(.headline)
                    Text(workflow.guideExportStatus ?? "Waiting to export…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            if let progress = workflow.guideExportProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                Text(workflow.guideExportCurrentFormat.map { "Current format: \($0.label)" } ?? "Preparing files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isExporting {
                ProgressView()
                    .controlSize(.small)
                Text(workflow.guideExportCurrentFormat.map { "Current format: \($0.label)" } ?? "Preparing files…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !workflow.lastGuideExportURLs.isEmpty {
                Text("\(workflow.lastGuideExportURLs.count) file\(workflow.lastGuideExportURLs.count == 1 ? "" : "s") ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isExporting {
                    Button(workflow.guideExportCancellationRequested ? "Cancelling…" : "Cancel Export", action: workflow.cancelGuideExport)
                        .disabled(workflow.guideExportCancellationRequested)
                } else if !workflow.lastGuideExportURLs.isEmpty {
                    Button("Reveal in Finder", action: workflow.revealGuideExports)
                }
                Spacer()
                Button(isExporting ? "Hide" : "Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 390)
    }
}
