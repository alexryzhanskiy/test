import CoreGraphics
import Foundation

/// The four court corners the user tapped, together with everything needed to
/// turn image measurements into metres.
///
/// Image points are stored in *normalized* buffer coordinates (0...1, origin at
/// the top-left of the analysis buffer) so a calibration stays valid if the
/// capture resolution changes between sessions.
struct CourtCalibration: Codable, Equatable {
    var court: CourtPreset
    var normalizedImagePoints: [CGPoint]
    var bufferSize: CGSize
    var intrinsics: CameraIntrinsics
    var measurementHeight: Double
    var createdAt: Date

    init(
        court: CourtPreset,
        normalizedImagePoints: [CGPoint],
        bufferSize: CGSize,
        intrinsics: CameraIntrinsics,
        measurementHeight: Double,
        createdAt: Date = Date()
    ) {
        self.court = court
        self.normalizedImagePoints = normalizedImagePoints
        self.bufferSize = bufferSize
        self.intrinsics = intrinsics
        self.measurementHeight = measurementHeight
        self.createdAt = createdAt
    }

    var isComplete: Bool { normalizedImagePoints.count == 4 }

    func imagePoints(for size: CGSize) -> [CGPoint] {
        normalizedImagePoints.map {
            CGPoint(x: $0.x * size.width, y: $0.y * size.height)
        }
    }
}

/// A calibration with all of its derived geometry worked out once, ready to be
/// used on every frame.
struct ResolvedCalibration {
    let calibration: CourtCalibration
    let court: CourtPreset
    /// Court metres (Z = 0) → pixels in the analysis buffer.
    let courtToImage: Mat3
    /// Pixels → court metres, on the ground plane.
    let imageToCourtGround: Mat3
    /// Pixels → court metres, on the plane at `measurementHeight`.
    let imageToCourtMeasurementPlane: Mat3
    let intrinsics: CameraIntrinsics
    let bufferSize: CGSize
    let pose: CameraPose?
    /// Mean corner reprojection error in pixels — a direct read on tap accuracy.
    let reprojectionErrorPixels: Double
    /// True when the tapped corners ran clockwise and the court frame's X axis
    /// had to be mirrored so that Z points up out of the surface.
    let isMirrored: Bool

    var measurementHeight: Double { calibration.measurementHeight }

    /// Camera height above the playing surface, when pose recovery succeeded.
    var cameraHeightMeters: Double? {
        guard let pose else { return nil }
        let height = pose.cameraCenter.z
        return height.isFinite ? height : nil
    }

    /// Distance from the camera to the centre of the calibrated rectangle.
    var cameraDistanceMeters: Double? {
        guard let pose else { return nil }
        let centre = Vec3(court.width / 2, court.length / 2, 0)
        return (pose.cameraCenter - centre).length
    }

    var supportsBallisticEstimation: Bool { pose != nil }

    enum ResolveError: Error, LocalizedError {
        case incompleteCalibration
        case degenerate(Error)

        var errorDescription: String? {
            switch self {
            case .incompleteCalibration:
                return "Tap all four corners before measuring."
            case .degenerate(let underlying):
                return underlying.localizedDescription
            }
        }
    }

    static func resolve(_ calibration: CourtCalibration) throws -> ResolvedCalibration {
        guard calibration.isComplete else { throw ResolveError.incompleteCalibration }

        let bufferSize = calibration.bufferSize
        let imagePoints = calibration.imagePoints(for: bufferSize)
        let intrinsics = calibration.intrinsics.scaled(to: bufferSize)

        func build(mirrored: Bool) throws -> (Mat3, CameraPose?, Double) {
            let corners = calibration.court.courtCorners
            let courtPoints =
                mirrored
                ? corners.map { CGPoint(x: calibration.court.width - $0.x, y: $0.y) }
                : corners
            let homography = try Homography.estimate(from: courtPoints, to: imagePoints)
            let error = Homography.reprojectionError(homography, from: courtPoints, to: imagePoints)
            let pose = PlanarPose.decompose(courtToImage: homography, intrinsics: intrinsics)
            return (homography, pose, error)
        }

        var mirrored = false
        var courtToImage: Mat3
        var pose: CameraPose?
        var reprojectionError: Double
        do {
            let initial = try build(mirrored: false)
            courtToImage = initial.0
            pose = initial.1
            reprojectionError = initial.2
        } catch {
            throw ResolveError.degenerate(error)
        }

        // A camera below the playing surface means the corners were tapped in
        // clockwise order, which leaves the court frame left-handed. Mirroring
        // X restores a right-handed frame with Z pointing up, so that gravity
        // can be applied correctly in the ballistic fit.
        if let recovered = pose, recovered.cameraCenter.z < 0 {
            if let retry = try? build(mirrored: true), let retryPose = retry.1,
                retryPose.cameraCenter.z > 0
            {
                mirrored = true
                courtToImage = retry.0
                pose = retryPose
                reprojectionError = retry.2
            }
        }

        guard let imageToCourtGround = courtToImage.inverted else {
            throw ResolveError.degenerate(Homography.EstimationError.degenerateConfiguration)
        }

        var measurementPlane = imageToCourtGround
        if let pose, calibration.measurementHeight != 0 {
            let planeHomography = PlanarPose.homography(
                forPlaneHeight: calibration.measurementHeight,
                pose: pose,
                intrinsics: intrinsics
            )
            if let inverted = planeHomography.inverted {
                measurementPlane = inverted
            }
        }

        return ResolvedCalibration(
            calibration: calibration,
            court: calibration.court,
            courtToImage: courtToImage,
            imageToCourtGround: imageToCourtGround,
            imageToCourtMeasurementPlane: measurementPlane,
            intrinsics: intrinsics,
            bufferSize: bufferSize,
            pose: pose,
            reprojectionErrorPixels: reprojectionError,
            isMirrored: mirrored
        )
    }

    /// Maps a pixel to court metres on the measurement plane.
    func courtPoint(forImagePoint point: CGPoint) -> CGPoint? {
        imageToCourtMeasurementPlane.project(point)
    }

    /// Maps a normalized (0...1) image point to court metres.
    func courtPoint(forNormalizedPoint point: CGPoint) -> CGPoint? {
        courtPoint(
            forImagePoint: CGPoint(
                x: point.x * bufferSize.width,
                y: point.y * bufferSize.height
            ))
    }

    /// Court outline in normalized image coordinates, for drawing the overlay.
    var courtOutlineNormalized: [CGPoint] {
        court.courtCorners.compactMap { corner -> CGPoint? in
            let source =
                isMirrored ? CGPoint(x: court.width - corner.x, y: corner.y) : corner
            guard let projected = courtToImage.project(source), bufferSize.width > 0,
                bufferSize.height > 0
            else { return nil }
            return CGPoint(
                x: projected.x / bufferSize.width,
                y: projected.y / bufferSize.height
            )
        }
    }
}
