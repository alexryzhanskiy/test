import Foundation

/// A saved shot: the fitted speed plus enough context to make sense of it later.
struct SpeedMeasurement: Identifiable, Codable, Hashable {
    var id: UUID
    var recordedAt: Date
    var courtName: String
    var courtWidth: Double
    var courtLength: Double
    var estimate: SpeedEstimate
    /// File name inside the recordings directory, when the clip was kept.
    var videoFileName: String?
    /// Camera height above the surface at capture time, if pose was recovered.
    var cameraHeightMeters: Double?
    var cameraDistanceMeters: Double?
    /// Mean corner reprojection error of the calibration used, in pixels.
    var calibrationErrorPixels: Double?
    var note: String?

    init(
        id: UUID = UUID(),
        recordedAt: Date = Date(),
        courtName: String,
        courtWidth: Double,
        courtLength: Double,
        estimate: SpeedEstimate,
        videoFileName: String? = nil,
        cameraHeightMeters: Double? = nil,
        cameraDistanceMeters: Double? = nil,
        calibrationErrorPixels: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.recordedAt = recordedAt
        self.courtName = courtName
        self.courtWidth = courtWidth
        self.courtLength = courtLength
        self.estimate = estimate
        self.videoFileName = videoFileName
        self.cameraHeightMeters = cameraHeightMeters
        self.cameraDistanceMeters = cameraDistanceMeters
        self.calibrationErrorPixels = calibrationErrorPixels
        self.note = note
    }

    var speedMetersPerSecond: Double { estimate.initialSpeedMetersPerSecond }

    var videoURL: URL? {
        guard let videoFileName else { return nil }
        return RecordingsDirectory.url(forFileName: videoFileName)
    }

    static func make(
        estimate: SpeedEstimate,
        calibration: ResolvedCalibration,
        videoFileName: String?,
        recordedAt: Date = Date()
    ) -> SpeedMeasurement {
        SpeedMeasurement(
            recordedAt: recordedAt,
            courtName: calibration.court.name,
            courtWidth: calibration.court.width,
            courtLength: calibration.court.length,
            estimate: estimate,
            videoFileName: videoFileName,
            cameraHeightMeters: calibration.cameraHeightMeters,
            cameraDistanceMeters: calibration.cameraDistanceMeters,
            calibrationErrorPixels: calibration.reprojectionErrorPixels
        )
    }
}

/// Location of the kept video clips on disk.
enum RecordingsDirectory {
    static var url: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func url(forFileName name: String) -> URL {
        url.appendingPathComponent(name)
    }

    static func makeFileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "shot-\(formatter.string(from: date)).mov"
    }
}
