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
