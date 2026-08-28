import CoreGraphics
import XCTest

@testable import BallSpeed

final class MatrixTests: XCTestCase {

    func testInverseRoundTrip() throws {
        let matrix = Mat3([2, 0.5, -1, 0.25, 3, 2, 1, -1, 4])
        let inverse = try XCTUnwrap(matrix.inverted)
        let product = matrix * inverse
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(product[row, column], row == column ? 1 : 0, accuracy: 1e-9)
            }
        }
    }

    func testSingularMatrixHasNoInverse() {
        // Third row is the sum of the first two.
        XCTAssertNil(Mat3([1, 2, 3, 4, 5, 6, 5, 7, 9]).inverted)
    }

    func testColumnAndRowAccess() {
        let matrix = Mat3(columns: Vec3(1, 2, 3), Vec3(4, 5, 6), Vec3(7, 8, 9))
        XCTAssertEqual(matrix.column(0), Vec3(1, 2, 3))
        XCTAssertEqual(matrix.row(0), Vec3(1, 4, 7))
    }

    func testCrossProductIsRightHanded() {
        XCTAssertEqual(Vec3(1, 0, 0).cross(Vec3(0, 1, 0)), Vec3(0, 0, 1))
    }
}

final class LinearSolverTests: XCTestCase {

    func testSolvesSquareSystem() throws {
        // 2x + y = 5, x - 3y = -6  ->  x = 9/7, y = 17/7
        let solution = try XCTUnwrap(
            LinearSolver.solve(matrix: [2, 1, 1, -3], vector: [5, -6], size: 2))
        XCTAssertEqual(solution[0], 9.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(solution[1], 17.0 / 7.0, accuracy: 1e-9)
    }

    func testSingularSystemReturnsNil() {
        XCTAssertNil(LinearSolver.solve(matrix: [1, 2, 2, 4], vector: [1, 2], size: 2))
    }

    func testLeastSquaresRecoversOverdeterminedFit() throws {
        // Four points exactly on y = 3x + 1.
        let rows = [[0.0, 1.0], [1.0, 1.0], [2.0, 1.0], [3.0, 1.0]]
        let values = [1.0, 4.0, 7.0, 10.0]
        let solution = try XCTUnwrap(
            LinearSolver.leastSquares(rows: rows, values: values, unknowns: 2))
        XCTAssertEqual(solution[0], 3, accuracy: 1e-9)
        XCTAssertEqual(solution[1], 1, accuracy: 1e-9)
    }
}

final class HomographyTests: XCTestCase {

    func testRecoversKnownProjectiveTransform() throws {
        let source = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 20), CGPoint(x: 0, y: 20),
        ]
        let truth = Mat3([1.4, 0.2, 30, -0.3, 1.1, 12, 0.0009, 0.0004, 1])
        let destination = source.map { truth.project($0)! }

        let estimated = try Homography.estimate(from: source, to: destination)
        for point in source {
            let expected = truth.project(point)!
            let actual = try XCTUnwrap(estimated.project(point))
            XCTAssertEqual(Double(actual.x), Double(expected.x), accuracy: 1e-6)
            XCTAssertEqual(Double(actual.y), Double(expected.y), accuracy: 1e-6)
        }
        XCTAssertLessThan(
            Homography.reprojectionError(estimated, from: source, to: destination), 1e-6)
    }

    func testRejectsCollinearPoints() {
        let collinear = (0..<4).map { CGPoint(x: Double($0), y: Double($0) * 2) }
        let destination = (0..<4).map { CGPoint(x: Double($0) * 3, y: Double($0)) }
        XCTAssertThrowsError(try Homography.estimate(from: collinear, to: destination))
    }

    func testRejectsTooFewPoints() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
        XCTAssertThrowsError(try Homography.estimate(from: points, to: points))
    }
}

final class CameraGeometryTests: XCTestCase {

