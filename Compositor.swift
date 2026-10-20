import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import UIKit

/// 一帧合成所需的全部状态（值类型，帧回调里拿快照用）。
struct RenderState {
    var layout: LayoutMode = .pip
    var swapped = false
    var pip = PiPConfig()
    var splitRatio: CGFloat = 0.5
    var filter: FilterPreset = .original
    var filterStrength: CGFloat = 1
    var canvas = CGSize(width: 1080, height: 1920)
}

/// 把两路画面合成为一帧。预览、照片、合成视频共用这一个函数，保证所见即所得。
enum Compositor {

    /// 根据画幅、分辨率档位和采集源尺寸算出合成画布：
    /// 不会超过采集源的实际像素（不做无意义的放大）。
    static func canvasSize(aspect: AspectPreset, resolution: ResolutionPreset,
                           source: CGSize) -> CGSize {
        let ratio = aspect.ratio                       // 宽 / 高
        var width = resolution.shortSide
        if source.width > 0 { width = min(width, source.width) }
        if source.height > 0 { width = min(width, source.height * ratio) }
        width = max(320, (width / 2).rounded(.down) * 2)
        let height = (width / ratio / 2).rounded() * 2
        return CGSize(width: width, height: height)
    }

    static func render(a: CVPixelBuffer, b: CVPixelBuffer, state s: RenderState) -> CIImage {
        let size = s.canvas
        let bounds = CGRect(origin: .zero, size: size)
        let imgA = CIImage(cvPixelBuffer: a)
        let imgB = CIImage(cvPixelBuffer: b)
        let (main, second) = s.swapped ? (imgB, imgA) : (imgA, imgB)
        let W = size.width, H = size.height

        var out: CIImage
        switch s.layout {
        case .split:
            // Core Image 坐标原点在左下角：y 大的是上半屏
            let topH = (H * s.splitRatio).rounded()
            let top = fill(main, into: CGRect(x: 0, y: H - topH, width: W, height: topH))
            let bottom = fill(second, into: CGRect(x: 0, y: 0, width: W, height: H - topH))
            out = top.composited(over: bottom)

        case .pip:
            let base = fill(main, into: bounds)
            out = pipLayer(second, config: s.pip, canvas: size).composited(over: base)
        }

        out = s.filter.apply(to: out.cropped(to: bounds), strength: s.filterStrength)
        return out.cropped(to: bounds)
    }

    // MARK: 小窗

    private static func pipLayer(_ src: CIImage, config c: PiPConfig, canvas: CGSize) -> CIImage {
        let k = canvas.width / 1080
        let r = c.rect(in: canvas)                                   // 左上角原点
        let rect = CGRect(x: r.minX, y: canvas.height - r.maxY,       // 转成 CI 坐标（左下角原点）
                          width: r.width, height: r.height)
        let radius = c.cornerRadius(for: rect.size)

        let mask = roundedRect(rect, radius: radius)
        let content = fill(src, into: rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])

        var layer = content
        if c.border > 0.02 {
            let bw = max(1.5, c.border * 7 * k)
            let outer = roundedRect(rect.insetBy(dx: -bw, dy: -bw), radius: radius + bw)
            let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [
                kCIInputBackgroundImageKey: mask
            ])
            layer = ring.composited(over: content)
        }

        if c.opacity < 0.99 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: c.opacity)
            ])
        }

        // Skip per-frame Gaussian shadow blur. The inset border provides separation
        // without an extra blur pass on every preview/recording frame.
        return layer
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
