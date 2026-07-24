import AVFAudio
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated enum ScreenRecordingTargetSource: Equatable, Sendable {
    case display(CGDirectDisplayID, excludingProcessID: pid_t?, includeMenuBar: Bool)
    case window(CGWindowID)
}

nonisolated struct ScreenRecordingTarget: Equatable, Sendable {
    let source: ScreenRecordingTargetSource
    let contentBounds: CGRect
    let pointPixelScale: CGFloat
    let sourceRect: CGRect?
}

nonisolated struct ScreenRecordingConfiguration: Equatable, Sendable {
    var width: Int
    var height: Int
    var minimumFrameInterval: CMTime
    var queueDepth: Int
    var captureResolution: VideoRecordingCaptureResolution
    var showsCursor: Bool
    var showsMouseClicks: Bool
    var capturesAudio: Bool
    var capturesMicrophone: Bool
    var excludesCurrentProcessAudio: Bool
    var sampleRate: Int
    var channelCount: Int
    var hidesDesktopWindows: Bool

    init(
        width: Int,
        height: Int,
        minimumFrameInterval: CMTime,
        queueDepth: Int = 5,
        captureResolution: VideoRecordingCaptureResolution,
        showsCursor: Bool,
        showsMouseClicks: Bool,
        capturesAudio: Bool,
        capturesMicrophone: Bool,
        excludesCurrentProcessAudio: Bool = true,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        hidesDesktopWindows: Bool = false
    ) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.minimumFrameInterval = minimumFrameInterval
        self.queueDepth = queueDepth
        self.captureResolution = captureResolution
        self.showsCursor = showsCursor
        self.showsMouseClicks = showsMouseClicks
        self.capturesAudio = capturesAudio
        self.capturesMicrophone = capturesMicrophone
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.hidesDesktopWindows = hidesDesktopWindows
    }
}

nonisolated struct ScreenRecordingSegmentToken: Hashable, Sendable {
    fileprivate let rawValue = UUID()

    init() {}
}

nonisolated enum ScreenRecordingAudioSource: Sendable {
    case system
    case microphone
}

nonisolated struct ScreenRecordingAudioLevels: Equatable, Sendable {
    var system: Double = 0
    var microphone: Double = 0
}

@MainActor
protocol ScreenRecordingPlatformEventSink: AnyObject {
    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didFinishSegment token: ScreenRecordingSegmentToken
    )
    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        segment token: ScreenRecordingSegmentToken,
        didFailWith error: Error
    )
    func recordingPlatformSession(_ session: any ScreenRecordingPlatformSession, didStopWith error: Error)
    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didUpdateAudioLevel level: Double,
        source: ScreenRecordingAudioSource
    )
}

nonisolated protocol ScreenRecordingPlatformFrameSink: AnyObject, Sendable {
    func recordingPlatformDidOutputFrame(_ frame: GuideBufferedFrame)
}

extension ScreenRecordingPlatformEventSink {
    func recordingPlatformSession(
        _ session: any ScreenRecordingPlatformSession,
        didUpdateAudioLevel level: Double,
        source: ScreenRecordingAudioSource
    ) {}
}

@MainActor
protocol ScreenRecordingPlatformSession: AnyObject {
    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?)
    func setFrameSink(_ sink: (any ScreenRecordingPlatformFrameSink)?)
    func startCapture() async throws
    func stopCapture() async throws
    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws
    func updateTarget(_ target: ScreenRecordingTarget, configuration: ScreenRecordingConfiguration) async throws
    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken
    func removeRecordingSegment(_ token: ScreenRecordingSegmentToken) throws
}

extension ScreenRecordingPlatformSession {
    func setFrameSink(_ sink: (any ScreenRecordingPlatformFrameSink)?) {}

    func updateTarget(_ target: ScreenRecordingTarget, configuration: ScreenRecordingConfiguration) async throws {
        try await updateConfiguration(configuration)
    }
}

protocol ScreenRecordingPlatform: Sendable {
    nonisolated func shareableContent() async throws -> ScreenContentSnapshot
    nonisolated func requestMicrophoneAccess() async throws
    @MainActor func makeSession(
        target: ScreenRecordingTarget,
        configuration: ScreenRecordingConfiguration
    ) async throws -> any ScreenRecordingPlatformSession
}

