import AVFoundation
import CoreMedia
import Foundation
import os

/// Writes the capture stream to a QuickTime file.
///
/// Fed from the same `AVCaptureVideoDataOutput` sample buffers that the tracker
/// analyses, so the recorded clip and the measurement are guaranteed to be the
/// same frames.
final class VideoRecorder {

    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case notReady

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already in progress."
            case .notReady: return "The recorder is not ready to accept frames."
            }
        }
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var hasStartedSession = false
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.ballspeed.app", category: "VideoRecorder")

    private(set) var outputURL: URL?
    private(set) var isRecording = false
    private(set) var firstPresentationTime: CMTime?
    private(set) var lastPresentationTime: CMTime?

    var recordedDuration: TimeInterval {
        guard let first = firstPresentationTime, let last = lastPresentationTime else { return 0 }
        return (last - first).seconds
    }

    func start(
        url: URL,
        formatDescription: CMFormatDescription?,
        videoSettings: [String: Any]?,
        transform: CGAffineTransform
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isRecording else { throw RecorderError.alreadyRecording }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let input: AVAssetWriterInput
        if let videoSettings {
            input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: videoSettings,
                sourceFormatHint: formatDescription
            )
        } else {
            // No recommended settings available: fall back to passthrough.
            input = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        }
        input.expectsMediaDataInRealTime = true
        input.transform = transform

        guard writer.canAdd(input) else { throw RecorderError.notReady }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.notReady
        }

        self.writer = writer
        self.input = input
        self.outputURL = url
        self.hasStartedSession = false
        self.firstPresentationTime = nil
        self.lastPresentationTime = nil
        self.isRecording = true
    }

    /// Appends one frame. Call on the capture queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRecording, let writer, let input, writer.status == .writing else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedSession {
            writer.startSession(atSourceTime: presentationTime)
            hasStartedSession = true
            firstPresentationTime = presentationTime
        }
        guard input.isReadyForMoreMediaData else {
            logger.debug("Writer input not ready; frame skipped")
            return
        }
        if input.append(sampleBuffer) {
            lastPresentationTime = presentationTime
        }
    }

    /// Finishes the file and returns its URL, or `nil` if nothing was written.
    func finish() async -> URL? {
        lock.lock()
        guard isRecording, let writer, let input else {
            lock.unlock()
            return nil
        }
        isRecording = false
        let url = outputURL
        let wroteAnything = hasStartedSession
        lock.unlock()

        input.markAsFinished()
        guard wroteAnything else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url ?? URL(fileURLWithPath: "/dev/null"))
            clear()
            return nil
        }

        await writer.finishWriting()
        let status = writer.status
        clear()

        guard status == .completed else {
            logger.error(
                "Recording failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return url
    }

    func cancel() {
        lock.lock()
        let writer = self.writer
        let url = outputURL
        isRecording = false
        lock.unlock()

        writer?.cancelWriting()
        if let url { try? FileManager.default.removeItem(at: url) }
        clear()
    }

    private func clear() {
        lock.lock()
        writer = nil
        input = nil
        hasStartedSession = false
        outputURL = nil
        lock.unlock()
    }
}
