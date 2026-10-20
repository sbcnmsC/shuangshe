import AVFoundation
import Combine
import CoreImage
import ImageIO
import Photos
import UIKit

/// 同时驱动两颗摄像头的管理器（AVCaptureMultiCamSession）。
/// A = 后置广角（主摄），B = 前置 / 后置超广角 / 后置长焦（取决于模式）。
///
/// 画面流程：两路相机帧 → Core Image 合成（小窗 / 分屏 + 滤镜）→ 同一帧同时用于
/// 预览（AVSampleBufferDisplayLayer）、拍照、录像，所以所见即所得。
/// 手动参数（曝光补偿、ISO/快门、白平衡、变焦、对焦）作用于「当前主画面」镜头，
/// 副镜头保持自动。
final class DualCameraManager: NSObject, ObservableObject {

    // MARK: - 对外状态

    @Published var mode: CameraMode = .frontBack { didSet { onModeChanged() } }
    @Published var layout: LayoutMode = .pip { didSet { syncRenderState() } }
    @Published var swapped = false { didSet { onSwapChanged() } }
    @Published var saveRaw = false           // 默认不同时写入两路原片，降低多编码器负载
    @Published var isReady = false
    @Published var isRecording = false
    @Published var elapsed = 0
    @Published var statusText: String?

    // 小窗 / 分屏
    @Published var pip = PiPConfig() { didSet { syncRenderState() } }
    @Published var splitRatio: CGFloat = 0.5 { didSet { syncRenderState() } }

    // 滤镜
    @Published var filter: FilterPreset = .original { didSet { syncRenderState() } }
    @Published var filterStrength: CGFloat = 1 { didSet { syncRenderState() } }

    // 输出画面
    @Published var aspect: AspectPreset = .tall { didSet { updateCanvas() } }
    @Published var resolution: ResolutionPreset = .p1080 { didSet { onQualityChanged() } }
    @Published var fps: FPSOption = .f30 { didSet { onQualityChanged() } }
    @Published private(set) var canvasSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var activeFPS = 30
    @Published var lowLight = false { didSet { applyFrameDuration() } }
    @Published var stabilize = true { didSet { applyConnectionOptions() } }
    @Published var mirrorFront = true { didSet { applyConnectionOptions() } }
    @Published var showGrid = false
    @Published var timerSeconds = 0
    @Published var countdown: Int?
    @Published var flashOn = false

    // 相机参数（作用于主画面镜头）
    @Published var ev: Float = 0 { didSet { applyActiveSettings() } }
    @Published var manualExposure = false { didSet { applyActiveSettings() } }
    @Published var iso: Float = 200 { didSet { applyActiveSettings() } }
    @Published var shutter: Double = 1.0 / 120.0 { didSet { applyActiveSettings() } }
    @Published var wbPreset: WBPreset = .auto { didSet { applyActiveSettings() } }
    @Published var wbTemperature: Float = 5000 { didSet { applyActiveSettings() } }
    @Published var wbTint: Float = 0 { didSet { applyActiveSettings() } }
    @Published var manualFocus = false { didSet { applyActiveSettings() } }
    @Published var lensPosition: Float = 0.5 { didSet { applyActiveSettings() } }
    @Published var aeAfLocked = false { didSet { applyActiveSettings() } }
    /// 变焦倍数（「显示倍数」：超广角 0.5x 起，长焦按实际倍率）
    @Published var zoom: CGFloat = 1 { didSet { applyZoom() } }
    @Published var evIndicator: Float?

    // 由当前主镜头决定的取值范围
    @Published private(set) var zoomStops: [CGFloat] = [1, 2, 5]
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...5
    @Published private(set) var isoRange: ClosedRange<Float> = 25...1600
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    @Published private(set) var canManualFocus = false

    // MARK: - 内部

    let session: AVCaptureMultiCamSession
    /// 合成后的画面显示层（SwiftUI 里用 DisplayLayerView 展示）
    let displayLayer = AVSampleBufferDisplayLayer()
    /// 这两个预览层不显示，只用来把「点按位置」换算成对焦点（处理旋转 / 镜像）。
    private let layerA: AVCaptureVideoPreviewLayer
    private let layerB: AVCaptureVideoPreviewLayer

    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    private let frameQueue = DispatchQueue(label: "dualcam.frames")
    private let paramQueue = DispatchQueue(label: "dualcam.params")
    private let outputA = AVCaptureVideoDataOutput()
    private let outputB = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    /// 关闭颜色管理 + 不缓存中间结果：8-bit 管线里明显更省 GPU。
    private let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    private var configured = false
    private var hasStarted = false
    private var suppress = false

