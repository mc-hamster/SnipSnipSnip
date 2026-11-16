import Accelerate
import CoreGraphics
import Foundation

nonisolated enum ScrollingStitchAppendResult: Equatable, Sendable {
    case appended
    case unchanged
    case lowConfidence
    case reachedMaximumHeight
}

nonisolated struct ScrollingStitchState: Sendable {
    private var segments: [CGImage]
    fileprivate private(set) var lastCapturedFrame: CGImage
    private(set) var segmentCount: Int
    private(set) var width: Int
    private(set) var outputHeight: Int
    let maxOutputHeight: Int

    var retainedSegmentBytes: Int {
        segments.reduce(0) { total, image in
            total + (image.dataProvider?.data.map { CFDataGetLength($0) } ?? image.bytesPerRow * image.height)
        }
    }

    var image: CGImage {
        makeImage() ?? segments[0]
    }

    init(image: CGImage, maxOutputHeight: Int) {
        self.segments = [image]
        self.lastCapturedFrame = image
        self.segmentCount = 1
        self.width = image.width
        self.outputHeight = image.height
        self.maxOutputHeight = max(maxOutputHeight, 1)
    }

    mutating func appendSegment(_ image: CGImage) {
        segments.append(image)
        outputHeight += image.height
        segmentCount += 1
    }

    mutating func prependSegment(_ image: CGImage) {
        segments.insert(image, at: 0)
        outputHeight += image.height
        segmentCount += 1
    }

    mutating func prependSegment(_ image: CGImage, replacingPrefixRows count: Int, stitcher: ScrollingStitcher) -> Bool {
        guard count >= 0, count <= outputHeight else { return false }
        var remaining = count
        var retained: [CGImage] = []
        for segment in segments {
            if remaining >= segment.height { remaining -= segment.height; continue }
            if remaining > 0 {
                guard let trimmed = stitcher.ownedStrip(segment, startY: remaining, height: segment.height - remaining) else { return false }
                retained.append(trimmed)
                remaining = 0
            } else { retained.append(segment) }
        }
        segments = [image] + retained
        outputHeight += image.height - count
        segmentCount += 1
        return true
    }

    mutating func recordCapturedFrame(_ image: CGImage) {
        lastCapturedFrame = image
    }

    func makeImage() -> CGImage? {
        guard !segments.isEmpty else {
            return nil
        }

        return Self.combinedImage(segments: segments, height: outputHeight)
    }

    func makePreviewImage(maximumDimension: Int = 512) -> CGImage? {
        Self.combinedImage(segments: segments, height: outputHeight, maximumDimension: max(maximumDimension, 1))
    }

    private static func combinedImage(segments: [CGImage], height: Int, maximumDimension: Int? = nil) -> CGImage? {
        guard let first = segments.first else {
            return nil
        }

        let width = first.width
        let scale = maximumDimension.map { min(CGFloat($0) / CGFloat(max(width, height)), 1) } ?? 1
        let outputWidth = max(Int((CGFloat(width) * scale).rounded(.down)), 1)
        let outputHeight = max(Int((CGFloat(height) * scale).rounded(.down)), 1)

        guard width > 0,
              height > 0,
              segments.allSatisfy({ $0.width == width }),
              let context = SRGBBitmapContext.make(
                  width: outputWidth,
                  height: outputHeight
              ) else {
            return nil
        }

        context.interpolationQuality = maximumDimension == nil ? .none : .low
        context.scaleBy(x: CGFloat(outputWidth) / CGFloat(width), y: CGFloat(outputHeight) / CGFloat(height))
        var y = height
        for segment in segments {
            y -= segment.height
            context.draw(segment, in: CGRect(x: 0, y: CGFloat(y), width: CGFloat(segment.width), height: CGFloat(segment.height)))
        }

        return context.makeImage()
    }
}

nonisolated struct ScrollingStitchMatch: Equatable {
    let overlapHeight: Int
    let nextStartY: Int
    let confidence: Double

    var appendStartY: Int {
        nextStartY + overlapHeight
    }
}

