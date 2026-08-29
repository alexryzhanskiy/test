import AVFoundation
import CoreMedia
import Foundation
import os

/// Facts about the active capture format that the rest of the app needs.
struct CameraConfiguration: Equatable {
    var bufferSize: CGSize
    var frameRate: Double
    var fieldOfViewDegrees: Double
    var isHighFrameRate: Bool { frameRate >= 100 }
}

protocol CameraSessionDelegate: AnyObject {
    /// Called on the capture queue for every frame.
    func cameraSession(_ session: CameraSession, didOutput sampleBuffer: CMSampleBuffer)
}

/// Owns the `AVCaptureSession`: permissions, device and format selection, and a
/// single video data output that feeds both the tracker and the recorder.
///
/// One output serves both jobs on purpose. Running `AVCaptureMovieFileOutput`
/// alongside a data output costs a second encode path and, on several devices,
/// blocks the high-frame-rate formats that make this whole measurement possible.
final class CameraSession: NSObject {

    enum SessionError: Error, LocalizedError {
        case notAuthorized
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Camera access is required to measure ball speed. Enable it in Settings."
            case .noCamera:
                return "No usable back camera was found on this device."
            case .cannotAddInput:
                return "The camera could not be attached to the capture session."
            case .cannotAddOutput:
                return "The video output could not be attached to the capture session."
            }
        }
    }

    let session = AVCaptureSession()
    weak var delegate: CameraSessionDelegate?

    private let sessionQueue = DispatchQueue(label: "com.speedradar.session")
    private let outputQueue = DispatchQueue(
        label: "com.speedradar.video-output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let logger = Logger(subsystem: "com.speedradar.app", category: "CameraSession")

    private(set) var device: AVCaptureDevice?
    private(set) var configuration: CameraConfiguration?
    private var isConfigured = false

    /// Highest frame rate the current device can offer at a usable resolution.
    private(set) var availableFrameRates: [Double] = []

    // MARK: - Authorization

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func requestAccess() async -> Bool {
        switch authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: - Configuration

    /// Configures the session. Safe to call again to switch frame-rate strategy.
    func configure(prefersHighFrameRate: Bool) async throws -> CameraConfiguration {
        guard await CameraSession.requestAccess() else { throw SessionError.notAuthorized }

        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let configuration = try self.performConfiguration(
                        prefersHighFrameRate: prefersHighFrameRate)
                    continuation.resume(returning: configuration)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performConfiguration(prefersHighFrameRate: Bool) throws -> CameraConfiguration {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority

        guard let device = CameraSession.bestBackCamera() else { throw SessionError.noCamera }
        self.device = device

        if !isConfigured {
            session.inputs.forEach { session.removeInput($0) }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw SessionError.cannotAddInput }
            session.addInput(input)

            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(videoOutput) else { throw SessionError.cannotAddOutput }
            session.addOutput(videoOutput)
            isConfigured = true
        }

        let format = CameraSession.bestFormat(
            for: device, prefersHighFrameRate: prefersHighFrameRate)
        availableFrameRates = CameraSession.frameRates(for: device)

        try device.lockForConfiguration()
        if let format {
            device.activeFormat = format
            let maxRate =
                format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
            let duration = CMTime(value: 1, timescale: CMTimeScale(maxRate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        // A ball crossing the frame in a few milliseconds smears badly under a
        // long exposure, and a smeared blob is a poor detection. Continuous
        // auto-exposure with a capped duration keeps the ball compact.
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        device.unlockForConfiguration()

        if let connection = videoOutput.connection(with: .video) {
            // Keep buffers in the sensor's native orientation: the per-frame
            // intrinsic matrix is expressed in those coordinates, and rotating
            // the buffer would invalidate it. Rotation is handled in the preview
            // and in the recorded file's transform instead.
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            connection.isVideoMirrored = false
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let frameRate = 1.0 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
        let configuration = CameraConfiguration(
            bufferSize: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
            frameRate: frameRate.isFinite ? frameRate : 30,
            fieldOfViewDegrees: Double(device.activeFormat.videoFieldOfView)
        )
        self.configuration = configuration
        logger.info(
            "Capture configured: \(dimensions.width)x\(dimensions.height) @ \(frameRate, format: .fixed(precision: 0)) fps"
        )
        return configuration
    }

    /// Prefers the wide-angle back camera; the virtual multi-camera devices
    /// switch lenses mid-shot, which would silently change the intrinsics.
    static func bestBackCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .back
        )
        return discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? discovery.devices.first
    }

    /// Picks the format that best trades resolution against frame rate.
    ///
    /// Frame rate is what limits speed accuracy: at 240 fps a ball at 40 m/s
    /// moves 17 cm between frames, at 30 fps it moves 1.3 m and may not be
    /// detected at all. Resolution beyond 720p buys very little here.
    static func bestFormat(for device: AVCaptureDevice, prefersHighFrameRate: Bool)
        -> AVCaptureDevice.Format?
    {
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let isSupportedSubtype =
                subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            return isSupportedSubtype && dimensions.width >= 1280 && dimensions.height >= 720
        }

        guard !candidates.isEmpty else { return device.formats.last }

        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }

        if prefersHighFrameRate {
            return candidates.max { lhs, rhs in
                let lhsRate = maxRate(lhs)
                let rhsRate = maxRate(rhs)
                if lhsRate == rhsRate {
                    let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                    let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                    return l.width * l.height < r.width * r.height
                }
                return lhsRate < rhsRate
            }
        }

        // Otherwise: the highest resolution that still reaches 60 fps.
        let sixtyOrBetter = candidates.filter { maxRate($0) >= 60 }
        let pool = sixtyOrBetter.isEmpty ? candidates : sixtyOrBetter
        return pool.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return l.width * l.height < r.width * r.height
        }
    }

    static func frameRates(for device: AVCaptureDevice) -> [Double] {
        let rates = device.formats.flatMap { format in
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate)
        }
        return Array(Set(rates.map { ($0).rounded() })).sorted()
    }

    /// Encoder settings matched to the active format, used by the recorder so
    /// the clip is compressed rather than written as raw frames.
    func recommendedVideoSettings(for fileType: AVFileType) -> [String: Any]? {
        videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: fileType)
    }

    var activeFormatDescription: CMFormatDescription? {
        device?.activeFormat.formatDescription
    }

    // MARK: - Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Locks focus and exposure so they cannot shift mid-rally, which would
    /// change the effective intrinsics and blur the ball inconsistently.
    func lockFocusAndExposure(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device, (try? device.lockForConfiguration()) != nil else {
                return
            }
            if locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
        }
    }

    func focus(atNormalizedPoint point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.device, (try? device.lockForConfiguration()) != nil else {
                return
            }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
        }
    }
}

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        delegate?.cameraSession(self, didOutput: sampleBuffer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        logger.debug("Dropped a frame while tracking")
    }
}
