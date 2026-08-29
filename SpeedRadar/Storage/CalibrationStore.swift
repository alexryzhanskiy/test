import Foundation
import os

/// Keeps the most recent court calibration so the app can pick up where it left
/// off — useful when the phone stays on its tripod between sessions.
///
/// A calibration is only valid while the camera does not move, so the stored one
/// is offered as a starting point rather than trusted outright.
@MainActor
final class CalibrationStore: ObservableObject {
    @Published private(set) var calibration: CourtCalibration?

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.speedradar.app", category: "CalibrationStore")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? CalibrationStore.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        MeasurementStore.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("calibration.json")
    }

    /// Calibrations older than this are almost certainly stale.
    static let staleInterval: TimeInterval = 60 * 60 * 6

    var isStale: Bool {
        guard let calibration else { return false }
        return Date().timeIntervalSince(calibration.createdAt) > CalibrationStore.staleInterval
    }

    func store(_ calibration: CourtCalibration) {
        self.calibration = calibration
        save()
    }

    func clear() {
        calibration = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            calibration = try decoder.decode(
                CourtCalibration.self, from: Data(contentsOf: fileURL))
        } catch {
            logger.error(
                "Failed to load calibration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let calibration else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(calibration).write(to: fileURL, options: .atomic)
        } catch {
            logger.error(
                "Failed to save calibration: \(error.localizedDescription, privacy: .public)")
        }
    }
}
