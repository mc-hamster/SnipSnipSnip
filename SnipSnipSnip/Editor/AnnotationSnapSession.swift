import CoreGraphics

/// Holds the same alignment target until the pointer leaves its release distance.
/// Distances are measured in canvas points, independent of image magnification.
nonisolated struct AnnotationSnapSession {
    static let attachmentDistance: CGFloat = 6
    static let releaseDistance: CGFloat = 10

    private struct AxisLock {
        let targetIndex: Int
        let guide: CGFloat
    }

    private var horizontalLock: AxisLock?
    private var verticalLock: AxisLock?

    mutating func reset() {
        horizontalLock = nil
        verticalLock = nil
    }

    mutating func snapPoint(
        _ point: CGPoint,
        candidates: SnapCandidateSet,
        displayScale: CGFloat
    ) -> PointSnapResolution {
        let proposed = gscSnapPoint(point, candidates: candidates, threshold: attachmentThreshold(for: displayScale))
        let x = resolveAxis(targets: [point.x], proposedGuides: proposed.guides, orientation: .vertical, displayScale: displayScale)
        let y = resolveAxis(targets: [point.y], proposedGuides: proposed.guides, orientation: .horizontal, displayScale: displayScale)
        return PointSnapResolution(
            point: CGPoint(x: point.x + (x?.delta ?? 0), y: point.y + (y?.delta ?? 0)),
            guides: [x?.guide, y?.guide].compactMap { $0 }
        )
    }

    mutating func snapRect(
        _ rect: CGRect,
        candidates: SnapCandidateSet,
        within bounds: CGRect,
        displayScale: CGFloat,
        bypassed: Bool
    ) -> SnapResolution {
        guard !bypassed else {
            reset()
            return SnapResolution(rect: rect.gscContained(in: bounds), guides: [])
        }

        let proposed = gscSnapRect(rect, candidates: candidates, threshold: attachmentThreshold(for: displayScale))
        let x = resolveAxis(targets: [rect.minX, rect.midX, rect.maxX], proposedGuides: proposed.guides, orientation: .vertical, displayScale: displayScale)
        let y = resolveAxis(targets: [rect.minY, rect.midY, rect.maxY], proposedGuides: proposed.guides, orientation: .horizontal, displayScale: displayScale)
        return SnapResolution(
            rect: rect.offsetBy(dx: x?.delta ?? 0, dy: y?.delta ?? 0).gscContained(in: bounds),
            guides: [x?.guide, y?.guide].compactMap { $0 }
        )
    }

    mutating func snapSignedScaleBounds(
        _ bounds: SignedScaleBounds,
        handle: ResizeHandle,
        candidates: SnapCandidateSet,
        displayScale: CGFloat,
        bypassed: Bool
    ) -> SignedScaleResolution {
        guard !bypassed else {
            reset()
            return SignedScaleResolution(bounds: bounds, guides: [])
        }

        let sides = draggedSides(for: handle)
        let proposed = gscSnapSignedScaleBounds(bounds, handle: handle, candidates: candidates, threshold: attachmentThreshold(for: displayScale))
        let xTargets = sides.minX ? [bounds.minXTarget] : (sides.maxX ? [bounds.maxXTarget] : [])
        let yTargets = sides.minY ? [bounds.minYTarget] : (sides.maxY ? [bounds.maxYTarget] : [])
        let x = resolveAxis(targets: xTargets, proposedGuides: proposed.guides, orientation: .vertical, displayScale: displayScale)
        let y = resolveAxis(targets: yTargets, proposedGuides: proposed.guides, orientation: .horizontal, displayScale: displayScale)
        return SignedScaleResolution(
            bounds: SignedScaleBounds(
                minXTarget: bounds.minXTarget + (sides.minX ? x?.delta ?? 0 : 0),
                maxXTarget: bounds.maxXTarget + (sides.maxX ? x?.delta ?? 0 : 0),
                minYTarget: bounds.minYTarget + (sides.minY ? y?.delta ?? 0 : 0),
                maxYTarget: bounds.maxYTarget + (sides.maxY ? y?.delta ?? 0 : 0)
            ),
            guides: [x?.guide, y?.guide].compactMap { $0 }
        )
    }

    private mutating func resolveAxis(
        targets: [CGFloat],
        proposedGuides: [SnapGuide],
        orientation: SnapOrientation,
        displayScale: CGFloat
    ) -> (delta: CGFloat, guide: SnapGuide)? {
        let retainedLock = orientation == .vertical ? horizontalLock : verticalLock
        let scale = validDisplayScale(displayScale)
        var resolvedLock: AxisLock?

        if let retainedLock,
           targets.indices.contains(retainedLock.targetIndex),
           abs(retainedLock.guide - targets[retainedLock.targetIndex]) * scale <= Self.releaseDistance {
            resolvedLock = retainedLock
        } else if let guide = proposedGuides.first(where: { $0.orientation == orientation }),
                  let index = targets.indices.min(by: { abs(targets[$0] - guide.position) < abs(targets[$1] - guide.position) }) {
            resolvedLock = AxisLock(targetIndex: index, guide: guide.position)
        }

        if orientation == .vertical {
            horizontalLock = resolvedLock
        } else {
            verticalLock = resolvedLock
        }

        guard let resolvedLock else { return nil }
        return (
            resolvedLock.guide - targets[resolvedLock.targetIndex],
            SnapGuide(orientation: orientation, position: resolvedLock.guide)
        )
    }

    private func attachmentThreshold(for displayScale: CGFloat) -> CGFloat {
        Self.attachmentDistance / validDisplayScale(displayScale)
    }

    private func validDisplayScale(_ value: CGFloat) -> CGFloat {
        value.isFinite && value > 0 ? value : 1
    }

    private func draggedSides(for handle: ResizeHandle) -> (minX: Bool, maxX: Bool, minY: Bool, maxY: Bool) {
        switch handle {
        case .topLeft: (true, false, true, false)
        case .top: (false, false, true, false)
        case .topRight: (false, true, true, false)
        case .right: (false, true, false, false)
        case .bottomRight: (false, true, false, true)
        case .bottom: (false, false, false, true)
        case .bottomLeft: (true, false, false, true)
        case .left: (true, false, false, false)
        }
    }
}
