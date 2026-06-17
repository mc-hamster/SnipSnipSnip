import CoreGraphics
import Foundation

nonisolated enum PresentationSceneSlotType: String, Codable, Sendable {
    case image
    case text
}

nonisolated struct PresentationSceneSlot: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var type: PresentationSceneSlotType
    var required: Bool
    var label: String
    var defaultValue: String?
    var defaultFraming: PresentationSceneFramingPreset
    var allowUserOverride: Bool
    var minScale: CGFloat?
    var maxScale: CGFloat?
    var maxAutoEnlargement: CGFloat?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case required
        case label
        case defaultValue
        case defaultFraming
        case allowUserOverride
        case minScale
        case maxScale
        case maxAutoEnlargement
    }

    nonisolated init(
        id: String,
        type: PresentationSceneSlotType,
        required: Bool = false,
        label: String,
        defaultValue: String? = nil,
        defaultFraming: PresentationSceneFramingPreset = .auto,
        allowUserOverride: Bool = true,
        minScale: CGFloat? = nil,
        maxScale: CGFloat? = nil,
        maxAutoEnlargement: CGFloat? = nil
    ) {
        self.id = id
        self.type = type
        self.required = required
        self.label = label
        self.defaultValue = defaultValue
        self.defaultFraming = defaultFraming
        self.allowUserOverride = allowUserOverride
        self.minScale = minScale
        self.maxScale = maxScale
        self.maxAutoEnlargement = maxAutoEnlargement
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(PresentationSceneSlotType.self, forKey: .type)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? id
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        defaultFraming = try container.decodeIfPresent(PresentationSceneFramingPreset.self, forKey: .defaultFraming) ?? .auto
        allowUserOverride = try container.decodeIfPresent(Bool.self, forKey: .allowUserOverride) ?? true
        minScale = try container.decodeIfPresent(CGFloat.self, forKey: .minScale)
        maxScale = try container.decodeIfPresent(CGFloat.self, forKey: .maxScale)
        maxAutoEnlargement = try container.decodeIfPresent(CGFloat.self, forKey: .maxAutoEnlargement)
    }
}

nonisolated struct PresentationSceneCanvas: Equatable, Codable, Sendable {
    var width: Int
    var height: Int

    var size: CGSize {
        CGSize(width: max(width, 1), height: max(height, 1))
    }
}

nonisolated struct PresentationSceneMetadata: Equatable, Codable, Sendable {
    static let schema = "com.oontz.snipsnipsnip.presentation-scene"
    static let supportedSchemaVersion = 1

    var schema: String
    var schemaVersion: Int
    var id: String
    var name: String
    var version: Int
    var author: String?
    var description: String?
    var canvas: PresentationSceneCanvas
    var slots: [PresentationSceneSlot]

    var primaryScreenshotSlot: PresentationSceneSlot? {
        slots.first { $0.id == PresentationSceneStore.primaryScreenshotSlotID && $0.type == .image }
    }

    var textSlots: [PresentationSceneSlot] {
        slots.filter { $0.type == .text }
    }
}

nonisolated enum PresentationSceneSource: String, CaseIterable, Codable, Sendable {
    case bundled
    case user

    var label: String {
        switch self {
        case .bundled:
            return "Bundled"
        case .user:
            return "User"
        }
    }
}

nonisolated struct PresentationSceneDefinition: Identifiable, Equatable, Sendable {
    var id: String { metadata.id }
    var metadata: PresentationSceneMetadata
    var sanitizedSVGText: String
    var source: PresentationSceneSource
    var fileURL: URL
    var isUserModifiedBundled: Bool

    var name: String { metadata.name }
    var version: Int { metadata.version }
    var textSlots: [PresentationSceneSlot] { metadata.textSlots }
}

nonisolated enum PresentationSceneDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

