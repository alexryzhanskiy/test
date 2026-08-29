import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import os

/// Main-actor coordinator between the capture pipeline, the stores and the UI.
@MainActor
final class CaptureController: ObservableObject {

    enum Status: Equatable {
        case idle
        case preparing
        case ready
        case recording
        case analyzing
        case failed(String)

        var isRecording: Bool { self == .recording }
    }

    // MARK: - Published state

    @Published private(set) var status: Status = .idle
    @Published private(set) var configuration: CameraConfiguration?
    @Published private(set) var resolvedCalibration: ResolvedCalibration?
    @Published private(set) var liveTrackPoints: [CGPoint] = []
    @Published private(set) var liveEstimate: SpeedEstimate?
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var detectionCount: Int = 0
    @Published private(set) var lastMeasurement: SpeedMeasurement?
    @Published private(set) var lastTakeHadNoTrajectory = false
    @Published var errorMessage: String?
    /// Rotation applied to the preview, in degrees clockwise, so overlays can
    /// map buffer coordinates onto the displayed image.
    @Published private(set) var previewRotationDegrees: Double = 0

    let cameraSession = CameraSession()
    private let engine = CaptureEngine()
    private let settings: AppSettings
    private let measurementStore: MeasurementStore
    private let calibrationStore: CalibrationStore
    private let logger = Logger(subsystem: "com.speedradar.app", category: "CaptureController")

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingVideoURL: URL?

