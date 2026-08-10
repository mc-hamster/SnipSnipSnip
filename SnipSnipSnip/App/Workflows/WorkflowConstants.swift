import Foundation

/// Canonical user-facing terms shared across otherwise independent workflows.
///
/// Keep behavior, persistence, and automation identifiers in their owning
/// models. These values exist only to prevent capture, Guide, video, clipboard,
/// and library surfaces from inventing different labels for the same concept.
nonisolated enum WorkflowVocabulary {
    nonisolated enum Source {
        static let region = String(localized: "Region")
        static let window = String(localized: "Window")
        static let screen = String(localized: "Screen")
        static let app = String(localized: "App")
        static let scrollingContent = String(localized: "Scrolling Content")
        static let connectedDevice = String(localized: "Connected Device")
        static let existingImage = String(localized: "Existing Image")
    }

    nonisolated enum Instructions {
        static let recordGuide = String(localized: "Record a Guide")
        static let buildStepsManually =
            String(localized: "Build Steps manually")
    }

    nonisolated enum Status {
        static let guideCapturing = String(localized: "Guide Capturing")
        static let videoRecording = String(localized: "Recording")
        static let videoPaused = String(localized: "Paused")
        static let videoFinishing = String(localized: "Finishing")
        static let clipboardMonitoring = String(localized: "Monitoring")
        static let clipboardMonitoringPaused =
            String(localized: "Monitoring Paused")
    }

    nonisolated enum Library {
        static let snipLibrary = String(localized: "Snip Library")
        static let recentSnips = String(localized: "Recent Snips")
        static let snipHistory = String(localized: "Snip History")
        static let changeHistory = String(localized: "Change History")
        static let recycleBin = String(localized: "Recycle Bin")
        static let historyStorage = String(localized: "Snip History Storage")
    }
}

nonisolated enum ClipboardWorkflowConstants {
    static let autoCopyDebounceNanoseconds: UInt64 = 250_000_000
}

nonisolated enum DocumentWorkflowConstants {
    static let autosaveDebounceNanoseconds: UInt64 = 1_250_000_000
    static let captureHistoryLimit = 36
    static let captureHistorySearchLimit = 100
    static let recentSnipLimit = 12
    static let recycleBinLimit = 48
}

nonisolated enum AppLifecycleConstants {
    static let currentOnboardingVersion = 1
}

nonisolated enum ArchiveWorkflowConstants {
    static let maintenanceDebounceNanoseconds: UInt64 = 300_000_000_000
    static let defaultMaximumSizeMB = 1_024
    static let minimumMaximumSizeMB = 100
    static let defaultRecycleBinRetentionDays = 30
    static let minimumRecycleBinRetentionDays = 1
    static let maximumRecycleBinRetentionDays = 180
}
