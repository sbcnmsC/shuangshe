import AVFoundation
import Combine
import UIKit

final class CameraSessionManager: ObservableObject {
    enum CameraError: LocalizedError {
        case multicamUnsupported
        case cameraUnavailable
        case cannotAddInput(String)
        case cannotConnectPreview(String)
        case permissionDenied
        case photoOutputsUnavailable
        case captureFailed
        case torchUnavailable

        var errorDescription: String? {
            switch self {
            case .multicamUnsupported:
                return "这台设备不支持 AVCaptureMultiCamSession，请在支持双摄的 iPhone 真机上运行。"
            case .cameraUnavailable:
                return "未找到可用的前置或后置广角摄像头。"
            case .cannotAddInput(let name):
                return "无法启用\(name)摄像头输入。"
            case .cannotConnectPreview(let name):
                return "无法连接\(name)摄像头预览。"
            case .permissionDenied:
                return "没有相机权限。请在 iPhone「设置」中允许 DualCam 使用相机。"
            case .photoOutputsUnavailable:
                return "当前设备无法同时启用两路拍照输出；双摄预览可能仍可使用。"
            case .captureFailed:
                return "拍照失败，请稍后重试。"
            case .torchUnavailable:
                return "当前设备的后置摄像头不支持补光灯。"
            }
        }
    }

    private enum CameraSide { case rear, front }

    @Published private(set) var isStarting = false
    @Published private(set) var isRunning = false
    @Published private(set) var rearPreviewLayer: AVCaptureVideoPreviewLayer?
    @Published private(set) var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTorchOn = false

    let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.dualcam.session.queue", qos: .userInitiated)
    private var hasRequestedStart = false
    private var rearDevice: AVCaptureDevice?
    private var rearPhotoOutput: AVCapturePhotoOutput?
    private var frontPhotoOutput: AVCapturePhotoOutput?
    private var activeCaptures: [UUID: PendingPhotoCapture] = [:]

