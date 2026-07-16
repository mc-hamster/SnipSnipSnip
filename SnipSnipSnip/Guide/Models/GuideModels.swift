import CoreGraphics
import Foundation

nonisolated enum GuideCaptureSource: Codable, Equatable, Sendable {
    case window(id: CGWindowID, ownerPID: pid_t, name: String, frame: CGRect)
    case app(processID: pid_t, bundleIdentifier: String?, name: String, initialFrame: CGRect)
    case region(CGRect)
    case displays(GuideDisplaySelection)
}

nonisolated enum GuideDisplaySelection: Codable, Equatable, Sendable {
    case current
    case selected([CGDirectDisplayID])
    case all
}

nonisolated enum GuideEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case click
    case doubleClick
    case selection
    case textEntry
    case scroll
    case gesture
    case shortcut
    case manual

    var id: String { rawValue }
}

nonisolated enum GuideExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf
    case docx
    case gif
    case apng
    case fullMotionMP4
    case highlightMP4
    case slideshowMP4
    case stepImages
    case zip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word Document (.docx)"
        case .gif: "GIF"
        case .apng: "APNG"
        case .fullMotionMP4: "Full Motion MP4"
        case .highlightMP4: "Action Highlights MP4"
        case .slideshowMP4: "Step Slideshow MP4"
        case .stepImages: "Step Images"
        case .zip: "ZIP"
        }
    }
}

nonisolated enum GuideAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark
    var id: String { rawValue }
}

nonisolated enum GuidePDFPaper: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case letter
    case a4
    var id: String { rawValue }
}

nonisolated enum GuidePDFOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape
    var id: String { rawValue }
}

nonisolated enum GuideStepImageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    var id: String { rawValue }
}

nonisolated enum GuideRedactionKind: String, Codable, Sendable {
    case blur
    case pixelate
    case solid
}

nonisolated struct GuideRedaction: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: GuideRedactionKind
    var rect: CGRect
}

nonisolated struct GuideMarker: Codable, Equatable, Sendable {
    var target: CGPoint
    var tail: CGPoint
    var colorHex: String?
    var lineWidth: Double?
    var length: Double?
    var isHidden = false
}

nonisolated struct GuideTargetMetadata: Codable, Equatable, Sendable {
    var role: String?
    var title: String?
    var label: String?
    var elementDescription: String?
    var safeValue: String?
    var identifier: String?
    var actions: [String]
    var frame: CGRect?
    var processID: pid_t?
    var windowID: CGWindowID?
    var isSecure = false

    init(
        role: String? = nil,
        title: String? = nil,
        label: String? = nil,
        elementDescription: String? = nil,
        safeValue: String? = nil,
        identifier: String? = nil,
        actions: [String] = [],
        frame: CGRect? = nil,
        processID: pid_t? = nil,
        windowID: CGWindowID? = nil,
        isSecure: Bool = false
    ) {
        self.role = role
        self.title = title
        self.label = label
        self.elementDescription = elementDescription
        self.safeValue = isSecure ? nil : safeValue
        self.identifier = identifier
        self.actions = actions
        self.frame = frame
        self.processID = processID
        self.windowID = windowID
        self.isSecure = isSecure
    }
}

nonisolated struct GuideStepSession: Codable, Equatable, Sendable {
    var cropRect: CGRect?
    var marker: GuideMarker?
    var redactions: [GuideRedaction] = []
    var annotationSessionAsset: String?
    var sourceCoordinateRect: CGRect
    var sourcePixelSize: CGSize
    var styleOverrides: GuideStepStyleOverrides?
    var showsCursor = false
}

nonisolated struct GuideStepStyleOverrides: Codable, Equatable, Sendable {
    var accentColorHex: String?
    var backgroundColorHex: String?
    var markerColorHex: String?
}

