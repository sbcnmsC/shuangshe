import SwiftUI
import AVFoundation

/// 把合成后的画面（AVSampleBufferDisplayLayer）放进 SwiftUI。
/// 预览显示的就是最终合成帧，所以滤镜、小窗位置、画幅都是所见即所得。
struct DisplayLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.backgroundColor = .black
        v.attach(displayLayer)
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.attach(displayLayer)
    }

    final class HostView: UIView {
        private var hosted: CALayer?

        func attach(_ l: CALayer) {
            guard hosted !== l else { return }
            l.removeFromSuperlayer()
            layer.addSublayer(l)
            hosted = l
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}
