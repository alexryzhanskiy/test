import SwiftUI

@main
struct BallSpeedApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var measurementStore: MeasurementStore
    @StateObject private var calibrationStore: CalibrationStore
    @StateObject private var controller: CaptureController

    init() {
        let settings = AppSettings()
        let measurementStore = MeasurementStore()
        let calibrationStore = CalibrationStore()
        _settings = StateObject(wrappedValue: settings)
        _measurementStore = StateObject(wrappedValue: measurementStore)
        _calibrationStore = StateObject(wrappedValue: calibrationStore)
        _controller = StateObject(
            wrappedValue: CaptureController(
                settings: settings,
                measurementStore: measurementStore,
                calibrationStore: calibrationStore
            ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(measurementStore)
                .environmentObject(calibrationStore)
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }
}
