import CoreGraphics
import Foundation

/// Recovers the ball's full 3D flight from a single camera.
///
/// A monocular view cannot place a point in space on its own — each pixel is a
/// ray, not a position. What makes this solvable is the motion model: a flying
/// ball follows `P(t) = P0 + V·t + ½·g·t²` with `g` known. That leaves six
/// unknowns, and every detection contributes two linear constraints once the
/// projection is written in cross-product form, so five or more detections
/// over-determine the system and it can be solved by least squares.
///
/// The result is a real 3D speed — vertical motion included — rather than the
/// speed of the ball's shadow, and it does not depend on guessing how high the
/// ball was flying.
///
/// The catch is where the scale comes from. Gravity is the only thing fixing how
/// far away the ball is: a fast ball far away and a slow ball nearby project to
/// the same straight line, and only the parabola's curvature tells them apart.
/// Over a very short window that curvature is a fraction of a pixel and the
/// depth is effectively unobservable, so the fit is gated on the curvature being
/// large enough to see — see `observability(...)`. When it is not, the caller
/// falls back to the planar estimator instead of reporting a confident number
/// built on noise.
enum BallisticSpeedEstimator {

    struct Solution: Equatable {
        /// Position at time zero of the fit, in court metres.
        var origin: Vec3
        /// Velocity at that same instant, in metres per second.
        var velocity: Vec3

        func position(at time: Double) -> Vec3 {
            origin + velocity * time
                + Vec3(0, 0, -0.5 * EstimationOptions.gravity * time * time)
        }

        /// Instantaneous velocity, named distinctly from the stored property so
        /// the two never shadow one another.
        func velocityVector(at time: Double) -> Vec3 {
            velocity + Vec3(0, 0, -EstimationOptions.gravity * time)
        }
    }

