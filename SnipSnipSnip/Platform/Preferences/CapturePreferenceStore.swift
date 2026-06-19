import CoreGraphics
import Foundation

nonisolated struct CapturePreferenceStore {
    private let storage: PreferenceStorage
    private let presetsPreference = CodablePreference<[CapturePreset]>(
        key: AppModelPreferenceKey.capturePresets,
        defaultValue: []
    )

    init(storage: PreferenceStorage) {
        self.storage = storage
    }

    func loadAutoRefreshWindowsEnabled() -> Bool {
        storage.bool(forKey: AppModelPreferenceKey.autoRefreshWindowsEnabled)
    }

    func saveAutoRefreshWindowsEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: AppModelPreferenceKey.autoRefreshWindowsEnabled)
    }

    func loadCaptureDelay() -> CaptureDelay {
        CaptureDelay(rawValue: storage.integer(forKey: AppModelPreferenceKey.captureDelay)) ?? .immediate
    }

    func saveCaptureDelay(_ delay: CaptureDelay) {
        storage.set(delay.rawValue, forKey: AppModelPreferenceKey.captureDelay)
    }

    func loadCapturePresets() -> [CapturePreset] {
        presetsPreference.load(from: storage)
    }

    func saveCapturePresets(_ presets: [CapturePreset]) {
        presetsPreference.save(presets, to: storage)
    }

    func loadScreenshotIncludesCursor() -> Bool {
        storage.object(forKey: AppModelPreferenceKey.screenshotIncludesCursor) as? Bool ?? false
    }

    func saveScreenshotIncludesCursor(_ includesCursor: Bool) {
        storage.set(includesCursor, forKey: AppModelPreferenceKey.screenshotIncludesCursor)
    }

    func loadFullscreenDisplayMode() -> ScreenshotFullscreenDisplayMode {
        storage.string(forKey: AppModelPreferenceKey.screenshotFullscreenDisplayMode)
            .flatMap(ScreenshotFullscreenDisplayMode.init(rawValue:)) ?? .currentDisplay
    }

    func saveFullscreenDisplayMode(_ mode: ScreenshotFullscreenDisplayMode) {
        storage.set(mode.rawValue, forKey: AppModelPreferenceKey.screenshotFullscreenDisplayMode)
    }

    func loadSelectedFullscreenDisplayID() -> CGDirectDisplayID? {
        guard let selectedDisplayNumber = storage.object(forKey: AppModelPreferenceKey.selectedScreenshotFullscreenDisplayID) as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(selectedDisplayNumber.uint32Value)
    }

    func saveSelectedFullscreenDisplayID(_ displayID: CGDirectDisplayID?) {
        if let displayID {
            storage.set(displayID, forKey: AppModelPreferenceKey.selectedScreenshotFullscreenDisplayID)
        } else {
            storage.removeObject(forKey: AppModelPreferenceKey.selectedScreenshotFullscreenDisplayID)
        }
    }

    func loadScreenshotJPEGQuality() -> CGFloat {
        guard let configuredValue = storage.object(forKey: AppModelPreferenceKey.screenshotJPEGQuality) as? Double else {
            return ImageExportOptions.default.jpegQuality
        }

        return ImageExportOptions.sanitizedJPEGQuality(CGFloat(configuredValue))
    }

    func saveScreenshotJPEGQuality(_ quality: CGFloat) {
        storage.set(Double(ImageExportOptions.sanitizedJPEGQuality(quality)), forKey: AppModelPreferenceKey.screenshotJPEGQuality)
    }

    func loadRegionCapturePreferences() -> RegionCapturePreferences {
        RegionCapturePreferences(
            overlayMode: (storage.object(forKey: AppModelPreferenceKey.regionCaptureOverlayMode) as? Int)
                .flatMap(RegionCaptureOverlayMode.init(rawValue:)) ?? .crosshairAndMagnifyingGlass,
            showsActionControls: storage.object(forKey: AppModelPreferenceKey.regionCaptureShowsActionControls) as? Bool ?? false,
            advancedControlsEnabled: storage.object(forKey: AppModelPreferenceKey.regionCaptureAdvancedControlsEnabled) as? Bool ?? false
        )
    }

    func saveRegionCapturePreferences(_ preferences: RegionCapturePreferences) {
        storage.set(preferences.overlayMode.rawValue, forKey: AppModelPreferenceKey.regionCaptureOverlayMode)
        storage.set(preferences.showsActionControls, forKey: AppModelPreferenceKey.regionCaptureShowsActionControls)
        storage.set(preferences.advancedControlsEnabled, forKey: AppModelPreferenceKey.regionCaptureAdvancedControlsEnabled)
    }

    func loadScreenshotFilenameTemplate() -> String {
        storage.string(forKey: AppModelPreferenceKey.screenshotFilenameTemplate) ?? ScreenshotFilenameTemplate.defaultPattern
    }

    func saveScreenshotFilenameTemplate(_ template: String) {
        storage.set(template, forKey: AppModelPreferenceKey.screenshotFilenameTemplate)
    }

    func loadScreenshotDragOutFormat() -> ImageExportFormat {
        storage.string(forKey: AppModelPreferenceKey.screenshotDragOutFormat)
            .flatMap(ImageExportFormat.init(rawValue:)) ?? .png
    }

    func saveScreenshotDragOutFormat(_ format: ImageExportFormat) {
        storage.set(format.rawValue, forKey: AppModelPreferenceKey.screenshotDragOutFormat)
    }

    func loadPrivateCaptureEnabled() -> Bool {
        storage.object(forKey: AppModelPreferenceKey.privateCaptureEnabled) as? Bool ?? false
    }

    func savePrivateCaptureEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: AppModelPreferenceKey.privateCaptureEnabled)
    }

    func loadUIMapEnabled(defaultEnabled: Bool) -> Bool {
        storage.object(forKey: AppModelPreferenceKey.uiMapEnabled) as? Bool ?? defaultEnabled
    }

    func saveUIMapEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: AppModelPreferenceKey.uiMapEnabled)
    }
}
