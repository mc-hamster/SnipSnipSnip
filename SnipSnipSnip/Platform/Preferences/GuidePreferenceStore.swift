import Foundation

nonisolated struct GuideCapturePreferences: Codable, Equatable, Sendable {
    var sourceVideoEnabled = true
    var framesPerSecond = 30
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var showsSmoothVideoCursor = true
    var showsCursorInSteps = false
    var hidesDesktopIcons = true
    var masksSecureFields = true
    var automaticCaptions = true
    var aiCaptionRefinement = true
    var menuBarIncludedForDisplays = false
    var hudCorner = "topRight"
    var hudPreviewsEnabled = true
}

nonisolated struct GuidePreferenceStore {
    private static let brandLogoKey = "guide.brand.logo.png"
    private let storage: PreferenceStorage
    private let capturePreference = CodablePreference(key: "guide.capture.preferences", defaultValue: GuideCapturePreferences())
    private let exportPreference = CodablePreference(key: "guide.export.preferences", defaultValue: GuideExportSettings())
    private let themePreference = CodablePreference(key: "guide.theme.default", defaultValue: GuideTheme())
    private let savedThemesPreference = CodablePreference<[GuideTheme]>(key: "guide.theme.saved", defaultValue: [])

    init(storage: PreferenceStorage) { self.storage = storage }

    func loadCapturePreferences() -> GuideCapturePreferences { capturePreference.load(from: storage) }
    func saveCapturePreferences(_ value: GuideCapturePreferences) { capturePreference.save(value, to: storage) }
    func loadExportSettings() -> GuideExportSettings { exportPreference.load(from: storage) }
    func saveExportSettings(_ value: GuideExportSettings) { exportPreference.save(value, to: storage) }
    func loadTheme() -> GuideTheme { themePreference.load(from: storage) }
    func saveTheme(_ value: GuideTheme) { themePreference.save(value, to: storage) }
    func loadSavedThemes() -> [GuideTheme] { savedThemesPreference.load(from: storage) }
    func saveSavedThemes(_ value: [GuideTheme]) { savedThemesPreference.save(value, to: storage) }
    func loadBrandLogoData() -> Data? { storage.data(forKey: Self.brandLogoKey) }
    func saveBrandLogoData(_ value: Data?) { storage.set(value, forKey: Self.brandLogoKey) }

    func loadLastSource() -> GuideCaptureSource? {
        guard let data = storage.data(forKey: "guide.lastSource") else { return nil }
        return try? JSONDecoder().decode(GuideCaptureSource.self, from: data)
    }

    func saveLastSource(_ source: GuideCaptureSource?) {
        storage.set(source.flatMap { try? JSONEncoder().encode($0) }, forKey: "guide.lastSource")
    }

    func loadOnboardingVersion() -> Int { storage.integer(forKey: "guide.onboarding.version") }
    func saveOnboardingVersion(_ version: Int) { storage.set(version, forKey: "guide.onboarding.version") }
}
