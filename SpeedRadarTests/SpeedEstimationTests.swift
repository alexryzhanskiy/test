import CoreGraphics
import XCTest

@testable import SpeedRadar

final class BallisticSpeedEstimatorTests: XCTestCase {

    /// A drive across the court at ~30 m/s, filmed at 240 fps for half a second.
    func testRecoversKnownSpeedFromExactDetections() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let velocity = Vec3(2, 29.5, 3)
        let trajectory = scene.flight(
            origin: Vec3(2, 2, 1.1), velocity: velocity, frameRate: 240, frameCount: 130)

        XCTAssertGreaterThanOrEqual(trajectory.samples.count, 60)
        let estimate = try XCTUnwrap(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))

        XCTAssertEqual(estimate.method, .ballistic)
        XCTAssertEqual(
            estimate.initialSpeedMetersPerSecond, velocity.length,
            accuracy: velocity.length * 0.01)
        XCTAssertEqual(
            estimate.horizontalSpeedMetersPerSecond, hypot(velocity.x, velocity.y),
            accuracy: 0.5)
        XCTAssertLessThan(estimate.residual, 0.5)
        XCTAssertGreaterThan(estimate.confidence, 0.7)
    }

    /// The same flight with a pixel of detection jitter, which is about what a
    /// real detector delivers.
    func testToleratesDetectionNoise() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let velocity = Vec3(2, 29.5, 3)
        let trajectory = scene.flight(
            origin: Vec3(2, 2, 1.1),
            velocity: velocity,
            frameRate: 240,
            frameCount: 130,
            pixelNoise: 1.0
        )

        let estimate = try XCTUnwrap(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
        XCTAssertEqual(
            estimate.initialSpeedMetersPerSecond, velocity.length,
            accuracy: velocity.length * 0.10)
    }

    /// The vertical component is the part a flat homography cannot see, so it
    /// gets its own check.
    func testRecoversLaunchAngleOfALob() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let velocity = Vec3(0, 12, 12)  // 45° up
        let trajectory = scene.flight(
            origin: Vec3(5, 1, 0.8),
            velocity: velocity,
            frameRate: 120,
            frameCount: 120,
            pixelNoise: 1.0
        )

        let estimate = try XCTUnwrap(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
        XCTAssertEqual(
            estimate.initialSpeedMetersPerSecond, velocity.length,
            accuracy: velocity.length * 0.08)
        let angle = try XCTUnwrap(estimate.launchAngleDegrees)
        XCTAssertEqual(angle, 45, accuracy: 3.0)
        XCTAssertNotNil(estimate.apexHeightMeters)
    }

    /// Over a very short window the gravity curvature is a fraction of a pixel,
    /// so depth — and therefore absolute speed — is not measurable. The fit must
    /// decline rather than report a confident wrong answer.
    func testGatesOutWindowsWhereDepthIsUnobservable() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(3, 3, 1.0),
            velocity: Vec3(1, 25, 2),
            frameRate: 240,
            frameCount: 20,
            pixelNoise: 1.0
        )
        XCTAssertNil(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
    }

    func testObservabilityGrowsWithWindowLength() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let pose = try XCTUnwrap(resolved.pose)

        let short = BallisticSpeedEstimator.observability(
            window: 0.08, sampleCount: 20, meanDepth: 14, pose: pose,
            intrinsics: resolved.intrinsics)
        let long = BallisticSpeedEstimator.observability(
            window: 0.5, sampleCount: 120, meanDepth: 14, pose: pose,
            intrinsics: resolved.intrinsics)

        XCTAssertLessThan(short, BallisticSpeedEstimator.minimumObservability)
        XCTAssertGreaterThan(long, BallisticSpeedEstimator.minimumObservability)
    }

    func testRejectsTooFewSamples() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(2, 2, 1), velocity: Vec3(0, 25, 2), frameCount: 3)
        XCTAssertNil(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
    }

    func testRejectsStationaryBlob() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(5, 10, 1), velocity: Vec3(0, 0, 0), frameCount: 60)
        XCTAssertNil(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
    }

    func testDiscardsAnOutlyingDetection() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let velocity = Vec3(0, 28, 2)
        var trajectory = scene.flight(
            origin: Vec3(4, 2, 1.1), velocity: velocity, frameRate: 240, frameCount: 130)

        // Something else in the scene — a racket head — lands in the middle of
        // the path.
        var samples = trajectory.samples
        let index = samples.count / 2
        samples[index].normalizedPoint.x += 0.12
        trajectory.samples = samples

        let estimate = try XCTUnwrap(
            BallisticSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
        XCTAssertLessThan(estimate.sampleCount, samples.count)
        XCTAssertEqual(
            estimate.initialSpeedMetersPerSecond, velocity.length,
            accuracy: velocity.length * 0.05)
    }
}

final class PlanarSpeedEstimatorTests: XCTestCase {

