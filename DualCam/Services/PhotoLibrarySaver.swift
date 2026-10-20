import Photos
import UIKit

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "没有照片添加权限。请在系统设置中允许 DualCam 保存照片。"
            case .saveFailed: return "保存照片失败，请检查系统照片权限后重试。"
            }
        }
    }

    static func save(_ image: UIImage, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(SaveError.permissionDenied))
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if let error {
                    completion(.failure(error))
                } else if success {
                    completion(.success(()))
                } else {
                    completion(.failure(SaveError.saveFailed))
                }
            }
        }
    }
}
