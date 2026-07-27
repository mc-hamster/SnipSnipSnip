import Foundation
import OSLog

nonisolated enum CaptureContentDiagnosticLevel: Sendable {
    case debug
    case info
    case notice
    case error
}

nonisolated protocol CaptureContentDiagnosticSink: Sendable {
    func emit(
        level: CaptureContentDiagnosticLevel,
        category: String,
        message: String
    )
}

nonisolated struct SystemCaptureContentDiagnosticSink:
    CaptureContentDiagnosticSink
{
    func emit(
        level: CaptureContentDiagnosticLevel,
        category: String,
        message: String
    ) {
        let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier
                ?? "com.oontz.SnipSnipSnip",
            category: category
        )
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}

/// Carries capture privacy through asynchronous services before any
/// content-bearing diagnostic is constructed or emitted.
nonisolated struct CaptureContentDiagnostics: Sendable {
    @TaskLocal static var current = CaptureContentDiagnostics(
        isPrivateCapture: false
    )

    private let isPrivateCapture: Bool
    private let sink: any CaptureContentDiagnosticSink

    init(
        isPrivateCapture: Bool,
        sink: any CaptureContentDiagnosticSink =
            SystemCaptureContentDiagnosticSink()
    ) {
        self.isPrivateCapture = isPrivateCapture
        self.sink = sink
    }

    func debug(category: String, _ message: @autoclosure () -> String) {
        emit(level: .debug, category: category, message)
    }

    func info(category: String, _ message: @autoclosure () -> String) {
        emit(level: .info, category: category, message)
    }

    func notice(category: String, _ message: @autoclosure () -> String) {
        emit(level: .notice, category: category, message)
    }

    func error(category: String, _ message: @autoclosure () -> String) {
        emit(level: .error, category: category, message)
    }

    private func emit(
        level: CaptureContentDiagnosticLevel,
        category: String,
        _ message: () -> String
    ) {
        // The autoclosure is intentionally not evaluated for Private Capture,
        // keeping window titles, OCR text, source names, paths, and geometry
        // out of both logs and intermediate diagnostic strings.
        guard !isPrivateCapture else {
            return
        }
        sink.emit(
            level: level,
            category: category,
            message: message()
        )
    }
}