    /// With the ball travelling exactly on the assumed plane, the flat fit is as
    /// accurate as the 3D one.
    func testRecoversSpeedOnTheAssumedPlane() throws {
        let scene = SyntheticScene(measurementHeight: 1.2)
        let resolved = try scene.resolvedCalibration()

        var samples: [TrackedSample] = []
        let speed = 22.0
        for index in 0..<16 {
            let t = Double(index) / 240.0
            let position = Vec3(3 + 0.2 * speed * t, 2 + 0.98 * speed * t, 1.2)
            guard let pixel = scene.project(position) else { continue }
            samples.append(
                TrackedSample(normalizedPoint: scene.normalized(pixel), time: 5 + t))
        }
        let trajectory = TrackedTrajectory(id: UUID(), samples: samples, visionConfidence: 1)

        let estimate = try XCTUnwrap(
            PlanarSpeedEstimator.estimate(trajectory: trajectory, calibration: resolved))
        XCTAssertEqual(estimate.method, .planar)
        XCTAssertEqual(estimate.initialSpeedMetersPerSecond, speed, accuracy: speed * 0.03)
        XCTAssertLessThan(estimate.residual, 0.05)
    }

    func testLineFitRecoversSlopeAndIntercept() throws {
        let times = [0.0, 0.1, 0.2, 0.3]
        let values = times.map { 2.5 + 7.0 * $0 }
        let fit = try XCTUnwrap(LineFit.fit(times: times, values: values))
        XCTAssertEqual(fit.slope, 7, accuracy: 1e-9)
        XCTAssertEqual(fit.intercept, 2.5, accuracy: 1e-9)
    }
}

final class TrajectoryAnalyzerTests: XCTestCase {

    func testPrefersTheBallisticFitWhenTheFlightSupportsIt() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(3, 2, 1.2), velocity: Vec3(1, 26, 4), frameRate: 240, frameCount: 130)

        let estimate = try XCTUnwrap(
            TrajectoryAnalyzer.analyze(trajectory: trajectory, calibration: resolved))
        XCTAssertEqual(estimate.method, .ballistic)
    }

    /// When the 3D fit declines, the user still gets a number — from the flat
    /// fit, clearly labelled as such.
    func testFallsBackToPlanarWhenTheWindowIsTooShort() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(3, 3, 1.0),
            velocity: Vec3(1, 25, 2),
            frameRate: 240,
            frameCount: 20,
            pixelNoise: 1.0
        )

        let estimate = try XCTUnwrap(
            TrajectoryAnalyzer.analyze(trajectory: trajectory, calibration: resolved))
        XCTAssertEqual(estimate.method, .planar)
        XCTAssertGreaterThan(estimate.initialSpeedMetersPerSecond, 0)
    }

    func testFallsBackToPlanarWhenBallisticIsDisallowed() throws {
        let scene = SyntheticScene(measurementHeight: 1.2)
        let resolved = try scene.resolvedCalibration()
        let trajectory = scene.flight(
            origin: Vec3(3, 2, 1.2), velocity: Vec3(1, 26, 0), frameRate: 240, frameCount: 60)

        let estimate = try XCTUnwrap(
            TrajectoryAnalyzer.analyze(
                trajectory: trajectory, calibration: resolved, allowsBallistic: false))
        XCTAssertEqual(estimate.method, .planar)
    }
}

final class TrackedTrajectoryTests: XCTestCase {

    func testMergeKeepsOneSamplePerTimestampInOrder() {
        var trajectory = TrackedTrajectory(
            id: UUID(),
            samples: [
                TrackedSample(normalizedPoint: CGPoint(x: 0.1, y: 0.1), time: 1.0),
                TrackedSample(normalizedPoint: CGPoint(x: 0.2, y: 0.2), time: 1.1),
            ],
            visionConfidence: 0.8
        )
        trajectory.merge([
            TrackedSample(normalizedPoint: CGPoint(x: 0.25, y: 0.25), time: 1.1),
            TrackedSample(normalizedPoint: CGPoint(x: 0.3, y: 0.3), time: 1.2),
        ])

        XCTAssertEqual(trajectory.samples.count, 3)
        XCTAssertEqual(trajectory.samples.map(\.time), [1.0, 1.1, 1.2])
        XCTAssertEqual(Double(trajectory.samples[1].normalizedPoint.x), 0.25, accuracy: 1e-9)
    }

    func testNormalizedSpanMeasuresStraightLineExtent() {
        let trajectory = TrackedTrajectory(
            id: UUID(),
            samples: [
                TrackedSample(normalizedPoint: CGPoint(x: 0.1, y: 0.1), time: 0),
                TrackedSample(normalizedPoint: CGPoint(x: 0.4, y: 0.5), time: 0.1),
            ],
            visionConfidence: 1
        )
        XCTAssertEqual(trajectory.normalizedSpan, 0.5, accuracy: 1e-9)
    }
}
