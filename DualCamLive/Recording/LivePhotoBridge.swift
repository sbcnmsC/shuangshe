import AVFoundation
import Photos
import UIKit

enum LivePhotoExportResult {
    case success(URL)
    case degradedToVideo(URL, reason: String)
}

/// Explicitly conservative bridge: a normal movie is never mislabeled as a Live Photo.
/// Full export requires a paired still image, content identifier, StillImageTime,
/// Apple MakerNote and PhotoKit validation against a real device-captured metadata donor.
final class LivePhotoBridge {
    func makeLivePhoto(from clipURL: URL, donorLivePhotoMovieURL: URL? = nil,
                       completion: @escaping (LivePhotoExportResult) -> Void) {
        guard let donorURL = donorLivePhotoMovieURL else {
            completion(.degradedToVideo(clipURL,
                reason: "尚未提供真机 Live Photo 元数据样本；当前保留为普通视频。"))
            return
        }
        let asset = AVURLAsset(url: donorURL)
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            guard status == .loaded, asset.tracks(withMediaType: .metadata).count >= 2 else {
                completion(.degradedToVideo(clipURL,
                    reason: "样本未包含两条可验证的实况元数据轨道，当前保留为普通视频。"))
                return
            }
            completion(.degradedToVideo(clipURL,
                reason: "检测到候选元数据，但内容标识、StillImageTime、MakerNote 和 PhotoKit 成对校验仍未完成。"))
        }
    }
}
