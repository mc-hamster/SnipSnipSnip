import CoreGraphics
import Foundation

/// Deterministic, side-effect-free composition layout.
///
/// All returned geometry uses a top-left origin. The engine accepts either
/// original asset descriptors (and applies each item's crop dimensions) or the
/// final per-item image sizes produced by the editor renderer.
nonisolated enum CompositionLayoutEngine {
    static func layout(
        composition: CompositionSnapshot,
        assetDescriptors: [UUID: CompositionAssetDescriptor]
    ) throws -> CompositionRenderLayout {
        var itemSizes: [UUID: CGSize] = [:]
        for item in composition.items where item.isIncluded {
            guard let descriptor = assetDescriptors[item.assetID] else {
                throw CompositionLayoutError.missingAssetDescriptor(assetID: item.assetID)
            }
            let sourceSize = try resolvedSourceSize(
                descriptor: descriptor,
                cropRect: item.editState.cropRect
            )
            itemSizes[item.id] = sourceSize
        }
        return try layout(composition: composition, renderedItemSizes: itemSizes)
    }

    /// Layout for already-edited images. The dictionary is keyed by item ID,
    /// rather than asset ID, so two items may reuse one source with different
    /// crops and annotations.
    static func layout(
        composition: CompositionSnapshot,
        renderedItemSizes: [UUID: CGSize]
    ) throws -> CompositionRenderLayout {
        let included = try composition.items.compactMap { item -> ResolvedItem? in
            guard item.isIncluded else { return nil }
            guard let size = renderedItemSizes[item.id] else {
                throw CompositionLayoutError.missingAssetDescriptor(assetID: item.assetID)
            }
            guard size.isCompositionValid else {
                throw CompositionLayoutError.invalidAssetDimensions(assetID: item.assetID)
            }
            return ResolvedItem(item: item, sourceSize: size)
        }

        guard !included.isEmpty else {
            throw CompositionLayoutError.emptyComposition
        }

        switch composition.layout.mode {
        case .auto:
            return try autoLayout(composition: composition, items: included)
        case .row:
            return linearLayout(composition: composition, items: included, axis: .horizontal, resolvedMode: .row)
        case .column:
            return linearLayout(composition: composition, items: included, axis: .vertical, resolvedMode: .column)
        case .grid:
            return gridLayout(
                composition: composition,
                items: included,
                requestedColumns: composition.layout.gridColumns
            )
        case .steps:
            return stepsLayout(composition: composition, items: included)
        case .compare:
            return try comparisonLayout(composition: composition, items: included)
        case .freeform:
            return freeformLayout(composition: composition, items: included)
        }
    }

    // MARK: - Resolution

    private struct ResolvedItem: Sendable {
        let item: CompositionItem
        let sourceSize: CGSize
    }

    private struct Candidate: Sendable {
        let priority: Int
        let layout: CompositionRenderLayout?
        let gridColumns: Int?
        let minimumVisibleScale: CGFloat
        let occupiedArea: CGFloat
    }

    private struct CaptionMeasurement: Sendable {
        let lineLengths: [Int]
    }

    private struct AutoGridScoringContext: Sendable {
        let appearance: CompositionCanvasAppearance
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        let itemWeights: [CGFloat]
        let captions: [CaptionMeasurement?]
        let title: CaptionMeasurement?
        let targetAspectRatio: CGFloat
    }

    private final class CandidateCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Candidate] = []

        func append(contentsOf candidates: [Candidate]) {
            lock.lock()
            storage.append(contentsOf: candidates)
            lock.unlock()
        }

        var candidates: [Candidate] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct AutoLayoutCacheKey: Equatable, Sendable {
        let composition: CompositionSnapshot
        let sourceSizes: [CGSize]
    }

    private final class AutoLayoutCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (
            key: AutoLayoutCacheKey,
            layout: CompositionRenderLayout
        )?

        func layout(for key: AutoLayoutCacheKey) -> CompositionRenderLayout? {
            lock.lock()
            defer { lock.unlock() }
            guard entry?.key == key else {
                return nil
            }
            return entry?.layout
        }

        func store(
            _ layout: CompositionRenderLayout,
            for key: AutoLayoutCacheKey
        ) {
            lock.lock()
            entry = (key, layout)
            lock.unlock()
        }
    }

    private static let autoLayoutCache = AutoLayoutCache()

    private static func resolvedSourceSize(
        descriptor: CompositionAssetDescriptor,
        cropRect: CGRect?
    ) throws -> CGSize {
        let fullSize = descriptor.pixelSize
        guard fullSize.isCompositionValid else {
            throw CompositionLayoutError.invalidAssetDimensions(assetID: descriptor.id)
        }
        guard let cropRect else { return fullSize }

        let fullRect = CGRect(origin: .zero, size: fullSize)
        let standardized = cropRect.standardized.intersection(fullRect)
        let integral = standardized.integral
        guard !integral.isNull, integral.size.isCompositionValid else {
            throw CompositionLayoutError.invalidAssetDimensions(assetID: descriptor.id)
        }
        return integral.size
    }

    private static func autoLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem]
    ) throws -> CompositionRenderLayout {
        if items.count == 1 {
            return linearLayout(
                composition: composition,
                items: items,
                axis: .horizontal,
                resolvedMode: .row
            )
        }
        if items.count == 2 {
            let row = linearLayout(
                composition: composition,
                items: items,
                axis: .horizontal,
                resolvedMode: .row
            )
            let column = linearLayout(
                composition: composition,
                items: items,
                axis: .vertical,
                resolvedMode: .column
            )
            return preferredCandidate(
                [
                    candidate(row, items: items, target: targetAspectRatio(composition), priority: 0),
                    candidate(column, items: items, target: targetAspectRatio(composition), priority: 1),
                ]
            ).layout!
        }

        let cacheKey = AutoLayoutCacheKey(
            composition: composition,
            sourceSizes: items.map(\.sourceSize)
        )
        if let cached = autoLayoutCache.layout(for: cacheKey) {
            return cached
        }

        let target = targetAspectRatio(composition)

        var candidates: [Candidate] = []
        let row = linearLayout(composition: composition, items: items, axis: .horizontal, resolvedMode: .row)
        candidates.append(candidate(row, items: items, target: target, priority: 0))
        let gridScoringContext = autoGridScoringContext(
            composition: composition,
            items: items
        )

        // Evaluate every legal column count. A fixed cap produces visibly
        // suboptimal Auto layouts for wide, high-item-count sources. At the
        // 200-item release soak this remains just 40,000 inexpensive geometry
        // placements; larger normal documents use the same uncapped logic.
        let upperGridColumns = items.count
        if upperGridColumns >= 2 {
            let candidateCount = upperGridColumns - 1
            if candidateCount >= 48 {
                let workerCount = min(
                    max(ProcessInfo.processInfo.activeProcessorCount, 1),
                    candidateCount
                )
                let collector = CandidateCollector()
                DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                    var workerCandidates: [Candidate] = []
                    workerCandidates.reserveCapacity(
                        Int(ceil(Double(candidateCount) / Double(workerCount)))
                    )
                    var columns = 2 + worker
                    while columns <= upperGridColumns {
                        workerCandidates.append(
                            gridCandidate(
                                composition: composition,
                                items: items,
                                scoringContext: gridScoringContext,
                                columns: columns,
                                target: target,
                                priority: 10 + columns
                            )
                        )
                        columns += workerCount
                    }
                    collector.append(contentsOf: workerCandidates)
                }
                candidates.append(contentsOf: collector.candidates)
            } else {
                for columns in 2...upperGridColumns {
                    candidates.append(
                        gridCandidate(
                            composition: composition,
                            items: items,
                            scoringContext: gridScoringContext,
                            columns: columns,
                            target: target,
                            priority: 10 + columns
                        )
                    )
                }
            }
        }

        let column = linearLayout(composition: composition, items: items, axis: .vertical, resolvedMode: .column)
        candidates.append(candidate(column, items: items, target: target, priority: 100))

        let preferred = preferredCandidate(candidates)
        let resolvedLayout: CompositionRenderLayout
        if let layout = preferred.layout {
            resolvedLayout = layout
        } else {
            resolvedLayout = gridLayout(
                composition: composition,
                items: items,
                requestedColumns: preferred.gridColumns
            )
        }
        autoLayoutCache.store(resolvedLayout, for: cacheKey)
        return resolvedLayout
    }

    private static func targetAspectRatio(_ composition: CompositionSnapshot) -> CGFloat {
        switch composition.layout.orientation {
        case .automatic:
            return composition.layout.targetAspectRatio.isFinite
                ? max(composition.layout.targetAspectRatio, 0.01)
                : 4 / 3
        case .landscape:
            return 16 / 9
        case .portrait:
            return 9 / 16
        case .square:
            return 1
        case .custom:
            return composition.layout.targetAspectRatio.isFinite
                ? max(composition.layout.targetAspectRatio, 0.01)
                : 4 / 3
        }
    }

    private static func candidate(
        _ layout: CompositionRenderLayout,
        items: [ResolvedItem],
        target: CGFloat,
        priority: Int
    ) -> Candidate {
        let targetSize = target >= 1
            ? CGSize(width: 1_600, height: 1_600 / target)
            : CGSize(width: 1_600 * target, height: 1_600)
        let canvasScale = min(
            targetSize.width / max(layout.canvasSize.width, 1),
            targetSize.height / max(layout.canvasSize.height, 1)
        )
        let sourceSizes = Dictionary(uniqueKeysWithValues: items.map { ($0.item.id, $0.sourceSize) })
        let visibleScales = layout.items.compactMap { placement -> CGFloat? in
            guard let source = sourceSizes[placement.itemID],
                  source.width > 0,
                  source.height > 0 else {
                return nil
            }
            return min(
                placement.imageClipRect.width / source.width,
                placement.imageClipRect.height / source.height
            ) * canvasScale
        }
        let minimumScale = visibleScales.min() ?? 0
        let occupiedArea = layout.items.reduce(CGFloat.zero) {
            $0 + $1.imageClipRect.width * $1.imageClipRect.height * canvasScale * canvasScale
        }
        return Candidate(
            priority: priority,
            layout: layout,
            gridColumns: nil,
            minimumVisibleScale: minimumScale,
            occupiedArea: occupiedArea
        )
    }

    /// Scores an Auto-grid candidate without materializing its item
    /// placements. Auto evaluates every legal column count, so constructing
    /// and then shifting hundreds of complete layouts made the 200-item path
    /// quadratic in relatively expensive value-model work. This calculation
    /// mirrors `gridLayout` geometry and builds only the winning layout.
    private static func gridCandidate(
        composition: CompositionSnapshot,
        items: [ResolvedItem],
        scoringContext: AutoGridScoringContext,
        columns requestedColumns: Int,
        target: CGFloat,
        priority: Int
    ) -> Candidate {
        let appearance = scoringContext.appearance
        let insets = appearance.insets
        let spacing = appearance.itemSpacing
        let columns = min(max(requestedColumns, 1), items.count)
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let usesWeights = composition.layout.sizingMode == .weighted

        var columnWeights = Array(repeating: CGFloat(1), count: columns)
        var rowWeights = Array(repeating: CGFloat(1), count: rows)
        if usesWeights {
            for (index, sanitizedWeight) in scoringContext.itemWeights.enumerated() {
                columnWeights[index % columns] = max(
                    columnWeights[index % columns],
                    sanitizedWeight
                )
                rowWeights[index / columns] = max(
                    rowWeights[index / columns],
                    sanitizedWeight
                )
            }
        }
        let columnWidths = proportionalSizes(
            total: scoringContext.imageWidth * CGFloat(columns),
            weights: columnWeights,
            count: columns
        )
        let rowHeights = proportionalSizes(
            total: scoringContext.imageHeight * CGFloat(rows),
            weights: rowWeights,
            count: rows
        )

        var rowCaptionHeights = Array(repeating: CGFloat.zero, count: rows)
        if appearance.captionPlacement == .below
            || appearance.captionPlacement == .above {
            for (index, caption) in scoringContext.captions.enumerated() {
                guard let caption else {
                    continue
                }
                let row = index / columns
                rowCaptionHeights[row] = max(
                    rowCaptionHeights[row],
                    captionHeight(
                        for: caption,
                        width: columnWidths[index % columns],
                        appearance: appearance
                    )
                )
            }
        }

        let baseCanvasSize = CGSize(
            width: insets.leading
                + columnWidths.reduce(0, +)
                + CGFloat(max(0, columns - 1)) * spacing
                + insets.trailing,
            height: insets.top
                + rowHeights.reduce(0, +)
                + rowCaptionHeights.reduce(0, +)
                + CGFloat(max(0, rows - 1)) * spacing
                + insets.bottom
        )
        let canvasSize = resolvedCanvasSizeForScoring(
            baseCanvasSize,
            composition: composition,
            resolvedMode: .grid,
            appearance: appearance,
            title: scoringContext.title,
            targetAspectRatio: scoringContext.targetAspectRatio
        )
        let targetSize = target >= 1
            ? CGSize(width: 1_600, height: 1_600 / target)
            : CGSize(width: 1_600 * target, height: 1_600)
        let canvasScale = min(
            targetSize.width / max(canvasSize.width, 1),
            targetSize.height / max(canvasSize.height, 1)
        )

        var minimumVisibleScale = CGFloat.greatestFiniteMagnitude
        var occupiedArea: CGFloat = 0
        for (index, item) in items.enumerated() {
            let cellWidth = columnWidths[index % columns]
            let cellHeight = rowHeights[index / columns]
            minimumVisibleScale = min(
                minimumVisibleScale,
                min(
                    cellWidth / item.sourceSize.width,
                    cellHeight / item.sourceSize.height
                ) * canvasScale
            )
            occupiedArea += cellWidth * cellHeight * canvasScale * canvasScale
        }

        return Candidate(
            priority: priority,
            layout: nil,
            gridColumns: columns,
            minimumVisibleScale: minimumVisibleScale.isFinite
                ? minimumVisibleScale
                : 0,
            occupiedArea: occupiedArea
        )
    }

    private static func autoGridScoringContext(
        composition: CompositionSnapshot,
        items: [ResolvedItem]
    ) -> AutoGridScoringContext {
        let appearance = composition.canvas.appearance.sanitized
        let reservesCaptions = appearance.captionPlacement == .below
            || appearance.captionPlacement == .above
        return AutoGridScoringContext(
            appearance: appearance,
            imageWidth: max(items.lazy.map(\.sourceSize.width).max() ?? 1, 1),
            imageHeight: max(items.lazy.map(\.sourceSize.height).max() ?? 1, 1),
            itemWeights: items.map {
                let value = $0.item.weight
                return value.isFinite && value > 0 ? value : 1
            },
            captions: reservesCaptions
                ? items.map { captionMeasurement(for: $0.item) }
                : Array(repeating: nil, count: items.count),
            title: textMeasurement(composition.canvas.title),
            targetAspectRatio: targetAspectRatio(composition)
        )
    }

    private static func captionMeasurement(
        for item: CompositionItem
    ) -> CaptionMeasurement? {
        guard let caption = item.caption else {
            return nil
        }
        return textMeasurement(caption)
    }

    private static func textMeasurement(
        _ text: String
    ) -> CaptionMeasurement? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return CaptionMeasurement(
            lineLengths: normalized.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            .map(\.count)
        )
    }

    private static func captionHeight(
        for measurement: CaptionMeasurement,
        width: CGFloat,
        appearance: CompositionCanvasAppearance
    ) -> CGFloat {
        let fontSize = appearance.captionFontSize
        let usableWidth = max(
            1,
            width
                - appearance.captionInsets.leading
                - appearance.captionInsets.trailing
        )
        let estimatedCharacterWidth = max(fontSize * 0.55, 1)
        let charactersPerLine = max(
            Int(floor(usableWidth / estimatedCharacterWidth)),
            1
        )
        let lineCount = measurement.lineLengths.reduce(0) {
            $0 + max(
                1,
                Int(ceil(Double($1) / Double(charactersPerLine)))
            )
        }
        return appearance.captionInsets.top
            + CGFloat(lineCount) * ceil(fontSize * 1.25)
            + appearance.captionInsets.bottom
    }

    private static func resolvedCanvasSizeForScoring(
        _ canvasSize: CGSize,
        composition: CompositionSnapshot,
        resolvedMode: CompositionLayoutMode,
        appearance: CompositionCanvasAppearance,
        title: CaptionMeasurement?,
        targetAspectRatio: CGFloat
    ) -> CGSize {
        var resolved = CGSize(
            width: max(ceil(canvasSize.width), 1),
            height: max(ceil(canvasSize.height), 1)
        )
        if let title {
            resolved.height += titleHeight(
                for: title,
                width: max(
                    resolved.width
                        - appearance.insets.leading
                        - appearance.insets.trailing,
                    1
                ),
                appearance: appearance
            )
        }

        if composition.layout.orientation != .automatic,
           resolvedMode != .freeform {
            let current = resolved.width / max(resolved.height, 1)
            if current > targetAspectRatio {
                resolved.height = ceil(resolved.width / targetAspectRatio)
            } else if current < targetAspectRatio {
                resolved.width = ceil(resolved.height * targetAspectRatio)
            }
        }
        return resolved
    }

    private static func titleHeight(
        for measurement: CaptionMeasurement,
        width: CGFloat,
        appearance: CompositionCanvasAppearance
    ) -> CGFloat {
        let usableWidth = max(
            width
                - appearance.titleInsets.leading
                - appearance.titleInsets.trailing,
            1
        )
        let estimatedCharacterWidth = max(
            appearance.titleFontSize * 0.55,
            1
        )
        let charactersPerLine = max(
            Int(floor(usableWidth / estimatedCharacterWidth)),
            1
        )
        let lines = measurement.lineLengths.reduce(0) {
            $0 + max(
                1,
                Int(ceil(Double($1) / Double(charactersPerLine)))
            )
        }
        return appearance.titleInsets.top
            + CGFloat(lines) * ceil(appearance.titleFontSize * 1.2)
            + appearance.titleInsets.bottom
    }

    private static func preferredCandidate(_ candidates: [Candidate]) -> Candidate {
        candidates.max {
            if abs($0.minimumVisibleScale - $1.minimumVisibleScale) > 0.000_001 {
                return $0.minimumVisibleScale < $1.minimumVisibleScale
            }
            if abs($0.occupiedArea - $1.occupiedArea) > 0.5 {
                return $0.occupiedArea < $1.occupiedArea
            }
            return $0.priority > $1.priority
        }!
    }

    // MARK: - Linear layouts

    private static func linearLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem],
        axis: CompositionAxis,
        resolvedMode: CompositionLayoutMode
    ) -> CompositionRenderLayout {
        let appearance = composition.canvas.appearance.sanitized
        let spacing = appearance.itemSpacing
        let insets = appearance.insets
        let captionHeights = items.map {
            captionHeight(for: $0.item, width: $0.sourceSize.width, appearance: appearance)
        }

        let placements: [CompositionItemRenderLayout]
        let canvasSize: CGSize

        switch axis {
        case .horizontal:
            let imageHeight = max(items.map(\.sourceSize.height).max() ?? 1, 1)
            let availableImageWidth = max(items.map(\.sourceSize.width).reduce(0, +), CGFloat(items.count))
            let widths = proportionalSizes(
                total: availableImageWidth,
                weights: composition.layout.sizingMode == .equal
                    ? Array(repeating: 1, count: items.count)
                    : items.map { $0.item.weight },
                count: items.count
            )
            let maximumCaptionHeight = reservedCaptionHeight(
                captionHeights.max() ?? 0,
                placement: appearance.captionPlacement
            )
            let cardHeight = imageHeight + maximumCaptionHeight
            var cursor = insets.leading
            placements = items.enumerated().map { index, resolved in
                let imageRect = CGRect(
                    x: cursor,
                    y: insets.top,
                    width: widths[index],
                    height: imageHeight
                )
                let captionRect = captionHeights[index] > 0
                    ? CGRect(
                        x: cursor,
                        y: imageRect.maxY,
                        width: widths[index],
                        height: captionHeights[index]
                    )
                    : nil
                let placement = makePlacement(
                    resolved,
                    imageRect: imageRect,
                    captionRect: captionRect,
                    badgeRect: nil,
                    captionPlacement: appearance.captionPlacement,
                    zIndex: index,
                    role: .item
                )
                cursor += widths[index] + spacing
                return placement
            }
            canvasSize = CGSize(
                width: insets.leading + widths.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1)) + insets.trailing,
                height: insets.top + cardHeight + insets.bottom
            )
        case .vertical:
            let imageWidth = max(items.map(\.sourceSize.width).max() ?? 1, 1)
            let availableImageHeight = max(items.map(\.sourceSize.height).reduce(0, +), CGFloat(items.count))
            let heights = proportionalSizes(
                total: availableImageHeight,
                weights: composition.layout.sizingMode == .equal
                    ? Array(repeating: 1, count: items.count)
                    : items.map { $0.item.weight },
                count: items.count
            )
            var cursor = insets.top
            placements = items.enumerated().map { index, resolved in
                let imageRect = CGRect(
                    x: insets.leading,
                    y: cursor,
                    width: imageWidth,
                    height: heights[index]
                )
                let captionRect = captionHeights[index] > 0
                    ? CGRect(
                        x: insets.leading,
                        y: imageRect.maxY,
                        width: imageWidth,
                        height: captionHeights[index]
                    )
                    : nil
                let placement = makePlacement(
                    resolved,
                    imageRect: imageRect,
                    captionRect: captionRect,
                    badgeRect: nil,
                    captionPlacement: appearance.captionPlacement,
                    zIndex: index,
                    role: .item
                )
                cursor += heights[index]
                    + reservedCaptionHeight(
                        captionHeights[index],
                        placement: appearance.captionPlacement
                    )
                    + spacing
                return placement
            }
            canvasSize = CGSize(
                width: insets.leading + imageWidth + insets.trailing,
                height: insets.top
                    + heights.reduce(0, +)
                    + captionHeights.reduce(CGFloat.zero) {
                        $0 + reservedCaptionHeight(
                            $1,
                            placement: appearance.captionPlacement
                        )
                    }
                    + spacing * CGFloat(max(0, items.count - 1))
                    + insets.bottom
            )
        }

        return makeLayout(
            composition: composition,
            resolvedMode: resolvedMode,
            canvasSize: canvasSize,
            placements: placements
        )
    }

    private static func proportionalSizes(total: CGFloat, weights: [CGFloat], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let sanitized = weights.map { value in
            value.isFinite && value > 0 ? value : 1
        }
        let totalWeight = sanitized.reduce(0, +)
        return sanitized.map { max(1, total * $0 / totalWeight) }
    }

    // MARK: - Grid

    private static func gridLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem],
        requestedColumns: Int?
    ) -> CompositionRenderLayout {
        let appearance = composition.canvas.appearance.sanitized
        let insets = appearance.insets
        let spacing = appearance.itemSpacing
        let inferredColumns = Int(ceil(sqrt(Double(items.count))))
        let columns = min(max(requestedColumns ?? inferredColumns, 1), items.count)
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let imageWidth = max(items.map(\.sourceSize.width).max() ?? 1, 1)
        let imageHeight = max(items.map(\.sourceSize.height).max() ?? 1, 1)
        let usesWeights = composition.layout.sizingMode == .weighted
        let itemWeights = items.map { usesWeights ? $0.item.weight : 1 }

        var columnWeights = Array(repeating: CGFloat(1), count: columns)
        var rowWeights = Array(repeating: CGFloat(1), count: rows)
        if usesWeights {
            for (index, weight) in itemWeights.enumerated() {
                let sanitizedWeight = weight.isFinite && weight > 0 ? weight : 1
                columnWeights[index % columns] = max(
                    columnWeights[index % columns],
                    sanitizedWeight
                )
                rowWeights[index / columns] = max(
                    rowWeights[index / columns],
                    sanitizedWeight
                )
            }
        }
        let columnWidths = proportionalSizes(
            total: imageWidth * CGFloat(columns),
            weights: columnWeights,
            count: columns
        )
        let rowHeights = proportionalSizes(
            total: imageHeight * CGFloat(rows),
            weights: rowWeights,
            count: rows
        )

        var columnOrigins = Array(repeating: insets.leading, count: columns)
        if columns > 1 {
            for column in 1..<columns {
                columnOrigins[column] = columnOrigins[column - 1]
                    + columnWidths[column - 1]
                    + spacing
            }
        }

        var rowCaptionHeights = Array(repeating: CGFloat.zero, count: rows)
        for (index, resolved) in items.enumerated() {
            let row = index / columns
            let column = index % columns
            rowCaptionHeights[row] = max(
                rowCaptionHeights[row],
                captionHeight(
                    for: resolved.item,
                    width: columnWidths[column],
                    appearance: appearance
                )
            )
        }

        var rowOrigins = Array(repeating: CGFloat.zero, count: rows)
        var cursorY = insets.top
        for row in 0..<rows {
            rowOrigins[row] = cursorY
            cursorY += rowHeights[row]
                + reservedCaptionHeight(
                    rowCaptionHeights[row],
                    placement: appearance.captionPlacement
                )
            if row < rows - 1 {
                cursorY += spacing
            }
        }

        let placements = items.enumerated().map { index, resolved in
            let row = index / columns
            let column = index % columns
            let x = columnOrigins[column]
            let imageRect = CGRect(
                x: x,
                y: rowOrigins[row],
                width: columnWidths[column],
                height: rowHeights[row]
            )
            let ownCaptionHeight = captionHeight(
                for: resolved.item,
                width: columnWidths[column],
                appearance: appearance
            )
            let captionRect = ownCaptionHeight > 0
                ? CGRect(
                    x: x,
                    y: imageRect.maxY,
                    width: columnWidths[column],
                    height: ownCaptionHeight
                )
                : nil
            return makePlacement(
                resolved,
                imageRect: imageRect,
                captionRect: captionRect,
                badgeRect: nil,
                captionPlacement: appearance.captionPlacement,
                zIndex: index,
                role: .item
            )
        }

        let canvasSize = CGSize(
            width: insets.leading
                + columnWidths.reduce(0, +)
                + CGFloat(max(0, columns - 1)) * spacing
                + insets.trailing,
            height: cursorY + insets.bottom
        )
        return makeLayout(
            composition: composition,
            resolvedMode: .grid,
            canvasSize: canvasSize,
            placements: placements
        )
    }

    // MARK: - Steps

    private static func stepsLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem]
    ) -> CompositionRenderLayout {
        let appearance = composition.canvas.appearance.sanitized
        let insets = appearance.insets
        let spacing = max(appearance.itemSpacing, appearance.stepBadgeDiameter / 2)
        let showsCaptions = composition.steps.showsCaptions
        let flow = composition.steps.flow
        let gridColumns = min(
            max(composition.steps.gridColumns, 1),
            max(items.count, 1)
        )
        let baseImageWidth = max(items.map(\.sourceSize.width).max() ?? 1, 1)
        let baseImageHeight = max(items.map(\.sourceSize.height).max() ?? 1, 1)
        let usesWeights = composition.layout.sizingMode == .weighted
        let itemWeights = items.map { usesWeights ? $0.item.weight : 1 }
        let rowWidths = proportionalSizes(
            total: baseImageWidth * CGFloat(items.count),
            weights: itemWeights,
            count: items.count
        )
        let columnHeights = proportionalSizes(
            total: baseImageHeight * CGFloat(items.count),
            weights: itemWeights,
            count: items.count
        )
        let gridRowCount = Int(ceil(Double(items.count) / Double(gridColumns)))
        var gridColumnWeights = Array(repeating: CGFloat(1), count: gridColumns)
        var gridRowWeights = Array(repeating: CGFloat(1), count: gridRowCount)
        if usesWeights {
            for (index, weight) in itemWeights.enumerated() {
                let sanitizedWeight = weight.isFinite && weight > 0 ? weight : 1
                gridColumnWeights[index % gridColumns] = max(
                    gridColumnWeights[index % gridColumns],
                    sanitizedWeight
                )
                gridRowWeights[index / gridColumns] = max(
                    gridRowWeights[index / gridColumns],
                    sanitizedWeight
                )
            }
        }
        let gridColumnWidths = proportionalSizes(
            total: baseImageWidth * CGFloat(gridColumns),
            weights: gridColumnWeights,
            count: gridColumns
        )
        let gridRowHeights = proportionalSizes(
            total: baseImageHeight * CGFloat(gridRowCount),
            weights: gridRowWeights,
            count: gridRowCount
        )
        let itemWidths = items.indices.map { index -> CGFloat in
            switch flow {
            case .row:
                return rowWidths[index]
            case .column:
                return baseImageWidth
            case .grid:
                return gridColumnWidths[index % gridColumns]
            }
        }
        let itemHeights = items.indices.map { index -> CGFloat in
            switch flow {
            case .row:
                return baseImageHeight
            case .column:
                return columnHeights[index]
            case .grid:
                return gridRowHeights[index / gridColumns]
            }
        }
        let captionHeights = items.enumerated().map { index, resolved in
            showsCaptions
                ? captionHeight(
                    for: resolved.item,
                    width: itemWidths[index],
                    appearance: appearance
                )
                : 0
        }
        let reservedCaptionHeights = captionHeights.map {
            reservedCaptionHeight(
                $0,
                placement: appearance.captionPlacement
            )
        }

        var columnOrigins = Array(repeating: insets.top, count: items.count)
        if flow == .column, items.count > 1 {
            for index in 1..<items.count {
                columnOrigins[index] = columnOrigins[index - 1]
                    + itemHeights[index - 1]
                    + spacing
                    + reservedCaptionHeights[index - 1]
            }
        }

        var gridRowOrigins = Array(repeating: insets.top, count: gridRowCount)
        if flow == .grid, gridRowCount > 1 {
            var rowCaptionHeights = Array(repeating: CGFloat.zero, count: gridRowCount)
            for (index, height) in reservedCaptionHeights.enumerated() {
                rowCaptionHeights[index / gridColumns] = max(
                    rowCaptionHeights[index / gridColumns],
                    height
                )
            }
            for row in 1..<gridRowCount {
                gridRowOrigins[row] = gridRowOrigins[row - 1]
                    + gridRowHeights[row - 1]
                    + spacing
                    + rowCaptionHeights[row - 1]
            }
        }

        var rowItemOrigins = Array(repeating: insets.leading, count: items.count)
        if flow == .row, items.count > 1 {
            for index in 1..<items.count {
                rowItemOrigins[index] = rowItemOrigins[index - 1]
                    + itemWidths[index - 1]
                    + spacing
            }
        }
        var gridColumnOrigins = Array(repeating: insets.leading, count: gridColumns)
        if flow == .grid, gridColumns > 1 {
            for column in 1..<gridColumns {
                gridColumnOrigins[column] = gridColumnOrigins[column - 1]
                    + gridColumnWidths[column - 1]
                    + spacing
            }
        }

        var placements: [CompositionItemRenderLayout] = []
        placements.reserveCapacity(items.count)

        for (index, resolved) in items.enumerated() {
            let x: CGFloat
            let y: CGFloat
            switch flow {
            case .row:
                x = rowItemOrigins[index]
                y = insets.top
            case .column:
                x = insets.leading
                y = columnOrigins[index]
            case .grid:
                let row = index / gridColumns
                let column = index % gridColumns
                x = gridColumnOrigins[column]
                y = gridRowOrigins[row]
            }

            let imageRect = CGRect(
                x: x,
                y: y,
                width: itemWidths[index],
                height: itemHeights[index]
            )
            let resolvedCaptionHeight = captionHeights[index]
            let captionRect = resolvedCaptionHeight > 0
                ? CGRect(
                    x: x,
                    y: imageRect.maxY,
                    width: itemWidths[index],
                    height: resolvedCaptionHeight
                )
                : nil
            let badgeRect: CGRect?
            let stepLabel = composition.steps.label(for: index)
            if stepLabel != nil {
                badgeRect = CGRect(
                    x: imageRect.minX + 8,
                    y: imageRect.minY + 8,
                    width: appearance.stepBadgeDiameter,
                    height: appearance.stepBadgeDiameter
                )
            } else {
                badgeRect = nil
            }

            placements.append(
                makePlacement(
                    resolved,
                    imageRect: imageRect,
                    captionRect: captionRect,
                    badgeRect: badgeRect,
                    captionPlacement: appearance.captionPlacement,
                    zIndex: index,
                    role: .step(index: index, label: stepLabel)
                )
            )
        }

        let connectors = zip(placements, placements.dropFirst()).map { current, next in
            let horizontalTransition = abs(current.imageClipRect.midY - next.imageClipRect.midY)
                < min(current.imageClipRect.height, next.imageClipRect.height) / 2
            if horizontalTransition {
                return CompositionConnectorRenderLayout(
                    start: CGPoint(x: current.imageClipRect.maxX, y: current.imageClipRect.midY),
                    end: CGPoint(x: next.imageClipRect.minX, y: next.imageClipRect.midY),
                    style: composition.steps.connectorStyle
                )
            } else {
                return CompositionConnectorRenderLayout(
                    start: CGPoint(x: current.imageClipRect.midX, y: current.frameRect.maxY),
                    end: CGPoint(x: next.imageClipRect.midX, y: next.imageClipRect.minY),
                    style: composition.steps.connectorStyle
                )
            }
        }

        let contentBounds = placements.map(\.frameRect).union
        let canvasSize = CGSize(
            width: max(contentBounds.maxX + insets.trailing, 1),
            height: max(contentBounds.maxY + insets.bottom, 1)
        )
        return makeLayout(
            composition: composition,
            resolvedMode: .steps,
            canvasSize: canvasSize,
            placements: placements,
            connectors: connectors
        )
    }

    // MARK: - Comparison

    private static func comparisonLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem]
    ) throws -> CompositionRenderLayout {
        guard items.count >= 2 else {
            throw CompositionLayoutError.comparisonRequiresTwoItems
        }

        let pair = comparisonPair(settings: composition.comparison, items: items)
        let primary = pair.0
        let secondary = pair.1
        let selectedIDs = Set([primary.item.id, secondary.item.id])
        let excludedIDs = composition.items.filter { !$0.isIncluded }.map(\.id)
        let omittedIDs = excludedIDs + items.filter { !selectedIDs.contains($0.item.id) }.map(\.item.id)
        let appearance = composition.canvas.appearance.sanitized
        let insets = appearance.insets
        let spacing = appearance.itemSpacing
        let maximumWidth = max(primary.sourceSize.width, secondary.sourceSize.width)
        let maximumHeight = max(primary.sourceSize.height, secondary.sourceSize.height)
        let primaryCaptionHeight = captionHeight(for: primary.item, width: maximumWidth, appearance: appearance)
        let secondaryCaptionHeight = captionHeight(for: secondary.item, width: maximumWidth, appearance: appearance)

        var placements: [CompositionItemRenderLayout] = []
        var canvasSize: CGSize
        var sharedFrame: CGRect?
        var dividerRect: CGRect?

        switch composition.comparison.mode {
        case .sideBySide:
            switch composition.comparison.axis {
            case .horizontal:
                let widths = proportionalSizes(
                    total: maximumWidth * 2,
                    weights: composition.layout.sizingMode == .equal
                        ? [1, 1]
                        : [primary.item.weight, secondary.item.weight],
                    count: 2
                )
                let firstImage = CGRect(
                    x: insets.leading,
                    y: insets.top,
                    width: widths[0],
                    height: maximumHeight
                )
                let secondImage = CGRect(
                    x: firstImage.maxX + spacing,
                    y: insets.top,
                    width: widths[1],
                    height: maximumHeight
                )
                placements = [
                    makePlacement(
                        primary,
                        imageRect: firstImage,
                        captionRect: primaryCaptionHeight > 0
                            ? CGRect(x: firstImage.minX, y: firstImage.maxY, width: widths[0], height: primaryCaptionHeight)
                            : nil,
                        badgeRect: nil,
                        captionPlacement: appearance.captionPlacement,
                        zIndex: 0,
                        role: .comparisonPrimary
                    ),
                    makePlacement(
                        secondary,
                        imageRect: secondImage,
                        captionRect: secondaryCaptionHeight > 0
                            ? CGRect(x: secondImage.minX, y: secondImage.maxY, width: widths[1], height: secondaryCaptionHeight)
                            : nil,
                        badgeRect: nil,
                        captionPlacement: appearance.captionPlacement,
                        zIndex: 1,
                        role: .comparisonSecondary
                    )
                ]
                canvasSize = CGSize(
                    width: insets.leading + widths.reduce(0, +) + spacing + insets.trailing,
                height: insets.top + maximumHeight
                    + reservedCaptionHeight(
                        max(primaryCaptionHeight, secondaryCaptionHeight),
                        placement: appearance.captionPlacement
                    )
                    + insets.bottom
                )
            case .vertical:
                let heights = proportionalSizes(
                    total: maximumHeight * 2,
                    weights: composition.layout.sizingMode == .equal
                        ? [1, 1]
                        : [primary.item.weight, secondary.item.weight],
                    count: 2
                )
                let firstImage = CGRect(
                    x: insets.leading,
                    y: insets.top,
                    width: maximumWidth,
                    height: heights[0]
                )
                let firstCaption = primaryCaptionHeight > 0
                    ? CGRect(x: firstImage.minX, y: firstImage.maxY, width: maximumWidth, height: primaryCaptionHeight)
                    : nil
                let secondImage = CGRect(
                    x: insets.leading,
                    y: firstImage.maxY
                        + reservedCaptionHeight(
                            primaryCaptionHeight,
                            placement: appearance.captionPlacement
                        )
                        + spacing,
                    width: maximumWidth,
                    height: heights[1]
                )
                let secondCaption = secondaryCaptionHeight > 0
                    ? CGRect(x: secondImage.minX, y: secondImage.maxY, width: maximumWidth, height: secondaryCaptionHeight)
                    : nil
                placements = [
                    makePlacement(
                        primary,
                        imageRect: firstImage,
                        captionRect: firstCaption,
                        badgeRect: nil,
                        captionPlacement: appearance.captionPlacement,
                        zIndex: 0,
                        role: .comparisonPrimary
                    ),
                    makePlacement(
                        secondary,
                        imageRect: secondImage,
                        captionRect: secondCaption,
                        badgeRect: nil,
                        captionPlacement: appearance.captionPlacement,
                        zIndex: 1,
                        role: .comparisonSecondary
                    )
                ]
                canvasSize = CGSize(
                    width: insets.leading + maximumWidth + insets.trailing,
                    height: secondImage.maxY
                        + reservedCaptionHeight(
                            secondaryCaptionHeight,
                            placement: appearance.captionPlacement
                        )
                        + insets.bottom
                )
            }
        case .overlay, .blink, .difference, .changeHighlight, .wipe:
            let imageRect = CGRect(x: insets.leading, y: insets.top, width: maximumWidth, height: maximumHeight)
            let sharedCaptionHeight = max(primaryCaptionHeight, secondaryCaptionHeight)
            let captionRect = sharedCaptionHeight > 0
                ? CGRect(x: imageRect.minX, y: imageRect.maxY, width: maximumWidth, height: sharedCaptionHeight)
                : nil
            placements = [
                makePlacement(
                    primary,
                    imageRect: imageRect,
                    captionRect: captionRect,
                    badgeRect: nil,
                    captionPlacement: appearance.captionPlacement,
                    zIndex: 0,
                    role: .comparisonPrimary
                ),
                makePlacement(
                    secondary,
                    imageRect: imageRect,
                    captionRect: captionRect,
                    badgeRect: nil,
                    captionPlacement: appearance.captionPlacement,
                    zIndex: 1,
                    role: .comparisonSecondary
                )
            ]
            sharedFrame = imageRect
            if composition.comparison.mode == .wipe {
                let position = composition.comparison.wipePosition.clampedToUnit
                switch composition.comparison.axis {
                case .horizontal:
                    dividerRect = CGRect(
                        x: imageRect.minX + imageRect.width * position - appearance.comparisonDividerWidth / 2,
                        y: imageRect.minY,
                        width: appearance.comparisonDividerWidth,
                        height: imageRect.height
                    )
                case .vertical:
                    dividerRect = CGRect(
                        x: imageRect.minX,
                        y: imageRect.minY + imageRect.height * position - appearance.comparisonDividerWidth / 2,
                        width: imageRect.width,
                        height: appearance.comparisonDividerWidth
                    )
                }
            }
            canvasSize = CGSize(
                width: insets.leading + maximumWidth + insets.trailing,
                height: insets.top + maximumHeight
                    + reservedCaptionHeight(
                        sharedCaptionHeight,
                        placement: appearance.captionPlacement
                    )
                    + insets.bottom
            )
        }

        let comparison = CompositionComparisonRenderLayout(
            mode: composition.comparison.mode,
            axis: composition.comparison.axis,
            primaryItemID: primary.item.id,
            secondaryItemID: secondary.item.id,
            sharedFrame: sharedFrame,
            dividerRect: dividerRect,
            wipePosition: composition.comparison.mode == .wipe
                ? composition.comparison.wipePosition.clampedToUnit
                : nil
        )
        return makeLayout(
            composition: composition,
            resolvedMode: .compare,
            canvasSize: canvasSize,
            placements: placements,
            comparison: comparison,
            omittedItemIDs: omittedIDs
        )
    }

    private static func comparisonPair(
        settings: CompositionComparisonSettings,
        items: [ResolvedItem]
    ) -> (ResolvedItem, ResolvedItem) {
        let primary = settings.primaryItemID.flatMap { requested in
            items.first { $0.item.id == requested }
        } ?? items[0]
        let secondary = settings.secondaryItemID.flatMap { requested in
            items.first { $0.item.id == requested && $0.item.id != primary.item.id }
        } ?? items.first { $0.item.id != primary.item.id }!
        return (primary, secondary)
    }

    // MARK: - Freeform

    private static func freeformLayout(
        composition: CompositionSnapshot,
        items: [ResolvedItem]
    ) -> CompositionRenderLayout {
        let appearance = composition.canvas.appearance.sanitized
        let insets = appearance.insets
        let spacing = appearance.itemSpacing

        var cursor = CGPoint.zero
        var raw: [(resolved: ResolvedItem, imageRect: CGRect, captionRect: CGRect?)] = []
        raw.reserveCapacity(items.count)

        for resolved in items {
            let proposed = resolved.item.freeformFrame?.standardized
            let imageRect: CGRect
            if let proposed, proposed.size.isCompositionValid {
                imageRect = proposed
            } else {
                imageRect = CGRect(origin: cursor, size: resolved.sourceSize)
                cursor.x += resolved.sourceSize.width + spacing
            }
            let captionHeight = captionHeight(
                for: resolved.item,
                width: imageRect.width,
                appearance: appearance
            )
            let captionRect = captionHeight > 0
                ? CGRect(x: imageRect.minX, y: imageRect.maxY, width: imageRect.width, height: captionHeight)
                : nil
            raw.append((resolved, imageRect, captionRect))
        }

        let rawBounds = raw.map { value in
            value.captionRect.map { value.imageRect.union($0) } ?? value.imageRect
        }.union
        let explicitCanvas = composition.layout.freeformCanvasSize
        let translation: CGSize
        let canvasSize: CGSize

        if let explicitCanvas, explicitCanvas.isCompositionValid {
            translation = CGSize(width: insets.leading, height: insets.top)
            canvasSize = CGSize(
                width: insets.leading + explicitCanvas.width + insets.trailing,
                height: insets.top + explicitCanvas.height + insets.bottom
            )
        } else {
            translation = CGSize(
                width: insets.leading - rawBounds.minX,
                height: insets.top - rawBounds.minY
            )
            canvasSize = CGSize(
                width: insets.leading + rawBounds.width + insets.trailing,
                height: insets.top + rawBounds.height + insets.bottom
            )
        }

        let placements = raw.enumerated().map { index, value in
            makePlacement(
                value.resolved,
                imageRect: value.imageRect.offsetBy(dx: translation.width, dy: translation.height),
                captionRect: value.captionRect?.offsetBy(dx: translation.width, dy: translation.height),
                badgeRect: nil,
                captionPlacement: appearance.captionPlacement,
                zIndex: value.resolved.item.zIndex == 0 ? index : value.resolved.item.zIndex,
                role: .item
            )
        }

        return makeLayout(
            composition: composition,
            resolvedMode: .freeform,
            canvasSize: canvasSize,
            placements: placements
        )
    }

    // MARK: - Placement helpers

    private static func makePlacement(
        _ resolved: ResolvedItem,
        imageRect: CGRect,
        captionRect: CGRect?,
        badgeRect: CGRect?,
        captionPlacement: CompositionCaptionPlacement,
        zIndex: Int,
        role: CompositionItemRole
    ) -> CompositionItemRenderLayout {
        var resolvedImageRect = imageRect
        var resolvedCaptionRect = captionRect
        if let captionRect {
            switch captionPlacement {
            case .hidden:
                resolvedCaptionRect = nil
            case .below:
                break
            case .above:
                resolvedCaptionRect = CGRect(
                    x: imageRect.minX,
                    y: imageRect.minY,
                    width: imageRect.width,
                    height: captionRect.height
                )
                resolvedImageRect = imageRect.offsetBy(dx: 0, dy: captionRect.height)
            case .overlayTop:
                resolvedCaptionRect = CGRect(
                    x: imageRect.minX,
                    y: imageRect.minY,
                    width: imageRect.width,
                    height: captionRect.height
                )
            case .overlayBottom:
                resolvedCaptionRect = CGRect(
                    x: imageRect.minX,
                    y: imageRect.maxY - captionRect.height,
                    width: imageRect.width,
                    height: captionRect.height
                )
            }
        }
        let drawRect = fittedRect(
            sourceSize: resolved.sourceSize,
            destination: resolvedImageRect,
            framing: resolved.item.framing
        )
        let frameRect = resolvedCaptionRect.map { resolvedImageRect.union($0) }
            ?? resolvedImageRect
        return CompositionItemRenderLayout(
            itemID: resolved.item.id,
            assetID: resolved.item.assetID,
            sourceSize: resolved.sourceSize,
            frameRect: frameRect,
            imageClipRect: resolvedImageRect,
            imageDrawRect: drawRect,
            captionRect: resolvedCaptionRect,
            badgeRect: badgeRect,
            opacity: resolved.item.opacity.clampedToUnit,
            zIndex: zIndex,
            role: role
        )
    }

    private static func fittedRect(
        sourceSize: CGSize,
        destination: CGRect,
        framing: CompositionItemFraming
    ) -> CGRect {
        let baseScale: CGFloat
        switch framing.contentMode {
        case .contain:
            baseScale = min(destination.width / sourceSize.width, destination.height / sourceSize.height)
        case .fill:
            baseScale = max(destination.width / sourceSize.width, destination.height / sourceSize.height)
        case .actualSize:
            baseScale = 1
        }
        let customScale = framing.scale.isFinite && framing.scale > 0 ? framing.scale : 1
        let drawSize = CGSize(
            width: sourceSize.width * baseScale * customScale,
            height: sourceSize.height * baseScale * customScale
        )

        let x: CGFloat
        switch framing.horizontalAlignment {
        case .leading:
            x = destination.minX
        case .center:
            x = destination.midX - drawSize.width / 2
        case .trailing:
            x = destination.maxX - drawSize.width
        }
        let y: CGFloat
        switch framing.verticalAlignment {
        case .top:
            y = destination.minY
        case .center:
            y = destination.midY - drawSize.height / 2
        case .bottom:
            y = destination.maxY - drawSize.height
        }
        let offset = framing.offset.isCompositionFinite ? framing.offset : .zero
        return CGRect(
            x: x + offset.width,
            y: y + offset.height,
            width: drawSize.width,
            height: drawSize.height
        )
    }

    private static func captionHeight(
        for item: CompositionItem,
        width: CGFloat,
        appearance: CompositionCanvasAppearance
    ) -> CGFloat {
        guard appearance.captionPlacement != .hidden else {
            return 0
        }
        guard let caption = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !caption.isEmpty,
              width > 0 else {
            return 0
        }
        let fontSize = appearance.captionFontSize
        let usableWidth = max(
            1,
            width - appearance.captionInsets.leading - appearance.captionInsets.trailing
        )
        let estimatedCharacterWidth = max(fontSize * 0.55, 1)
        let charactersPerLine = max(Int(floor(usableWidth / estimatedCharacterWidth)), 1)
        let explicitLines = caption.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = explicitLines.reduce(0) { partial, line in
            partial + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        }
        return appearance.captionInsets.top
            + CGFloat(lineCount) * ceil(fontSize * 1.25)
            + appearance.captionInsets.bottom
    }

    private static func reservedCaptionHeight(
        _ height: CGFloat,
        placement: CompositionCaptionPlacement
    ) -> CGFloat {
        switch placement {
        case .below, .above:
            return height
        case .hidden, .overlayTop, .overlayBottom:
            return 0
        }
    }

    private static func makeLayout(
        composition: CompositionSnapshot,
        resolvedMode: CompositionLayoutMode,
        canvasSize: CGSize,
        placements: [CompositionItemRenderLayout],
        connectors: [CompositionConnectorRenderLayout] = [],
        comparison: CompositionComparisonRenderLayout? = nil,
        omittedItemIDs: [UUID]? = nil
    ) -> CompositionRenderLayout {
        var boundedCanvasSize = CGSize(
            width: max(ceil(canvasSize.width), 1),
            height: max(ceil(canvasSize.height), 1)
        )
        let appearance = composition.canvas.appearance.sanitized
        let titleHeight = compositionTitleHeight(
            composition.canvas.title,
            width: max(
                boundedCanvasSize.width
                    - appearance.insets.leading
                    - appearance.insets.trailing,
                1
            ),
            appearance: appearance
        )
        var resolvedTitleRect = titleHeight > 0
            ? CGRect(
                x: appearance.insets.leading,
                y: appearance.insets.top,
                width: max(
                    boundedCanvasSize.width
                        - appearance.insets.leading
                        - appearance.insets.trailing,
                    1
                ),
                height: titleHeight
            )
            : nil
        var resolvedPlacements = titleHeight > 0
            ? placements.map { shifted($0, dx: 0, dy: titleHeight) }
            : placements
        var resolvedConnectors = titleHeight > 0
            ? connectors.map {
                CompositionConnectorRenderLayout(
                    start: $0.start.gscOffsetting(x: 0, y: titleHeight),
                    end: $0.end.gscOffsetting(x: 0, y: titleHeight),
                    style: $0.style
                )
            }
            : connectors
        var resolvedComparison = comparison.map {
            shifted($0, dx: 0, dy: titleHeight)
        }
        if titleHeight > 0 {
            boundedCanvasSize.height += titleHeight
        }

        // An explicit orientation is a canvas contract, not merely an Auto
        // scoring hint. Expand (never crop) structured layouts to the requested
        // aspect and center their complete title/content geometry.
        if composition.layout.orientation != .automatic,
           resolvedMode != .freeform {
            let target = targetAspectRatio(composition)
            let current = boundedCanvasSize.width / max(boundedCanvasSize.height, 1)
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if current > target {
                let expandedHeight = ceil(boundedCanvasSize.width / target)
                dy = (expandedHeight - boundedCanvasSize.height) / 2
                boundedCanvasSize.height = expandedHeight
            } else if current < target {
                let expandedWidth = ceil(boundedCanvasSize.height * target)
                dx = (expandedWidth - boundedCanvasSize.width) / 2
                boundedCanvasSize.width = expandedWidth
            }
            if dx != 0 || dy != 0 {
                resolvedTitleRect = resolvedTitleRect?.offsetBy(dx: dx, dy: dy)
                resolvedPlacements = resolvedPlacements.map {
                    shifted($0, dx: dx, dy: dy)
                }
                resolvedConnectors = resolvedConnectors.map {
                    CompositionConnectorRenderLayout(
                        start: $0.start.gscOffsetting(x: dx, y: dy),
                        end: $0.end.gscOffsetting(x: dx, y: dy),
                        style: $0.style
                    )
                }
                resolvedComparison = resolvedComparison.map {
                    shifted($0, dx: dx, dy: dy)
                }
            }
        }
        let contentRect = resolvedPlacements.map(\.frameRect).union
        let defaultOmitted = composition.items.filter { !$0.isIncluded }.map(\.id)
        return CompositionRenderLayout(
            requestedMode: composition.layout.mode,
            resolvedMode: resolvedMode,
            canvasSize: boundedCanvasSize,
            contentRect: contentRect,
            titleRect: resolvedTitleRect,
            items: resolvedPlacements,
            connectors: resolvedConnectors,
            comparison: resolvedComparison,
            omittedItemIDs: omittedItemIDs ?? defaultOmitted
        )
    }

    private static func compositionTitleHeight(
        _ title: String,
        width: CGFloat,
        appearance: CompositionCanvasAppearance
    ) -> CGFloat {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return 0
        }
        let usableWidth = max(
            width - appearance.titleInsets.leading - appearance.titleInsets.trailing,
            1
        )
        let estimatedCharacterWidth = max(appearance.titleFontSize * 0.55, 1)
        let charactersPerLine = max(Int(floor(usableWidth / estimatedCharacterWidth)), 1)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) {
                $0 + max(1, Int(ceil(Double($1.count) / Double(charactersPerLine))))
            }
        return appearance.titleInsets.top
            + CGFloat(lines) * ceil(appearance.titleFontSize * 1.2)
            + appearance.titleInsets.bottom
    }

    private static func shifted(
        _ placement: CompositionItemRenderLayout,
        dx: CGFloat,
        dy: CGFloat
    ) -> CompositionItemRenderLayout {
        CompositionItemRenderLayout(
            itemID: placement.itemID,
            assetID: placement.assetID,
            sourceSize: placement.sourceSize,
            frameRect: placement.frameRect.offsetBy(dx: dx, dy: dy),
            imageClipRect: placement.imageClipRect.offsetBy(dx: dx, dy: dy),
            imageDrawRect: placement.imageDrawRect.offsetBy(dx: dx, dy: dy),
            captionRect: placement.captionRect?.offsetBy(dx: dx, dy: dy),
            badgeRect: placement.badgeRect?.offsetBy(dx: dx, dy: dy),
            opacity: placement.opacity,
            zIndex: placement.zIndex,
            role: placement.role
        )
    }

    private static func shifted(
        _ comparison: CompositionComparisonRenderLayout,
        dx: CGFloat,
        dy: CGFloat
    ) -> CompositionComparisonRenderLayout {
        CompositionComparisonRenderLayout(
            mode: comparison.mode,
            axis: comparison.axis,
            primaryItemID: comparison.primaryItemID,
            secondaryItemID: comparison.secondaryItemID,
            sharedFrame: comparison.sharedFrame?.offsetBy(dx: dx, dy: dy),
            dividerRect: comparison.dividerRect?.offsetBy(dx: dx, dy: dy),
            wipePosition: comparison.wipePosition
        )
    }
}

