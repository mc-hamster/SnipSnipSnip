import AppKit
import CoreGraphics

nonisolated enum SnapOrientation: Equatable {
    case horizontal
    case vertical
}

nonisolated struct SnapGuide: Equatable {
    let orientation: SnapOrientation
    let position: CGFloat
}

nonisolated struct SnapResolution: Equatable {
    let rect: CGRect
    let guides: [SnapGuide]
}

nonisolated struct SnapCandidateSet {
    fileprivate struct Candidate {
        let value: CGFloat
        let order: Int
    }

    fileprivate let bounds: CGRect
    fileprivate let xCandidates: [Candidate]
    fileprivate let yCandidates: [Candidate]

    init(bounds: CGRect, others: [CGRect]) {
        self.bounds = bounds

        var xCandidates: [Candidate] = []
        var yCandidates: [Candidate] = []
        xCandidates.reserveCapacity(3 + others.count * 3)
        yCandidates.reserveCapacity(3 + others.count * 3)

        func appendX(_ value: CGFloat) {
            xCandidates.append(Candidate(value: value, order: xCandidates.count))
        }

        func appendY(_ value: CGFloat) {
            yCandidates.append(Candidate(value: value, order: yCandidates.count))
        }

        appendX(bounds.minX)
        appendX(bounds.midX)
        appendX(bounds.maxX)
        appendY(bounds.minY)
        appendY(bounds.midY)
        appendY(bounds.maxY)

        for rect in others {
            appendX(rect.minX)
            appendX(rect.midX)
            appendX(rect.maxX)
            appendY(rect.minY)
            appendY(rect.midY)
            appendY(rect.maxY)
        }

        self.xCandidates = xCandidates.sorted {
            $0.value == $1.value ? $0.order < $1.order : $0.value < $1.value
        }
        self.yCandidates = yCandidates.sorted {
            $0.value == $1.value ? $0.order < $1.order : $0.value < $1.value
        }
    }
}

nonisolated struct SignedScaleBounds: Equatable {
    let minXTarget: CGFloat
    let maxXTarget: CGFloat
    let minYTarget: CGFloat
    let maxYTarget: CGFloat

    var rect: CGRect {
        CGRect(
            x: min(minXTarget, maxXTarget),
            y: min(minYTarget, maxYTarget),
            width: abs(maxXTarget - minXTarget),
            height: abs(maxYTarget - minYTarget)
        ).integral
    }

    var isFlippedHorizontally: Bool {
        maxXTarget < minXTarget
    }

    var isFlippedVertically: Bool {
        maxYTarget < minYTarget
    }

    func resolved(to rect: CGRect) -> SignedScaleBounds {
        let standardizedRect = rect.standardized.integral

        return SignedScaleBounds(
            minXTarget: isFlippedHorizontally ? standardizedRect.maxX : standardizedRect.minX,
            maxXTarget: isFlippedHorizontally ? standardizedRect.minX : standardizedRect.maxX,
            minYTarget: isFlippedVertically ? standardizedRect.maxY : standardizedRect.minY,
            maxYTarget: isFlippedVertically ? standardizedRect.minY : standardizedRect.maxY
        )
    }
}

extension NSScreen {
    nonisolated var gscDisplayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return CGDirectDisplayID(number.uint32Value)
    }

    var gscDisplayName: String {
        if #available(macOS 12.0, *) {
            return localizedName
        }

        return "Display"
    }
}

extension CGRect {
    nonisolated var gscIntegralStandardized: CGRect {
        standardized.integral
    }

