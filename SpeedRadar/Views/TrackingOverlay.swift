import SwiftUI

/// Draws the calibrated court outline and the tracked flight path on top of the
/// camera preview.
struct TrackingOverlay: View {
    var geometry: PreviewGeometry
    var courtOutline: [CGPoint]
    var trackPoints: [CGPoint]
    var showsCourt: Bool
    var showsTrack: Bool

    var body: some View {
        Canvas { context, _ in
            if showsCourt, courtOutline.count == 4 {
                let points = courtOutline.map(geometry.viewPoint(forNormalizedBufferPoint:))
                var path = Path()
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                context.stroke(
                    path,
                    with: .color(.green.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                )
                context.fill(path, with: .color(.green.opacity(0.08)))
            }

            guard showsTrack, trackPoints.count >= 2 else { return }
            let points = trackPoints.map(geometry.viewPoint(forNormalizedBufferPoint:))

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(
                path,
                with: .color(.yellow.opacity(0.9)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )

            // Fade the older detections so the direction of travel reads at a glance.
            for (index, point) in points.enumerated() {
                let progress = Double(index) / Double(max(points.count - 1, 1))
                let radius = 3.0 + 3.0 * progress
                let rect = CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.yellow.opacity(0.35 + 0.65 * progress))
                )
            }
        }
        .allowsHitTesting(false)
    }
}
