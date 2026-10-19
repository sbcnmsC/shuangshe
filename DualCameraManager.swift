import AVFoundation
import CoreImage
import Photos
import UIKit

enum CameraMode: String, CaseIterable, Identifiable {
    case frontBack = "前 + 后"
    case wideUltra = "广角 + 超广角"
    case wideTele = "广角 + 长焦"
    var id: String { rawValue }
}

/// 白平衡预设。自定义用色温滑杆（wbTemperature）。
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
        case .auto: return nil
        case .daylight: return 5200
        case .cloudy: return 6500
        case .tungsten: return 3000
        case .fluorescent: return 4200
        case .custom: return nil
        }
    }
}

/// 同时驱动两颗摄像头的管理器（AVCaptureMultiCamSession）。
/// A = 后置广角（主摄），B = 前置 / 后置超广角 / 后置长焦（取决于模式）。
/// 手动参数（曝光补偿、ISO/快门、白平衡、变焦、对焦/曝光点、AE/AF 锁定）
/// 全部作用于「当前主画面」镜头，副镜头保持自动，保证合成画面所见即所得。
final class DualCameraManager: NSObject, ObservableObject {

    // MARK: 对外状态
    @Published var mode: CameraMode = .frontBack { didSet { onModeChanged() } }
    @Published var layout: LayoutMode = .pip { didSet { syncRenderState() } }
    @Published var swapped = false { didSet { syncRenderState() } }
    @Published var saveRaw = true            // 同时保存两路原片
    @Published var isReady = false
    @Published var isRecording = false
    @Published var elapsed = 0
    @Published var statusText: String?

    // MARK: 相机参数（作用于主画面镜头）
    /// 曝光补偿 EV（-2 ... +2）
    @Published var ev: Float = 0 { didSet { applyActiveSettings() } }
    /// 手动 ISO / 快门开关
    @Published var manualExposure = false { didSet { applyActiveSettings() } }
    /// 手动 ISO
    @Published var iso: Float = 200 { didSet { applyActiveSettings() } }
    /// 手动快门时长（秒）
    @Published var shutter: Double = 1.0 / 120.0 { didSet { applyActiveSettings() } }
    /// 白平衡预设
    @Published var wbPreset: WBPreset = .auto { didSet { applyActiveSettings() } }
    /// 自定义色温（K）
    @Published var wbTemperature: Float = 5000 { didSet { applyActiveSettings() } }
    /// 变焦倍数（主画面镜头）
    @Published var zoom: CGFloat = 1.0 { didSet { applyZoom() } }
    /// 拍照闪光灯
    @Published var flashOn = false
    /// AE / AF 锁定（防止曝光、对焦在拍摄中漂移）
    @Published var aeAfLocked = false { didSet { applyActiveSettings() } }
    /// 对焦框指示位置（屏幕坐标，UI 用）
    @Published var focusIndicator: CGPoint?
    /// 点按对焦后短暂显示的 EV 徽章
    @Published var evIndicator: Float?

    let session: AVCaptureMultiCamSession
    let layerA: AVCaptureVideoPreviewLayer
    let layerB: AVCaptureVideoPreviewLayer

    // MARK: 内部
    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let frameQueue = DispatchQueue(label: "dualcam.frames")
    private let paramQueue = DispatchQueue(label: "dualcam.params")
    private let outputA = AVCaptureVideoDataOutput()
    private let outputB = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ciContext = CIContext()
    private var configured = false

    private var deviceA: AVCaptureDevice?
    private var deviceB: AVCaptureDevice?

    /// 当前主画面镜头（手动参数的作用对象）。
    var activeDevice: AVCaptureDevice? { swapped ? deviceB : deviceA }

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

    private func onModeChanged() {
        swapped = false
        reconfigure()
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

        // 分辨率从高到低、帧率从高到低尝试，直到硬件开销 <= 1（优先 1080p60，资源不足自动降级）
        var failure: BuildFailure?
        var success = false
    outer: for width in [Int32(1920), 1280, 640] {
            for fps in [Int32(60), 30] {
                failure = build(mode: mode, maxWidth: width, fps: fps)
                if failure == nil { success = true; break outer }
                if case .other = failure! { break }
            }
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
            // 新会话就绪后恢复用户参数（新格式下 zoom 会被重置为 1）
            self.applyActiveSettings()
            self.applyZoom()
        }
    }

    private func build(mode: CameraMode, maxWidth: Int32, fps: Int32) -> BuildFailure? {
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
        case .wideTele:
            second = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        }
        guard let second else {
            return .other("这台 iPhone 没有所选模式需要的摄像头（超广角需 iPhone 11 及以上，长焦需 iPhone 7 Plus / 11 Pro 及以上）")
        }

        if let err = wire(back, output: outputA, layer: layerA, maxWidth: maxWidth, fps: fps) { return .other(err) }
        if let err = wire(second, output: outputB, layer: layerB, maxWidth: maxWidth, fps: fps) { return .other(err) }

