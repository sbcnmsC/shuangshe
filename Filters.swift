import CoreImage
import UIKit

/// 实时滤镜（作用于合成后的整幅画面，预览 / 照片 / 视频一致）。
/// 全部用系统自带的 Core Image 滤镜，GPU 上一次跑完。
enum FilterPreset: String, CaseIterable, Identifiable, Codable {
    case original = "原图"
    case vivid = "鲜艳"
    case warm = "暖阳"
    case cool = "冷调"
    case fresh = "清新"
    case cinema = "电影"
    case film = "胶片"
    case retro = "复古"
    case fade = "褪色"
    case chrome = "铬黄"
    case mono = "黑白"
    case noir = "黑金"

    var id: String { rawValue }

    /// strength：0 = 原图，1 = 完整滤镜效果。
    func apply(to image: CIImage, strength: CGFloat) -> CIImage {
        guard self != .original, strength > 0.01 else { return image }
        let filtered = styled(image)
        if strength >= 0.99 { return filtered.cropped(to: image.extent) }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: Double(strength)
        ]).cropped(to: image.extent)
    }

    private func styled(_ img: CIImage) -> CIImage {
        switch self {
        case .original:
            return img

        case .vivid:
            return img
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 1.12, "inputContrast": 1.08
                ])

        case .warm:
            return Self.gain(img, r: 1.07, g: 1.0, b: 0.90)
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 1.08, "inputBrightness": 0.01
                ])

        case .cool:
            return Self.gain(img, r: 0.92, g: 1.0, b: 1.08)
                .applyingFilter("CIColorControls", parameters: ["inputSaturation": 1.04])

        case .fresh:
            return img
                .applyingFilter("CIColorControls", parameters: [
                    "inputBrightness": 0.05, "inputSaturation": 1.10, "inputContrast": 0.96
                ])
                .applyingFilter("CIColorMatrix", parameters: Self.gainParams(r: 0.98, g: 1.02, b: 1.03))

        case .cinema:
            // 青橙色调：暗部偏青、亮部偏橙，再加一点对比度
            return img
                .applyingFilter("CIColorPolynomial", parameters: [
                    "inputRedCoefficients": CIVector(x: 0.0, y: 0.90, z: 0.18, w: 0),
                    "inputGreenCoefficients": CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0),
                    "inputBlueCoefficients": CIVector(x: 0.04, y: 1.15, z: -0.22, w: 0),
                    "inputAlphaCoefficients": CIVector(x: 0, y: 1, z: 0, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    "inputContrast": 1.10, "inputSaturation": 0.92
                ])

        case .film:
            return img.applyingFilter("CIPhotoEffectInstant")

        case .retro:
            return img
                .applyingFilter("CISepiaTone", parameters: ["inputIntensity": 0.45])
                .applyingFilter("CIColorControls", parameters: [
                    "inputSaturation": 0.85, "inputContrast": 0.95
                ])
                .applyingFilter("CIVignette", parameters: [
                    "inputIntensity": 0.9, "inputRadius": 1.6
                ])

        case .fade:
            return img.applyingFilter("CIPhotoEffectFade")

        case .chrome:
            return img.applyingFilter("CIPhotoEffectChrome")

        case .mono:
            return img.applyingFilter("CIPhotoEffectMono")

        case .noir:
            return img.applyingFilter("CIPhotoEffectNoir")
        }
    }

    private static func gainParams(r: CGFloat, g: CGFloat, b: CGFloat) -> [String: Any] {
        [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]
    }

    private static func gain(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: gainParams(r: r, g: g, b: b))
    }
}
