import AVFoundation

/// 一个 .mov 文件的写入器：1 路视频（优先 HEVC）+ 可选音频。
/// 所有方法都应在同一个串行队列里调用（DualCameraManager 的 frameQueue）。
final class MovieWriter {
    let url: URL
    private let audioSettings: [String: Any]?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid

    private(set) var isStarted = false
    private(set) var failed = false

    init(audioSettings: [String: Any]?) {
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        self.audioSettings = audioSettings
    }

    private func videoSettings(codec: AVVideoCodecType, width: Int, height: Int, fps: Int) -> [String: Any] {
        // 码率按「每像素每帧」估算：HEVC 约 0.14 bit，1080x1920@30 ≈ 8.7 Mbps
        let bitrate = max(3_000_000, Int(Double(width * height) * Double(fps) * 0.14))
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ]
    }

    /// 收到第一帧视频时调用，此时才知道画面尺寸、像素格式和起始时间。
    func start(width: Int, height: Int, at pts: CMTime, pixelFormat: OSType, fps: Int) {
        guard !isStarted, !failed else { return }
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)

            var v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: videoSettings(codec: .hevc, width: width, height: height, fps: fps))
            if !w.canAdd(v) {
                v = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: videoSettings(codec: .h264, width: width, height: height, fps: fps))
            }
            v.expectsMediaDataInRealTime = true

            let ad = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: v,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ])

            guard w.canAdd(v) else { failed = true; return }
            w.add(v)

            if let audioSettings {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); audioInput = a }
            }

            guard w.startWriting() else { failed = true; return }
            w.startSession(atSourceTime: pts)

            writer = w
            videoInput = v
            adaptor = ad
            startPTS = pts
            isStarted = true
        } catch {
            failed = true
        }
    }

    func append(_ pixelBuffer: CVPixelBuffer, at pts: CMTime) {
        guard isStarted, !failed, let v = videoInput, v.isReadyForMoreMediaData else { return }
        if lastPTS.isValid && pts <= lastPTS { return }
        if adaptor?.append(pixelBuffer, withPresentationTime: pts) == true {
            lastPTS = pts
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard isStarted, !failed, let a = audioInput, a.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts >= startPTS else { return }   // 丢掉视频开始前的音频
        a.append(sampleBuffer)
    }

    func finish(_ done: @escaping (URL?) -> Void) {
        guard isStarted, !failed, let writer else { done(nil); return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            done(writer.status == .completed ? self.url : nil)
        }
    }
}