    nonisolated func gscClamped(to bounds: CGRect) -> CGRect {
        guard !isNull, !bounds.isNull else {
            return .null
        }

        let x = min(max(minX, bounds.minX), bounds.maxX)
        let y = min(max(minY, bounds.minY), bounds.maxY)
        let maxX = min(max(self.maxX, bounds.minX), bounds.maxX)
        let maxY = min(max(self.maxY, bounds.minY), bounds.maxY)

        if maxX <= x || maxY <= y {
            return .null
        }

        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    nonisolated func gscScaled(x scaleX: CGFloat, y scaleY: CGFloat) -> CGRect {
        CGRect(
            x: origin.x * scaleX,
            y: origin.y * scaleY,
            width: size.width * scaleX,
            height: size.height * scaleY
        )
    }

    nonisolated func gscContained(in bounds: CGRect) -> CGRect {
        guard !isNull, !bounds.isNull else {
            return .null
        }

        let container = bounds.standardized.integral

        guard container.width > 0, container.height > 0 else {
            return .null
        }

        var contained = standardized.integral

        if contained.width >= container.width {
            contained.origin.x = container.minX
            contained.size.width = container.width
        } else if contained.minX < container.minX {
            contained.origin.x += container.minX - contained.minX
        } else if contained.maxX > container.maxX {
            contained.origin.x += container.maxX - contained.maxX
        }

        if contained.height >= container.height {
            contained.origin.y = container.minY
            contained.size.height = container.height
        } else if contained.minY < container.minY {
            contained.origin.y += container.minY - contained.minY
        } else if contained.maxY > container.maxY {
            contained.origin.y += container.maxY - contained.maxY
        }

        return contained.integral
    }
}

extension CGSize {
    nonisolated var gscIsFinite: Bool {
        width.isFinite && height.isFinite
    }

    nonisolated var gscAspectRatio: CGFloat {
        guard height != 0 else {
            return 1
        }

        return width / height
    }
}

extension CGPoint {
    nonisolated var gscIsFinite: Bool {
        x.isFinite && y.isFinite
    }

    nonisolated func gscOffsetting(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: self.x + x, y: self.y + y)
    }
}

extension CGRect {
    nonisolated var gscIsFinite: Bool {
        origin.gscIsFinite && size.gscIsFinite
    }

    nonisolated func gscFiniteOr(_ fallback: CGRect) -> CGRect {
        let standardizedRect = standardized
        guard standardizedRect.gscIsFinite else {
            return fallback.standardized
        }

        return standardizedRect
    }
}

nonisolated func gscDistanceFromPoint(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y

    if dx == 0, dy == 0 {
        return hypot(point.x - start.x, point.y - start.y)
    }

    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
    let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
    return hypot(point.x - projection.x, point.y - projection.y)
}

nonisolated func gscDistanceFromPoint(_ point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
    guard let first = points.first else {
        return .greatestFiniteMagnitude
    }

    guard points.count > 1 else {
        return hypot(point.x - first.x, point.y - first.y)
    }

    return zip(points, points.dropFirst()).map { segmentStart, segmentEnd in
        gscDistanceFromPoint(point, toSegmentFrom: segmentStart, to: segmentEnd)
    }.min() ?? .greatestFiniteMagnitude
}

nonisolated func gscBoundingRect(of rects: [CGRect]) -> CGRect {
    rects.reduce(CGRect.null) { partial, rect in
        partial.union(rect.standardized)
    }.gscIntegralStandardized
}

nonisolated func gscScaledPoint(_ point: CGPoint, from oldBounds: CGRect, to newBounds: CGRect) -> CGPoint {
    guard oldBounds.width > 0, oldBounds.height > 0 else {
        return newBounds.origin
    }

    let x = (point.x - oldBounds.minX) / oldBounds.width
    let y = (point.y - oldBounds.minY) / oldBounds.height

    return CGPoint(
        x: newBounds.minX + x * newBounds.width,
        y: newBounds.minY + y * newBounds.height
    )
}

nonisolated func gscScaledPoint(_ point: CGPoint, from oldBounds: CGRect, to newBounds: SignedScaleBounds) -> CGPoint {
    guard oldBounds.width > 0, oldBounds.height > 0 else {
        return CGPoint(x: newBounds.minXTarget, y: newBounds.minYTarget)
    }

    let x = (point.x - oldBounds.minX) / oldBounds.width
    let y = (point.y - oldBounds.minY) / oldBounds.height

    return CGPoint(
        x: newBounds.minXTarget + x * (newBounds.maxXTarget - newBounds.minXTarget),
        y: newBounds.minYTarget + y * (newBounds.maxYTarget - newBounds.minYTarget)
    )
}

nonisolated func gscScaledRect(_ rect: CGRect, from oldBounds: CGRect, to newBounds: CGRect) -> CGRect {
    let minPoint = gscScaledPoint(rect.origin, from: oldBounds, to: newBounds)
    let maxPoint = gscScaledPoint(CGPoint(x: rect.maxX, y: rect.maxY), from: oldBounds, to: newBounds)

    return CGRect(
        x: min(minPoint.x, maxPoint.x),
        y: min(minPoint.y, maxPoint.y),
        width: abs(maxPoint.x - minPoint.x),
        height: abs(maxPoint.y - minPoint.y)
    ).integral
}

