import CoreGraphics
import Foundation

/// The top-left-origin coordinate space used by composition layout, hit testing,
/// and canvas annotations. Rendering is responsible for converting it to Quartz.
nonisolated enum CompositionLayoutMode: String, CaseIterable, Codable, Sendable {
    case auto
    case compare
    case steps
    case row
    case column
    case grid
    case freeform
}

nonisolated enum CompositionAxis: String, CaseIterable, Codable, Sendable {
    case horizontal
    case vertical
}

nonisolated enum CompositionSizingMode: String, CaseIterable, Codable, Sendable {
    case equal
    case weighted
}

nonisolated enum CompositionCanvasOrientation: String, CaseIterable, Codable, Sendable {
    case automatic
    case landscape
    case portrait
    case square
    case custom
}

nonisolated enum CompositionComparisonMode: String, CaseIterable, Codable, Sendable {
    case sideBySide
    case overlay
    case wipe
    case blink
    case difference
    case changeHighlight
}

nonisolated enum CompositionRegistrationMode: String, CaseIterable, Codable, Sendable {
    case automatic
    case manual
    case disabled
}

nonisolated enum CompositionDifferenceCueStyle: String, CaseIterable, Codable, Sendable {
    case luminance
    case outline
    case pattern
    case outlineAndPattern
}

nonisolated enum CompositionPosterFrame: String, CaseIterable, Codable, Sendable {
    case primary
    case secondary
}

nonisolated struct CompositionComparisonSettings: Equatable, Codable, Sendable {
    var mode: CompositionComparisonMode
    var axis: CompositionAxis
    var primaryItemID: UUID?
    var secondaryItemID: UUID?
    var wipePosition: CGFloat
    var overlayOpacity: CGFloat
    var blinkInterval: TimeInterval
    var differenceIntensity: CGFloat
    var changeThreshold: CGFloat
    var changeHighlightColor: RGBAColor
    var primaryLabel: String
    var secondaryLabel: String
    var showsLabels: Bool
    var keepsViewsLinked: Bool
    var registrationMode: CompositionRegistrationMode
    var manualRegistrationOffset: CGSize
    var registrationSensitivity: CGFloat
    var unchangedContentOpacity: CGFloat
    var differenceCueStyle: CompositionDifferenceCueStyle
    var blinkCrossfadeDuration: TimeInterval
    var blinkLoops: Bool
    var posterFrame: CompositionPosterFrame

    init(
        mode: CompositionComparisonMode = .sideBySide,
        axis: CompositionAxis = .horizontal,
        primaryItemID: UUID? = nil,
        secondaryItemID: UUID? = nil,
        wipePosition: CGFloat = 0.5,
        overlayOpacity: CGFloat = 0.5,
        blinkInterval: TimeInterval = 0.75,
        differenceIntensity: CGFloat = 1,
        changeThreshold: CGFloat = 0.1,
        changeHighlightColor: RGBAColor = .calloutFill,
        primaryLabel: String = "Before",
        secondaryLabel: String = "After",
        showsLabels: Bool = true,
        keepsViewsLinked: Bool = true,
        registrationMode: CompositionRegistrationMode = .automatic,
        manualRegistrationOffset: CGSize = .zero,
        registrationSensitivity: CGFloat = 0.5,
        unchangedContentOpacity: CGFloat = 0.2,
        differenceCueStyle: CompositionDifferenceCueStyle = .outlineAndPattern,
        blinkCrossfadeDuration: TimeInterval = 0,
        blinkLoops: Bool = true,
        posterFrame: CompositionPosterFrame = .secondary
    ) {
        self.mode = mode
        self.axis = axis
        self.primaryItemID = primaryItemID
        self.secondaryItemID = secondaryItemID
        self.wipePosition = wipePosition
        self.overlayOpacity = overlayOpacity
        self.blinkInterval = blinkInterval
        self.differenceIntensity = differenceIntensity
        self.changeThreshold = changeThreshold
        self.changeHighlightColor = changeHighlightColor
        self.primaryLabel = primaryLabel
        self.secondaryLabel = secondaryLabel
        self.showsLabels = showsLabels
        self.keepsViewsLinked = keepsViewsLinked
        self.registrationMode = registrationMode
        self.manualRegistrationOffset = manualRegistrationOffset
        self.registrationSensitivity = registrationSensitivity
        self.unchangedContentOpacity = unchangedContentOpacity
        self.differenceCueStyle = differenceCueStyle
        self.blinkCrossfadeDuration = blinkCrossfadeDuration
        self.blinkLoops = blinkLoops
        self.posterFrame = posterFrame
    }
}

