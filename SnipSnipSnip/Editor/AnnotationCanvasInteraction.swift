import AppKit

final class FreehandDraftBuffer {
    var points: [CGPoint]

    init(start: CGPoint) {
        points = [start]
        points.reserveCapacity(256)
    }
}

struct AnnotationCanvasInteractionState {
    enum DragMode {
        case drawingRect(tool: EditorTool, anchor: CGPoint)
        case drawingLine(tool: EditorTool, anchor: CGPoint)
        case drawingFreehand(tool: EditorTool, buffer: FreehandDraftBuffer)
        case moving(annotations: [Annotation], anchor: CGPoint, originalBounds: CGRect)
        case movingCrop(anchor: CGPoint, originalBounds: CGRect)
        case resizing(annotations: [Annotation], originalBounds: CGRect, handle: ResizeHandle)
        case resizingCrop(originalBounds: CGRect, handle: ResizeHandle)
        case cropping(anchor: CGPoint)
        case recognizingText(anchor: CGPoint)
        case marqueeSelecting(anchor: CGPoint, additive: Bool)
    }

    enum Commit {
        case none
        case add(Annotation)
        case update([Annotation])
        case select(ids: [UUID], additive: Bool)
        case clearSelection
        case crop(CGRect)
        case ocr(CGRect)
    }

    private(set) var dragMode: DragMode?
    private(set) var draftAnnotations: [Annotation] = []
    private(set) var draftCropRect: CGRect?
    private(set) var draftSelectionRect: CGRect?
    private(set) var snapGuides: [SnapGuide] = []

    mutating func beginRectDrawing(tool: EditorTool, anchor: CGPoint) {
        dragMode = .drawingRect(tool: tool, anchor: anchor)
    }

    mutating func beginLineDrawing(tool: EditorTool, anchor: CGPoint) {
        dragMode = .drawingLine(tool: tool, anchor: anchor)
    }

    mutating func beginFreehand(tool: EditorTool, at point: CGPoint, style: AnnotationStyle) {
        let buffer = FreehandDraftBuffer(start: point)
        dragMode = .drawingFreehand(tool: tool, buffer: buffer)
        draftAnnotations = [makeFreehandAnnotation(for: tool, points: buffer.points, style: style)]
    }

    mutating func beginMove(annotations: [Annotation], anchor: CGPoint, originalBounds: CGRect) {
        dragMode = .moving(annotations: annotations, anchor: anchor, originalBounds: originalBounds)
    }

    mutating func beginResize(annotations: [Annotation], originalBounds: CGRect, handle: ResizeHandle) {
        dragMode = .resizing(annotations: annotations, originalBounds: originalBounds, handle: handle)
    }

    mutating func beginCropResize(originalBounds: CGRect, handle: ResizeHandle) {
        dragMode = .resizingCrop(originalBounds: originalBounds, handle: handle)
        draftCropRect = originalBounds
    }

    mutating func beginCropMove(anchor: CGPoint, originalBounds: CGRect) {
        dragMode = .movingCrop(anchor: anchor, originalBounds: originalBounds)
        draftCropRect = originalBounds
    }

    mutating func beginCrop(at point: CGPoint) {
        dragMode = .cropping(anchor: point)
        draftCropRect = CGRect(origin: point, size: .zero)
    }

    mutating func beginTextRecognition(at point: CGPoint) {
        dragMode = .recognizingText(anchor: point)
        draftCropRect = CGRect(origin: point, size: .zero)
    }

    mutating func beginMarquee(at point: CGPoint, additive: Bool) {
        dragMode = .marqueeSelecting(anchor: point, additive: additive)
        draftSelectionRect = CGRect(origin: point, size: .zero)
    }