    static func estimate(
        trajectory: TrackedTrajectory,
        calibration: ResolvedCalibration,
        options: EstimationOptions = .default
    ) -> SpeedEstimate? {
        guard let pose = calibration.pose else { return nil }

        let samples = trajectory.samples.sorted { $0.time < $1.time }
        guard samples.count >= options.minimumSampleCount else { return nil }

        let bufferSize = calibration.bufferSize
        guard bufferSize.width > 0, bufferSize.height > 0 else { return nil }

        let startTime = samples[0].time
        let elapsed = samples.map { $0.time - startTime }
        guard let span = elapsed.last, span >= options.minimumDuration else { return nil }

        // Fit around the middle of the window. Centring decorrelates position
        // from velocity and keeps the normal equations far better conditioned
        // than measuring everything from the first frame.
        let centre = span / 2
        var times = elapsed.map { $0 - centre }
        var displayTimes = elapsed
        var pixels = samples.map {
            CGPoint(
                x: $0.normalizedPoint.x * bufferSize.width,
                y: $0.normalizedPoint.y * bufferSize.height
            )
        }
        var keptSamples = samples

        guard
            var solution = solve(
                pixels: pixels,
                times: times,
                pose: pose,
                intrinsics: calibration.intrinsics
            )
        else { return nil }

        var residuals = reprojectionResiduals(
            solution: solution,
            pixels: pixels,
            times: times,
            pose: pose,
            intrinsics: calibration.intrinsics
        )
        guard !residuals.isEmpty else { return nil }

        // A single bad detection — a racket head, a distant player, a
        // reflection — can drag the whole fit. Drop the clear outliers once and
        // refit against what is left.
        if options.rejectsOutliers {
            let threshold = max(4.0, 3.0 * median(residuals))
            let keep = residuals.indices.filter { residuals[$0] <= threshold }
            if keep.count < residuals.count && keep.count >= options.minimumSampleCount {
                let filteredTimes = keep.map { times[$0] }
                let filteredPixels = keep.map { pixels[$0] }
                let filteredSpan = (filteredTimes.last ?? 0) - (filteredTimes.first ?? 0)
                if filteredSpan >= options.minimumDuration,
                    let refit = solve(
                        pixels: filteredPixels,
                        times: filteredTimes,
                        pose: pose,
                        intrinsics: calibration.intrinsics
                    )
                {
                    solution = refit
                    times = filteredTimes
                    displayTimes = keep.map { displayTimes[$0] }
                    pixels = filteredPixels
                    keptSamples = keep.map { samples[$0] }
                    residuals = reprojectionResiduals(
                        solution: solution,
                        pixels: pixels,
                        times: times,
                        pose: pose,
                        intrinsics: calibration.intrinsics
                    )
                    guard !residuals.isEmpty else { return nil }
                }
            }
        }

        let windowStart = times.first ?? 0
        let windowEnd = times.last ?? 0
        let window = windowEnd - windowStart
        guard window >= options.minimumDuration else { return nil }

        let initialVelocity = solution.velocityVector(at: windowStart)
        let initialSpeed = initialVelocity.length
        guard initialSpeed.isFinite,
            initialSpeed >= options.minimumSpeedMetersPerSecond,
            initialSpeed <= options.maximumSpeedMetersPerSecond
        else { return nil }

        // Reject fits that put the ball underground, absurdly high, or well off
        // the playing area. Those are the signature of a depth solution that
        // collapsed towards the camera or ran away from it.
        let positions = times.map { solution.position(at: $0) }
        guard let minHeight = positions.map(\.z).min(),
            let maxHeight = positions.map(\.z).max(),
            minHeight > -1.5, maxHeight < 80
        else { return nil }

        let margin = options.courtMarginMeters
        let withinCourt = positions.allSatisfy {
            $0.x > -margin && $0.x < calibration.court.width + margin
                && $0.y > -margin && $0.y < calibration.court.length + margin
        }
        guard withinCourt else { return nil }

        // Every position must sit in front of the camera.
        guard positions.allSatisfy({ pose.transformToCamera($0).z > 0.5 }) else { return nil }

        let residual = residuals.reduce(0, +) / Double(residuals.count)
        guard residual < 60 else { return nil }

        let depths = positions.map { pose.transformToCamera($0).z }
        let meanDepth = depths.reduce(0, +) / Double(depths.count)
        let curvatureSNR = observability(
            window: window,
            sampleCount: keptSamples.count,
            meanDepth: meanDepth,
            pose: pose,
            intrinsics: calibration.intrinsics
        )
        guard curvatureSNR >= minimumObservability else { return nil }

        var peakSpeed = 0.0
        var speedSum = 0.0
        for time in times {
            let speed = solution.velocityVector(at: time).length
            peakSpeed = max(peakSpeed, speed)
            speedSum += speed
        }
        let averageSpeed = speedSum / Double(times.count)

        let startPosition = solution.position(at: windowStart)
        let endPosition = solution.position(at: windowEnd)
        let distance = (endPosition - startPosition).length

        let horizontalSpeed = hypot(initialVelocity.x, initialVelocity.y)
        let launchAngle = atan2(initialVelocity.z, horizontalSpeed) * 180 / .pi

        // Apex of the parabola, clamped to the tracked window when the ball was
        // already descending.
        var apex = max(startPosition.z, endPosition.z)
        if initialVelocity.z > 0 {
            let timeToApex = initialVelocity.z / EstimationOptions.gravity
            if timeToApex <= window {
                apex = max(apex, solution.position(at: windowStart + timeToApex).z)
            }
        }

        var points: [ResolvedTrackPoint] = []
        points.reserveCapacity(keptSamples.count)
        for (index, sample) in keptSamples.enumerated() {
            let position = positions[index]
            points.append(
                ResolvedTrackPoint(
                    time: displayTimes[index],
                    courtX: position.x,
                    courtY: position.y,
                    courtZ: position.z,
                    normalizedImageX: Double(sample.normalizedPoint.x),
                    normalizedImageY: Double(sample.normalizedPoint.y)
                ))
        }

        // Weak curvature still measures a real speed, just a less certain one,
        // so it tempers the score rather than being hidden.
        let observabilityFactor = min(1.0, curvatureSNR / (minimumObservability * 3))
        let confidence =
            QualityScore.score(
                sampleCount: keptSamples.count,
                duration: window,
                residual: residual,
                residualScale: 3.0
            ) * (0.55 + 0.45 * observabilityFactor)

        return SpeedEstimate(
            method: .ballistic,
            initialSpeedMetersPerSecond: initialSpeed,
            peakSpeedMetersPerSecond: peakSpeed,
            averageSpeedMetersPerSecond: averageSpeed,
            horizontalSpeedMetersPerSecond: horizontalSpeed,
            launchAngleDegrees: launchAngle,
            apexHeightMeters: apex,
            distanceMeters: distance,
            durationSeconds: window,
            sampleCount: keptSamples.count,
            residual: residual,
            confidence: min(1, max(0, confidence)),
            points: points
        )
    }

