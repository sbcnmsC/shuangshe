import AVFoundation
import Combine
import CoreImage
import Photos
import ImageIO
import SwiftUI
import UIKit

final class CameraManager: NSObject, ObservableObject {
    @Published var settings = CameraSettings()
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRecording = false
    @Published private(set) var countdownText: String?
    @Published private(set) var statusMessage = "正在准备相机…"
    @Published private(set) var actualResolutionText = "—"
    @Published private(set) var actualFPS = 30
    @Published private(set) var isMultiCameraActive = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var currentRearLensLabel = "1×"
    @Published private(set) var filterThumbnails: [LiveFilter: UIImage] = [:]

    private let sessionQueue = DispatchQueue(label: "com.dualcam.session")
    private let frameQueue = DispatchQueue(label: "com.dualcam.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var captureSession: AVCaptureSession?
    private var multiCameraSession: AVCaptureMultiCamSession?
    private var backDevice: AVCaptureDevice?
    private var frontDevice: AVCaptureDevice?
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var backVideoOutput = AVCaptureVideoDataOutput()
    private var frontVideoOutput = AVCaptureVideoDataOutput()
    private var audioOutput = AVCaptureAudioDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private struct CameraPair {
        let back: AVCaptureDevice
        let front: AVCaptureDevice
    }
    private var supportedCameraPairs: [CameraPair] = []
    private var activeCameraPairIndex = 0
    private var microphoneAuthorized = false
    private var savedRearZoom: CGFloat = 1
    private var savedFrontZoom: CGFloat = 1
    private var hasFrontCamera = false
    private var latestBackBuffer: CVPixelBuffer?
    private var latestFrontBuffer: CVPixelBuffer?
    private var latestComposite: CIImage?
    private var latestBaseComposite: CIImage?
    private var latestCanvasSize = CGSize(width: 1080, height: 1920)
    private var lastPreviewPush = CACurrentMediaTime()

    // Writer state is accessed only on frameQueue.
    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerURL: URL?
    private var writerSessionStarted = false
    private var recordingStartPTS: CMTime = .zero
    private var lastVideoPTS: CMTime = .invalid
    private var lastDurationUpdate = CACurrentMediaTime()
    private var pendingRecordStart = false
    private var pendingRecordStop = false
    private var captureGeneration = 0

    override init() {
        super.init()
    }

    // MARK: Lifecycle and permissions

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        Task {
            let videoAllowed = await requestPermission(for: .video)
            guard videoAllowed else {
                isStarting = false
                statusMessage = "请在「设置 → DualCam」中允许使用相机。"
                return
            }
            // Audio is requested at launch so recorded video can include sound.
            let audioAllowed = await requestPermission(for: .audio)
            microphoneAuthorized = audioAllowed
            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    if AVCaptureMultiCamSession.isMultiCamSupported {
                        do {
                            try self.configureMultiCameraSession(includeAudio: audioAllowed)
                        } catch {
                            try self.configureSingleCameraSession(includeAudio: audioAllowed)
                        }
                    } else {
                        try self.configureSingleCameraSession(includeAudio: audioAllowed)
                    }
                    guard let activeSession = self.captureSession else { throw CameraError.sessionUnavailable }
                    activeSession.startRunning()
                    DispatchQueue.main.async {
                        self.isRunning = activeSession.isRunning
                        self.isStarting = false
                        self.statusMessage = self.isMultiCameraActive ? "双摄已连接" : "单摄模式（设备不支持当前双摄组合）"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isStarting = false
                        self.isRunning = false
                        self.statusMessage = "相机启动失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.isStarting = false
                self.previewImage = nil
            }
        }
    }

    private func requestPermission(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    // MARK: Session construction

    private func configureMultiCameraSession(includeAudio: Bool) throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .unspecified
        )
        var pairs: [CameraPair] = []
        var seenPairs = Set<String>()
        for deviceSet in discovery.supportedMultiCamDeviceSets {
            let backs = deviceSet.filter { $0.position == .back }
            let fronts = deviceSet.filter { $0.position == .front }
            for backDevice in backs {
                for frontDevice in fronts {
                    let key = "\(backDevice.uniqueID)|\(frontDevice.uniqueID)"
                    if seenPairs.insert(key).inserted {
                        pairs.append(CameraPair(back: backDevice, front: frontDevice))
                    }
                }
            }
        }
        pairs.sort { lensPriority($0.back) < lensPriority($1.back) }
        guard !pairs.isEmpty else { throw CameraError.noSupportedCameraPair }
        supportedCameraPairs = pairs
        activeCameraPairIndex = activeCameraPairIndex % pairs.count
        let selectedPair = pairs[activeCameraPairIndex]
        let back = selectedPair.back
        let front = selectedPair.front