nonisolated enum CompositionStepNumberingStyle: String, CaseIterable, Codable, Sendable {
    case none
    case decimal
    case uppercaseLetters
    case lowercaseLetters
    case uppercaseRoman
    case lowercaseRoman
}

nonisolated enum CompositionStepConnectorStyle: String, CaseIterable, Codable, Sendable {
    case none
    case line
    case arrow
}

nonisolated enum CompositionStepFlow: String, CaseIterable, Codable, Sendable {
    case row
    case column
    case grid
}

nonisolated struct CompositionStepsSettings: Equatable, Codable, Sendable {
    var axis: CompositionAxis
    var flow: CompositionStepFlow
    var gridColumns: Int
    var numberingStyle: CompositionStepNumberingStyle
    var startIndex: Int
    var showsCaptions: Bool
    var connectorStyle: CompositionStepConnectorStyle
    var itemsPerPage: Int?

    init(
        axis: CompositionAxis = .vertical,
        flow: CompositionStepFlow = .column,
        gridColumns: Int = 2,
        numberingStyle: CompositionStepNumberingStyle = .decimal,
        startIndex: Int = 1,
        showsCaptions: Bool = true,
        connectorStyle: CompositionStepConnectorStyle = .arrow,
        itemsPerPage: Int? = nil
    ) {
        self.axis = axis
        self.flow = flow
        self.gridColumns = gridColumns
        self.numberingStyle = numberingStyle
        self.startIndex = startIndex
        self.showsCaptions = showsCaptions
        self.connectorStyle = connectorStyle
        self.itemsPerPage = itemsPerPage
    }

    func label(for zeroBasedIndex: Int) -> String? {
        let value = max(0, startIndex + zeroBasedIndex)

        switch numberingStyle {
        case .none:
            return nil
        case .decimal:
            return String(value)
        case .uppercaseLetters:
            return Self.alphabeticLabel(for: value).uppercased()
        case .lowercaseLetters:
            return Self.alphabeticLabel(for: value).lowercased()
        case .uppercaseRoman:
            return Self.romanLabel(for: value).uppercased()
        case .lowercaseRoman:
            return Self.romanLabel(for: value).lowercased()
        }
    }

    private static func alphabeticLabel(for value: Int) -> String {
        var remainder = max(value, 1)
        var result = ""
        while remainder > 0 {
            remainder -= 1
            let scalar = UnicodeScalar(65 + remainder % 26)!
            result.insert(Character(scalar), at: result.startIndex)
            remainder /= 26
        }
        return result
    }

    private static func romanLabel(for value: Int) -> String {
        // Repeating M keeps large, user-selected start values deterministic
        // instead of silently collapsing every value above 3,999 to the same
        // label.
        var remainder = max(value, 1)
        let numerals: [(Int, String)] = [
            (1_000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var result = ""
        for (amount, numeral) in numerals {
            while remainder >= amount {
                result += numeral
                remainder -= amount
            }
        }
        return result
    }
}

nonisolated struct CompositionInsets: Equatable, Codable, Sendable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    init(_ value: CGFloat) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }

    static let zero = CompositionInsets(0)
}

nonisolated enum CompositionCanvasFill: Equatable, Codable, Sendable {
    case transparent
    case color(RGBAColor)
}

nonisolated enum CompositionCaptionPlacement: String, CaseIterable, Codable, Sendable {
    case hidden
    case below
    case above
    case overlayTop
    case overlayBottom
}

