import CoreGraphics
import Foundation

/// Converts between points on screen and normalized coordinates in the capture
/// buffer.
///
/// The buffer is never rotated — that would invalidate the camera intrinsics —
/// so the preview layer rotates the image for display and this type undoes that
/// rotation when the user taps, and reapplies it when drawing overlays.
struct PreviewGeometry: Equatable {
    /// Size of the analysis buffer, in pixels, unrotated.
    var bufferSize: CGSize
    /// Clockwise rotation applied by the preview, in degrees.
    var rotationDegrees: Double
    /// Size of the view showing the preview.
    var viewSize: CGSize

    /// Rotation snapped to a quarter turn.
    var quarterTurns: Int {
        let normalized = ((rotationDegrees / 90).rounded()).truncatingRemainder(dividingBy: 4)
        let turns = Int(normalized)
        return turns < 0 ? turns + 4 : turns
    }

    var isQuarterTurned: Bool { quarterTurns % 2 == 1 }

    /// Size of the image as displayed, after rotation.
    var displayedImageSize: CGSize {
        isQuarterTurned
            ? CGSize(width: bufferSize.height, height: bufferSize.width)
            : bufferSize
    }

    /// The letterboxed rectangle the video occupies inside the view.
    ///
    /// Matches `AVLayerVideoGravity.resizeAspect`, which the preview uses so
    /// that no part of the court can be cropped out of reach during calibration.
    var displayedRect: CGRect {
        let image = displayedImageSize
        guard image.width > 0, image.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let scale = min(viewSize.width / image.width, viewSize.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Buffer point (normalized, top-left origin) → point in the view.
    func viewPoint(forNormalizedBufferPoint point: CGPoint) -> CGPoint {
        let rotated = rotate(point, turns: quarterTurns)
        let rect = displayedRect
        return CGPoint(
            x: rect.minX + rotated.x * rect.width,
            y: rect.minY + rotated.y * rect.height
        )
    }

    /// Point in the view → buffer point (normalized, top-left origin).
    /// Returns `nil` for taps in the letterbox bars, which map nowhere.
    func normalizedBufferPoint(forViewPoint point: CGPoint) -> CGPoint? {
        let rect = displayedRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let displayed = CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (point.y - rect.minY) / rect.height
        )
        guard displayed.x >= -0.001, displayed.x <= 1.001,
            displayed.y >= -0.001, displayed.y <= 1.001
        else { return nil }
        let unrotated = rotate(displayed, turns: (4 - quarterTurns) % 4)
        return CGPoint(
            x: min(max(unrotated.x, 0), 1),
            y: min(max(unrotated.y, 0), 1)
        )
    }

    /// Rotates a point in the unit square clockwise by `turns` quarter turns.
    private func rotate(_ point: CGPoint, turns: Int) -> CGPoint {
        switch turns % 4 {
        case 1: return CGPoint(x: 1 - point.y, y: point.x)
        case 2: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return CGPoint(x: point.y, y: 1 - point.x)
        default: return point
        }
    }
}