/// ScreenCaptureKit delivers frames on a serial sample queue, while the session
/// itself is main-actor isolated. Publishing through this relay preserves the
/// stream's frame order and avoids building a backlog of unstructured main-actor
/// tasks that can leave Guide selecting an old frame for later actions.
nonisolated private final class ScreenRecordingFrameSinkRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sink: (any ScreenRecordingPlatformFrameSink)?

    func setSink(_ sink: (any ScreenRecordingPlatformFrameSink)?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    var hasSink: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    func publish(_ frame: GuideBufferedFrame) {
        lock.lock()
        let sink = sink
        lock.unlock()
        sink?.recordingPlatformDidOutputFrame(frame)
    }
}

struct LiveScreenRecordingPlatform: ScreenRecordingPlatform {
    nonisolated func shareableContent() async throws -> ScreenContentSnapshot {
        try await LiveScreenCapturePlatform().shareableContent()
    }

    nonisolated func requestMicrophoneAccess() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw ScreenRecordingError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }

            if !granted {
                throw ScreenRecordingError.microphonePermissionDenied
            }
        @unknown default:
            throw ScreenRecordingError.microphonePermissionDenied
        }
    }

    @MainActor
    func makeSession(
        target: ScreenRecordingTarget,
        configuration: ScreenRecordingConfiguration
    ) async throws -> any ScreenRecordingPlatformSession {
        let content = try await rawShareableContent(excludingDesktopWindows: configuration.hidesDesktopWindows)
        let filter = try Self.contentFilter(for: target.source, content: content)
        if case .display(_, _, let includeMenuBar) = target.source {
            filter.includeMenuBar = includeMenuBar
        }
        return LiveScreenRecordingPlatformSession(
            filter: filter,
            target: target,
            configuration: configuration
        )
    }

    nonisolated fileprivate func rawShareableContent(excludingDesktopWindows: Bool = false) async throws -> SCShareableContent {
        let result: ScreenRecordingShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content else {
                    continuation.resume(throwing: ScreenRecordingError.noDisplays)
                    return
                }

                continuation.resume(returning: ScreenRecordingShareableContentResult(content: content))
            }
        }
        return result.content
    }

    nonisolated fileprivate static func contentFilter(
        for source: ScreenRecordingTargetSource,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch source {
        case .display(let displayID, let excludedProcessID, _):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenRecordingError.selectedDisplayUnavailable
            }

            guard let excludedProcessID else {
                return SCContentFilter(display: display, excludingWindows: [])
            }

            let excludedApplications = content.applications.filter { $0.processID == excludedProcessID }
            if excludedApplications.isEmpty {
                let excludedWindows = content.windows.filter { $0.owningApplication?.processID == excludedProcessID }
                return SCContentFilter(display: display, excludingWindows: excludedWindows)
            }

            return SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenRecordingError.noWindowsAvailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    nonisolated fileprivate static func streamConfiguration(
        from configuration: ScreenRecordingConfiguration,
        target: ScreenRecordingTarget
    ) -> SCStreamConfiguration {
        let scConfiguration = SCStreamConfiguration()
        if let sourceRect = target.sourceRect {
            scConfiguration.sourceRect = sourceRect.gscIntegralStandardized
        }
        scConfiguration.width = configuration.width
        scConfiguration.height = configuration.height
        scConfiguration.minimumFrameInterval = configuration.minimumFrameInterval
        scConfiguration.queueDepth = configuration.queueDepth
        scConfiguration.captureResolution = configuration.captureResolution.screenCaptureKitValue
        scConfiguration.showsCursor = configuration.showsCursor
        scConfiguration.showMouseClicks = configuration.showsMouseClicks
        scConfiguration.capturesAudio = configuration.capturesAudio
        scConfiguration.captureMicrophone = configuration.capturesMicrophone
        scConfiguration.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio
        scConfiguration.sampleRate = configuration.sampleRate
        scConfiguration.channelCount = configuration.channelCount
        scConfiguration.captureDynamicRange = .SDR
        return scConfiguration
    }
}