nonisolated enum CompositionTextWeight: String, CaseIterable, Codable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

nonisolated enum CompositionTextAlignment: String, CaseIterable, Codable, Sendable {
    case leading
    case center
    case trailing
}

nonisolated struct CompositionCanvasAppearance: Equatable, Codable, Sendable {
    var fill: CompositionCanvasFill
    var insets: CompositionInsets
    var itemSpacing: CGFloat
    var itemFill: RGBAColor
    var itemBorderColor: RGBAColor
    var itemBorderWidth: CGFloat
    var itemCornerRadius: CGFloat
    var itemShadowColor: RGBAColor
    var itemShadowBlur: CGFloat
    var itemShadowOffset: CGSize
    var captionColor: RGBAColor
    var captionBackgroundColor: RGBAColor
    var captionFontSize: CGFloat
    var captionFontName: String?
    var captionFontWeight: CompositionTextWeight
    var captionTextAlignment: CompositionTextAlignment
    var captionPlacement: CompositionCaptionPlacement
    var captionInsets: CompositionInsets
    var titleColor: RGBAColor
    var titleBackgroundColor: RGBAColor
    var titleFontSize: CGFloat
    var titleFontName: String?
    var titleFontWeight: CompositionTextWeight
    var titleTextAlignment: CompositionTextAlignment
    var titleInsets: CompositionInsets
    var stepBadgeFill: RGBAColor
    var stepBadgeForeground: RGBAColor
    var stepBadgeDiameter: CGFloat
    var connectorColor: RGBAColor
    var connectorWidth: CGFloat
    var comparisonDividerColor: RGBAColor
    var comparisonDividerWidth: CGFloat

    init(
        fill: CompositionCanvasFill = .transparent,
        insets: CompositionInsets = CompositionInsets(24),
        itemSpacing: CGFloat = 16,
        itemFill: RGBAColor = .clear,
        itemBorderColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.18),
        itemBorderWidth: CGFloat = 0,
        itemCornerRadius: CGFloat = 0,
        itemShadowColor: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.22),
        itemShadowBlur: CGFloat = 0,
        itemShadowOffset: CGSize = .zero,
        captionColor: RGBAColor = RGBAColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
        captionBackgroundColor: RGBAColor = .clear,
        captionFontSize: CGFloat = 14,
        captionFontName: String? = nil,
        captionFontWeight: CompositionTextWeight = .regular,
        captionTextAlignment: CompositionTextAlignment = .leading,
        captionPlacement: CompositionCaptionPlacement = .below,
        captionInsets: CompositionInsets = CompositionInsets(top: 8, leading: 8, bottom: 8, trailing: 8),
        titleColor: RGBAColor = RGBAColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
        titleBackgroundColor: RGBAColor = .clear,
        titleFontSize: CGFloat = 28,
        titleFontName: String? = nil,
        titleFontWeight: CompositionTextWeight = .semibold,
        titleTextAlignment: CompositionTextAlignment = .leading,
        titleInsets: CompositionInsets = CompositionInsets(top: 8, leading: 4, bottom: 16, trailing: 4),
        stepBadgeFill: RGBAColor = .ellipseStroke,
        stepBadgeForeground: RGBAColor = .textForeground,
        stepBadgeDiameter: CGFloat = 28,
        connectorColor: RGBAColor = RGBAColor(red: 0.38, green: 0.40, blue: 0.45, alpha: 1),
        connectorWidth: CGFloat = 2,
        comparisonDividerColor: RGBAColor = .textForeground,
        comparisonDividerWidth: CGFloat = 2
    ) {
        self.fill = fill
        self.insets = insets
        self.itemSpacing = itemSpacing
        self.itemFill = itemFill
        self.itemBorderColor = itemBorderColor
        self.itemBorderWidth = itemBorderWidth
        self.itemCornerRadius = itemCornerRadius
        self.itemShadowColor = itemShadowColor
        self.itemShadowBlur = itemShadowBlur
        self.itemShadowOffset = itemShadowOffset
        self.captionColor = captionColor
        self.captionBackgroundColor = captionBackgroundColor
        self.captionFontSize = captionFontSize
        self.captionFontName = captionFontName
        self.captionFontWeight = captionFontWeight
        self.captionTextAlignment = captionTextAlignment
        self.captionPlacement = captionPlacement
        self.captionInsets = captionInsets
        self.titleColor = titleColor
        self.titleBackgroundColor = titleBackgroundColor
        self.titleFontSize = titleFontSize
        self.titleFontName = titleFontName
        self.titleFontWeight = titleFontWeight
        self.titleTextAlignment = titleTextAlignment
        self.titleInsets = titleInsets
        self.stepBadgeFill = stepBadgeFill
        self.stepBadgeForeground = stepBadgeForeground
        self.stepBadgeDiameter = stepBadgeDiameter
        self.connectorColor = connectorColor
        self.connectorWidth = connectorWidth
        self.comparisonDividerColor = comparisonDividerColor
        self.comparisonDividerWidth = comparisonDividerWidth
    }

    static let pixelPreserving = CompositionCanvasAppearance(
        fill: .transparent,
        insets: .zero,
        itemSpacing: 0
    )
}