nonisolated func gscScaledRect(_ rect: CGRect, from oldBounds: CGRect, to newBounds: SignedScaleBounds) -> CGRect {
    let standardizedRect = rect.standardized
    let minPoint = gscScaledPoint(standardizedRect.origin, from: oldBounds, to: newBounds)
    let maxPoint = gscScaledPoint(CGPoint(x: standardizedRect.maxX, y: standardizedRect.maxY), from: oldBounds, to: newBounds)

    return CGRect(
        x: min(minPoint.x, maxPoint.x),
        y: min(minPoint.y, maxPoint.y),
        width: abs(maxPoint.x - minPoint.x),
        height: abs(maxPoint.y - minPoint.y)
    ).integral
}

nonisolated func gscCenteredCropRect(around center: CGPoint, size: CGFloat, within bounds: CGRect) -> CGRect {
    CGRect(
        x: center.x - size / 2,
        y: center.y - size / 2,
        width: size,
        height: size
    ).gscClamped(to: bounds)
}

nonisolated struct CropInteractionHUDLayout: Equatable {
    let loupeRect: CGRect
    let loupeImageRect: CGRect
    let dimensionRect: CGRect
}

nonisolated func gscCropInteractionHUDLayout(
    around focusPoint: CGPoint,
    in bounds: CGRect,
    dimensionSize: CGSize,
    loupeSize: CGSize = CGSize(width: 120, height: 120),
    offset: CGSize = CGSize(width: 24, height: 24),
    edgeInset: CGFloat = 16,
    loupeContentInset: CGFloat = 8,
    gap: CGFloat = 10,
    labelPadding: CGSize = CGSize(width: 12, height: 8)
) -> CropInteractionHUDLayout {
    let clampedLoupeOrigin = CGPoint(
        x: min(max(focusPoint.x + offset.width, bounds.minX + edgeInset), bounds.maxX - loupeSize.width - edgeInset),
        y: min(max(focusPoint.y + offset.height, bounds.minY + edgeInset), bounds.maxY - loupeSize.height - edgeInset)
    )

    let loupeRect = CGRect(origin: clampedLoupeOrigin, size: loupeSize)
    let paddedDimensionSize = CGSize(
        width: dimensionSize.width + labelPadding.width * 2,
        height: dimensionSize.height + labelPadding.height * 2
    )
    let labelX = min(max(loupeRect.minX, bounds.minX + edgeInset), bounds.maxX - paddedDimensionSize.width - edgeInset)
    let preferredBelowY = loupeRect.maxY + gap
    let preferredAboveY = loupeRect.minY - gap - paddedDimensionSize.height
    let labelY: CGFloat

    if preferredBelowY + paddedDimensionSize.height <= bounds.maxY - edgeInset {
        labelY = preferredBelowY
    } else if preferredAboveY >= bounds.minY + edgeInset {
        labelY = preferredAboveY
    } else {
        labelY = min(
            max(bounds.minY + edgeInset, preferredBelowY),
            bounds.maxY - edgeInset - paddedDimensionSize.height
        )
    }

    return CropInteractionHUDLayout(
        loupeRect: loupeRect,
        loupeImageRect: loupeRect.insetBy(dx: loupeContentInset, dy: loupeContentInset),
        dimensionRect: CGRect(x: labelX, y: labelY, width: paddedDimensionSize.width, height: paddedDimensionSize.height)
    )
}

nonisolated func gscCropPixelDimensionText(for rect: CGRect) -> String {
    let dimensions = rect.gscIntegralStandardized
    return "\(Int(dimensions.width)) × \(Int(dimensions.height)) px"
}

nonisolated struct AutoCropOptions: Equatable {
    static let paddedCropPadding: CGFloat = 8

    var padding: CGFloat = 0
    var edgeSampleThickness: Int = 2
    var colorDistanceThreshold: Int = 30
    var alphaDifferenceThreshold: Int = 10
    var minimumCropSize: CGSize = CGSize(width: 4, height: 4)
}

