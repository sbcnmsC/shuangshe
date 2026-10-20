import AVFoundation
import CoreMedia
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Creates a genuine Live Photo pair: JPEG MakerApple["17"], movie content identifier,
/// and the timed still-image-time metadata track. The source movie is never modified.
final class LivePhotoConverter {
    static let shared = LivePhotoConverter()

    enum ConversionError: LocalizedError {
        case noVideoTrack
        case clipTooShort
        case readerSetup(String)
        case writerSetup(String)
        case imageExport
        case metadataSetup
        case movieExport(String)
        case photoPermission
        case photoSave(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "这个文件中没有可用的视频轨道。"
            case .clipTooShort: return "视频太短，至少需要约 0.5 秒才能转换。"
            case .readerSetup(let message): return "读取视频失败：\(message)"
            case .writerSetup(let message): return "建立实况视频失败：\(message)"
            case .imageExport: return "无法从视频提取封面照片。"
            case .metadataSetup: return "无法创建实况照片所需的元数据。"
            case .movieExport(let message): return "生成实况视频失败：\(message)"
            case .photoPermission: return "请允许 DualCam 将实况照片保存到系统照片图库。"
            case .photoSave(let message): return "保存实况照片失败：\(message)"
            }
        }
    }

    private init() {}

    /// Uses a centered clip (up to 3 seconds) and extracts the matching still frame.
    func convertVideoToLivePhoto(from sourceURL: URL,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.buildAndSavePair(from: sourceURL, completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func buildAndSavePair(from sourceURL: URL,
                                  completion: @escaping (Result<Void, Error>) -> Void) throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw ConversionError.noVideoTrack
        }

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        guard durationSeconds.isFinite, durationSeconds >= 0.5 else {
            throw ConversionError.clipTooShort
        }

        let clipSeconds = min(3.0, durationSeconds)
        let clipStartSeconds = max(0, (durationSeconds - clipSeconds) / 2)
        let clipStart = CMTime(seconds: clipStartSeconds, preferredTimescale: 600)
        let clipDuration = CMTime(seconds: clipSeconds, preferredTimescale: 600)
        let clipRange = CMTimeRange(start: clipStart, duration: clipDuration)
        let stillTime = CMTimeAdd(clipStart, CMTime(seconds: clipSeconds / 2, preferredTimescale: 600))
        let identifier = UUID().uuidString

        let root = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let photoURL = root.appendingPathComponent("DualCam-Live-\(token).jpg")
        let movieURL = root.appendingPathComponent("DualCam-Live-\(token).mov")
        try? FileManager.default.removeItem(at: photoURL)
        try? FileManager.default.removeItem(at: movieURL)

        do {
            try writeCoverImage(asset: asset, at: stillTime, identifier: identifier, to: photoURL)
            try writePairedMovie(asset: asset, videoTrack: videoTrack, clipRange: clipRange,
                                 stillTime: stillTime, identifier: identifier, to: movieURL) { result in
                switch result {
                case .success:
                    self.savePair(photoURL: photoURL, movieURL: movieURL, completion: completion)
                case .failure(let error):
                    try? FileManager.default.removeItem(at: photoURL)
                    try? FileManager.default.removeItem(at: movieURL)
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: movieURL)
            throw error
        }
    }

    private func writeCoverImage(asset: AVAsset, at time: CMTime,
                                  identifier: String, to url: URL) throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 4096, height: 4096)
        let image: CGImage
        do {
            image = try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw ConversionError.imageExport
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ConversionError.imageExport
        }
        let properties: [String: Any] = [
            kCGImagePropertyMakerAppleDictionary as String: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality as String: 0.96
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.imageExport
        }
    }

    private func writePairedMovie(asset: AVAsset, videoTrack: AVAssetTrack,
                                  clipRange: CMTimeRange, stillTime: CMTime,
                                  identifier: String, to outputURL: URL,
                                  completion: @escaping (Result<Void, Error>) -> Void) throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ConversionError.writerSetup(error.localizedDescription)
        }
        reader.timeRange = clipRange
        writer.shouldOptimizeForNetworkUse = false

        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.keySpace = .quickTimeMetadata
        contentIdentifier.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        contentIdentifier.value = identifier as NSString
        contentIdentifier.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [contentIdentifier]

        let stillKey = "com.apple.quicktime.still-image-time"
        let specification: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                "\(AVMetadataKeySpace.quickTimeMetadata.rawValue)/\(stillKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                kCMMetadataBaseDataType_SInt8
        ]
        var metadataDescription: CMMetadataFormatDescription?
        let metadataStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &metadataDescription
        )
        guard metadataStatus == noErr, let metadataDescription else {
            throw ConversionError.metadataSetup
        }

        let metadataInput = AVAssetWriterInput(mediaType: .metadata,
                                               outputSettings: nil,
                                               sourceFormatHint: metadataDescription)
        metadataInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(metadataInput) else { throw ConversionError.metadataSetup }
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        let writerInputs = try addPassThroughTrack(videoTrack, mediaType: .video,
                                                   reader: reader, writer: writer)
        var allInputs = writerInputs
        if let audioTrack = asset.tracks(withMediaType: .audio).first {
            let audioInputs = try addPassThroughTrack(audioTrack, mediaType: .audio,
                                                      reader: reader, writer: writer)
            allInputs.append(contentsOf: audioInputs)
        }

        guard writer.startWriting() else {
            throw ConversionError.writerSetup(writer.error?.localizedDescription ?? "未知错误")
        }
        writer.startSession(atSourceTime: clipRange.start)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ConversionError.readerSetup(reader.error?.localizedDescription ?? "未知错误")
        }

        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = stillKey as NSString
        stillItem.value = 0 as NSNumber
        stillItem.dataType = "com.apple.metadata.datatype.int8"
        let stillGroup = AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 30))
        )

        let transferQueue = DispatchQueue(label: "com.dualcam.livephoto.transfer",
                                          qos: .userInitiated,
                                          attributes: [])
        let group = DispatchGroup()
        let errorLock = NSLock()
        var transferError: Error?

        func recordError(_ error: Error) {
            errorLock.lock()
            if transferError == nil { transferError = error }
            errorLock.unlock()
        }

        for pair in allInputs {
            group.enter()
            var didFinish = false
            let finishLock = NSLock()
            pair.input.requestMediaDataWhenReady(on: transferQueue) {
                finishLock.lock()
                let alreadyFinished = didFinish
                finishLock.unlock()
                guard !alreadyFinished else { return }

                while pair.input.isReadyForMoreMediaData {
                    guard let sample = pair.output.copyNextSampleBuffer() else {
                        finishLock.lock()
                        let shouldFinish = !didFinish
                        didFinish = true
                        finishLock.unlock()
                        if shouldFinish {
                            pair.input.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                    if !pair.input.append(sample) {
                        recordError(writer.error ?? ConversionError.movieExport("视频帧写入失败"))
                        reader.cancelReading()
                        finishLock.lock()
                        let shouldFinish = !didFinish
                        didFinish = true
                        finishLock.unlock()
                        if shouldFinish {
                            pair.input.markAsFinished()
                            group.leave()
                        }
                        return
                    }
                }
            }
        }

        group.enter()
        var metadataFinished = false
        metadataInput.requestMediaDataWhenReady(on: transferQueue) {
            guard metadataInput.isReadyForMoreMediaData, !metadataFinished else { return }
            metadataFinished = true
            if !metadataAdaptor.append(stillGroup) {
                recordError(writer.error ?? ConversionError.metadataSetup)
            }
            metadataInput.markAsFinished()
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            errorLock.lock()
            let error = transferError
            errorLock.unlock()
            if let error {
                reader.cancelReading()
                writer.cancelWriting()
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            writer.finishWriting {
                guard writer.status == .completed else {
                    let error = ConversionError.movieExport(
                        writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "未知错误"
                    )
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                completion(.success(()))
            }
        }
    }

    private typealias TrackPair = (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)

    private func addPassThroughTrack(_ track: AVAssetTrack, mediaType: AVMediaType,
                                     reader: AVAssetReader, writer: AVAssetWriter) throws -> [TrackPair] {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw ConversionError.readerSetup("无法读取\(mediaType.rawValue)轨道") }
        reader.add(output)

        let formatHint = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: formatHint)
        input.expectsMediaDataInRealTime = false
        if mediaType == .video { input.transform = track.preferredTransform }
        guard writer.canAdd(input) else { throw ConversionError.writerSetup("无法写入\(mediaType.rawValue)轨道") }
        writer.add(input)
        return [(output, input)]
    }

    private func savePair(photoURL: URL, movieURL: URL,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: photoURL)
                try? FileManager.default.removeItem(at: movieURL)
                DispatchQueue.main.async { completion(.failure(ConversionError.photoPermission)) }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photoURL, options: nil)
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: videoOptions)
            }) { success, error in
                try? FileManager.default.removeItem(at: photoURL)
                try? FileManager.default.removeItem(at: movieURL)
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(ConversionError.photoSave(error?.localizedDescription ?? "未知错误")))
                    }
                }
            }
        }
    }
}