nonisolated struct CompositionLayoutConfiguration: Equatable, Codable, Sendable {
    var mode: CompositionLayoutMode
    var gridColumns: Int?
    var targetAspectRatio: CGFloat
    var freeformCanvasSize: CGSize?
    var sizingMode: CompositionSizingMode
    var orientation: CompositionCanvasOrientation

    init(
        mode: CompositionLayoutMode = .auto,
        gridColumns: Int? = nil,
        targetAspectRatio: CGFloat = 4 / 3,
        freeformCanvasSize: CGSize? = nil,
        sizingMode: CompositionSizingMode = .equal,
        orientation: CompositionCanvasOrientation = .automatic
    ) {
        self.mode = mode
        self.gridColumns = gridColumns
        self.targetAspectRatio = targetAspectRatio
        self.freeformCanvasSize = freeformCanvasSize
        self.sizingMode = sizingMode
        self.orientation = orientation
    }
}

nonisolated enum CompositionContentMode: String, CaseIterable, Codable, Sendable {
    case contain
    case fill
    case actualSize
}

nonisolated enum CompositionHorizontalAlignment: String, CaseIterable, Codable, Sendable {
    case leading
    case center
    case trailing
}

nonisolated enum CompositionVerticalAlignment: String, CaseIterable, Codable, Sendable {
    case top
    case center
    case bottom
}

nonisolated struct CompositionItemFraming: Equatable, Codable, Sendable {
    var contentMode: CompositionContentMode
    var horizontalAlignment: CompositionHorizontalAlignment
    var verticalAlignment: CompositionVerticalAlignment
    var scale: CGFloat
    var offset: CGSize
    var linkGroupID: UUID?

    init(
        contentMode: CompositionContentMode = .contain,
        horizontalAlignment: CompositionHorizontalAlignment = .center,
        verticalAlignment: CompositionVerticalAlignment = .center,
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        linkGroupID: UUID? = nil
    ) {
        self.contentMode = contentMode
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.scale = scale
        self.offset = offset
        self.linkGroupID = linkGroupID
    }
}

nonisolated enum CompositionItemSemanticRole: String, CaseIterable, Codable, Sendable {
    case standard
    case before
    case after
    case step
}