    mutating func update(
        at point: CGPoint,
        snapshot: EditorSnapshot,
        imageBounds: CGRect,
        cropAspectRatio: CGFloat?,
        styleProvider: (EditorTool) -> AnnotationStyle
    ) {
        snapGuides = []

        switch dragMode {
        case let .drawingRect(tool, anchor):
            updateDraftRect(for: tool, anchor: anchor, point: point, snapshot: snapshot, styleProvider: styleProvider)
        case let .drawingLine(tool, anchor):
            updateDraftLine(for: tool, anchor: anchor, point: point, styleProvider: styleProvider)
        case let .drawingFreehand(tool, buffer):
            updateDraftFreehand(tool: tool, buffer: buffer, point: point, style: styleProvider(tool))
        case let .moving(annotations, anchor, originalBounds):
            updateMovedAnnotations(annotations, anchor: anchor, originalBounds: originalBounds, snapshot: snapshot, point: point)
        case let .movingCrop(anchor, originalBounds):
            updateMovedCrop(anchor: anchor, originalBounds: originalBounds, imageBounds: imageBounds, point: point)
        case let .resizing(annotations, originalBounds, handle):
            updateResizedAnnotations(annotations, originalBounds: originalBounds, handle: handle, snapshot: snapshot, point: point)
        case let .resizingCrop(originalBounds, handle):
            updateResizedCrop(originalBounds: originalBounds, handle: handle, imageBounds: imageBounds, point: point, aspectRatio: cropAspectRatio)
        case let .cropping(anchor):
            updateDraftCrop(anchor: anchor, point: point, imageBounds: imageBounds, aspectRatio: cropAspectRatio)
        case let .recognizingText(anchor):
            updateDraftCrop(anchor: anchor, point: point, imageBounds: imageBounds, aspectRatio: nil)
        case let .marqueeSelecting(anchor, _):
            updateDraftSelection(anchor: anchor, point: point)
        case .none:
            break
        }
    }

    func finish(snapshot: EditorSnapshot) -> Commit {
        switch dragMode {
        case .drawingRect, .drawingLine, .drawingFreehand:
            return commitDraftAnnotation()
        case .moving, .resizing:
            return .update(draftAnnotations)
        case .movingCrop, .resizingCrop:
            return commitDraftCrop()
        case let .marqueeSelecting(_, additive):
            return commitMarqueeSelection(additive: additive, snapshot: snapshot)
        case .cropping:
            return commitDraftCrop()
        case .recognizingText:
            return commitDraftOCR()
        case .none:
            return .none
        }
    }

    mutating func reset() {
        dragMode = nil
        draftAnnotations = []
        draftCropRect = nil
        draftSelectionRect = nil
        snapGuides = []
    }

    private mutating func updateDraftRect(
        for tool: EditorTool,
        anchor: CGPoint,
        point: CGPoint,
        snapshot: EditorSnapshot,
        styleProvider: (EditorTool) -> AnnotationStyle
    ) {
        let rect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        let resolution = gscSnapRect(rect, within: snapshot.cropRect, against: otherAnnotationRects(excluding: [], snapshot: snapshot))
        snapGuides = resolution.guides
        draftAnnotations = makeRectAnnotation(for: tool, rect: resolution.rect, styleProvider: styleProvider).map { [$0] } ?? []
    }

    private mutating func updateDraftLine(for tool: EditorTool, anchor: CGPoint, point: CGPoint, styleProvider: (EditorTool) -> AnnotationStyle) {
        draftAnnotations = makeLineAnnotation(for: tool, start: anchor, end: point, styleProvider: styleProvider).map { [$0] } ?? []
    }

    private mutating func updateDraftFreehand(tool: EditorTool, buffer: FreehandDraftBuffer, point: CGPoint, style: AnnotationStyle) {
        if let last = buffer.points.last, hypot(point.x - last.x, point.y - last.y) < 2 {
            draftAnnotations = [makeFreehandAnnotation(for: tool, points: buffer.points, style: style)]
            return
        }

        buffer.points.append(point)
        draftAnnotations = [makeFreehandAnnotation(for: tool, points: buffer.points, style: style)]
    }

    private mutating func updateMovedAnnotations(
        _ annotations: [Annotation],
        anchor: CGPoint,
        originalBounds: CGRect,
        snapshot: EditorSnapshot,
        point: CGPoint
    ) {
        let rawDelta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
        let movedBounds = originalBounds.offsetBy(dx: rawDelta.width, dy: rawDelta.height)
        let resolution = gscSnapRect(
            movedBounds,
            within: snapshot.cropRect,
            against: otherAnnotationRects(excluding: annotations.map(\.id), snapshot: snapshot)
        )
        let snappedDelta = CGSize(width: resolution.rect.minX - originalBounds.minX, height: resolution.rect.minY - originalBounds.minY)
        snapGuides = resolution.guides
        draftAnnotations = annotations.map { $0.translated(by: snappedDelta) }
    }

