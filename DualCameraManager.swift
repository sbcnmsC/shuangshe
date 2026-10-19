import AVFoundation
import CoreImage
import Photos
import UIKit

enum CameraMode: String, CaseIterable, Identifiable {
    case frontBack = "前 + 后"
    case wideUltra = "广角 + 超广角"
    var id: String { rawValue }
}

/// 同时驱动两颗摄像头的管理器（AVCaptureMultiCamSession）。
/// A = 后置广角（主摄），B = 前置 或 后置超广角（取决于模式）。
final class DualCameraManager: NSObject, ObservableObject {

    // MARK: 对外状态
    @Published var mode: CameraMode = .frontBack
    @Published var layout: LayoutMode = .pip { didSet { syncRenderState() } }
    @Published var swapped = false { didSet { syncRenderState() } }
    @Published var saveRaw = true            // 同时保存两路原片
    @Published var isReady = false
    @Published var isRecording = false
    @Published var elapsed = 0
    @Published var statusText: String?

    let session: AVCaptureMultiCamSession
    let layerA: AVCaptureVideoPreviewLayer
    let layerB: AVCaptureVideoPreviewLayer

    // MARK: 内部
    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let frameQueue = DispatchQueue(label: "dualcam.frames")
    private let outputA = AVCaptureVideoDataOutput()
    private let outputB = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ciContext = CIContext()
    private var configured = false

    // 被 lock 保护（主线程写，帧队列读）
    private let lock = NSLock()
    private var bufferA: CVPixelBuffer?
    private var bufferB: CVPixelBuffer?
    private var renderLayout: LayoutMode = .pip
    private var renderSwapped = false
    private var audioSettings: [String: Any]?

    // 只在 frameQueue 上访问
    private var writerComposite: MovieWriter?
    private var writerA: MovieWriter?
    private var writerB: MovieWriter?

    private var timer: Timer?

    override init() {
        let s = AVCaptureMultiCamSession()
        session = s
        layerA = AVCaptureVideoPreviewLayer(sessionWithNoConnection: s)
        layerB = AVCaptureVideoPreviewLayer(sessionWithNoConnection: s)
        super.init()
        layerA.videoGravity = .resizeAspectFill
        layerB.videoGravity = .resizeAspectFill

        NotificationCenter.default.addObserver(
            self, selector: #selector(runtimeError),
            name: .AVCaptureSessionRuntimeError, object: session)
    }

    private func syncRenderState() {
        lock.lock()
        renderLayout = layout
        renderSwapped = swapped
        lock.unlock()
    }

