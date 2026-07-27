import CoreGraphics
import Foundation

nonisolated enum CompositionTemplateSource: String, Codable, Sendable {
    case builtIn
    case user
}

nonisolated enum CompositionTemplateItemCount: Equatable, Codable, Sendable {
    case exact(Int)
    case flexible(minimum: Int, maximum: Int?)

    func accepts(_ count: Int) -> Bool {
        switch self {
        case .exact(let expected):
            return count == expected
        case .flexible(let minimum, let maximum):
            return count >= minimum && maximum.map { count <= $0 } ?? true
        }
    }

    var exactCount: Int? {
        guard case .exact(let count) = self else { return nil }
        return count
    }
}

/// Framing saved without document-specific link UUIDs. A small integer links
/// indexed template items without leaking identities from the source document.
nonisolated struct CompositionTemplateFraming: Equatable, Codable, Sendable {
    var contentMode: CompositionContentMode
    var horizontalAlignment: CompositionHorizontalAlignment
    var verticalAlignment: CompositionVerticalAlignment
    var scale: CGFloat
    var offset: CGSize
    var linkGroupIndex: Int?

    init(_ framing: CompositionItemFraming, linkGroupIndex: Int?) {
        contentMode = framing.contentMode
        horizontalAlignment = framing.horizontalAlignment
        verticalAlignment = framing.verticalAlignment
        scale = framing.scale
        offset = framing.offset
        self.linkGroupIndex = linkGroupIndex
    }

    func framing(linkGroupID: UUID?) -> CompositionItemFraming {
        CompositionItemFraming(
            contentMode: contentMode,
            horizontalAlignment: horizontalAlignment,
            verticalAlignment: verticalAlignment,
            scale: scale,
            offset: offset,
            linkGroupID: linkGroupID
        )
    }
}

nonisolated struct CompositionTemplateItemSettings: Equatable, Codable, Sendable {
    var framing: CompositionTemplateFraming
    var weight: CGFloat
    var opacity: CGFloat
    var normalizedFreeformFrame: CGRect?
    var zIndex: Int
}

/// Comparison configuration deliberately excludes item UUIDs. The template
/// records pair positions in the ordered item list instead.
nonisolated struct CompositionTemplateComparisonSettings: Equatable, Codable, Sendable {
    var mode: CompositionComparisonMode
    var axis: CompositionAxis
    var primaryItemIndex: Int
    var secondaryItemIndex: Int
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

    init(_ settings: CompositionComparisonSettings, items: [CompositionItem]) {
        mode = settings.mode
        axis = settings.axis
        primaryItemIndex = settings.primaryItemID
            .flatMap { requested in items.firstIndex(where: { $0.id == requested }) } ?? 0
        secondaryItemIndex = settings.secondaryItemID
            .flatMap { requested in items.firstIndex(where: { $0.id == requested }) } ?? min(1, max(items.count - 1, 0))
        wipePosition = settings.wipePosition
        overlayOpacity = settings.overlayOpacity
        blinkInterval = settings.blinkInterval
        differenceIntensity = settings.differenceIntensity
        changeThreshold = settings.changeThreshold
        changeHighlightColor = settings.changeHighlightColor
        primaryLabel = settings.primaryLabel
        secondaryLabel = settings.secondaryLabel
        showsLabels = settings.showsLabels
        keepsViewsLinked = settings.keepsViewsLinked
        registrationMode = settings.registrationMode
        manualRegistrationOffset = settings.manualRegistrationOffset
        registrationSensitivity = settings.registrationSensitivity
        unchangedContentOpacity = settings.unchangedContentOpacity
        differenceCueStyle = settings.differenceCueStyle
        blinkCrossfadeDuration = settings.blinkCrossfadeDuration
        blinkLoops = settings.blinkLoops
        posterFrame = settings.posterFrame
    }

    func settings(items: [CompositionItem]) -> CompositionComparisonSettings {
        let primaryID = items.indices.contains(primaryItemIndex)
            ? items[primaryItemIndex].id
            : items.first?.id
        let secondaryID = items.indices.contains(secondaryItemIndex)
            ? items[secondaryItemIndex].id
            : items.first(where: { $0.id != primaryID })?.id
        return CompositionComparisonSettings(
            mode: mode,
            axis: axis,
            primaryItemID: primaryID,
            secondaryItemID: secondaryID,
            wipePosition: wipePosition,
            overlayOpacity: overlayOpacity,
            blinkInterval: blinkInterval,
            differenceIntensity: differenceIntensity,
            changeThreshold: changeThreshold,
            changeHighlightColor: changeHighlightColor,
            primaryLabel: primaryLabel,
            secondaryLabel: secondaryLabel,
            showsLabels: showsLabels,
            keepsViewsLinked: keepsViewsLinked,
            registrationMode: registrationMode,
            manualRegistrationOffset: manualRegistrationOffset,
            registrationSensitivity: registrationSensitivity,
            unchangedContentOpacity: unchangedContentOpacity,
            differenceCueStyle: differenceCueStyle,
            blinkCrossfadeDuration: blinkCrossfadeDuration,
            blinkLoops: blinkLoops,
            posterFrame: posterFrame
        )
    }
}

