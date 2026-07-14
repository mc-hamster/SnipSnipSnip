import Foundation
import Vision

nonisolated enum ClipboardTextRecognition {
    static func recognizedText(in imageData: Data) -> String {
        guard !imageData.isEmpty else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(data: imageData)
        do {
            try handler.perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        } catch {
            return ""
        }
    }
}

