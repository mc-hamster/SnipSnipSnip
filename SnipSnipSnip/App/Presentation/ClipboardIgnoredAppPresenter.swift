import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct LiveClipboardIgnoredAppPresenter: ClipboardIgnoredAppPresenting {
    func selectIgnoredClipboardApp() -> ClipboardIgnoredApp? {
        let panel = NSOpenPanel()
        panel.title = "Choose App to Ignore"
        panel.prompt = "Ignore"
        panel.message = "Choose an app. \(AppBranding.displayName) will skip clipboard history entries copied from it."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let appURL = panel.url else {
            return nil
        }

        let bundle = Bundle(url: appURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent

        return ClipboardIgnoredApp(
            name: displayName,
            match: bundle?.bundleIdentifier ?? displayName
        )
    }
}
