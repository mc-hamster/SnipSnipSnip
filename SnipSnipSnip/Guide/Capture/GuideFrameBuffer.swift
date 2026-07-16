import CoreMedia
import CoreVideo
import Foundation

nonisolated struct GuideBufferedFrame: @unchecked Sendable {
    let timestamp: CMTime
    let pixelBuffer: CVPixelBuffer

    var byteCount: Int {
        CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
    }
}

nonisolated final class GuideFrameBuffer: @unchecked Sendable {
    static let maximumBytes = 256 * 1_024 * 1_024
    static let targetDuration = CMTime(seconds: 0.2, preferredTimescale: 600)

    private let lock = NSLock()
    private var frames: [GuideBufferedFrame] = []
    private var bytes = 0

    func append(_ frame: GuideBufferedFrame) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        bytes += frame.byteCount
        trim(relativeTo: frame.timestamp)
    }

    func newestFrame(before timestamp: CMTime) -> GuideBufferedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last { CMTimeCompare($0.timestamp, timestamp) <= 0 }
    }

    func flush() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        lock.unlock()
    }

    var memoryUsage: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    private func trim(relativeTo latestTimestamp: CMTime) {
        while frames.count > 3 {
            let isOverMemory = bytes > Self.maximumBytes
            let age = CMTimeSubtract(latestTimestamp, frames[0].timestamp)
            let isTooOld = CMTimeCompare(age, Self.targetDuration) > 0
            guard isOverMemory || isTooOld else { break }
            bytes -= frames.removeFirst().byteCount
        }
    }
}
