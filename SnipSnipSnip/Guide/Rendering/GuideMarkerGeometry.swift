import CoreGraphics
import Foundation

/// Shared geometry for Guide marker capture and rendering.
///
/// The marker's target stays at the recorded action. Only the numbered end is
/// placed automatically, and it is kept outside the detected accessibility
/// element whenever the element bounds are useful.
nonisolated enum GuideMarkerGeometry {
    static let badgeRadius: CGFloat = 18
    static let targetOuterRadius: CGFloat = 22

    struct Connector: Equatable, Sendable {
        var start: CGPoint
        var end: CGPoint
    }

    static func automaticTail(
        for target: CGPoint,
        avoiding targetRect: CGRect?,
        in canvasSize: CGSize,
        preferredLength: CGFloat,
        badgeRadius: CGFloat,
        targetClearance: CGFloat
    ) -> CGPoint {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return target }

        let canvas = CGRect(origin: .zero, size: canvasSize)
        let permitted = canvas.insetBy(dx: badgeRadius + 4, dy: badgeRadius + 4)
        guard !permitted.isNull, permitted.width > 0, permitted.height > 0 else {
            return CGPoint(
                x: min(max(target.x, 0), canvasSize.width),
                y: min(max(target.y, 0), canvasSize.height)
            )
        }

        let fallbackTargetRect = CGRect(
            x: target.x - targetClearance,
            y: target.y - targetClearance,
            width: targetClearance * 2,
            height: targetClearance * 2
        )
        let targetBounds = usableTargetRect(targetRect, containing: target, in: canvas)
            ?? fallbackTargetRect
        let excluded = targetBounds.insetBy(
            dx: -(badgeRadius + targetClearance),
            dy: -(badgeRadius + targetClearance)
        )
        let directions = [
            CGVector(dx: 1, dy: -1),
            CGVector(dx: -1, dy: -1),
            CGVector(dx: 1, dy: 1),
            CGVector(dx: -1, dy: 1),
            CGVector(dx: 0, dy: -1),
            CGVector(dx: 1, dy: 0),
            CGVector(dx: 0, dy: 1),
            CGVector(dx: -1, dy: 0)
        ]

        var bestPoint = clamped(
            CGPoint(x: target.x + preferredLength, y: target.y - preferredLength),
            to: permitted
        )
        var bestScore = CGFloat.greatestFiniteMagnitude

        for (index, rawDirection) in directions.enumerated() {
            let magnitude = max(hypot(rawDirection.dx, rawDirection.dy), 0.001)
            let direction = CGVector(
                dx: rawDirection.dx / magnitude,
                dy: rawDirection.dy / magnitude
            )
            let exitDistance = distanceToExit(excluded, from: target, along: direction)
            let distance = max(preferredLength, exitDistance + 2)
            let proposed = CGPoint(
                x: target.x + direction.dx * distance,
                y: target.y + direction.dy * distance
            )
            let candidate = clamped(proposed, to: permitted)
            let badgeRect = CGRect(
                x: candidate.x - badgeRadius,
                y: candidate.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
            let overlap = badgeRect.intersection(targetBounds).standardized
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            let clampDistance = hypot(candidate.x - proposed.x, candidate.y - proposed.y)
            let edgeClearance = min(
                candidate.x - permitted.minX,
                permitted.maxX - candidate.x,
                candidate.y - permitted.minY,
                permitted.maxY - candidate.y
            )
            let score =
                overlapArea * 10_000
                + clampDistance * 100
                + distance * 0.15
                - min(max(edgeClearance, 0), 80) * 0.2
                + CGFloat(index) * 0.01

            if score < bestScore {
                bestScore = score
                bestPoint = candidate
            }
        }

        return bestPoint
    }

    static func connector(
        from badgeCenter: CGPoint,
        to targetCenter: CGPoint,
        badgeRadius: CGFloat = badgeRadius,
        targetRadius: CGFloat = targetOuterRadius
    ) -> Connector? {
        let dx = targetCenter.x - badgeCenter.x
        let dy = targetCenter.y - badgeCenter.y
        let distance = hypot(dx, dy)
        let requiredGap = badgeRadius + targetRadius + 6
        guard distance > requiredGap else { return nil }

        let unit = CGVector(dx: dx / distance, dy: dy / distance)
        return Connector(
            start: CGPoint(
                x: badgeCenter.x + unit.dx * (badgeRadius + 3),
                y: badgeCenter.y + unit.dy * (badgeRadius + 3)
            ),
            end: CGPoint(
                x: targetCenter.x - unit.dx * (targetRadius + 3),
                y: targetCenter.y - unit.dy * (targetRadius + 3)
            )
        )
    }

    private static func usableTargetRect(
        _ targetRect: CGRect?,
        containing target: CGPoint,
        in canvas: CGRect
    ) -> CGRect? {
        guard let targetRect else { return nil }
        let clipped = targetRect.standardized.intersection(canvas)
        guard !clipped.isNull,
              clipped.width > 1,
              clipped.height > 1,
              clipped.insetBy(dx: -4, dy: -4).contains(target),
              clipped.width <= canvas.width * 0.72,
              clipped.height <= canvas.height * 0.72,
              clipped.width * clipped.height <= canvas.width * canvas.height * 0.42 else {
            return nil
        }
        return clipped
    }

    private static func distanceToExit(
        _ rect: CGRect,
        from point: CGPoint,
        along direction: CGVector
    ) -> CGFloat {
        guard rect.contains(point) else { return 0 }
        var distances: [CGFloat] = []
        if direction.dx > 0 {
            distances.append((rect.maxX - point.x) / direction.dx)
        } else if direction.dx < 0 {
            distances.append((rect.minX - point.x) / direction.dx)
        }
        if direction.dy > 0 {
            distances.append((rect.maxY - point.y) / direction.dy)
        } else if direction.dy < 0 {
            distances.append((rect.minY - point.y) / direction.dy)
        }
        return distances.filter { $0 >= 0 }.min() ?? 0
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