nonisolated struct PresentationSceneDiagnostic: Identifiable, Equatable, Sendable {
    var id: String
    var severity: PresentationSceneDiagnosticSeverity
    var message: String
    var filePath: String?
    var sceneID: String?

    nonisolated init(
        severity: PresentationSceneDiagnosticSeverity,
        message: String,
        fileURL: URL? = nil,
        sceneID: String? = nil
    ) {
        self.severity = severity
        self.message = message
        self.filePath = fileURL?.path
        self.sceneID = sceneID
        id = [
            severity.rawValue,
            sceneID ?? "",
            fileURL?.path ?? "",
            message,
        ].joined(separator: "|")
    }
}

nonisolated enum PresentationSceneScreenshotFit: String, CaseIterable, Codable, Sendable {
    case contain
    case cover
    case actualSize

    var label: String {
        switch self {
        case .contain:
            return "Contain"
        case .cover:
            return "Fill"
        case .actualSize:
            return "Actual Size"
        }
    }

    var svgPreserveAspectRatioKeyword: String {
        switch self {
        case .contain:
            return "xMidYMid meet"
        case .cover:
            return "xMidYMid slice"
        case .actualSize:
            return "none"
        }
    }
}

nonisolated enum PresentationSceneFramingPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case showFull
    case fillFrame
    case focusTop
    case focusBottom
    case focusLeft
    case focusRight
    case actualSize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:
            return "Auto"
        case .showFull:
            return "Show Full"
        case .fillFrame:
            return "Fill"
        case .focusTop:
            return "Top"
        case .focusBottom:
            return "Bottom"
        case .focusLeft:
            return "Left"
        case .focusRight:
            return "Right"
        case .actualSize:
            return "Actual Size"
        }
    }

    var defaultFit: PresentationSceneScreenshotFit {
        switch self {
        case .auto, .showFull:
            return .contain
        case .fillFrame, .focusTop, .focusBottom, .focusLeft, .focusRight:
            return .cover
        case .actualSize:
            return .actualSize
        }
    }

    var defaultAlignment: PresentationSubjectAlignment {
        switch self {
        case .auto, .showFull, .fillFrame, .actualSize:
            return .center
        case .focusTop:
            return .top
        case .focusBottom:
            return .bottom
        case .focusLeft:
            return .left
        case .focusRight:
            return .right
        }
    }
}

nonisolated struct PresentationSceneScreenshotSlotSettings: Equatable, Codable, Sendable {
    var framingPreset: PresentationSceneFramingPreset
    var fit: PresentationSceneScreenshotFit
    var alignment: PresentationSubjectAlignment
    var scale: CGFloat
    var offset: CGSize
    var hasManualAdjustment: Bool

    private enum CodingKeys: String, CodingKey {
        case framingPreset
        case fit
        case alignment
        case scale
        case offset
        case hasManualAdjustment
    }

    nonisolated init(
        framingPreset: PresentationSceneFramingPreset = .auto,
        fit: PresentationSceneScreenshotFit? = nil,
        alignment: PresentationSubjectAlignment? = nil,
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        hasManualAdjustment: Bool = false
    ) {
        self.framingPreset = framingPreset
        self.fit = fit ?? framingPreset.defaultFit
        self.alignment = alignment ?? framingPreset.defaultAlignment
        self.scale = max(scale, 0.05)
        self.offset = offset
        self.hasManualAdjustment = hasManualAdjustment
    }

    nonisolated init(fit: PresentationSceneScreenshotFit) {
        let preset: PresentationSceneFramingPreset = fit == .contain ? .showFull : (fit == .actualSize ? .actualSize : .fillFrame)
        self.init(framingPreset: preset, fit: fit)
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFit = try container.decodeIfPresent(PresentationSceneScreenshotFit.self, forKey: .fit)
        let decodedPreset = try container.decodeIfPresent(PresentationSceneFramingPreset.self, forKey: .framingPreset)
            ?? decodedFit.map { fit -> PresentationSceneFramingPreset in
                switch fit {
                case .contain:
                    return .showFull
                case .cover:
                    return .fillFrame
                case .actualSize:
                    return .actualSize
                }
            }
            ?? .auto

        framingPreset = decodedPreset
        fit = decodedFit ?? decodedPreset.defaultFit
        alignment = try container.decodeIfPresent(PresentationSubjectAlignment.self, forKey: .alignment) ?? decodedPreset.defaultAlignment
        scale = max(try container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1, 0.05)
        offset = try container.decodeIfPresent(CGSize.self, forKey: .offset) ?? .zero
        hasManualAdjustment = try container.decodeIfPresent(Bool.self, forKey: .hasManualAdjustment) ?? false
    }

    nonisolated mutating func applyPreset(_ preset: PresentationSceneFramingPreset) {
        framingPreset = preset
        fit = preset.defaultFit
        alignment = preset.defaultAlignment
        scale = 1
        offset = .zero
        hasManualAdjustment = false
    }

    nonisolated mutating func applyManualAdjustment(
        fit: PresentationSceneScreenshotFit? = nil,
        alignment: PresentationSubjectAlignment? = nil,
        scale: CGFloat? = nil,
        offset: CGSize? = nil
    ) {
        if let fit {
            self.fit = fit
        }
        if let alignment {
            self.alignment = alignment
        }
        if let scale {
            self.scale = max(scale, 0.05)
        }
        if let offset {
            self.offset = offset
        }
        hasManualAdjustment = true
    }

    nonisolated static let `default` = PresentationSceneScreenshotSlotSettings()
}

