import CoreGraphics
import CoreMedia
import Foundation
import simd

/// Pinhole camera intrinsics expressed in pixels of the analysed video buffer.
struct CameraIntrinsics: Equatable, Codable {
    var focalLengthX: Double
    var focalLengthY: Double
    var principalPointX: Double
    var principalPointY: Double
    /// Size of the buffer the intrinsics were measured against.
    var imageWidth: Double
    var imageHeight: Double

    var matrix: Mat3 {
        Mat3([
            focalLengthX, 0, principalPointX,
            0, focalLengthY, principalPointY,
            0, 0, 1,
        ])
    }

    /// Builds intrinsics from the horizontal field of view reported by
    /// `AVCaptureDevice.Format.videoFieldOfView`, assuming square pixels and a
    /// centred principal point. Used when the capture pipeline cannot deliver a
    /// per-frame intrinsic matrix.
    init(horizontalFieldOfViewDegrees fov: Double, imageSize: CGSize, zoomFactor: Double = 1) {
        let width = Double(imageSize.width)
        let height = Double(imageSize.height)
        let halfAngle = (fov * .pi / 180) / 2
        let focal = (width / 2) / max(tan(halfAngle), 1e-6) * max(zoomFactor, 0.01)
        self.focalLengthX = focal
        self.focalLengthY = focal
        self.principalPointX = width / 2
        self.principalPointY = height / 2
        self.imageWidth = width
        self.imageHeight = height
    }

    init(focalLengthX: Double, focalLengthY: Double, principalPointX: Double, principalPointY: Double, imageSize: CGSize) {
        self.focalLengthX = focalLengthX
        self.focalLengthY = focalLengthY
        self.principalPointX = principalPointX
        self.principalPointY = principalPointY
        self.imageWidth = Double(imageSize.width)
        self.imageHeight = Double(imageSize.height)
    }

    /// Reads the intrinsic matrix attachment that the capture connection
    /// delivers when `isCameraIntrinsicMatrixDeliveryEnabled` is on.
    init?(sampleBuffer: CMSampleBuffer, imageSize: CGSize) {
        guard
            let data = CMGetAttachment(
                sampleBuffer,
                key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                attachmentModeOut: nil
            ) as? Data,
            data.count >= MemoryLayout<matrix_float3x3>.size
        else { return nil }

        let matrix: matrix_float3x3 = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(as: matrix_float3x3.self)
        }
        let fx = Double(matrix.columns.0.x)
        let fy = Double(matrix.columns.1.y)
        guard fx.isFinite, fy.isFinite, fx > 1, fy > 1 else { return nil }

        self.init(
            focalLengthX: fx,
            focalLengthY: fy,
            principalPointX: Double(matrix.columns.2.x),
            principalPointY: Double(matrix.columns.2.y),
            imageSize: imageSize
        )
    }

    /// Rescales intrinsics measured on one buffer size to another.
    func scaled(to size: CGSize) -> CameraIntrinsics {
        guard imageWidth > 0, imageHeight > 0 else { return self }
        let sx = Double(size.width) / imageWidth
        let sy = Double(size.height) / imageHeight
        return CameraIntrinsics(
            focalLengthX: focalLengthX * sx,
            focalLengthY: focalLengthY * sy,
            principalPointX: principalPointX * sx,
            principalPointY: principalPointY * sy,
            imageSize: size
        )
    }
}

/// The pose of the camera relative to the court frame.
///
/// The court frame has its origin at the first calibration corner, `X` running
/// along the court's width, `Y` along its length, and `Z` pointing up out of
/// the playing surface.
struct CameraPose: Equatable {
    /// Rotation taking a point from court coordinates into camera coordinates.
    var rotation: Mat3
    /// Translation, in metres, applied after `rotation`.
    var translation: Vec3

    /// Position of the camera expressed in the court frame.
    var cameraCenter: Vec3 {
        let inverse = rotation.transposed
        return -(inverse * translation)
    }

    func transformToCamera(_ courtPoint: Vec3) -> Vec3 {
        rotation * courtPoint + translation
    }
}

/// Recovers camera pose from a court-plane homography and re-derives
/// homographies for planes parallel to the court.
enum PlanarPose {

    /// Decomposes `H` (court metres → image pixels) into a rigid pose.
    ///
    /// Follows the standard planar-target decomposition: the first two columns
    /// of `K⁻¹H` are the first two rotation columns up to a common scale, and
    /// the third is the translation.
    static func decompose(courtToImage homography: Mat3, intrinsics: CameraIntrinsics) -> CameraPose? {
        guard let inverseIntrinsics = intrinsics.matrix.inverted else { return nil }
        let b = inverseIntrinsics * homography

        let b1 = b.column(0)
        let b2 = b.column(1)
        let b3 = b.column(2)

        let norm = (b1.length + b2.length) / 2
        guard norm > 1e-9 else { return nil }
        var scale = 1 / norm

        // Two solutions differ by an overall sign; the physical one puts the
        // court in front of the camera.
        if b3.z < 0 { scale = -scale }

        let r1raw = b1 * scale
        let r2raw = b2 * scale
        let translation = b3 * scale

        // Gram-Schmidt: the raw columns are only approximately orthonormal
        // because of noise in the four tapped corners.
        let e1 = r1raw.normalized
        let projected = r2raw - e1 * e1.dot(r2raw)
        guard projected.length > 1e-9 else { return nil }
        let e2 = projected.normalized
        let e3 = e1.cross(e2)

        let rotation = Mat3(columns: e1, e2, e3)
        guard rotation.elements.allSatisfy({ $0.isFinite }),
            translation.x.isFinite, translation.y.isFinite, translation.z.isFinite
        else { return nil }

        return CameraPose(rotation: rotation, translation: translation)
    }

    /// Homography mapping points on the plane `Z = height` (court metres) to
    /// image pixels.
    static func homography(
        forPlaneHeight height: Double,
        pose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> Mat3 {
        let r1 = pose.rotation.column(0)
        let r2 = pose.rotation.column(1)
        let r3 = pose.rotation.column(2)
        let shifted = r3 * height + pose.translation
        return intrinsics.matrix * Mat3(columns: r1, r2, shifted)
    }

    /// Projects a 3D court-frame point into pixel coordinates.
    static func project(
        courtPoint: Vec3,
        pose: CameraPose,
        intrinsics: CameraIntrinsics
    ) -> CGPoint? {
        let camera = pose.transformToCamera(courtPoint)
        guard camera.z > 1e-6 else { return nil }
        return (intrinsics.matrix * camera).dehomogenized
    }
}