    private mutating func updateResizedAnnotations(
        _ annotations: [Annotation],
        originalBounds: CGRect,
        handle: ResizeHandle,
        snapshot: EditorSnapshot,
        point: CGPoint
    ) {
        let signedBounds = gscSignedScaleBounds(for: originalBounds, handle: handle, point: point)
        let resizedBounds = signedBounds.rect.gscClamped(to: snapshot.cropRect)
        let resolution = gscSnapRect(
            resizedBounds,
            within: snapshot.cropRect,
            against: otherAnnotationRects(excluding: annotations.map(\.id), snapshot: snapshot)
        )
        let resolvedBounds = signedBounds.resolved(to: resolution.rect)
        snapGuides = resolution.guides
        draftAnnotations = annotations.map { $0.scaled(from: originalBounds, to: resolvedBounds) }
    }

    private mutating func updateDraftCrop(anchor: CGPoint, point: CGPoint, imageBounds: CGRect, aspectRatio: CGFloat?) {
        let rect = constrainedCropRect(anchor: anchor, point: point, aspectRatio: aspectRatio)
        draftCropRect = rect.gscClamped(to: imageBounds)
    }

    private mutating func updateResizedCrop(
        originalBounds: CGRect,
        handle: ResizeHandle,
        imageBounds: CGRect,
        point: CGPoint,
        aspectRatio: CGFloat?
    ) {
        let rect = constrainedResizedCropRect(originalBounds: originalBounds, handle: handle, point: point, aspectRatio: aspectRatio)
        draftCropRect = rect.gscClamped(to: imageBounds)
    }

    private mutating func updateMovedCrop(anchor: CGPoint, originalBounds: CGRect, imageBounds: CGRect, point: CGPoint) {
        let deltaX = point.x - anchor.x
        let deltaY = point.y - anchor.y
        let minX = imageBounds.minX
        let maxX = imageBounds.maxX - originalBounds.width
        let minY = imageBounds.minY
        let maxY = imageBounds.maxY - originalBounds.height

        let clampedOrigin = CGPoint(
            x: floor(min(max(originalBounds.minX + deltaX, minX), maxX)),
            y: floor(min(max(originalBounds.minY + deltaY, minY), maxY))
        )

        draftCropRect = CGRect(origin: clampedOrigin, size: originalBounds.size)
    }

