import CoreImage
import CoreVideo
import Foundation
import Metal

enum FilterCatalog: String, CaseIterable, Identifiable {
    case original = "原片"
    case vivid = "鲜艳"
    case warm = "暖阳"
    case cool = "冷调"
    case fresh = "清新"
    case cinematic = "电影"
    case film = "胶片"
    case vintage = "复古"
    case faded = "褪色"
    case chrome = "铬黄"
    case mono = "黑白"
    case noir = "黑金"

    var id: String { rawValue }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .original: return image
        case .vivid: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.1])
        case .warm: return image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5000, y: 0)])
        case .cool: return image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 5000, y: 0), "inputTargetNeutral": CIVector(x: 7000, y: 0)])
        case .fresh: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.18, kCIInputBrightnessKey: 0.03])
        case .cinematic: return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.82, kCIInputContrastKey: 1.18])
        case .film: return image.applyingFilter("CIPhotoEffectProcess")
        case .vintage: return image.applyingFilter("CIPhotoEffectTransfer")
        case .faded: return image.applyingFilter("CIPhotoEffectFade")
        case .chrome: return image.applyingFilter("CIPhotoEffectChrome")
        case .mono: return image.applyingFilter("CIPhotoEffectMono")
        case .noir: return image.applyingFilter("CIPhotoEffectNoir")
        }
    }
}

final class FilterProcessor {
    private let context: CIContext
    init() {
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) }
        else { context = CIContext(options: [.cacheIntermediates: false]) }
    }

    func process(_ buffer: CVPixelBuffer, filter: FilterCatalog, strength: CGFloat) -> CVPixelBuffer? {
        guard filter != .original else { return buffer }
        let input = CIImage(cvPixelBuffer: buffer)
        let filtered = filter.apply(to: input)
        let amount = min(max(strength, 0), 1)
        let mask = CIImage(color: CIColor(red: amount, green: amount, blue: amount, alpha: 1)).cropped(to: input.extent)
        let blended = filtered.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: input, kCIInputMaskImageKey: mask
        ])
        var output: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(buffer),
            kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(buffer),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &output)
        guard let output else { return buffer }
        context.render(blended, to: output, bounds: input.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }
}
