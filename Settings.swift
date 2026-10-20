import CoreGraphics
import Foundation

// MARK: - 基础枚举

enum LayoutMode: String, CaseIterable, Identifiable, Codable {
    case pip = "画中画"
    case split = "上下分屏"
    var id: String { rawValue }
}

enum CameraMode: String, CaseIterable, Identifiable, Codable {
    case frontBack = "前 + 后"
    case wideUltra = "广角 + 超广角"
    case wideTele = "广角 + 长焦"
    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .frontBack: return "前+后"
        case .wideUltra: return "广+超广"
        case .wideTele: return "广+长焦"
        }
    }
}

/// 白平衡预设。自定义用色温 / 色调滑杆。
enum WBPreset: String, CaseIterable, Identifiable {
    case auto = "自动"
    case daylight = "日光"
    case cloudy = "多云"
    case tungsten = "白炽灯"
    case fluorescent = "荧光灯"
    case custom = "自定义"
    var id: String { rawValue }

    /// 预设色温（K）；自动 / 自定义返回 nil。
    var temperature: Float? {
        switch self {
        case .auto, .custom: return nil
        case .daylight: return 5200
        case .cloudy: return 6500
        case .tungsten: return 3000
        case .fluorescent: return 4200
        }
    }
}

// MARK: - 输出画面

/// 输出画幅（宽 / 高）。
enum AspectPreset: String, CaseIterable, Identifiable, Codable {
    case tall = "9:16"
    case classic = "3:4"
    case square = "1:1"
    var id: String { rawValue }

    var ratio: CGFloat {
        switch self {
        case .tall: return 9.0 / 16.0
        case .classic: return 3.0 / 4.0
        case .square: return 1
        }
    }
}

/// 输出分辨率档位。「最高」= 硬件允许的最大合成尺寸（最高 4K）。
enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case p720 = "720p"
    case p1080 = "1080p"
    case highest = "最高"
    var id: String { rawValue }

    /// 合成画布的宽（短边）上限。
    var shortSide: CGFloat {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .highest: return 2160
        }
    }

    /// 摄像头采集分辨率（宽）从高到低的尝试顺序。
    var sourceWidths: [Int32] {
        switch self {
        case .p720: return [1280, 640]
        case .p1080: return [1920, 1280, 640]
        case .highest: return [3840, 1920, 1280, 640]
        }
    }
}

enum FPSOption: Int, CaseIterable, Identifiable, Codable {
    case f30 = 30
    case f60 = 60
    var id: Int { rawValue }
}

// MARK: - 画中画小窗

enum PiPShape: String, CaseIterable, Identifiable, Codable {
    case rounded = "圆角"
    case circle = "圆形"
    var id: String { rawValue }
}

enum PiPAspect: String, CaseIterable, Identifiable, Codable {
    case portrait = "3:4"
    case square = "1:1"
    case landscape = "4:3"
    case tall = "9:16"
    var id: String { rawValue }

    /// 高 / 宽
    var heightOverWidth: CGFloat {
        switch self {
        case .portrait: return 4.0 / 3.0
        case .square: return 1
        case .landscape: return 3.0 / 4.0
        case .tall: return 16.0 / 9.0
        }
    }
}

/// 小窗的位置、大小、外观。位置用画面的归一化坐标（原点在左上角），
/// 预览和合成共用这一份数据，所以所见即所得。
struct PiPConfig: Codable, Equatable {
    var centerX: CGFloat = 0.80
    var centerY: CGFloat = 0.17
    /// 宽度占画面宽度的比例
    var width: CGFloat = 0.30
    var aspect: PiPAspect = .portrait
    var shape: PiPShape = .rounded
    /// 圆角占短边的比例（0 ... 0.5）
    var corner: CGFloat = 0.16
    /// 边框粗细（0 = 无边框）
    var border: CGFloat = 0.5
    var opacity: CGFloat = 1.0
    /// 松手后自动吸附到边缘 / 中线
    var snap: Bool = true

    static let minWidth: CGFloat = 0.16
    static let maxWidth: CGFloat = 0.72

    /// 小窗在 size 里的矩形（左上角为原点），保证完全落在画面内。
    func rect(in size: CGSize) -> CGRect {
        let ratio = (shape == .circle) ? 1 : aspect.heightOverWidth
        var w = min(max(width, Self.minWidth), Self.maxWidth) * size.width
        var h = w * ratio
        let maxH = size.height * 0.9
        if h > maxH {
            h = maxH
            w = h / ratio
        }
        let cx = min(max(centerX * size.width, w / 2), size.width - w / 2)
        let cy = min(max(centerY * size.height, h / 2), size.height - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func cornerRadius(for size: CGSize) -> CGFloat {
        if shape == .circle { return min(size.width, size.height) / 2 }
        return min(size.width, size.height) * min(max(corner, 0), 0.5)
    }

    /// 把中心点限制在合法范围内，避免拖出边界后出现「死区」。
    func clamped(in size: CGSize) -> PiPConfig {
        var p = self
        let r = rect(in: size)
        p.centerX = r.midX / size.width
        p.centerY = r.midY / size.height
        p.width = min(max(width, Self.minWidth), Self.maxWidth)
        return p
    }
}
