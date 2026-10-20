import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer?

    func makeUIView(context: Context) -> PreviewHostView {
        PreviewHostView()
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.setPreviewLayer(previewLayer)
    }
}

final class PreviewHostView: UIView {
    private weak var currentPreviewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
    }

    func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer?) {
        guard currentPreviewLayer !== previewLayer else { return }
        currentPreviewLayer?.removeFromSuperlayer()
        currentPreviewLayer = previewLayer
        guard let previewLayer else { return }
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        currentPreviewLayer?.frame = bounds
    }
}
