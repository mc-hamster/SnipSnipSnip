import CoreGraphics
import Foundation
@preconcurrency import Vision

nonisolated protocol CaptureTextRecognizing: Sendable {
    nonisolated func recognizeText(in image: CGImage) throws -> String
}

nonisolated struct VisionCaptureTextRecognizer: CaptureTextRecognizing {
    nonisolated func recognizeText(in image: CGImage) throws -> String {
        try CaptureTextRecognizer.recognizeText(in: image)
    }
}

enum CaptureTextRecognizer {
    nonisolated static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ") ?? ""
    }

    nonisolated static func recognizeText(in image: CGImage, region: CGRect) throws -> String {
        guard let cropped = cropImage(in: image, region: region) else {
            return ""
        }

        return try recognizeText(in: cropped)
    }

    nonisolated static func cropImage(in image: CGImage, region: CGRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = region.gscIntegralStandardized.intersection(imageBounds)

        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        return image.gscCropped(topLeftPixelRect: rect)
    }

    nonisolated static func normalizedRecognizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class CaptureTextRecognitionCoordinator {
    private static let recognitionDelayNanoseconds: UInt64 = 1_500_000_000

    private let recognizer: any CaptureTextRecognizing
    private var activeTasks: [URL: Task<Void, Never>] = [:]

    init(recognizer: any CaptureTextRecognizing = VisionCaptureTextRecognizer()) {
        self.recognizer = recognizer
    }

    deinit {
        activeTasks.values.forEach { $0.cancel() }
    }

    func recognizeText(
        for entry: DocumentHistoryEntry,
        image: CGImage,
        includeUIMapSearchText: Bool = FeatureFlags.uiMapEnabled,
        didUpdate: @escaping @MainActor (String) -> Void
    ) {
        guard activeTasks[entry.packageURL] == nil else {
            return
        }

        let packageURL = entry.packageURL
        let recognizer = self.recognizer
        activeTasks[packageURL] = Task { @MainActor [weak self, image, packageURL, didUpdate] in
            defer {
                self?.activeTasks[packageURL] = nil
            }

            do {
                try await Task.sleep(nanoseconds: Self.recognitionDelayNanoseconds)
            } catch {
                return
            }

            let writeTask = Task.detached(priority: .utility) {
                let recognizedText = (try? recognizer.recognizeText(in: image)) ?? ""

                guard !Task.isCancelled else {
                    return nil as String?
                }

                return try? SSSDocumentPackage.updateRecognizedText(
                    recognizedText,
                    in: packageURL,
                    includeUIMapSearchText: includeUIMapSearchText
                )
            }

            let searchableText = await withTaskCancellationHandler {
                await writeTask.value
            } onCancel: {
                writeTask.cancel()
            }

            guard let searchableText, !Task.isCancelled else {
                return
            }

            didUpdate(searchableText)
        }
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }
}