        deviceA = back
        deviceB = second

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
                      maxWidth: Int32,
                      fps: Int32) -> String? {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "无法添加摄像头输入" }
            session.addInputWithNoConnections(input)

            try configureFormat(device, maxWidth: maxWidth, fps: fps)

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
                // 视频稳定：多摄下若硬件不支持会被系统忽略，不影响采集
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = .auto
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

    /// 选一个支持多摄同时采集、指定帧率、宽度不超过 maxWidth 的最大分辨率格式。
    private func configureFormat(_ device: AVCaptureDevice, maxWidth: Int32, fps: Int32) throws {
        func area(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        let fpsD = Double(fps)
        let candidates = device.formats.filter { f in
            guard f.isMultiCamSupported else { return false }
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width <= maxWidth else { return false }
            return f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fpsD && $0.maxFrameRate >= fpsD }
        }
        guard let best = candidates.max(by: { area($0) < area($1) }) else {
            throw NSError(domain: "DualCam", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用的多摄像头格式"])
        }
        try device.lockForConfiguration()
        device.activeFormat = best
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
        device.unlockForConfiguration()
    }

    // MARK: - 参数设置（iPhone 原相机风格的曝光 / 白平衡 / 对焦 / 变焦）

    /// 把当前 UI 参数应用到主画面镜头（在 paramQueue 串行执行，避免与配置并发）。
    func applyActiveSettings() {
        guard configured, let device = activeDevice else { return }
        let ev = self.ev
        let manual = self.manualExposure
        let iso = self.iso
        let shutter = self.shutter
        let preset = self.wbPreset
        let temp = self.wbTemperature
        let locked = self.aeAfLocked

        paramQueue.async {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                // 1) 曝光：锁定 > 手动 ISO/快门 > 自动 + 曝光补偿
                if locked {
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                } else if manual, device.isExposureModeSupported(.custom) {
                    let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: duration, iso: iso) { _ in }
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                    let minB = device.minExposureTargetBias
                    let maxB = device.maxExposureTargetBias
                    device.setExposureTargetBias(min(max(ev, minB), maxB)) { _ in }
                }

                // 2) 对焦（AE/AF 锁定时同步锁定对焦，防止漂移）
                if locked, device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }

                // 3) 白平衡：自动 / 指定色温锁定
                switch preset {
                case .auto:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                default:
                    let t = preset.temperature ?? temp
                    let gains = device.deviceWhiteBalanceGains(for:
                        AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: t, tint: 0))
                    let maxG = device.maxWhiteBalanceGain
                    let clamped = AVCaptureDevice.WhiteBalanceGains(
                        redGain: min(gains.redGain, maxG),
                        greenGain: min(gains.greenGain, maxG),
                        blueGain: min(gains.blueGain, maxG))
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.setWhiteBalanceModeLocked(with: clamped)
                    }
                }
            } catch {}
        }
    }

    /// 变焦（上限同时受镜头光学变焦能力与 8x 数字变焦限制）。
    func applyZoom() {
        guard configured, let device = activeDevice else { return }
        let factor = self.zoom
        paramQueue.async {
            let maxZ = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            let target = min(max(factor, 1.0), maxZ)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setZoom(_ factor: CGFloat) {
        zoom = factor
    }

    /// 点按预览：对主画面镜头单次对焦 + 自动曝光（手动曝光模式下只对焦）。
    /// - Parameters:
    ///   - layerPoint: layer 坐标系中的点击位置（已按画中画/分屏换算）
    ///   - layer: 被点击的预览层（据此确定作用镜头）
    ///   - indicator: 屏幕上用于显示对焦框 / EV 徽章的位置
    func focusAndExpose(atLayerPoint layerPoint: CGPoint,
                        in layer: AVCaptureVideoPreviewLayer,
                        indicator: CGPoint) {
        guard configured else { return }
        let device = (layer === layerA) ? deviceA : deviceB
        guard let device else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        let manual = manualExposure
        if aeAfLocked { aeAfLocked = false }

        paramQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if !manual, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }

        DispatchQueue.main.async {
            self.focusIndicator = indicator
            self.evIndicator = self.ev
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if self.focusIndicator == indicator { self.focusIndicator = nil }
                if self.evIndicator == self.ev { self.evIndicator = nil }
            }
        }
    }

    /// 上下滑动调节曝光补偿（上滑加亮，等价 iPhone 原相机 EV 手势）。
    func adjustEV(by delta: Float) {
        ev = min(max(ev + delta, -2.0), 2.0)
        evIndicator = ev
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.evIndicator == self.ev { self.evIndicator = nil }
            }
        }
    }

    func toggleAEAFLock() {
        aeAfLocked.toggle()
    }

    // MARK: - 闪光灯（拍照打光；录像不用，避免长时间亮灯过热）

    private var torchCapable: Bool {
        guard let d = activeDevice else { return false }
        return d.hasTorch && d.isTorchAvailable
    }

    private func setTorch(_ on: Bool) {
        guard let d = activeDevice, d.hasTorch else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        } catch {}
    }

    // MARK: - 拍照

    /// 同时拍下两颗摄像头当前画面：合成图（按当前布局）+ 可选两张原图。
    /// 开了闪光灯时，先打光约 0.18s 让传感器稳定，再抓帧保存。
    func capture() {
        let useFlash = flashOn && torchCapable

        DispatchQueue.global(qos: .userInitiated).async {
            if useFlash {
                self.setTorch(true)
                Thread.sleep(forTimeInterval: 0.18)
            }
            defer { if useFlash { self.setTorch(false) } }

            self.lock.lock()
            let a = self.bufferA, b = self.bufferB
            self.lock.unlock()

            guard let a, let b else {
                self.setStatus("画面还没准备好")
                return
            }
            let layout = self.layout, swapped = self.swapped, raw = self.saveRaw

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