nonisolated enum AutoCropAnalyzer {
    fileprivate struct Pixel {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    static func tightenedCropRect(
        baseImage: CGImage,
        currentCrop: CGRect,
        requiredBounds: CGRect? = nil,
        options: AutoCropOptions = AutoCropOptions()
    ) -> CGRect? {
        let imageBounds = CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height)
        let crop = currentCrop.gscIntegralStandardized.gscClamped(to: imageBounds)

        guard crop.width >= options.minimumCropSize.width,
              crop.height >= options.minimumCropSize.height,
              let pixels = pixelBuffer(for: baseImage, crop: crop) else {
            return nil
        }

        let background = estimatedBackground(in: pixels, edgeSampleThickness: options.edgeSampleThickness)
        let detectedBounds = contentBounds(in: pixels, background: background, options: options).map { localBounds in
            localBounds.offsetBy(dx: crop.minX, dy: crop.minY)
        }
        let clippedRequiredBounds = requiredBounds?
            .gscIntegralStandardized
            .intersection(crop)
            .gscIntegralStandardized
        let meaningfulRequiredBounds = clippedRequiredBounds.flatMap { rect in
            rect.isNull || rect.isEmpty ? nil : rect
        }

        let contentRects = [detectedBounds, meaningfulRequiredBounds].compactMap { $0 }
        guard !contentRects.isEmpty else {
            return nil
        }

        let padded = gscBoundingRect(of: contentRects)
            .insetBy(dx: -max(options.padding, 0), dy: -max(options.padding, 0))
            .gscIntegralStandardized
            .gscClamped(to: crop)

        guard !padded.isNull,
              padded.width >= options.minimumCropSize.width,
              padded.height >= options.minimumCropSize.height,
              padded != crop else {
            return nil
        }

        return padded
    }

    private static func pixelBuffer(for image: CGImage, crop: CGRect) -> AutoCropPixelBuffer? {
        guard let croppedImage = image.gscCropped(topLeftPixelRect: crop) else {
            return nil
        }

        let width = croppedImage.width
        let height = croppedImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let drewImage = data.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.interpolationQuality = .none
            context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drewImage else {
            return nil
        }

        return AutoCropPixelBuffer(width: width, height: height, bytesPerRow: bytesPerRow, bytes: data)
    }

    private static func estimatedBackground(in pixels: AutoCropPixelBuffer, edgeSampleThickness: Int) -> Pixel {
        let thickness = min(max(edgeSampleThickness, 1), max(1, min(pixels.width, pixels.height) / 2))
        var red: [Int] = []
        var green: [Int] = []
        var blue: [Int] = []
        var alpha: [Int] = []

        for y in 0..<pixels.height {
            for x in 0..<pixels.width where x < thickness || x >= pixels.width - thickness || y < thickness || y >= pixels.height - thickness {
                let pixel = pixels.pixel(x: x, y: y)
                red.append(pixel.red)
                green.append(pixel.green)
                blue.append(pixel.blue)
                alpha.append(pixel.alpha)
            }
        }

        guard !red.isEmpty else {
            return Pixel(red: 0, green: 0, blue: 0, alpha: 0)
        }

        return Pixel(
            red: median(red),
            green: median(green),
            blue: median(blue),
            alpha: median(alpha)
        )
    }

    private static func median(_ values: [Int]) -> Int {
        let sortedValues = values.sorted()
        return sortedValues[sortedValues.count / 2]
    }

    private static func contentBounds(
        in pixels: AutoCropPixelBuffer,
        background: Pixel,
        options: AutoCropOptions
    ) -> CGRect? {
        var minX = pixels.width
        var minY = pixels.height
        var maxX = -1
        var maxY = -1

        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                guard isContentPixel(pixels.pixel(x: x, y: y), background: background, options: options) else {
                    continue
                }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1).integral
    }

    private static func isContentPixel(_ pixel: Pixel, background: Pixel, options: AutoCropOptions) -> Bool {
        if abs(pixel.alpha - background.alpha) > options.alphaDifferenceThreshold {
            return true
        }

        let colorDistance = abs(pixel.red - background.red)
            + abs(pixel.green - background.green)
            + abs(pixel.blue - background.blue)

        return colorDistance > options.colorDistanceThreshold
    }
}