    /// Signal-to-noise ratio of the gravity curvature the depth solution rests on.
    ///
    /// Over a window of `T` seconds the ball deviates from a straight line by
    /// `g·T²/8` metres. Projected into the image that is a certain number of
    /// pixels; averaged over `n` detections its effective precision improves
    /// with `sqrt(n)`. The product is what decides whether depth — and therefore
    /// absolute speed — is measurable at all, assuming roughly a pixel of
    /// detection jitter.
    static func observability(
        window: Double,
        sampleCount: Int,
        meanDepth: Double,
        pose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> Double {
        guard window > 0, meanDepth > 0.1, sampleCount > 0 else { return 0 }
        let sagitta = EstimationOptions.gravity * window * window / 8
        // Only the part of that offset across the line of sight moves the image.
        let offsetInCamera = pose.rotation * Vec3(0, 0, -sagitta)
        let acrossView = hypot(offsetInCamera.x, offsetInCamera.y)
        let focal = (intrinsics.focalLengthX + intrinsics.focalLengthY) / 2
        let sagittaPixels = acrossView * focal / meanDepth
        return sagittaPixels * Double(sampleCount).squareRoot()
    }

    /// Below this the depth is guesswork; the caller falls back to the flat fit.
    static let minimumObservability = 20.0

    /// Linear least-squares solve for `[P0, V]`.
    ///
    /// For a detection `u` at time `t`, the projection constraint
    /// `u × K(R·P(t) + T) = 0` gives two independent linear equations. With
    /// `M = K·R` and `c = K(R·½g t² + T)` those are:
    ///
    ///     (uₓ·M₃ − M₁)·P0 + t·(uₓ·M₃ − M₁)·V = −(uₓ·c_z − c_x)
    ///     (u_y·M₃ − M₂)·P0 + t·(u_y·M₃ − M₂)·V = −(u_y·c_z − c_y)
    ///
    /// Each equation is scaled to unit norm before being handed to the solver:
    /// the raw rows carry pixel-times-focal-length magnitudes that differ by
    /// orders of magnitude between the position and velocity blocks.
    static func solve(
        pixels: [CGPoint],
        times: [Double],
        pose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> Solution? {
        guard pixels.count == times.count, pixels.count >= 3 else { return nil }

        let k = intrinsics.matrix
        let m = k * pose.rotation

        var rows: [[Double]] = []
        var values: [Double] = []
        rows.reserveCapacity(pixels.count * 2)
        values.reserveCapacity(pixels.count * 2)

        func append(coefficients: Vec3, time: Double, value: Double) {
            let row = [
                coefficients.x, coefficients.y, coefficients.z,
                coefficients.x * time, coefficients.y * time, coefficients.z * time,
            ]
            let norm = row.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-9 else { return }
            rows.append(row.map { $0 / norm })
            values.append(value / norm)
        }

        for (index, pixel) in pixels.enumerated() {
            let t = times[index]
            let gravityTerm = Vec3(0, 0, -0.5 * EstimationOptions.gravity * t * t)
            let c = k * (pose.rotation * gravityTerm + pose.translation)

            let u = Double(pixel.x)
            let v = Double(pixel.y)

            append(coefficients: m.row(2) * u - m.row(0), time: t, value: -(u * c.z - c.x))
            append(coefficients: m.row(2) * v - m.row(1), time: t, value: -(v * c.z - c.y))
        }

        guard rows.count >= 6,
            let solved = LinearSolver.leastSquares(rows: rows, values: values, unknowns: 6),
            solved.allSatisfy({ $0.isFinite })
        else { return nil }

        return Solution(
            origin: Vec3(solved[0], solved[1], solved[2]),
            velocity: Vec3(solved[3], solved[4], solved[5])
        )
    }

    static func reprojectionResiduals(
        solution: Solution,
        pixels: [CGPoint],
        times: [Double],
        pose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> [Double] {
        var residuals: [Double] = []
        residuals.reserveCapacity(pixels.count)
        for (index, pixel) in pixels.enumerated() {
            guard
                let projected = PlanarPose.project(
                    courtPoint: solution.position(at: times[index]),
                    pose: pose,
                    intrinsics: intrinsics
                )
            else { return [] }
            residuals.append(
                hypot(Double(projected.x - pixel.x), Double(projected.y - pixel.y)))
        }
        return residuals
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