    init(
        settings: AppSettings,
        measurementStore: MeasurementStore,
        calibrationStore: CalibrationStore
    ) {
        self.settings = settings
        self.measurementStore = measurementStore
        self.calibrationStore = calibrationStore

        cameraSession.delegate = engine
        engine.setOptions(settings.estimationOptions)
        engine.onLiveUpdate = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.apply(update)
            }
        }

        settings.$minimumSampleCount
            .sink { [weak self] value in
                guard let self else { return }
                var options = EstimationOptions.default
                options.minimumSampleCount = max(4, value)
                self.engine.setOptions(options)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard status == .idle || isFailed else { return }
        status = .preparing
        do {
            let configuration = try await cameraSession.configure(
                prefersHighFrameRate: settings.prefersHighFrameRate)
            self.configuration = configuration
            engine.setFieldOfView(configuration.fieldOfViewDegrees)
            cameraSession.start()
            setUpRotationTracking()
            restoreStoredCalibration()
            status = .ready
        } catch {
            logger.error("Capture setup failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    func resume() {
        guard !isFailed, status != .idle else { return }
        cameraSession.start()
    }

    func pause() {
        guard !status.isRecording else { return }
        cameraSession.stop()
    }

    func reconfigureForFrameRatePreference() async {
        guard !status.isRecording else { return }
        do {
            let configuration = try await cameraSession.configure(
                prefersHighFrameRate: settings.prefersHighFrameRate)
            self.configuration = configuration
            engine.setFieldOfView(configuration.fieldOfViewDegrees)
            // A format change usually changes the buffer size; the stored
            // calibration is in normalized coordinates so it still applies.
            restoreStoredCalibration()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setUpRotationTracking() {
        guard let device = cameraSession.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        previewRotationDegrees = coordinator.videoRotationAngleForHorizonLevelPreview
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in
                self?.previewRotationDegrees = angle
            }
        }
    }

    // MARK: - Calibration

    var bufferSize: CGSize {
        let engineSize = engine.currentBufferSize()
        if engineSize.width > 0 { return engineSize }
        return configuration?.bufferSize ?? CGSize(width: 1920, height: 1080)
    }

    var hasCalibration: Bool { resolvedCalibration != nil }

    var usesMeasuredIntrinsics: Bool { engine.hasMeasuredIntrinsics() }

    /// Builds and applies a calibration from four tapped corners, expressed in
    /// normalized buffer coordinates.
    @discardableResult
    func applyCalibration(normalizedCorners corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        let size = bufferSize
        let intrinsics =
            engine.currentIntrinsics()
            ?? CameraIntrinsics(
                horizontalFieldOfViewDegrees: configuration?.fieldOfViewDegrees ?? 60,
                imageSize: size
            )

        let calibration = CourtCalibration(
            court: settings.court,
            normalizedImagePoints: corners,
            bufferSize: size,
            intrinsics: intrinsics,
            measurementHeight: settings.measurementHeight
        )

        do {
            let resolved = try ResolvedCalibration.resolve(calibration)
            self.resolvedCalibration = resolved
            engine.setCalibration(resolved)
            calibrationStore.store(calibration)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearCalibration() {
        resolvedCalibration = nil
        engine.setCalibration(nil)
        calibrationStore.clear()
    }

    /// Re-resolves the stored calibration against the current court settings.
    func restoreStoredCalibration() {
        guard var stored = calibrationStore.calibration else { return }
        stored.court = settings.court
        stored.measurementHeight = settings.measurementHeight
        stored.bufferSize = bufferSize
        if let intrinsics = engine.currentIntrinsics() {
            stored.intrinsics = intrinsics
        }
        do {
            let resolved = try ResolvedCalibration.resolve(stored)
            resolvedCalibration = resolved
            engine.setCalibration(resolved)
        } catch {
            logger.error(
                "Stored calibration could not be resolved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    var storedCalibrationIsStale: Bool { calibrationStore.isStale }

    // MARK: - Recording

    func startRecording() {
        guard status == .ready else { return }
        guard resolvedCalibration != nil else {
            errorMessage = "Calibrate the court before measuring."
            return
        }

        let url = RecordingsDirectory.url(forFileName: RecordingsDirectory.makeFileName())
        pendingVideoURL = url
        liveTrackPoints = []
        liveEstimate = nil
        detectionCount = 0
        recordingDuration = 0
        lastTakeHadNoTrajectory = false

        // Locking focus and exposure keeps the intrinsics — and therefore the
        // geometry — constant for the whole take.
        cameraSession.lockFocusAndExposure(true)

        do {
            try engine.beginTake(
                url: url,
                formatDescription: cameraSession.activeFormatDescription,
                videoSettings: cameraSession.recommendedVideoSettings(for: .mov),
                transform: recordingTransform(),
                recordsVideo: settings.keepsVideo
            )
            status = .recording
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            cameraSession.lockFocusAndExposure(false)
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard status == .recording else { return }
        status = .analyzing
        UIApplication.shared.isIdleTimerDisabled = false
        cameraSession.lockFocusAndExposure(false)

        let result = await engine.endTake()

        var measurement: SpeedMeasurement?
        if let trajectory = result.trajectory,
            let calibration = resolvedCalibration,
            let estimate = TrajectoryAnalyzer.analyze(
                trajectory: trajectory,
                calibration: calibration,
                options: settings.estimationOptions
            )
        {
            let fileName = result.videoURL?.lastPathComponent
            measurement = SpeedMeasurement.make(
                estimate: estimate,
                calibration: calibration,
                videoFileName: settings.keepsVideo ? fileName : nil
            )
        }

        if let measurement {
            measurementStore.add(measurement)
            lastMeasurement = measurement
            liveEstimate = measurement.estimate
            liveTrackPoints = measurement.estimate.points.map(\.normalizedImagePoint)
            lastTakeHadNoTrajectory = false
        } else {
            lastTakeHadNoTrajectory = true
            liveEstimate = nil
            // Nothing was measured, so there is nothing worth keeping on disk.
            if let url = result.videoURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        if !settings.keepsVideo, let url = result.videoURL {
            try? FileManager.default.removeItem(at: url)
        }

        pendingVideoURL = nil
        recordingDuration = result.duration
        status = .ready
    }

    func cancelRecording() {
        guard status == .recording else { return }
        engine.cancelTake()
        cameraSession.lockFocusAndExposure(false)
        UIApplication.shared.isIdleTimerDisabled = false
        pendingVideoURL = nil
        status = .ready
    }

    func focus(atNormalizedPoint point: CGPoint) {
        cameraSession.focus(atNormalizedPoint: point)
    }

    // MARK: - Helpers

    private func apply(_ update: CaptureEngine.LiveUpdate) {
        guard status == .recording else { return }
        liveTrackPoints = update.trackPoints
        liveEstimate = update.estimate
        detectionCount = update.detectionCount
        recordingDuration = update.recordingDuration
    }

    /// Rotation baked into the recorded file so playback is upright, matching
    /// what the preview showed.
    private func recordingTransform() -> CGAffineTransform {
        CGAffineTransform(rotationAngle: previewRotationDegrees * .pi / 180)
    }
}