nonisolated struct GuideStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sequence: Int
    var eventKind: GuideEventKind
    var capturedAt: Date
    var sourceTimestampSeconds: Double?
    var caption: String
    var deterministicCaption: String
    var note: String
    var isIncluded: Bool
    var isDeleted: Bool
    var duration: Double
    var keyboardShortcut: String?
    var scrollDistance: Double?
    var targetMetadata: GuideTargetMetadata?
    var baseImageAsset: String
    var session: GuideStepSession
    var captionRevision: Int
    var userEditedCaption: Bool

    init(
        id: UUID = UUID(),
        sequence: Int,
        eventKind: GuideEventKind,
        capturedAt: Date = Date(),
        sourceTimestampSeconds: Double? = nil,
        caption: String,
        note: String = "",
        isIncluded: Bool = true,
        duration: Double = 2,
        keyboardShortcut: String? = nil,
        scrollDistance: Double? = nil,
        targetMetadata: GuideTargetMetadata? = nil,
        baseImageAsset: String = "base.png",
        session: GuideStepSession
    ) {
        self.id = id
        self.sequence = sequence
        self.eventKind = eventKind
        self.capturedAt = capturedAt
        self.sourceTimestampSeconds = sourceTimestampSeconds
        self.caption = caption
        self.deterministicCaption = caption
        self.note = note
        self.isIncluded = isIncluded
        self.isDeleted = false
        self.duration = min(max(duration, 0.5), 5)
        self.keyboardShortcut = keyboardShortcut
        self.scrollDistance = scrollDistance
        self.targetMetadata = targetMetadata
        self.baseImageAsset = baseImageAsset
        self.session = session
        self.captionRevision = 0
        self.userEditedCaption = false
    }
}

nonisolated struct GuideTheme: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name = "Standard"
    var appearance: GuideAppearance = .system
    var accentColorHex = "#E53935"
    var backgroundColorHex = "#F5F5F7"
    var markerColorHex = "#E53935"
    var markerLineWidth = 3.0
    var markerLength = 80.0
    var markerHeadStyle = "triangle"
    var markerNumberStyle = "circle"
    var showsClickHighlight = true
    var organizationName = ""
    var footer = ""
    var screenshotCornerRadius = 12.0
    var pageMargin = 72.0
    var showsScreenshotShadow = true
    var logoAsset: String?
}

nonisolated struct GuideExportSettings: Codable, Equatable, Sendable {
    var formats: Set<GuideExportFormat> = [.pdf, .gif]
    var stepDuration = 2.0
    var usesCrossfade = true
    var crossfadeDuration = 0.2
    var includesCoverWhenTitled = true
    var usesCompactPDFLayout = false
    var pdfDPI = 216
    var pdfPaper = GuidePDFPaper.automatic
    var pdfOrientation = GuidePDFOrientation.portrait
    var stepImageFormat = GuideStepImageFormat.png
    var includesSourceMediaInZIP = false
    var filenameTemplate = "SnipSnipSnip-Guide-{title}-{yyyy-MM-dd-HH-mm-ss}"
}

nonisolated struct GuideTimelineSegment: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var asset: String
    var startedAt: Date
    var duration: Double
}

nonisolated struct GuideTimeline: Codable, Equatable, Sendable {
    var segments: [GuideTimelineSegment] = []
    var sourceVideoEnabled = true
    var cursorSamples: [GuideCursorSample] = []
}

nonisolated struct GuideCursorSample: Codable, Equatable, Sendable {
    var timestampSeconds: Double
    var point: CGPoint
}

nonisolated struct GuideProject: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title = ""
    var createdAt = Date()
    var modifiedAt = Date()
    var source: GuideCaptureSource
    var isPrivate = false
    var steps: [GuideStep] = []
    var theme = GuideTheme()
    var exportSettings = GuideExportSettings()
    var timeline = GuideTimeline()

    mutating func normalizeStepSequence() {
        for index in steps.indices {
            steps[index].sequence = index + 1
        }
        modifiedAt = Date()
    }
}
