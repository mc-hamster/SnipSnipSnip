import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

nonisolated enum VideoRecordingKind: String, Codable, Equatable {
    case region
    case window
    case fullscreen

    var label: String {
        switch self {
        case .region:
            return "Region"
        case .window:
            return "Window"
        case .fullscreen:
            return "Fullscreen"
        }
    }
}

nonisolated enum VideoRecordingFrameRate: Int, CaseIterable, Codable, Identifiable {
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }

    var label: String {
        "\(rawValue) fps"
    }

    var frameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }
}

nonisolated enum VideoRecordingQuality: String, CaseIterable, Codable, Identifiable {
    case compact
    case balanced
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            return "Compact"
        case .balanced:
            return "Balanced"
        case .high:
            return "High"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "Smaller files with logical-resolution capture."
        case .balanced:
            return "Good detail with moderated Retina scaling."
        case .high:
            return "Native Retina detail with larger files."
        }
    }

    func outputScale(for pointPixelScale: CGFloat) -> CGFloat {
        switch self {
        case .compact:
            return 1
        case .balanced:
            return min(max(pointPixelScale, 1), 1.5)
        case .high:
            return max(pointPixelScale, 1)
        }
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .compact:
            return .nominal
        case .balanced:
            return .automatic
        case .high:
            return .best
        }
    }
}

nonisolated enum VideoRecordingFullscreenDisplayMode: String, CaseIterable, Codable, Identifiable {
    case currentDisplay
    case selectedDisplay
    case allDisplays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .currentDisplay:
            return "Current Display"
        case .selectedDisplay:
            return "Selected Display"
        case .allDisplays:
            return "All Displays"
        }
    }
}

nonisolated struct VideoRecordingPreferences: Codable, Equatable {
    var quality: VideoRecordingQuality = .balanced
    var frameRate: VideoRecordingFrameRate = .thirty
    var fullscreenDisplayMode: VideoRecordingFullscreenDisplayMode = .currentDisplay
    var selectedFullscreenDisplayID: UInt32?
    var recordsSystemAudio = false
    var recordsMicrophone = false
    var showsCursor = true
    var showsMouseClicks = true
}

nonisolated struct CapturedVideoRecording: Identifiable, Equatable {
    let id = UUID()
    var sourceURL: URL
    var kind: VideoRecordingKind
    var sourceName: String
    var bounds: CGRect
    var recordedAt: Date
    var duration: TimeInterval
    var preferences: VideoRecordingPreferences

    var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return "SnipSnipSnip-\(kind.rawValue)-recording-\(formatter.string(from: recordedAt))"
    }

    func updatingSourceURL(_ sourceURL: URL) -> CapturedVideoRecording {
        var copy = self
        copy.sourceURL = sourceURL
        return copy
    }
}

nonisolated struct VideoEditorSession: Codable, Equatable {
    var trimStartSeconds: TimeInterval
    var trimEndSeconds: TimeInterval
    var posterTimeSeconds: TimeInterval

    nonisolated static func fullDuration(_ duration: TimeInterval) -> VideoEditorSession {
        VideoEditorSession(
            trimStartSeconds: 0,
            trimEndSeconds: max(duration, 0),
            posterTimeSeconds: 0
        )
    }

    nonisolated func normalized(for duration: TimeInterval) -> VideoEditorSession {
        let boundedDuration = max(duration, 0)
        let start = min(max(trimStartSeconds, 0), boundedDuration)
        let end = min(max(trimEndSeconds, start), boundedDuration)
        let poster = min(max(posterTimeSeconds, start), end)

        return VideoEditorSession(
            trimStartSeconds: start,
            trimEndSeconds: end,
            posterTimeSeconds: poster
        )
    }
}

nonisolated struct EditableVideoDocument {
    var recording: CapturedVideoRecording
    var session: VideoEditorSession
}

nonisolated enum VideoExportFormat: String, CaseIterable, Codable, Identifiable {
    case mp4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4:
            return "MP4"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var fileType: AVFileType {
        switch self {
        case .mp4:
            return .mp4
        }
    }
}

nonisolated enum VideoExportQualityPreset: String, CaseIterable, Codable, Identifiable {
    case compact
    case balanced
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:
            return "Compact"
        case .balanced:
            return "Balanced"
        case .high:
            return "High"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "Favors smaller files over maximum detail."
        case .balanced:
            return "Balances file size, detail, and broad compatibility."
        case .high:
            return "Preserves the most detail with larger files."
        }
    }
}

nonisolated enum VideoExportSizeLimit: String, CaseIterable, Codable, Identifiable {
    case under25MB
    case under100MB
    case under250MB

    var id: String { rawValue }

    var maximumBytes: Int64 {
        switch self {
        case .under25MB:
            return 25 * 1_000_000
        case .under100MB:
            return 100 * 1_000_000
        case .under250MB:
            return 250 * 1_000_000
        }
    }

    var label: String {
        switch self {
        case .under25MB:
            return "Under 25 MB"
        case .under100MB:
            return "Under 100 MB"
        case .under250MB:
            return "Under 250 MB"
        }
    }

    var firstPassTargetBytes: Int64 {
        Int64(Double(maximumBytes) * 0.95)
    }
}

nonisolated enum VideoExportTarget: Codable, Equatable {
    case quality(VideoExportQualityPreset)
    case sizeLimit(VideoExportSizeLimit)

    var label: String {
        switch self {
        case .quality(let preset):
            return preset.label
        case .sizeLimit(let sizeLimit):
            return sizeLimit.label
        }
    }

    var detail: String {
        switch self {
        case .quality(let preset):
            return preset.detail
        case .sizeLimit(let sizeLimit):
            return "Retries compression until the export is at or below \(sizeLimit.label.lowercased())."
        }
    }

    var isSizeConstrained: Bool {
        if case .sizeLimit = self {
            return true
        }

        return false
    }

    func supports(_ format: VideoExportFormat) -> Bool {
        switch self {
        case .quality:
            return true
        case .sizeLimit:
            return format == .mp4
        }
    }

    func menuLabel(format: VideoExportFormat) -> String {
        format.label + " • " + label
    }
}

nonisolated struct VideoExportPreferences: Codable, Equatable {
    var format: VideoExportFormat = .mp4
    var target: VideoExportTarget = .quality(.balanced)

    var menuLabel: String {
        target.menuLabel(format: format)
    }
}

nonisolated struct VideoExportRequest: Equatable {
    var format: VideoExportFormat
    var target: VideoExportTarget
    var updatesDefaults: Bool = true

    var menuLabel: String {
        target.menuLabel(format: format)
    }
}

nonisolated struct VideoExportProgress: Equatable, Sendable {
    var title: String
    var detail: String
    var fractionCompleted: Double?
}
