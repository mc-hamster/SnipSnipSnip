import CoreGraphics
import Foundation

nonisolated enum ScrollingStitchAppendResult: Equatable {
    case appended
    case unchanged
    case lowConfidence
    case reachedMaximumHeight
}

nonisolated struct ScrollingStitchState {
    private var segments: [CGImage]
    fileprivate private(set) var lastCapturedFrame: CGImage
    private(set) var segmentCount: Int
    private(set) var width: Int
    private(set) var outputHeight: Int
    let maxOutputHeight: Int

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

nonisolated struct ScrollingStitcher {
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
            guard let cropped = image.gscCropped(topLeftPixelRect: CGRect(x: 0, y: 0, width: image.width, height: limit)) else {
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
        let targetHeight = state.outputHeight + appendHeight

        guard targetHeight <= state.maxOutputHeight else {
            let allowedHeight = state.maxOutputHeight - state.outputHeight
            guard allowedHeight > 0,
                  let partialAppend = nextImage.gscCropped(
                    topLeftPixelRect: CGRect(x: 0, y: match.appendStartY, width: nextImage.width, height: allowedHeight)
                  ) else {
                return .reachedMaximumHeight
            }

            state.appendSegment(partialAppend)
            state.recordCapturedFrame(nextImage)
            return .reachedMaximumHeight
        }

        guard let appendImage = nextImage.gscCropped(
            topLeftPixelRect: CGRect(x: 0, y: match.appendStartY, width: nextImage.width, height: appendHeight)
        ) else {
            return .lowConfidence
        }

        state.appendSegment(appendImage)
        state.recordCapturedFrame(nextImage)
        return targetHeight == state.maxOutputHeight ? .reachedMaximumHeight : .appended
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

    private func bestMatch(previousSample: ScrollingSampleImage, nextSample: ScrollingSampleImage) -> ScrollingStitchMatch? {
        let viewportHeight = min(previousSample.height, nextSample.height)
        let minimumOverlap = max(Int(Double(viewportHeight) * 0.15), min(12, max(viewportHeight / 4, 1)))
        let maximumOverlap = viewportHeight
        guard maximumOverlap >= minimumOverlap else {
            return nil
        }
        let maximumHeaderHeight = min(Int(Double(viewportHeight) * 0.20), 160)
        var best: ScrollingStitchMatch?

        // The last scroll can advance by just one pixel or not move at all.
        // Search every seam, including zero movement, so a stationary frame
        // with a blinking caret cannot force a duplicate tail into the output.
        // Excluding a bounded header from both aligned strips keeps sticky
        // headers out of scoring without a second search dimension. The seam
        // remains totalOverlap regardless of how much header was excluded.
        for totalOverlap in minimumOverlap...maximumOverlap {
            let nextStart = min(maximumHeaderHeight, totalOverlap - minimumOverlap)
            let overlap = totalOverlap - nextStart
            let score = confidence(
                left: previousSample,
                leftY: previousSample.height - overlap,
                right: nextSample,
                rightY: nextStart,
                height: overlap,
                minConfidence: max(best?.confidence ?? minimumConfidence, minimumConfidence)
            )
            let candidate = ScrollingStitchMatch(overlapHeight: overlap, nextStartY: nextStart, confidence: score)
            if isBetterMatch(candidate, than: best) {
                best = candidate
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

        var difference = 0
        var edgeDifference = 0
        var edgeMagnitude = 0

        for yOffset in stride(from: 0, to: height, by: rowStep) {
            let leftOffset = (leftY + yOffset) * width
            let rightOffset = (rightY + yOffset) * width

            for x in 0..<width {
                difference += abs(Int(left.pixels[leftOffset + x]) - Int(right.pixels[rightOffset + x]))
                if x >= 3 {
                    let leftEdge = Int(left.pixels[leftOffset + x]) - Int(left.pixels[leftOffset + x - 3])
                    let rightEdge = Int(right.pixels[rightOffset + x]) - Int(right.pixels[rightOffset + x - 3])
                    edgeDifference += abs(leftEdge - rightEdge)
                    edgeMagnitude += abs(leftEdge) + abs(rightEdge)
                }
            }

            if Double(difference) > maxAllowedDifference {
                return 0
            }
        }

        guard sampleCount > 0 else {
            return 0
        }

        let normalizedDifference = Double(difference) / Double(sampleCount * 255)
        let colorConfidence = 1 - normalizedDifference
        // White page backgrounds can dominate an average color score even when
        // every text edge is misplaced. Require the informative edges to agree
        // too; flat-color strips still use their color score.
        let edgeConfidence = edgeMagnitude > 0 ? 1 - Double(edgeDifference) / Double(edgeMagnitude) : 1
        return min(colorConfidence, edgeConfidence)
    }

}

nonisolated struct ScrollingSampleImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

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
        var samples = [UInt8](repeating: 0, count: resolvedWidth * resolvedHeight * 3)
        for y in 0..<resolvedHeight {
            for x in 0..<resolvedWidth {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let sampleOffset = (y * resolvedWidth + x) * 3
                samples[sampleOffset] = rgba[offset]
                samples[sampleOffset + 1] = rgba[offset + 1]
                samples[sampleOffset + 2] = rgba[offset + 2]
            }
        }

        width = resolvedWidth
        height = resolvedHeight
        pixels = samples
    }
}