/// Reusable composition structure and appearance. This type cannot contain
/// capture pixels, asset identifiers, item identifiers, titles, or captions.
nonisolated struct CompositionTemplate: Identifiable, Equatable, Codable, Sendable {
    static let formatVersion = 1

    var formatVersion: Int
    var id: String
    var name: String
    var source: CompositionTemplateSource
    var itemCount: CompositionTemplateItemCount
    var layout: CompositionLayoutConfiguration
    var appearance: CompositionCanvasAppearance
    var comparison: CompositionTemplateComparisonSettings
    var steps: CompositionStepsSettings
    var itemSettings: [CompositionTemplateItemSettings]

    init(
        formatVersion: Int = CompositionTemplate.formatVersion,
        id: String,
        name: String,
        source: CompositionTemplateSource,
        itemCount: CompositionTemplateItemCount,
        layout: CompositionLayoutConfiguration,
        appearance: CompositionCanvasAppearance,
        comparison: CompositionTemplateComparisonSettings,
        steps: CompositionStepsSettings,
        itemSettings: [CompositionTemplateItemSettings]
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.source = source
        self.itemCount = itemCount
        self.layout = layout
        self.appearance = appearance
        self.comparison = comparison
        self.steps = steps
        self.itemSettings = itemSettings
    }

    var isBuiltIn: Bool { source == .builtIn }

    func isCompatible(itemCount: Int) -> Bool {
        self.itemCount.accepts(itemCount)
    }
}

nonisolated enum CompositionTemplateStoreError: LocalizedError, Equatable {
    case invalidName
    case invalidTemplate
    case unsupportedVersion(Int)
    case builtInMutation
    case missingTemplate

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a template name."
        case .invalidTemplate:
            return "The composition template is invalid or contains unsupported values."
        case .unsupportedVersion(let version):
            return "Composition template version \(version) is not supported."
        case .builtInMutation:
            return "Built-in composition templates cannot be changed."
        case .missingTemplate:
            return "The selected composition template is unavailable."
        }
    }
}