    func testIntrinsicsFromFieldOfView() {
        let intrinsics = CameraIntrinsics(
            horizontalFieldOfViewDegrees: 90,
            imageSize: CGSize(width: 1000, height: 500)
        )
        // A 90° horizontal field of view puts the focal length at half the width.
        XCTAssertEqual(intrinsics.focalLengthX, 500, accuracy: 1e-6)
        XCTAssertEqual(intrinsics.principalPointX, 500, accuracy: 1e-9)
        XCTAssertEqual(intrinsics.principalPointY, 250, accuracy: 1e-9)
    }

    func testIntrinsicsScaleWithBufferSize() {
        let intrinsics = CameraIntrinsics(
            horizontalFieldOfViewDegrees: 60, imageSize: CGSize(width: 1920, height: 1080))
        let scaled = intrinsics.scaled(to: CGSize(width: 960, height: 540))
        XCTAssertEqual(scaled.focalLengthX, intrinsics.focalLengthX / 2, accuracy: 1e-9)
        XCTAssertEqual(scaled.principalPointY, intrinsics.principalPointY / 2, accuracy: 1e-9)
    }

    func testPoseDecompositionRecoversCameraPosition() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let pose = try XCTUnwrap(resolved.pose)

        XCTAssertFalse(resolved.isMirrored)
        XCTAssertEqual(pose.cameraCenter.x, scene.cameraPosition.x, accuracy: 0.02)
        XCTAssertEqual(pose.cameraCenter.y, scene.cameraPosition.y, accuracy: 0.02)
        XCTAssertEqual(pose.cameraCenter.z, scene.cameraPosition.z, accuracy: 0.02)
        XCTAssertLessThan(resolved.reprojectionErrorPixels, 0.5)
    }

    func testClockwiseCornerOrderIsMirroredBackToZUp() throws {
        let scene = SyntheticScene()
        var calibration = scene.calibration()
        // Tap the same corners the other way round the rectangle.
        calibration.normalizedImagePoints = [
            calibration.normalizedImagePoints[1],
            calibration.normalizedImagePoints[0],
            calibration.normalizedImagePoints[3],
            calibration.normalizedImagePoints[2],
        ]
        let resolved = try ResolvedCalibration.resolve(calibration)
        let pose = try XCTUnwrap(resolved.pose)

        XCTAssertTrue(resolved.isMirrored)
        XCTAssertGreaterThan(pose.cameraCenter.z, 0)
        XCTAssertEqual(pose.cameraCenter.z, scene.cameraPosition.z, accuracy: 0.05)
    }

    func testPlaneHomographyMatchesDirectProjection() throws {
        let scene = SyntheticScene()
        let resolved = try scene.resolvedCalibration()
        let pose = try XCTUnwrap(resolved.pose)
        let height = 1.75

        let homography = PlanarPose.homography(
            forPlaneHeight: height, pose: pose, intrinsics: resolved.intrinsics)

        for courtPoint in [CGPoint(x: 2, y: 4), CGPoint(x: 8, y: 15), CGPoint(x: 5, y: 21)] {
            let viaHomography = try XCTUnwrap(homography.project(courtPoint))
            let direct = try XCTUnwrap(
                scene.project(Vec3(Double(courtPoint.x), Double(courtPoint.y), height)))
            XCTAssertEqual(Double(viaHomography.x), Double(direct.x), accuracy: 1.0)
            XCTAssertEqual(Double(viaHomography.y), Double(direct.y), accuracy: 1.0)
        }
    }

    func testGroundPlaneMappingRoundTrips() throws {
        let scene = SyntheticScene(measurementHeight: 0)
        let resolved = try scene.resolvedCalibration()
        let courtPoint = CGPoint(x: 6.5, y: 17.25)
        let pixel = try XCTUnwrap(scene.project(Vec3(6.5, 17.25, 0)))
        let recovered = try XCTUnwrap(resolved.courtPoint(forImagePoint: pixel))
        XCTAssertEqual(Double(recovered.x), Double(courtPoint.x), accuracy: 0.05)
        XCTAssertEqual(Double(recovered.y), Double(courtPoint.y), accuracy: 0.05)
    }
}
