import Foundation

/// Runs the available estimators over a tracked path and returns the best fit.
///
/// The 3D estimator declines when the flight is too short for its depth solution
/// to be observable, so reaching the planar branch is a normal outcome, not an
/// error path.
enum TrajectoryAnalyzer {

    static func analyze(
        trajectory: TrackedTrajectory,
        calibration: ResolvedCalibration,
        options: EstimationOptions = .default,
        allowsBallistic: Bool = true
    ) -> SpeedEstimate? {
        let ballistic =
            allowsBallistic
            ? BallisticSpeedEstimator.estimate(
                trajectory: trajectory,
                calibration: calibration,
                options: options
            ) : nil

        let planar = PlanarSpeedEstimator.estimate(
            trajectory: trajectory,
            calibration: calibration,
            options: options
        )

        switch (ballistic, planar) {
        case (let ballistic?, let planar?):
            // The 3D fit is the better model, but a badly conditioned one — a
            // near-head-on flight, say — can fit worse than the flat model. Only
            // hand over when the planar fit is clearly more trustworthy.
            return planar.confidence > ballistic.confidence + 0.25 ? planar : ballistic
        case (let ballistic?, nil):
            return ballistic
        case (nil, let planar?):
            return planar
        case (nil, nil):
            return nil
        }
    }
}