nonisolated struct PresentationSceneFramingAnalysis: Equatable, Sendable {
    var slotRect: CGRect
    var contentRect: CGRect
    var fit: PresentationSceneScreenshotFit
    var alignment: PresentationSubjectAlignment
    var cropPercentage: CGFloat
    var enlargement: CGFloat
    var hasLetterbox: Bool
    var hasManualAdjustment: Bool

    var warningMessages: [String] {
        var messages: [String] = []
        if cropPercentage >= 0.05 {
            messages.append("Fill crops about \(Int((cropPercentage * 100).rounded()))% of the screenshot.")
        }
        if enlargement > 1.5 {
            messages.append("This framing enlarges the screenshot above \(Int((enlargement * 100).rounded()))%.")
        }
        if fit == .actualSize && hasLetterbox {
            messages.append("Actual Size leaves empty space around the screenshot.")
        }
        return messages
    }
}

extension PresentationSceneSlot {
    nonisolated var effectiveMinScale: CGFloat {
        max(minScale ?? 0.25, 0.05)
    }

    nonisolated var effectiveMaxScale: CGFloat {
        max(maxScale ?? 3, effectiveMinScale)
    }

    nonisolated var effectiveMaxAutoEnlargement: CGFloat {
        max(maxAutoEnlargement ?? 1.5, 0.1)
    }
}

nonisolated struct AppliedPresentationScene: Equatable, Codable, Sendable {
    var sceneID: String
    var name: String
    var version: Int
    var sanitizedSVGText: String
    var textSlotValues: [String: String]
    var screenshotSlotSettings: PresentationSceneScreenshotSlotSettings

    nonisolated init(
        sceneID: String,
        name: String,
        version: Int,
        sanitizedSVGText: String,
        textSlotValues: [String: String],
        screenshotSlotSettings: PresentationSceneScreenshotSlotSettings = .default
    ) {
        self.sceneID = sceneID
        self.name = name
        self.version = version
        self.sanitizedSVGText = sanitizedSVGText
        self.textSlotValues = textSlotValues
        self.screenshotSlotSettings = screenshotSlotSettings
    }

    nonisolated init(definition: PresentationSceneDefinition) {
        let defaultFraming = definition.metadata.primaryScreenshotSlot?.defaultFraming ?? .auto
        self.init(
            sceneID: definition.metadata.id,
            name: definition.metadata.name,
            version: definition.metadata.version,
            sanitizedSVGText: definition.sanitizedSVGText,
            textSlotValues: Dictionary(uniqueKeysWithValues: definition.metadata.textSlots.map { slot in
                (slot.id, slot.defaultValue ?? "")
            }),
            screenshotSlotSettings: PresentationSceneScreenshotSlotSettings(framingPreset: defaultFraming)
        )
    }
}

nonisolated struct PresentationSceneStoreResult: Equatable, Sendable {
    var rootURL: URL
    var scenes: [PresentationSceneDefinition]
    var diagnostics: [PresentationSceneDiagnostic]
}
