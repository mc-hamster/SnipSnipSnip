import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var first: CMTime?
    var count = 0
    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL:url,fileType:.mov)
        input = AVAssetWriterInput(mediaType:.video,outputSettings:[
            AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width, AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:22000000,AVVideoMaxKeyFrameIntervalKey:30,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, buffer.isValid, CMSampleBufferGetImageBuffer(buffer) != nil else { return }
        let pts=CMSampleBufferGetPresentationTimeStamp(buffer)
        if first == nil { first=pts; writer.startWriting(); writer.startSession(atSourceTime:pts); print("RECORDING"); fflush(stdout) }
        if input.isReadyForMoreMediaData { input.append(buffer); count += 1 }
    }
}
@main struct Main {
    static func main() async throws {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count == 6 else { fatalError("record-live output.mov seconds x y width height") }
        let url=URL(fileURLWithPath:args[0]), seconds=Double(args[1])!
        guard !FileManager.default.fileExists(atPath:url.path) else { fatalError("Will not overwrite an existing take") }
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        guard let display=content.displays.first(where:{$0.displayID==CGMainDisplayID()}) else { fatalError("Main display unavailable") }
        let excluded=content.windows.filter { $0.owningApplication?.applicationName == "ChatGPT Computer Use" }
        print("Excluding only filming-control overlays: \(excluded.map(\.windowID))")
        let filter=SCContentFilter(display:display,excludingWindows:excluded)
        let c=SCStreamConfiguration()
        c.sourceRect=CGRect(x:Double(args[2])!,y:Double(args[3])!,width:Double(args[4])!,height:Double(args[5])!)
        c.width=Int(args[4])!*2; c.height=Int(args[5])!*2
        c.minimumFrameInterval=CMTime(value:1,timescale:30)
        c.queueDepth=6; c.showsCursor=true; c.capturesAudio=false
        c.pixelFormat=kCVPixelFormatType_32BGRA
        let sink=try Sink(url:url,width:c.width,height:c.height)
        let queue=DispatchQueue(label:"AppPreviewFrames")
        let stream=SCStream(filter:filter,configuration:c,delegate:nil)
        try stream.addStreamOutput(sink,type:.screen,sampleHandlerQueue:queue)
        try await stream.startCapture()
        try await Task.sleep(for:.seconds(seconds))
        try await stream.stopCapture()
        queue.sync { sink.input.markAsFinished() }
        await sink.writer.finishWriting()
        print("FINISHED \(sink.count) frames \(sink.writer.status.rawValue) \(sink.writer.error?.localizedDescription ?? "OK")")
    }
}