private nonisolated extension CompositionCanvasAppearance {
    var sanitized: CompositionCanvasAppearance {
        var copy = self
        copy.insets = CompositionInsets(
            top: topLevelFiniteNonnegative(insets.top),
            leading: topLevelFiniteNonnegative(insets.leading),
            bottom: topLevelFiniteNonnegative(insets.bottom),
            trailing: topLevelFiniteNonnegative(insets.trailing)
        )
        copy.itemSpacing = topLevelFiniteNonnegative(itemSpacing)
        copy.itemBorderWidth = topLevelFiniteNonnegative(itemBorderWidth)
        copy.itemCornerRadius = topLevelFiniteNonnegative(itemCornerRadius)
        copy.itemShadowBlur = topLevelFiniteNonnegative(itemShadowBlur)
        copy.captionFontSize = max(topLevelFiniteNonnegative(captionFontSize), 1)
        copy.captionInsets = CompositionInsets(
            top: topLevelFiniteNonnegative(captionInsets.top),
            leading: topLevelFiniteNonnegative(captionInsets.leading),
            bottom: topLevelFiniteNonnegative(captionInsets.bottom),
            trailing: topLevelFiniteNonnegative(captionInsets.trailing)
        )
        copy.titleFontSize = max(topLevelFiniteNonnegative(titleFontSize), 1)
        copy.titleInsets = CompositionInsets(
            top: topLevelFiniteNonnegative(titleInsets.top),
            leading: topLevelFiniteNonnegative(titleInsets.leading),
            bottom: topLevelFiniteNonnegative(titleInsets.bottom),
            trailing: topLevelFiniteNonnegative(titleInsets.trailing)
        )
        copy.stepBadgeDiameter = max(topLevelFiniteNonnegative(stepBadgeDiameter), 1)
        copy.connectorWidth = topLevelFiniteNonnegative(connectorWidth)
        copy.comparisonDividerWidth = topLevelFiniteNonnegative(comparisonDividerWidth)
        return copy
    }
}

private nonisolated extension CGFloat {
    var clampedToUnit: CGFloat {
        guard isFinite else { return 0 }
        return Swift.min(Swift.max(self, 0), 1)
    }
}

private nonisolated extension CGSize {
    var isCompositionValid: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }

    var isCompositionFinite: Bool {
        width.isFinite && height.isFinite
    }
}

private nonisolated extension Array where Element == CGRect {
    var union: CGRect {
        guard let first else { return .zero }
        return dropFirst().reduce(first) { $0.union($1) }
    }
}

private nonisolated func topLevelFiniteNonnegative(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(value, 0) : 0
}