    private mutating func updateDraftSelection(anchor: CGPoint, point: CGPoint) {
        draftSelectionRect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    private func commitDraftAnnotation() -> Commit {
        guard let annotation = draftAnnotations.first,
              annotation.boundingRect.width > 4 || annotation.boundingRect.height > 4
        else {
            return .none
        }

        return .add(annotation)
    }

    private func commitMarqueeSelection(additive: Bool, snapshot: EditorSnapshot) -> Commit {
        let ids = annotationsIntersectingDraftSelection(in: snapshot).map(\.id)

        if ids.isEmpty, !additive {
            return .clearSelection
        }

        return .select(ids: ids, additive: additive)
    }

    private func commitDraftCrop() -> Commit {
        guard let draftCropRect, draftCropRect.width > 10, draftCropRect.height > 10 else {
            return .none
        }

        return .crop(draftCropRect)
    }

    private func commitDraftOCR() -> Commit {
        guard let draftCropRect, draftCropRect.width > 10, draftCropRect.height > 10 else {
            return .none
        }

        return .ocr(draftCropRect)
    }

    private func makeRectAnnotation(for tool: EditorTool, rect: CGRect, styleProvider: (EditorTool) -> AnnotationStyle) -> Annotation? {
        tool.makeRectAnnotation(in: rect, style: styleProvider(tool))
    }

    private func makeLineAnnotation(for tool: EditorTool, start: CGPoint, end: CGPoint, styleProvider: (EditorTool) -> AnnotationStyle) -> Annotation? {
        switch tool {
        case .line:
            return Annotation.makeLine(from: start, to: end, style: styleProvider(.line))
        case .arrow:
            return Annotation.makeArrow(from: start, to: end, style: styleProvider(.arrow))
        case .measure:
            return Annotation.makeMeasurement(from: start, to: end, style: styleProvider(.measure))
        default:
            return nil
        }
    }

    private func makeFreehandAnnotation(for tool: EditorTool, points: [CGPoint], style: AnnotationStyle) -> Annotation {
        switch tool {
        case .highlighter:
            return Annotation.makeHighlighter(points: points, style: style)
        default:
            return Annotation.makeFreehand(points: points, style: style)
        }
    }

    private func otherAnnotationRects(excluding excludedIDs: [UUID], snapshot: EditorSnapshot) -> [CGRect] {
        let excludedSet = Set(excludedIDs)
        return snapshot.annotations.compactMap { annotation in
            excludedSet.contains(annotation.id) ? nil : annotation.boundingRect
        }
    }

    private func annotationsIntersectingDraftSelection(in snapshot: EditorSnapshot) -> [Annotation] {
        guard let draftSelectionRect else {
            return []
        }

        let selection = draftSelectionRect.standardized
        return snapshot.annotations.filter { annotation in
            selection.intersects(annotation.boundingRect) || selection.contains(annotation.boundingRect.origin)
        }
    }

    private func constrainedCropRect(anchor: CGPoint, point: CGPoint, aspectRatio: CGFloat?) -> CGRect {
        guard let aspectRatio, aspectRatio > 0 else {
            return CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            )
        }

        let deltaX = point.x - anchor.x
        let deltaY = point.y - anchor.y
        let width = abs(deltaX)
        let height = abs(deltaY)

        let resolvedSize: CGSize
        if width / max(height, .leastNonzeroMagnitude) > aspectRatio {
            resolvedSize = CGSize(width: height * aspectRatio, height: height)
        } else {
            resolvedSize = CGSize(width: width, height: width / aspectRatio)
        }

        let origin = CGPoint(
            x: deltaX >= 0 ? anchor.x : anchor.x - resolvedSize.width,
            y: deltaY >= 0 ? anchor.y : anchor.y - resolvedSize.height
        )
        return CGRect(origin: origin, size: resolvedSize)
    }

    private func constrainedResizedCropRect(
        originalBounds: CGRect,
        handle: ResizeHandle,
        point: CGPoint,
        aspectRatio: CGFloat?
    ) -> CGRect {
        guard let aspectRatio, aspectRatio > 0 else {
            return gscResizedRect(originalBounds, handle: handle, point: point)
        }

        switch handle {
        case .topLeft:
            return constrainedCropRect(anchor: CGPoint(x: originalBounds.maxX, y: originalBounds.maxY), point: point, aspectRatio: aspectRatio)
        case .topRight:
            return constrainedCropRect(anchor: CGPoint(x: originalBounds.minX, y: originalBounds.maxY), point: point, aspectRatio: aspectRatio)
        case .bottomRight:
            return constrainedCropRect(anchor: CGPoint(x: originalBounds.minX, y: originalBounds.minY), point: point, aspectRatio: aspectRatio)
        case .bottomLeft:
            return constrainedCropRect(anchor: CGPoint(x: originalBounds.maxX, y: originalBounds.minY), point: point, aspectRatio: aspectRatio)
        case .left, .right:
            let anchoredX = handle == .left ? originalBounds.maxX : originalBounds.minX
            let width = abs(point.x - anchoredX)
            let height = width / aspectRatio
            let minX = handle == .left ? anchoredX - width : anchoredX
            return CGRect(
                x: minX,
                y: originalBounds.midY - height / 2,
                width: width,
                height: height
            )
        case .top, .bottom:
            let anchoredY = handle == .top ? originalBounds.maxY : originalBounds.minY
            let height = abs(point.y - anchoredY)
            let width = height * aspectRatio
            let minY = handle == .top ? anchoredY - height : anchoredY
            return CGRect(
                x: originalBounds.midX - width / 2,
                y: minY,
                width: width,
                height: height
            )
        }
    }
}