    private var deviceA: AVCaptureDevice?
    private var deviceB: AVCaptureDevice?
    private var connInfo: [(conn: AVCaptureConnection, front: Bool)] = []

    // 仅主线程访问
    private var sourceSizeA = CGSize(width: 1080, height: 1920)
    private var sourceSizeB = CGSize(width: 1080, height: 1920)
    private var activeBase: CGFloat = 1
    private var zoomStore: [Bool: CGFloat] = [:]      // key = swapped
    private var rampNext = false
    private var evHideWork: DispatchWorkItem?
    private var pipTween: Timer?
    private var countdownTimer: Timer?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    /// 当前主画面镜头（手动参数的作用对象）。
    var activeDevice: AVCaptureDevice? { swapped ? deviceB : deviceA }

    // 被 lock 保护（主线程写，帧队列读）
    private let lock = NSLock()
    private var bufferA: CVPixelBuffer?
    private var bufferB: CVPixelBuffer?
    private var renderState = RenderState()
    private var audioSettings: [String: Any]?
    private var recordFPS = 30
    private var redrawScheduled = false

    // 只在 frameQueue 上访问
    private var writerComposite: MovieWriter?
    private var writerA: MovieWriter?
    private var writerB: MovieWriter?
    private var liveCapturePending = false
    private var canvasPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    // 只在 paramQueue 上访问：点按对焦后保持对焦，直到画面内容明显变化
    private var focusHeld = false

    // MARK: - 偏好持久化

    private struct Prefs: Codable {
        var mode: CameraMode
        var layout: LayoutMode
        var saveRaw: Bool
        var pip: PiPConfig
        var splitRatio: CGFloat
        var filter: FilterPreset
        var filterStrength: CGFloat
        var aspect: AspectPreset
        var resolution: ResolutionPreset
        var fps: FPSOption
        var lowLight: Bool
        var stabilize: Bool
        var mirrorFront: Bool
        var showGrid: Bool
        var timerSeconds: Int
    }

    private let prefsKey = "dualcam.prefs.v2"

