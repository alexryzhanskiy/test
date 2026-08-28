import AVKit
import SwiftUI

/// Everything known about one saved shot: the clip, the numbers, and the fitted
/// path drawn both from above and in profile.
struct MeasurementDetailView: View {
    let measurement: SpeedMeasurement
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var playbackRate: Float = 0.5

    private var estimate: SpeedEstimate { measurement.estimate }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline
                if measurement.videoURL != nil {
                    videoSection
                }
                statsSection
                planView
                if estimate.method == .ballistic {
                    heightProfile
                }
                methodNotes
            }
            .padding()
        }
        .navigationTitle(measurement.recordedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: preparePlayer)
        .onDisappear { player?.pause() }
    }

    // MARK: - Sections

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(settings.speedUnit.format(metersPerSecond: estimate.initialSpeedMetersPerSecond))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(settings.speedUnit.abbreviation)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Badge(text: estimate.method.displayName, tint: .blue)
                Badge(text: "\(estimate.confidenceLabel) fit", tint: .green)
                Badge(text: measurement.courtName, tint: .gray)
            }
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip").font(.headline)
            if let player {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    ForEach([Float(0.1), 0.25, 0.5, 1.0], id: \.self) { rate in
                        Button {
                            playbackRate = rate
                            player.rate = rate
                        } label: {
                            Text("\(rate, specifier: "%g")×")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(playbackRate == rate ? Color.accentColor : Color.gray)
                    }
                    Spacer()
                    Button {
                        player.seek(to: .zero)
                        player.rate = playbackRate
                    } label: {
                        Label("Replay", systemImage: "gobackward")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Text(
                    "Recorded at capture frame rate. Slow the playback down to see the frames the fit used."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measurements").font(.headline)
            StatGrid(rows: rows)
        }
    }

    private var rows: [StatGrid.Row] {
        var rows: [StatGrid.Row] = [
            .init(
                title: "Initial speed",
                value: settings.speedUnit.formatWithUnit(
                    metersPerSecond: estimate.initialSpeedMetersPerSecond)),
            .init(
                title: "Peak speed",
                value: settings.speedUnit.formatWithUnit(
                    metersPerSecond: estimate.peakSpeedMetersPerSecond)),
            .init(
                title: "Average speed",
                value: settings.speedUnit.formatWithUnit(
                    metersPerSecond: estimate.averageSpeedMetersPerSecond)),
            .init(
                title: "Horizontal speed",
                value: settings.speedUnit.formatWithUnit(
                    metersPerSecond: estimate.horizontalSpeedMetersPerSecond)),
            .init(title: "Path length", value: String(format: "%.2f m", estimate.distanceMeters)),
            .init(
                title: "Tracked for", value: String(format: "%.3f s", estimate.durationSeconds)),
            .init(title: "Detections", value: "\(estimate.sampleCount)"),
            .init(
                title: "Fit residual",
                value: String(format: "%.2f %@", estimate.residual, estimate.residualUnit)),
            .init(
                title: "Confidence",
                value: String(format: "%.0f%% (%@)", estimate.confidence * 100, estimate.confidenceLabel)),
        ]
        if let angle = estimate.launchAngleDegrees {
            rows.append(.init(title: "Launch angle", value: String(format: "%.1f°", angle)))
        }
        if let apex = estimate.apexHeightMeters {
            rows.append(.init(title: "Apex height", value: String(format: "%.2f m", apex)))
        }
        if let height = measurement.cameraHeightMeters {
            rows.append(.init(title: "Camera height", value: String(format: "%.2f m", height)))
        }
        if let distance = measurement.cameraDistanceMeters {
            rows.append(
                .init(title: "Camera distance", value: String(format: "%.1f m", distance)))
        }
        if let error = measurement.calibrationErrorPixels {
            rows.append(
                .init(title: "Calibration error", value: String(format: "%.2f px", error)))
        }
        return rows
    }

    /// The flight path seen from directly above the court.
    private var planView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Path from above").font(.headline)
            Canvas { context, size in
                let court = CGSize(width: measurement.courtWidth, height: measurement.courtLength)
                guard court.width > 0, court.height > 0 else { return }
                let inset = 16.0
                let scale = min(
                    (size.width - inset * 2) / court.width,
                    (size.height - inset * 2) / court.height
                )
                let originX = (size.width - court.width * scale) / 2
                let originY = (size.height - court.height * scale) / 2

                func point(_ x: Double, _ y: Double) -> CGPoint {
                    // Court Y grows away from the camera; draw it up the screen.
                    CGPoint(
                        x: originX + x * scale,
                        y: originY + (court.height - y) * scale
                    )
                }

                let outline = Path(
                    CGRect(
                        x: originX, y: originY,
                        width: court.width * scale, height: court.height * scale))
                context.stroke(outline, with: .color(.secondary), lineWidth: 1)

                let points = estimate.points.map { point($0.courtX, $0.courtY) }
                guard points.count >= 2 else { return }
                var path = Path()
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                context.stroke(
                    path, with: .color(.orange),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                for p in points {
                    context.fill(
                        Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                        with: .color(.orange))
                }
            }
            .frame(height: 220)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Text(
                String(
                    format: "Court rectangle %.2f m × %.2f m", measurement.courtWidth,
                    measurement.courtLength)
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    /// Height against time, which makes the ballistic fit easy to sanity-check.
    private var heightProfile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Height over time").font(.headline)
            Canvas { context, size in
                let points = estimate.points
                guard points.count >= 2 else { return }
                let inset = 18.0
                let maxTime = points.map(\.time).max() ?? 1
                let maxHeight = max(points.map(\.courtZ).max() ?? 1, 0.5)
                let minHeight = min(points.map(\.courtZ).min() ?? 0, 0)
                let heightRange = max(maxHeight - minHeight, 0.2)

                func place(_ time: Double, _ height: Double) -> CGPoint {
                    CGPoint(
                        x: inset + (time / max(maxTime, 1e-6)) * (size.width - inset * 2),
                        y: size.height - inset
                            - ((height - minHeight) / heightRange) * (size.height - inset * 2)
                    )
                }

                var ground = Path()
                ground.move(to: place(0, 0))
                ground.addLine(to: place(maxTime, 0))
                context.stroke(
                    ground, with: .color(.secondary),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                var path = Path()
                path.move(to: place(points[0].time, points[0].courtZ))
                for p in points.dropFirst() { path.addLine(to: place(p.time, p.courtZ)) }
                context.stroke(
                    path, with: .color(.blue),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(height: 160)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Text("Dashed line is the court surface.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var methodNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How this was measured").font(.headline)
            Text(methodText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var methodText: String {
        switch estimate.method {
        case .ballistic:
            return """
                The four calibrated corners fix the camera's position and orientation relative to \
                the court. Each detection of the ball is then a ray through space, and fitting a \
                gravity-constrained parabola to all of those rays at once recovers the full 3D \
                flight — no assumption about how high the ball was flying. The speed shown is the \
                magnitude of the fitted velocity at the first tracked frame.
                """
        case .planar:
            return """
                The 3D fit was not usable here — either camera pose could not be recovered, or \
                the flight was too brief for gravity to bend the path measurably, which is what \
                fixes the ball's distance from the camera. Instead the ball was assumed to travel \
                on a flat plane a fixed height above the court. Vertical motion is not measured, \
                and the reading is inflated the further the ball strays above that plane. \
                Tracking the ball for longer, or from a higher vantage point, restores the 3D fit.
                """
        }
    }

    private func preparePlayer() {
        guard player == nil, let url = measurement.videoURL,
            FileManager.default.fileExists(atPath: url.path)
        else { return }
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        self.player = player
    }
}

/// Two-column list of labelled values.
struct StatGrid: View {
    struct Row: Identifiable {
        var id: String { title }
        var title: String
        var value: String
    }

    let rows: [Row]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                HStack {
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .padding(.vertical, 7)
                Divider()
            }
        }
    }
}
