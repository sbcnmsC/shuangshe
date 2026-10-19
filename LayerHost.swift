import SwiftUI
import AVFoundation

/// 把一个 AVCaptureVideoPreviewLayer 放进 SwiftUI。
/// 同一个 layer 在大图/小窗/分屏之间切换时会被自动移动。
struct LayerHost: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.host(layer)
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.host(layer)
    }

    final class HostView: UIView {
        private weak var hosted: CALayer?

        func host(_ l: CALayer) {
            guard hosted !== l || l.superlayer !== layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.removeFromSuperlayer()
            layer.addSublayer(l)
            l.frame = bounds
            CATransaction.commit()
            hosted = l
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // layer 可能已被别的 host 接管，只处理仍属于自己的
            guard let hosted, hosted.superlayer === layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted.frame = bounds
            CATransaction.commit()
        }
    }
}
