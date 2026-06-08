import CoreGraphics
import Foundation

nonisolated struct UIMapExportDocument: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var capturedAt: Date
    var sourceName: String
    var captureKind: String
    var sourceRect: UIMapExportRect
    var sourceWindowIdentity: UIMapExportSourceWindowIdentity?
    var documentRect: UIMapExportRect
    var pixelSize: UIMapExportSize
    var elementCount: Int
    var selectedElementID: UUID?
    var elements: [UIMapExportElement]
    var flattenedElements: [UIMapExportElementSummary]

    init(
        exportedAt: Date = Date(),
        capture: CapturedScreenshot,
        uiMap: UIMapSnapshot,
        selectedElementID: UUID?
    ) {
        schemaVersion = 1
        self.exportedAt = exportedAt
        capturedAt = uiMap.capturedAt
        sourceName = capture.sourceName
        captureKind = capture.kind.rawValue
        sourceRect = UIMapExportRect(capture.sourceRect)
        sourceWindowIdentity = capture.sourceWindowIdentity.map(UIMapExportSourceWindowIdentity.init)
        documentRect = UIMapExportRect(capture.documentRect)
        pixelSize = UIMapExportSize(capture.pixelSize)
        elementCount = uiMap.elementCount
        self.selectedElementID = selectedElementID
        elements = uiMap.elements.map {
            UIMapExportElement(element: $0, depth: 0, parentIDs: [])
        }
        flattenedElements = uiMap.elements.flatMap {
            UIMapExportElementSummary.flattened(from: $0, depth: 0, parentIDs: [])
        }
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

nonisolated struct UIMapExportSourceWindowIdentity: Codable, Equatable, Sendable {
    var windowID: UInt32
    var ownerName: String
    var ownerPID: Int32
    var bundleIdentifier: String?
    var title: String
    var frame: UIMapExportRect

    init(_ identity: CaptureSourceWindowIdentity) {
        windowID = identity.windowID
        ownerName = identity.ownerName
        ownerPID = identity.ownerPID
        bundleIdentifier = identity.bundleIdentifier
        title = identity.title
        frame = UIMapExportRect(identity.frame)
    }
}

nonisolated struct UIMapExportElement: Codable, Equatable, Sendable {
    var id: UUID
    var name: String?
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    var role: String?
    var roleDescription: String?
    var valueDescription: String?
    var documentRect: UIMapExportRect
    var owningApplication: String?
    var bundleIdentifier: String?
    var depth: Int
    var parentIDs: [UUID]
    var displayName: String
    var typeLabel: String
    var showAllOverlayCandidate: Bool
    var children: [UIMapExportElement]

    init(element: UIMapElement, depth: Int, parentIDs: [UUID]) {
        id = element.id
        name = element.name
        accessibilityLabel = element.accessibilityLabel
        accessibilityIdentifier = element.accessibilityIdentifier
        role = element.role
        roleDescription = element.roleDescription
        valueDescription = element.valueDescription
        documentRect = UIMapExportRect(element.documentRect)
        owningApplication = element.owningApplication
        bundleIdentifier = element.bundleIdentifier
        self.depth = depth
        self.parentIDs = parentIDs
        displayName = element.displayName
        typeLabel = element.typeLabel
        showAllOverlayCandidate = element.isShowAllOverlayCandidate
        children = element.children.map {
            UIMapExportElement(element: $0, depth: depth + 1, parentIDs: parentIDs + [element.id])
        }
    }
}

nonisolated struct UIMapExportElementSummary: Codable, Equatable, Sendable {
    var id: UUID
    var parentIDs: [UUID]
    var depth: Int
    var displayName: String
    var typeLabel: String
    var role: String?
    var roleDescription: String?
    var documentRect: UIMapExportRect
    var showAllOverlayCandidate: Bool
    var owningApplication: String?
    var bundleIdentifier: String?

    static func flattened(from element: UIMapElement, depth: Int, parentIDs: [UUID]) -> [UIMapExportElementSummary] {
        let summary = UIMapExportElementSummary(
            id: element.id,
            parentIDs: parentIDs,
            depth: depth,
            displayName: element.displayName,
            typeLabel: element.typeLabel,
            role: element.role,
            roleDescription: element.roleDescription,
            documentRect: UIMapExportRect(element.documentRect),
            showAllOverlayCandidate: element.isShowAllOverlayCandidate,
            owningApplication: element.owningApplication,
            bundleIdentifier: element.bundleIdentifier
        )
        return [summary] + element.children.flatMap {
            flattened(from: $0, depth: depth + 1, parentIDs: parentIDs + [element.id])
        }
    }
}

nonisolated struct UIMapExportRect: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var minX: CGFloat
    var minY: CGFloat
    var maxX: CGFloat
    var maxY: CGFloat
    var midX: CGFloat
    var midY: CGFloat

    init(_ rect: CGRect) {
        let normalized = rect.gscIntegralStandardized
        x = normalized.origin.x
        y = normalized.origin.y
        width = normalized.width
        height = normalized.height
        minX = normalized.minX
        minY = normalized.minY
        maxX = normalized.maxX
        maxY = normalized.maxY
        midX = normalized.midX
        midY = normalized.midY
    }
}

nonisolated struct UIMapExportSize: Codable, Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }
}
