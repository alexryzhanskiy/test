import Foundation

/// User preferences, backed by `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let speedUnit = "settings.speedUnit"
        static let courtPresetID = "settings.courtPresetID"
        static let customWidth = "settings.customWidth"
        static let customLength = "settings.customLength"
        static let measurementHeight = "settings.measurementHeight"
        static let keepsVideo = "settings.keepsVideo"
        static let showsCourtOverlay = "settings.showsCourtOverlay"
        static let showsTrackOverlay = "settings.showsTrackOverlay"
        static let prefersHighFrameRate = "settings.prefersHighFrameRate"
        static let minimumSampleCount = "settings.minimumSampleCount"
    }

    private let defaults: UserDefaults

    @Published var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Key.speedUnit) }
    }
    @Published var courtPresetID: String {
        didSet { defaults.set(courtPresetID, forKey: Key.courtPresetID) }
    }
    @Published var customWidth: Double {
        didSet { defaults.set(customWidth, forKey: Key.customWidth) }
    }
    @Published var customLength: Double {
        didSet { defaults.set(customLength, forKey: Key.customLength) }
    }
    /// Height above the surface assumed by the planar fallback estimator.
    @Published var measurementHeight: Double {
        didSet { defaults.set(measurementHeight, forKey: Key.measurementHeight) }
    }
    @Published var keepsVideo: Bool {
        didSet { defaults.set(keepsVideo, forKey: Key.keepsVideo) }
    }
    @Published var showsCourtOverlay: Bool {
        didSet { defaults.set(showsCourtOverlay, forKey: Key.showsCourtOverlay) }
    }
    @Published var showsTrackOverlay: Bool {
        didSet { defaults.set(showsTrackOverlay, forKey: Key.showsTrackOverlay) }
    }
    @Published var prefersHighFrameRate: Bool {
        didSet { defaults.set(prefersHighFrameRate, forKey: Key.prefersHighFrameRate) }
    }
    @Published var minimumSampleCount: Int {
        didSet { defaults.set(minimumSampleCount, forKey: Key.minimumSampleCount) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.speedUnit =
            SpeedUnit(rawValue: defaults.string(forKey: Key.speedUnit) ?? "")
            ?? .kilometersPerHour
        self.courtPresetID = defaults.string(forKey: Key.courtPresetID) ?? CourtPreset.default.id
        self.customWidth = defaults.object(forKey: Key.customWidth) as? Double ?? 10.0
        self.customLength = defaults.object(forKey: Key.customLength) as? Double ?? 20.0
        self.measurementHeight =
            defaults.object(forKey: Key.measurementHeight) as? Double
            ?? CourtPreset.default.defaultMeasurementHeight
        self.keepsVideo = defaults.object(forKey: Key.keepsVideo) as? Bool ?? true
        self.showsCourtOverlay = defaults.object(forKey: Key.showsCourtOverlay) as? Bool ?? true
        self.showsTrackOverlay = defaults.object(forKey: Key.showsTrackOverlay) as? Bool ?? true
        self.prefersHighFrameRate =
            defaults.object(forKey: Key.prefersHighFrameRate) as? Bool ?? true
        self.minimumSampleCount = defaults.object(forKey: Key.minimumSampleCount) as? Int ?? 5
    }

    /// The court currently selected, resolving the custom rectangle from the
    /// user's own dimensions.
    var court: CourtPreset {
        if courtPresetID == "custom" {
            return CourtPreset.custom(
                width: customWidth,
                length: customLength,
                measurementHeight: measurementHeight
            )
        }
        return CourtPreset.preset(withID: courtPresetID) ?? .default
    }

    var estimationOptions: EstimationOptions {
        var options = EstimationOptions.default
        options.minimumSampleCount = max(4, minimumSampleCount)
        return options
    }

    func selectCourt(_ preset: CourtPreset) {
        courtPresetID = preset.id
        if !preset.isCustom {
            measurementHeight = preset.defaultMeasurementHeight
        }
    }
}
