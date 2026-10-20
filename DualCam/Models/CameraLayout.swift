import Foundation

enum CameraLayout: String, CaseIterable, Identifiable {
    case pictureInPicture
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pictureInPicture: return "画中画"
        case .split: return "上下分屏"
        }
    }
}
