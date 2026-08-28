import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import os

/// The real-time half of the app: it runs on the capture queue, feeds frames to
/// the tracker and the recorder, and publishes throttled updates for the UI.
///
/// Kept separate from `CaptureController` so that per-frame work never has to
/// hop to the main actor.
final class CaptureEngine: NSObject {

    struct LiveUpdate {
        var trackPoints: [CGPoint]
        var estimate: SpeedEstimate?
        var detectionCount: Int
        var recordingDuration: TimeInterval
    }

    struct TakeResult {
        var videoURL: URL?
        var trajectory: TrackedTrajectory?
        var allTrajectories: [TrackedTrajectory]
        var duration: TimeInterval
    }

    /// Invoked on the main queue roughly ten times a second while recording.
    var onLiveUpdate: ((LiveUpdate) -> Void)?

    private let tracker = BallTracker()
    private let recorder = VideoRecorder()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.ballspeed.app", category: "CaptureEngine")

    private var calibration: ResolvedCalibration?
    private var options = EstimationOptions.default
    private var isRecording = false
    private var recordingStart: CMTime?
    private var lastLiveUpdate: CFTimeInterval = 0
    private var bufferSize: CGSize = .zero
    private var intrinsics: CameraIntrinsics?
    private var fieldOfViewDegrees: Double = 60

    /// Minimum wall-clock gap between UI updates while recording.
    private let liveUpdateInterval: CFTimeInterval = 0.1

    // MARK: - Configuration

    func setCalibration(_ calibration: ResolvedCalibration?) {
        lock.lock()
        self.calibration = calibration
        lock.unlock()
    }

    func setOptions(_ options: EstimationOptions) {
        lock.lock()
        self.options = options
        lock.unlock()
    }

    func setFieldOfView(_ degrees: Double) {
        lock.lock()
        fieldOfViewDegrees = degrees
        lock.unlock()
    }

    func setTrajectoryLength(_ length: Int) {
        tracker.trajectoryLength = length
    }

    /// Best available intrinsics: the per-frame matrix from the capture
    /// connection when the device supplies it, otherwise derived from the
    /// format's field of view.
    func currentIntrinsics() -> CameraIntrinsics? {
        lock.lock()
        defer { lock.unlock() }
        if let intrinsics { return intrinsics }
        guard bufferSize.width > 0 else { return nil }
        return CameraIntrinsics(
            horizontalFieldOfViewDegrees: fieldOfViewDegrees, imageSize: bufferSize)
    }

    func currentBufferSize() -> CGSize {
        lock.lock()
        defer { lock.unlock() }
        return bufferSize
    }

    /// True when the intrinsic matrix is coming from the capture connection
    /// rather than being derived from the field of view.
    func hasMeasuredIntrinsics() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return intrinsics != nil
    }

    // MARK: - Takes

    func beginTake(
        url: URL,
        formatDescription: CMFormatDescription?,
        videoSettings: [String: Any]?,
        transform: CGAffineTransform,
        recordsVideo: Bool
    ) throws {
        tracker.reset()
        lock.lock()
        recordingStart = nil
        lastLiveUpdate = 0
        isRecording = true
        lock.unlock()

        if recordsVideo {
            try recorder.start(
                url: url,
                formatDescription: formatDescription,
                videoSettings: videoSettings,
                transform: transform
            )
        }
    }

    func endTake() async -> TakeResult {
        lock.lock()
        isRecording = false
        lock.unlock()

        let url = await recorder.finish()
        let duration = recorder.recordedDuration
        return TakeResult(
            videoURL: url,
            trajectory: tracker.bestTrajectory,
            allTrajectories: tracker.allTrajectories,
            duration: duration
        )
    }

    func cancelTake() {
        lock.lock()
        isRecording = false
        lock.unlock()
        recorder.cancel()
        tracker.reset()
    }

    // MARK: - Analysis

    func analyze(_ trajectory: TrackedTrajectory) -> SpeedEstimate? {
        lock.lock()
        let calibration = self.calibration
        let options = self.options
        lock.unlock()
        guard let calibration else { return nil }
        return TrajectoryAnalyzer.analyze(
            trajectory: trajectory, calibration: calibration, options: options)
    }
}

// MARK: - Frame handling

extension CaptureEngine: CameraSessionDelegate {

    func cameraSession(_ session: CameraSession, didOutput sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))

        lock.lock()
        if bufferSize != size { bufferSize = size }
        if let measured = CameraIntrinsics(sampleBuffer: sampleBuffer, imageSize: size) {
            intrinsics = measured
        }
        let recording = isRecording
        if recording, recordingStart == nil {
            recordingStart = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }
        let start = recordingStart
        lock.unlock()

        guard recording else { return }

        recorder.append(sampleBuffer)
        tracker.process(sampleBuffer: sampleBuffer)

        let now = CACurrentMediaTime()
        lock.lock()
        let shouldPublish = now - lastLiveUpdate >= liveUpdateInterval
        if shouldPublish { lastLiveUpdate = now }
        lock.unlock()
        guard shouldPublish else { return }

        let elapsed: TimeInterval = {
            guard let start else { return 0 }
            return (CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - start).seconds
        }()

        let best = tracker.bestTrajectory
        let points = best?.samples.map(\.normalizedPoint) ?? []
        let estimate = best.flatMap { analyze($0) }
        let count = tracker.allTrajectories.count

        let update = LiveUpdate(
            trackPoints: points,
            estimate: estimate,
            detectionCount: count,
            recordingDuration: max(0, elapsed)
        )
        DispatchQueue.main.async { [weak self] in
            self?.onLiveUpdate?(update)
        }
    }
}
