import CoreGraphics
import Foundation

nonisolated enum CompositionDividerAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

nonisolated enum CompositionFreeformResizeCorner: Equatable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

nonisolated enum CompositionFreeformAlignment: Equatable, Sendable {
    case leading
    case horizontalCenter
    case trailing
    case top
    case verticalCenter
    case bottom
}

nonisolated enum CompositionFreeformDistribution: Equatable, Sendable {
    case horizontal
    case vertical
}

nonisolated enum CompositionFreeformSizeMatch: Equatable, Sendable {
    case width
    case height
    case both
}

nonisolated enum CompositionFreeformZOrderDirection: Equatable, Sendable {
    case towardBack
    case towardFront
}

nonisolated enum CompositionFreeformZOrdering {
    static func itemIDsBackToFront(
        _ items: [CompositionItem]
    ) -> [UUID] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.zIndex == rhs.element.zIndex {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.zIndex < rhs.element.zIndex
            }
            .map(\.element.id)
    }
}

nonisolated struct CompositionWeightedDividerHit: Equatable, Sendable {
    let firstItemID: UUID
    let secondItemID: UUID
    let axis: CompositionDividerAxis
}

nonisolated enum CompositionWeightedDividerHitTesting {
    static func divider(
        at point: CGPoint,
        in placements: [CompositionItemRenderLayout]
    ) -> CompositionWeightedDividerHit? {
        let orderedPlacements = placements.sorted {
            if $0.frameRect.minY == $1.frameRect.minY {
                return $0.frameRect.minX < $1.frameRect.minX
            }
            return $0.frameRect.minY < $1.frameRect.minY
        }
        for first in orderedPlacements {
            let rightNeighbor = orderedPlacements
                .filter { candidate in
                    candidate.itemID != first.itemID
                        && candidate.frameRect.minX >= first.frameRect.maxX - 1
                        && candidate.frameRect.maxY > first.frameRect.minY
                        && candidate.frameRect.minY < first.frameRect.maxY
                }
                .min { $0.frameRect.minX < $1.frameRect.minX }
            if let second = rightNeighbor {
                let overlapStart = max(
                    first.frameRect.minY,
                    second.frameRect.minY
                )
                let overlapEnd = min(
                    first.frameRect.maxY,
                    second.frameRect.maxY
                )
                let gapStart = first.frameRect.maxX
                let gapEnd = second.frameRect.minX
                let hitRect = CGRect(
                    x: min(gapStart, gapEnd) - 4,
                    y: overlapStart,
                    width: max(abs(gapEnd - gapStart) + 8, 18),
                    height: max(overlapEnd - overlapStart, 0)
                )
                if hitRect.contains(point) {
                    return CompositionWeightedDividerHit(
                        firstItemID: first.itemID,
                        secondItemID: second.itemID,
                        axis: .horizontal
                    )
                }
            }

            let lowerNeighbor = orderedPlacements
                .filter { candidate in
                    candidate.itemID != first.itemID
                        && candidate.frameRect.minY >= first.frameRect.maxY - 1
                        && candidate.frameRect.maxX > first.frameRect.minX
                        && candidate.frameRect.minX < first.frameRect.maxX
                }
                .min { $0.frameRect.minY < $1.frameRect.minY }
            if let second = lowerNeighbor {
                let overlapStart = max(
                    first.frameRect.minX,
                    second.frameRect.minX
                )
                let overlapEnd = min(
                    first.frameRect.maxX,
                    second.frameRect.maxX
                )
                let gapStart = first.frameRect.maxY
                let gapEnd = second.frameRect.minY
                let hitRect = CGRect(
                    x: overlapStart,
                    y: min(gapStart, gapEnd) - 4,
                    width: max(overlapEnd - overlapStart, 0),
                    height: max(abs(gapEnd - gapStart) + 8, 18)
                )
                if hitRect.contains(point) {
                    return CompositionWeightedDividerHit(
                        firstItemID: first.itemID,
                        secondItemID: second.itemID,
                        axis: .vertical
                    )
                }
            }
        }
        return nil
    }
}

extension EditorController {
    func currentCompositionRenderLayout() throws -> CompositionRenderLayout {
        guard let composition = snapshot.composition else {
            throw CompositionLayoutError.emptyComposition
        }
        var sizes: [UUID: CGSize] = [:]
        for item in composition.items where item.isIncluded {
            guard let descriptor = compositionAssetRepository.storedAsset(for: item.assetID)?.descriptor else {
                continue
            }
            sizes[item.id] = item.editState.cropRect?.size ?? descriptor.pixelSize
        }
        return try CompositionLayoutEngine.layout(
            composition: composition,
            renderedItemSizes: sizes
        )
    }