nonisolated struct ScrollingStitchFrameResult: Sendable {
    let result: ScrollingStitchAppendResult
    let state: ScrollingStitchState
    let sample: ScrollingSampleImage?
}

nonisolated struct ScrollingStitcher: Sendable {
    private let minimumConfidence: Double
    private let sampleWidth: Int

    init(minimumConfidence: Double = 0.86, sampleWidth: Int = 96) {
        self.minimumConfidence = minimumConfidence
        self.sampleWidth = max(sampleWidth, 8)
    }

    func initialState(with image: CGImage, maxOutputHeight: Int) throws -> ScrollingStitchState {
        guard image.width > 0, image.height > 0 else {
            throw ScrollingCaptureError.firstFrameUnavailable
        }

        let limit = max(maxOutputHeight, 1)
        let outputImage: CGImage
        if image.height > limit {
            guard let cropped = ownedStrip(image, startY: 0, height: limit) else {
                throw ScrollingCaptureError.stitchingFailed
            }
            outputImage = cropped
        } else {
            outputImage = image
        }
        var state = ScrollingStitchState(image: outputImage, maxOutputHeight: limit)
        state.recordCapturedFrame(image)
        return state
    }

    func imagesAreDuplicate(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.bitsPerPixel == rhs.bitsPerPixel,
              lhs.bitsPerComponent == rhs.bitsPerComponent,
              lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.bitmapInfo == rhs.bitmapInfo,
              let left = lhs.dataProvider?.data,
              let right = rhs.dataProvider?.data else {
            return false
        }

        // Average similarity can hide a short final movement or a changed last
        // row. End detection must not discard pixels merely because most of the
        // viewport is unchanged. Compare the complete raster conservatively.
        return CFEqual(left, right)
    }

    func makeSampleImage(for image: CGImage) -> ScrollingSampleImage? {
        ScrollingSampleImage(image: image, sampleWidth: sampleWidth)
    }

    @concurrent
    func prepareSample(for image: CGImage) async -> ScrollingSampleImage? {
        makeSampleImage(for: image)
    }

    @concurrent
    func appendingFrame(
        _ image: CGImage, after previousImage: CGImage,
        previousSample: ScrollingSampleImage?, to state: ScrollingStitchState
    ) async -> ScrollingStitchFrameResult {
        var updated = state
        let sample = makeSampleImage(for: image)
        let result: ScrollingStitchAppendResult
        if let previousSample, let sample {
            result = append(image, after: previousImage, previousSample: previousSample, nextSample: sample, to: &updated)
        } else {
            result = append(image, after: previousImage, to: &updated)
        }
        return ScrollingStitchFrameResult(result: result, state: updated, sample: sample)
    }

    @concurrent
    func makeOutput(for state: ScrollingStitchState) async -> CGImage? {
        state.makeImage()
    }

    @concurrent
    func makePreview(for state: ScrollingStitchState) async -> CGImage? {
        state.makePreviewImage()
    }

    func append(_ nextImage: CGImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        append(nextImage, after: state.lastCapturedFrame, to: &state)
    }

    func append(_ nextImage: CGImage, after previousImage: CGImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        guard let previousSample = makeSampleImage(for: previousImage),
              let nextSample = makeSampleImage(for: nextImage) else {
            return .lowConfidence
        }

        return append(nextImage, after: previousImage, previousSample: previousSample, nextSample: nextSample, to: &state)
    }

    func append(_ nextImage: CGImage, after previousImage: CGImage, previousSample: ScrollingSampleImage, nextSample: ScrollingSampleImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        // A repeated terminal frame contributes no new rows, even when append is
        // used without the capture service's duplicate-frame preflight.
        if imagesAreDuplicate(previousImage, nextImage) {
            return .unchanged
        }

        guard state.width == nextImage.width,
              previousImage.width == nextImage.width,
              previousImage.height == nextImage.height,
              let match = bestMatch(previousSample: previousSample, nextSample: nextSample),
              match.confidence >= minimumConfidence else {
            return .lowConfidence
        }

        guard match.appendStartY < nextImage.height else {
            state.recordCapturedFrame(nextImage)
            return .unchanged
        }

        let appendHeight = nextImage.height - match.appendStartY
        let (targetHeight, overflow) = state.outputHeight.addingReportingOverflow(appendHeight)
        guard !overflow else { return .reachedMaximumHeight }

        guard targetHeight <= state.maxOutputHeight else {
            let allowedHeight = state.maxOutputHeight - state.outputHeight
            guard allowedHeight > 0,
                  let partialAppend = ownedStrip(nextImage, startY: match.appendStartY, height: allowedHeight) else {
                return .reachedMaximumHeight
            }

            state.appendSegment(partialAppend)
            state.recordCapturedFrame(nextImage)
            return .reachedMaximumHeight
        }

        guard let appendImage = ownedStrip(nextImage, startY: match.appendStartY, height: appendHeight) else {
            return .lowConfidence
        }

        state.appendSegment(appendImage)
        state.recordCapturedFrame(nextImage)
        return targetHeight == state.maxOutputHeight ? .reachedMaximumHeight : .appended
    }

    // CGImage crops can retain their entire source provider. A one-pixel scroll
    // must retain one row, not another full viewport, throughout a long session.
    func ownedStrip(_ image: CGImage, startY: Int, height: Int) -> CGImage? {
        guard startY >= 0, height > 0, height <= image.height, startY <= image.height - height else { return nil }
        guard let crop = image.gscCropped(topLeftPixelRect: CGRect(
            x: 0, y: startY, width: image.width, height: height
        )), let context = SRGBBitmapContext.make(width: image.width, height: height) else { return nil }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        return context.makeImage()
    }

    func bestMatch(previous: CGImage, next: CGImage) -> ScrollingStitchMatch? {
        guard previous.width == next.width, previous.height == next.height,
              let previousSample = makeSampleImage(for: previous),
              let nextSample = makeSampleImage(for: next),
              previousSample.width == nextSample.width else {
            return nil
        }

        return bestMatch(previousSample: previousSample, nextSample: nextSample)
    }

    func bestMatch(previousSample: ScrollingSampleImage, nextSample: ScrollingSampleImage) -> ScrollingStitchMatch? {
        let viewportHeight = min(previousSample.height, nextSample.height)
        let minimumOverlap = max(Int(Double(viewportHeight) * 0.15), min(12, max(viewportHeight / 4, 1)))
        let maximumOverlap = viewportHeight
        guard maximumOverlap >= minimumOverlap else {
            return nil
        }
        let maximumHeaderHeight = min(Int(Double(viewportHeight) * 0.20), 160)
        let ambiguityMargin = 0.000_1
        var candidates: [ScrollingStitchMatch] = []
        var best: ScrollingStitchMatch?
        var differences = [Float](repeating: 0, count: previousSample.width * 3)

        // The last scroll can advance by just one pixel or not move at all.
        // Search every seam, including zero movement, so a stationary frame
        // with a blinking caret cannot force a duplicate tail into the output.
        // Excluding a bounded header from both aligned strips keeps sticky
        // headers out of scoring without a second search dimension. The seam
        // remains totalOverlap regardless of how much header was excluded.
        // Check small movements first so their strong scores can cheaply rule
        // out the remaining candidates without sampling every overlap in full.
        for totalOverlap in stride(from: maximumOverlap, through: minimumOverlap, by: -1) {
            let nextStart = min(maximumHeaderHeight, totalOverlap - minimumOverlap)
            let overlap = totalOverlap - nextStart
            let score = confidence(
                left: previousSample,
                leftY: previousSample.height - overlap,
                right: nextSample,
                rightY: nextStart,
                height: overlap,
                differences: &differences,
                minConfidence: max((best?.confidence ?? minimumConfidence) - ambiguityMargin, minimumConfidence)
            )
            let candidate = ScrollingStitchMatch(overlapHeight: overlap, nextStartY: nextStart, confidence: score)
            if score >= minimumConfidence {
                candidates.append(candidate)
            }
            if isBetterMatch(candidate, than: best) {
                best = candidate
            }
        }

        guard var best, best.confidence >= minimumConfidence else { return nil }
        if best.appendStartY < viewportHeight {
            // Sparse sampling can make adjacent offsets through repeated text
            // baselines appear equally perfect. Verify every row of plausible
            // moving matches before deciding their alignment is ambiguous.
            // Stationary/blank frames retain their conservative no-new-rows path.
            var verified: [ScrollingStitchMatch] = []
            for candidate in candidates {
                let score = confidence(
                    left: previousSample, leftY: previousSample.height - candidate.overlapHeight,
                    right: nextSample, rightY: candidate.nextStartY,
                    height: candidate.overlapHeight, differences: &differences,
                    maxRows: Int.max, minConfidence: minimumConfidence
                )
                if score >= minimumConfidence {
                    verified.append(ScrollingStitchMatch(overlapHeight: candidate.overlapHeight,
                        nextStartY: candidate.nextStartY, confidence: score))
                }
            }
            guard var refined = verified.first else { return nil }
            for candidate in verified.dropFirst() where isBetterMatch(candidate, than: refined) { refined = candidate }
            best = refined
            candidates = verified
        }
        // A stationary match never invents content. For movement, distinct
        // equally plausible offsets are ambiguous (for example repeated rows).
        // Let the capture service retry or offer the accepted partial result.
        if best.appendStartY < viewportHeight,
           candidates.contains(where: {
               abs($0.appendStartY - best.appendStartY) > 1
                   && $0.confidence >= best.confidence - ambiguityMargin
           }) {
            return nil
        }
        // A good average can conceal a local layout shift (for example an
        // image loading in the middle of the overlap). Independently validate
        // three bands before accepting movement. Stationary frames can retain
        // the accepted pixels without inventing any new content.
        if best.appendStartY < viewportHeight {
            let bandCount = min(3, best.overlapHeight)
            for band in 0..<bandCount {
                let start = best.overlapHeight * band / bandCount
                let end = best.overlapHeight * (band + 1) / bandCount
                let score = confidence(
                    left: previousSample, leftY: previousSample.height - best.overlapHeight + start,
                    right: nextSample, rightY: best.nextStartY + start,
                    height: end - start, differences: &differences,
                    minConfidence: minimumConfidence
                )
                guard score >= minimumConfidence else { return nil }
            }
        }
        return best
    }

    private func isBetterMatch(
        _ candidate: ScrollingStitchMatch,
        than current: ScrollingStitchMatch?
    ) -> Bool {
        guard let current else {
            return true
        }

        if candidate.confidence > current.confidence {
            return true
        }

        if candidate.confidence < current.confidence {
            return false
        }

        // Repeated or blank content cannot prove a larger scroll. Prefer the
        // smallest movement supported by equally good matches, including zero.
        return candidate.appendStartY > current.appendStartY
    }

    private func confidence(
        left: ScrollingSampleImage,
        leftY: Int,
        right: ScrollingSampleImage,
        rightY: Int,
        height: Int,
        differences: inout [Float],
        maxRows: Int = 160,
        minConfidence: Double = 0
    ) -> Double {
        guard left.width == right.width,
              height > 0,
              leftY >= 0,
              rightY >= 0,
              leftY + height <= left.height,
              rightY + height <= right.height else {
            return 0
        }

        let width = left.width * 3
        let rowStep = max(height / max(maxRows, 1), 1)
        let rows = (height + rowStep - 1) / rowStep
        let sampleCount = width * rows
        let maxAllowedDifference = Double(sampleCount) * 255 * (1 - minConfidence)

        // Accelerate executes the pixel arithmetic in optimized vector code even
        // in Xcode's Debug builds. The metric and sampled rows are unchanged.
        return left.colors.withUnsafeBufferPointer { leftColors in
            right.colors.withUnsafeBufferPointer { rightColors in
                left.edges.withUnsafeBufferPointer { leftEdges in
                    right.edges.withUnsafeBufferPointer { rightEdges in
                        differences.withUnsafeMutableBufferPointer { scratch in
                            var difference: Double = 0
                            var edgeDifference: Double = 0
                            var edgeMagnitude: Double = 0
                            let count = vDSP_Length(width)
                            for yOffset in stride(from: 0, to: height, by: rowStep) {
                                let leftRow = leftY + yOffset
                                let rightRow = rightY + yOffset
                                let leftOffset = leftRow * width
                                let rightOffset = rightRow * width
                                var rowDifference: Float = 0
                                vDSP_vsub(leftColors.baseAddress! + leftOffset, 1,
                                          rightColors.baseAddress! + rightOffset, 1,
                                          scratch.baseAddress!, 1, count)
                                vDSP_svemg(scratch.baseAddress!, 1, &rowDifference, count)
                                difference += Double(rowDifference)
                                if difference > maxAllowedDifference { return 0 }

                                vDSP_vsub(leftEdges.baseAddress! + leftOffset, 1,
                                          rightEdges.baseAddress! + rightOffset, 1,
                                          scratch.baseAddress!, 1, count)
                                vDSP_svemg(scratch.baseAddress!, 1, &rowDifference, count)
                                edgeDifference += Double(rowDifference)
                                edgeMagnitude += Double(left.edgeMagnitudes[leftRow]) + Double(right.edgeMagnitudes[rightRow])
                            }

                            let colorConfidence = 1 - difference / Double(sampleCount * 255)
                            // Edge positions still reject unrelated text on white backgrounds.
                            let edgeConfidence = edgeMagnitude > 0 ? 1 - edgeDifference / edgeMagnitude : 1
                            return min(colorConfidence, edgeConfidence)
                        }
                    }
                }
            }
        }
    }

}

