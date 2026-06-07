import AppKit
import CoreGraphics
import ImageIO
import OSLog
import SwiftUI

nonisolated private final class CachedPreviewAsset: NSObject, @unchecked Sendable {
    let asset: PreviewAsset

    init(asset: PreviewAsset) {
        self.asset = asset
    }
}

nonisolated private enum PreviewAssetCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, CachedPreviewAsset> = {
        let cache = NSCache<NSString, CachedPreviewAsset>()
        cache.countLimit = 192
        return cache
    }()
}

struct DocumentPreviewThumbnailView: View {
    let packageURL: URL?
    var thumbnailSize = CGSize(width: 96, height: 64)
    var cornerRadius: CGFloat = 10
    var contentMode: ContentMode = .fill
    @State private var previewAsset: PreviewAsset?

    private var previewLoadID: String {
        [
            packageURL?.path ?? "missing",
            "\(Int(thumbnailSize.width))",
            "\(Int(thumbnailSize.height))",
            "\(Int(NSScreen.main?.backingScaleFactor ?? 2))"
        ].joined(separator: "|")
    }

    var body: some View {
        Group {
            if let previewAsset {
                PreviewImageView(asset: previewAsset, contentMode: contentMode)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: "doc.richtext")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .task(id: previewLoadID) {
            let maxPixelDimension = Int(max(thumbnailSize.width, thumbnailSize.height) * (NSScreen.main?.backingScaleFactor ?? 2))
            let asset = await PreviewAsset.load(from: packageURL, maxPixelDimension: maxPixelDimension)

            guard !Task.isCancelled else {
                return
            }

            previewAsset = asset
        }
    }
}

private struct PreviewImageView: NSViewRepresentable {
    let asset: PreviewAsset
    let contentMode: ContentMode

    func makeNSView(context: Context) -> PreviewImageHostView {
        PreviewImageHostView()
    }

    func updateNSView(_ nsView: PreviewImageHostView, context: Context) {
        nsView.configure(asset: asset, contentMode: contentMode)
    }
}

private struct PreviewAsset: @unchecked Sendable {
    let cgImage: CGImage
    let cacheKey: String
    let fileName: String
    let fileSizeBytes: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int?

    static func load(from packageURL: URL?, maxPixelDimension: Int) async -> PreviewAsset? {
        let task = Task.detached(priority: .utility) { () -> PreviewAsset? in
            guard !Task.isCancelled else {
                return nil
            }

            return loadSynchronously(from: packageURL, maxPixelDimension: maxPixelDimension)
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func loadSynchronously(from packageURL: URL?, maxPixelDimension: Int) -> PreviewAsset? {
        guard let packageURL else {
            HistoryPreviewDiagnostics.log("load skipped: missing package URL")
            return nil
        }

        let cacheKey = "\(packageURL.path)|\(maxPixelDimension)" as NSString

        if let cached = PreviewAssetCache.shared.object(forKey: cacheKey)?.asset {
            HistoryPreviewDiagnostics.log("cache hit file=\(cached.fileName) pixels=\(cached.pixelWidth)x\(cached.pixelHeight)")
            return cached
        }

        do {
            let storedPreviewURL = SSSDocumentPackage.previewAssetURL(in: packageURL)
            let storedPreviewData = storedPreviewURL.flatMap { try? Data(contentsOf: $0) }
            let storedPreviewSource = storedPreviewData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            let storedProperties = storedPreviewSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let storedPixelWidth = storedProperties?[kCGImagePropertyPixelWidth] as? Int
            let storedPixelHeight = storedProperties?[kCGImagePropertyPixelHeight] as? Int

            guard let displayPreview = try SSSDocumentPackage.loadThumbnailDisplayPreview(from: packageURL, maxPixelDimension: maxPixelDimension) else {
                HistoryPreviewDiagnostics.log("load failed: no display preview could be resolved package=\(packageURL.lastPathComponent)")
                return nil
            }
            let cgImage = displayPreview.image

            let storedFileName = storedPreviewURL?.lastPathComponent ?? "preview.png"
            let storedFileSize = storedPreviewData?.count ?? 0
            let asset = PreviewAsset(
                cgImage: cgImage,
                cacheKey: "\(packageURL.path)|\(storedFileName)|\(cgImage.width)x\(cgImage.height)",
                fileName: storedFileName,
                fileSizeBytes: storedFileSize,
                pixelWidth: cgImage.width,
                pixelHeight: cgImage.height,
                orientation: (storedProperties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue
            )
            let orientationDescription = asset.orientation.map(String.init) ?? "nil"

            HistoryPreviewDiagnostics.log(
                "load success file=\(asset.fileName) bytes=\(asset.fileSizeBytes) pixels=\(asset.pixelWidth)x\(asset.pixelHeight) orientation=\(orientationDescription) source=\(displayPreview.source) storedPixels=\(storedPixelWidth.map(String.init) ?? "nil")x\(storedPixelHeight.map(String.init) ?? "nil")"
            )
            PreviewAssetCache.shared.setObject(CachedPreviewAsset(asset: asset), forKey: cacheKey)
            return asset
        } catch {
            HistoryPreviewDiagnostics.log("load failed: \(error.localizedDescription) package=\(packageURL.path)")
            return nil
        }
    }
}

private final class PreviewImageHostView: NSView {
    private let imageLayer = CALayer()
    private var currentCacheKey: String?
    private var currentContentMode: ContentMode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.masksToBounds = true
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("PreviewImageHostView is programmatic-only; use init(frame:) instead of init(coder:).")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    func configure(asset: PreviewAsset, contentMode: ContentMode) {
        guard currentCacheKey != asset.cacheKey || currentContentMode != contentMode else {
            return
        }

        currentCacheKey = asset.cacheKey
        currentContentMode = contentMode
        imageLayer.contents = asset.cgImage
        imageLayer.contentsGravity = contentMode == .fill ? .resizeAspectFill : .resizeAspect
        imageLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let gravity = contentMode == .fill ? "resizeAspectFill" : "resizeAspect"

        HistoryPreviewDiagnostics.log(
            "display file=\(asset.fileName) bounds=\(Int(bounds.width))x\(Int(bounds.height)) gravity=\(gravity) pixels=\(asset.pixelWidth)x\(asset.pixelHeight)"
        )
    }
}

private enum HistoryPreviewDiagnostics {
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.oontz.SnipSnipSnip",
        category: "HistoryPreview"
    )

    nonisolated static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SNIP_HISTORY_PREVIEW_DEBUG"] == "1"
        #else
        false
        #endif
    }

    nonisolated static func log(_ message: String) {
        guard isEnabled else {
            return
        }

        logger.debug("[HistoryPreview] \(message, privacy: .public)")
    }
}
