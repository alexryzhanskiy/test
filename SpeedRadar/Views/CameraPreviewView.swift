import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview.
///
/// Uses `resizeAspect` rather than `resizeAspectFill` so the whole frame is on
/// screen: during calibration a cropped preview could hide a court corner the
/// user needs to tap, and every overlay is positioned against the full frame.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var rotationDegrees: Double

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.apply(rotationDegrees: rotationDegrees)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.apply(rotationDegrees: rotationDegrees)
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe by construction: `layerClass` above guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }

    func apply(rotationDegrees: Double) {
        guard let connection = previewLayer.connection else { return }
        let angle = CGFloat(rotationDegrees)
        if connection.isVideoRotationAngleSupported(angle),
            connection.videoRotationAngle != angle
        {
            connection.videoRotationAngle = angle
        }
    }
}
