import CoreGraphics
import Foundation

nonisolated enum AppPreferenceDefaults {
    static let archiveMaximumSizeMB = 1_024
    static let editorCropOutsideOverlayAlpha: CGFloat = 0.80
    static let recycleBinRetentionDays = 30
    static let legacyRecycleBinRetentionDays = 2
    static let minimumArchiveMaximumSizeMB = 100
    static let minimumRecycleBinRetentionDays = 1
    static let maximumRecycleBinRetentionDays = 180
}
