import CoreGraphics
import Foundation

/// Which model produced a speed figure.
enum EstimationMethod: String, Codable, Hashable {
    /// Full 3D fit of a ballistic path against the recovered camera pose.
    case ballistic
    /// Flat homography at a fixed assumed height above the surface.
    case planar

    var displayName: String {
        switch self {
        case .ballistic: return "3D ballistic fit"
        case .planar: return "Ground-plane fit"
        }
    }

    var shortName: String {
        switch self {
        case .ballistic: return "3D"
        case .planar: return "2D"
        }
    }
}

/// One resolved point of the flight path.
struct ResolvedTrackPoint: Codable, Hashable {
    var time: TimeInterval
    var courtX: Double
    var courtY: Double
    var courtZ: Double
    var normalizedImageX: Double
    var normalizedImageY: Double

    var courtPosition: Vec3 { Vec3(courtX, courtY, courtZ) }

    var normalizedImagePoint: CGPoint {
        CGPoint(x: normalizedImageX, y: normalizedImageY)
    }
}

/// The outcome of fitting a motion model to a tracked flight path.
struct SpeedEstimate: Codable, Hashable {
    var method: EstimationMethod
    /// Speed at the first tracked sample — the headline number, closest to the
    /// moment of contact for a shot tracked from impact.
    var initialSpeedMetersPerSecond: Double
    var peakSpeedMetersPerSecond: Double
    var averageSpeedMetersPerSecond: Double
    /// Speed of the ball's shadow on the court, ignoring vertical motion.
    var horizontalSpeedMetersPerSecond: Double
    /// Angle of the velocity vector above the surface, when a 3D fit was made.
    var launchAngleDegrees: Double?
    /// Highest point reached over the tracked window, when a 3D fit was made.
    var apexHeightMeters: Double?
    var distanceMeters: Double
    var durationSeconds: Double
    var sampleCount: Int
    /// Mean fit residual: pixels for the ballistic fit, metres for the planar fit.
    var residual: Double
    /// 0...1 quality score combining sample count, duration and residual.
    var confidence: Double
    var points: [ResolvedTrackPoint]

    var residualUnit: String { method == .ballistic ? "px" : "m" }

    var confidenceLabel: String {
        switch confidence {
        case ..<0.35: return "Low"
        case ..<0.7: return "Fair"
        default: return "Good"
        }
    }
}

/// Speed unit conversion and formatting, kept in one place so the UI and the
/// exports always agree.
enum SpeedUnit: String, CaseIterable, Codable, Identifiable {
    case kilometersPerHour
    case milesPerHour
    case metersPerSecond

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .kilometersPerHour: return "km/h"
        case .milesPerHour: return "mph"
        case .metersPerSecond: return "m/s"
        }
    }

    var displayName: String {
        switch self {
        case .kilometersPerHour: return "Kilometres per hour"
        case .milesPerHour: return "Miles per hour"
        case .metersPerSecond: return "Metres per second"
        }
    }

    func value(fromMetersPerSecond value: Double) -> Double {
        switch self {
        case .kilometersPerHour: return value * 3.6
        case .milesPerHour: return value * 2.236_936_292_05
        case .metersPerSecond: return value
        }
    }

    func format(metersPerSecond value: Double, fractionDigits: Int = 1) -> String {
        String(format: "%.\(fractionDigits)f", self.value(fromMetersPerSecond: value))
    }

    func formatWithUnit(metersPerSecond value: Double, fractionDigits: Int = 1) -> String {
        "\(format(metersPerSecond: value, fractionDigits: fractionDigits)) \(abbreviation)"
    }
}
