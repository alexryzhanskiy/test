import Foundation
import os

/// Persists measurements to a JSON file in Application Support and keeps the
/// in-memory list the UI observes.
@MainActor
final class MeasurementStore: ObservableObject {
    @Published private(set) var measurements: [SpeedMeasurement] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.speedradar.app", category: "MeasurementStore")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? MeasurementStore.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let manager = FileManager.default
        let base =
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SpeedRadar", isDirectory: true)
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("measurements.json")
    }

    var fastest: SpeedMeasurement? {
        measurements.max { $0.speedMetersPerSecond < $1.speedMetersPerSecond }
    }

    var averageSpeedMetersPerSecond: Double? {
        guard !measurements.isEmpty else { return nil }
        let total = measurements.reduce(0.0) { $0 + $1.speedMetersPerSecond }
        return total / Double(measurements.count)
    }

    func add(_ measurement: SpeedMeasurement) {
        measurements.insert(measurement, at: 0)
        save()
    }

    func update(_ measurement: SpeedMeasurement) {
        guard let index = measurements.firstIndex(where: { $0.id == measurement.id }) else { return }
        measurements[index] = measurement
        save()
    }

    func delete(_ measurement: SpeedMeasurement) {
        measurements.removeAll { $0.id == measurement.id }
        if let url = measurement.videoURL {
            try? FileManager.default.removeItem(at: url)
        }
        save()
    }

    func delete(atOffsets offsets: IndexSet) {
        for index in offsets {
            if let url = measurements[index].videoURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        measurements.remove(atOffsets: offsets)
        save()
    }

    func deleteAll() {
        for measurement in measurements {
            if let url = measurement.videoURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        measurements.removeAll()
        save()
    }

    /// CSV export of every saved shot, written to a temporary file.
    func exportCSV() throws -> URL {
        var lines = [
            "recorded_at,court,method,initial_speed_mps,peak_speed_mps,average_speed_mps,"
                + "horizontal_speed_mps,launch_angle_deg,distance_m,duration_s,samples,residual,confidence"
        ]
        let formatter = ISO8601DateFormatter()
        for measurement in measurements.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            let estimate = measurement.estimate
            let fields: [String] = [
                formatter.string(from: measurement.recordedAt),
                "\"\(measurement.courtName)\"",
                estimate.method.rawValue,
                String(format: "%.3f", estimate.initialSpeedMetersPerSecond),
                String(format: "%.3f", estimate.peakSpeedMetersPerSecond),
                String(format: "%.3f", estimate.averageSpeedMetersPerSecond),
                String(format: "%.3f", estimate.horizontalSpeedMetersPerSecond),
                estimate.launchAngleDegrees.map { String(format: "%.2f", $0) } ?? "",
                String(format: "%.3f", estimate.distanceMeters),
                String(format: "%.4f", estimate.durationSeconds),
                String(estimate.sampleCount),
                String(format: "%.3f", estimate.residual),
                String(format: "%.3f", estimate.confidence),
            ]
            lines.append(fields.joined(separator: ","))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speedradar-export.csv")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            measurements = try decoder.decode([SpeedMeasurement].self, from: data)
                .sorted { $0.recordedAt > $1.recordedAt }
        } catch {
            logger.error("Failed to load measurements: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let snapshot = measurements
        let url = fileURL
        let logger = self.logger
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error(
                    "Failed to save measurements: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