    private func persist() {
        let p = Prefs(mode: mode, layout: layout, saveRaw: saveRaw, pip: pip,
                      splitRatio: splitRatio, filter: filter, filterStrength: filterStrength,
                      aspect: aspect, resolution: resolution, fps: fps, lowLight: lowLight,
                      stabilize: stabilize, mirrorFront: mirrorFront, showGrid: showGrid,
                      timerSeconds: timerSeconds)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: prefsKey)
        }
    }

    // MARK: - 初始化

    override init() {
        let s = AVCaptureMultiCamSession()
        session = s
        layerA = AVCaptureVideoPreviewLayer(sessionWithNoConnection: s)
        layerB = AVCaptureVideoPreviewLayer(sessionWithNoConnection: s)
        super.init()

        suppress = true
        if let data = UserDefaults.standard.data(forKey: prefsKey),
           let p = try? JSONDecoder().decode(Prefs.self, from: data) {
            mode = p.mode
            layout = p.layout
            saveRaw = p.saveRaw
            pip = p.pip
            splitRatio = p.splitRatio
            filter = p.filter
            filterStrength = p.filterStrength
            aspect = p.aspect
            resolution = p.resolution
            fps = p.fps
            lowLight = p.lowLight
            stabilize = p.stabilize
            mirrorFront = p.mirrorFront
            showGrid = p.showGrid
            timerSeconds = p.timerSeconds
        }
        suppress = false

        layerA.videoGravity = .resizeAspectFill
        layerB.videoGravity = .resizeAspectFill
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor

        NotificationCenter.default.addObserver(
            self, selector: #selector(runtimeError),
            name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaChanged),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)

        updateCanvas()

        // 任何设置变化后停 0.8 秒再保存，避免拖滑杆时频繁写盘
        objectWillChange
            .debounce(for: .seconds(0.8), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &bag)
    }

    // MARK: - 状态同步

    private func syncRenderState() {
        var s = RenderState()
        s.layout = layout
        s.swapped = swapped
        s.pip = pip
        s.splitRatio = splitRatio
        s.filter = filter
        s.filterStrength = filterStrength
        s.canvas = canvasSize
        lock.lock()
        renderState = s
        lock.unlock()
        requestRedraw()
    }

    private func updateCanvas() {
        guard !suppress else { return }
        // The composite must not upscale the lower-resolution camera in a pair.
        let pairSource = CGSize(
            width: min(sourceSizeA.width, sourceSizeB.width),
            height: min(sourceSizeA.height, sourceSizeB.height)
        )
        let size = Compositor.canvasSize(aspect: aspect, resolution: resolution, source: pairSource)
        if size != canvasSize { canvasSize = size }
        syncRenderState()
    }

    private func onModeChanged() {
        guard !suppress else { return }
        if swapped { swapped = false }
        zoomStore = [:]
        reconfigure()
    }

    private func onQualityChanged() {
        guard !suppress else { return }
        updateCanvas()
        reconfigure()
    }

    /// 主 / 副画面互换：各镜头记住自己的变焦；旧主镜头恢复自动，新主镜头应用用户参数。
    private func onSwapChanged() {
        guard !suppress else { return }
        syncRenderState()
        guard configured else { return }
        let previous = swapped ? deviceA : deviceB
        refreshDeviceInfo()
        zoom = zoomStore[swapped] ?? activeBase
        if let previous {
            paramQueue.async { self.resetToAuto(previous) }
        }
        applyActiveSettings()
    }

    // MARK: - 生命周期

    func start() {
        if hasStarted { resume(); return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.setStatus("请在「设置」中允许相机权限", autoClear: false)
                return
            }
            // 麦克风可选：拒绝了也能用，只是录像没声音
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.hasStarted = true
                    let opts = self.currentOptions()
                    self.sessionQueue.async { self.configureAndRun(opts) }
                }
            }
        }
    }

    func reconfigure() {
        guard hasStarted, !isRecording else { return }
        let opts = currentOptions()
        isReady = false
        sessionQueue.async { self.configureAndRun(opts) }
    }

    func resume() {
        sessionQueue.async {
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    func pause() {
        if isRecording { stopRecording() }
        cancelCountdown()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    @objc private func runtimeError(_ note: Notification) {
        sessionQueue.async {
            if self.configured && !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// 点按对焦后，画面内容发生明显变化时回到连续自动对焦 / 曝光（和系统相机一致）。
    @objc private func subjectAreaChanged(_ note: Notification) {
        guard let dev = note.object as? AVCaptureDevice, dev === deviceA || dev === deviceB else { return }
        DispatchQueue.main.async {
            guard !self.aeAfLocked else { return }
            self.paramQueue.async {
                self.focusHeld = false
                self.resetToAuto(dev)
            }
            self.applyActiveSettings()
        }
    }

    // MARK: - 配置会话

    private struct SessionOptions {
        var mode: CameraMode
        var resolution: ResolutionPreset
        var fps: Int32
        var mirrorFront: Bool
        var stabilize: Bool
        var lowLight: Bool
    }

    private enum BuildFailure {
        case cost
        case other(String)
    }

    /// 必须在主线程调用。
    private func currentOptions() -> SessionOptions {
        SessionOptions(mode: mode, resolution: resolution, fps: Int32(fps.rawValue),
                       mirrorFront: mirrorFront, stabilize: stabilize, lowLight: lowLight)
    }

    private func configureAndRun(_ o: SessionOptions) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            setStatus("此设备不支持多摄像头同时采集（需 iPhone XS / XR 及以上，且不能用模拟器）", autoClear: false)
            return
        }
        if session.isRunning { session.stopRunning() }
        configured = false

        // 分辨率从高到低、帧率从高到低尝试，直到硬件开销 <= 1（资源不足时自动降级）
        var failure: BuildFailure?
        var success = false
        var usedFPS: Int32 = 30
        let fpsList: [Int32] = o.fps >= 60 ? [60, 30] : [30]
    outer: for width in o.resolution.sourceWidths {
            for f in fpsList {
                failure = build(o, maxWidth: width, fps: f)
                if failure == nil { success = true; usedFPS = f; break outer }
                // Format availability at 4K / 60 fps varies by device. Retry lower
                // formats and frame rates before surfacing a hard failure.
            }
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

        let sizeA = Self.portraitSize(deviceA)
        let sizeB = Self.portraitSize(deviceB)
        DispatchQueue.main.async {
            self.sourceSizeA = sizeA
            self.sourceSizeB = sizeB
            self.layerA.frame = CGRect(origin: .zero, size: sizeA)
            self.layerB.frame = CGRect(origin: .zero, size: sizeB)
            self.activeFPS = Int(usedFPS)
            self.lock.lock(); self.recordFPS = Int(usedFPS); self.lock.unlock()
            self.zoomStore = [:]
            self.refreshDeviceInfo()
            self.updateCanvas()
            self.isReady = true
            self.statusText = nil
            // 新会话就绪后恢复用户参数（新格式下 zoom 会被重置为 1）
            self.applyActiveSettings()
            self.zoom = self.activeBase
        }
    }

    private static func portraitSize(_ device: AVCaptureDevice?) -> CGSize {
        guard let device else { return CGSize(width: 1080, height: 1920) }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        // 数据输出已旋转成竖屏：宽高对调
        return CGSize(width: CGFloat(d.height), height: CGFloat(d.width))
    }

    private func build(_ o: SessionOptions, maxWidth: Int32, fps: Int32) -> BuildFailure? {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 清空旧配置
        session.connections.forEach { session.removeConnection($0) }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        connInfo = []
        lock.lock()
        audioSettings = nil
        bufferA = nil
        bufferB = nil
        lock.unlock()

        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return .other("找不到后置广角摄像头")
        }

        let second: AVCaptureDevice?
        switch o.mode {
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

        if let err = wire(back, output: outputA, layer: layerA, o: o, maxWidth: maxWidth, fps: fps) { return .other(err) }
        if let err = wire(second, output: outputB, layer: layerB, o: o, maxWidth: maxWidth, fps: fps) { return .other(err) }

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
                      o: SessionOptions,
                      maxWidth: Int32,
                      fps: Int32) -> String? {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "无法添加摄像头输入" }
            session.addInputWithNoConnections(input)

            try configureFormat(device, maxWidth: maxWidth, fps: fps, lowLight: o.lowLight)

            guard let port = input.ports(for: .video,
                                         sourceDeviceType: device.deviceType,
                                         sourceDevicePosition: device.position).first else {
                return "找不到摄像头视频端口"
            }

            // 4:2:0 双平面格式：比 BGRA 省带宽和功耗，Core Image 和编码器都直接支持
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
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

            let isFront = device.position == .front
            for conn in [dataConn, previewConn] {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = isFront ? o.mirrorFront : false
                }
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = o.stabilize ? .auto : .off
                }
                connInfo.append((conn, isFront))
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

    /// 选一个支持多摄同时采集、指定帧率、宽度不超过 maxWidth 的最大分辨率格式，
    /// 并打开连续自动对焦、平滑对焦、主体变化监测。
    private func configureFormat(_ device: AVCaptureDevice, maxWidth: Int32,
                                 fps: Int32, lowLight: Bool) throws {
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
        Self.applyDurations(device, fps: fps, lowLight: lowLight)

        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.unlockForConfiguration()
    }

    /// 帧率：目标帧率固定为最短帧时长；开「弱光增亮」时，
    /// 暗处允许帧率最多降到一半（不低于 15），让每帧曝光更久、画面更亮更干净。
    /// 调用前设备必须已 lockForConfiguration。
    private static func applyDurations(_ d: AVCaptureDevice, fps: Int32, lowLight: Bool) {
        let minD = CMTime(value: 1, timescale: fps)
        var maxD = minD
        if lowLight {
            let floorFPS = max(fps / 2, 15)
            let ok = d.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(floorFPS) }
            if ok { maxD = CMTime(value: 1, timescale: floorFPS) }
        }
        d.activeVideoMinFrameDuration = minD
        d.activeVideoMaxFrameDuration = maxD
    }

    func applyFrameDuration() {
        guard configured else { return }
        let fpsValue = Int32(activeFPS)
        let low = lowLight
        let devices = [deviceA, deviceB].compactMap { $0 }
        paramQueue.async {
            for d in devices {
                do {
                    try d.lockForConfiguration()
                    Self.applyDurations(d, fps: fpsValue, lowLight: low)
                    d.unlockForConfiguration()
                } catch {}
            }
        }
    }

    /// 防抖 / 前置镜像可以在会话运行中直接切换。
    func applyConnectionOptions() {
        guard configured else { return }
        let mirror = mirrorFront
        let stab = stabilize
        let info = connInfo
        sessionQueue.async {
            self.session.beginConfiguration()
            for (conn, front) in info {
                if front, conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = mirror
                }
                if conn.isVideoStabilizationSupported {
                    conn.preferredVideoStabilizationMode = stab ? .auto : .off
                }
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: - 镜头信息（变焦倍率、ISO / 快门范围）

    /// 超广角 / 长焦相对广角的倍率，用视场角换算并取整到 0.5。
    private static func zoomBase(for dev: AVCaptureDevice, wide: AVCaptureDevice?) -> CGFloat {
        switch dev.deviceType {
        case .builtInUltraWideCamera, .builtInTelephotoCamera:
            let isUltra = dev.deviceType == .builtInUltraWideCamera
            guard let wide else { return isUltra ? 0.5 : 2 }
            let fw = Double(wide.activeFormat.videoFieldOfView) * Double.pi / 180
            let fd = Double(dev.activeFormat.videoFieldOfView) * Double.pi / 180
            let ratio = tan(fw / 2) / tan(fd / 2)
            guard ratio.isFinite, ratio > 0.2 else { return isUltra ? 0.5 : 2 }
            return CGFloat(max(0.5, (ratio * 2).rounded() / 2))
        default:
            return 1
        }
    }

    private func refreshDeviceInfo() {
        guard let dev = activeDevice else { return }
        let base = Self.zoomBase(for: dev, wide: deviceA)
        activeBase = base

        let nativeMax = max(1, min(dev.activeFormat.videoMaxZoomFactor, 10 / base))
        let upper = max(base * nativeMax, base + 0.1)
        zoomRange = base...upper

        let multipliers: [CGFloat]
        switch dev.deviceType {
        case .builtInUltraWideCamera: multipliers = [1, 2, 4]
        case .builtInWideAngleCamera where dev.position == .back: multipliers = [1, 2, 5]
        default: multipliers = [1, 2]
        }
        var stops = multipliers.map { base * $0 }.filter { $0 <= upper + 0.01 }
        if stops.isEmpty { stops = [base] }
        zoomStops = stops

        let f = dev.activeFormat
        if f.maxISO > f.minISO { isoRange = f.minISO...f.maxISO }
        let lo = max(f.minExposureDuration.seconds, 1.0 / 8000)
        let hi = min(f.maxExposureDuration.seconds, 1.0 / 3)
        if hi > lo { shutterRange = lo...hi }
        canManualFocus = dev.isLockingFocusWithCustomLensPositionSupported
    }

    // MARK: - 参数设置

    private struct ParamSnapshot {
        var ev: Float
        var manual: Bool
        var iso: Float
        var shutter: Double
        var wb: WBPreset
        var temp: Float
        var tint: Float
        var locked: Bool
        var manualFocus: Bool
        var lens: Float
    }

    /// 把当前 UI 参数应用到主画面镜头（在 paramQueue 串行执行，避免与配置并发）。
    func applyActiveSettings() {
        guard configured, let device = activeDevice else { return }
        let snap = ParamSnapshot(ev: ev, manual: manualExposure, iso: iso, shutter: shutter,
                                 wb: wbPreset, temp: wbTemperature, tint: wbTint,
                                 locked: aeAfLocked, manualFocus: manualFocus, lens: lensPosition)
        paramQueue.async { self.applyParams(snap, to: device) }
    }

    private func applyParams(_ s: ParamSnapshot, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // 1) 曝光：锁定 > 手动 ISO/快门 > 自动 + 曝光补偿
            if s.locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else if s.manual, device.isExposureModeSupported(.custom) {
                let f = device.activeFormat
                let d = min(max(s.shutter, f.minExposureDuration.seconds), f.maxExposureDuration.seconds)
                let isoValue = min(max(s.iso, f.minISO), f.maxISO)
                device.setExposureModeCustom(
                    duration: CMTime(seconds: d, preferredTimescale: 1_000_000_000),
                    iso: isoValue) { _ in }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                let bias = min(max(s.ev, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(bias) { _ in }
            }

            // 2) 对焦：锁定 > 手动镜头位置 > 点按后保持 > 连续自动对焦
            if s.locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else if s.manualFocus, device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: min(max(s.lens, 0), 1)) { _ in }
            } else if !focusHeld, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            // 3) 白平衡：自动 / 指定色温 + 色调（增益限制在合法范围内，越界会直接崩溃）
            switch s.wb {
            case .auto:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            default:
                guard device.isWhiteBalanceModeSupported(.locked) else { break }
                let t = s.wb.temperature ?? s.temp
                let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: t, tint: s.tint)
                var g = device.deviceWhiteBalanceGains(for: tv)
                let mx = device.maxWhiteBalanceGain
                g.redGain = min(max(g.redGain, 1), mx)
                g.greenGain = min(max(g.greenGain, 1), mx)
                g.blueGain = min(max(g.blueGain, 1), mx)
                device.setWhiteBalanceModeLocked(with: g) { _ in }
            }
        } catch {}
    }

    /// 让一颗镜头完全回到自动（换主画面时用于旧主镜头）。在 paramQueue 上调用。
    private func resetToAuto(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                device.setExposureTargetBias(0) { _ in }
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        } catch {}
    }

    // MARK: 变焦

    /// 把「显示倍数」换算成镜头的实际变焦系数并应用。
    func applyZoom() {
        zoomStore[swapped] = zoom
        guard configured, let device = activeDevice else { return }
        let base = activeBase
        let maxNative = max(1, min(device.activeFormat.videoMaxZoomFactor, 10 / base))
        let native = min(max(zoom / base, 1), maxNative)
        let ramp = rampNext
        paramQueue.async {
            do {
                try device.lockForConfiguration()
                if ramp {
                    device.ramp(toVideoZoomFactor: native, withRate: 5)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = native
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// animated = true 时平滑过渡（点倍率按钮）；捏合手势用 false 直接跟手。
    func setZoom(_ factor: CGFloat, animated: Bool = false) {
        let v = min(max(factor, zoomRange.lowerBound), zoomRange.upperBound)
        rampNext = animated
        zoom = v
        rampNext = false
    }

    // MARK: 对焦 / 曝光

    /// 点按预览：u、v 是点击位置在合成画面里的归一化坐标（左上角为原点）。
    /// 自动判断点在主画面还是小窗 / 下半屏，并换算到对应镜头的对焦点。
    func tapFocus(u: CGFloat, v: CGFloat) {
        guard configured else { return }
        let W = canvasSize.width, H = canvasSize.height
        let point = CGPoint(x: u * W, y: v * H)

        var region = CGRect(x: 0, y: 0, width: W, height: H)
        var onSecond = false
        switch layout {
        case .pip:
            let r = pip.rect(in: canvasSize)
            if r.contains(point) { region = r; onSecond = true }
        case .split:
            let topH = (H * splitRatio).rounded()
            if point.y >= topH {
                region = CGRect(x: 0, y: topH, width: W, height: H - topH)
                onSecond = true
            } else {
                region = CGRect(x: 0, y: 0, width: W, height: topH)
            }
        }

        // 主画面 = swapped ? B : A；副画面相反
        let useB = onSecond ? !swapped : swapped
        let device = useB ? deviceB : deviceA
        let layer = useB ? layerB : layerA
        let src = useB ? sourceSizeB : sourceSizeA
        guard let device, region.width > 0, region.height > 0,
              src.width > 0, src.height > 0 else { return }

        // 区域内的位置 → 采集源上的位置（考虑「铺满裁切」造成的偏移）
        let lu = (point.x - region.minX) / region.width
        let lv = (point.y - region.minY) / region.height
        let s = max(region.width / src.width, region.height / src.height)
        let visW = region.width / (s * src.width)
        let visH = region.height / (s * src.height)
        let sx = 0.5 + (lu - 0.5) * visW
        let sy = 0.5 + (lv - 0.5) * visH
        let layerPoint = CGPoint(x: sx * layer.bounds.width, y: sy * layer.bounds.height)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        let manual = manualExposure
        if aeAfLocked { aeAfLocked = false }

        paramQueue.async {
            self.focusHeld = true
            do {
                try device.lockForConfiguration()
                device.isSubjectAreaChangeMonitoringEnabled = true
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
    }

    /// 曝光补偿（-2 ... +2），并在预览上短暂显示。
    func setEV(_ value: Float) {
        ev = min(max(value, -2), 2)
        evIndicator = ev
        evHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evIndicator = nil }
        evHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func toggleAEAFLock() {
        aeAfLocked.toggle()
    }

    // MARK: - 小窗

    /// 修改小窗外观（形状、比例、边框……）并保证位置仍在画面内。
    func updatePip(_ change: (inout PiPConfig) -> Void) {
        pipTween?.invalidate()
        var p = pip
        change(&p)
        pip = p.clamped(in: canvasSize)
    }

    func movePip(toCenterX x: CGFloat, y: CGFloat) {
        pipTween?.invalidate()
        var p = pip
        p.centerX = x
        p.centerY = y
        pip = p.clamped(in: canvasSize)
    }

    func resizePip(width: CGFloat) {
        var p = pip
        p.width = min(max(width, PiPConfig.minWidth), PiPConfig.maxWidth)
        pip = p.clamped(in: canvasSize)
    }

    /// 松手后吸附到边缘 / 中线，并用短动画过渡。
    func finishPipDrag() {
        var p = pip
        guard p.snap else { return }
        let W = canvasSize.width, H = canvasSize.height
        let r = p.rect(in: canvasSize)
        let margin = W * 0.04
        let thX = W * 0.08, thY = H * 0.05
        var cx = r.midX, cy = r.midY

        if r.minX < thX { cx = margin + r.width / 2 }
        else if W - r.maxX < thX { cx = W - margin - r.width / 2 }
        else if abs(r.midX - W / 2) < W * 0.03 { cx = W / 2 }

        if r.minY < thY { cy = margin + r.height / 2 }
        else if H - r.maxY < thY { cy = H - margin - r.height / 2 }
        else if abs(r.midY - H / 2) < H * 0.03 { cy = H / 2 }

        p.centerX = cx / W
        p.centerY = cy / H
        animatePip(to: p.clamped(in: canvasSize))
    }

    func resetPip() {
        var p = PiPConfig()
        p.aspect = pip.aspect
        p.shape = pip.shape
        animatePip(to: p.clamped(in: canvasSize))
    }

    private func animatePip(to target: PiPConfig, duration: TimeInterval = 0.2) {
        pipTween?.invalidate()
        let start = pip
        let t0 = CACurrentMediaTime()
        pipTween = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, (CACurrentMediaTime() - t0) / duration)
            let e = CGFloat(1 - pow(1 - k, 3))
            var p = target
            p.centerX = start.centerX + (target.centerX - start.centerX) * e
            p.centerY = start.centerY + (target.centerY - start.centerY) * e
            p.width = start.width + (target.width - start.width) * e
            self.pip = p
            if k >= 1 { t.invalidate(); self.pipTween = nil }
        }
    }

    // MARK: - 滤镜缩略图（用当前画面实时生成）

    func makeFilterThumbnails(_ completion: @escaping ([FilterPreset: UIImage]) -> Void) {
        frameQueue.async {
            self.lock.lock()
            let a = self.bufferA
            let b = self.bufferB
            var snapshot = self.renderState
            self.lock.unlock()
            guard let a, let b else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            // Preview the actual current composite layout. Remove the active filter first,
            // so every preset is compared against the same live frame.
            snapshot.filter = .original
            snapshot.filterStrength = 0
            let base = Compositor.render(a: a, b: b, state: snapshot)
            let e = base.extent
            let aspect: CGFloat = 3.0 / 4.0
            var crop = e
            if e.width / e.height > aspect {
                let w = e.height * aspect
                crop = CGRect(x: e.midX - w / 2, y: e.minY, width: w, height: e.height)
            } else {
                let h = e.width / aspect
                crop = CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h)
            }
            let scale = min(120 / crop.width, 160 / crop.height)
            let small = base.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let rect = CGRect(x: 0, y: 0, width: crop.width * scale, height: crop.height * scale)

            var result: [FilterPreset: UIImage] = [:]
            for f in FilterPreset.allCases {
                let img = f.apply(to: small, strength: 1)
                if let cg = self.ciContext.createCGImage(img, from: rect) {
                    result[f] = UIImage(cgImage: cg)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
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

    // MARK: - 快门 / 倒计时

    /// 快门按钮：有倒计时先取消；设了定时器就先倒数。
    func shutterAction(video: Bool) {
        if countdown != nil { cancelCountdown(); return }
        if video {
            if isRecording { stopRecording(); return }
            if timerSeconds > 0 {
                startCountdown(timerSeconds) { [weak self] in self?.startRecording() }
            } else {
                startRecording()
            }
        } else {
            if timerSeconds > 0 {
                startCountdown(timerSeconds) { [weak self] in self?.captureNow() }
            } else {
                captureNow()
            }
        }
    }

    /// 实况模式：录制短片后生成带配对元数据的 Live Photo，而不是把普通视频冒充实况。
    func livePhotoAction() {
        if countdown != nil { cancelCountdown(); return }
        guard isReady else { setStatus("相机尚未准备好"); return }
        if isRecording { stopRecording(); return }
        let begin = { [weak self] in
            guard let self, self.isReady, !self.isRecording else { return }
            self.liveCapturePending = true
            self.startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.isRecording, self.liveCapturePending else { return }
                self.stopRecording()
            }
        }
        if timerSeconds > 0 { startCountdown(timerSeconds, then: begin) }
        else { begin() }
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
    }

    private func startCountdown(_ n: Int, then action: @escaping () -> Void) {
        countdown = n
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let next = (self.countdown ?? 1) - 1
            if next <= 0 {
                t.invalidate()
                self.countdownTimer = nil
                self.countdown = nil
                action()
            } else {
                self.countdown = next
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    // MARK: - 拍照

    /// 同时拍下两颗摄像头当前画面：合成图（按当前布局 + 滤镜）+ 可选两张原图。
    /// 开了闪光灯时，先打光约 0.18s 让传感器稳定，再抓帧保存。
    private func captureNow() {
        let useFlash = flashOn && torchCapable
        let raw = saveRaw

        DispatchQueue.global(qos: .userInitiated).async {
            if useFlash {
                self.setTorch(true)
                Thread.sleep(forTimeInterval: 0.18)
            }
            defer { if useFlash { self.setTorch(false) } }

            self.lock.lock()
            let a = self.bufferA, b = self.bufferB
            let state = self.renderState
            self.lock.unlock()

            guard let a, let b else {
                self.setStatus("画面还没准备好")
                return
            }

            var datas: [Data] = []
            let composite = Compositor.render(a: a, b: b, state: state)
            if let d = self.jpegData(composite, rect: CGRect(origin: .zero, size: state.canvas)) {
                datas.append(d)
            }
            if raw {
                for buf in [a, b] {
                    let img = CIImage(cvPixelBuffer: buf)
                    if let d = self.jpegData(img, rect: img.extent) { datas.append(d) }
                }
            }
            self.savePhotos(datas)
        }
    }

    private func jpegData(_ image: CIImage, rect: CGRect) -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image.cropped(to: rect),
                                            colorSpace: cs,
                                            options: [quality: 0.95])
    }

    private func savePhotos(_ datas: [Data]) {
        guard !datas.isEmpty else {
            setStatus("拍照失败")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                self.setStatus("请在「设置」中允许保存到相册", autoClear: false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for d in datas {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: d, options: nil)
                }
            }) { ok, error in
                self.setStatus(ok ? "已保存 \(datas.count) 张照片" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
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
                let urls = results.compactMap { $0 }
                guard self.liveCapturePending else {
                    self.saveVideos(urls)
                    return
                }
                self.liveCapturePending = false
                guard let source = results.first ?? nil else {
                    self.setStatus("实况片段生成失败，未找到视频文件")
                    return
                }
                LivePhotoConverter.shared.convertVideoToLivePhoto(from: source) { result in
                    switch result {
                    case .success:
                        urls.forEach { try? FileManager.default.removeItem(at: $0) }
                        self.setStatus("实况照片已保存到系统图库")
                    case .failure(let error):
                        self.setStatus("实况转换失败，改为保存普通视频：\(error.localizedDescription)")
                        self.saveVideos(urls)
                    }
                }
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

    // MARK: - 渲染（都在 frameQueue 上）

    /// 参数变化（拖动小窗、换滤镜……）时立刻用最近一帧重画预览，
    /// 不用等下一帧相机画面，暗光下低帧率时也跟手。多次请求会合并成一次。
    private func requestRedraw() {
        lock.lock()
        let already = redrawScheduled
        redrawScheduled = true
        lock.unlock()
        if already { return }
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.redrawScheduled = false
            let a = self.bufferA, b = self.bufferB
            let state = self.renderState
            self.lock.unlock()
            guard let a, let b, let canvas = self.renderCanvas(a: a, b: b, state: state) else { return }
            self.display(canvas)
        }
    }

    private func rebuildPool(_ size: CGSize) {
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        canvasPool = pool
        poolSize = size
    }

    private func renderCanvas(a: CVPixelBuffer, b: CVPixelBuffer, state: RenderState) -> CVPixelBuffer? {
        if canvasPool == nil || poolSize != state.canvas { rebuildPool(state.canvas) }
        guard let pool = canvasPool else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let out = pb else { return nil }
        let image = Compositor.render(a: a, b: b, state: state)
        ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: state.canvas), colorSpace: nil)
        return out
    }

    /// 把合成帧送去预览显示（立即显示，不排队）。
    private func display(_ pixelBuffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        if displayLayer.isReadyForMoreMediaData { displayLayer.enqueue(sample) }
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
        let state = renderState
        let rate = recordFPS
        lock.unlock()

        if output === outputA {
            // 原片 A
            if let w = writerA {
                if !w.isStarted {
                    w.start(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer), at: pts,
                            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer), fps: rate)
                }
                w.append(pixelBuffer, at: pts)
            }
            // 合成帧：以 A 的帧为节拍，叠上 B 的最新一帧。预览和录像用同一块画布。
            if let a, let b, let canvas = renderCanvas(a: a, b: b, state: state) {
                display(canvas)
                if let w = writerComposite {
                    if !w.isStarted {
                        w.start(width: CVPixelBufferGetWidth(canvas),
                                height: CVPixelBufferGetHeight(canvas), at: pts,
                                pixelFormat: kCVPixelFormatType_32BGRA, fps: rate)
                    }
                    w.append(canvas, at: pts)
                }
            }
        } else if output === outputB {
            if let w = writerB {
                if !w.isStarted {
                    w.start(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer), at: pts,
                            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer), fps: rate)
                }
                w.append(pixelBuffer, at: pts)
            }
        }
    }
}
