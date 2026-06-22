import Foundation

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
    static let defaultRecycleBinRetentionDays = 2
    static let minimumRecycleBinRetentionDays = 1
}
