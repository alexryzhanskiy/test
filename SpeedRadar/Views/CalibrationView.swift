import SwiftUI

/// Court calibration: the user taps the four corners of a rectangle whose real
/// dimensions are known, which is what turns pixels into metres.
struct CalibrationView: View {
    @EnvironmentObject private var controller: CaptureController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var corners: [CGPoint] = []
    @State private var selectedIndex: Int?
    @State private var showsCourtPicker = false
    @State private var errorMessage: String?

    /// One nudge step, in normalized buffer units — about a pixel on a 1080p frame.
    private let nudgeStep = 0.001

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

                quadOverlay(geometry: geometry)

                ForEach(Array(corners.enumerated()), id: \.offset) { index, corner in
                    CornerMarker(
                        index: index,
                        label: cornerLabel(index),
                        isSelected: selectedIndex == index
                    )
                    .position(geometry.viewPoint(forNormalizedBufferPoint: corner))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                selectedIndex = index
                                if let point = geometry.normalizedBufferPoint(
                                    forViewPoint: value.location)
                                {
                                    corners[index] = point
                                }
                            }
                    )
                }

                // Tap layer sits underneath the markers so dragging one never
                // adds a new corner by accident.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        handleTap(at: location, geometry: geometry)
                    }
                    .allowsHitTesting(corners.count < 4)

                VStack {
                    instructions
                    Spacer()
                    controls
                }
                .padding()
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showsCourtPicker) {
            CourtPickerView()
                .environmentObject(settings)
        }
        .onAppear(perform: seedFromExistingCalibration)
        .alert(
            "Calibration failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private func quadOverlay(geometry: PreviewGeometry) -> some View {
        Canvas { context, _ in
            guard corners.count >= 2 else { return }
            let points = corners.map(geometry.viewPoint(forNormalizedBufferPoint:))
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            if corners.count == 4 { path.closeSubpath() }
            context.stroke(
                path,
                with: .color(.green),
                style: StrokeStyle(lineWidth: 2, dash: corners.count == 4 ? [] : [6, 4])
            )
            if corners.count == 4 {
                context.fill(path, with: .color(.green.opacity(0.12)))
            }
        }
        .allowsHitTesting(false)
    }

    private var instructions: some View {
        VStack(spacing: 8) {
            Text(settings.court.name)
                .font(.headline)
            Text(settings.court.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if corners.count < 4 {
                Label(cornerLabel(corners.count), systemImage: "hand.tap")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                Text("Tap the corner on screen. Zoom in mentally — precision here sets the accuracy of every measurement.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("Drag any marker to fine-tune, then save.")
                    .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let selectedIndex, corners.indices.contains(selectedIndex) {
                NudgePad { dx, dy in
                    var point = corners[selectedIndex]
                    point.x = min(max(point.x + dx * nudgeStep, 0), 1)
                    point.y = min(max(point.y + dy * nudgeStep, 0), 1)
                    corners[selectedIndex] = point
                }
            }

            HStack(spacing: 12) {
                Button {
                    showsCourtPicker = true
                } label: {
                    Label("Court", systemImage: "ruler")
                }
                .buttonStyle(.bordered)

                Button {
                    if !corners.isEmpty {
                        corners.removeLast()
                        selectedIndex = nil
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(corners.isEmpty)

                Button {
                    corners.removeAll()
                    selectedIndex = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(corners.isEmpty)

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(corners.count != 4)
            }

            Button("Cancel") { dismiss() }
                .font(.footnote)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func handleTap(at location: CGPoint, geometry: PreviewGeometry) {
        guard corners.count < 4,
            let point = geometry.normalizedBufferPoint(forViewPoint: location)
        else { return }
        corners.append(point)
        selectedIndex = corners.count - 1
        // Buffers are delivered in the sensor's native landscape orientation,
        // which is the same space the focus point of interest is expressed in.
        controller.focus(atNormalizedPoint: point)
    }

    private func cornerLabel(_ index: Int) -> String {
        let labels = settings.court.cornerLabels
        guard labels.indices.contains(index) else { return "Corner \(index + 1)" }
        return labels[index]
    }

    private func seedFromExistingCalibration() {
        guard corners.isEmpty,
            let existing = controller.resolvedCalibration?.calibration,
            existing.isComplete
        else { return }
        corners = existing.normalizedImagePoints
    }

    private func save() {
        if controller.applyCalibration(normalizedCorners: corners) {
            dismiss()
        } else {
            errorMessage =
                controller.errorMessage
                ?? "Those corners do not describe a rectangle the camera can resolve. Spread them further apart and try again."
        }
    }
}

/// One tappable, draggable court corner.
private struct CornerMarker: View {
    let index: Int
    let label: String
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.yellow : Color.green, lineWidth: 2)
                .frame(width: 34, height: 34)
            Circle()
                .fill(isSelected ? Color.yellow : Color.green)
                .frame(width: 5, height: 5)
            Text("\(index + 1)")
                .font(.caption2.bold())
                .foregroundStyle(.black)
                .padding(3)
                .background(Circle().fill(isSelected ? Color.yellow : Color.green))
                .offset(x: 20, y: -18)
        }
        .accessibilityLabel(Text(label))
        .contentShape(Circle().inset(by: -12))
    }
}

/// Arrow pad for sub-pixel corner adjustment; dragging alone is not precise
/// enough at the far end of a big court.
private struct NudgePad: View {
    let onNudge: (Double, Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            button(system: "chevron.up", dx: 0, dy: -1)
            HStack(spacing: 24) {
                button(system: "chevron.left", dx: -1, dy: 0)
                button(system: "chevron.right", dx: 1, dy: 0)
            }
            button(system: "chevron.down", dx: 0, dy: 1)
        }
    }

    private func button(system: String, dx: Double, dy: Double) -> some View {
        Button {
            onNudge(dx, dy)
        } label: {
            Image(systemName: system)
                .frame(width: 34, height: 26)
        }
        .buttonStyle(.bordered)
        .buttonRepeatBehavior(.enabled)
    }
}
