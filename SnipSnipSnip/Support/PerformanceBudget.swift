import Foundation

nonisolated struct PerformanceBudget: Equatable, Sendable {
    let name: String
    let maximumSeconds: TimeInterval

    func contains(_ elapsedSeconds: TimeInterval) -> Bool {
        elapsedSeconds <= maximumSeconds
    }
}

nonisolated enum PerformanceBudgetCatalog {
    static let captureEntryPoint = PerformanceBudget(name: "Capture entry point", maximumSeconds: 1.5)
    static let screenshotRenderAndExport = PerformanceBudget(name: "Screenshot render and export", maximumSeconds: 3.0)
    static let archiveIndexedSearch = PerformanceBudget(name: "Archive indexed search", maximumSeconds: 0.25)
    static let videoExportPlanning = PerformanceBudget(name: "Video export planning", maximumSeconds: 0.05)
    static let videoStoragePressureCheck = PerformanceBudget(name: "Video storage pressure check", maximumSeconds: 0.05)

    // Composition release gates are intentionally kept beside the other
    // product-wide budgets so tests, profiling scripts, and release sign-off
    // all use the same values.
    static let compositionLayout200ItemP95 = PerformanceBudget(
        name: "Composition layout (200 items, p95)",
        maximumSeconds: 0.016
    )
    static let compositionAppend4KPreviewWarm = PerformanceBudget(
        name: "Composition append 4K preview (warm)",
        maximumSeconds: 0.250
    )
    static let compositionAppend4KPreviewCold = PerformanceBudget(
        name: "Composition append 4K preview (cold)",
        maximumSeconds: 0.500
    )
    static let compositionComparison4KPreview = PerformanceBudget(
        name: "Composition comparison preview (two 4K sources at 1800 px)",
        maximumSeconds: 0.250
    )
    static let compositionTwelveItemPreview = PerformanceBudget(
        name: "Composition grid preview (twelve 1080p sources)",
        maximumSeconds: 0.500
    )
    static let compositionFourItemPNGExport = PerformanceBudget(
        name: "Composition PNG export (four 1080p sources)",
        maximumSeconds: 3.0
    )

    static let compositionPreviewPeakMemoryBytes = 256 * 1_024 * 1_024
    static let compositionTwelveItemExportPeakMemoryBytes = 512 * 1_024 * 1_024
}

nonisolated enum PerformanceBudgetTimer {
    static func measure(_ operation: () throws -> Void) rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return TimeInterval(end - start) / 1_000_000_000
    }

    static func measure(_ operation: () async throws -> Void) async rethrows -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return TimeInterval(end - start) / 1_000_000_000
    }
}
