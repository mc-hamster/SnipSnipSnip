import CoreGraphics
import Foundation
import Vision

/// OCR geometry uses the same top-left pixel coordinates as annotations.
nonisolated struct RecognizedTextWord: Equatable, Sendable {
    let text: String
    let rect: CGRect
}

nonisolated struct RecognizedTextLine: Equatable, Sendable {
    let text: String
    let rect: CGRect
    let confidence: Float
    var words: [RecognizedTextWord] = []
}

nonisolated struct RecognizedTextLayout: Equatable, Sendable {
    var lines: [RecognizedTextLine]

    /// Preserve line breaks and infer indentation from geometry. OCR cannot
    /// guarantee exact source whitespace, especially with proportional fonts.
    var formattedText: String {
        let ordered = lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) < min(lhs.rect.height, rhs.rect.height) * 0.4 {
                return lhs.rect.minX < rhs.rect.minX
            }
            return lhs.rect.midY < rhs.rect.midY
        }
        guard let left = ordered.map(\.rect.minX).min() else { return "" }
        let characterWidths = ordered.compactMap { line -> CGFloat? in
            guard !line.text.isEmpty, line.rect.width > 0 else { return nil }
            return line.rect.width / CGFloat(line.text.count)
        }.sorted()
        let characterWidth = max(characterWidths.isEmpty ? 8 : characterWidths[characterWidths.count / 2], 1)
        return ordered.enumerated().map { index, line in
            let indent = min(max(Int(((line.rect.minX - left) / characterWidth).rounded()), 0), 80)
            let blankLine = index > 0 && line.rect.minY - ordered[index - 1].rect.maxY > max(line.rect.height, ordered[index - 1].rect.height) * 0.9
            return (blankLine ? "\n" : "") + String(repeating: " ", count: indent) + line.text
        }.joined(separator: "\n")
    }
}

nonisolated protocol TextLayoutRecognizing: Sendable {
    func recognizeLayout(in image: CGImage) async throws -> RecognizedTextLayout
}

nonisolated struct VisionTextLayoutRecognizer: TextLayoutRecognizing {
    func recognizeLayout(in image: CGImage) async throws -> RecognizedTextLayout {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
            let size = CGSize(width: image.width, height: image.height)
            let lines = (request.results ?? []).compactMap { observation -> RecognizedTextLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let string = candidate.string
                var words: [RecognizedTextWord] = []
                string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .byWords) { word, range, _, _ in
                    guard let word, let box = try? candidate.boundingBox(for: range) else { return }
                    words.append(RecognizedTextWord(text: word, rect: Self.pixelRect(box.boundingBox, in: size)))
                }
                return RecognizedTextLine(text: string,
                    rect: Self.pixelRect(observation.boundingBox, in: size),
                    confidence: candidate.confidence, words: words)
            }
            return RecognizedTextLayout(lines: lines)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }
}

nonisolated enum RecognizedTextFormatting {
    static func preservingLines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    static func paragraph(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