/// Immutable metadata for an original composition asset. Pixel dimensions are
/// stored explicitly so layout never has to decode or mutate the backing image.
nonisolated struct CompositionAssetDescriptor: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceName: String
    let capturedAt: Date?
    let accessibilityLabel: String?
    let captureKind: String?
    let sourceRect: CGRect?
    let coordinateContract: DocumentCoordinateContract
    let isPrivate: Bool

    init(
        id: UUID = UUID(),
        pixelWidth: Int,
        pixelHeight: Int,
        sourceName: String = "",
        capturedAt: Date? = nil,
        accessibilityLabel: String? = nil,
        captureKind: String? = nil,
        sourceRect: CGRect? = nil,
        coordinateContract: DocumentCoordinateContract = .current,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourceName = sourceName
        self.capturedAt = capturedAt
        self.accessibilityLabel = accessibilityLabel
        self.captureKind = captureKind
        self.sourceRect = sourceRect
        self.coordinateContract = coordinateContract
        self.isPrivate = isPrivate
    }

    var pixelSize: CGSize {
        CGSize(width: max(0, pixelWidth), height: max(0, pixelHeight))
    }
}

/// Immutable pixels paired with their immutable source descriptor.
nonisolated struct CompositionAsset: @unchecked Sendable {
    let descriptor: CompositionAssetDescriptor
    let image: CGImage
    let uiMap: UIMapSnapshot?

    init?(
        descriptor: CompositionAssetDescriptor,
        image: CGImage,
        uiMap: UIMapSnapshot? = nil
    ) {
        guard descriptor.pixelWidth == image.width,
              descriptor.pixelHeight == image.height,
              image.width > 0,
              image.height > 0 else {
            return nil
        }
        self.descriptor = descriptor
        self.image = image
        self.uiMap = uiMap
    }

    init(
        id: UUID = UUID(),
        image: CGImage,
        sourceName: String = "",
        capturedAt: Date? = nil,
        accessibilityLabel: String? = nil,
        captureKind: String? = nil,
        sourceRect: CGRect? = nil,
        coordinateContract: DocumentCoordinateContract = .current,
        isPrivate: Bool = false,
        uiMap: UIMapSnapshot? = nil
    ) {
        self.descriptor = CompositionAssetDescriptor(
            id: id,
            pixelWidth: image.width,
            pixelHeight: image.height,
            sourceName: sourceName,
            capturedAt: capturedAt,
            accessibilityLabel: accessibilityLabel,
            captureKind: captureKind,
            sourceRect: sourceRect,
            coordinateContract: coordinateContract,
            isPrivate: isPrivate
        )
        self.image = image
        self.uiMap = uiMap
    }
}

/// Item-scoped screenshot edits remain separate from the immutable source
/// pixels. `Annotation` is intentionally reused so every existing editor tool
/// works without a second, lossy annotation representation.
nonisolated struct ScreenshotEditState: Equatable {
    var cropRect: CGRect?
    var annotations: [Annotation]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var pinnedUIMapElementIDs: [UUID]

    init(
        cropRect: CGRect? = nil,
        annotations: [Annotation] = [],
        selectedAnnotationIDs: [UUID] = [],
        nextCalloutNumber: Int = 1,
        pinnedUIMapElementIDs: [UUID] = []
    ) {
        self.cropRect = cropRect
        self.annotations = annotations
        self.selectedAnnotationIDs = selectedAnnotationIDs
        self.nextCalloutNumber = nextCalloutNumber
        self.pinnedUIMapElementIDs = pinnedUIMapElementIDs
    }
}

nonisolated struct CompositionItem: Identifiable, Equatable {
    let id: UUID
    let assetID: UUID
    var editState: ScreenshotEditState
    var framing: CompositionItemFraming
    var opacity: CGFloat
    var weight: CGFloat
    var title: String
    var caption: String?
    var accessibilityLabel: String?
    var freeformFrame: CGRect?
    var isIncluded: Bool
    var semanticRole: CompositionItemSemanticRole
    var zIndex: Int

    init(
        id: UUID = UUID(),
        assetID: UUID,
        editState: ScreenshotEditState = ScreenshotEditState(),
        framing: CompositionItemFraming = CompositionItemFraming(),
        opacity: CGFloat = 1,
        weight: CGFloat = 1,
        title: String = "",
        caption: String? = nil,
        accessibilityLabel: String? = nil,
        freeformFrame: CGRect? = nil,
        isIncluded: Bool = true,
        semanticRole: CompositionItemSemanticRole = .standard,
        zIndex: Int = 0
    ) {
        self.id = id
        self.assetID = assetID
        self.editState = editState
        self.framing = framing
        self.opacity = opacity
        self.weight = weight
        self.title = title
        self.caption = caption
        self.accessibilityLabel = accessibilityLabel
        self.freeformFrame = freeformFrame
        self.isIncluded = isIncluded
        self.semanticRole = semanticRole
        self.zIndex = zIndex
    }
}

