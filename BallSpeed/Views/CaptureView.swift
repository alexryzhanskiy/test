import AVFoundation
import SwiftUI
import UIKit

/// The measuring screen: live preview, overlays, record button and the result of
/// the last take.
struct CaptureView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var settings: AppSettings

    @State private var showsCalibration = false
    @State private var showsDetail = false
    @State private var showsCourtPicker = false

    var body: some View {
        GeometryReader { proxy in
            let geometry = PreviewGeometry(
                bufferSize: controller.bufferSize,
                rotationDegrees: controller.previewRotationDegrees,
                viewSize: proxy.size
            )

            ZStack {
                Color.black.ignoresSafeArea()

                CameraPreviewView(
                    session: controller.cameraSession.session,
                    rotationDegrees: controller.previewRotationDegrees
                )
                .ignoresSafeArea()

                TrackingOverlay(
                    geometry: geometry,
                    courtOutline: controller.resolvedCalibration?.courtOutlineNormalized ?? [],
                    trackPoints: controller.liveTrackPoints,
                    showsCourt: settings.showsCourtOverlay,
                    showsTrack: settings.showsTrackOverlay
                )
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    if case .failed(let message) = controller.status {
                        failureCard(message)
                    } else {
                        resultArea
                        recordButton
                    }
                }
                .padding()
            }
        }
        .task { await controller.prepare() }
        .sheet(isPresented: $showsCalibration) {
            CalibrationView()
                .environmentObject(controller)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showsCourtPicker) {
            CourtPickerView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showsDetail) {
            if let measurement = controller.lastMeasurement {
                NavigationStack {
                    MeasurementDetailView(measurement: measurement)
                        .environmentObject(settings)
                }
            }
        }
        .onChange(of: settings.courtPresetID) { _, _ in
            controller.restoreStoredCalibration()
        }
        .onChange(of: settings.measurementHeight) { _, _ in
            controller.restoreStoredCalibration()
        }
        .onChange(of: settings.prefersHighFrameRate) { _, _ in
            Task { await controller.reconfigureForFrameRatePreference() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    showsCourtPicker = true
                } label: {
                    Label(settings.court.name, systemImage: "ruler")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

                if let configuration = controller.configuration {
                    Text(
                        "\(Int(configuration.bufferSize.width))×\(Int(configuration.bufferSize.height)) · \(Int(configuration.frameRate.rounded())) fps"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                calibrationStatus
            }

            Spacer()

            Button {
                showsCalibration = true
            } label: {
                Label(
                    controller.hasCalibration ? "Recalibrate" : "Calibrate",
                    systemImage: "viewfinder"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.status.isRecording)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var calibrationStatus: some View {
        if let calibration = controller.resolvedCalibration {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(
                    String(
                        format: "Calibrated · corner error %.1f px",
                        calibration.reprojectionErrorPixels)
                )
                if !calibration.supportsBallisticEstimation {
                    Text("· 2D only")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } else {
            Label("Not calibrated", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        if controller.status.isRecording {
            recordingCard
        } else if controller.status == .analyzing {
            ProgressView("Fitting the flight path…")
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        } else if let measurement = controller.lastMeasurement, !controller.lastTakeHadNoTrajectory {
            ResultCard(measurement: measurement, unit: settings.speedUnit) {
                showsDetail = true
            }
        } else if controller.lastTakeHadNoTrajectory {
            noTrajectoryCard
        } else if !controller.hasCalibration {
            hintCard(
                title: "Calibrate first",
                message:
                    "Point the camera so the whole court is visible, then tap Calibrate and mark the four corners."
            )
        } else {
            hintCard(
                title: "Ready",
                message:
                    "Hold the phone still, start recording just before the shot, and stop a moment after the ball passes."
            )
        }
    }

    private var recordingCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(String(format: "%.1f s", controller.recordingDuration))
                    .monospacedDigit()
                Text("· \(controller.detectionCount) path\(controller.detectionCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if let estimate = controller.liveEstimate {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(
                        settings.speedUnit.format(
                            metersPerSecond: estimate.initialSpeedMetersPerSecond)
                    )
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    Text(settings.speedUnit.abbreviation)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tracking…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var noTrajectoryCard: some View {
        hintCard(
            title: "No flight path found",
            message:
                "Vision needs a few frames of a small object on a smooth arc. Try filling more of the frame with the ball's path, raising the frame rate, or recording in brighter light."
        )
    }

    private func hintCard(title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Label("Camera unavailable", systemImage: "video.slash")
                .font(.headline)
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            if controller.status.isRecording {
                Task { await controller.stopRecording() }
            } else {
                controller.startRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: controller.status.isRecording ? 6 : 30)
                    .fill(.red)
                    .frame(
                        width: controller.status.isRecording ? 32 : 60,
                        height: controller.status.isRecording ? 32 : 60
                    )
            }
            .animation(.easeInOut(duration: 0.15), value: controller.status)
        }
        .disabled(!controller.hasCalibration || controller.status == .analyzing)
        .opacity(controller.hasCalibration ? 1 : 0.4)
        .accessibilityLabel(controller.status.isRecording ? "Stop recording" : "Start recording")
    }
}

/// Headline result for the most recent take.
struct ResultCard: View {
    let measurement: SpeedMeasurement
    let unit: SpeedUnit
    var onDetails: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(unit.format(metersPerSecond: measurement.speedMetersPerSecond))
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(unit.abbreviation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Badge(text: measurement.estimate.method.shortName, tint: .blue)
                Badge(
                    text: "\(measurement.estimate.confidenceLabel) fit",
                    tint: confidenceTint
                )
                Badge(text: "\(measurement.estimate.sampleCount) pts", tint: .gray)
            }

            HStack(spacing: 18) {
                stat("Peak", unit.formatWithUnit(metersPerSecond: measurement.estimate.peakSpeedMetersPerSecond))
                if let angle = measurement.estimate.launchAngleDegrees {
                    stat("Angle", String(format: "%.0f°", angle))
                }
                stat("Distance", String(format: "%.1f m", measurement.estimate.distanceMeters))
            }

            Button("Details", action: onDetails)
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var confidenceTint: Color {
        switch measurement.estimate.confidence {
        case ..<0.35: return .orange
        case ..<0.7: return .yellow
        default: return .green
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.2), in: Capsule())
            .foregroundStyle(tint)
    }
}