nonisolated private struct AutoCropPixelBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytes: [UInt8]

    nonisolated func pixel(x: Int, y: Int) -> AutoCropAnalyzer.Pixel {
        let offset = y * bytesPerRow + x * 4
        return AutoCropAnalyzer.Pixel(
            red: Int(bytes[offset]),
            green: Int(bytes[offset + 1]),
            blue: Int(bytes[offset + 2]),
            alpha: Int(bytes[offset + 3])
        )
    }
}

nonisolated func gscUprightTextRotationDegrees(for degrees: CGFloat) -> CGFloat {
    var normalized = degrees.truncatingRemainder(dividingBy: 360)

    if normalized <= -180 {
        normalized += 360
    } else if normalized > 180 {
        normalized -= 360
    }

    if normalized < -90 {
        normalized += 180
    } else if normalized > 90 {
        normalized -= 180
    }

    return normalized
}

nonisolated func gscArrowLabelOffset(angle: CGFloat, distance: CGFloat, placeAbove: Bool, yAxisPointsDown: Bool) -> CGPoint {
    let normal = CGPoint(x: -sin(angle), y: cos(angle))
    let axisMultiplier: CGFloat = yAxisPointsDown ? -1 : 1
    let placementMultiplier: CGFloat = placeAbove ? 1 : -1
    let multiplier = axisMultiplier * placementMultiplier

    return CGPoint(x: normal.x * distance * multiplier, y: normal.y * distance * multiplier)
}

nonisolated func gscFittedTextRect(
    for text: String,
    currentRect: CGRect,
    font: NSFont,
    horizontalPadding: CGFloat,
    verticalPadding: CGFloat,
    minSize: CGSize,
    maxWidth: CGFloat
) -> CGRect {
    let normalizedRect = currentRect.standardized
    let displayText = text.isEmpty ? " " : text
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineBreakMode = .byWordWrapping

    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraphStyle
    ]

    let singleLineSize = NSString(string: displayText).size(withAttributes: attributes)
    let targetWidth = min(
        max(normalizedRect.width, ceil(singleLineSize.width) + horizontalPadding, minSize.width),
        maxWidth
    )

    let textBounds = NSString(string: displayText).boundingRect(
        with: CGSize(width: max(targetWidth - horizontalPadding, 1), height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attributes
    )

    // Keep a small font-derived slack so repeated explicit line breaks stay visible
    // during live preview updates instead of requiring another edit cycle to repaint in-bounds.
    let renderSlack = ceil(max(font.descender.magnitude, 4))

    let targetHeight = max(normalizedRect.height, ceil(textBounds.height) + verticalPadding + renderSlack, minSize.height)

    return CGRect(
        x: normalizedRect.minX,
        y: normalizedRect.minY,
        width: targetWidth,
        height: targetHeight
    ).gscIntegralStandardized
}

nonisolated func gscSuggestedTextRect(adjacentTo selectionBounds: CGRect, within canvasBounds: CGRect, size: CGSize = CGSize(width: 260, height: 80), padding: CGFloat = 14) -> CGRect {
    let normalizedSelection = selectionBounds.standardized
    let clampedSize = CGSize(
        width: min(size.width, canvasBounds.width),
        height: min(size.height, canvasBounds.height)
    )

    let candidates = [
        CGPoint(x: normalizedSelection.maxX + padding, y: normalizedSelection.minY),
        CGPoint(x: normalizedSelection.minX, y: normalizedSelection.maxY + padding),
        CGPoint(x: normalizedSelection.minX - clampedSize.width - padding, y: normalizedSelection.minY),
        CGPoint(x: normalizedSelection.minX, y: normalizedSelection.minY - clampedSize.height - padding)
    ]

    for origin in candidates {
        let rect = CGRect(origin: origin, size: clampedSize).gscIntegralStandardized

        if canvasBounds.contains(rect) {
            return rect
        }
    }

    let clampedX = min(max(normalizedSelection.maxX + padding, canvasBounds.minX), canvasBounds.maxX - clampedSize.width)
    let clampedY = min(max(normalizedSelection.minY, canvasBounds.minY), canvasBounds.maxY - clampedSize.height)

    return CGRect(x: clampedX, y: clampedY, width: clampedSize.width, height: clampedSize.height).gscIntegralStandardized
}