nonisolated enum CompositionAnchorTarget: Equatable, Codable, Sendable {
    case canvasNormalized(CGPoint)
    case itemNormalized(itemID: UUID, point: CGPoint)
    case detachedCanvas(CGPoint)
}

nonisolated struct CompositionAnnotationAnchor: Equatable, Codable, Sendable {
    var target: CompositionAnchorTarget
    /// The most recently resolved top-left composition coordinate. It provides
    /// a deterministic detachment location if the referenced item is removed.
    var lastCanvasPoint: CGPoint

    init(target: CompositionAnchorTarget, lastCanvasPoint: CGPoint) {
        self.target = target
        self.lastCanvasPoint = lastCanvasPoint
    }
}

nonisolated struct CompositionAnnotationAnchors: Equatable, Codable, Sendable {
    var primary: CompositionAnnotationAnchor
    var secondary: CompositionAnnotationAnchor?
}

/// Whole-canvas edits are independent from each item's screenshot edits.
nonisolated struct CompositionCanvasState: Equatable {
    var title: String
    var appearance: CompositionCanvasAppearance
    var annotations: [Annotation]
    var selectedAnnotationIDs: [UUID]
    var nextCalloutNumber: Int
    var annotationAnchors: [UUID: CompositionAnnotationAnchors]

    init(
        title: String = "",
        appearance: CompositionCanvasAppearance = .pixelPreserving,
        annotations: [Annotation] = [],
        selectedAnnotationIDs: [UUID] = [],
        nextCalloutNumber: Int = 1,
        annotationAnchors: [UUID: CompositionAnnotationAnchors] = [:]
    ) {
        self.title = title
        self.appearance = appearance
        self.annotations = annotations
        self.selectedAnnotationIDs = selectedAnnotationIDs
        self.nextCalloutNumber = nextCalloutNumber
        self.annotationAnchors = annotationAnchors
    }
}

nonisolated struct CompositionSnapshot: Equatable {
    var items: [CompositionItem]
    var selectedItemIDs: [UUID]
    /// A one-item composition can transparently back the legacy single-capture
    /// editor without exposing composition-specific UI until the user adds or
    /// otherwise activates composition content.
    var isActivated: Bool
    var layout: CompositionLayoutConfiguration
    var comparison: CompositionComparisonSettings
    var steps: CompositionStepsSettings
    var canvas: CompositionCanvasState

    init(
        items: [CompositionItem],
        selectedItemIDs: [UUID] = [],
        isActivated: Bool = true,
        layout: CompositionLayoutConfiguration = CompositionLayoutConfiguration(),
        comparison: CompositionComparisonSettings = CompositionComparisonSettings(),
        steps: CompositionStepsSettings = CompositionStepsSettings(),
        canvas: CompositionCanvasState = CompositionCanvasState()
    ) {
        self.items = items
        self.selectedItemIDs = selectedItemIDs
        self.isActivated = isActivated
        self.layout = layout
        self.comparison = comparison
        self.steps = steps
        self.canvas = canvas
    }
}

nonisolated enum CompositionItemRole: Equatable, Codable, Sendable {
    case item
    case comparisonPrimary
    case comparisonSecondary
    case step(index: Int, label: String?)
}

