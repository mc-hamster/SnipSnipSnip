import CoreGraphics
import Foundation

nonisolated enum ScrollingStitchAppendResult: Equatable {
    case appended
    case lowConfidence
    case reachedMaximumHeight
}

nonisolated struct ScrollingStitchState {
    private var segments: [CGImage]
    private(set) var segmentCount: Int
    private(set) var width: Int
    private(set) var outputHeight: Int
    let maxOutputHeight: Int

    var image: CGImage {
        makeImage() ?? segments[0]
    }

    init(image: CGImage, maxOutputHeight: Int) {
        self.segments = [image]
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

    func makeImage() -> CGImage? {
        guard !segments.isEmpty else {
            return nil
        }

        return Self.combinedImage(segments: segments, height: outputHeight)
    }

    private static func combinedImage(segments: [CGImage], height: Int) -> CGImage? {
        guard let first = segments.first else {
            return nil
        }

        let width = first.width

        guard width > 0,
              height > 0,
              segments.allSatisfy({ $0.width == width }),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .none
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
    private let duplicateConfidence: Double
    private let sampleWidth: Int

    init(minimumConfidence: Double = 0.86, duplicateConfidence: Double = 0.995, sampleWidth: Int = 96) {
        self.minimumConfidence = minimumConfidence
        self.duplicateConfidence = duplicateConfidence
        self.sampleWidth = max(sampleWidth, 8)
    }

    func initialState(with image: CGImage, maxOutputHeight: Int) throws -> ScrollingStitchState {
        guard image.width > 0, image.height > 0 else {
            throw ScrollingCaptureError.firstFrameUnavailable
        }

        return ScrollingStitchState(image: image, maxOutputHeight: maxOutputHeight)
    }

    func imagesAreDuplicate(_ lhs: CGImage, _ rhs: CGImage, lhsGray: GrayImage? = nil, rhsGray: GrayImage? = nil) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              let left = lhsGray ?? makeGrayImage(for: lhs),
              let right = rhsGray ?? makeGrayImage(for: rhs),
              left.width == right.width, left.height == right.height else {
            return false
        }

        return confidence(left: left, leftY: 0, right: right, rightY: 0, height: left.height, minConfidence: duplicateConfidence) >= duplicateConfidence
    }

    func makeGrayImage(for image: CGImage) -> GrayImage? {
        GrayImage(image: image, sampleWidth: sampleWidth)
    }

    func append(_ nextImage: CGImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        append(nextImage, after: state.image, to: &state)
    }

    func append(_ nextImage: CGImage, after previousImage: CGImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        guard let previousGray = makeGrayImage(for: previousImage),
              let nextGray = makeGrayImage(for: nextImage) else {
            return .lowConfidence
        }

        return append(nextImage, after: previousImage, previousGray: previousGray, nextGray: nextGray, to: &state)
    }

    func append(_ nextImage: CGImage, after previousImage: CGImage, previousGray: GrayImage, nextGray: GrayImage, to state: inout ScrollingStitchState) -> ScrollingStitchAppendResult {
        guard state.width == nextImage.width,
              previousImage.width == nextImage.width,
              let match = bestMatch(previousGray: previousGray, nextGray: nextGray),
              match.confidence >= minimumConfidence else {
            return .lowConfidence
        }

        guard match.appendStartY < nextImage.height else {
            return .appended
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
            return .reachedMaximumHeight
        }

        guard let appendImage = nextImage.gscCropped(
            topLeftPixelRect: CGRect(x: 0, y: match.appendStartY, width: nextImage.width, height: appendHeight)
        ) else {
            return .lowConfidence
        }

        state.appendSegment(appendImage)
        return .appended
    }

    func bestMatch(previous: CGImage, next: CGImage) -> ScrollingStitchMatch? {
        guard previous.width == next.width,
              let previousGray = makeGrayImage(for: previous),
              let nextGray = makeGrayImage(for: next),
              previousGray.width == nextGray.width else {
            return nil
        }

        return bestMatch(previousGray: previousGray, nextGray: nextGray)
    }

    private func bestMatch(previousGray: GrayImage, nextGray: GrayImage) -> ScrollingStitchMatch? {
        let viewportHeight = min(previousGray.height, nextGray.height)
        let minimumOverlap = max(Int(Double(viewportHeight) * 0.15), 12)
        let maximumOverlap = max(min(Int(Double(viewportHeight) * 0.70), viewportHeight - 1), minimumOverlap)
        let maximumNextStart = min(max(Int(Double(viewportHeight) * 0.20), 0), min(160, nextGray.height - minimumOverlap))
        let preferredOverlap = max(Int(Double(viewportHeight) * 0.25), minimumOverlap)
        var best: ScrollingStitchMatch?

        let coarseStride = 16
        for nextStart in stride(from: 0, through: maximumNextStart, by: coarseStride) {
            for overlap in stride(from: minimumOverlap, through: min(maximumOverlap, nextGray.height - nextStart), by: coarseStride) {
                let previousStart = previousGray.height - overlap
                let score = confidence(
                    left: previousGray,
                    leftY: previousStart,
                    right: nextGray,
                    rightY: nextStart,
                    height: overlap,
                    maxRows: 32,
                    minConfidence: max(best?.confidence ?? minimumConfidence, minimumConfidence)
                )

                let candidate = ScrollingStitchMatch(overlapHeight: overlap, nextStartY: nextStart, confidence: score)
                if isBetterMatch(candidate, than: best, preferredOverlap: preferredOverlap) {
                    best = candidate
                }
            }
        }

        guard let coarse = best else {
            return nil
        }

        return refinedMatch(
            previous: previousGray,
            next: nextGray,
            coarse: coarse,
            minimumOverlap: minimumOverlap,
            maximumOverlap: maximumOverlap,
            maximumNextStart: maximumNextStart
        )
    }

    private func refinedMatch(
        previous: GrayImage,
        next: GrayImage,
        coarse: ScrollingStitchMatch,
        minimumOverlap: Int,
        maximumOverlap: Int,
        maximumNextStart: Int
    ) -> ScrollingStitchMatch {
        var best = coarse
        let refinementRadius = 16
        let nextStartLowerBound = max(0, coarse.nextStartY - refinementRadius)
        let nextStartUpperBound = min(maximumNextStart, coarse.nextStartY + refinementRadius)
        let overlapLowerBound = max(minimumOverlap, coarse.overlapHeight - refinementRadius)
        let overlapUpperBound = min(maximumOverlap, coarse.overlapHeight + refinementRadius)
        let refinementStride = 2

        for nextStart in stride(from: nextStartLowerBound, through: nextStartUpperBound, by: refinementStride) {
            for overlap in stride(from: overlapLowerBound, through: overlapUpperBound, by: refinementStride) where overlap <= next.height - nextStart {
                let previousStart = previous.height - overlap
                let score = confidence(
                    left: previous,
                    leftY: previousStart,
                    right: next,
                    rightY: nextStart,
                    height: overlap,
                    minConfidence: max(best.confidence, minimumConfidence)
                )
                let candidate = ScrollingStitchMatch(overlapHeight: overlap, nextStartY: nextStart, confidence: score)

                if isBetterMatch(candidate, than: best, preferredOverlap: max(Int(Double(previous.height) * 0.25), minimumOverlap)) {
                    best = candidate
                }
            }
        }

        return best
    }

    private func isBetterMatch(
        _ candidate: ScrollingStitchMatch,
        than current: ScrollingStitchMatch?,
        preferredOverlap: Int
    ) -> Bool {
        guard let current else {
            return true
        }

        let meaningfulScoreDelta = 0.001
        if candidate.confidence > current.confidence + meaningfulScoreDelta {
            return true
        }

        if candidate.confidence < current.confidence - meaningfulScoreDelta {
            return false
        }

        let candidateDistance = abs(candidate.overlapHeight - preferredOverlap)
        let currentDistance = abs(current.overlapHeight - preferredOverlap)
        if candidateDistance != currentDistance {
            return candidateDistance < currentDistance
        }

        return candidate.nextStartY < current.nextStartY
    }

    private func confidence(
        left: GrayImage,
        leftY: Int,
        right: GrayImage,
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

        let width = left.width
        let rowStep = max(height / max(maxRows, 1), 1)
        let rows = (height + rowStep - 1) / rowStep
        let sampleCount = width * rows
        let maxAllowedDifference = Double(sampleCount) * 255 * (1 - minConfidence)

        var difference = 0
        var checkedRows = 0

        for yOffset in stride(from: 0, to: height, by: rowStep) {
            let leftOffset = (leftY + yOffset) * width
            let rightOffset = (rightY + yOffset) * width

            for x in 0..<width {
                difference += abs(Int(left.pixels[leftOffset + x]) - Int(right.pixels[rightOffset + x]))
            }

            checkedRows += 1
            if Double(difference) > maxAllowedDifference {
                return 0
            }
        }

        guard sampleCount > 0 else {
            return 0
        }

        let normalizedDifference = Double(difference) / Double(sampleCount * 255)
        return 1 - normalizedDifference
    }

}

nonisolated struct GrayImage {
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

        var gray = [UInt8](repeating: 0, count: resolvedWidth * resolvedHeight)
        for y in 0..<resolvedHeight {
            for x in 0..<resolvedWidth {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = Int(rgba[offset])
                let green = Int(rgba[offset + 1])
                let blue = Int(rgba[offset + 2])
                gray[y * resolvedWidth + x] = UInt8((red * 30 + green * 59 + blue * 11) / 100)
            }
        }

        width = resolvedWidth
        height = resolvedHeight
        pixels = gray
    }
}
