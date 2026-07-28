import CoreGraphics
import Foundation
import zlib

/// Encodes browser-compatible, metadata-free PNGs with screenshot-oriented row
/// filtering and strong DEFLATE compression. Sub filtering on the first row
/// and Paeth filtering thereafter preserve the compact result without making a
/// Debug export score every pixel against all five PNG filters.
nonisolated enum CompositionHTMLPNGEncoder {
    enum EncodingError: Error {
        case invalidImage
        case bitmapCreationFailed
        case compressionFailed
    }

    private enum Filter: UInt8 {
        case sub = 1
        case paeth = 4
    }

    static func data(for image: CGImage) throws -> Data {
        try Task.checkCancellation()
        guard image.width > 0,
              image.height > 0,
              image.width <= Int(UInt32.max),
              image.height <= Int(UInt32.max) else {
            throw EncodingError.invalidImage
        }

        let rgba = try normalizedRGBA(for: image)
        let isOpaque = Swift.stride(
            from: 3,
            to: rgba.count,
            by: 4
        ).allSatisfy { rgba[$0] == 255 }
        let componentsPerPixel = isOpaque ? 3 : 4
        let colorType: UInt8 = isOpaque ? 2 : 6
        let filtered = try filteredAndCompressed(
            rgba: rgba,
            width: image.width,
            height: image.height,
            componentsPerPixel: componentsPerPixel
        )
        try Task.checkCancellation()

        var png = Data()
        png.reserveCapacity(filtered.count + 96)
        png.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10])

        var header = Data()
        header.appendBigEndian(UInt32(image.width))
        header.appendBigEndian(UInt32(image.height))
        header.append(contentsOf: [
            8,          // Bit depth
            colorType,  // RGB or RGBA
            0,          // DEFLATE compression
            0,          // Adaptive filtering
            0,          // No interlacing
        ])
        png.appendPNGChunk(type: "IHDR", payload: header)
        png.appendPNGChunk(type: "sRGB", payload: Data([0]))
        png.appendPNGChunk(type: "IDAT", payload: filtered)
        png.appendPNGChunk(type: "IEND", payload: Data())
        return png
    }

    private static func normalizedRGBA(for image: CGImage) throws -> [UInt8] {
        let pixelCount = image.width.multipliedReportingOverflow(by: image.height)
        let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
        guard !pixelCount.overflow, !byteCount.overflow else {
            throw EncodingError.invalidImage
        }

        var rgba = [UInt8](repeating: 0, count: byteCount.partialValue)
        let didDraw = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: bytes.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: image.width,
                    height: image.height
                )
            )
            return true
        }
        guard didDraw else {
            throw EncodingError.bitmapCreationFailed
        }
        return rgba
    }

    private static func filteredAndCompressed(
        rgba: [UInt8],
        width: Int,
        height: Int,
        componentsPerPixel: Int
    ) throws -> Data {
        let rowByteCountResult = width.multipliedReportingOverflow(
            by: componentsPerPixel
        )
        guard !rowByteCountResult.overflow else {
            throw EncodingError.invalidImage
        }
        let rowByteCount = rowByteCountResult.partialValue
        var currentRow = [UInt8](repeating: 0, count: rowByteCount)
        var previousRow = [UInt8](repeating: 0, count: rowByteCount)
        var filteredRow = [UInt8](repeating: 0, count: rowByteCount + 1)
        let compressor = try Deflater()

        for row in 0..<height {
            if row.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            populate(
                &currentRow,
                from: rgba,
                sourceOffset: row * width * 4,
                pixelCount: width,
                includesAlpha: componentsPerPixel == 4
            )

            if row == 0 {
                filterSubRow(
                    currentRow,
                    bytesPerPixel: componentsPerPixel,
                    into: &filteredRow
                )
            } else {
                filterPaethRow(
                    currentRow,
                    previous: previousRow,
                    bytesPerPixel: componentsPerPixel,
                    into: &filteredRow
                )
            }
            try compressor.append(filteredRow)
            swap(&currentRow, &previousRow)
        }

        try Task.checkCancellation()
        return try compressor.finish()
    }

    private static func populate(
        _ row: inout [UInt8],
        from rgba: [UInt8],
        sourceOffset: Int,
        pixelCount: Int,
        includesAlpha: Bool
    ) {
        var destination = 0
        for pixel in 0..<pixelCount {
            let source = sourceOffset + pixel * 4
            let alpha = rgba[source + 3]
            if includesAlpha {
                row[destination] = unpremultiplied(rgba[source], alpha: alpha)
                row[destination + 1] = unpremultiplied(
                    rgba[source + 1],
                    alpha: alpha
                )
                row[destination + 2] = unpremultiplied(
                    rgba[source + 2],
                    alpha: alpha
                )
                row[destination + 3] = alpha
                destination += 4
            } else {
                row[destination] = rgba[source]
                row[destination + 1] = rgba[source + 1]
                row[destination + 2] = rgba[source + 2]
                destination += 3
            }
        }
    }

    private static func unpremultiplied(_ component: UInt8, alpha: UInt8) -> UInt8 {
        guard alpha > 0 else { return 0 }
        guard alpha < 255 else { return component }
        return UInt8(
            min(
                (Int(component) * 255 + Int(alpha) / 2) / Int(alpha),
                255
            )
        )
    }

    private static func filterSubRow(
        _ current: [UInt8],
        bytesPerPixel: Int,
        into output: inout [UInt8]
    ) {
        output[0] = Filter.sub.rawValue
        for index in current.indices {
            let left = index >= bytesPerPixel
                ? current[index - bytesPerPixel]
                : 0
            output[index + 1] = current[index] &- left
        }
    }

    private static func filterPaethRow(
        _ current: [UInt8],
        previous: [UInt8],
        bytesPerPixel: Int,
        into output: inout [UInt8]
    ) {
        output[0] = Filter.paeth.rawValue
        for index in current.indices {
            let left = index >= bytesPerPixel
                ? current[index - bytesPerPixel]
                : 0
            let above = previous[index]
            let upperLeft = index >= bytesPerPixel
                ? previous[index - bytesPerPixel]
                : 0
            let predictor = paeth(
                left: left,
                above: above,
                upperLeft: upperLeft
            )
            let filtered = current[index] &- predictor
            output[index + 1] = filtered
        }
    }

    private static func paeth(
        left: UInt8,
        above: UInt8,
        upperLeft: UInt8
    ) -> UInt8 {
        let left = Int(left)
        let above = Int(above)
        let upperLeft = Int(upperLeft)
        let estimate = left + above - upperLeft
        let leftDistance = abs(estimate - left)
        let aboveDistance = abs(estimate - above)
        let upperLeftDistance = abs(estimate - upperLeft)
        if leftDistance <= aboveDistance,
           leftDistance <= upperLeftDistance {
            return UInt8(left)
        }
        if aboveDistance <= upperLeftDistance {
            return UInt8(above)
        }
        return UInt8(upperLeft)
    }
}

