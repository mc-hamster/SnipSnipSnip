import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    func exportSupportDiagnostics() {
        let diagnostics = SupportDiagnosticsBuilder.make(model: self)
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "SnipSnipSnip-Diagnostics-\(Self.diagnosticsTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try diagnostics.jsonData().write(to: url, options: .atomic)
        } catch {
            present(error)
        }
    }

    private static func diagnosticsTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: Date())
    }
}