nonisolated struct CompositionItemRenderLayout: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let itemID: UUID
    let assetID: UUID
    let sourceSize: CGSize
    let frameRect: CGRect
    let imageClipRect: CGRect
    let imageDrawRect: CGRect
    let captionRect: CGRect?
    let badgeRect: CGRect?
    let opacity: CGFloat
    let zIndex: Int
    let role: CompositionItemRole

    init(
        itemID: UUID,
        assetID: UUID,
        sourceSize: CGSize,
        frameRect: CGRect,
        imageClipRect: CGRect,
        imageDrawRect: CGRect,
        captionRect: CGRect?,
        badgeRect: CGRect?,
        opacity: CGFloat,
        zIndex: Int,
        role: CompositionItemRole
    ) {
        self.id = itemID
        self.itemID = itemID
        self.assetID = assetID
        self.sourceSize = sourceSize
        self.frameRect = frameRect
        self.imageClipRect = imageClipRect
        self.imageDrawRect = imageDrawRect
        self.captionRect = captionRect
        self.badgeRect = badgeRect
        self.opacity = opacity
        self.zIndex = zIndex
        self.role = role
    }

    func sourceNormalizedPoint(at canvasPoint: CGPoint) -> CGPoint? {
        guard imageClipRect.contains(canvasPoint),
              imageDrawRect.width > 0,
              imageDrawRect.height > 0 else {
            return nil
        }
        return CGPoint(
            x: min(max((canvasPoint.x - imageDrawRect.minX) / imageDrawRect.width, 0), 1),
            y: min(max((canvasPoint.y - imageDrawRect.minY) / imageDrawRect.height, 0), 1)
        )
    }
}

nonisolated struct CompositionConnectorRenderLayout: Equatable, Codable, Sendable {
    let start: CGPoint
    let end: CGPoint
    let style: CompositionStepConnectorStyle
}

nonisolated enum CompositionComparisonClip: Equatable, Codable, Sendable {
    case none
    case leading(fraction: CGFloat, axis: CompositionAxis)
    case trailing(fraction: CGFloat, axis: CompositionAxis)
}

nonisolated struct CompositionComparisonRenderLayout: Equatable, Codable, Sendable {
    let mode: CompositionComparisonMode
    let axis: CompositionAxis
    let primaryItemID: UUID
    let secondaryItemID: UUID
    let sharedFrame: CGRect?
    let dividerRect: CGRect?
    let wipePosition: CGFloat?

    init(
        mode: CompositionComparisonMode,
        axis: CompositionAxis,
        primaryItemID: UUID,
        secondaryItemID: UUID,
        sharedFrame: CGRect?,
        dividerRect: CGRect?,
        wipePosition: CGFloat? = nil
    ) {
        self.mode = mode
        self.axis = axis
        self.primaryItemID = primaryItemID
        self.secondaryItemID = secondaryItemID
        self.sharedFrame = sharedFrame
        self.dividerRect = dividerRect
        self.wipePosition = wipePosition
    }
}

nonisolated enum CompositionHitRegion: String, Codable, Sendable {
    case image
    case caption
    case stepBadge
    case frame
}

nonisolated struct CompositionHitResult: Equatable, Codable, Sendable {
    let itemID: UUID
    let assetID: UUID
    let region: CompositionHitRegion
    let sourceNormalizedPoint: CGPoint?
}

