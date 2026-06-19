import CoreGraphics
import Foundation

nonisolated struct EditorPreferenceStore {
    private let storage: PreferenceStorage
    private let outOfCapturePatternPreference = CodablePreference<EditorOutOfCapturePatternSettings>(
        key: AppModelPreferenceKey.editorOutOfCapturePatternSettings,
        defaultValue: .default
    )
    private let uiMapPinnedOverlayPreference = CodablePreference<UIMapOverlayOptions>(
        key: AppModelPreferenceKey.uiMapPinnedOverlayDefaults,
        defaultValue: UIMapOverlayOptions()
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadSingleKeyToolShortcutsEnabled() -> Bool {
        storage.object(forKey: AppModelPreferenceKey.editorSingleKeyToolShortcutsEnabled) as? Bool ?? true
    }

    func saveSingleKeyToolShortcutsEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: AppModelPreferenceKey.editorSingleKeyToolShortcutsEnabled)
    }

    func loadCropOutsideOverlayAlpha() -> CGFloat {
        guard let configuredValue = storage.object(forKey: AppModelPreferenceKey.editorCropOutsideOverlayAlpha) as? Double else {
            return AppPreferenceDefaults.editorCropOutsideOverlayAlpha
        }

        return Self.clampedCropOutsideOverlayAlpha(CGFloat(configuredValue))
    }

    func saveCropOutsideOverlayAlpha(_ alpha: CGFloat) {
        storage.set(Double(Self.clampedCropOutsideOverlayAlpha(alpha)), forKey: AppModelPreferenceKey.editorCropOutsideOverlayAlpha)
    }

    func loadOutOfCapturePatternSettings() -> EditorOutOfCapturePatternSettings {
        outOfCapturePatternPreference.load(from: storage).sanitized()
    }

    func saveOutOfCapturePatternSettings(_ settings: EditorOutOfCapturePatternSettings) {
        outOfCapturePatternPreference.save(settings.sanitized(), to: storage)
    }

    func loadPresentationScenesRootURL() -> URL {
        guard let path = storage.string(forKey: AppModelPreferenceKey.presentationScenesRootPath),
              !path.isEmpty else {
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("SnipSnipSnipTests", isDirectory: true)
                    .appendingPathComponent("Presentation Scenes", isDirectory: true)
            }
            return PresentationSceneStore.defaultRootURL
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func savePresentationScenesRootURL(_ url: URL?) {
        if let url {
            let standardizedURL = url.standardizedFileURL
            storage.set(standardizedURL.path, forKey: AppModelPreferenceKey.presentationScenesRootPath)
        } else {
            storage.removeObject(forKey: AppModelPreferenceKey.presentationScenesRootPath)
        }
    }

    func loadUIMapPinnedOverlayDefaults() -> UIMapOverlayOptions {
        uiMapPinnedOverlayPreference.load(from: storage)
    }

    func saveUIMapPinnedOverlayDefaults(_ options: UIMapOverlayOptions) {
        uiMapPinnedOverlayPreference.save(options, to: storage)
    }

    static func clampedCropOutsideOverlayAlpha(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 0.9)
    }
}

nonisolated extension EditorOutOfCapturePatternSettings {
    func sanitized() -> EditorOutOfCapturePatternSettings {
        EditorOutOfCapturePatternSettings(
            isEnabled: isEnabled,
            spacing: min(max(spacing, 16), 96),
            lineOpacity: min(max(lineOpacity, 0.05), 0.9),
            dotOpacity: min(max(dotOpacity, 0.05), 1),
            dotDiameter: min(max(dotDiameter, 2), 12)
        )
    }
}