nonisolated func gscSnapRect(_ rect: CGRect, within bounds: CGRect, against others: [CGRect], threshold: CGFloat = 8) -> SnapResolution {
    gscSnapRect(rect, candidates: SnapCandidateSet(bounds: bounds, others: others), threshold: threshold)
}

nonisolated func gscSnapRect(_ rect: CGRect, candidates: SnapCandidateSet, threshold: CGFloat = 8) -> SnapResolution {
    let xTargets = [rect.minX, rect.midX, rect.maxX]
    let yTargets = [rect.minY, rect.midY, rect.maxY]

    let xSnap = gscBestSnap(for: xTargets, candidates: candidates.xCandidates, threshold: threshold)
    let ySnap = gscBestSnap(for: yTargets, candidates: candidates.yCandidates, threshold: threshold)

    let snappedRect = rect.offsetBy(dx: xSnap?.delta ?? 0, dy: ySnap?.delta ?? 0).gscContained(in: candidates.bounds)
    let guides = [
        xSnap.map { SnapGuide(orientation: .vertical, position: $0.guide) },
        ySnap.map { SnapGuide(orientation: .horizontal, position: $0.guide) }
    ].compactMap { $0 }

    return SnapResolution(rect: snappedRect, guides: guides)
}

nonisolated private func gscBestSnap(for targets: [CGFloat], candidates: [SnapCandidateSet.Candidate], threshold: CGFloat) -> (delta: CGFloat, guide: CGFloat)? {
    var best: (delta: CGFloat, guide: CGFloat)?

    for target in targets {
        guard let targetBest = gscBestSnap(for: target, candidates: candidates, threshold: threshold) else {
            continue
        }

        if let best, abs(best.delta) <= abs(targetBest.delta) {
            continue
        }

        best = (targetBest.delta, targetBest.guide)
    }

    return best
}

nonisolated private func gscBestSnap(
    for target: CGFloat,
    candidates: [SnapCandidateSet.Candidate],
    threshold: CGFloat
) -> (delta: CGFloat, guide: CGFloat, order: Int)? {
    let minimum = target - threshold
    let maximum = target + threshold
    var index = gscLowerBound(in: candidates, value: minimum)
    var best: (delta: CGFloat, guide: CGFloat, order: Int)?

    while index < candidates.count {
        let candidate = candidates[index]
        guard candidate.value <= maximum else {
            break
        }

        let delta = candidate.value - target
        let absoluteDelta = abs(delta)

        if absoluteDelta <= threshold {
            if let currentBest = best {
                let currentAbsoluteDelta = abs(currentBest.delta)
                if absoluteDelta < currentAbsoluteDelta ||
                    (absoluteDelta == currentAbsoluteDelta && candidate.order < currentBest.order) {
                    best = (delta, candidate.value, candidate.order)
                }
            } else {
                best = (delta, candidate.value, candidate.order)
            }
        }

        index += 1
    }

    return best
}

nonisolated private func gscLowerBound(in candidates: [SnapCandidateSet.Candidate], value: CGFloat) -> Int {
    var low = 0
    var high = candidates.count

    while low < high {
        let mid = (low + high) / 2
        if candidates[mid].value < value {
            low = mid + 1
        } else {
            high = mid
        }
    }

    return low
}

nonisolated func gscResizedRect(_ rect: CGRect, handle: ResizeHandle, point: CGPoint) -> CGRect {
    gscSignedScaleBounds(for: rect, handle: handle, point: point).rect
}

nonisolated func gscSignedScaleBounds(for rect: CGRect, handle: ResizeHandle, point: CGPoint) -> SignedScaleBounds {
    var minX = rect.minX
    var minY = rect.minY
    var maxX = rect.maxX
    var maxY = rect.maxY

    switch handle {
    case .topLeft:
        minX = point.x
        minY = point.y
    case .top:
        minY = point.y
    case .topRight:
        maxX = point.x
        minY = point.y
    case .right:
        maxX = point.x
    case .bottomRight:
        maxX = point.x
        maxY = point.y
    case .bottom:
        maxY = point.y
    case .bottomLeft:
        minX = point.x
        maxY = point.y
    case .left:
        minX = point.x
    }

    return SignedScaleBounds(
        minXTarget: minX,
        maxXTarget: maxX,
        minYTarget: minY,
        maxYTarget: maxY
    )
}
