import Photos
import SwiftUI
import AVFoundation

struct MediaGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var assets: [PHAsset] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var selectedAsset: PHAsset?
    @State private var previewImage: UIImage?
    @State private var showImagePreview = false
    @State private var convertingID: String?
    @State private var statusMessage: String?
    @State private var showStatus = false
    @State private var accessDenied = false

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if accessDenied {
                    ContentUnavailableView("需要照片权限",
                                           systemImage: "photo.badge.exclamationmark",
                                           description: Text("请在系统设置中允许 DualCam 访问照片图库。"))
                } else if assets.isEmpty {
                    ContentUnavailableView("还没有照片或视频",
                                           systemImage: "photo.on.rectangle.angled",
                                           description: Text("拍摄的照片和视频会显示在这里。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                Button { select(asset) } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        GalleryThumbnail(image: thumbnails[asset.localIdentifier])
                                            .aspectRatio(0.78, contentMode: .fill)
                                            .frame(maxWidth: .infinity)
                                            .clipped()
                                        if asset.mediaType == .video {
                                            HStack(spacing: 4) {
                                                Image(systemName: "play.fill")
                                                Text(duration(asset.duration))
                                            }
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 5)
                                            .background(.black.opacity(0.6), in: Capsule())
                                            .padding(6)
                                        } else if asset.mediaSubtypes.contains(.photoLive) {
                                            Image(systemName: "livephoto")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(6)
                                                .background(.black.opacity(0.6), in: Circle())
                                                .padding(6)
                                        }
                                        if convertingID == asset.localIdentifier {
                                            ProgressView().tint(.white)
                                                .padding(10)
                                                .background(.black.opacity(0.65), in: Circle())
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(convertingID != nil)
                                .contextMenu {
                                    if asset.mediaType == .video {
                                        Button {
                                            convert(asset)
                                        } label: {
                                            Label("转换为实况照片", systemImage: "livephoto")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .background(Color.black)
                }
            }
            .navigationTitle("照片图库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { loadAssets() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新图库")
                }
            }
            .task { requestAccessAndLoad() }
            .confirmationDialog("视频操作", isPresented: Binding(
                get: { selectedAsset != nil && selectedAsset?.mediaType == .video && convertingID == nil },
                set: { if !$0 { selectedAsset = nil } }
            ), titleVisibility: .visible) {
                Button("转换为实况照片") {
                    if let asset = selectedAsset { convert(asset) }
                }
                Button("取消", role: .cancel) { selectedAsset = nil }
            } message: {
                Text("将截取视频中间最多 3 秒，生成可在系统照片中按住播放的实况照片。")
            }
            .sheet(isPresented: $showImagePreview) {
                if let previewImage {
                    NavigationStack {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .padding(8)
                        }
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { showImagePreview = false }
                            }
                        }
                    }
                    .preferredColorScheme(.dark)
                }
            }
            .alert("图库", isPresented: $showStatus) {
                Button("好", role: .cancel) {}
            } message: {
                Text(statusMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func requestAccessAndLoad() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    accessDenied = true
                    return
                }
                accessDenied = false
                loadAssets()
            }
        }
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 300
        let result = PHAsset.fetchAssets(with: options)
        var next: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in next.append(asset) }
        assets = next
        thumbnails.removeAll(keepingCapacity: true)
        for asset in next {
            let size = CGSize(width: 360, height: 460)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            PHImageManager.default().requestImage(for: asset, targetSize: size,
                                                  contentMode: .aspectFill, options: options) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async { thumbnails[asset.localIdentifier] = image }
            }
        }
    }

    private func select(_ asset: PHAsset) {
        if asset.mediaType == .video {
            selectedAsset = asset
            return
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: PHImageManagerMaximumSize,
                                              contentMode: .aspectFit,
                                              options: options) { image, info in
            guard let image, (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
            DispatchQueue.main.async {
                previewImage = image
                showImagePreview = true
            }
        }
    }

    private func convert(_ asset: PHAsset) {
        guard asset.mediaType == .video else { return }
        selectedAsset = nil
        convertingID = asset.localIdentifier
        let options = PHVideoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
            guard let avAsset else {
                DispatchQueue.main.async {
                    convertingID = nil
                    statusMessage = info?[PHImageErrorKey] as? String ?? "无法读取此视频。"
                    showStatus = true
                }
                return
            }
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("DualCam-gallery-\(UUID().uuidString).mov")
            let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality)
            guard let export else {
                DispatchQueue.main.async {
                    convertingID = nil
                    statusMessage = "无法准备视频导出。"
                    showStatus = true
                }
                return
            }
            export.outputURL = source
            export.outputFileType = .mov
            export.shouldOptimizeForNetworkUse = true
            export.exportAsynchronously {
                guard export.status == .completed else {
                    try? FileManager.default.removeItem(at: source)
                    DispatchQueue.main.async {
                        convertingID = nil
                        statusMessage = export.error?.localizedDescription ?? "视频导出失败。"
                        showStatus = true
                    }
                    return
                }
                LivePhotoConverter.shared.convertVideoToLivePhoto(from: source) { result in
                    try? FileManager.default.removeItem(at: source)
                    convertingID = nil
                    switch result {
                    case .success:
                        statusMessage = "已将视频转换为实况照片并保存到系统图库。"
                        loadAssets()
                    case .failure(let error):
                        statusMessage = error.localizedDescription
                    }
                    showStatus = true
                }
            }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct GalleryThumbnail: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }
}
