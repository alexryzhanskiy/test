import CoreGraphics
import Foundation

/// Estimates the projective transform (homography) between two sets of coplanar
/// points — here, between court coordinates in metres and pixel coordinates in
/// the captured video frame.
enum Homography {

    enum EstimationError: Error, LocalizedError {
        case tooFewPoints
        case mismatchedPointCounts
        case degenerateConfiguration

        var errorDescription: String? {
            switch self {
            case .tooFewPoints:
                return "At least four points are needed to calibrate the court."
            case .mismatchedPointCounts:
                return "The number of court points and image points must match."
            case .degenerateConfiguration:
                return "The selected points are collinear or too close together."
            }
        }
    }

    /// Computes `H` such that `H * source ≈ destination` in homogeneous
    /// coordinates, using the normalized Direct Linear Transform.
    ///
    /// Hartley normalization (centroid at the origin, mean distance `sqrt(2)`)
    /// matters a great deal here: raw pixel coordinates in the thousands mixed
    /// with court coordinates in the tens produce a badly conditioned system.
    static func estimate(from source: [CGPoint], to destination: [CGPoint]) throws -> Mat3 {
        guard source.count == destination.count else { throw EstimationError.mismatchedPointCounts }
        guard source.count >= 4 else { throw EstimationError.tooFewPoints }

        guard let sourceNormalization = normalization(for: source),
            let destinationNormalization = normalization(for: destination)
        else { throw EstimationError.degenerateConfiguration }

        let normalizedSource = source.map { sourceNormalization.transform.project($0) }
        let normalizedDestination = destination.map { destinationNormalization.transform.project($0) }

        var rows: [[Double]] = []
        var values: [Double] = []
        rows.reserveCapacity(source.count * 2)
        values.reserveCapacity(source.count * 2)

        for index in 0..<source.count {
            guard let s = normalizedSource[index], let d = normalizedDestination[index] else {
                throw EstimationError.degenerateConfiguration
            }
            let x = Double(s.x)
            let y = Double(s.y)
            let u = Double(d.x)
            let v = Double(d.y)

            rows.append([x, y, 1, 0, 0, 0, -x * u, -y * u])
            values.append(u)
            rows.append([0, 0, 0, x, y, 1, -x * v, -y * v])
            values.append(v)
        }

        guard let h = LinearSolver.leastSquares(rows: rows, values: values, unknowns: 8) else {
            throw EstimationError.degenerateConfiguration
        }

        let normalizedHomography = Mat3([h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1])
        guard let inverseDestination = destinationNormalization.transform.inverted else {
            throw EstimationError.degenerateConfiguration
        }

        let result = inverseDestination * normalizedHomography * sourceNormalization.transform
        guard result.elements.allSatisfy({ $0.isFinite }), abs(result.determinant) > 1e-14 else {
            throw EstimationError.degenerateConfiguration
        }
        return result
    }

    /// Mean reprojection error, in destination units, for a candidate homography.
    static func reprojectionError(
        _ homography: Mat3,
        from source: [CGPoint],
        to destination: [CGPoint]
    ) -> Double {
        guard source.count == destination.count, !source.isEmpty else { return .infinity }
        var total = 0.0
        for index in 0..<source.count {
            guard let projected = homography.project(source[index]) else { return .infinity }
            total += hypot(
                Double(projected.x - destination[index].x),
                Double(projected.y - destination[index].y)
            )
        }
        return total / Double(source.count)
    }

    private struct Normalization {
        let transform: Mat3
    }

    private static func normalization(for points: [CGPoint]) -> Normalization? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        let centroidX = points.reduce(0.0) { $0 + Double($1.x) } / count
        let centroidY = points.reduce(0.0) { $0 + Double($1.y) } / count

        let meanDistance =
            points.reduce(0.0) {
                $0 + hypot(Double($1.x) - centroidX, Double($1.y) - centroidY)
            } / count
        guard meanDistance > 1e-9 else { return nil }

        let scale = 2.0.squareRoot() / meanDistance
        return Normalization(
            transform: Mat3([
                scale, 0, -scale * centroidX,
                0, scale, -scale * centroidY,
                0, 0, 1,
            ]))
    }
}
