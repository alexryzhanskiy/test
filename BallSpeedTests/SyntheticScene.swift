import CoreGraphics
import Foundation

@testable import BallSpeed

/// A virtual court and camera used to generate exact test data.
///
/// Everything the estimators consume — corner taps, ball detections — can be
/// produced here with known ground truth, which is what makes it possible to
/// test the geometry without a device.
struct SyntheticScene {
    var court: CourtPreset
    /// Camera position in the court frame, metres.
    var cameraPosition: Vec3
    /// Point the camera is aimed at, in the court frame.
    var lookAt: Vec3
    var imageSize: CGSize
    var horizontalFieldOfView: Double
    var measurementHeight: Double

    init(
        court: CourtPreset = CourtPreset.preset(withID: "tennis-doubles")!,
        cameraPosition: Vec3 = Vec3(-4, -6, 3.2),
        lookAt: Vec3? = nil,
        imageSize: CGSize = CGSize(width: 1920, height: 1080),
        horizontalFieldOfView: Double = 62,
        measurementHeight: Double = 1.0
    ) {
        self.court = court
        self.cameraPosition = cameraPosition
        self.lookAt = lookAt ?? Vec3(court.width / 2, court.length / 2, 0)
        self.imageSize = imageSize
        self.horizontalFieldOfView = horizontalFieldOfView
        self.measurementHeight = measurementHeight
    }

    var intrinsics: CameraIntrinsics {
        CameraIntrinsics(horizontalFieldOfViewDegrees: horizontalFieldOfView, imageSize: imageSize)
    }

    /// Rotation from court coordinates into camera coordinates, for a camera
    /// with X right, Y down and Z forward.
    var rotation: Mat3 {
        let forward = (lookAt - cameraPosition).normalized
        let worldUp = Vec3(0, 0, 1)
        let right = forward.cross(worldUp).normalized
        let down = forward.cross(right)
        return Mat3(rows: right, down, forward)
    }

    var translation: Vec3 { -(rotation * cameraPosition) }

    var pose: CameraPose { CameraPose(rotation: rotation, translation: translation) }

    /// Projects a court-frame point to pixels, or `nil` if it is behind the camera.
    func project(_ point: Vec3) -> CGPoint? {
        PlanarPose.project(courtPoint: point, pose: pose, intrinsics: intrinsics)
    }

    func normalized(_ pixel: CGPoint) -> CGPoint {
        CGPoint(x: pixel.x / imageSize.width, y: pixel.y / imageSize.height)
    }

    /// The four court corners as normalized image points, in tap order.
    func cornerTaps() -> [CGPoint] {
        court.courtCorners.compactMap { corner in
            project(Vec3(Double(corner.x), Double(corner.y), 0)).map(normalized)
        }
    }

    func calibration() -> CourtCalibration {
        CourtCalibration(
            court: court,
            normalizedImagePoints: cornerTaps(),
            bufferSize: imageSize,
            intrinsics: intrinsics,
            measurementHeight: measurementHeight
        )
    }

    func resolvedCalibration() throws -> ResolvedCalibration {
        try ResolvedCalibration.resolve(calibration())
    }

    /// Samples a ballistic flight, dropping any frame where the ball would fall
    /// outside the image.
    ///
    /// - Parameters:
    ///   - origin: Launch position in the court frame.
    ///   - velocity: Launch velocity in metres per second.
    ///   - frameRate: Capture rate in frames per second.
    ///   - frameCount: Number of frames to generate.
    ///   - startTime: Timestamp of the first frame.
    ///   - pixelNoise: Uniform noise added to each detection, in pixels.
    func flight(
        origin: Vec3,
        velocity: Vec3,
        frameRate: Double = 240,
        frameCount: Int = 12,
        startTime: TimeInterval = 10,
        pixelNoise: Double = 0,
        seed: UInt64 = 42
    ) -> TrackedTrajectory {
        var generator = SeededGenerator(seed: seed)
        var samples: [TrackedSample] = []
        for index in 0..<frameCount {
            let t = Double(index) / frameRate
            let position =
                origin + velocity * t + Vec3(0, 0, -0.5 * EstimationOptions.gravity * t * t)
            guard var pixel = project(position) else { continue }
            if pixelNoise > 0 {
                pixel.x += CGFloat(Double.random(in: -pixelNoise...pixelNoise, using: &generator))
                pixel.y += CGFloat(Double.random(in: -pixelNoise...pixelNoise, using: &generator))
            }
            guard pixel.x >= 0, pixel.y >= 0, pixel.x <= imageSize.width,
                pixel.y <= imageSize.height
            else { continue }
            samples.append(
                TrackedSample(normalizedPoint: normalized(pixel), time: startTime + t))
        }
        return TrackedTrajectory(id: UUID(), samples: samples, visionConfidence: 1)
    }
}

/// Deterministic random source so noisy tests do not flake.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
