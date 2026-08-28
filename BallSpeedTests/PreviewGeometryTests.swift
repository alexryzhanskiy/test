import CoreGraphics
import XCTest

@testable import BallSpeed

final class PreviewGeometryTests: XCTestCase {

    private func geometry(rotation: Double, viewSize: CGSize) -> PreviewGeometry {
        PreviewGeometry(
            bufferSize: CGSize(width: 1920, height: 1080),
            rotationDegrees: rotation,
            viewSize: viewSize
        )
    }

    func testLetterboxRectMatchesAspectFit() {
        let geometry = self.geometry(rotation: 0, viewSize: CGSize(width: 400, height: 400))
        let rect = geometry.displayedRect
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 225, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 87.5, accuracy: 0.001)
    }

    func testQuarterTurnSwapsDisplayedAspect() {
        let geometry = self.geometry(rotation: 90, viewSize: CGSize(width: 400, height: 400))
        XCTAssertTrue(geometry.isQuarterTurned)
        let rect = geometry.displayedRect
        XCTAssertEqual(rect.width, 225, accuracy: 0.001)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
    }

    func testViewPointRoundTripsForEveryRotation() throws {
        let bufferPoints = [
            CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.75),
        ]
        for rotation in [0.0, 90, 180, 270] {
            let geometry = self.geometry(rotation: rotation, viewSize: CGSize(width: 800, height: 600))
            for point in bufferPoints {
                let viewPoint = geometry.viewPoint(forNormalizedBufferPoint: point)
                let recovered = try XCTUnwrap(
                    geometry.normalizedBufferPoint(forViewPoint: viewPoint),
                    "rotation \(rotation) lost the point"
                )
                XCTAssertEqual(Double(recovered.x), Double(point.x), accuracy: 1e-6)
                XCTAssertEqual(Double(recovered.y), Double(point.y), accuracy: 1e-6)
            }
        }
    }

    func testTopLeftMapsToRotatedCornerAt180Degrees() {
        let geometry = self.geometry(rotation: 180, viewSize: CGSize(width: 1920, height: 1080))
        let point = geometry.viewPoint(forNormalizedBufferPoint: CGPoint(x: 0, y: 0))
        XCTAssertEqual(point.x, 1920, accuracy: 0.001)
        XCTAssertEqual(point.y, 1080, accuracy: 0.001)
    }

    func testTapsInTheLetterboxAreRejected() {
        let geometry = self.geometry(rotation: 0, viewSize: CGSize(width: 400, height: 400))
        // The video occupies y 87.5...312.5; a tap above that is on the bar.
        XCTAssertNil(geometry.normalizedBufferPoint(forViewPoint: CGPoint(x: 200, y: 10)))
        XCTAssertNotNil(geometry.normalizedBufferPoint(forViewPoint: CGPoint(x: 200, y: 200)))
    }

    func testNegativeRotationIsNormalized() {
        XCTAssertEqual(
            self.geometry(rotation: -90, viewSize: CGSize(width: 400, height: 400)).quarterTurns, 3)
    }
}

final class CourtPresetTests: XCTestCase {

    func testPresetIdentifiersAreUnique() {
        let ids = CourtPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryPresetHasFourCornerLabelsAndPositiveDimensions() {
        for preset in CourtPreset.all {
            XCTAssertEqual(preset.cornerLabels.count, 4, "\(preset.id)")
            XCTAssertEqual(preset.courtCorners.count, 4, "\(preset.id)")
            XCTAssertGreaterThan(preset.width, 0, "\(preset.id)")
            XCTAssertGreaterThan(preset.length, 0, "\(preset.id)")
        }
    }

    func testCornersAreCounterClockwiseInTapOrder() {
        // Shoelace area must be positive for the court frame to be right-handed.
        for preset in CourtPreset.all {
            let corners = preset.courtCorners
            var area = 0.0
            for index in corners.indices {
                let current = corners[index]
                let next = corners[(index + 1) % corners.count]
                area += Double(current.x * next.y - next.x * current.y)
            }
            XCTAssertGreaterThan(area / 2, 0, "\(preset.id)")
        }
    }

    func testKnownDimensions() throws {
        let tennis = try XCTUnwrap(CourtPreset.preset(withID: "tennis-doubles"))
        XCTAssertEqual(tennis.width, 10.97, accuracy: 0.001)
        XCTAssertEqual(tennis.length, 23.77, accuracy: 0.001)

        let volleyball = try XCTUnwrap(CourtPreset.preset(withID: "volleyball"))
        XCTAssertEqual(volleyball.area, 162, accuracy: 0.001)
    }

    func testCustomCourtUsesSuppliedDimensions() {
        let custom = CourtPreset.custom(width: 3.5, length: 7.25, measurementHeight: 0.4)
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(custom.width, 3.5, accuracy: 1e-9)
        XCTAssertEqual(custom.courtCorners[2], CGPoint(x: 3.5, y: 7.25))
    }
}

final class SpeedUnitTests: XCTestCase {

    func testConversions() {
        XCTAssertEqual(SpeedUnit.kilometersPerHour.value(fromMetersPerSecond: 10), 36, accuracy: 1e-9)
        XCTAssertEqual(
            SpeedUnit.milesPerHour.value(fromMetersPerSecond: 10), 22.369_362_920_5, accuracy: 1e-6)
        XCTAssertEqual(SpeedUnit.metersPerSecond.value(fromMetersPerSecond: 10), 10, accuracy: 1e-9)
    }

    func testFormatting() {
        XCTAssertEqual(
            SpeedUnit.kilometersPerHour.formatWithUnit(metersPerSecond: 30), "108.0 km/h")
        XCTAssertEqual(
            SpeedUnit.metersPerSecond.format(metersPerSecond: 12.5, fractionDigits: 2), "12.50")
    }
}

final class QualityScoreTests: XCTestCase {

    func testMoreSamplesAndLowerResidualScoreHigher() {
        let weak = QualityScore.score(
            sampleCount: 5, duration: 0.05, residual: 8, residualScale: 3)
        let strong = QualityScore.score(
            sampleCount: 20, duration: 0.4, residual: 0.4, residualScale: 3)
        XCTAssertLessThan(weak, strong)
        XCTAssertGreaterThanOrEqual(weak, 0)
        XCTAssertLessThanOrEqual(strong, 1)
    }
}
