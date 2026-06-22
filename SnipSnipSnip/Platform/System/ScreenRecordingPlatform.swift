import AVFAudio
import CoreMedia
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
        channelCount: Int = 2
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
    }
}

nonisolated struct ScreenRecordingSegmentToken: Hashable, Sendable {
    fileprivate let rawValue = UUID()

    init() {}
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
}

@MainActor
protocol ScreenRecordingPlatformSession: AnyObject {
    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?)
    func startCapture() async throws
    func stopCapture() async throws
    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws
    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken
    func removeRecordingSegment(_ token: ScreenRecordingSegmentToken) throws
}

protocol ScreenRecordingPlatform: Sendable {
    nonisolated func shareableContent() async throws -> ScreenContentSnapshot
    nonisolated func requestMicrophoneAccess() async throws
    @MainActor func makeSession(
        target: ScreenRecordingTarget,
        configuration: ScreenRecordingConfiguration
    ) async throws -> any ScreenRecordingPlatformSession
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
        let content = try await rawShareableContent()
        let filter = try Self.contentFilter(for: target.source, content: content)
        if case .display(_, _, let includeMenuBar) = target.source {
            filter.includeMenuBar = includeMenuBar
        }
        return LiveScreenRecordingPlatformSession(
            filter: filter,
            target: target,
            configuration: Self.streamConfiguration(from: configuration, target: target)
        )
    }

    nonisolated private func rawShareableContent() async throws -> SCShareableContent {
        let result: ScreenRecordingShareableContentResult = try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
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

    nonisolated private static func contentFilter(
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

    private var stream: SCStream!
    private let target: ScreenRecordingTarget
    private weak var eventSink: (any ScreenRecordingPlatformEventSink)?
    private var outputByToken: [ScreenRecordingSegmentToken: SCRecordingOutput] = [:]
    private var tokenByOutputID: [ObjectIdentifier: ScreenRecordingSegmentToken] = [:]
    private var didAttachSampleOutput = false

    init(filter: SCContentFilter, target: ScreenRecordingTarget, configuration: SCStreamConfiguration) {
        self.target = target
        super.init()
        self.stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    func setEventSink(_ sink: (any ScreenRecordingPlatformEventSink)?) {
        eventSink = sink
    }

    func startCapture() async throws {
        try await stream.startCapture()
    }

    func stopCapture() async throws {
        try await stream.stopCapture()
    }

    func updateConfiguration(_ configuration: ScreenRecordingConfiguration) async throws {
        try await stream.updateConfiguration(
            LiveScreenRecordingPlatform.streamConfiguration(from: configuration, target: target)
        )
    }

    func startRecordingSegment(to outputURL: URL) throws -> ScreenRecordingSegmentToken {
        try ensureSampleOutputAttached()

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
        tokenByOutputID[ObjectIdentifier(output)] = nil
        try stream.removeRecordingOutput(output)
    }

    private func ensureSampleOutputAttached() throws {
        guard !didAttachSampleOutput else {
            return
        }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: Self.sampleOutputQueue)
        didAttachSampleOutput = true
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self,
                  let token = self.tokenByOutputID[ObjectIdentifier(recordingOutput)] else {
                return
            }
            self.eventSink?.recordingPlatformSession(self, didFinishSegment: token)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self,
                  let token = self.tokenByOutputID[ObjectIdentifier(recordingOutput)] else {
                return
            }
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
        // RecordingOutput handles persisted media. Keep this sink attached so the
        // stream has an active output target and does not spam dropped-frame logs.
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
