import AVFoundation
import Combine
import Photos

@MainActor
final class DualCameraSessionModel: ObservableObject {
    @Published private(set) var engine: DualCameraSession?
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isMultiCameraActive = false
    @Published private(set) var hardwareCost: Float = 0
    @Published var statusText = "等待相机权限"
    @Published var lastError: String?
    let frameStore = PreviewFrameStore()
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var recordingURL: URL?

    func start(settings: CaptureSettings) {
        guard !started else { return }
        started = true
        Task {
            let authorized: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            guard authorized else {
                lastError = "请在系统设置中允许 DualCamLive 使用相机。"
                statusText = lastError ?? ""
                started = false
                return
            }
            let mic: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: mic = true
            case .notDetermined: mic = await AVCaptureDevice.requestAccess(for: .audio)
            default: mic = false
            }
            guard let compositor = MetalCompositor(width: settings.outputWidth, height: settings.outputHeight) else {
                lastError = "Metal 合成器初始化失败。"
                started = false
                return
            }
            let layout = CompositeLayout(
                pictureInPicture: settings.layout == .pictureInPicture,
                primaryFront: settings.primaryFront,
                insetRect: settings.pipRect,
                cornerRadiusPx: Float(settings.cornerRadius),
                mirrorFront: settings.mirrorFrontCamera,
                splitVertical: true
            )
            let capture = DualCameraSession(compositor: compositor, layout: layout, recordAudio: mic)
            capture.onFrame = { [weak frameStore] frame in frameStore?.publish(frame) }
            capture.onError = { [weak self] message in
                DispatchQueue.main.async { self?.lastError = message; self?.statusText = message }
            }
            capture.onThermal = { [weak self] state in
                if state == .serious || state == .critical {
                    DispatchQueue.main.async { self?.statusText = "设备温度较高，建议降低分辨率或帧率。" }
                }
            }
            engine = capture
            capture.configureAndStart()
            isRunning = true
            isMultiCameraActive = AVCaptureMultiCamSession.isMultiCamSupported
            statusText = isMultiCameraActive ? "双摄会话已启动（请在真机验证）" : "当前设备不支持双摄并发"
        }
    }

    func apply(settings: CaptureSettings) {
        guard let engine else { return }
        engine.setLayout(CompositeLayout(
            pictureInPicture: settings.layout == .pictureInPicture,
            primaryFront: settings.primaryFront,
            insetRect: settings.pipRect,
            cornerRadiusPx: Float(settings.cornerRadius),
            mirrorFront: settings.mirrorFrontCamera,
            splitVertical: true
        ))
        engine.setFilter(settings.filter, strength: settings.filterStrength)
    }

    func startRecording() {
        guard let engine, isRunning, !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DualCamLive-\(UUID().uuidString).mp4")
        recordingURL = url
        engine.startRecording(url: url, hevc: true)
        isRecording = true
        statusText = "正在录制合成视频…"
    }

    func stopRecording() {
        guard let engine, isRecording else { return }
        engine.stopRecording { [weak self] url in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isRecording = false
                guard let url else { self.lastError = "视频写入失败"; return }
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else { return }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }) { success, error in
                        DispatchQueue.main.async {
                            self.statusText = success ? "视频已保存到照片" : (error?.localizedDescription ?? "保存失败")
                        }
                    }
                }
            }
        }
    }

    func takePhoto() {
        guard let engine, isRunning else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DualCamLive-\(UUID().uuidString).jpg")
        engine.takePhoto(url: url) { [weak self] success in
            guard let self else { return }
            guard success else { DispatchQueue.main.async { self.lastError = "当前没有可保存的合成画面" }; return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async { self.statusText = success ? "照片已保存到照片" : (error?.localizedDescription ?? "保存失败") }
                }
            }
        }
    }

    func stop() {
        engine?.stop { [weak self] in
            DispatchQueue.main.async {
                self?.engine = nil
                self?.isRunning = false
                self?.isRecording = false
                self?.started = false
                self?.statusText = "相机已关闭"
            }
        }
    }
}
