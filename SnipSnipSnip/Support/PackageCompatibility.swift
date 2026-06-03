import Foundation

nonisolated enum PackageCompatibilityStatus: Equatable {
    case compatible
    case unsupportedFormatVersion(Int)
    case unsupportedFormatIdentifier(String)
    case invalidManifest

    nonisolated var isUnsupportedFormatVersion: Bool {
        if case .unsupportedFormatVersion = self {
            return true
        }

        return false
    }
}