        let newSession = AVCaptureMultiCamSession()
        let newBackInput = try AVCaptureDeviceInput(device: back)
        let newFrontInput = try AVCaptureDeviceInput(device: front)
        let newBackOutput = AVCaptureVideoDataOutput()
        let newFrontOutput = AVCaptureVideoDataOutput()
        configureVideoOutput(newBackOutput)
        configureVideoOutput(newFrontOutput)

        newSession.beginConfiguration()
        defer { newSession.commitConfiguration() }

        guard newSession.canAddInput(newBackInput), newSession.canAddInput(newFrontInput),
              newSession.canAddOutput(newBackOutput), newSession.canAddOutput(newFrontOutput) else {
            throw CameraError.cannotAddMultiCamComponents
        }
        newSession.addInputWithNoConnections(newBackInput)
        newSession.addInputWithNoConnections(newFrontInput)
        newSession.addOutputWithNoConnections(newBackOutput)
        newSession.addOutputWithNoConnections(newFrontOutput)

        try connect(input: newBackInput, output: newBackOutput, session: newSession, rotation: 90)
        try connect(input: newFrontInput, output: newFrontOutput, session: newSession, rotation: 90)

        var newAudioInput: AVCaptureDeviceInput?
        var newAudioOutput: AVCaptureAudioDataOutput?
        if includeAudio, let microphone = AVCaptureDevice.default(for: .audio) {
            let input = try AVCaptureDeviceInput(device: microphone)
            let output = AVCaptureAudioDataOutput()
            if newSession.canAddInput(input), newSession.canAddOutput(output) {
                newSession.addInputWithNoConnections(input)
                newSession.addOutputWithNoConnections(output)
                if let port = input.ports.first(where: { $0.mediaType == .audio }) {
                    let connection = AVCaptureConnection(inputPorts: [port], output: output)
                    if newSession.canAddConnection(connection) {
                        newSession.addConnection(connection)
                        newAudioInput = input
                        newAudioOutput = output
                    }
                }
            }
        }

        backDevice = back
        frontDevice = front
        backInput = newBackInput
        frontInput = newFrontInput
        audioInput = newAudioInput
        backVideoOutput = newBackOutput
        frontVideoOutput = newFrontOutput
        audioOutput = newAudioOutput ?? AVCaptureAudioDataOutput()
        multiCameraSession = newSession
        captureSession = newSession
        hasFrontCamera = true
        isMultiCameraActive = true
        configureStabilization(on: newBackOutput, in: newSession)
        let backFPS = configureFrameRate(device: back, requested: settings.frameRate)
        let frontFPS = configureFrameRate(device: front, requested: settings.frameRate)
        configureLowLightBoost(device: back)
        configureLowLightBoost(device: front)