nonisolated enum CompositionTemplateStore {
    private static let defaultsKey = "composition.userTemplates.v1"
    private static let exchangeIdentifier = "com.snipsnipsnip.composition-template"
    private static let maximumTemplateCount = 256
    private static let maximumItemsPerTemplate = 10_000
    private static let maximumNameLength = 120

    private struct ExchangeFile: Codable {
        var format: String
        var version: Int
        var templates: [CompositionTemplate]
    }

    static let builtInTemplates: [CompositionTemplate] = {
        let twoItems = [
            CompositionItem(assetID: UUID()),
            CompositionItem(assetID: UUID()),
        ]
        let baseComparison = CompositionTemplateComparisonSettings(
            CompositionComparisonSettings(),
            items: twoItems
        )

        return [
            CompositionTemplate(
                id: "builtin.clean-grid",
                name: "Clean Grid",
                source: .builtIn,
                itemCount: .flexible(minimum: 1, maximum: nil),
                layout: CompositionLayoutConfiguration(
                    mode: .grid,
                    sizingMode: .equal,
                    orientation: .automatic
                ),
                appearance: CompositionAppearanceTheme.clean.appearance,
                comparison: baseComparison,
                steps: CompositionStepsSettings(),
                itemSettings: []
            ),
            CompositionTemplate(
                id: "builtin.side-by-side",
                name: "Side by Side",
                source: .builtIn,
                itemCount: .flexible(minimum: 2, maximum: nil),
                layout: CompositionLayoutConfiguration(
                    mode: .compare,
                    sizingMode: .equal,
                    orientation: .landscape
                ),
                appearance: CompositionAppearanceTheme.cards.appearance,
                comparison: CompositionTemplateComparisonSettings(
                    CompositionComparisonSettings(mode: .sideBySide),
                    items: twoItems
                ),
                steps: CompositionStepsSettings(),
                itemSettings: []
            ),
            CompositionTemplate(
                id: "builtin.numbered-steps",
                name: "Numbered Steps",
                source: .builtIn,
                itemCount: .flexible(minimum: 1, maximum: nil),
                layout: CompositionLayoutConfiguration(
                    mode: .steps,
                    sizingMode: .equal,
                    orientation: .portrait
                ),
                appearance: CompositionAppearanceTheme.documentation.appearance,
                comparison: baseComparison,
                steps: CompositionStepsSettings(
                    flow: .column,
                    numberingStyle: .decimal,
                    connectorStyle: .arrow
                ),
                itemSettings: []
            ),
            CompositionTemplate(
                id: "builtin.freeform-board",
                name: "Freeform Board",
                source: .builtIn,
                itemCount: .flexible(minimum: 1, maximum: nil),
                layout: CompositionLayoutConfiguration(
                    mode: .freeform,
                    freeformCanvasSize: CGSize(width: 1_200, height: 800),
                    sizingMode: .weighted,
                    orientation: .landscape
                ),
                appearance: CompositionAppearanceTheme.dark.appearance,
                comparison: baseComparison,
                steps: CompositionStepsSettings(),
                itemSettings: []
            ),
        ]
    }()

    static func allTemplates(in defaults: UserDefaults) -> [CompositionTemplate] {
        builtInTemplates + loadUserTemplates(from: defaults)
    }

    static func upsert(_ template: CompositionTemplate, in defaults: UserDefaults) throws {
        guard template.source == .user else {
            throw CompositionTemplateStoreError.builtInMutation
        }
        try validate(template)
        var templates = loadUserTemplates(from: defaults)
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            guard templates.count < maximumTemplateCount else {
                throw CompositionTemplateStoreError.invalidTemplate
            }
            templates.append(template)
        }
        try saveUserTemplates(templates, to: defaults)
    }

    static func delete(id: String, in defaults: UserDefaults) throws {
        guard !builtInTemplates.contains(where: { $0.id == id }) else {
            throw CompositionTemplateStoreError.builtInMutation
        }
        var templates = loadUserTemplates(from: defaults)
        guard templates.contains(where: { $0.id == id }) else {
            throw CompositionTemplateStoreError.missingTemplate
        }
        templates.removeAll { $0.id == id }
        try saveUserTemplates(templates, to: defaults)
    }

    static func exportData(for template: CompositionTemplate) throws -> Data {
        try validate(template)
        return try JSONEncoder.compositionTemplateEncoder.encode(
            ExchangeFile(
                format: exchangeIdentifier,
                version: CompositionTemplate.formatVersion,
                templates: [template]
            )
        )
    }

    static func importedTemplates(
        from data: Data,
        exactItemCount: Int
    ) throws -> [CompositionTemplate] {
        let exchange = try JSONDecoder.compositionTemplateDecoder.decode(
            ExchangeFile.self,
            from: data
        )
        guard exchange.format == exchangeIdentifier else {
            throw CompositionTemplateStoreError.invalidTemplate
        }
        guard exchange.version == CompositionTemplate.formatVersion else {
            throw CompositionTemplateStoreError.unsupportedVersion(exchange.version)
        }
        guard !exchange.templates.isEmpty,
              exchange.templates.count <= maximumTemplateCount,
              exactItemCount > 0,
              exactItemCount <= maximumItemsPerTemplate else {
            throw CompositionTemplateStoreError.invalidTemplate
        }

        return try exchange.templates.map { imported in
            var user = imported
            user.id = "user.\(UUID().uuidString)"
            user.source = .user
            user.itemCount = .exact(exactItemCount)
            user.itemSettings = Array(user.itemSettings.prefix(exactItemCount))
            try validate(user)
            return user
        }
    }

    static func normalizedName(_ name: String) throws -> String {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maximumNameLength)
        guard !normalized.isEmpty else {
            throw CompositionTemplateStoreError.invalidName
        }
        return String(normalized)
    }

    static func validate(_ template: CompositionTemplate) throws {
        guard template.formatVersion == CompositionTemplate.formatVersion else {
            throw CompositionTemplateStoreError.unsupportedVersion(template.formatVersion)
        }
        _ = try normalizedName(template.name)

        let compatibleCount: Int
        switch template.itemCount {
        case .exact(let count):
            compatibleCount = count
        case .flexible(let minimum, let maximum):
            guard minimum > 0,
                  maximum.map({ $0 >= minimum && $0 <= maximumItemsPerTemplate }) ?? true else {
                throw CompositionTemplateStoreError.invalidTemplate
            }
            compatibleCount = minimum
        }
        guard compatibleCount > 0,
              compatibleCount <= maximumItemsPerTemplate,
              template.itemSettings.count <= maximumItemsPerTemplate,
              template.layout.targetAspectRatio.isFinite,
              template.layout.targetAspectRatio > 0,
              template.itemSettings.allSatisfy(\.isValid) else {
            throw CompositionTemplateStoreError.invalidTemplate
        }
    }

    private static func loadUserTemplates(from defaults: UserDefaults) -> [CompositionTemplate] {
        guard let data = defaults.data(forKey: defaultsKey),
              let templates = try? JSONDecoder.compositionTemplateDecoder.decode(
                [CompositionTemplate].self,
                from: data
              ) else {
            return []
        }
        return Array(
            templates
                .filter { $0.source == .user && (try? validate($0)) != nil }
                .prefix(maximumTemplateCount)
        )
    }

    private static func saveUserTemplates(
        _ templates: [CompositionTemplate],
        to defaults: UserDefaults
    ) throws {
        let data = try JSONEncoder.compositionTemplateEncoder.encode(templates)
        defaults.set(data, forKey: defaultsKey)
    }
}

private nonisolated extension CompositionTemplateItemSettings {
    var isValid: Bool {
        weight.isFinite
            && weight > 0
            && opacity.isFinite
            && (0...1).contains(opacity)
            && framing.scale.isFinite
            && framing.scale > 0
            && framing.offset.width.isFinite
            && framing.offset.height.isFinite
            && normalizedFreeformFrame.map { frame in
                frame.origin.x.isFinite
                    && frame.origin.y.isFinite
                    && frame.width.isFinite
                    && frame.height.isFinite
                    && frame.width > 0
                    && frame.height > 0
            } ?? true
    }
}

private nonisolated extension JSONEncoder {
    static var compositionTemplateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private nonisolated extension JSONDecoder {
    static var compositionTemplateDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
