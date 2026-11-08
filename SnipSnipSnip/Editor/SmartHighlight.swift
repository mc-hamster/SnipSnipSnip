import CoreGraphics
import Foundation

nonisolated enum SmartHighlightGeometry {
    /// Fit only words actually crossed by the stroke. A bounding-box-only
    /// test would incorrectly select every word inside a curved gesture.
    static func fittedRects(points: [CGPoint], lines: [RecognizedTextLine], offset: CGPoint = .zero) -> [CGRect] {
        guard points.count > 1 else { return [] }
        return lines.filter { $0.confidence >= 0.65 }.flatMap { line -> [CGRect] in
            let words = line.words.isEmpty ? [RecognizedTextWord(text: line.text, rect: line.rect)] : line.words
            let rects = words.map { $0.rect.offsetBy(dx: offset.x, dy: offset.y) }.sorted { $0.minX < $1.minX }
            var groups: [CGRect] = []
            var current: CGRect?
            for rect in rects {
                let tolerance = min(max(rect.height * 0.25, 2), 8)
                let hitRect = rect.insetBy(dx: -tolerance, dy: -tolerance)
                let crossed = zip(points, points.dropFirst()).contains { intersects($0, $1, rect: hitRect) }
                guard crossed else {
                    if let group = current { groups.append(group); current = nil }
                    continue
                }
                if let group = current, rect.minX - group.maxX <= line.rect.height {
                    current = group.union(rect)
                } else {
                    if let group = current { groups.append(group) }
                    current = rect
                }
            }
            if let group = current { groups.append(group) }
            return groups.map { $0.insetBy(dx: -2, dy: -max(1, $0.height * 0.1)).integral }
        }
    }

    private static func intersects(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for (start, delta, minimum, maximum) in [(a.x, b.x - a.x, rect.minX, rect.maxX), (a.y, b.y - a.y, rect.minY, rect.maxY)] {
            if abs(delta) < 0.0001 {
                if start < minimum || start > maximum { return false }
            } else {
                let first = (minimum - start) / delta
                let last = (maximum - start) / delta
                lower = max(lower, min(first, last))
                upper = min(upper, max(first, last))
                if lower > upper { return false }
            }
        }
        return true
    }
}

nonisolated struct FitHighlightStrokeCommand: DocumentCommand {
    let strokeID: UUID
    let highlights: [Annotation]
    var label: String { "Fit Highlight to Text" }

    func apply(to snapshot: EditorSnapshot) -> EditorSnapshot {
        guard snapshot.annotations.contains(where: { $0.id == strokeID }) else { return snapshot }
        var updated = snapshot
        updated.annotations = snapshot.annotations.flatMap { $0.id == strokeID ? highlights : [$0] }
        updated.selectedAnnotationIDs = highlights.map(\.id)
        return updated
    }
}

@MainActor
extension EditorController {
    func addDrawnAnnotation(_ annotation: Annotation, recognizer: any TextLayoutRecognizing = VisionTextLayoutRecognizer()) {
        addAnnotation(annotation)
        guard smartHighlightEnabled, case let .highlighter(stroke) = annotation.kind else { return }
        let original = snapshot
        let revision = persistenceRevision
        let scope = compositionEditingScope
        let captureID = capture.id
        let image = capture.image
        let crop = annotation.boundingRect.insetBy(dx: -64, dy: -32)
            .intersection(snapshot.cropRect).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard let sample = CaptureTextRecognizer.cropImage(in: image, region: crop) else { return }
        Task { @MainActor [weak self] in
            guard let layout = try? await recognizer.recognizeLayout(in: sample),
                  let self, self.smartHighlightEnabled, self.capture.id == captureID,
                  self.compositionEditingScope == scope, self.persistenceRevision == revision,
                  self.snapshot == original else { return }
            let rects = SmartHighlightGeometry.fittedRects(points: stroke.points, lines: layout.lines, offset: crop.origin)
                .map { $0.intersection(original.cropRect) }.filter { !$0.isEmpty }
            guard !rects.isEmpty else { return }
            // Preserve the marker's rendering, color, and opacity. Straight
            // two-point strokes adopt each recognized line's actual height.
            let highlights = rects.map { rect in
                var style = annotation.style
                style.lineWidth = rect.height
                return Annotation.makeHighlighter(points: [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)], style: style)
            }
            // The original stroke is still the latest undoable mutation. Fit
            // it in place so Undo removes the whole gesture and Redo restores
            // the fitted result. Any intervening change retains the freehand.
            self.execute(FitHighlightStrokeCommand(strokeID: annotation.id, highlights: highlights), undoable: false)
        }
    }
}
