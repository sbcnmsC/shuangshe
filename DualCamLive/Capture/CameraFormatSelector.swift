import AVFoundation
import CoreMedia

enum CameraFormatSelector {
    static func multiCamSupportedFormat(
        for device: AVCaptureDevice,
        position: AVCaptureDevice.Position,
        targetWidth: Int,
        fps: Double
    ) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { format in
            format.isMultiCamSupported &&
            format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        let available = candidates.isEmpty ? device.formats.filter(\.isMultiCamSupported) : candidates
        guard !available.isEmpty else { return nil }

        func longSide(_ format: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(max(d.width, d.height))
        }

        if position == .front {
            let binned = available.filter(\.isVideoBinned)
            let pool = binned.isEmpty ? available : binned
            return pool.min { longSide($0) < longSide($1) }
        }
        let crisp = available.filter { !$0.isVideoBinned }
        let pool = crisp.isEmpty ? available : crisp
        if let match = pool.filter({ longSide($0) >= targetWidth }).min(by: { longSide($0) < longSide($1) }) {
            return match
        }
        return pool.max { longSide($0) < longSide($1) }
    }
}
