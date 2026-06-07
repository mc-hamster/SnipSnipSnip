import CoreGraphics
import Foundation
import XCTest
@testable import SnipSnipSnip

nonisolated struct PixelSample: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}

private enum TestLifetimeRetainer {
    static let lock = NSLock()
    nonisolated(unsafe) static var objects: [AnyObject] = []
}

enum CoordinateImagePattern {
    case cartesian
    case weighted(xMultiplier: Int, yMultiplier: Int, includeBlueSum: Bool)
}

func makeCoordinateImage(width: Int, height: Int, pattern: CoordinateImagePattern = .cartesian) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)

            switch pattern {
            case .cartesian:
                pixels[offset] = UInt8(truncatingIfNeeded: x)
                pixels[offset + 1] = UInt8(truncatingIfNeeded: y)
                pixels[offset + 2] = 0
            case let .weighted(xMultiplier, yMultiplier, includeBlueSum):
                pixels[offset] = UInt8((x * xMultiplier) % 255)
                pixels[offset + 1] = UInt8((y * yMultiplier) % 255)
                pixels[offset + 2] = includeBlueSum ? UInt8((x + y) % 255) : 0
            }

            pixels[offset + 3] = 255
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func makeSolidImage(width: Int, height: Int, color: PixelSample) -> CGImage {
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            pixels[offset] = color.red
            pixels[offset + 1] = color.green
            pixels[offset + 2] = color.blue
            pixels[offset + 3] = color.alpha
        }
    }

    let provider = CGDataProvider(data: Data(pixels) as CFData)

    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

func samplePixel(
    in image: CGImage,
    topLeftX: Int,
    topLeftY: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) -> PixelSample {
    guard let data = image.dataProvider?.data else {
        XCTFail("Missing pixel data", file: file, line: line)
        return PixelSample(red: 0, green: 0, blue: 0, alpha: 0)
    }

    let bytes = CFDataGetBytePtr(data)!
    let bytesPerPixel = image.bitsPerPixel / 8
    let bytesPerRow = image.bytesPerRow
    let x = max(0, min(topLeftX, image.width - 1))
    let y = max(0, min(topLeftY, image.height - 1))
    let offset = (y * bytesPerRow) + (x * bytesPerPixel)

    return PixelSample(
        red: bytes[offset],
        green: bytes[offset + 1],
        blue: bytes[offset + 2],
        alpha: bytes[offset + 3]
    )
}

func pixelSample(for color: RGBAColor) -> PixelSample {
    PixelSample(
        red: UInt8((color.red * 255).rounded()),
        green: UInt8((color.green * 255).rounded()),
        blue: UInt8((color.blue * 255).rounded()),
        alpha: UInt8((color.alpha * 255).rounded())
    )
}

@discardableResult
func retainForTestLifetime<T: AnyObject>(_ object: T) -> T {
    TestLifetimeRetainer.lock.lock()
    defer { TestLifetimeRetainer.lock.unlock() }
    TestLifetimeRetainer.objects.append(object)
    return object
}

func makeDefaultToolStyles() -> [EditorTool: AnnotationStyle] {
    Dictionary(uniqueKeysWithValues: EditorTool.allCases.map { ($0, AnnotationStyle.default(for: $0)) })
}

func makeEditorSnapshot(
    cropRect: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
    annotations: [Annotation] = [],
    selectedAnnotationIDs: [UUID] = [],
    nextCalloutNumber: Int = 1,
    presentation: ScreenshotPresentation = .plain
) -> EditorSnapshot {
    EditorSnapshot(
        cropRect: cropRect,
        annotations: annotations,
        selectedAnnotationIDs: selectedAnnotationIDs,
        nextCalloutNumber: nextCalloutNumber,
        presentation: presentation
    )
}

func makeEditorDocumentSession(
    initialSnapshot: EditorSnapshot? = nil,
    currentSnapshot: EditorSnapshot? = nil,
    undoStack: [EditorSnapshot] = [],
    redoStack: [EditorSnapshot] = [],
    toolStyles: [EditorTool: AnnotationStyle] = makeDefaultToolStyles()
) -> EditorDocumentSession {
    let initial = initialSnapshot ?? makeEditorSnapshot()
    let current = currentSnapshot ?? initial

    return EditorDocumentSession(
        initialSnapshot: initial,
        currentSnapshot: current,
        undoStack: undoStack,
        redoStack: redoStack,
        toolStyles: toolStyles
    )
}

func makeCapturedScreenshot(
    image: CGImage? = nil,
    kind: CaptureKind = .region,
    sourceName: String = "Display",
    sourceRect: CGRect? = nil,
    bounds: CGRect? = nil,
    coordinateContract: DocumentCoordinateContract = .current,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    uiMap: UIMapSnapshot? = nil
) -> CapturedScreenshot {
    let resolvedImage = image ?? makeCoordinateImage(width: 64, height: 48)

    return CapturedScreenshot(
        image: resolvedImage,
        kind: kind,
        sourceName: sourceName,
        sourceRect: sourceRect ?? bounds ?? CGRect(origin: .zero, size: CGSize(width: resolvedImage.width, height: resolvedImage.height)),
        coordinateContract: coordinateContract,
        capturedAt: capturedAt,
        uiMap: uiMap
    )
}

func makeEditableDocument(
    capture: CapturedScreenshot? = nil,
    session: EditorDocumentSession? = nil
) -> EditableScreenshotDocument {
    let resolvedCapture = capture ?? makeCapturedScreenshot()
    let resolvedSession = session ?? makeEditorDocumentSession(
        initialSnapshot: makeEditorSnapshot(
            cropRect: CGRect(origin: .zero, size: CGSize(width: resolvedCapture.image.width, height: resolvedCapture.image.height))
        )
    )

    return EditableScreenshotDocument(capture: resolvedCapture, session: resolvedSession)
}

func makeCaptureWindow(
    id: CGWindowID = 0,
    ownerPID: pid_t = 0,
    ownerName: String = "App",
    title: String = "Window",
    focusRank: Int = 0,
    frame: CGRect = CGRect(x: 20, y: 20, width: 240, height: 180),
    thumbnail: CGImage? = nil,
    thumbnailSize: CGSize? = nil,
    thumbnailColor: PixelSample = PixelSample(red: 20, green: 40, blue: 60, alpha: 255)
) -> CaptureWindowSummary {
    let resolvedThumbnail = thumbnail ?? thumbnailSize.map {
        makeSolidImage(
            width: Int($0.width),
            height: Int($0.height),
            color: thumbnailColor
        )
    }

    return CaptureWindowSummary(
        id: id,
        ownerName: ownerName,
        ownerPID: ownerPID,
        title: title,
        frame: frame,
        layer: 0,
        focusRank: focusRank,
        thumbnail: resolvedThumbnail
    )
}