    func requestAccessAndStart() {
        guard !hasRequestedStart else { return }
        hasRequestedStart = true
        isStarting = true

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = CameraError.permissionDenied.localizedDescription
                        self.isStarting = false
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = CameraError.permissionDenied.localizedDescription
            isStarting = false
        @unknown default:
            errorMessage = CameraError.permissionDenied.localizedDescription
            isStarting = false
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSession()
                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    self.isStarting = false
                    self.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isStarting = false
                    self.isRunning = false
                }
            }
        }
    }

    private func configureSession() throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            throw CameraError.multicamUnsupported
        }

        guard
            let rearDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else {
            throw CameraError.cameraUnavailable
        }

        let rearInput = try AVCaptureDeviceInput(device: rearDevice)
        let frontInput = try AVCaptureDeviceInput(device: frontDevice)
        var needsCommit = true
        session.beginConfiguration()
        defer {
            if needsCommit { session.commitConfiguration() }
        }

        guard session.canAddInput(rearInput) else { throw CameraError.cannotAddInput("后置") }
        session.addInputWithNoConnections(rearInput)
        guard session.canAddInput(frontInput) else { throw CameraError.cannotAddInput("前置") }
        session.addInputWithNoConnections(frontInput)

        guard
            let rearPort = rearInput.ports.first(where: { $0.mediaType == .video }),
            let frontPort = frontInput.ports.first(where: { $0.mediaType == .video })
        else {
            throw CameraError.cameraUnavailable
        }

        let rearLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        let frontLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        rearLayer.videoGravity = .resizeAspectFill
        frontLayer.videoGravity = .resizeAspectFill

        let rearPreviewConnection = AVCaptureConnection(inputPort: rearPort, videoPreviewLayer: rearLayer)
        let frontPreviewConnection = AVCaptureConnection(inputPort: frontPort, videoPreviewLayer: frontLayer)
        guard session.canAddConnection(rearPreviewConnection) else {
            throw CameraError.cannotConnectPreview("后置")
        }
        session.addConnection(rearPreviewConnection)
        guard session.canAddConnection(frontPreviewConnection) else {
            throw CameraError.cannotConnectPreview("前置")
        }
        session.addConnection(frontPreviewConnection)

        if frontPreviewConnection.isVideoMirroringSupported {
            frontPreviewConnection.automaticallyAdjustsVideoMirroring = false
            frontPreviewConnection.isVideoMirrored = true
        }

        let rearOutput = AVCapturePhotoOutput()
        let frontOutput = AVCapturePhotoOutput()
        let rearPhotoAvailable = attachPhotoOutput(rearOutput, to: rearPort)
        let frontPhotoAvailable = attachPhotoOutput(frontOutput, to: frontPort)

        if !rearPhotoAvailable { rearPhotoOutput = nil } else { rearPhotoOutput = rearOutput }
        if !frontPhotoAvailable { frontPhotoOutput = nil } else { frontPhotoOutput = frontOutput }
        self.rearDevice = rearDevice

        session.commitConfiguration()
        needsCommit = false
        session.startRunning()

        DispatchQueue.main.async {
            self.rearPreviewLayer = rearLayer
            self.frontPreviewLayer = frontLayer
        }
    }

    private func attachPhotoOutput(_ output: AVCapturePhotoOutput, to port: AVCaptureInput.Port) -> Bool {
        guard session.canAddOutput(output) else { return false }
        session.addOutputWithNoConnections(output)
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            session.removeOutput(output)
            return false
        }
        session.addConnection(connection)
        return true
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.rearDevice, device.hasTorch else {
                DispatchQueue.main.async {
                    self?.errorMessage = CameraError.torchUnavailable.localizedDescription
                }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.torchMode == .on {
                    device.torchMode = .off
                } else {
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                }
                let enabled = device.torchMode == .on
                DispatchQueue.main.async { self.isTorchOn = enabled }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func capturePhoto(completion: @escaping (Result<(rear: UIImage, front: UIImage), Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.session.isRunning,
                  let rearOutput = self.rearPhotoOutput,
                  let frontOutput = self.frontPhotoOutput else {
                DispatchQueue.main.async {
                    completion(Result.failure(CameraError.photoOutputsUnavailable))
                }
                return
            }

            let captureID = UUID()
            let pending = PendingPhotoCapture(completion: completion)
            self.activeCaptures[captureID] = pending

            let rearDelegate = PhotoCaptureDelegate { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { self.receive(result, side: .rear, captureID: captureID) }
            }
            let frontDelegate = PhotoCaptureDelegate { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { self.receive(result, side: .front, captureID: captureID) }
            }
            pending.rearDelegate = rearDelegate
            pending.frontDelegate = frontDelegate

            rearOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: rearDelegate)
            frontOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: frontDelegate)
        }
    }

    private func receive(_ result: Result<UIImage, Error>, side: CameraSide, captureID: UUID) {
        guard let pending = activeCaptures[captureID], !pending.didComplete else { return }
        switch result {
        case .success(let image):
            if side == .rear { pending.rearImage = image } else { pending.frontImage = image }
        case .failure(let error):
            pending.failure = error
        }

        if side == .rear { pending.rearFinished = true } else { pending.frontFinished = true }
        guard pending.rearFinished && pending.frontFinished else { return }
        pending.didComplete = true
        activeCaptures.removeValue(forKey: captureID)

        let completion = pending.completion
        if let failure = pending.failure {
            DispatchQueue.main.async { completion(.failure(failure)) }
        } else if let rear = pending.rearImage, let front = pending.frontImage {
            DispatchQueue.main.async { completion(.success((rear: rear, front: front))) }
        } else {
            DispatchQueue.main.async { completion(.failure(CameraError.captureFailed)) }
        }
    }
}

private final class PendingPhotoCapture {
    let completion: (Result<(rear: UIImage, front: UIImage), Error>) -> Void
    var rearImage: UIImage?
    var frontImage: UIImage?
    var rearFinished = false
    var frontFinished = false
    var didComplete = false
    var failure: Error?
    var rearDelegate: PhotoCaptureDelegate?
    var frontDelegate: PhotoCaptureDelegate?

    init(completion: @escaping (Result<(rear: UIImage, front: UIImage), Error>) -> Void) {
        self.completion = completion
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto?,
                     error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo?.fileDataRepresentation(), let image = UIImage(data: data) else {
            completion(.failure(CameraSessionManager.CameraError.captureFailed))
            return
        }
        completion(.success(image))
    }
}
