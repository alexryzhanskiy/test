import CoreMedia
import Foundation
import Vision
import os

/// Finds the ball's flight path in the video stream.
///
/// Built on `VNDetectTrajectoriesRequest`, which is designed for exactly this:
/// it looks for small objects whose motion across frames fits a parabola, which
/// rules out players, shadows and camera shake without any colour tuning. The
/// request keeps state across frames, so the same instance is fed every frame of
/// a take and is replaced when a new take starts.
final class BallTracker {

    /// How many frames of history the request fits a parabola over. Longer means
    /// steadier trajectories but a slower first result.
    var trajectoryLength: Int = 8 {
        didSet { reset() }
    }
    /// Smallest and largest apparent ball radius, as a fraction of image height.
    var minimumObjectRadius: Float = 0.004
    var maximumObjectRadius: Float = 0.12
    /// Vision confidence below which an observation is ignored.
    var minimumConfidence: Float = 0.3

    private var request: VNDetectTrajectoriesRequest?
    private var trajectories: [UUID: TrackedTrajectory] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.speedradar.app", category: "BallTracker")

    /// Discards all state and starts a fresh take.
    func reset() {
        lock.lock()
        trajectories.removeAll()
        request = nil
        lock.unlock()
    }

    /// Feeds one frame to Vision. Call on a serial queue.
    ///
    /// - Returns: The trajectories updated by this frame, if any.
    @discardableResult
    func process(sampleBuffer: CMSampleBuffer) -> [TrackedTrajectory] {
        let request = existingOrNewRequest()
        do {
            let handler = VNImageRequestHandler(
                cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
            try handler.perform([request])
        } catch {
            logger.error(
                "Trajectory request failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        guard let observations = request.results else { return [] }
        return ingest(observations)
    }

    private func existingOrNewRequest() -> VNDetectTrajectoriesRequest {
        lock.lock()
        defer { lock.unlock() }
        if let request { return request }

        let request = VNDetectTrajectoriesRequest(
            frameAnalysisSpacing: .zero,
            trajectoryLength: max(5, trajectoryLength)
        )
        request.objectMinimumNormalizedRadius = minimumObjectRadius
        request.objectMaximumNormalizedRadius = maximumObjectRadius
        self.request = request
        return request
    }

    private func ingest(_ observations: [VNTrajectoryObservation]) -> [TrackedTrajectory] {
        var updated: [TrackedTrajectory] = []

        lock.lock()
        for observation in observations {
            guard observation.confidence >= minimumConfidence else { continue }
            let samples = BallTracker.samples(from: observation)
            guard samples.count >= 2 else { continue }

            var trajectory =
                trajectories[observation.uuid]
                ?? TrackedTrajectory(
                    id: observation.uuid, samples: [], visionConfidence: Double(observation.confidence))
            trajectory.visionConfidence = max(
                trajectory.visionConfidence, Double(observation.confidence))
            trajectory.merge(samples)
            trajectories[observation.uuid] = trajectory
            updated.append(trajectory)
        }
        lock.unlock()

        return updated
    }

    /// Converts a Vision observation into timestamped samples.
    ///
    /// Vision reports one time range per observation rather than a timestamp per
    /// point, but the points come from consecutive analysed frames, so spreading
    /// them evenly across the range recovers the per-point timing.
    static func samples(from observation: VNTrajectoryObservation) -> [TrackedSample] {
        let points = observation.detectedPoints
        guard points.count >= 2 else { return [] }

        let start = observation.timeRange.start.seconds
        let duration = observation.timeRange.duration.seconds
        guard start.isFinite, duration.isFinite, duration > 0 else { return [] }

        let step = duration / Double(points.count - 1)
        return points.enumerated().map { index, point in
            TrackedSample(
                // Vision's origin is bottom-left; everything else here uses top-left.
                normalizedPoint: CGPoint(x: point.x, y: 1 - point.y),
                time: start + Double(index) * step
            )
        }
    }

    /// All trajectories seen since the last reset, newest first.
    var allTrajectories: [TrackedTrajectory] {
        lock.lock()
        defer { lock.unlock() }
        return trajectories.values.sorted { lhs, rhs in
            (lhs.samples.first?.time ?? 0) > (rhs.samples.first?.time ?? 0)
        }
    }

    /// The trajectory most likely to be the shot the user meant to measure:
    /// the one that travelled furthest across the frame, with ties going to the
    /// one with more detections.
    var bestTrajectory: TrackedTrajectory? {
        lock.lock()
        defer { lock.unlock() }
        return trajectories.values.max { lhs, rhs in
            let lhsScore = lhs.normalizedSpan * Double(lhs.sampleCount)
            let rhsScore = rhs.normalizedSpan * Double(rhs.sampleCount)
            return lhsScore < rhsScore
        }
    }
}
