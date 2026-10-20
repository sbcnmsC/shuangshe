import Foundation
import CoreGraphics

// MARK: - Camera state models

enum CaptureMode: String, CaseIterable, Identifiable, Hashable {
    case photo = "拍照"
    case video = "录像"
    var id: String { rawValue }
}

enum CameraLayout: String, CaseIterable, Identifiable, Hashable {
    case pictureInPicture = "画中画"
    case split = "上下分屏"
    var id: String { rawValue }
}

enum CanvasAspect: String, CaseIterable, Identifiable, Hashable {
    case portrait916 = "9:16"
    case portrait34 = "3:4"
    case square = "1:1"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .portrait916: return CGSize(width: 1080, height: 1920)
        case .portrait34: return CGSize(width: 1080, height: 1440)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

enum OutputResolution: String, CaseIterable, Identifiable, Hashable {
    case p720 = "720p"
    case p1080 = "1080p"
    case maximum = "最高"
    var id: String { rawValue }
}

enum PipShape: String, CaseIterable, Identifiable, Hashable {
    case rounded = "圆角"
    case circle = "圆形"
    var id: String { rawValue }
}

enum PipAspect: String, CaseIterable, Identifiable, Hashable {
    case portrait34 = "3:4"
    case square = "1:1"
    case landscape43 = "4:3"
    case portrait916 = "9:16"
    var id: String { rawValue }
    var ratio: CGFloat {
        switch self {
        case .portrait34: return 3.0 / 4.0
        case .square: return 1
        case .landscape43: return 4.0 / 3.0
        case .portrait916: return 9.0 / 16.0
        }
    }
}

enum LiveFilter: String, CaseIterable, Identifiable, Hashable {
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
    case monochrome = "黑白"
    case noirGold = "黑金"
    var id: String { rawValue }
}

struct CameraSettings {
    var captureMode: CaptureMode = .photo
    var layout: CameraLayout = .pictureInPicture
    var aspect: CanvasAspect = .portrait916
    var resolution: OutputResolution = .p1080
    var frameRate: Int = 30
    var timerSeconds: Int = 0
    var flashEnabled: Bool = false
    var saveTwoOriginals: Bool = false
    var lowLightBoost: Bool = true
    var stabilizationEnabled: Bool = true
    var frontMirror: Bool = true
    var gridEnabled: Bool = false
    var snapPip: Bool = true

    // Normalized position in the composition canvas (x from left, y from top).
    var pipX: CGFloat = 0.73
    var pipY: CGFloat = 0.22
    var pipScale: CGFloat = 0.31
    var pipShape: PipShape = .rounded
    var pipAspect: PipAspect = .portrait34
    var pipCornerRadius: CGFloat = 28
    var pipBorderWidth: CGFloat = 4
    var pipOpacity: Double = 1.0
    var splitRatio: CGFloat = 0.5

    var filter: LiveFilter = .original
    var filterIntensity: Double = 0.8

    var zoom: CGFloat = 1.0
    var exposureBias: Double = 0
    var manualISO: Double = 0       // 0 = auto
    var shutterSeconds: Double = 1.0 / 60.0
    var whiteBalanceKelvin: Double = 5600
    var whiteBalanceTint: Double = 0
    var manualFocus: Double = 0.5
    var focusLocked: Bool = false
    var exposureLocked: Bool = false
    var mainUsesFrontCamera: Bool = false

    var outputSize: CGSize {
        let base = aspect.size
        switch resolution {
        case .p720:
            let scale = 720.0 / min(base.width, base.height)
            return CGSize(width: (base.width * scale).rounded(.down), height: (base.height * scale).rounded(.down))
        case .p1080:
            return base
        case .maximum:
            // The capture stream's real dimensions are checked by the camera engine.
            // This canvas is a target, not a promise that every device supplies 4K frames.
            return CGSize(width: base.width * 2, height: base.height * 2)
        }
    }
}