nonisolated struct CompositionRenderLayout: Equatable, Codable, Sendable {
    let requestedMode: CompositionLayoutMode
    let resolvedMode: CompositionLayoutMode
    let canvasSize: CGSize
    let contentRect: CGRect
    let titleRect: CGRect?
    let items: [CompositionItemRenderLayout]
    let connectors: [CompositionConnectorRenderLayout]
    let comparison: CompositionComparisonRenderLayout?
    let omittedItemIDs: [UUID]

    init(
        requestedMode: CompositionLayoutMode,
        resolvedMode: CompositionLayoutMode,
        canvasSize: CGSize,
        contentRect: CGRect,
        titleRect: CGRect? = nil,
        items: [CompositionItemRenderLayout],
        connectors: [CompositionConnectorRenderLayout],
        comparison: CompositionComparisonRenderLayout?,
        omittedItemIDs: [UUID]
    ) {
        self.requestedMode = requestedMode
        self.resolvedMode = resolvedMode
        self.canvasSize = canvasSize
        self.contentRect = contentRect
        self.titleRect = titleRect
        self.items = items
        self.connectors = connectors
        self.comparison = comparison
        self.omittedItemIDs = omittedItemIDs
    }

    var canvasRect: CGRect {
        CGRect(origin: .zero, size: canvasSize)
    }

    func itemLayout(for itemID: UUID) -> CompositionItemRenderLayout? {
        items.first { $0.itemID == itemID }
    }

    func hitTest(
        _ point: CGPoint,
        comparisonPhase: CompositionPosterFrame = .primary,
        overlayOpacity: CGFloat = 1
    ) -> CompositionHitResult? {
        if let comparison,
           comparison.mode != .sideBySide,
           let primary = itemLayout(for: comparison.primaryItemID),
           let secondary = itemLayout(for: comparison.secondaryItemID) {
            if let captionRect = primary.captionRect, captionRect.contains(point) {
                return hitResult(for: primary, at: point)
            }
            if primary.imageClipRect.contains(point) {
                let visiblePlacement: CompositionItemRenderLayout
                switch comparison.mode {
                case .wipe:
                    let fraction = min(max(comparison.wipePosition ?? 0.5, 0), 1)
                    let revealsSecondary: Bool
                    switch comparison.axis {
                    case .horizontal:
                        revealsSecondary = point.x
                            <= primary.imageClipRect.minX + primary.imageClipRect.width * fraction
                    case .vertical:
                        revealsSecondary = point.y
                            <= primary.imageClipRect.minY + primary.imageClipRect.height * fraction
                    }
                    visiblePlacement =
                        revealsSecondary && secondary.opacity > 0.001
                        ? secondary
                        : primary
                case .overlay:
                    visiblePlacement =
                        secondary.opacity * overlayOpacity > 0.001
                        ? secondary
                        : primary
                case .blink:
                    visiblePlacement = comparisonPhase == .secondary
                        ? secondary
                        : primary
                case .difference, .changeHighlight:
                    visiblePlacement = primary
                case .sideBySide:
                    visiblePlacement = primary
                }
                return hitResult(for: visiblePlacement, at: point)
            }
        }

        for item in items.sorted(by: { $0.zIndex > $1.zIndex }) {
            if let result = hitResult(for: item, at: point) { return result }
        }
        return nil
    }

    private func hitResult(
        for item: CompositionItemRenderLayout,
        at point: CGPoint
    ) -> CompositionHitResult? {
        let region: CompositionHitRegion
        let sourcePoint: CGPoint?
        if let badgeRect = item.badgeRect, badgeRect.contains(point) {
            region = .stepBadge
            sourcePoint = nil
        } else if let captionRect = item.captionRect, captionRect.contains(point) {
            region = .caption
            sourcePoint = nil
        } else if item.imageClipRect.contains(point) {
            region = .image
            sourcePoint = item.sourceNormalizedPoint(at: point)
        } else if item.frameRect.contains(point) {
            region = .frame
            sourcePoint = nil
        } else {
            return nil
        }
        return CompositionHitResult(
            itemID: item.itemID,
            assetID: item.assetID,
            region: region,
            sourceNormalizedPoint: sourcePoint
        )
    }
}

nonisolated enum CompositionLayoutError: LocalizedError, Equatable {
    case emptyComposition
    case missingAssetDescriptor(assetID: UUID)
    case invalidAssetDimensions(assetID: UUID)
    case comparisonRequiresTwoItems

    var errorDescription: String? {
        switch self {
        case .emptyComposition:
            return "The composition has no included images."
        case .missingAssetDescriptor(let assetID):
            return "The composition is missing image metadata for \(assetID.uuidString)."
        case .invalidAssetDimensions(let assetID):
            return "The composition image \(assetID.uuidString) has invalid dimensions."
        case .comparisonRequiresTwoItems:
            return "Comparison layouts require at least two included images."
        }
    }
}
