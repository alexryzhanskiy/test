import CoreGraphics
import Foundation

/// Speed from a single homography: every detection is assumed to lie on one
/// horizontal plane a fixed height above the court.
///
/// This is the fallback used when camera pose could not be recovered. It has no
/// gravity model, so it measures the ball's speed *as projected onto that
/// plane*; the error grows with how far the ball strays from the assumed height.
enum PlanarSpeedEstimator {

    static func estimate(
        trajectory: TrackedTrajectory,
        calibration: ResolvedCalibration,
        options: EstimationOptions = .default
    ) -> SpeedEstimate? {
        let samples = trajectory.samples.sorted { $0.time < $1.time }
        guard samples.count >= options.minimumSampleCount else { return nil }

        let court = calibration.court
        let marginX = court.width + options.courtMarginMeters
        let marginY = court.length + options.courtMarginMeters

        var times: [Double] = []
        var positions: [CGPoint] = []
        var kept: [TrackedSample] = []

        let startTime = samples[0].time
        for sample in samples {
            guard let courtPoint = calibration.courtPoint(forNormalizedPoint: sample.normalizedPoint),
                courtPoint.x.isFinite, courtPoint.y.isFinite,
                courtPoint.x > -options.courtMarginMeters, courtPoint.x < marginX,
                courtPoint.y > -options.courtMarginMeters, courtPoint.y < marginY
            else { continue }
            times.append(sample.time - startTime)
            positions.append(courtPoint)
            kept.append(sample)
        }

        guard kept.count >= options.minimumSampleCount,
            let duration = times.last, duration >= options.minimumDuration
        else { return nil }

        guard let fitX = LineFit.fit(times: times, values: positions.map { Double($0.x) }),
            let fitY = LineFit.fit(times: times, values: positions.map { Double($0.y) })
        else { return nil }

        let speed = hypot(fitX.slope, fitY.slope)
        guard speed >= options.minimumSpeedMetersPerSecond,
            speed <= options.maximumSpeedMetersPerSecond
        else { return nil }

        var residualSum = 0.0
        for (index, time) in times.enumerated() {
            let dx = Double(positions[index].x) - fitX.value(at: time)
            let dy = Double(positions[index].y) - fitY.value(at: time)
            residualSum += hypot(dx, dy)
        }
        let residual = residualSum / Double(times.count)

        let points = zip(kept, positions).enumerated().map { index, pair -> ResolvedTrackPoint in
            let (sample, position) = pair
            return ResolvedTrackPoint(
                time: times[index],
                courtX: Double(position.x),
                courtY: Double(position.y),
                courtZ: calibration.measurementHeight,
                normalizedImageX: Double(sample.normalizedPoint.x),
                normalizedImageY: Double(sample.normalizedPoint.y)
            )
        }

        let peak = peakSegmentSpeed(times: times, positions: positions) ?? speed
        let distance = hypot(
            Double(positions.last!.x - positions.first!.x),
            Double(positions.last!.y - positions.first!.y)
        )

        let confidence = QualityScore.score(
            sampleCount: kept.count,
            duration: duration,
            residual: residual,
            residualScale: 0.25,
            methodPenalty: 0.75
        )

        return SpeedEstimate(
            method: .planar,
            initialSpeedMetersPerSecond: speed,
            peakSpeedMetersPerSecond: max(peak, speed),
            averageSpeedMetersPerSecond: distance / duration,
            horizontalSpeedMetersPerSecond: speed,
            launchAngleDegrees: nil,
            apexHeightMeters: nil,
            distanceMeters: distance,
            durationSeconds: duration,
            sampleCount: kept.count,
            residual: residual,
            confidence: confidence,
            points: points
        )
    }

    /// Fastest speed over any short window, computed on a lightly smoothed path
    /// so that single-frame jitter does not dominate the peak.
    private static func peakSegmentSpeed(times: [Double], positions: [CGPoint]) -> Double? {
        guard times.count >= 3 else { return nil }
        var smoothed: [CGPoint] = []
        smoothed.reserveCapacity(positions.count)
        for index in positions.indices {
            let lower = max(0, index - 1)
            let upper = min(positions.count - 1, index + 1)
            let slice = positions[lower...upper]
            let count = CGFloat(slice.count)
            smoothed.append(
                CGPoint(
                    x: slice.reduce(0) { $0 + $1.x } / count,
                    y: slice.reduce(0) { $0 + $1.y } / count
                ))
        }

        var peak = 0.0
        for index in 1..<smoothed.count {
            let dt = times[index] - times[index - 1]
            guard dt > 1e-4 else { continue }
            let distance = hypot(
                Double(smoothed[index].x - smoothed[index - 1].x),
                Double(smoothed[index].y - smoothed[index - 1].y)
            )
            peak = max(peak, distance / dt)
        }
        return peak > 0 ? peak : nil
    }
}

/// Ordinary least squares fit of `value = intercept + slope * time`.
enum LineFit {
    struct Result: Equatable {
        var intercept: Double
        var slope: Double

        func value(at time: Double) -> Double { intercept + slope * time }
    }

    static func fit(times: [Double], values: [Double]) -> Result? {
        guard times.count == values.count, times.count >= 2 else { return nil }
        let n = Double(times.count)
        let meanT = times.reduce(0, +) / n
        let meanV = values.reduce(0, +) / n

        var covariance = 0.0
        var variance = 0.0
        for index in times.indices {
            let dt = times[index] - meanT
            covariance += dt * (values[index] - meanV)
            variance += dt * dt
        }
        guard variance > 1e-12 else { return nil }

        let slope = covariance / variance
        return Result(intercept: meanV - slope * meanT, slope: slope)
    }
}

/// Maps fit statistics onto a 0...1 confidence score.
enum QualityScore {
    static func score(
        sampleCount: Int,
        duration: TimeInterval,
        residual: Double,
        residualScale: Double,
        methodPenalty: Double = 1.0
    ) -> Double {
        let sampleTerm = min(1.0, Double(sampleCount) / 12.0)
        let durationTerm = min(1.0, duration / 0.25)
        let residualTerm = 1.0 / (1.0 + max(residual, 0) / max(residualScale, 1e-6))
        let raw = pow(sampleTerm * durationTerm * residualTerm, 1.0 / 3.0) * methodPenalty
        return min(1, max(0, raw))
    }
}