    func compositionItemID(
        at point: CGPoint,
        in layout: CompositionRenderLayout,
        comparisonPhase: CompositionComparisonPhase = .primary
    ) -> UUID? {
        let hitPhase: CompositionPosterFrame =
            comparisonPhase == .secondary ? .secondary : .primary
        return layout.hitTest(
            point,
            comparisonPhase: hitPhase,
            overlayOpacity: snapshot.composition?
                .comparison.overlayOpacity ?? 1
        )?.itemID
    }

    func canMoveFreeformCompositionItem(
        _ itemID: UUID,
        direction: CompositionFreeformZOrderDirection
    ) -> Bool {
        guard let composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return false
        }
        let itemIDs = CompositionFreeformZOrdering
            .itemIDsBackToFront(composition.items)
        guard let index = itemIDs.firstIndex(of: itemID) else {
            return false
        }
        switch direction {
        case .towardBack:
            return index > 0
        case .towardFront:
            return index + 1 < itemIDs.count
        }
    }

    func moveFreeformCompositionItem(
        _ itemID: UUID,
        direction: CompositionFreeformZOrderDirection
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        var itemIDs = CompositionFreeformZOrdering
            .itemIDsBackToFront(composition.items)
        guard let sourceIndex = itemIDs.firstIndex(of: itemID) else {
            return
        }
        let destinationIndex: Int
        switch direction {
        case .towardBack:
            destinationIndex = sourceIndex - 1
        case .towardFront:
            destinationIndex = sourceIndex + 1
        }
        guard itemIDs.indices.contains(destinationIndex) else {
            return
        }
        itemIDs.swapAt(sourceIndex, destinationIndex)
        let zIndices = Dictionary(
            uniqueKeysWithValues: itemIDs.enumerated().map {
                ($0.element, $0.offset + 1)
            }
        )
        for index in composition.items.indices {
            if let zIndex = zIndices[composition.items[index].id] {
                composition.items[index].zIndex = zIndex
            }
        }
        composition.selectedItemIDs = [itemID]
        execute(
            InspectorCompositionCommand(
                composition: composition,
                label: "Reorder Captures"
            )
        )
    }

    func beginCompositionItemFraming(_ itemID: UUID) {
        guard snapshot.composition?.items.contains(where: { $0.id == itemID }) == true else {
            return
        }
        selectCompositionItems([itemID])
        compositionFramingItemID = itemID
        showNotice("Framing \(compositionItemDisplayName(itemID)). Drag to set the focal offset; press Escape when done.")
    }

    func finishCompositionItemFraming() {
        guard compositionFramingItemID != nil else {
            return
        }
        compositionFramingItemID = nil
        AppAccessibility.announce("Item framing finished.")
    }

    func adjustCompositionItemFraming(itemID: UUID, by delta: CGSize) {
        guard var composition = snapshot.composition,
              let index = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        let linkGroupID = composition.items[index].framing.linkGroupID
        let affectedIndices = composition.items.indices.filter { candidate in
            candidate == index
                || (linkGroupID != nil && composition.items[candidate].framing.linkGroupID == linkGroupID)
        }
        for candidate in affectedIndices {
            composition.items[candidate].framing.offset.width += delta.width
            composition.items[candidate].framing.offset.height += delta.height
        }
        execute(SetCompositionCommand(composition: composition))
    }

    func adjustCompositionDivider(
        firstItemID: UUID,
        secondItemID: UUID,
        by delta: CGFloat,
        axis: CompositionDividerAxis,
        layout: CompositionRenderLayout
    ) {
        guard var composition = snapshot.composition,
              composition.layout.sizingMode == .weighted,
              let firstIndex = composition.items.firstIndex(where: { $0.id == firstItemID }),
              let secondIndex = composition.items.firstIndex(where: { $0.id == secondItemID }),
              let firstLayout = layout.itemLayout(for: firstItemID),
              let secondLayout = layout.itemLayout(for: secondItemID) else {
            return
        }
        let firstExtent = axis == .horizontal ? firstLayout.frameRect.width : firstLayout.frameRect.height
        let secondExtent = axis == .horizontal ? secondLayout.frameRect.width : secondLayout.frameRect.height
        let combinedExtent = max(firstExtent + secondExtent, 1)
        let combinedWeight = max(
            composition.items[firstIndex].weight + composition.items[secondIndex].weight,
            0.2
        )
        let firstFraction = min(max((firstExtent + delta) / combinedExtent, 0.08), 0.92)
        composition.items[firstIndex].weight = combinedWeight * firstFraction
        composition.items[secondIndex].weight = combinedWeight * (1 - firstFraction)
        execute(SetCompositionCommand(composition: composition))
    }

    func adjustCompositionWipeDivider(to position: CGFloat) {
        updateCompositionComparison { comparison in
            comparison.wipePosition = min(max(position, 0), 1)
        }
    }

    func moveCompositionSelectionForKeyboard(dx: CGFloat, dy: CGFloat) {
        guard let composition = snapshot.composition else {
            return
        }
        if composition.layout.mode == .freeform {
            moveSelectedCompositionItemsBy(dx: dx, dy: dy)
            return
        }
        guard let selectedID = composition.selectedItemIDs.last,
              let currentIndex = composition.items.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        let offset = abs(dx) >= abs(dy) ? (dx < 0 ? -1 : 1) : (dy < 0 ? -1 : 1)
        moveCompositionItem(selectedID, to: currentIndex + offset)
    }

    func resizeFreeformCompositionItem(
        itemID: UUID,
        corner: CompositionFreeformResizeCorner,
        by delta: CGSize,
        preservesAspectRatio: Bool
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform,
              let index = composition.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }
        var frame = resolvedFreeformFrame(for: composition.items[index])
        let original = frame
        switch corner {
        case .topLeading:
            frame.origin.x += delta.width
            frame.origin.y += delta.height
            frame.size.width -= delta.width
            frame.size.height -= delta.height
        case .topTrailing:
            frame.origin.y += delta.height
            frame.size.width += delta.width
            frame.size.height -= delta.height
        case .bottomLeading:
            frame.origin.x += delta.width
            frame.size.width -= delta.width
            frame.size.height += delta.height
        case .bottomTrailing:
            frame.size.width += delta.width
            frame.size.height += delta.height
        }

        if preservesAspectRatio {
            let aspectRatio = max(original.width / max(original.height, 1), 0.01)
            if abs(delta.width) >= abs(delta.height) {
                frame.size.height = frame.width / aspectRatio
            } else {
                frame.size.width = frame.height * aspectRatio
            }
            if corner == .topLeading || corner == .topTrailing {
                frame.origin.y = original.maxY - frame.height
            }
            if corner == .topLeading || corner == .bottomLeading {
                frame.origin.x = original.maxX - frame.width
            }
        }

        let minimumDimension: CGFloat = 24
        if frame.width < minimumDimension {
            if corner == .topLeading || corner == .bottomLeading {
                frame.origin.x = original.maxX - minimumDimension
            }
            frame.size.width = minimumDimension
        }
        if frame.height < minimumDimension {
            if corner == .topLeading || corner == .topTrailing {
                frame.origin.y = original.maxY - minimumDimension
            }
            frame.size.height = minimumDimension
        }
        composition.items[index].freeformFrame = frame
        execute(SetCompositionCommand(composition: composition))
    }

    func resizeSelectedFreeformCompositionItemsBy(
        widthDelta: CGFloat,
        heightDelta: CGFloat
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        let selectedIndices = composition.items.indices.filter {
            selectedIDs.contains(composition.items[$0].id)
        }
        guard !selectedIndices.isEmpty else {
            return
        }

        let minimumDimension: CGFloat = 24
        for index in selectedIndices {
            var frame = resolvedFreeformFrame(for: composition.items[index])
            frame.size.width = max(
                minimumDimension,
                frame.width + widthDelta
            )
            frame.size.height = max(
                minimumDimension,
                frame.height + heightDelta
            )
            composition.items[index].freeformFrame = frame
        }
        execute(SetCompositionCommand(composition: composition))
        let selectionDescription = selectedIndices.count == 1
            ? "Selected item"
            : "\(selectedIndices.count) selected items"
        AppAccessibility.announce(
            "\(selectionDescription) resized by "
                + "\(Int(widthDelta.rounded())) width and "
                + "\(Int(heightDelta.rounded())) height."
        )
    }

    func setFreeformCompositionCanvasSize(_ size: CGSize?) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        if let size {
            guard size.width.isFinite,
                  size.height.isFinite else {
                return
            }
            composition.layout.freeformCanvasSize = CGSize(
                width: max(size.width, 24),
                height: max(size.height, 24)
            )
        } else {
            composition.layout.freeformCanvasSize = nil
        }
        execute(SetCompositionCommand(composition: composition))
    }

    func trimFreeformCompositionCanvasToIncludedItems() {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        let includedIndices = composition.items.indices.filter {
            composition.items[$0].isIncluded
        }
        guard !includedIndices.isEmpty else {
            return
        }
        let rawBounds = includedIndices
            .map { resolvedFreeformFrame(for: composition.items[$0]) }
            .reduce(CGRect.null) { $0.union($1) }
        guard !rawBounds.isNull,
              rawBounds.width.isFinite,
              rawBounds.height.isFinite else {
            return
        }

        let renderedContentSize: CGSize
        if let liveLayout = try? currentCompositionRenderLayout() {
            let liveBounds = liveLayout.items.reduce(CGRect.null) { bounds, item in
                let itemBounds = item.captionRect.map {
                    item.frameRect.union($0)
                } ?? item.frameRect
                return bounds.union(itemBounds)
            }
            renderedContentSize = liveBounds.isNull
                ? rawBounds.size
                : liveBounds.size
        } else {
            renderedContentSize = rawBounds.size
        }

        let translation = CGSize(
            width: -rawBounds.minX,
            height: -rawBounds.minY
        )
        for index in composition.items.indices {
            var frame = resolvedFreeformFrame(for: composition.items[index])
            frame.origin.x += translation.width
            frame.origin.y += translation.height
            composition.items[index].freeformFrame = frame
        }
        composition.layout.freeformCanvasSize = CGSize(
            width: max(rawBounds.width, renderedContentSize.width, 24),
            height: max(rawBounds.height, renderedContentSize.height, 24)
        )
        execute(SetCompositionCommand(composition: composition))
        AppAccessibility.announce(
            "Freeform canvas trimmed to the included items."
        )
    }

    func snapSelectedFreeformCompositionItems(threshold: CGFloat) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        let selectedIndices = composition.items.indices.filter {
            selectedIDs.contains(composition.items[$0].id)
        }
        guard !selectedIndices.isEmpty else {
            return
        }
        let selectedFrames = selectedIndices.map {
            resolvedFreeformFrame(for: composition.items[$0])
        }
        let selectionBounds = selectedFrames.reduce(CGRect.null) { $0.union($1) }
        let otherFrames = composition.items.indices
            .filter { !selectedIndices.contains($0) && composition.items[$0].isIncluded }
            .map { resolvedFreeformFrame(for: composition.items[$0]) }
        let canvasSize = (try? currentCompositionRenderLayout().canvasSize)
            ?? composition.layout.freeformCanvasSize
            ?? selectionBounds.size

        let xTargets: [CGFloat] = [0, canvasSize.width / 2, canvasSize.width]
            + otherFrames.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let yTargets: [CGFloat] = [0, canvasSize.height / 2, canvasSize.height]
            + otherFrames.flatMap { [$0.minY, $0.midY, $0.maxY] }
        let xSources: [CGFloat] = [
            selectionBounds.minX,
            selectionBounds.midX,
            selectionBounds.maxX,
        ]
        let ySources: [CGFloat] = [
            selectionBounds.minY,
            selectionBounds.midY,
            selectionBounds.maxY,
        ]
        let correctionX = nearestSnapCorrection(
            sources: xSources,
            targets: xTargets,
            threshold: threshold
        )
        let correctionY = nearestSnapCorrection(
            sources: ySources,
            targets: yTargets,
            threshold: threshold
        )
        guard correctionX != 0 || correctionY != 0 else {
            return
        }
        for index in selectedIndices {
            var frame = resolvedFreeformFrame(for: composition.items[index])
            frame.origin.x += correctionX
            frame.origin.y += correctionY
            composition.items[index].freeformFrame = frame
        }
        execute(SetCompositionCommand(composition: composition))
    }

    func alignSelectedFreeformCompositionItems(
        _ alignment: CompositionFreeformAlignment
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        let indices = composition.items.indices.filter {
            selectedIDs.contains(composition.items[$0].id)
        }
        guard indices.count >= 2 else {
            return
        }
        let frames = indices.map { resolvedFreeformFrame(for: composition.items[$0]) }
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        for index in indices {
            var frame = resolvedFreeformFrame(for: composition.items[index])
            switch alignment {
            case .leading:
                frame.origin.x = bounds.minX
            case .horizontalCenter:
                frame.origin.x = bounds.midX - frame.width / 2
            case .trailing:
                frame.origin.x = bounds.maxX - frame.width
            case .top:
                frame.origin.y = bounds.minY
            case .verticalCenter:
                frame.origin.y = bounds.midY - frame.height / 2
            case .bottom:
                frame.origin.y = bounds.maxY - frame.height
            }
            composition.items[index].freeformFrame = frame
        }
        execute(SetCompositionCommand(composition: composition))
    }

    func distributeSelectedFreeformCompositionItems(
        _ distribution: CompositionFreeformDistribution
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        var indices = composition.items.indices.filter {
            selectedIDs.contains(composition.items[$0].id)
        }
        guard indices.count >= 3 else {
            return
        }
        indices.sort {
            let first = resolvedFreeformFrame(for: composition.items[$0])
            let second = resolvedFreeformFrame(for: composition.items[$1])
            return distribution == .horizontal
                ? first.midX < second.midX
                : first.midY < second.midY
        }
        let frames = indices.map { resolvedFreeformFrame(for: composition.items[$0]) }
        switch distribution {
        case .horizontal:
            let occupied = frames.reduce(CGFloat.zero) { $0 + $1.width }
            let gap = (frames.last!.maxX - frames.first!.minX - occupied)
                / CGFloat(indices.count - 1)
            var cursor = frames.first!.minX
            for index in indices {
                var frame = resolvedFreeformFrame(for: composition.items[index])
                frame.origin.x = cursor
                cursor += frame.width + gap
                composition.items[index].freeformFrame = frame
            }
        case .vertical:
            let occupied = frames.reduce(CGFloat.zero) { $0 + $1.height }
            let gap = (frames.last!.maxY - frames.first!.minY - occupied)
                / CGFloat(indices.count - 1)
            var cursor = frames.first!.minY
            for index in indices {
                var frame = resolvedFreeformFrame(for: composition.items[index])
                frame.origin.y = cursor
                cursor += frame.height + gap
                composition.items[index].freeformFrame = frame
            }
        }
        execute(SetCompositionCommand(composition: composition))
    }

    func matchSelectedFreeformCompositionItemSizes(
        _ match: CompositionFreeformSizeMatch
    ) {
        guard var composition = snapshot.composition,
              composition.layout.mode == .freeform,
              let referenceID = composition.selectedItemIDs.first,
              let referenceIndex = composition.items.firstIndex(where: { $0.id == referenceID }) else {
            return
        }
        let selectedIDs = Set(composition.selectedItemIDs)
        guard selectedIDs.count >= 2 else {
            return
        }
        let referenceSize = resolvedFreeformFrame(
            for: composition.items[referenceIndex]
        ).size
        for index in composition.items.indices
            where selectedIDs.contains(composition.items[index].id) && index != referenceIndex {
            var frame = resolvedFreeformFrame(for: composition.items[index])
            if match == .width || match == .both {
                frame.size.width = referenceSize.width
            }
            if match == .height || match == .both {
                frame.size.height = referenceSize.height
            }
            composition.items[index].freeformFrame = frame
        }
        execute(SetCompositionCommand(composition: composition))
    }

    private func compositionItemDisplayName(_ itemID: UUID) -> String {
        let title = snapshot.composition?.items.first(where: { $0.id == itemID })?.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : "selected item"
    }

    private func resolvedFreeformFrame(for item: CompositionItem) -> CGRect {
        item.freeformFrame
            ?? CGRect(
                origin: .zero,
                size: compositionAssetRepository
                    .storedAsset(for: item.assetID)?
                    .descriptor
                    .pixelSize
                    ?? CGSize(width: 320, height: 200)
            )
    }

    private func nearestSnapCorrection(
        sources: [CGFloat],
        targets: [CGFloat],
        threshold: CGFloat
    ) -> CGFloat {
        var nearest: CGFloat?
        for source in sources {
            for target in targets {
                let correction = target - source
                guard abs(correction) <= threshold else {
                    continue
                }
                if nearest == nil || abs(correction) < abs(nearest!) {
                    nearest = correction
                }
            }
        }
        return nearest ?? 0
    }
}
