import CoreGraphics
import Foundation

/// One detection of the ball: where it was in the frame and when.
///
/// Points are normalized to 0...1 with the origin at the top-left of the
/// analysis buffer, matching the convention used everywhere outside Vision.
struct TrackedSample: Equatable, Codable {
    var normalizedPoint: CGPoint
    var time: TimeInterval
}

/// A candidate flight path emitted by the tracker.
struct TrackedTrajectory: Identifiable, Equatable {
    var id: UUID
    var samples: [TrackedSample]
    /// Confidence reported by Vision for the underlying observation.
    var visionConfidence: Double

    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time - first.time
    }

    var sampleCount: Int { samples.count }

    /// Straight-line extent of the path in normalized image units. Used to
    /// throw away jittery, near-stationary detections before doing any real work.
    var normalizedSpan: Double {
        guard let first = samples.first?.normalizedPoint,
            let last = samples.last?.normalizedPoint
        else { return 0 }
        return hypot(Double(last.x - first.x), Double(last.y - first.y))
    }

    /// Merges newly detected samples into this trajectory, keeping one sample
    /// per timestamp and preserving chronological order.
    mutating func merge(_ newSamples: [TrackedSample]) {
        var byTime: [Int: TrackedSample] = [:]
        for sample in samples + newSamples {
            // Quantise to a tenth of a millisecond so float noise in the
            // timestamps cannot produce duplicate entries.
            byTime[Int((sample.time * 10_000).rounded())] = sample
        }
        samples = byTime.values.sorted { $0.time < $1.time }
    }
}