nonisolated struct ScrollingSampleImage: Sendable {
    let width: Int
    let height: Int
    let colors: [Float]
    let edges: [Float]
    let edgeMagnitudes: [Float]

    init?(image: CGImage, sampleWidth: Int) {
        let resolvedWidth = min(max(sampleWidth, 8), image.width)
        let resolvedHeight = image.height
        let bytesPerPixel = 4
        let bytesPerRow = resolvedWidth * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: resolvedHeight * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: resolvedWidth,
                height: resolvedHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: resolvedWidth, height: resolvedHeight))

        // Preserve color channels: different colored rows can have identical
        // luminance, which otherwise looks like a stationary or repeated page.
        let rowWidth = resolvedWidth * 3
        let pixelCount = resolvedWidth * resolvedHeight
        var colors = [Float](repeating: 0, count: pixelCount * 3)
        rgba.withUnsafeBufferPointer { source in
            colors.withUnsafeMutableBufferPointer { target in
                for channel in 0..<3 {
                    vDSP_vfltu8(source.baseAddress! + channel, 4,
                                target.baseAddress! + channel, 3, vDSP_Length(pixelCount))
                }
            }
        }
        var edges = [Float](repeating: 0, count: colors.count)
        var edgeMagnitudes = [Float](repeating: 0, count: resolvedHeight)
        colors.withUnsafeBufferPointer { source in
            edges.withUnsafeMutableBufferPointer { target in
                // Bound edge amplitude on both sides so isolated visual updates
                // cannot outweigh aligned edges. Cache this once per frame.
                var minimum: Float = -4
                var maximum: Float = 4
                for row in 0..<resolvedHeight where rowWidth > 3 {
                    let offset = row * rowWidth
                    let count = vDSP_Length(rowWidth - 3)
                    let output = target.baseAddress! + offset + 3
                    vDSP_vsub(source.baseAddress! + offset, 1,
                              source.baseAddress! + offset + 3, 1, output, 1, count)
                    vDSP_vclip(output, 1, &minimum, &maximum, output, 1, count)
                    vDSP_svemg(output, 1, &edgeMagnitudes[row], count)
                }
            }
        }
        self.width = resolvedWidth
        self.height = resolvedHeight
        self.colors = colors
        self.edges = edges
        self.edgeMagnitudes = edgeMagnitudes
    }
}
