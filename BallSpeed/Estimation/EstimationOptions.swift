import Foundation

/// Tunables shared by both speed estimators.
struct EstimationOptions: Equatable {
    /// Fewer samples than this and a fit is not worth trusting.
    var minimumSampleCount: Int = 5
    /// Very short windows make the velocity fit dominated by timing jitter.
    var minimumDuration: TimeInterval = 0.03
    /// Anything slower is treated as noise rather than a shot.
    var minimumSpeedMetersPerSecond: Double = 1.0
    /// Well above any ball sport's record, so only nonsense is rejected.
    var maximumSpeedMetersPerSecond: Double = 150.0
    /// How far outside the calibrated rectangle a detection may land, in metres.
    var courtMarginMeters: Double = 15.0
    /// Drop points whose reprojection residual is far above the median, then refit.
    var rejectsOutliers: Bool = true

    static let `default` = EstimationOptions()

    /// Standard gravity, m/s². The court frame has Z pointing up.
    static let gravity = 9.806_65
}
