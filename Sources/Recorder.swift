import AVFoundation
import ScreenCaptureKit

/// Records one screen plus everything the Mac plays (system audio) into an .mp4 file.
/// ScreenCaptureKit does the capturing; AVAssetWriter encodes H.264 video and AAC audio.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameRate = 30

    let outputURL: URL
    let displayID: CGDirectDisplayID
    /// Called if recording stops on its own, e.g. the screen was disconnected or the disk is full.
    var onUnexpectedStop: (@MainActor (Error) -> Void)?

    private var captureStream: SCStream?
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var audioInput: AVAssetWriterInput!
    private var frameAdaptor: AVAssetWriterInputPixelBufferAdaptor!

    // Everything below is only touched on `queue`, where ScreenCaptureKit delivers samples.
    private let queue = DispatchQueue(label: "ScreenRecorder.capture")
    private var sessionStart: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime: CMTime?
    private var finished = false
    private var reportedFailure = false

    init(outputURL: URL, displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.outputURL = outputURL
        self.displayID = displayID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        // Leave this app (its menu bar icon) out of the video.
        let thisApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: thisApp, exceptingWindows: [])

        let (width, height) = Self.videoSize(for: display)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
        config.queueDepth = 6
        config.showsCursor = true
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        try startWriter(width: width, height: height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        captureStream = stream
    }

    /// Stops recording and finishes the file. Returns where it was saved.
    func stop() async throws -> URL {
        try? await captureStream?.stopCapture()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.finish(continuation) }
        }
    }

    // MARK: - Writing the file

    private func startWriter(width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // About 9 Mbit/s for a MacBook screen: sharp text, roughly 4 GB per hour.
                AVVideoAverageBitRateKey: width * height * Self.frameRate / 20,
                AVVideoExpectedSourceFrameRateKey: Self.frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        frameAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.cannotWrite
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid else { return }
        guard writer.status == .writing else {
            reportFailure(writer.error ?? RecorderError.cannotWrite)
            return
        }
        switch outputType {
        case .screen: appendFrame(sampleBuffer)
        case .audio: appendAudio(sampleBuffer)
        default: break
        }
    }

    private func appendFrame(_ sampleBuffer: CMSampleBuffer) {
        // Skip "nothing changed" updates, which carry no image.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let frame = sampleBuffer.imageBuffer
        else { return }

        let time = sampleBuffer.presentationTimeStamp
        if sessionStart == nil {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        }
        if let lastFrameTime, time <= lastFrameTime { return }
        // If the encoder is still busy with earlier frames, drop this one.
        guard videoInput.isReadyForMoreMediaData else { return }
        if frameAdaptor.append(frame, withPresentationTime: time) {
            lastFrame = frame
            lastFrameTime = time
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // The video starts at the first frame; skip any sound from before that.
        guard let sessionStart, sampleBuffer.presentationTimeStamp >= sessionStart,
              audioInput.isReadyForMoreMediaData
        else { return }
        audioInput.append(sampleBuffer)
    }

    private func finish(_ continuation: CheckedContinuation<URL, Error>) {
        guard !finished else {
            continuation.resume(throwing: RecorderError.cannotWrite)
            return
        }
        finished = true

        guard writer.status == .writing else {
            continuation.resume(throwing: writer.error ?? RecorderError.cannotWrite)
            return
        }
        guard sessionStart != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: RecorderError.nothingRecorded)
            return
        }

        // ScreenCaptureKit only sends frames when something changes, so repeat the last
        // frame at the moment Stop was clicked to make the video last until then.
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        if let lastFrame, let lastFrameTime, end > lastFrameTime, videoInput.isReadyForMoreMediaData {
            frameAdaptor.append(lastFrame, withPresentationTime: end)
        }
        writer.endSession(atSourceTime: end)
        writer.finishWriting { [self] in
            if writer.status == .completed {
                continuation.resume(returning: outputURL)
            } else {
                continuation.resume(throwing: writer.error ?? RecorderError.cannotWrite)
            }
        }
    }

    // MARK: - Problems

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.reportFailure(error) }
    }

    private func reportFailure(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Task { @MainActor in self.onUnexpectedStop?(error) }
    }

    // MARK: - Video size

    /// The screen's size in real pixels (Retina screens have 2 per point), scaled down
    /// if needed to fit H.264's 4096×2304 limit. Encoders need even numbers.
    private static func videoSize(for display: SCDisplay) -> (width: Int, height: Int) {
        var width = Double(display.width)
        var height = Double(display.height)
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.width > 0 {
            let pixelsPerPoint = Double(mode.pixelWidth) / Double(mode.width)
            width *= pixelsPerPoint
            height *= pixelsPerPoint
        }
        let scale = min(1, 4096 / max(width, height), (4096 * 2304 / (width * height)).squareRoot())
        return (Int(width * scale) / 2 * 2, Int(height * scale) / 2 * 2)
    }
}

enum RecorderError: LocalizedError {
    case noDisplay, cannotWrite, nothingRecorded

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No screen was found to record."
        case .cannotWrite: return "The video file couldn't be written."
        case .nothingRecorded: return "Nothing was recorded."
        }
    }
}