    // MARK: - 生命周期

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.setStatus("请在「设置」中允许相机权限", autoClear: false)
                return
            }
            // 麦克风可选：拒绝了也能用，只是录像没声音
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                let mode = DispatchQueue.main.sync { self.mode }
                self.sessionQueue.async { self.configureAndRun(mode: mode) }
            }
        }
    }

    func reconfigure() {
        guard !isRecording else { return }
        let mode = self.mode
        DispatchQueue.main.async { self.isReady = false }
        sessionQueue.async { self.configureAndRun(mode: mode) }
    }

    func resume() {
        sessionQueue.async {
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func pause() {
        if isRecording { stopRecording() }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    @objc private func runtimeError(_ note: Notification) {
        sessionQueue.async {
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    // MARK: - 配置会话

    private enum BuildFailure {
        case cost
        case other(String)
    }

    private func configureAndRun(mode: CameraMode) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            setStatus("此设备不支持多摄像头同时采集（需 iPhone XS / XR 及以上，且不能用模拟器）", autoClear: false)
            return
        }
        if session.isRunning { session.stopRunning() }
        configured = false

        // 分辨率从高到低尝试，直到硬件开销 <= 1
        var failure: BuildFailure?
        var success = false
        for width in [Int32(1920), 1280, 640] {
            failure = build(mode: mode, maxWidth: width)
            if failure == nil { success = true; break }
            if case .other = failure! { break }
        }

        guard success else {
            switch failure {
            case .other(let msg): setStatus(msg, autoClear: false)
            default: setStatus("硬件资源不足，无法同时开启这两颗摄像头", autoClear: false)
            }
            return
        }

        configured = true
        session.startRunning()
        DispatchQueue.main.async {
            self.isReady = true
            self.statusText = nil
        }
    }

    private func build(mode: CameraMode, maxWidth: Int32) -> BuildFailure? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 清空旧配置
        session.connections.forEach { session.removeConnection($0) }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        lock.lock(); audioSettings = nil; lock.unlock()

        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return .other("找不到后置广角摄像头")
        }

        let second: AVCaptureDevice?
        switch mode {
        case .frontBack:
            second = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .wideUltra:
            second = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        }
        guard let second else {
            return .other("这台 iPhone 没有所选模式需要的摄像头（超广角需 iPhone 11 及以上）")
        }

        if let err = wire(back, output: outputA, layer: layerA, maxWidth: maxWidth) { return .other(err) }
        if let err = wire(second, output: outputB, layer: layerB, maxWidth: maxWidth) { return .other(err) }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            _ = wireAudio()   // 失败就当没有麦克风
        }

        if session.hardwareCost > 1.0 || session.systemPressureCost > 1.0 {
            return .cost
        }
        return nil
    }

    /// 把一颗摄像头的 input → 数据输出 + 预览层 手动连起来。返回错误信息（nil = 成功）。
    private func wire(_ device: AVCaptureDevice,
                      output: AVCaptureVideoDataOutput,
                      layer: AVCaptureVideoPreviewLayer,
                      maxWidth: Int32) -> String? {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "无法添加摄像头输入" }
            session.addInputWithNoConnections(input)

            try configureFormat(device, maxWidth: maxWidth)

            guard let port = input.ports(for: .video,
                                         sourceDeviceType: device.deviceType,
                                         sourceDevicePosition: device.position).first else {
                return "找不到摄像头视频端口"
            }

            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { return "无法添加视频输出" }
            session.addOutputWithNoConnections(output)

            let dataConn = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(dataConn) else { return "这两颗摄像头无法同时使用" }
            session.addConnection(dataConn)

            let previewConn = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard session.canAddConnection(previewConn) else { return "无法连接预览层" }
            session.addConnection(previewConn)

            // 竖屏；前置镜像（所见即所得）
            let mirrored = device.position == .front
            for conn in [dataConn, previewConn] {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = mirrored
                }
            }
            return nil
        } catch {
            return "摄像头配置失败：\(error.localizedDescription)"
        }
    }

    private func wireAudio() -> Bool {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)

        guard let port = input.ports(for: .audio,
                                     sourceDeviceType: mic.deviceType,
                                     sourceDevicePosition: .unspecified).first else { return false }

        audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(audioOutput) else { return false }
        session.addOutputWithNoConnections(audioOutput)

        let conn = AVCaptureConnection(inputPorts: [port], output: audioOutput)
        guard session.canAddConnection(conn) else { return false }
        session.addConnection(conn)

        let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        lock.lock(); audioSettings = settings; lock.unlock()
        return true
    }

    /// 选一个支持多摄同时采集、30fps、宽度不超过 maxWidth 的最大分辨率格式。
    private func configureFormat(_ device: AVCaptureDevice, maxWidth: Int32) throws {
        func area(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        let candidates = device.formats.filter { f in
            guard f.isMultiCamSupported else { return false }
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width <= maxWidth else { return false }
            return f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        guard let best = candidates.max(by: { area($0) < area($1) }) else {
            throw NSError(domain: "DualCam", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的多摄像头格式"])
        }
        try device.lockForConfiguration()
        device.activeFormat = best
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    // MARK: - 拍照

    /// 同时拍下两颗摄像头当前画面：合成图（按当前布局）+ 可选两张原图。
    func capture() {
        lock.lock()
        let a = bufferA, b = bufferB
        lock.unlock()

        guard let a, let b else {
            setStatus("画面还没准备好")
            return
        }
        let layout = self.layout, swapped = self.swapped, raw = self.saveRaw

        DispatchQueue.global(qos: .userInitiated).async {
            var images: [UIImage] = []
            let ci = Compositor.render(a: a, b: b, layout: layout, swapped: swapped)
            if let cg = self.ciContext.createCGImage(ci, from: Compositor.bounds) {
                images.append(UIImage(cgImage: cg))
            }
            if raw {
                if let imgA = self.image(from: a) { images.append(imgA) }
                if let imgB = self.image(from: b) { images.append(imgB) }
            }
            self.saveImages(images)
        }
    }

    private func image(from buffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private func saveImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.setStatus("请在「设置」中允许保存到相册", autoClear: false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                images.forEach { PHAssetChangeRequest.creationRequestForAsset(from: $0) }
            }) { ok, error in
                self.setStatus(ok ? "已保存 \(images.count) 张照片" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            }
        }
    }

    // MARK: - 录像

    func startRecording() {
        guard isReady, !isRecording else { return }
        let raw = saveRaw
        lock.lock(); let settings = audioSettings; lock.unlock()

        isRecording = true
        elapsed = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsed += 1
        }

        frameQueue.async {
            self.writerComposite = MovieWriter(audioSettings: settings)
            self.writerA = raw ? MovieWriter(audioSettings: settings) : nil
            self.writerB = raw ? MovieWriter(audioSettings: settings) : nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        frameQueue.async {
            let writers = [self.writerComposite, self.writerA, self.writerB].compactMap { $0 }
            self.writerComposite = nil
            self.writerA = nil
            self.writerB = nil

            var results = [URL?](repeating: nil, count: writers.count)
            let resultLock = NSLock()
            let group = DispatchGroup()
            for (i, w) in writers.enumerated() {
                group.enter()
                w.finish { url in
                    resultLock.lock(); results[i] = url; resultLock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .global()) {
                self.saveVideos(results.compactMap { $0 })
            }
        }
    }

    private func saveVideos(_ urls: [URL]) {
        guard !urls.isEmpty else {
            setStatus("录像失败，没有生成视频")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.setStatus("请在「设置」中允许保存到相册", autoClear: false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                urls.forEach { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: $0) }
            }) { ok, error in
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
                self.setStatus(ok ? "已保存 \(urls.count) 个视频" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            }
        }
    }

    // MARK: - 状态提示

    private func setStatus(_ text: String, autoClear: Bool = true) {
        DispatchQueue.main.async {
            self.statusText = text
            guard autoClear else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if self.statusText == text { self.statusText = nil }
            }
        }
    }
}

// MARK: - 帧回调（视频 + 音频都在 frameQueue 上）

extension DualCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // 音频：分发给所有正在录的文件
        if output === audioOutput {
            writerComposite?.appendAudio(sampleBuffer)
            writerA?.appendAudio(sampleBuffer)
            writerB?.appendAudio(sampleBuffer)
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        if output === outputA { bufferA = pixelBuffer }
        else if output === outputB { bufferB = pixelBuffer }
        let a = bufferA, b = bufferB
        let layout = renderLayout, swapped = renderSwapped
        lock.unlock()

        if output === outputA {
            // 原片 A
            if let w = writerA {
                if !w.isStarted {
                    w.start(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer), at: pts)
                }
                w.append(pixelBuffer, at: pts)
            }
            // 合成视频：以 A 的帧为节拍，叠上 B 的最新一帧
            if let w = writerComposite, let a, let b {
                if !w.isStarted {
                    w.start(width: Int(Compositor.size.width),
                            height: Int(Compositor.size.height), at: pts)
                }
                if let canvas = w.newPixelBuffer() {
                    let image = Compositor.render(a: a, b: b, layout: layout, swapped: swapped)
                    ciContext.render(image, to: canvas)
                    w.append(canvas, at: pts)
                }
            }
        } else if output === outputB {
            if let w = writerB {
                if !w.isStarted {
                    w.start(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer), at: pts)
                }
                w.append(pixelBuffer, at: pts)
            }
        }
    }
}
