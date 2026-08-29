import CoreGraphics
import Foundation

/// A rectangular reference region on the playing surface whose real-world
/// dimensions are known. Calibration only needs four corners of *some* known
/// rectangle — a full court, a service box, or a taped-out rectangle all work.
struct CourtPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var detail: String
    /// Extent along the court frame's X axis, in metres.
    var width: Double
    /// Extent along the court frame's Y axis, in metres.
    var length: Double
    /// Height above the surface at which the ball is expected to travel. Used
    /// by the planar estimator and as the initial guess for the 3D fit.
    var defaultMeasurementHeight: Double
    /// Labels for the four corners, in tap order.
    var cornerLabels: [String]

    /// Corner positions in the court frame, in tap order, in metres.
    var courtCorners: [CGPoint] {
        [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width, y: 0),
            CGPoint(x: width, y: length),
            CGPoint(x: 0, y: length),
        ]
    }

    var area: Double { width * length }

    var diagonal: Double { (width * width + length * length).squareRoot() }

    static let defaultCornerLabels = [
        "Near left corner",
        "Near right corner",
        "Far right corner",
        "Far left corner",
    ]

    init(
        id: String,
        name: String,
        detail: String,
        width: Double,
        length: Double,
        defaultMeasurementHeight: Double,
        cornerLabels: [String] = CourtPreset.defaultCornerLabels
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.width = width
        self.length = length
        self.defaultMeasurementHeight = defaultMeasurementHeight
        self.cornerLabels = cornerLabels
    }

    /// Dimensions come from the governing bodies' current rule books (ITF, BWF,
    /// FIVB, FIBA, USAPA, ITTF, IHF and the IFAB Laws of the Game).
    static let all: [CourtPreset] = [
        CourtPreset(
            id: "tennis-singles",
            name: "Tennis (singles)",
            detail: "8.23 m × 23.77 m — singles sidelines, baseline to baseline",
            width: 8.23,
            length: 23.77,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "tennis-doubles",
            name: "Tennis (doubles)",
            detail: "10.97 m × 23.77 m — doubles sidelines, baseline to baseline",
            width: 10.97,
            length: 23.77,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "tennis-service-box",
            name: "Tennis service box",
            detail: "4.115 m × 6.40 m — one service box",
            width: 4.115,
            length: 6.40,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "padel",
            name: "Padel",
            detail: "10 m × 20 m — full court",
            width: 10.0,
            length: 20.0,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "pickleball",
            name: "Pickleball",
            detail: "6.10 m × 13.41 m — full court",
            width: 6.10,
            length: 13.41,
            defaultMeasurementHeight: 0.9
        ),
        CourtPreset(
            id: "badminton-doubles",
            name: "Badminton (doubles)",
            detail: "6.10 m × 13.40 m — full court",
            width: 6.10,
            length: 13.40,
            defaultMeasurementHeight: 1.5
        ),
        CourtPreset(
            id: "volleyball",
            name: "Volleyball",
            detail: "9 m × 18 m — full court",
            width: 9.0,
            length: 18.0,
            defaultMeasurementHeight: 2.0
        ),
        CourtPreset(
            id: "basketball-fiba",
            name: "Basketball (FIBA)",
            detail: "15 m × 28 m — full court",
            width: 15.0,
            length: 28.0,
            defaultMeasurementHeight: 1.8
        ),
        CourtPreset(
            id: "basketball-nba",
            name: "Basketball (NBA)",
            detail: "15.24 m × 28.65 m — full court",
            width: 15.24,
            length: 28.65,
            defaultMeasurementHeight: 1.8
        ),
        CourtPreset(
            id: "handball",
            name: "Handball",
            detail: "20 m × 40 m — full court",
            width: 20.0,
            length: 40.0,
            defaultMeasurementHeight: 1.8
        ),
        CourtPreset(
            id: "football-penalty-area",
            name: "Football penalty area",
            detail: "40.32 m × 16.5 m — the 18-yard box",
            width: 40.32,
            length: 16.5,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "football-goal",
            name: "Football goal mouth",
            detail: "7.32 m × 2.44 m — goal frame, treated as an upright rectangle",
            width: 7.32,
            length: 2.44,
            defaultMeasurementHeight: 0.0,
            cornerLabels: [
                "Bottom left post",
                "Bottom right post",
                "Top right corner",
                "Top left corner",
            ]
        ),
        CourtPreset(
            id: "table-tennis",
            name: "Table tennis",
            detail: "1.525 m × 2.74 m — table surface",
            width: 1.525,
            length: 2.74,
            defaultMeasurementHeight: 0.2
        ),
        CourtPreset(
            id: "cricket-pitch",
            name: "Cricket pitch",
            detail: "3.05 m × 20.12 m — crease to crease",
            width: 3.05,
            length: 20.12,
            defaultMeasurementHeight: 1.0
        ),
        CourtPreset(
            id: "baseball-mound-to-plate",
            name: "Baseball (mound to plate)",
            detail: "3 m × 18.44 m — a marked rectangle along the pitching line",
            width: 3.0,
            length: 18.44,
            defaultMeasurementHeight: 1.2
        ),
    ]

    static let `default` = all[0]

    /// A user-defined rectangle. Any four measured corners will do.
    static func custom(width: Double, length: Double, measurementHeight: Double) -> CourtPreset {
        CourtPreset(
            id: "custom",
            name: "Custom rectangle",
            detail: String(format: "%.2f m × %.2f m — measured by hand", width, length),
            width: width,
            length: length,
            defaultMeasurementHeight: measurementHeight
        )
    }

    var isCustom: Bool { id == "custom" }

    static func preset(withID id: String) -> CourtPreset? {
        all.first { $0.id == id }
    }
}