        let outputs: [AVCaptureOutput] = [newBackOutput, newFrontOutput]
        let newSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: outputs)
        newSynchronizer.setDelegate(self, queue: frameQueue)
        synchronizer = newSynchronizer
        newAudioOutput?.setSampleBufferDelegate(self, queue: frameQueue)

        DispatchQueue.main.async {
            self.currentRearLensLabel = self.lensLabel(for: back)
            self.actualFPS = min(backFPS, frontFPS)
        }
    }

    private func configureSingleCameraSession(includeAudio: Bool) throws {
        let newSession = AVCaptureSession()
        guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
        let newInput = try AVCaptureDeviceInput(device: back)
        let newOutput = AVCaptureVideoDataOutput()
        configureVideoOutput(newOutput)

        newSession.beginConfiguration()
        newSession.sessionPreset = .high
        guard newSession.canAddInput(newInput), newSession.canAddOutput(newOutput) else {
            newSession.commitConfiguration()
            throw CameraError.cannotAddSingleCamComponents
        }
        newSession.addInput(newInput)
        newSession.addOutput(newOutput)
        if let connection = newOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            if settings.stabilizationEnabled && connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        var newAudioInput: AVCaptureDeviceInput?
        var newAudioOutput: AVCaptureAudioDataOutput?
        if includeAudio, let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone) {
            let output = AVCaptureAudioDataOutput()
            if newSession.canAddInput(input), newSession.canAddOutput(output) {
                newSession.addInput(input)
                newSession.addOutput(output)
                newAudioInput = input
                newAudioOutput = output
            }
        }
        newSession.commitConfiguration()

        backDevice = back
        frontDevice = nil
        backInput = newInput
        frontInput = nil
        audioInput = newAudioInput
        backVideoOutput = newOutput
        frontVideoOutput = AVCaptureVideoDataOutput()
        audioOutput = newAudioOutput ?? AVCaptureAudioDataOutput()
        captureSession = newSession
        multiCameraSession = nil
        hasFrontCamera = false
        isMultiCameraActive = false
        let actualFPS = configureFrameRate(device: back, requested: settings.frameRate)
        configureLowLightBoost(device: back)
        let newSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [newOutput])
        newSynchronizer.setDelegate(self, queue: frameQueue)
        synchronizer = newSynchronizer
        newAudioOutput?.setSampleBufferDelegate(self, queue: frameQueue)
        DispatchQueue.main.async {
            self.currentRearLensLabel = self.lensLabel(for: back)
            self.actualFPS = actualFPS
        }
    }

    private func configureVideoOutput(_ output: AVCaptureVideoDataOutput) {
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
    }

    private func connect(input: AVCaptureDeviceInput, output: AVCaptureOutput, session: AVCaptureMultiCamSession, rotation: CGFloat) throws {
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else {
            throw CameraError.videoPortUnavailable
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        if connection.isVideoRotationAngleSupported(rotation) {
            connection.videoRotationAngle = rotation
        }
        if settings.stabilizationEnabled && connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        guard session.canAddConnection(connection) else { throw CameraError.cannotConnectCamera }
        session.addConnection(connection)
    }

    private func configureStabilization(on output: AVCaptureVideoDataOutput, in session: AVCaptureMultiCamSession) {
        guard let connection = output.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = settings.stabilizationEnabled ? .auto : .off
        }
    }

    @discardableResult
    private func configureFrameRate(device: AVCaptureDevice, requested: Int) -> Int {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            let actual = ranges.contains { $0.minFrameRate <= Double(requested) && $0.maxFrameRate >= Double(requested) } ? requested : 30
            let duration = CMTime(value: 1, timescale: CMTimeScale(actual))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            return actual
        } catch {
            // Keep the device's system-selected frame rate if locking is unavailable.
            return 30
        }
    }

    func setFrameRate(_ requested: Int) {
        guard !isRecording else {
            statusMessage = "录像时不能更改帧率。"
            return
        }
        settings.frameRate = requested
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let backRate = self.backDevice.map { self.configureFrameRate(device: $0, requested: requested) } ?? requested
            let frontRate = self.frontDevice.map { self.configureFrameRate(device: $0, requested: requested) } ?? requested
            let effective = min(backRate, frontRate)
            DispatchQueue.main.async { self.actualFPS = effective }
        }
    }

    // MARK: Sample processing and live composition

    private func synchronizedBuffer(_ collection: AVCaptureSynchronizedDataCollection, for output: AVCaptureOutput) -> CVPixelBuffer? {
        guard let data = collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData,
              !data.sampleBufferWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(data.sampleBuffer) else { return nil }
        return pixelBuffer
    }

    private func processSynchronizedFrames(_ collection: AVCaptureSynchronizedDataCollection) {
        guard let backBuffer = synchronizedBuffer(collection, for: backVideoOutput) else { return }
        latestBackBuffer = backBuffer
        if hasFrontCamera, let frontBuffer = synchronizedBuffer(collection, for: frontVideoOutput) {
            latestFrontBuffer = frontBuffer
        }
        guard let mainBuffer = settings.mainUsesFrontCamera ? (latestFrontBuffer ?? latestBackBuffer) : latestBackBuffer else { return }
        let baseComposite = compose(back: latestBackBuffer, front: latestFrontBuffer)
        latestBaseComposite = baseComposite
        let composite = apply(filter: settings.filter, intensity: settings.filterIntensity, to: baseComposite)
        latestComposite = composite
        let renderSize = composite.extent.size
        latestCanvasSize = renderSize

        let now = CACurrentMediaTime()
        if now - lastPreviewPush >= 1.0 / 20.0 {
            lastPreviewPush = now
            if let cgImage = ciContext.createCGImage(composite, from: composite.extent) {
                let uiImage = UIImage(cgImage: cgImage)
                DispatchQueue.main.async {
                    self.previewImage = uiImage
                    self.actualResolutionText = "\(Int(renderSize.width))×\(Int(renderSize.height))"
                }
            }
        }
        _ = mainBuffer // Kept explicit to document which stream is currently treated as the main input.

        if pendingRecordStart {
            pendingRecordStart = false
            do { try beginWriter(size: renderSize) }
            catch {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "无法开始录像：\(error.localizedDescription)"
                }
            }
        }
        if let writer, writer.status == .writing {
            let samplePTS = collectionSample(collection, output: backVideoOutput).map { CMSampleBufferGetPresentationTimeStamp($0) } ?? .invalid
            appendVideoFrame(composite, at: samplePTS)
            if now - lastDurationUpdate >= 0.25 {
                lastDurationUpdate = now
                if writerSessionStarted, samplePTS.isValid {
                    let elapsed = CMTimeGetSeconds(CMTimeSubtract(samplePTS, recordingStartPTS))
                    if elapsed.isFinite && elapsed >= 0 {
                        DispatchQueue.main.async { self.recordingDuration = elapsed }
                    }
                }
            }
        }
        if pendingRecordStop {
            pendingRecordStop = false
            finishWriter()
        }
    }

    // Accessor avoids making assumptions about optional synchronized sample buffers.
    private func collectionSample(_ collection: AVCaptureSynchronizedDataCollection, output: AVCaptureOutput) -> CMSampleBuffer? {
        (collection.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData)?.sampleBuffer
    }

    private func compose(back: CVPixelBuffer?, front: CVPixelBuffer?) -> CIImage {
        let settingsCopy = settings
        let target = resolveCanvasSize(settingsCopy: settingsCopy, back: back, front: front)
        let canvasRect = CGRect(origin: .zero, size: target)
        let backImage = back.map { CIImage(cvPixelBuffer: $0) }
        var frontImage = front.map { CIImage(cvPixelBuffer: $0) }
        if settingsCopy.frontMirror, let source = frontImage {
            let extent = source.extent
            frontImage = source.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: extent.minX + extent.maxX, ty: 0)).cropped(to: extent)
        }
        let mainSource = settingsCopy.mainUsesFrontCamera ? (frontImage ?? backImage) : backImage
        let insetSource = settingsCopy.mainUsesFrontCamera ? backImage : (frontImage ?? backImage)
        guard let mainSource else { return CIImage(color: .black).cropped(to: canvasRect) }

        var result: CIImage
        if settingsCopy.layout == .split, let insetSource, front != nil {
            let dividerY = target.height * settingsCopy.splitRatio
            let bottomRect = CGRect(x: 0, y: 0, width: target.width, height: dividerY)
            let topRect = CGRect(x: 0, y: dividerY, width: target.width, height: target.height - dividerY)
            // UIKit's top is Core Image's high-y half.
            let topImage = aspectFill(mainSource, into: topRect)
            let bottomImage = aspectFill(insetSource, into: bottomRect)
            result = topImage.composited(over: bottomImage).cropped(to: canvasRect)
        } else {
            result = aspectFill(mainSource, into: canvasRect)
            if let insetSource, front != nil {
                let pipWidth = target.width * settingsCopy.pipScale
                let aspect = settingsCopy.pipAspect.ratio
                let pipHeight = pipWidth / aspect
                let centerX = target.width * settingsCopy.pipX
                let centerY = target.height * (1.0 - settingsCopy.pipY)
                let pipRect = CGRect(x: centerX - pipWidth / 2, y: centerY - pipHeight / 2, width: pipWidth, height: pipHeight)
                    .intersection(canvasRect)
                if !pipRect.isNull && pipRect.width > 10 && pipRect.height > 10 {
                    var pip = aspectFill(insetSource, into: pipRect)
                    if settingsCopy.pipShape == .circle {
                        let radius = min(pipRect.width, pipRect.height) / 2
                        let mask = roundedMask(rect: pipRect, radius: radius)
                        pip = pip.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: pipRect),
                            kCIInputMaskImageKey: mask
                        ])
                    } else if settingsCopy.pipCornerRadius > 0 {
                        let mask = roundedMask(rect: pipRect, radius: settingsCopy.pipCornerRadius)
                        pip = pip.applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: pipRect),
                            kCIInputMaskImageKey: mask
                        ])
                    }
                    if settingsCopy.pipOpacity < 0.999 {
                        pip = pip.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: settingsCopy.pipOpacity)
                        ])
                    }
                    if settingsCopy.pipBorderWidth > 0 {
                        let borderRect = pipRect.insetBy(dx: -settingsCopy.pipBorderWidth / 2, dy: -settingsCopy.pipBorderWidth / 2)
                        let borderMask = roundedMask(rect: borderRect, radius: settingsCopy.pipShape == .circle ? min(borderRect.width, borderRect.height) / 2 : settingsCopy.pipCornerRadius)
                        let border = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92))
                            .cropped(to: borderRect)
                            .applyingFilter("CIBlendWithMask", parameters: [
                                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: borderRect),
                                kCIInputMaskImageKey: borderMask
                            ])
                        result = border.composited(over: result)
                    }
                    result = pip.composited(over: result)
                }
            }
        }

        return result.cropped(to: canvasRect)
    }

    private func resolveCanvasSize(settingsCopy: CameraSettings, back: CVPixelBuffer?, front: CVPixelBuffer?) -> CGSize {
        var target = settingsCopy.outputSize
        let sourceLongSide = [back, front].compactMap { $0 }.map { max(CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }.max() ?? Int(max(target.width, target.height))
        let targetLongSide = max(target.width, target.height)
        // Never enlarge the render canvas beyond the longest side of the actual camera stream.
        let scale = min(1.0, CGFloat(sourceLongSide) / targetLongSide)
        target = CGSize(width: max(2, (target.width * scale).rounded(.down)), height: max(2, (target.height * scale).rounded(.down)))
        return CGSize(width: max(2, target.width.rounded(.down)), height: max(2, target.height.rounded(.down)))
    }

    private func aspectFill(_ source: CIImage, into rect: CGRect) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else {
            return CIImage(color: .black).cropped(to: rect)
        }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: rect.midX - scaled.extent.midX,
            y: rect.midY - scaled.extent.midY
        ))
        return centered.cropped(to: rect)
    }

    private func roundedMask(rect: CGRect, radius: CGFloat) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator")!
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(max(0, radius), forKey: "inputRadius")
        filter.setValue(CIColor.white, forKey: "inputColor")
        return filter.outputImage?.cropped(to: rect) ?? CIImage(color: .white).cropped(to: rect)
    }

    private func drawGrid(over image: CIImage, rect: CGRect) -> CIImage {
        let lineWidth = max(1, rect.width / 720)
        var grid = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.42)).cropped(to: CGRect(x: rect.minX + rect.width / 3 - lineWidth / 2, y: rect.minY, width: lineWidth, height: rect.height))
        let v2 = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.42)).cropped(to: CGRect(x: rect.minX + rect.width * 2 / 3 - lineWidth / 2, y: rect.minY, width: lineWidth, height: rect.height))
        let h1 = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.42)).cropped(to: CGRect(x: rect.minX, y: rect.minY + rect.height / 3 - lineWidth / 2, width: rect.width, height: lineWidth))
        let h2 = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.42)).cropped(to: CGRect(x: rect.minX, y: rect.minY + rect.height * 2 / 3 - lineWidth / 2, width: rect.width, height: lineWidth))
        grid = v2.composited(over: grid)
        grid = h1.composited(over: grid)
        grid = h2.composited(over: grid)
        return grid.composited(over: image)
    }

    private func apply(filter: LiveFilter, intensity: Double, to image: CIImage) -> CIImage {
        guard filter != .original, intensity > 0 else { return image }
        var filtered = image
        func colorControls(saturation: Double = 1, contrast: Double = 1, brightness: Double = 0) {
            filtered = filtered.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation,
                kCIInputContrastKey: contrast,
                kCIInputBrightnessKey: brightness
            ])
        }
        switch filter {
        case .original: return image
        case .vivid: colorControls(saturation: 1.5, contrast: 1.1, brightness: 0.01)
        case .warm:
            filtered = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4900, y: 20)])
            colorControls(saturation: 1.12, contrast: 1.04)
        case .cool:
            filtered = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8200, y: -10)])
            colorControls(saturation: 0.96, contrast: 1.05)
        case .fresh: colorControls(saturation: 1.12, contrast: 1.02, brightness: 0.025)
        case .cinematic:
            colorControls(saturation: 0.82, contrast: 1.18, brightness: -0.015)
            filtered = filtered.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.72, "inputShadowAmount": 0.35])
        case .film: filtered = image.applyingFilter("CIPhotoEffectProcess")
        case .vintage: filtered = image.applyingFilter("CIPhotoEffectTransfer")
        case .faded: filtered = image.applyingFilter("CIPhotoEffectFade")
        case .chrome: filtered = image.applyingFilter("CIPhotoEffectChrome")
        case .monochrome: filtered = image.applyingFilter("CIPhotoEffectMono")
        case .noirGold:
            filtered = image.applyingFilter("CIPhotoEffectNoir")
            filtered = filtered.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.18])
            colorControls(saturation: 0.65, contrast: 1.22)
        }
        let blend = CIFilter(name: "CIDissolveTransition")!
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(filtered, forKey: kCIInputTargetImageKey)
        blend.setValue(min(1, max(0, intensity)), forKey: kCIInputTimeKey)
        return blend.outputImage?.cropped(to: image.extent) ?? filtered
    }

    // MARK: Photo capture

    func timerButtonPressed() {
        if countdownText != nil {
            captureGeneration += 1
            countdownText = nil
            statusMessage = "已取消倒计时"
            return
        }
        let options = [0, 3, 10]
        let current = options.firstIndex(of: settings.timerSeconds) ?? 0
        settings.timerSeconds = options[(current + 1) % options.count]
    }

    func refreshFilterThumbnails() {
        frameQueue.async { [weak self] in
            guard let self, let base = self.latestBaseComposite else { return }
            var cache: [LiveFilter: UIImage] = [:]
            for filter in LiveFilter.allCases {
                let processed = self.apply(filter: filter, intensity: 0.9, to: base)
                let thumbnailScale = min(1, min(180 / max(1, processed.extent.width), 220 / max(1, processed.extent.height)))
                let scaled = processed.transformed(by: CGAffineTransform(scaleX: thumbnailScale, y: thumbnailScale))
                if let cgImage = self.ciContext.createCGImage(scaled, from: scaled.extent) {
                    cache[filter] = UIImage(cgImage: cgImage)
                }
            }
            DispatchQueue.main.async { self.filterThumbnails = cache }
        }
    }

    func shutterPressed() {
        if countdownText != nil {
            captureGeneration += 1
            countdownText = nil
            statusMessage = "已取消倒计时"
            return
        }
        if settings.timerSeconds > 0 {
            captureGeneration += 1
            let generation = captureGeneration
            Task { @MainActor in
                for remaining in stride(from: settings.timerSeconds, through: 1, by: -1) {
                    guard generation == captureGeneration else { return }
                    countdownText = "\(remaining)"
                    try? await Task.sleep(for: .seconds(1))
                }
                guard generation == captureGeneration else { return }
                countdownText = nil
                performShutterAction()
            }
        } else {
            performShutterAction()
        }
    }

    private func performShutterAction() {
        if settings.captureMode == .photo {
            savePhoto()
        } else if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func savePhoto() {
        frameQueue.async { [weak self] in
            guard let self, let composite = self.latestComposite else {
                DispatchQueue.main.async { self?.statusMessage = "画面尚未就绪，请稍后再拍。" }
                return
            }
            guard let jpegData = self.ciContext.jpegRepresentation(of: composite, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.97]) else {
                DispatchQueue.main.async { self.statusMessage = "照片生成失败。" }
                return
            }
            let originals: [Data] = self.settings.saveTwoOriginals ? [self.latestBackBuffer, self.latestFrontBuffer].compactMap { buffer in
                guard let buffer else { return nil }
                return self.ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.96])
            } : []
            self.saveJPEGs([jpegData] + originals, photoCount: 1)
        }
    }

    private func saveJPEGs(_ images: [Data], photoCount: Int) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authorization in
            guard let self else { return }
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.statusMessage = "请允许 DualCam 添加照片到系统照片图库。" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                images.forEach { data in
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.statusMessage = success ? (photoCount == 1 ? "照片已保存到系统照片 App" : "作品已保存") : "保存失败：\(error?.localizedDescription ?? "未知错误")"
                }
            }
        }
    }

    // MARK: Video recording

    func startRecording() {
        guard !isRecording, isRunning else { return }
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.resetWriter()
            self.pendingRecordStart = true
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingDuration = 0
                self.statusMessage = "正在录像…"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRecordStop = false
            DispatchQueue.main.async { self.isRecording = false }
            self.finishWriter()
        }
    }

    private func beginWriter(size: CGSize) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DualCam-\(UUID().uuidString).mov")
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = max(2, Int(size.width.rounded(.down)))
        let height = max(2, Int(size.height.rounded(.down)))
        let codec: AVVideoCodecType = settings.resolution == .maximum && width >= 2160 ? .hevc : .hevc
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(5_000_000, width * height * max(settings.frameRate, 24) / 8)]
        ])
        videoInput.expectsMediaDataInRealTime = true
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ])
        audioInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(videoInput) else { throw CameraError.writerInputUnavailable }
        assetWriter.add(videoInput)
        if assetWriter.canAdd(audioInput) { assetWriter.add(audioInput); writerAudioInput = audioInput } else { writerAudioInput = nil }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: attributes)
        guard assetWriter.startWriting() else { throw assetWriter.error ?? CameraError.writerFailed }
        writer = assetWriter
        writerVideoInput = videoInput
        pixelBufferAdaptor = adaptor
        writerURL = url
        writerSessionStarted = false
        lastVideoPTS = .invalid
    }

    private func appendVideoFrame(_ image: CIImage, at pts: CMTime) {
        guard let writer, let videoInput = writerVideoInput, let adaptor = pixelBufferAdaptor,
              writer.status == .writing, videoInput.isReadyForMoreMediaData else { return }
        guard pts.isValid else { return }
        let presentationTime = pts
        if !writerSessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            recordingStartPTS = presentationTime
            writerSessionStarted = true
        }
        if lastVideoPTS.isValid && CMTimeCompare(presentationTime, lastVideoPTS) <= 0 { return }
        guard let pool = adaptor.pixelBufferPool else { return }
        var optionalPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optionalPixelBuffer) == kCVReturnSuccess,
              let pixelBuffer = optionalPixelBuffer else { return }
        let outputRect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let recordingImage = image.extent.size == outputRect.size ? image : aspectFill(image, into: outputRect)
        ciContext.render(recordingImage, to: pixelBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            DispatchQueue.main.async { self.statusMessage = "视频帧写入异常：\(writer.error?.localizedDescription ?? "请重试")" }
        }
        lastVideoPTS = presentationTime
    }

    private func finishWriter() {
        guard let completedWriter = writer else { resetWriter(); return }
        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        let completedURL = writerURL
        completedWriter.finishWriting { [weak self] in
            guard let self else { return }
            guard completedWriter.status == .completed, let completedURL else {
                DispatchQueue.main.async { self.statusMessage = "录像保存失败：\(completedWriter.error?.localizedDescription ?? "未知错误")" }
                self.frameQueue.async { self.resetWriter() }
                return
            }
            // Clear the writer before requesting Photos permission, so a fast next recording cannot be reset by this save callback.
            self.frameQueue.async {
                self.resetWriter()
                self.saveVideoToPhotoLibrary(at: completedURL)
            }
        }
    }

    private func saveVideoToPhotoLibrary(at url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] authorization in
            guard let self else { return }
            guard authorization == .authorized || authorization == .limited else {
                DispatchQueue.main.async { self.statusMessage = "视频已生成，但照片图库权限未开启。" }
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.statusMessage = success ? "视频已保存到系统照片 App" : "视频保存失败：\(error?.localizedDescription ?? "未知错误")"
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func resetWriter() {
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        pixelBufferAdaptor = nil
        writerURL = nil
        writerSessionStarted = false
        pendingRecordStart = false
        pendingRecordStop = false
    }

    // MARK: Hardware controls

    func toggleFlash() {
        settings.flashEnabled.toggle()
        setTorch(enabled: settings.flashEnabled)
    }

    private func setTorch(enabled: Bool) {
        guard let device = backDevice, device.hasTorch else {
            if enabled { statusMessage = "当前镜头没有可用补光灯。" }
            settings.flashEnabled = false
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = enabled ? .on : .off
        } catch {
            statusMessage = "无法切换补光灯：\(error.localizedDescription)"
        }
    }

    func setZoom(_ value: Double) {
        settings.zoom = CGFloat(value)
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let actualZoom = min(device.activeFormat.videoMaxZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(value)))
            device.videoZoomFactor = actualZoom
            settings.zoom = actualZoom
            if device.position == .front { savedFrontZoom = actualZoom } else { savedRearZoom = actualZoom }
            currentRearLensLabel = lensLabel(for: device)
        } catch { statusMessage = "无法调整变焦。" }
    }

    func cycleLensCombination() {
        guard !isRecording else { statusMessage = "录像时暂不切换物理镜头。"; return }
        guard isMultiCameraActive, supportedCameraPairs.count > 1 else {
            guard let device = backDevice else { return }
            let candidates = [CGFloat(1), min(2, device.activeFormat.videoMaxZoomFactor), min(3, device.activeFormat.videoMaxZoomFactor)]
            let currentIndex = candidates.firstIndex(where: { abs($0 - settings.zoom) < 0.2 }) ?? 0
            setZoom(Double(candidates[(currentIndex + 1) % candidates.count]))
            return
        }
        activeCameraPairIndex = (activeCameraPairIndex + 1) % supportedCameraPairs.count
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.stopRunning()
            do {
                try self.configureMultiCameraSession(includeAudio: self.microphoneAuthorized)
                self.captureSession?.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = self.captureSession?.isRunning ?? false
                    self.statusMessage = "镜头组合已切换"
                }
            } catch {
                DispatchQueue.main.async { self.statusMessage = "切换镜头失败：\(error.localizedDescription)" }
            }
        }
    }

    private func zoomLabel(for device: AVCaptureDevice) -> String {
        let value = device.position == .front ? savedFrontZoom : savedRearZoom
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    private func lensLabel(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "0.5×"
        case .builtInTelephotoCamera: return "长焦"
        default: return zoomLabel(for: device)
        }
    }

    private func lensPriority(_ device: AVCaptureDevice) -> Int {
        switch device.deviceType {
        case .builtInWideAngleCamera: return 0
        case .builtInUltraWideCamera: return 1
        case .builtInTelephotoCamera: return 2
        default: return 3
        }
    }

    func focus(at normalizedPoint: CGPoint) {
        let device = settings.mainUsesFrontCamera ? frontDevice : backDevice
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let point = CGPoint(x: min(1, max(0, normalizedPoint.x)), y: min(1, max(0, normalizedPoint.y)))
            if device.isFocusPointOfInterestSupported && !settings.focusLocked {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            if device.isExposurePointOfInterestSupported && !settings.exposureLocked {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
        } catch { statusMessage = "对焦操作未能完成。" }
    }

    func setExposureBias(_ value: Double) {
        settings.exposureBias = value
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let requestedBias = Float(value)
            let bias = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, requestedBias))
            device.setExposureTargetBias(bias, completionHandler: nil)
        } catch { statusMessage = "无法调整曝光。" }
    }

    func applyManualExposure(iso: Double, shutter: Double) {
        settings.manualISO = iso
        settings.shutterSeconds = shutter
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if iso <= 0 {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                return
            }
            guard device.isExposureModeSupported(.custom) else { return }
            let requestedISO = Float(iso)
            let boundedISO = min(device.activeFormat.maxISO, max(device.activeFormat.minISO, requestedISO))
            let duration = CMTime(seconds: max(device.activeFormat.minExposureDuration.seconds, min(device.activeFormat.maxExposureDuration.seconds, shutter)), preferredTimescale: 1_000_000_000)
            device.setExposureModeCustom(duration: duration, iso: boundedISO, completionHandler: nil)
        } catch { statusMessage = "手动曝光设置失败。" }
    }

    func applyWhiteBalance(kelvin: Double, tint: Double) {
        settings.whiteBalanceKelvin = kelvin
        settings.whiteBalanceTint = tint
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice,
              device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: Float(tint))
            let gains = device.deviceWhiteBalanceGains(for: temperature)
            device.setWhiteBalanceModeLocked(with: clampWhiteBalanceGains(gains, device: device), completionHandler: nil)
        } catch { statusMessage = "白平衡设置失败。" }
    }

    private func clampWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(maxGain, max(1, gains.redGain)),
            greenGain: min(maxGain, max(1, gains.greenGain)),
            blueGain: min(maxGain, max(1, gains.blueGain))
        )
    }

    func setManualFocus(_ value: Double) {
        settings.manualFocus = value
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice,
              device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setFocusModeLocked(lensPosition: Float(min(1, max(0, value))), completionHandler: nil)
        } catch { statusMessage = "手动对焦设置失败。" }
    }

    func toggleFocusLock() {
        settings.focusLocked.toggle()
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if settings.focusLocked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        } catch { statusMessage = "对焦锁定失败。" }
    }

    func toggleExposureLock() {
        settings.exposureLocked.toggle()
        guard let device = settings.mainUsesFrontCamera ? frontDevice : backDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if settings.exposureLocked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
        } catch { statusMessage = "曝光锁定失败。" }
    }

    func toggleMainCamera() {
        guard hasFrontCamera else { statusMessage = "当前设备只有一个可用视频输入。"; return }
        settings.mainUsesFrontCamera.toggle()
        settings.zoom = settings.mainUsesFrontCamera ? savedFrontZoom : savedRearZoom
        setZoom(Double(settings.zoom))
    }

    func applyLowLightBoost() {
        [backDevice, frontDevice].compactMap { $0 }.forEach { configureLowLightBoost(device: $0) }
    }

    private func configureLowLightBoost(device: AVCaptureDevice) {
        guard device.isLowLightBoostSupported else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.automaticallyEnablesLowLightBoostWhenAvailable = settings.lowLightBoost
        } catch {
            // Unsupported formats can reject the feature; leave the capture session running.
        }
    }

    func updateStabilization() {
        guard let captureSession else { return }
        for output in captureSession.outputs.compactMap({ $0 as? AVCaptureVideoDataOutput }) {
            guard let connection = output.connection(with: .video), connection.isVideoStabilizationSupported else { continue }
            connection.preferredVideoStabilizationMode = settings.stabilizationEnabled ? .auto : .off
        }
    }
}

extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer, didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // AVCaptureDataOutputSynchronizer is assigned frameQueue, so frame state stays serialized.
        processSynchronizedFrames(synchronizedDataCollection)
    }
}

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output is AVCaptureAudioDataOutput,
              writerSessionStarted,
              let writer, writer.status == .writing,
              let audioInput = writerAudioInput, audioInput.isReadyForMoreMediaData else { return }
        if CMSampleBufferDataIsReady(sampleBuffer) {
            _ = audioInput.append(sampleBuffer)
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case noSupportedCameraPair
    case sessionUnavailable
    case cannotAddMultiCamComponents
    case cannotAddSingleCamComponents
    case videoPortUnavailable
    case cannotConnectCamera
    case writerInputUnavailable
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .noCamera: return "没有找到可用摄像头。"
        case .noSupportedCameraPair: return "设备没有支持的前后双摄组合。"
        case .sessionUnavailable: return "相机 Session 尚未建立。"
        case .cannotAddMultiCamComponents: return "设备无法同时添加所需的摄像头输入。"
        case .cannotAddSingleCamComponents: return "设备无法建立单摄采集链路。"
        case .videoPortUnavailable: return "摄像头视频端口不可用。"
        case .cannotConnectCamera: return "无法连接摄像头输出。"
        case .writerInputUnavailable: return "视频编码器不可用。"
        case .writerFailed: return "无法启动视频编码器。"
        }
    }
}

