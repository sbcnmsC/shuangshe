import Combine
import CoreGraphics
import Foundation

enum CaptureLayout: String, CaseIterable, Identifiable {
    case pictureInPicture = "画中画"
    case split = "上下分屏"
    var id: String { rawValue }
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case ratio9x16 = "9:16"
    case ratio3x4 = "3:4"
    case square = "1:1"
    var id: String { rawValue }
    var ratio: CGFloat {
        switch self {
        case .ratio9x16: return 9.0 / 16.0
        case .ratio3x4: return 3.0 / 4.0
        case .square: return 1
        }
    }
}

enum OutputResolution: String, CaseIterable, Identifiable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case maximum = "最高（安全上限 1080p）"
    var id: String { rawValue }
    var width: Int { self == .hd720 ? 720 : 1080 }
    var targetCaptureWidth: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .maximum: return 3840
        }
    }
}

@MainActor
final class CaptureSettings: ObservableObject {
    @Published var layout: CaptureLayout = .pictureInPicture
    @Published var aspectRatio: AspectRatio = .ratio9x16
    @Published var resolution: OutputResolution = .hd720
    @Published var frameRate = 30
    @Published var primaryFront = false
    @Published var pipRect = CGRect(x: 0.64, y: 0.08, width: 0.29, height: 0.25)
    @Published var cornerRadius: CGFloat = 22
    @Published var mirrorFrontCamera = true
    @Published var snapToEdge = true
    @Published var showGrid = false
    @Published var saveOriginalStreams = false
    @Published var lowLightBoost = false
    @Published var stabilization = true
    @Published var filter: FilterCatalog = .original
    @Published var filterStrength: CGFloat = 1
    @Published var zoom = 1.0
    @Published var exposureBias = 0.0
    @Published var manualExposure = false
    @Published var iso = 200.0
    @Published var shutterSeconds = 1.0 / 120.0
    @Published var manualFocus = false
    @Published var focusPosition = 0.5
    @Published var whiteBalanceTemperature = 5200.0
    @Published var whiteBalanceTint = 0.0

    var outputWidth: Int { resolution.width }
    var outputHeight: Int { max(1, Int((Double(outputWidth) / Double(aspectRatio.ratio)).rounded())) }
}