nonisolated private final class Deflater {
    private var stream = z_stream()
    private var output = Data()
    private var isFinished = false

    init() throws {
        let result = deflateInit_(
            &stream,
            Z_BEST_COMPRESSION,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard result == Z_OK else {
            throw CompositionHTMLPNGEncoder.EncodingError.compressionFailed
        }
    }

    deinit {
        deflateEnd(&stream)
    }

    func append(_ bytes: [UInt8]) throws {
        guard !isFinished else {
            throw CompositionHTMLPNGEncoder.EncodingError.compressionFailed
        }
        try bytes.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(
                mutating: input.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(input.count)
            while stream.avail_in > 0 {
                try drain(flush: Z_NO_FLUSH)
            }
        }
    }

    func finish() throws -> Data {
        guard !isFinished else {
            throw CompositionHTMLPNGEncoder.EncodingError.compressionFailed
        }
        isFinished = true
        var result = Z_OK
        while result != Z_STREAM_END {
            result = try drain(flush: Z_FINISH)
        }
        return output
    }

    @discardableResult
    private func drain(flush: Int32) throws -> Int32 {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let result = buffer.withUnsafeMutableBytes { destination -> Int32 in
            stream.next_out = destination.bindMemory(
                to: Bytef.self
            ).baseAddress
            stream.avail_out = uInt(destination.count)
            return deflate(&stream, flush)
        }
        guard result == Z_OK || result == Z_STREAM_END else {
            throw CompositionHTMLPNGEncoder.EncodingError.compressionFailed
        }
        let produced = buffer.count - Int(stream.avail_out)
        output.append(contentsOf: buffer.prefix(produced))
        return result
    }
}

nonisolated private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) {
            append(contentsOf: $0)
        }
    }

    mutating func appendPNGChunk(type: String, payload: Data) {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4)
        appendBigEndian(UInt32(payload.count))
        append(contentsOf: typeBytes)
        append(payload)

        var checksum = crc32(0, nil, 0)
        typeBytes.withUnsafeBytes { bytes in
            checksum = crc32(
                checksum,
                bytes.bindMemory(to: Bytef.self).baseAddress,
                uInt(bytes.count)
            )
        }
        payload.withUnsafeBytes { bytes in
            checksum = crc32(
                checksum,
                bytes.bindMemory(to: Bytef.self).baseAddress,
                uInt(bytes.count)
            )
        }
        appendBigEndian(UInt32(checksum))
    }
}
