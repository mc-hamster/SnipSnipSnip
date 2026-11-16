import CoreGraphics

/// Tracks the viewport within a contiguous captured interval. Revisited rows
/// move the reference frame without adding pixels; upward motion can extend the
/// beginning as well as downward motion extending the end.
nonisolated struct ManualScrollingAccumulator: Sendable {
    private(set) var state: ScrollingStitchState
    private var reference: CGImage
    private var referenceSample: ScrollingSampleImage?
    private var position = 0
    private var beginning = 0
    private var headerHeight = 0
    private var end: Int
    private let stitcher: ScrollingStitcher

    init(first: CGImage, maximumHeight: Int, stitcher: ScrollingStitcher) throws {
        self.stitcher = stitcher
        state = try stitcher.initialState(with: first, maxOutputHeight: maximumHeight)
        reference = first
        referenceSample = stitcher.makeSampleImage(for: first)
        end = first.height
    }

    @concurrent
    func processing(_ image: CGImage) async -> (ManualScrollingAccumulator, ScrollingStitchAppendResult) {
        var updated = self
        let result = updated.consume(image)
        return (updated, result)
    }

    private mutating func consume(_ image: CGImage) -> ScrollingStitchAppendResult {
        guard image.width == reference.width, image.height == reference.height else { return .lowConfidence }
        if stitcher.imagesAreDuplicate(reference, image) { return .unchanged }
        guard let previous = referenceSample, let sample = stitcher.makeSampleImage(for: image) else { return .lowConfidence }
        let forward = stitcher.bestMatch(previousSample: previous, nextSample: sample)
        let backward = stitcher.bestMatch(previousSample: sample, nextSample: previous)
        let distance: Int
        switch (forward, backward) {
        case let (a?, b?):
            let down = image.height - a.appendStartY
            let up = image.height - b.appendStartY
            // Do not select a direction from equally plausible repeated rows.
            if down > 0, up > 0, abs(a.confidence - b.confidence) < 0.005 { return .lowConfidence }
            distance = a.confidence >= b.confidence ? down : -up
        case let (a?, nil): distance = image.height - a.appendStartY
        case let (nil, b?): distance = -(image.height - b.appendStartY)
        case (nil, nil): return .lowConfidence
        }
        if distance != 0 {
            // Preserve a fixed header once at the top when extending upward.
            // Blank matching backgrounds alone are not evidence of a header.
            let rowWidth = sample.width * 3
            var prefix = 0
            var edgeMagnitude: Float = 0
            for row in 0..<min(160, image.height / 5) {
                let range = (row * rowWidth)..<((row + 1) * rowWidth)
                guard previous.colors[range].elementsEqual(sample.colors[range]) else { break }
                prefix += 1
                edgeMagnitude += sample.edgeMagnitudes[row]
            }
            if prefix >= 2 && edgeMagnitude > 0 { headerHeight = max(headerHeight, prefix) }
        }
        let (newPosition, overflow) = position.addingReportingOverflow(distance)
        guard !overflow else { return .lowConfidence }
        let newEnd = newPosition + image.height
        let prepend = max(beginning - newPosition, 0)
        let append = max(newEnd - end, 0)
        let added = max(prepend, append)
        if added > 0 {
            let available = state.maxOutputHeight - state.outputHeight
            let height = min(added, available)
            guard height > 0 else { return .reachedMaximumHeight }
            // At the upper capacity boundary keep the portion adjacent to the
            // accepted interval, never create a gap by retaining its far end.
            let startY = prepend > 0 ? prepend - height : image.height - append
            guard let strip = stitcher.ownedStrip(image, startY: startY, height: height) else { return .lowConfidence }
            if prepend > 0 {
                if headerHeight > 0 {
                    guard let header = stitcher.ownedStrip(image, startY: 0, height: headerHeight),
                          let content = stitcher.ownedStrip(image, startY: startY + headerHeight, height: height) else { return .lowConfidence }
                    var leading = ScrollingStitchState(image: header, maxOutputHeight: headerHeight + height)
                    leading.appendSegment(content)
                    guard let combined = leading.makeImage(),
                          state.prependSegment(combined, replacingPrefixRows: headerHeight, stitcher: stitcher) else { return .lowConfidence }
                } else { state.prependSegment(strip) }
                beginning -= height
            } else {
                state.appendSegment(strip)
                end += height
            }
        }
        position = newPosition
        reference = image
        referenceSample = sample
        return state.outputHeight >= state.maxOutputHeight ? .reachedMaximumHeight : (added > 0 ? .appended : .unchanged)
    }
}
