import CoreGraphics
import Foundation
import OSLog

nonisolated enum PresentationPerformanceMetrics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip",
        category: "PresentationPerformance"
    )
    @TaskLocal private static var isLoggingSuppressed = false

    nonisolated static var isVerboseEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    @discardableResult
    nonisolated static func measure<T>(
        _ operation: String,
        context: @autoclosure () -> String = "",
        warnAfterMS: Double = 75,
        _ body: () throws -> T
    ) rethrows -> T {
        guard !isLoggingSuppressed else {
            return try body()
        }

        let start = DispatchTime.now().uptimeNanoseconds

        do {
            let result = try body()
            log(
                operation: operation,
                durationMS: elapsedMilliseconds(since: start),
                context: context(),
                didSucceed: true,
                warnAfterMS: warnAfterMS
            )
            return result
        } catch {
            log(
                operation: operation,
                durationMS: elapsedMilliseconds(since: start),
                context: context(),
                didSucceed: false,
                warnAfterMS: 0
            )
            throw error
        }
    }

    nonisolated static func logEvent(
        _ event: String,
        context: @autoclosure () -> String = ""
    ) {
        guard !isLoggingSuppressed, isVerboseEnabled else {
            return
        }

        let resolvedContext = context()
        logger.info(
            "event=\(event, privacy: .public) \(resolvedContext, privacy: .public)"
        )
    }

    /// Runs privacy-sensitive rendering without emitting public performance
    /// context from this task or any nested renderer instrumentation.
    nonisolated static func withLoggingSuppressed<T>(
        _ suppressed: Bool,
        _ body: () throws -> T
    ) rethrows -> T {
        guard suppressed, !isLoggingSuppressed else {
            return try body()
        }
        return try $isLoggingSuppressed.withValue(true, operation: body)
    }

    /// Async counterpart used by export pipelines whose rendering and encoding
    /// may suspend. Structured child tasks inherit the suppression value.
    nonisolated static func withLoggingSuppressed<T>(
        _ suppressed: Bool,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard suppressed, !isLoggingSuppressed else {
            return try await body()
        }
        return try await $isLoggingSuppressed.withValue(
            true,
            operation: body
        )
    }

    nonisolated static func imageSize(_ image: CGImage?) -> String {
        guard let image else {
            return "nil"
        }

        return "\(image.width)x\(image.height)"
    }

    nonisolated static func size(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    nonisolated static func presentationSummary(
        _ presentation: ScreenshotPresentation,
        maxPixelDimension: CGFloat? = nil
    ) -> String {
        [
            "enabled=\(presentation.isEnabled)",
            "scene=\(presentation.scene?.sceneID ?? "none")",
            "sceneFraming=\(presentation.scene?.screenshotSlotSettings.framingPreset.rawValue ?? "none")",
            "sceneScale=\(presentation.scene.map { String(format: "%.2f", Double($0.screenshotSlotSettings.scale)) } ?? "none")",
            "canvas=\(presentation.canvas.label)",
            "background=\(presentation.background.metricName)",
            "frame=\(presentation.frame.metricName)",
            "shadow=\(presentation.shadow.rawValue)",
            "fit=\(presentation.subjectPlacement.fit.rawValue)",
            "scale=\(String(format: "%.2f", Double(presentation.subjectPlacement.scale)))",
            "cap=\(maxPixelDimension.map { String(Int($0.rounded())) } ?? "none")",
        ].joined(separator: " ")
    }

    nonisolated private static func elapsedMilliseconds(since start: UInt64) -> Double {
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsedNanoseconds) / 1_000_000
    }

    nonisolated private static func log(
        operation: String,
        durationMS: Double,
        context: String,
        didSucceed: Bool,
        warnAfterMS: Double
    ) {
        guard isVerboseEnabled || durationMS >= warnAfterMS || !didSucceed else {
            return
        }

        let duration = String(format: "%.1f", durationMS)
        let status = didSucceed ? "ok" : "failed"
        let message = "op=\(operation) durationMS=\(duration) status=\(status) \(context)"

        if !didSucceed || durationMS >= warnAfterMS {
            logger.warning("\(message, privacy: .public)")
        } else {
            logger.info("\(message, privacy: .public)")
        }
    }
}

private extension ScreenshotPresentationBackground {
    nonisolated var metricName: String {
        switch self {
        case .transparent:
            return "transparent"
        case .solid:
            return "solid"
        case .twoColorGradient:
            return "gradient"
        case .radialSpotlight:
            return "spotlight"
        case .blurredScreenshot:
            return "blurredScreenshot"
        }
    }
}

private extension PresentationFrame {
    nonisolated var metricName: String {
        switch self {
        case .none:
            return "none"
        case .browser:
            return "browser"
        case .macOSWindow:
            return "macOSWindow"
        case .phone:
            return "phone"
        case .tablet:
            return "tablet"
        }
    }
}
