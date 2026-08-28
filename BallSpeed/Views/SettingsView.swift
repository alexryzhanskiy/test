import SwiftUI

/// Preferences, calibration management and an explanation of the method.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: CaptureController

    @State private var showsCourtPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    Picker("Speed", selection: $settings.speedUnit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                }

                Section {
                    Button {
                        showsCourtPicker = true
                    } label: {
                        LabeledContent("Reference court") {
                            Text(settings.court.name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    LabeledContent("Assumed ball height") {
                        DimensionField(value: $settings.measurementHeight)
                    }
                } header: {
                    Text("Court")
                } footer: {
                    Text(
                        "The assumed height only matters for the 2D fallback fit. When camera pose is available the 3D fit measures the ball's height itself."
                    )
                }

                Section {
                    if let calibration = controller.resolvedCalibration {
                        LabeledContent("Corner error") {
                            Text(String(format: "%.2f px", calibration.reprojectionErrorPixels))
                                .monospacedDigit()
                        }
                        if let height = calibration.cameraHeightMeters {
                            LabeledContent("Camera height") {
                                Text(String(format: "%.2f m", height))
                                    .monospacedDigit()
                            }
                        }
                        if let distance = calibration.cameraDistanceMeters {
                            LabeledContent("Camera distance") {
                                Text(String(format: "%.1f m", distance))
                                    .monospacedDigit()
                            }
                        }
                        LabeledContent("Estimator") {
                            Text(
                                calibration.supportsBallisticEstimation
                                    ? "3D ballistic" : "Ground plane only"
                            )
                            .foregroundStyle(.secondary)
                        }
                        LabeledContent("Intrinsics") {
                            Text(
                                controller.usesMeasuredIntrinsics
                                    ? "From camera" : "From field of view"
                            )
                            .foregroundStyle(.secondary)
                        }
                        Button("Clear calibration", role: .destructive) {
                            controller.clearCalibration()
                        }
                    } else {
                        Text("Not calibrated yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Calibration")
                } footer: {
                    if controller.storedCalibrationIsStale {
                        Text(
                            "This calibration was made a while ago. It is only valid while the camera has not moved."
                        )
                    } else {
                        Text("A calibration stays valid only while the camera stays put.")
                    }
                }

                Section {
                    Toggle("Prefer high frame rate", isOn: $settings.prefersHighFrameRate)
                    Toggle("Keep video clips", isOn: $settings.keepsVideo)
                    Toggle("Show court outline", isOn: $settings.showsCourtOverlay)
                    Toggle("Show flight path", isOn: $settings.showsTrackOverlay)
                    Stepper(
                        "Minimum detections: \(settings.minimumSampleCount)",
                        value: $settings.minimumSampleCount,
                        in: 4...20
                    )
                } header: {
                    Text("Capture")
                } footer: {
                    Text(
                        "Frame rate is the biggest lever on accuracy: more frames means more detections across the same flight, and a shorter gap between them."
                    )
                }

                Section("How it works") {
                    DisclosureGroup("Measuring speed from one camera") {
                        Text(Self.methodExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Getting an accurate reading") {
                        Text(Self.accuracyTips)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showsCourtPicker) {
                CourtPickerView()
                    .environmentObject(settings)
            }
        }
    }

    private static let methodExplanation = """
        Four tapped court corners with known real-world spacing give a homography \
        between the court plane and the image. Combined with the camera's own \
        intrinsic matrix, that fixes where the phone is and which way it is pointing.

        Vision then finds the ball's flight path in the video. Each detection is a \
        ray out of the camera rather than a position, so the app fits a single \
        gravity-constrained parabola whose projection matches every detection at once. \
        Six unknowns, two equations per detection: five or more detections make it a \
        least-squares problem with a unique answer, which yields true 3D speed \
        including vertical motion.

        Gravity is also the only thing that fixes how far away the ball is: a fast ball \
        far away looks the same as a slow one nearby, and only the curve of the path \
        separates them. Over a very short flight that curve is a fraction of a pixel, so \
        the app checks whether it is measurable and declines the 3D fit when it is not.

        In that case — and when pose cannot be recovered at all — it falls back to a flat \
        homography at an assumed ball height and reports the ground-plane speed, marked 2D.
        """

    private static let accuracyTips = """
        • Mount or brace the phone. Any camera movement after calibration invalidates \
        the geometry.
        • Tap the corners as precisely as you can — corner accuracy is the single \
        largest source of error.
        • Film across the flight rather than down the line. A ball flying straight at \
        the camera barely moves in the image, and the fit becomes ill-conditioned.
        • Use the highest frame rate available, and film in good light so the ball is \
        a compact blob rather than a long smear.
        • Let the ball run. The longer it is tracked, the more the flight curves, and \
        that curvature is what pins down distance — and therefore speed — from one camera. \
        Very short clips fall back to the less accurate 2D fit.
        """
}
