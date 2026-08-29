import XCTest

@testable import SpeedRadar

@MainActor
final class MeasurementStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("measurements-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func makeMeasurement(speed: Double, at date: Date = Date()) -> SpeedMeasurement {
        SpeedMeasurement(
            recordedAt: date,
            courtName: "Tennis (doubles)",
            courtWidth: 10.97,
            courtLength: 23.77,
            estimate: SpeedEstimate(
                method: .ballistic,
                initialSpeedMetersPerSecond: speed,
                peakSpeedMetersPerSecond: speed + 1,
                averageSpeedMetersPerSecond: speed - 1,
                horizontalSpeedMetersPerSecond: speed - 0.5,
                launchAngleDegrees: 8,
                apexHeightMeters: 2.1,
                distanceMeters: 6,
                durationSeconds: 0.2,
                sampleCount: 12,
                residual: 0.8,
                confidence: 0.82,
                points: []
            )
        )
    }

    func testAddPersistsAcrossInstances() throws {
        let store = MeasurementStore(fileURL: fileURL)
        store.add(makeMeasurement(speed: 30))
        XCTAssertEqual(store.measurements.count, 1)

        // The write is asynchronous, so wait for the file to appear.
        let expectation = expectation(description: "file written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let reloaded = MeasurementStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.measurements.count, 1)
        XCTAssertEqual(reloaded.measurements[0].speedMetersPerSecond, 30, accuracy: 1e-9)
    }

    func testFastestAndAverage() {
        let store = MeasurementStore(fileURL: fileURL)
        store.add(makeMeasurement(speed: 20))
        store.add(makeMeasurement(speed: 40))
        XCTAssertEqual(store.fastest?.speedMetersPerSecond, 40)
        XCTAssertEqual(store.averageSpeedMetersPerSecond ?? 0, 30, accuracy: 1e-9)
    }

    func testDeleteRemovesMeasurement() {
        let store = MeasurementStore(fileURL: fileURL)
        let measurement = makeMeasurement(speed: 25)
        store.add(measurement)
        store.delete(measurement)
        XCTAssertTrue(store.measurements.isEmpty)
    }

    func testCSVExportHasHeaderAndOneRowPerMeasurement() throws {
        let store = MeasurementStore(fileURL: fileURL)
        store.add(makeMeasurement(speed: 25))
        store.add(makeMeasurement(speed: 35))

        let url = try store.exportCSV()
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("recorded_at,court,method"))
    }
}

@MainActor
final class CalibrationStoreTests: XCTestCase {

    func testStoreAndReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let scene = SyntheticScene()
        let store = CalibrationStore(fileURL: url)
        store.store(scene.calibration())

        let reloaded = CalibrationStore(fileURL: url)
        let calibration = try XCTUnwrap(reloaded.calibration)
        XCTAssertEqual(calibration.normalizedImagePoints.count, 4)
        XCTAssertEqual(calibration.court.id, scene.court.id)
        XCTAssertFalse(reloaded.isStale)
    }
}