@MainActor
private final class LiveScreenRecordingPlatformSession: NSObject, ScreenRecordingPlatformSession, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    nonisolated private static let sampleOutputQueue = DispatchQueue(label: "com.oontz.SnipSnipSnip.ScreenRecordingSampleOutput")
    nonisolated private let frameSinkRelay = ScreenRecordingFrameSinkRelay()

    private var stream: SCStream!
    private var target: ScreenRecordingTarget
    private weak var eventSink: (any ScreenRecordingPlatformEventSink)?
    private var outputByToken: [ScreenRecordingSegmentToken: SCRecordingOutput] = [:]
    private var tokenByOutputID: [ObjectIdentifier: ScreenRecordingSegmentToken] = [:]
    private var configuration: ScreenRecordingConfiguration
    private var didAttachScreenOutput = false
    private var didAttachAudioOutput = false
    private var didAttachMicrophoneOutput = false
    private var lastAudioLevelUpdateBySource: [ScreenRecordingAudioSource: Date] = [:]

    init(filter: SCContentFilter, target: ScreenRecordingTarget, configuration: ScreenRecordingConfiguration) {
        self.target = target
        self.configuration = configuration
        super.init()
        self.stream = SCStream(
            filter: filter,
            configuration: LiveScreenRecordingPlatform.streamConfiguration(from: configuration, target: target),
            delegate: self
        )
    }

    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?) {
        eventSink = sink
    }

    func setFrameSink(_ sink: (any ScreenRecordingPlatformFrameSink)?) {
        frameSinkRelay.setSink(sink)
    }

    func startCapture() async throws {
        if frameSinkRelay.hasSink {
            try ensureSampleOutputsAttached(for: configuration)
        }
        try await stream.startCapture()
    }

    func stopCapture() async throws {
        try await stream.stopCapture()
    }

    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws {
        if configuration.capturesAudio || configuration.capturesMicrophone {
            try ensureSampleOutputsAttached(for: configuration)
        }

        try await stream.updateConfiguration(LiveScreenRecordingPlatform.streamConfiguration(from: configuration, target: target))
        try removeDisabledSampleOutputs(for: configuration)
        self.configuration = configuration
    }

    func updateTarget(_ target: ScreenRecordingTarget, configuration: ScreenRecordingConfiguration) async throws {
        if configuration.capturesAudio || configuration.capturesMicrophone {
            try ensureSampleOutputsAttached(for: configuration)
        }
        let content = try await LiveScreenRecordingPlatform().rawShareableContent(
            excludingDesktopWindows: configuration.hidesDesktopWindows
        )
        let filter = try LiveScreenRecordingPlatform.contentFilter(for: target.source, content: content)
        if case .display(_, _, let includeMenuBar) = target.source {
            filter.includeMenuBar = includeMenuBar
        }
        try await stream.updateContentFilter(filter)
        try await stream.updateConfiguration(
            LiveScreenRecordingPlatform.streamConfiguration(from: configuration, target: target)
        )
        try removeDisabledSampleOutputs(for: configuration)
        self.target = target
        self.configuration = configuration
    }

    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken {
        try ensureSampleOutputsAttached(for: configuration)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        guard recordingConfiguration.availableOutputFileTypes.contains(.mp4),
              recordingConfiguration.availableVideoCodecTypes.contains(.h264) else {
            throw ScreenRecordingError.unsupportedRecordingFormat
        }

        let token = ScreenRecordingSegmentToken()
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        outputByToken[token] = recordingOutput
        tokenByOutputID[ObjectIdentifier(recordingOutput)] = token
        return token
    }

    func removeRecordingSegment(_ token: ScreenRecordingSegmentToken) throws {
        guard let output = outputByToken.removeValue(forKey: token) else {
            return
        }
        try stream.removeRecordingOutput(output)
    }

    private func ensureSampleOutputsAttached(for configuration: ScreenRecordingConfiguration) throws {
        if !didAttachScreenOutput {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.sampleOutputQueue)
            didAttachScreenOutput = true
        }

        if configuration.capturesAudio, !didAttachAudioOutput {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: Self.sampleOutputQueue)
            didAttachAudioOutput = true
        }

        if configuration.capturesMicrophone, !didAttachMicrophoneOutput {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: Self.sampleOutputQueue)
            didAttachMicrophoneOutput = true
        }
    }

    private func removeDisabledSampleOutputs(for configuration: ScreenRecordingConfiguration) throws {
        if !configuration.capturesAudio, didAttachAudioOutput {
            try stream.removeStreamOutput(self, type: .audio)
            didAttachAudioOutput = false
        }

        if !configuration.capturesMicrophone, didAttachMicrophoneOutput {
            try stream.removeStreamOutput(self, type: .microphone)
            didAttachMicrophoneOutput = false
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self,
                  let token = self.tokenByOutputID[ObjectIdentifier(recordingOutput)] else {
                return
            }
            self.tokenByOutputID[ObjectIdentifier(recordingOutput)] = nil
            self.eventSink?.recordingPlatformSession(self, didFinishSegment: token)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self,
                  let token = self.tokenByOutputID[ObjectIdentifier(recordingOutput)] else {
                return
            }
            self.tokenByOutputID[ObjectIdentifier(recordingOutput)] = nil
            self.eventSink?.recordingPlatformSession(self, segment: token, didFailWith: error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            self.eventSink?.recordingPlatformSession(self, didStopWith: error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen,
           sampleBuffer.isValid,
           CMSampleBufferDataIsReady(sampleBuffer),
           Self.isUsableScreenFrame(sampleBuffer),
           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let frame = GuideBufferedFrame(
                timestamp: Self.screenFrameTimestamp(sampleBuffer),
                pixelBuffer: pixelBuffer
            )
            frameSinkRelay.publish(frame)
            return
        }

        guard let source = ScreenRecordingAudioSource(streamOutputType: type),
              let level = Self.audioLevel(from: sampleBuffer) else {
            // RecordingOutput handles persisted media. Keep this sink attached so the
            // stream has an active output target and does not spam dropped-frame logs.
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  self.shouldPublishAudioLevel(for: source) else {
                return
            }

            self.eventSink?.recordingPlatformSession(self, didUpdateAudioLevel: level, source: source)
        }
    }

    nonisolated private static func isUsableScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachmentArray.first,
        let rawStatus = attachment[.status] as? Int,
        let status = SCFrameStatus(rawValue: rawStatus) else {
            // Preserve compatibility if a future ScreenCaptureKit version omits
            // the status attachment. Current versions include it on screen frames.
            return true
        }
        return status == .complete || status == .started
    }

    nonisolated private static func screenFrameTimestamp(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        guard let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachmentArray.first,
        let displayTime = attachment[.displayTime] as? UInt64 else {
            return CMClockGetTime(CMClockGetHostTimeClock())
        }
        return CMClockMakeHostTimeFromSystemUnits(displayTime)
    }

    private func shouldPublishAudioLevel(for source: ScreenRecordingAudioSource) -> Bool {
        let now = Date()
        let minimumInterval: TimeInterval = 1.0 / 24.0
        if let previous = lastAudioLevelUpdateBySource[source],
           now.timeIntervalSince(previous) < minimumInterval {
            return false
        }

        lastAudioLevelUpdateBySource[source] = now
        return true
    }

    nonisolated private static func audioLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
            return nil
        }

        var audioBufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &audioBufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, audioBufferListSize > 0 else {
            return nil
        }

        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            audioBufferListPointer.deallocate()
        }

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return nil
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        let rms = rootMeanSquareLevel(
            in: buffers,
            streamDescription: streamDescription
        )

        guard rms.isFinite, rms > 0 else {
            return 0
        }

        let decibels = 20 * log10(rms)
        return min(max((decibels + 60) / 60, 0), 1)
    }

    nonisolated private static func rootMeanSquareLevel(
        in buffers: UnsafeMutableAudioBufferListPointer,
        streamDescription: AudioStreamBasicDescription
    ) -> Double {
        let formatFlags = streamDescription.mFormatFlags
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (formatFlags & kAudioFormatFlagIsSignedInteger) != 0
        var squaredSum = 0.0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            let byteCount = Int(buffer.mDataByteSize)
            if isFloat, bitsPerChannel == 32 {
                let values = data.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.stride)
                for index in 0..<(byteCount / MemoryLayout<Float>.stride) {
                    let sample = Double(values[index])
                    squaredSum += sample * sample
                    sampleCount += 1
                }
            } else if isSignedInteger, bitsPerChannel == 16 {
                let values = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.stride)
                for index in 0..<(byteCount / MemoryLayout<Int16>.stride) {
                    let sample = Double(values[index]) / Double(Int16.max)
                    squaredSum += sample * sample
                    sampleCount += 1
                }
            } else if isSignedInteger, bitsPerChannel == 32 {
                let values = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.stride)
                for index in 0..<(byteCount / MemoryLayout<Int32>.stride) {
                    let sample = Double(values[index]) / Double(Int32.max)
                    squaredSum += sample * sample
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else {
            return 0
        }

        return sqrt(squaredSum / Double(sampleCount))
    }
}

private extension ScreenRecordingAudioSource {
    nonisolated init?(streamOutputType: SCStreamOutputType) {
        switch streamOutputType {
        case .audio:
            self = .system
        case .microphone:
            self = .microphone
        default:
            return nil
        }
    }
}

nonisolated private struct ScreenRecordingShareableContentResult: @unchecked Sendable {
    let content: SCShareableContent
}

private extension VideoRecordingCaptureResolution {
    nonisolated var screenCaptureKitValue: SCCaptureResolutionType {
        switch self {
        case .nominal:
            return .nominal
        case .automatic:
            return .automatic
        case .best:
            return .best
        }
    }
}
