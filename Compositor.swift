import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

enum LayoutMode: String, CaseIterable, Identifiable {
    case pip = "画中画"
    case split = "上下分屏"
    var id: String { rawValue }
}

/// 把两路画面合成为一帧（照片和合成视频共用，保证所见即所得）。
enum Compositor {
    static let size = CGSize(width: 1080, height: 1920)
    static let bounds = CGRect(origin: .zero, size: size)

    static func render(a: CVPixelBuffer, b: CVPixelBuffer,
                       layout: LayoutMode, swapped: Bool) -> CIImage {
        let imgA = CIImage(cvPixelBuffer: a)
        let imgB = CIImage(cvPixelBuffer: b)
        let (main, second) = swapped ? (imgB, imgA) : (imgA, imgB)
        let W = size.width, H = size.height

        switch layout {
        case .split:
            // Core Image 坐标原点在左下角：y 大的是上半屏
            let top = fill(main, into: CGRect(x: 0, y: H / 2, width: W, height: H / 2))
            let bottom = fill(second, into: CGRect(x: 0, y: 0, width: W, height: H / 2))
            return top.composited(over: bottom).cropped(to: bounds)

        case .pip:
            let base = fill(main, into: bounds)
            let w = W * 0.3
            let h = w * 150 / 110
            let margin = W * 0.04
            let rect = CGRect(x: W - w - margin, y: H - h - margin * 2.5, width: w, height: h)
            let radius = w * 0.12

            let small = fill(second, into: rect)
            let mask = roundedRect(rect, radius: radius)
            let border = roundedRect(rect.insetBy(dx: -5, dy: -5), radius: radius + 5)

            let clipped = small.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask
            ])
            return clipped.composited(over: border.composited(over: base)).cropped(to: bounds)
        }
    }

    /// 等比放大并居中裁切，铺满目标矩形（等同 resizeAspectFill）。
    private static func fill(_ img: CIImage, into rect: CGRect) -> CIImage {
        let e = img.extent
        let s = max(rect.width / e.width, rect.height / e.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let se = scaled.extent
        let moved = scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX,
                                                              y: rect.midY - se.midY))
        return moved.cropped(to: rect)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(radius)
        f.color = .white
        return f.outputImage ?? CIImage.empty()
    }
}
